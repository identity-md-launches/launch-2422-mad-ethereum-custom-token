// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {MadTestBase} from "./Base.t.sol";
import {MadToken} from "../src/MadToken.sol";
import {IMadToken} from "../src/interfaces/IMadToken.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";

contract SpoofBinding {
    address public launchFactory;
    IMadToken public mad;
    bool public bindingActive = true;

    constructor(address factory_, IMadToken token_) {
        launchFactory = factory_;
        mad = token_;
    }

    function bind() external {
        mad.bindHook();
    }
}

contract MadTokenTest is MadTestBase {
    MadToken private unbound;

    function setUp() public override {
        super.setUp();
        unbound = new MadToken(); // next transaction's transient capability must be gone
    }

    function test_supplyMetadataAndLaunchTransfers() public {
        assertEq(token.totalSupply(), 1_000_000_000 ether);
        assertEq(token.name(), "Mutually Assured Destruction");
        assertEq(token.symbol(), "MAD");
        assertEq(token.decimals(), 18);
        assertEq(token.hook(), address(hook));
        uint256 beforeSupply = token.totalSupply();
        uint256 before = token.balanceOf(BOB);
        vm.prank(ALICE);
        token.transfer(BOB, 123);
        assertEq(token.balanceOf(BOB), before + 123);
        token.transfer(address(router), 789);
        vm.prank(address(router));
        token.transfer(address(manager), 789);
        assertEq(token.totalSupply(), beforeSupply);
    }

    function test_freezeCostBurnRemainderAndEvent() public {
        address tiny = makeAddr("tiny");
        token.transfer(tiny, 301);
        uint256 held = token.balanceOf(ALICE);
        uint256 supply = token.totalSupply();
        vm.expectEmit(true, true, false, true, address(token));
        emit MadToken.Frozen(ALICE, tiny, 3, uint64(block.timestamp + 24 hours));
        vm.prank(ALICE);
        token.freeze(tiny);
        assertEq(token.balanceOf(ALICE), held - 3);
        assertEq(token.balanceOf(tiny), 303);
        assertEq(token.totalSupply(), supply - 1);
        assertEq(token.spent(1, ALICE), 3);
        assertEq(token.leader(1), ALICE);
    }

    function test_zeroSelfContractsAndNoFundsRejected() public {
        vm.startPrank(ALICE);
        vm.expectRevert(MadToken.InvalidTarget.selector);
        token.freeze(address(0));
        vm.expectRevert(MadToken.InvalidTarget.selector);
        token.freeze(ALICE);
        vm.expectRevert(MadToken.InvalidTarget.selector);
        token.freeze(address(router));
        vm.expectRevert(MadToken.ZeroCost.selector);
        token.freeze(makeAddr("empty"));
        vm.stopPrank();
        vm.prank(makeAddr("poor"));
        vm.expectRevert();
        token.freeze(ALICE);
        assertEq(token.frozenUntil(ALICE), 0);
    }

    function test_frozenCannotTransferTransferFromSellOrAddLiquidity() public {
        _open(1800);
        vm.prank(BOB);
        token.freeze(ALICE);
        vm.prank(ALICE);
        vm.expectRevert();
        token.transfer(BOB, 1);
        vm.prank(ALICE);
        token.approve(CAROL, type(uint256).max);
        vm.prank(CAROL);
        vm.expectRevert();
        token.transferFrom(ALICE, CAROL, 1);
        vm.expectRevert();
        _swap(false, -1 ether);
        vm.prank(ALICE);
        vm.expectRevert();
        router.modify(key, ModifyLiquidityParams(-600, 600, 1 ether, bytes32(0)));
        // Receiving, including buying, is permitted.
        uint256 before = token.balanceOf(ALICE);
        _swap(true, -1 ether);
        assertGt(token.balanceOf(ALICE), before);
        token.transfer(ALICE, 1);
        vm.warp(token.frozenUntil(ALICE));
        vm.prank(ALICE);
        token.transfer(BOB, 1);
    }

    function test_frozenFreezerCanPayButNoGeneralExemption() public {
        vm.prank(BOB);
        token.freeze(ALICE);
        uint256 cost = token.freezeCost(BOB);
        uint256 held = token.balanceOf(ALICE);
        vm.prank(ALICE);
        token.freeze(BOB);
        assertEq(token.balanceOf(ALICE), held - cost);
        vm.prank(ALICE);
        vm.expectRevert();
        token.transfer(BOB, 1);
    }

    function test_frozenDebitsAlsoFailOnAnUnrelatedPool() public {
        PoolKey memory other = PoolKey(key.currency0, key.currency1, 3000, 60, IHooks(address(0)));
        manager.initialize(other, Q96);
        router.modify(other, ModifyLiquidityParams(-887220, 887220, 1_000_000 ether, bytes32(0)));
        vm.prank(BOB);
        token.freeze(ALICE);
        bool zeroForOne = Currency.unwrap(other.currency0) == address(token);
        vm.prank(ALICE);
        vm.expectRevert();
        router.swap(
            other,
            SwapParams(zeroForOne, -1 ether, zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1)
        );
        vm.prank(ALICE);
        vm.expectRevert();
        router.modify(other, ModifyLiquidityParams(-600, 600, 1 ether, bytes32(0)));
    }

    function test_repeatedFreezeResetsNotAdds() public {
        vm.prank(ALICE);
        token.freeze(BOB);
        uint64 original = token.frozenUntil(BOB);
        vm.warp(block.timestamp + 100);
        vm.prank(CAROL);
        token.freeze(BOB);
        assertEq(token.frozenUntil(BOB), original + 100);
    }

    function test_7702ExactDesignationOnly() public {
        address delegated = makeAddr("delegated");
        vm.etch(delegated, abi.encodePacked(hex"ef0100", address(router)));
        token.transfer(delegated, 20_000 ether);
        assertTrue(token.isWallet(delegated));
        vm.prank(ALICE);
        token.freeze(delegated);
        vm.prank(delegated);
        vm.expectRevert();
        token.transfer(BOB, 1);
        vm.prank(delegated);
        token.freeze(BOB);
        address wrong = makeAddr("wrong-prefix");
        vm.etch(wrong, abi.encodePacked(hex"600000", address(router)));
        token.transfer(wrong, 1000 ether);
        vm.prank(ALICE);
        vm.expectRevert(MadToken.InvalidTarget.selector);
        token.freeze(wrong);
        vm.etch(wrong, abi.encodePacked(hex"600000", address(router), hex"00"));
        vm.prank(ALICE);
        vm.expectRevert(MadToken.InvalidTarget.selector);
        token.freeze(wrong);
    }

    function test_frozenCounterfactualAddressStaysFrozenAfterDeployingCode() public {
        address counterfactual = makeAddr("counterfactual");
        token.transfer(counterfactual, 1000 ether);
        vm.prank(BOB);
        token.freeze(counterfactual);
        uint64 until = token.frozenUntil(counterfactual);
        vm.prank(counterfactual);
        vm.expectRevert(abi.encodeWithSelector(MadToken.WalletFrozen.selector, counterfactual, until));
        token.transfer(CAROL, 1);
        vm.etch(counterfactual, address(router).code); // the CREATE2 deployment lands inside the window
        assertFalse(token.isWallet(counterfactual));
        vm.prank(counterfactual);
        vm.expectRevert(abi.encodeWithSelector(MadToken.WalletFrozen.selector, counterfactual, until));
        token.transfer(CAROL, 1);
        vm.prank(ALICE);
        vm.expectRevert(MadToken.InvalidTarget.selector);
        token.freeze(counterfactual); // a contract can never be frozen again
        vm.warp(until);
        vm.prank(counterfactual);
        token.transfer(CAROL, 1);
    }

    function test_tiesAndRoundBoundary() public {
        address t1 = makeAddr("t1");
        address t2 = makeAddr("t2");
        token.transfer(t1, 10_000);
        token.transfer(t2, 10_000);
        vm.prank(ALICE);
        token.freeze(t1);
        vm.prank(BOB);
        token.freeze(t2);
        assertEq(token.spent(1, ALICE), 100);
        assertEq(token.spent(1, BOB), 100);
        assertEq(token.leader(1), ALICE);
        vm.prank(BOB);
        token.freeze(t2);
        assertEq(token.leader(1), BOB);
        vm.prank(ALICE);
        token.freeze(t1);
        assertEq(token.spent(1, ALICE), token.spent(1, BOB));
        assertEq(token.leader(1), BOB);
        vm.expectRevert(MadToken.UnauthorizedHook.selector);
        token.closeRound();
        vm.prank(address(hook));
        assertEq(token.closeRound(), 1);
        (uint64 first, uint64 last) = token.roundBlocks(1);
        assertEq(first, 100);
        assertEq(last, block.number);
        (first, last) = token.roundBlocks(2);
        assertEq(first, block.number + 1);
        assertEq(last, 0);
        vm.prank(ALICE);
        vm.expectRevert(MadToken.RoundClosedForBlock.selector);
        token.freeze(BOB);
        vm.prank(address(hook));
        vm.expectRevert(MadToken.RoundClosedForBlock.selector);
        token.closeRound();
        vm.roll(block.number + 1);
        vm.prank(ALICE);
        token.freeze(BOB);
        assertEq(token.currentRound(), 2);
        assertEq(token.leader(2), ALICE);
    }

    function test_arbitraryBindAndRebindRejectedIncludingSameBlockLaterTransaction() public {
        vm.expectRevert(MadToken.InvalidBinding.selector);
        token.bindHook();
        SpoofBinding fake = new SpoofBinding(address(this), IMadToken(address(unbound)));
        assertEq(block.number, 100);
        vm.expectRevert(MadToken.InvalidBinding.selector);
        fake.bind();
    }

    function testFuzz_freezeConservesAndTracks(uint96 raw) public {
        uint256 targetBalance = bound(uint256(raw), 100, 100_000 ether);
        address target = makeAddr("fuzz-target");
        token.transfer(target, targetBalance);
        uint256 cost = targetBalance / 100;
        uint256 supply = token.totalSupply();
        uint256 payer = token.balanceOf(ALICE);
        vm.prank(ALICE);
        token.freeze(target);
        assertEq(token.balanceOf(target), targetBalance + cost - cost / 2);
        assertEq(token.balanceOf(ALICE), payer - cost);
        assertEq(token.totalSupply(), supply - cost / 2);
        assertEq(token.spent(1, ALICE), cost);
    }
}
