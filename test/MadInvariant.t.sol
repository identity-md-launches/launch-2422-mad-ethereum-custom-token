// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {Test} from "forge-std/Test.sol";
import {MadTestBase} from "./Base.t.sol";
import {MadHook} from "../src/MadHook.sol";
import {MadToken} from "../src/MadToken.sol";
import {TestRouter} from "./mocks/TestRouter.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

contract MadHandler is Test {
    MadHook public hook;
    MadToken public token;
    TestRouter public router;
    PoolKey private key;
    address private alice;
    address private bob;
    uint256 public earnedPlayground;
    uint256 public paidPlayground;
    uint256 public burnedMad;

    constructor(MadHook h, MadToken t, TestRouter r, PoolKey memory k, address a, address b) {
        hook = h;
        token = t;
        router = r;
        key = k;
        alice = a;
        bob = b;
    }

    function swap(uint96 amount, bool buyMad, bool exactInput, uint16 advance) external {
        uint256 n = _bound(amount, 10_000, 100 ether);
        vm.warp(vm.getBlockTimestamp() + _bound(advance, 0, 600));
        bool z = buyMad == (Currency.unwrap(key.currency0) == hook.FWA());
        uint256 beforeClaims = hook.playgroundClaims();
        vm.prank(alice);
        try router.swap(
            key,
            SwapParams(
                z, exactInput ? -int256(n) : int256(n), z ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            )
        ) {
            earnedPlayground += hook.playgroundClaims() - beforeClaims;
        } catch {}
    }

    function freeze(bool fromAlice) external {
        uint256 beforeSupply = token.totalSupply();
        vm.prank(fromAlice ? alice : bob);
        try token.freeze(fromAlice ? bob : alice) {
            burnedMad += beforeSupply - token.totalSupply();
        } catch {}
    }

    function payout() external {
        paidPlayground += hook.payout();
    }
}

contract MadInvariantTest is MadTestBase {
    MadHandler private handler;
    uint256 private initialFwa;

    function setUp() public override {
        super.setUp();
        _open(0);
        initialFwa = fwa.totalSupply();
        handler = new MadHandler(hook, token, router, key, ALICE, BOB);
        targetContract(address(handler));
    }

    function invariant_claimBudgetsNeverMixOrDoublePay() public view {
        assertEq(
            manager.balanceOf(address(hook), uint160(FWA)),
            hook.playgroundClaims() + hook.nftFwaClaims() + hook.burnClaims()
        );
        assertEq(hook.burnClaims(), 0, "the seeded manager always covers these burns in the same swap");
        assertEq(handler.earnedPlayground(), hook.playgroundClaims() + handler.paidPlayground());
        assertEq(handler.earnedPlayground(), hook.nftFwaClaims());
        assertEq(fwa.balanceOf(hook.receiver()), handler.paidPlayground());
    }

    function invariant_supplyAndBurnConservation() public view {
        assertEq(fwa.totalSupply() + fwa.burned(), initialFwa);
        assertEq(token.totalSupply() + handler.burnedMad(), token.INITIAL_SUPPLY());
        assertEq(fwa.balanceOf(address(hook)), 0);
        assertEq(token.balanceOf(address(hook)), 0);
    }
}
