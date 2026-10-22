// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {MadTestBase} from "./Base.t.sol";
import {MadHook} from "../src/MadHook.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Vm} from "forge-std/Vm.sol";
import {MockMarketHook} from "./mocks/MockMarketHook.sol";

contract MadHookTest is MadTestBase {
    function test_permissionsOwnerSizeAndClosedTrading() public {
        assertEq(hook.owner(), OWNER);
        assertEq(rewards.owner(), OWNER);
        assertLe(address(hook).code.length, 24_576);
        assertLe(address(rewards).code.length, 24_576);
        assertLe(address(token).code.length, 24_576);
        assertEq(uint160(address(hook)) & ((1 << 14) - 1), hook.HOOK_FLAGS());
        Hooks.Permissions memory p = hook.getHookPermissions();
        assertTrue(
            p.beforeInitialize && p.beforeSwap && p.afterSwap && p.beforeSwapReturnDelta && p.afterSwapReturnDelta
        );
        assertFalse(p.beforeRemoveLiquidity || p.afterRemoveLiquidity || p.beforeAddLiquidity || p.afterAddLiquidity);
        vm.expectRevert();
        _swap(true, -1 ether);
        vm.prank(OWNER);
        vm.expectRevert();
        router.swap(key, SwapParams(true, -1 ether, TickMath.MIN_SQRT_PRICE + 1));
        vm.expectRevert(MadHook.Unauthorized.selector);
        hook.enableTrading();
        vm.prank(OWNER);
        hook.enableTrading();
        vm.prank(OWNER);
        vm.expectRevert(MadHook.AlreadyEnabled.selector);
        hook.enableTrading();
    }

    function test_callbacksAuthenticateManagerPoolAndContext() public {
        SwapParams memory p = SwapParams(true, -1 ether, TickMath.MIN_SQRT_PRICE + 1);
        vm.expectRevert(MadHook.Unauthorized.selector);
        hook.beforeSwap(ALICE, key, p, "");
        vm.expectRevert(MadHook.Unauthorized.selector);
        hook.afterSwap(ALICE, key, p, BalanceDelta.wrap(0), "");
        vm.expectRevert(MadHook.Unauthorized.selector);
        hook.beforeInitialize(address(this), key, Q96);
        vm.expectRevert(MadHook.Unauthorized.selector);
        hook.unlockCallback(abi.encode(1));
        vm.prank(address(manager));
        vm.expectRevert(MadHook.InvalidUnlock.selector);
        hook.unlockCallback(abi.encode(1));
        PoolKey memory wrong = key;
        wrong.fee = 3000;
        vm.prank(address(manager));
        vm.expectRevert(MadHook.InvalidPool.selector);
        hook.beforeSwap(ALICE, wrong, p, "");
        vm.prank(address(manager));
        vm.expectRevert(MadHook.InvalidSwap.selector);
        hook.afterSwap(ALICE, key, p, BalanceDelta.wrap(0), "");
    }

    function test_liquidityAndFeeCollectionNotGated() public {
        BalanceDelta d = router.modify(key, ModifyLiquidityParams(-887220, 887220, 0, bytes32(0)));
        assertEq(d.amount0(), 0);
        assertEq(d.amount1(), 0);
        router.modify(key, ModifyLiquidityParams(-600, 600, 1 ether, bytes32(0)));
        router.modify(key, ModifyLiquidityParams(-600, 600, -1 ether, bytes32(0)));
        _open(1800);
        _swap(true, -1000 ether);
        d = router.modify(key, ModifyLiquidityParams(-887220, 887220, 0, bytes32(0)));
        assertTrue(d.amount0() > 0 || d.amount1() > 0);
    }

    function test_decayAtZeroFifteenAndThirtyMinutes() public {
        _open(0);
        assertEq(hook.feeFor(10_000 ether), 9900 ether);
        vm.warp(hook.openedAt() + 900);
        assertEq(hook.feeFor(10_000 ether), 5000 ether);
        vm.warp(hook.openedAt() + 1800);
        assertEq(hook.feeFor(10_000 ether), 100 ether);
        vm.warp(hook.openedAt() + 1 days);
        assertEq(hook.feeFor(10_000 ether), 100 ether);
    }

    function test_allSwapModesDuringDecayAndAtRest() public {
        _open(0);
        for (uint256 time; time < 3; ++time) {
            vm.warp(hook.openedAt() + time * 900);
            for (uint256 mode; mode < 4; ++mode) {
                _assertSwap(mode < 2, mode % 2 == 0, 100 ether);
            }
        }
    }

    function testFuzz_swapFeeAccounting(uint96 raw, uint16 elapsed, bool buyMad, bool exactInput) public {
        _open(bound(elapsed, 0, 3600));
        _assertSwap(buyMad, exactInput, bound(raw, 10_000, 1000 ether));
    }

    function _assertSwap(bool buyMad, bool exactInput, uint256 amount) internal {
        uint256 pg = hook.playgroundClaims();
        uint256 nft = hook.nftFwaClaims();
        uint256 burned = fwa.burned();
        uint256 supply = fwa.totalSupply();
        uint256 madSupply = token.totalSupply();
        vm.recordLogs();
        BalanceDelta d = _swap(buyMad, exactInput ? -int256(amount) : int256(amount));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 count;
        uint256 base;
        uint256 fee;
        uint256 share;
        uint256 burnAmount;
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter == address(hook)
                    && logs[i].topics[0] == keccak256("FeeCharged(uint256,uint256,uint256,uint256,uint256)")
            ) {
                uint256 other;
                (base, fee, share, other, burnAmount) =
                    abi.decode(logs[i].data, (uint256, uint256, uint256, uint256, uint256));
                assertEq(share, other);
                ++count;
            }
        }
        assertEq(count, 1, "one fee callback per swap");
        uint256 rate = hook.feeNumerator();
        uint256 den = hook.RATE_DENOMINATOR();
        if (!buyMad && !exactInput) {
            assertEq(fee, Math.mulDiv(amount, rate, den - rate, Math.Rounding.Ceil));
            assertEq(base, amount + fee);
        } else if (buyMad && !exactInput) {
            // Gross-up of the net FWA the pool consumed: fee / gross == schedule, like every other route.
            assertEq(fee, Math.mulDiv(base - fee, rate, den - rate, Math.Rounding.Ceil));
            assertLe(base * rate / den, fee);
            assertLe(fee - base * rate / den, 2);
        } else {
            assertEq(fee, Math.mulDiv(base, rate, den));
        }
        int128 fwaD = Currency.unwrap(key.currency0) == FWA ? d.amount0() : d.amount1();
        if (buyMad && exactInput) {
            assertEq(base, amount);
            assertEq(-int256(fwaD), int256(amount));
        } else if (buyMad) {
            assertEq(-int256(fwaD), int256(base), "trader pays exactly the gross FWA base");
        } else {
            assertEq(int256(fwaD), int256(base - fee));
        }
        assertEq(share, base / 200);
        assertEq(hook.playgroundClaims() - pg, share);
        assertEq(hook.nftFwaClaims() - nft, share);
        assertEq(fwa.burned() - burned, burnAmount);
        assertEq(supply - fwa.totalSupply(), burnAmount);
        assertEq(burnAmount, fee - 2 * share);
        assertEq(token.totalSupply(), madSupply, "no MAD protocol tax");
        assertEq(fwa.balanceOf(address(hook)), 0, "burn immediately");
        assertEq(manager.balanceOf(address(hook), uint160(FWA)), hook.playgroundClaims() + hook.nftFwaClaims());
    }

    function _buy(int256 amount) internal returns (uint256 fwaPaid, uint256 madReceived) {
        uint256 f0 = fwa.balanceOf(ALICE);
        uint256 m0 = token.balanceOf(ALICE);
        _swap(true, amount);
        fwaPaid = f0 - fwa.balanceOf(ALICE);
        madReceived = token.balanceOf(ALICE) - m0;
    }

    function test_exactOutputBuyPaysTheSameScheduleAsExactInputBuy() public {
        _open(0);
        (uint256 paidIn, uint256 madIn) = _buy(-100 ether);
        assertEq(hook.feeFor(paidIn), 99 ether);
        (uint256 paidOut, uint256 madOut) = _buy(int256(madIn));
        assertEq(madOut, madIn);
        assertApproxEqRel(paidOut, paidIn, 0.001e18, "same MAD costs the same gross FWA on either route");
        vm.warp(hook.openedAt() + 900);
        (paidIn, madIn) = _buy(-100 ether);
        (paidOut, madOut) = _buy(int256(madIn));
        assertEq(madOut, madIn);
        assertApproxEqRel(paidOut, paidIn, 0.001e18, "50% route parity");
    }

    function test_payoutDirectFromManagerSeparateAndIdempotentBeforeSetup() public {
        _open(0);
        _swap(true, -1000 ether);
        uint256 share = hook.playgroundClaims();
        uint256 nft = hook.nftFwaClaims();
        uint256 before = fwa.balanceOf(hook.receiver());
        vm.prank(BOB);
        assertEq(hook.payout(), share);
        assertEq(fwa.balanceOf(hook.receiver()), before + share);
        assertEq(fwa.lastTransferFrom(), address(manager));
        assertEq(fwa.lastTransferTo(), hook.receiver());
        assertEq(hook.playgroundClaims(), 0);
        assertEq(hook.nftFwaClaims(), nft);
        assertEq(hook.payout(), 0);
        assertEq(manager.balanceOf(address(hook), uint160(FWA)), nft);
        address recipient = hook.receiver();
        vm.prank(ALICE);
        vm.expectRevert();
        fwa.transfer(recipient, 1);
        (bool ok,) = address(hook).call(abi.encodeWithSignature("setReceiver(address)", BOB));
        assertFalse(ok);
        (ok,) = address(hook).call(abi.encodeWithSignature("setProtocolRecipient(address)", BOB));
        assertFalse(ok);
    }

    function test_onlyNFTShareConvertsInsideSwap() public {
        _market(Q96 * 2);
        _open(900);
        _swap(true, -1000 ether);
        assertEq(hook.playgroundClaims(), 5 ether);
        assertEq(hook.nftFwaClaims(), 0);
        assertGt(address(rewards).balance, 4 ether);
        assertLt(address(rewards).balance, 5 ether); // official market's modeled 1% fee and price impact
        assertEq(MockMarketHook(MARKET_HOOK).swaps(), 1);
        assertEq(manager.balanceOf(address(hook), uint160(FWA)), 5 ether);
        uint256 budget = address(rewards).balance;
        hook.payout();
        assertEq(address(rewards).balance, budget);
    }

    function test_priceBoundPartialNFTSaleCarriesOnlyUnsoldNFTClaims() public {
        _market(Q96 + Q96 / 10_000);
        _open(1800);
        _swap(true, -1000 ether);
        assertGt(hook.nftFwaClaims(), 4 ether);
        assertLt(hook.nftFwaClaims(), 5 ether);
        assertGt(address(rewards).balance, 0);
        assertEq(hook.playgroundClaims(), 5 ether);
        vm.prank(OWNER);
        hook.setConversionBounds(Q96 * 2, 1 << 126);
        _swap(true, -1000 ether);
        assertEq(hook.nftFwaClaims(), 0);
        assertEq(hook.playgroundClaims(), 10 ether);
        assertEq(MockMarketHook(MARKET_HOOK).swaps(), 2);
    }

    function test_nativeClaimsWhenManagerHasNoETHAndLaterRedemption() public {
        _market(Q96 * 2);
        vm.deal(address(manager), 0);
        _open(1800);
        _swap(true, -1000 ether);
        uint256 claims = hook.nftEthClaims();
        assertGt(claims, 0);
        assertEq(address(rewards).balance, 0);
        assertEq(rewards.nftBudget(), claims);
        vm.deal(address(manager), 1000 ether);
        hook.flushNftETH();
        assertEq(hook.nftEthClaims(), 0);
        assertEq(address(rewards).balance, claims);
        hook.flushNftETH();
        assertEq(address(rewards).balance, claims);
    }

    function test_inconsistentMinimumRejectedAndStaleLimitDefers() public {
        _market(Q96 * 2);
        _open(1800);
        // 2 ETH per FWA cannot be guaranteed by a bound whose price is 0.25 ETH per FWA.
        assertEq(hook.ethPerFwaX128(Q96 * 2), 1 << 126);
        assertEq(hook.ethPerFwaX128(Q96), 1 << 128);
        vm.prank(OWNER);
        vm.expectRevert(MadHook.InvalidConfig.selector);
        hook.setConversionBounds(Q96 * 2, 2 << 128);
        vm.prank(OWNER);
        hook.setConversionBounds(Q96 - 1, 1 << 126);
        _swap(true, -1000 ether);
        assertEq(hook.nftFwaClaims(), 5 ether);
        assertEq(address(rewards).balance, 0);
        assertEq(MockMarketHook(MARKET_HOOK).swaps(), 0);
    }

    function _parkMarket(uint160 target) internal {
        router.swap(market, SwapParams(false, -1_000_000 ether, target));
        (uint160 current,,,) = StateLibrary.getSlot0(manager, market.toId());
        assertEq(current, target);
    }

    function test_parkedMarketPriceDefersConversionInsteadOfFailingTrades() public {
        _market(Q96 * 2);
        _open(1800);
        _swap(true, -1000 ether);
        assertEq(hook.nftFwaClaims(), 0);
        uint256 budget = address(rewards).balance;
        // Any FWA holder can leave the official market one unit under the owner's bound.
        _parkMarket(Q96 * 2 - 1);
        _swap(true, -1000 ether);
        assertEq(hook.nftFwaClaims(), 5 ether, "claims wait for a later swap");
        _swap(false, -1000 ether);
        assertGt(hook.nftFwaClaims(), 5 ether);
        _swap(true, 1 ether);
        _swap(false, 1 ether);
        assertEq(address(rewards).balance, budget);
        assertEq(MockMarketHook(MARKET_HOOK).swaps(), 2, "one conversion plus the parking swap");
        // Once the bound again lies above the market, the waiting claims sell on the next swap.
        vm.prank(OWNER);
        hook.setConversionBounds(Q96 * 3, 1 << 124);
        _swap(true, -1000 ether);
        assertEq(hook.nftFwaClaims(), 0);
        assertGt(address(rewards).balance, budget);
        assertEq(MockMarketHook(MARKET_HOOK).swaps(), 3);
    }

    function test_dustShareNeverFailsASwap() public {
        _market(Q96 * 2);
        _open(1800);
        uint256 nft = hook.nftFwaClaims();
        _swap(true, -300);
        assertEq(hook.nftFwaClaims(), nft + 1);
        assertEq(MockMarketHook(MARKET_HOOK).swaps(), 0);
        _parkMarket(Q96 * 2 - 1);
        _swap(true, -300);
        assertEq(hook.nftFwaClaims(), nft + 2);
    }

    function test_largeBuyAtOpenDefersBurnUntilFlushed() public {
        _open(0);
        uint256 reserve = fwa.balanceOf(address(manager));
        fwa.mint(ALICE, reserve * 10);
        uint256 burnedBefore = fwa.burned();
        _swap(true, -int256(reserve * 3));
        uint256 deferred = hook.burnClaims();
        assertGt(deferred, reserve);
        assertEq(fwa.burned(), burnedBefore);
        assertEq(
            manager.balanceOf(address(hook), uint160(FWA)),
            hook.playgroundClaims() + hook.nftFwaClaims() + deferred,
            "burn claims are tracked apart from revenue claims"
        );
        assertEq(hook.flushBurn(), deferred);
        assertEq(hook.burnClaims(), 0);
        assertEq(fwa.burned(), burnedBefore + deferred);
        assertEq(fwa.balanceOf(address(hook)), 0);
        assertEq(hook.flushBurn(), 0);
        assertEq(manager.balanceOf(address(hook), uint160(FWA)), hook.playgroundClaims() + hook.nftFwaClaims());
    }

    function test_partialMainSpecifiedSwapRevertsInsteadOfChargingUnspentInput() public {
        _open(1800);
        bool z = Currency.unwrap(key.currency0) == FWA;
        vm.prank(ALICE);
        vm.expectRevert();
        router.swap(key, SwapParams(z, -1000 ether, z ? Q96 - 1 : Q96 + 1));
        assertEq(hook.playgroundClaims(), 0);
    }
}
