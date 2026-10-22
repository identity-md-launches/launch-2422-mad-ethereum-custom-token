// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {MadTestBase} from "./Base.t.sol";
import {MadHook} from "src/MadHook.sol";
import {MockFWA} from "./mocks/MockFWA.sol";
import {TestRouter} from "./mocks/TestRouter.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @dev Reads the hook's FeeCharged record from a recorded swap. The fee is then checked against
/// amounts the trader actually paid or received, not against the hook's own arithmetic.
abstract contract FeeLog is Test {
    bytes32 internal constant FEE_CHARGED = keccak256("FeeCharged(uint256,uint256,uint256,uint256,uint256)");

    function _feeCharged(address hook)
        internal
        returns (uint256 base, uint256 fee, uint256 playground, uint256 nft, uint256 burned)
    {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == hook && logs[i].topics[0] == FEE_CHARGED) {
                (base, fee, playground, nft, burned) =
                    abi.decode(logs[i].data, (uint256, uint256, uint256, uint256, uint256));
                ++found;
            }
        }
        assertEq(found, 1, "exactly one fee charge per swap");
    }
}

/// @dev Drives the same-swap burn and its deferral when the PoolManager holds less FWA than the
/// burn. No ETH/FWA market is configured, so NFT claims are never converted here.
contract MadBurnDeferralHandler is FeeLog {
    uint256 private constant DEN = 10_000 * 1800;
    MadHook public immutable hook;
    TestRouter public immutable router;
    IPoolManager public immutable manager;
    MockFWA public immutable fwa;
    address public immutable trader;
    PoolKey private key;
    bool private immutable fwaIs0;

    uint256 public sharesEarned;
    uint256 public paid;
    uint256 public burnedInSwap;
    uint256 public burnOutstanding;
    uint256 public burnFlushed;
    uint256 public minted;
    uint256 public deferrals;
    uint256 public flushes;
    uint256 public bigIn;

    constructor(MadHook h, TestRouter r, PoolKey memory k, address t) {
        hook = h;
        router = r;
        manager = h.poolManager();
        fwa = MockFWA(h.FWA());
        key = k;
        trader = t;
        fwaIs0 = Currency.unwrap(k.currency0) == h.FWA();
    }

    function buy(uint96 raw, uint16 advance) external {
        vm.warp(vm.getBlockTimestamp() + _bound(advance, 0, 600));
        _buy(_bound(raw, 1e6, 100 ether));
    }

    /// @dev Large enough that the burn exceeds the manager's whole FWA balance during the decay.
    function bigBuy(uint16 scale, uint16 advance) external {
        vm.warp(vm.getBlockTimestamp() + _bound(advance, 0, 300));
        uint256 rate = hook.feeNumerator();
        if (rate < 180_000 + 10 * 9800 || bigIn > 1e31) return;
        uint256 balance = fwa.balanceOf(address(manager));
        uint256 amount = Math.mulDiv(balance, DEN, rate - 180_000) * _bound(scale, 101, 300) / 100;
        bigIn += amount;
        uint256 deferredBefore = deferrals;
        _buy(amount);
        assertEq(deferrals, deferredBefore + 1, "a burn above the manager's balance is deferred, not reverted");
    }

    function _buy(uint256 amount) private {
        fwa.mint(trader, amount);
        minted += amount;
        uint256 rate = hook.feeNumerator();
        uint256 fee = Math.mulDiv(amount, rate, DEN);
        uint256 share = amount / 200;
        uint256 burned = fee - 2 * share;
        bool defer = burned > fwa.balanceOf(address(manager));
        uint256 fwaBefore = fwa.balanceOf(trader);
        vm.prank(trader);
        router.swap(
            key, SwapParams(fwaIs0, -int256(amount), fwaIs0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1)
        );
        assertEq(fwaBefore - fwa.balanceOf(trader), amount, "exact gross input");
        _account(share, burned, defer);
    }

    function sell(uint96 raw, uint16 advance) external {
        vm.warp(vm.getBlockTimestamp() + _bound(advance, 0, 600));
        uint256 amount = _bound(raw, 1e6, 100 ether);
        uint256 managerFwa = fwa.balanceOf(address(manager));
        uint256 fwaBefore = fwa.balanceOf(trader);
        uint256 rate = hook.feeNumerator();
        vm.recordLogs();
        vm.prank(trader);
        router.swap(
            key,
            SwapParams(!fwaIs0, -int256(amount), fwaIs0 ? TickMath.MAX_SQRT_PRICE - 1 : TickMath.MIN_SQRT_PRICE + 1)
        );
        (uint256 base, uint256 fee, uint256 pg, uint256 nft, uint256 burned) = _feeCharged(address(hook));
        assertEq(fwa.balanceOf(trader) - fwaBefore + fee, base, "fee base is the gross FWA output");
        assertEq(fee, Math.mulDiv(base, rate, DEN), "floor of the scheduled rate");
        assertEq(pg, base / 200);
        assertEq(nft, pg);
        assertEq(burned, fee - 2 * pg);
        _account(pg, burned, burned > managerFwa);
    }

    function _account(uint256 share, uint256 burned, bool defer) private {
        sharesEarned += share;
        if (defer) {
            burnOutstanding += burned;
            ++deferrals;
        } else {
            burnedInSwap += burned;
        }
        assertEq(hook.playgroundClaims() + paid, sharesEarned);
        assertEq(hook.nftFwaClaims(), sharesEarned);
        assertEq(hook.burnClaims(), burnOutstanding);
        assertEq(fwa.burned(), burnedInSwap + burnFlushed);
    }

    function payout() external {
        uint256 burnBefore = hook.burnClaims();
        uint256 expected = sharesEarned - paid;
        assertEq(hook.payout(), expected);
        paid += expected;
        assertEq(hook.burnClaims(), burnBefore, "burn claims are never paid to the receiver");
    }

    function flushBurn() external {
        uint256 pg = hook.playgroundClaims();
        uint256 nft = hook.nftFwaClaims();
        uint256 supply = fwa.totalSupply();
        uint256 expected = burnOutstanding;
        vm.prank(address(uint160(uint256(keccak256(abi.encode("anyone", flushes))))));
        assertEq(hook.flushBurn(), expected);
        assertEq(supply - fwa.totalSupply(), expected, "flush destroys exactly the deferred amount");
        assertEq(hook.playgroundClaims(), pg);
        assertEq(hook.nftFwaClaims(), nft);
        burnFlushed += expected;
        burnOutstanding = 0;
        ++flushes;
    }

    function wait(uint32 delta) external {
        vm.warp(vm.getBlockTimestamp() + _bound(delta, 0, 1 hours));
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 60
/// forge-config: default.invariant.fail-on-revert = true
contract MadBurnDeferralInvariantTest is MadTestBase {
    MadBurnDeferralHandler internal handler;
    uint256 internal initialSupply;

    function setUp() public override {
        super.setUp();
        _open(0);
        initialSupply = fwa.totalSupply();
        handler = new MadBurnDeferralHandler(hook, router, key, ALICE);
        vm.prank(ALICE);
        fwa.approve(address(router), type(uint256).max);
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = handler.buy.selector;
        selectors[1] = handler.bigBuy.selector;
        selectors[2] = handler.sell.selector;
        selectors[3] = handler.payout.selector;
        selectors[4] = handler.flushBurn.selector;
        selectors[5] = handler.wait.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function invariant_claimsMatchSeparateObligationsAndBurnsAreConserved() public view {
        uint256 claims = manager.balanceOf(address(hook), uint160(FWA));
        assertEq(claims, hook.playgroundClaims() + hook.nftFwaClaims() + hook.burnClaims());
        assertGe(fwa.balanceOf(address(manager)), claims, "every claim is backed by FWA in the manager");
        assertEq(hook.burnClaims(), handler.burnOutstanding());
        assertEq(fwa.burned(), handler.burnedInSwap() + handler.burnFlushed());
        assertEq(fwa.totalSupply() + fwa.burned(), initialSupply + handler.minted());
        assertEq(fwa.balanceOf(hook.receiver()), handler.paid());
        assertEq(hook.playgroundClaims() + handler.paid(), handler.sharesEarned());
        assertEq(hook.nftFwaClaims(), handler.sharesEarned(), "no market: NFT claims only accrue");
        assertEq(fwa.balanceOf(address(hook)), 0, "the hook never keeps loose FWA");
        assertEq(address(rewards).balance, 0);
    }

    function test_burnDeferralHandlerReachesDeferFlushAndSell() public {
        handler.bigBuy(150, 0);
        assertGt(hook.burnClaims(), 0);
        handler.sell(10 ether, 60);
        handler.buy(10 ether, 60);
        handler.payout();
        handler.flushBurn();
        assertEq(hook.burnClaims(), 0);
        handler.flushBurn(); // nothing left: a second flush burns nothing
        handler.bigBuy(300, 300);
        handler.wait(1 hours);
        handler.buy(1 ether, 0); // at rest: at most one unit of rounding dust is burned
        handler.flushBurn();
        assertEq(handler.deferrals(), 2);
        assertGt(handler.burnFlushed(), 0);
        invariant_claimsMatchSeparateObligationsAndBurnsAreConserved();
    }
}

/// @dev Exact-output routes gross the fee up from a net amount. The smallest fee that is at least
/// the scheduled share of everything the trader pays is exactly ceil(rate * gross).
contract MadExactOutputFeeTest is MadTestBase, FeeLog {
    uint256 private constant DEN = 10_000 * 1800;

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_exactOutputRoutesChargeCeilingOfScheduleOnGross(uint96 rawOut, uint16 rawElapsed, bool buyMad)
        public
    {
        _open(_bound(rawElapsed, 0, 2000));
        uint256 out = _bound(rawOut, 1e6, 1000 ether);
        uint256 rate = hook.feeNumerator();
        uint256 fwaBefore = fwa.balanceOf(ALICE);
        uint256 madBefore = token.balanceOf(ALICE);
        vm.recordLogs();
        _swap(buyMad, int256(out));
        (uint256 base, uint256 fee, uint256 pg, uint256 nft, uint256 burned) = _feeCharged(address(hook));
        if (buyMad) {
            assertEq(token.balanceOf(ALICE) - madBefore, out, "exact MAD output");
            assertEq(fwaBefore - fwa.balanceOf(ALICE), base, "fee base is everything the trader paid");
        } else {
            assertEq(fwa.balanceOf(ALICE) - fwaBefore, out, "exact net FWA output survives the fee");
            assertEq(base, out + fee);
        }
        assertEq(fee, Math.mulDiv(base, rate, DEN, Math.Rounding.Ceil), "minimal fee covering the schedule");
        assertEq(pg, base / 200);
        assertEq(nft, pg);
        assertEq(burned, fee - 2 * pg);
        assertEq(hook.burnClaims(), 0, "seeded manager burns in the same swap");
    }

    function test_exactOutputAtRestChargesOnePercentRoundedUp() public {
        _open(1800);
        vm.recordLogs();
        _swap(false, 199); // 199 net FWA out: gross 202 (ceil(199/99) = 3), fee = ceil(2.02)
        (uint256 base, uint256 fee, uint256 pg,, uint256 burned) = _feeCharged(address(hook));
        assertEq(fee, 3);
        assertEq(base, 202);
        assertEq(pg, 1);
        assertEq(burned, 1);
    }
}
