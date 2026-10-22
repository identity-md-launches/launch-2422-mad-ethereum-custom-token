// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {MadTestBase} from "./Base.t.sol";
import {MadHook} from "src/MadHook.sol";
import {MadRewards} from "src/MadRewards.sol";
import {MockFWA} from "./mocks/MockFWA.sol";
import {TestRouter} from "./mocks/TestRouter.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";

contract MadHookAdversarialTest is MadTestBase {
    function test_failedPayoutCannotDestroyClaimsAndLaterRetryPaysOnce() public {
        _open(900);
        _swap(true, -1000 ether);
        uint256 pg = hook.playgroundClaims();
        uint256 nft = hook.nftFwaClaims();
        uint256 receiverBalance = fwa.balanceOf(hook.receiver());
        // An outside token can temporarily reject a transfer. The PoolManager's claim burn
        // and the hook's accounting must both roll back, even though they occur before take.
        vm.mockCallRevert(
            FWA,
            abi.encodeWithSelector(fwa.transfer.selector, hook.receiver(), pg),
            abi.encodeWithSignature("InvalidTransfer()")
        );
        vm.expectRevert();
        hook.payout();
        assertEq(hook.playgroundClaims(), pg);
        assertEq(hook.nftFwaClaims(), nft);
        assertEq(manager.balanceOf(address(hook), uint160(FWA)), pg + nft);
        assertEq(fwa.balanceOf(hook.receiver()), receiverBalance);
        vm.clearMockedCalls();
        assertEq(hook.payout(), pg);
        assertEq(hook.payout(), 0);
        assertEq(fwa.balanceOf(hook.receiver()), receiverBalance + pg);
        assertEq(manager.balanceOf(address(hook), uint160(FWA)), nft);
    }

    function test_failedNativeRedemptionRetainsOnlyNFTClaims() public {
        _market(Q96 * 2);
        vm.deal(address(manager), 0);
        _open(1800);
        _swap(true, -1000 ether);
        uint256 nativeClaims = hook.nftEthClaims();
        uint256 pg = hook.playgroundClaims();
        vm.expectRevert();
        hook.flushNftETH();
        assertEq(hook.nftEthClaims(), nativeClaims);
        assertEq(manager.balanceOf(address(hook), 0), nativeClaims);
        assertEq(hook.playgroundClaims(), pg);
        assertEq(address(rewards).balance, 0);
        // FWA payout remains possible while the manager's ETH reserve is empty.
        assertEq(hook.payout(), pg);
        vm.deal(address(manager), nativeClaims);
        hook.flushNftETH();
        assertEq(address(rewards).balance, nativeClaims);
        assertEq(hook.nftEthClaims(), 0);
        assertEq(manager.balanceOf(address(hook), 0), 0);
    }

    function test_poolChangeInvalidatesConversionPermissionButPreservesBudgets() public {
        _market(Q96 * 2);
        _open(1800);
        vm.prank(OWNER);
        hook.setConversionBounds(Q96 - 1, 1 << 126);
        _swap(true, -1000 ether);
        assertEq(hook.nftFwaClaims(), 5 ether);
        vm.prank(OWNER);
        hook.setEthFwaPool(market);
        assertEq(hook.sqrtPriceLimitX96(), 0);
        assertEq(hook.minEthPerFwaX128(), 0);
        _swap(true, -1000 ether);
        assertEq(hook.nftFwaClaims(), 10 ether);
        assertEq(hook.playgroundClaims(), 10 ether);
        assertEq(address(rewards).balance, 0);
        vm.prank(OWNER);
        hook.setConversionBounds(Q96 * 2, 1 << 126);
        _swap(true, -1000 ether);
        assertEq(hook.nftFwaClaims(), 0);
        assertEq(hook.playgroundClaims(), 15 ether);
        assertGt(address(rewards).balance, 0);
    }

    function test_conversionAndMarketSettersRejectUnauthorizedAndUnsafeBounds() public {
        vm.expectRevert(MadHook.Unauthorized.selector);
        hook.setConversionBounds(Q96 * 2, 1);
        vm.expectRevert(MadHook.Unauthorized.selector);
        hook.setEthFwaPool(key);
        vm.startPrank(OWNER);
        vm.expectRevert(MadHook.InvalidConfig.selector);
        hook.setConversionBounds(TickMath.MIN_SQRT_PRICE, 1);
        vm.expectRevert(MadHook.InvalidConfig.selector);
        hook.setConversionBounds(TickMath.MAX_SQRT_PRICE, 1);
        vm.expectRevert(MadHook.InvalidConfig.selector);
        hook.setConversionBounds(Q96, 0);
        PoolKey memory bad = PoolKey(Currency.wrap(address(token)), Currency.wrap(FWA), 0, 60, IHooks(MARKET_HOOK));
        vm.expectRevert(MadHook.InvalidPool.selector);
        hook.setEthFwaPool(bad);
        bad.currency0 = Currency.wrap(address(0));
        bad.hooks = IHooks(address(hook));
        vm.expectRevert(MadHook.InvalidPool.selector);
        hook.setEthFwaPool(bad);
        bad.hooks = IHooks(MARKET_HOOK);
        bad.tickSpacing = 0;
        vm.expectRevert(MadHook.InvalidPool.selector);
        hook.setEthFwaPool(bad);
        vm.stopPrank();
    }

    function test_zeroAndOutOfInt128SwapsCannotPoisonNextSwap() public {
        _open(900);
        int256[4] memory invalid =
            [int256(0), int256(type(int128).max) + 1, -int256(type(int128).max) - 1, type(int256).min];
        bool z = Currency.unwrap(key.currency0) == FWA;
        for (uint256 i; i < invalid.length; ++i) {
            vm.prank(address(manager));
            vm.expectRevert(MadHook.InvalidSwap.selector);
            hook.beforeSwap(
                address(router),
                key,
                SwapParams(z, invalid[i], z ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1),
                ""
            );
        }
        _swap(true, -1000 ether);
        assertEq(hook.playgroundClaims(), 5 ether);
        assertEq(hook.nftFwaClaims(), 5 ether);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_feeRoundingBoundAndMonotonicDecay(uint128 rawAmount, uint16 rawElapsed, uint16 rawLater) public {
        uint256 amount = rawAmount;
        uint256 elapsed = bound(rawElapsed, 0, 3600);
        _open(elapsed);
        uint256 fee = hook.feeFor(amount);
        // Cross-multiplication checks floor rounding without copying Math.mulDiv.
        uint256 numerator = elapsed >= 1800 ? 180_000 : 17_820_000 - 9800 * elapsed;
        uint256 exactScaled = amount * numerator;
        assertLe(fee * 18_000_000, exactScaled);
        assertGt((fee + 1) * 18_000_000, exactScaled);
        assertGe(fee, amount / 100);
        assertLe(fee, amount * 99 / 100);
        vm.warp(block.timestamp + bound(rawLater, 0, 3600));
        assertLe(hook.feeFor(amount), fee);
    }

    function test_restingDustAndLaunchFeeBoundariesThroughRealManager() public {
        _open(0);
        uint256[7] memory values = [uint256(1), 99, 100, 199, 200, 201, 399];
        for (uint256 period; period < 2; ++period) {
            vm.warp(uint256(hook.openedAt()) + period * 1800);
            for (uint256 i; i < values.length; ++i) {
                uint256 amount = values[i];
                uint256 pg = hook.playgroundClaims();
                uint256 burns = fwa.burned();
                _swap(true, -int256(amount));
                assertEq(hook.playgroundClaims() - pg, amount / 200);
                assertEq(hook.nftFwaClaims(), hook.playgroundClaims());
                uint256 fee = period == 0 ? amount * 99 / 100 : amount / 100;
                assertEq(fwa.burned() - burns, fee - 2 * (amount / 200));
            }
        }
    }
}

contract MadConversionHandler is Test {
    using StateLibrary for IPoolManager;
    MadHook public immutable hook;
    TestRouter public immutable router;
    IPoolManager public immutable manager;
    MockFWA public immutable fwa;
    address public immutable trader;
    address public immutable owner;
    PoolKey private key;
    PoolKey private market;
    uint256 public sharesEarned;
    uint256 public feesBurned;
    uint256 public paid;
    uint256 public swaps;

    constructor(MadHook h, TestRouter r, PoolKey memory k, PoolKey memory m, address a, address o) {
        hook = h;
        router = r;
        manager = h.poolManager();
        fwa = MockFWA(h.FWA());
        key = k;
        market = m;
        trader = a;
        owner = o;
    }

    function swap(uint96 rawAmount, uint16 advance) external {
        uint256 amount = _bound(rawAmount, 10_000, 100 ether);
        vm.warp(vm.getBlockTimestamp() + _bound(advance, 0, 600));
        uint256 elapsed = vm.getBlockTimestamp() - hook.openedAt();
        uint256 numerator = elapsed >= 1800 ? 180_000 : 17_820_000 - 9800 * elapsed;
        uint256 share = amount / 200;
        bool z = Currency.unwrap(key.currency0) == hook.FWA();
        vm.prank(trader);
        router.swap(key, SwapParams(z, -int256(amount), z ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1));
        sharesEarned += share;
        feesBurned += amount * numerator / 18_000_000 - 2 * share;
        ++swaps;
    }

    function setLimit(uint8 choice) external {
        (uint160 price,,,) = manager.getSlot0(market.toId());
        uint160 limit = choice % 3 == 0 ? price : choice % 3 == 1 ? price + price / 100_000 : price * 2;
        // The minimum may not exceed the price the bound itself allows; take the stricter of the two.
        uint256 atBound = hook.ethPerFwaX128(limit);
        uint256 minimum = atBound < 1 << 126 ? atBound : 1 << 126;
        if (atBound < type(uint256).max) {
            vm.prank(owner);
            vm.expectRevert(MadHook.InvalidConfig.selector);
            hook.setConversionBounds(limit, atBound + 1);
        }
        vm.prank(owner);
        hook.setConversionBounds(limit, minimum);
    }

    function payout() external {
        uint256 expected = sharesEarned - paid;
        assertEq(hook.payout(), expected);
        paid += expected;
    }

    function flush() external {
        uint256 budget = hook.rewards().nftBudget();
        hook.flushNftETH();
        assertEq(hook.rewards().nftBudget(), budget, "redeeming is not new revenue");
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 80
/// forge-config: default.invariant.fail-on-revert = true
contract MadConversionInvariantTest is MadTestBase {
    MadConversionHandler internal handler;
    uint256 internal initialSupply;
    uint256 internal initialNative;

    function setUp() public override {
        super.setUp();
        _market(Q96 + Q96 / 100_000);
        _open(0);
        initialSupply = fwa.totalSupply();
        initialNative = address(manager).balance;
        handler = new MadConversionHandler(hook, router, key, market, ALICE, OWNER);
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = handler.swap.selector;
        selectors[1] = handler.setLimit.selector;
        selectors[2] = handler.payout.selector;
        selectors[3] = handler.flush.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function invariant_feeRevenueConservationWithPartialConversionsAndPayouts() public view {
        assertEq(hook.playgroundClaims() + handler.paid(), handler.sharesEarned());
        assertEq(fwa.balanceOf(hook.receiver()), handler.paid());
        assertLe(hook.nftFwaClaims(), handler.sharesEarned());
        assertEq(manager.balanceOf(address(hook), uint160(FWA)), hook.playgroundClaims() + hook.nftFwaClaims());
        assertEq(manager.balanceOf(address(hook), 0), hook.nftEthClaims());
        assertEq(fwa.totalSupply() + handler.feesBurned(), initialSupply);
        assertEq(fwa.burned(), handler.feesBurned());
        assertEq(fwa.balanceOf(address(hook)), 0);
        assertEq(fwa.balanceOf(address(rewards)), 0);
        assertEq(address(manager).balance + address(rewards).balance, initialNative);
        assertEq(rewards.nftBudget(), address(rewards).balance + hook.nftEthClaims());
    }

    function test_conversionHandlerExercisesPartialDeferredAndCompleteSales() public {
        handler.swap(100 ether, 0);
        assertGt(hook.nftFwaClaims(), 0);
        assertGt(address(rewards).balance, 0);
        handler.setLimit(0);
        uint256 retained = hook.nftFwaClaims();
        handler.swap(100 ether, 900);
        assertEq(hook.nftFwaClaims(), retained + 0.5 ether);
        handler.payout();
        handler.setLimit(2);
        handler.swap(100 ether, 900);
        assertEq(hook.nftFwaClaims(), 0);
        handler.flush();
        invariant_feeRevenueConservationWithPartialConversionsAndPayouts();
    }
}
