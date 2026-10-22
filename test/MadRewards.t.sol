// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {MadTestBase} from "./Base.t.sol";
import {MadRewards} from "../src/MadRewards.sol";
import {MadHook} from "../src/MadHook.sol";
import {MockNFT, RetryReceiver} from "./mocks/MockNFT.sol";
import {MockFWAV2} from "./mocks/MockFWAV2.sol";
import {MockIMD, MockIntake} from "./mocks/MockIntake.sol";
import {OracleAttestation} from "../src/oracle/OracleAttestation.sol";
import {OracleQuestion} from "../src/oracle/OracleQuestion.sol";

abstract contract MadRewardsFixture is MadTestBase {
    uint256 internal constant SIGNER_KEY = 0x1234;
    MockNFT internal nft;
    MockFWAV2 internal pool;
    MockIntake internal intake;
    MockIMD internal imd;

    function setUp() public virtual override {
        super.setUp();
        nft = new MockNFT();
        pool = new MockFWAV2(nft);
        intake = new MockIntake();
        imd = new MockIMD();
        vm.startPrank(OWNER);
        rewards.setFwaV2(pool);
        rewards.setAcquisitionBounds(0.001 ether, 100);
        rewards.setOracleSettings(intake, bytes32("oracle.request@oracle-1"), imd, 1 ether, vm.addr(SIGNER_KEY));
        vm.stopPrank();
        vm.deal(address(rewards), 2 ether);
        imd.mint(address(rewards), 10 ether);
    }

    function _keep() internal returns (uint256 requestId) {
        requestId = hook.buy();
        pool.fulfill(requestId);
        hook.claim(requestId);
    }

    function _close() internal returns (uint256 round) {
        _keep();
        vm.prank(ALICE);
        token.freeze(BOB);
        (uint64 first,) = token.roundBlocks(token.currentRound());
        vm.roll(uint256(first) + hook.MIN_ROUND_BLOCKS() - 1);
        round = hook.closeRound();
        vm.roll(block.number + 8);
    }

    function _attestation(uint256 round, bytes32 uuid, address winner)
        internal
        view
        returns (OracleAttestation.Attestation memory a)
    {
        (, bytes32 hash) = rewards.questionBody(round);
        (uint64 first, uint64 last) = token.roundBlocks(round);
        address[] memory answers = new address[](1);
        answers[0] = winner;
        a = OracleAttestation.Attestation(
            uuid,
            1,
            hash,
            4,
            abi.encode(answers),
            token.spent(round, ALICE),
            first,
            last,
            bytes32(uint256(7)),
            keccak256("panel"),
            30,
            20,
            20,
            uint64(vm.getBlockTimestamp()),
            uint64(vm.getBlockTimestamp() + 3600)
        );
    }

    function _signature(OracleAttestation.Attestation memory a) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_KEY, rewards.attestationDigest(a));
        return abi.encodePacked(r, s, v);
    }

    function _deliver(bytes32 id, OracleAttestation.Attestation memory a) internal returns (bool) {
        (bool ok,) = intake.deliver(id, a, _signature(a));
        return ok;
    }

    function _winner(uint256 round) internal view returns (address w) {
        (,, w,,,) = rewards.rounds(round);
    }
}

contract MadRewardsTest is MadRewardsFixture {
    function test_buyQuoteBoundsBlackoutAndRefundOverpayment() public {
        pool.setBlackout(true);
        vm.expectRevert(MadRewards.Blackout.selector);
        hook.buy();
        pool.setBlackout(false);
        pool.setDiscount(0.02 ether);
        uint256 before = address(rewards).balance;
        uint256 id = hook.buy();
        assertEq(address(rewards).balance, before - 0.09 ether);
        assertEq(pool.lastPurchaser(), address(rewards));
        assertEq(pool.lastCount(), 1);
        assertEq(pool.lastMaxFee(), 0.101 ether);
        assertEq(pool.lastMinWeight(), 0);
        assertEq(pool.lastSlippage(), 100);
        (address source, bool claimed) = rewards.purchases(id);
        assertEq(source, address(pool));
        assertFalse(claimed);
        vm.deal(address(rewards), 0);
        vm.expectRevert(MadRewards.InsufficientBudget.selector);
        hook.buy();
    }

    function test_buyRedeemsOnlyNeededEthClaims() public {
        vm.deal(address(rewards), 0);
        _market(Q96 * 2);
        vm.deal(address(manager), 0);
        _open(1800);
        _swap(true, -1000 ether);
        uint256 claims = hook.nftEthClaims();
        assertGt(claims, 0.11 ether);
        vm.deal(address(manager), 1000 ether);
        hook.buy();
        assertEq(hook.nftEthClaims(), claims - 0.11 ether);
        assertEq(address(rewards).balance, 0);
        assertEq(hook.playgroundClaims(), 5 ether);
    }

    function test_refundReturnsToBudgetAndOldPoolStillWorksAfterChange() public {
        uint256 id = hook.buy();
        uint256 afterBuy = address(rewards).balance;
        pool.refund(id);
        MockFWAV2 next = new MockFWAV2(new MockNFT());
        vm.prank(OWNER);
        rewards.setFwaV2(next);
        assertEq(rewards.withdrawAcquisitionRefund(address(pool)), 0.1 ether);
        assertEq(address(rewards).balance, afterBuy + 0.1 ether);
        vm.expectRevert();
        rewards.withdrawAcquisitionRefund(address(pool));
        vm.expectRevert(MadRewards.InvalidAcquisition.selector);
        rewards.withdrawAcquisitionRefund(address(next));
    }

    function test_claimWithinWindowOnlyOnceAndUsingOriginalPool() public {
        uint256 id = hook.buy();
        vm.expectRevert(MadRewards.InvalidAcquisition.selector);
        hook.claim(id);
        pool.fulfill(id);
        MockFWAV2 replacement = new MockFWAV2(new MockNFT());
        vm.prank(OWNER);
        rewards.setFwaV2(replacement);
        vm.prank(BOB);
        hook.claim(id);
        assertEq(nft.ownerOf(id), address(rewards));
        assertEq(pool.keepCalls(), 1);
        vm.expectRevert(MadRewards.InvalidAcquisition.selector);
        hook.claim(id);
    }

    function test_lateClaimRejectedAndFailedKeepRetriable() public {
        uint256 id = hook.buy();
        pool.fulfill(id);
        nft.setRejectTransfers(true);
        vm.expectRevert();
        hook.claim(id);
        (, bool claimed) = rewards.purchases(id);
        assertFalse(claimed);
        nft.setRejectTransfers(false);
        hook.claim(id);
        uint256 late = hook.buy();
        pool.fulfill(late);
        vm.warp(block.timestamp + 3600);
        vm.expectRevert(MadRewards.SettlementWindowClosed.selector);
        hook.claim(late);
    }

    function test_closeRequiresLeaderAndNftAssignsOldestKeptOnly() public {
        vm.roll(100 + hook.MIN_ROUND_BLOCKS());
        vm.expectRevert(MadHook.NoRoundReward.selector);
        hook.closeRound();
        uint256 first = hook.buy();
        uint256 second = hook.buy();
        pool.fulfill(second);
        hook.claim(second);
        pool.fulfill(first);
        hook.claim(first);
        vm.expectRevert(MadHook.NoRoundReward.selector);
        hook.closeRound();
        vm.prank(ALICE);
        token.freeze(BOB);
        assertEq(hook.closeRound(), 1);
        (uint256 index,,,,,) = rewards.rounds(1);
        assertEq(index, 1);
        (, uint256 id) = rewards.keptNFTs(index - 1);
        assertEq(id, second);
        vm.expectRevert();
        hook.closeRound();
        vm.roll(block.number + hook.MIN_ROUND_BLOCKS());
        vm.prank(ALICE);
        token.freeze(BOB);
        hook.closeRound();
        (index,,,,,) = rewards.rounds(2);
        assertEq(index, 2);
        (, id) = rewards.keptNFTs(index - 1);
        assertEq(id, first);
        vm.expectRevert(MadRewards.Unauthorized.selector);
        rewards.assignRound(3);
    }

    function test_dustFreezeAndShortRoundCannotCaptureAnNFT() public {
        _keep();
        _keep();
        address victim = makeAddr("victim");
        address sniper = makeAddr("sniper");
        token.transfer(victim, 100);
        token.transfer(sniper, 1);
        vm.prank(sniper);
        token.freeze(victim); // 1 wei: the sniper leads an otherwise empty round
        assertEq(token.leader(1), sniper);
        (uint64 first,) = token.roundBlocks(1);
        vm.roll(uint256(first) + hook.MIN_ROUND_BLOCKS() - 1);
        vm.expectRevert(MadHook.NoRoundReward.selector);
        hook.closeRound(); // long enough, but the leader's spend is below the floor
        vm.prank(ALICE);
        token.freeze(BOB); // 10,000 MAD
        vm.roll(vm.getBlockNumber() - 1);
        vm.expectRevert(MadHook.NoRoundReward.selector);
        hook.closeRound(); // real spend, but the round is one block short
        vm.roll(vm.getBlockNumber() + 1);
        assertEq(hook.closeRound(), 1);
        (uint64 openedAt, uint64 closedAt) = token.roundBlocks(1);
        assertEq(uint256(closedAt) - uint256(openedAt) + 1, hook.MIN_ROUND_BLOCKS());
        (uint256 index,,,,,) = rewards.rounds(1);
        assertEq(index, 1);
        // The next round cannot be ended in its first block by the same trick.
        vm.roll(vm.getBlockNumber() + 1);
        vm.prank(ALICE);
        token.freeze(BOB);
        vm.expectRevert(MadHook.NoRoundReward.selector);
        hook.closeRound();
        assertTrue(rewards.hasUnassignedNFT());
    }

    function test_questionExactBodyLivePriceAndEightConfirmations() public {
        uint256 round = _close();
        vm.roll(block.number - 1);
        vm.expectRevert(MadRewards.TooEarly.selector);
        hook.askWinner(round);
        vm.roll(block.number + 1);
        intake.setPrice(0.7 ether);
        bytes32 id = hook.askWinner(round);
        assertTrue(id != bytes32(0));
        assertEq(intake.lastPaid(), 0.7 ether);
        assertEq(imd.balanceOf(address(rewards)), 9.3 ether);
        assertEq(imd.allowance(address(rewards), address(intake)), 0);
        (bytes memory body, bytes32 hash) = rewards.questionBody(round);
        assertEq(intake.lastBody(), body);
        OracleQuestion.Question memory q = rewards.question(round);
        assertEq(hash, OracleQuestion.hash(q));
        assertEq(q.chainId, 1);
        assertEq(q.answerType, 4);
        assertEq(q.head, 1);
        assertEq(q.fromBlock, 100);
        assertEq(q.toBlock, 100 + hook.MIN_ROUND_BLOCKS() - 1);
        assertFalse(q.panelEvidence);
        assertTrue(_contains(string(body), '"panelSize":30,"quorum":20,"validForSeconds":3600,"evidence":"chain"'));
        assertTrue(_contains(q.question, "Ties: first to reach that total in block/transaction/log order."));
        vm.expectRevert(MadRewards.AskStillLive.selector);
        hook.askWinner(round);
    }

    function test_callbackStoresOnlyAndAwardOnceUnderGasStipend() public {
        uint256 round = _close();
        bytes32 id = hook.askWinner(round);
        OracleAttestation.Attestation memory a = _attestation(round, keccak256("uuid"), CAROL);
        assertTrue(_deliver(id, a));
        assertEq(_winner(round), CAROL);
        assertTrue(rewards.consumed(a.requestId));
        assertEq(nft.ownerOf(1), address(rewards));
        assertFalse(_deliver(id, a));
        assertTrue(hook.award(round));
        assertEq(nft.ownerOf(1), CAROL);
        vm.expectRevert(MadRewards.AlreadyAwarded.selector);
        hook.award(round);
        vm.expectRevert(MadRewards.InvalidRound.selector);
        hook.askWinner(round);
    }

    function test_wrongSenderUnknownHashChainPanelAndValidityRejected() public {
        uint256 round = _close();
        bytes32 id = hook.askWinner(round);
        OracleAttestation.Attestation memory a = _attestation(round, keccak256("uuid"), CAROL);
        bytes memory sig = _signature(a);
        vm.expectRevert(MadRewards.UnknownRequest.selector);
        rewards.onOracleResult(id, a, sig);
        vm.prank(address(intake));
        vm.expectRevert(MadRewards.UnknownRequest.selector);
        rewards.onOracleResult(keccak256("unknown"), a, sig);
        a.questionHash = keccak256("other question");
        assertFalse(_deliver(id, a));
        a = _attestation(round, a.requestId, CAROL);
        a.chainId = 2;
        assertFalse(_deliver(id, a));
        a = _attestation(round, a.requestId, CAROL);
        a.quorum = 19;
        assertFalse(_deliver(id, a));
        a = _attestation(round, a.requestId, CAROL);
        a.agreed = 19;
        assertFalse(_deliver(id, a));
        a = _attestation(round, a.requestId, CAROL);
        a.fromBlock = 99;
        assertFalse(_deliver(id, a));
        a = _attestation(round, a.requestId, CAROL);
        a.expiresAt = a.issuedAt + 3601;
        assertFalse(_deliver(id, a));
        a = _attestation(round, a.requestId, CAROL);
        a.issuedAt--;
        assertFalse(_deliver(id, a));
        a = _attestation(round, a.requestId, CAROL);
        a.issuedAt += 301;
        a.expiresAt += 301;
        assertFalse(_deliver(id, a));
        a = _attestation(round, a.requestId, address(0));
        assertFalse(_deliver(id, a));
        a = _attestation(round, a.requestId, CAROL);
        (bool ok,) = intake.deliver(id, a, hex"1234");
        assertFalse(ok);
        sig = _signature(a);
        a.figure++;
        (ok,) = intake.deliver(id, a, sig);
        assertFalse(ok);
        a = _attestation(round, a.requestId, CAROL);
        vm.warp(block.timestamp + 3601);
        assertFalse(_deliver(id, a));
        assertEq(_winner(round), address(0));
    }

    function test_failureAndUnansweredTimeoutRetryRejectsSupersededResponse() public {
        uint256 round = _close();
        bytes32 id = hook.askWinner(round);
        vm.expectRevert(MadRewards.UnknownRequest.selector);
        rewards.onOracleFailure(id, 1, bytes32("bad"), 0, 0, "");
        assertFalse(intake.fail(id, 0, bytes32("invalid")));
        assertTrue(intake.fail(id, 2, bytes32("disagreed")));
        bytes32 second = hook.askWinner(round);
        assertTrue(second != id);
        assertFalse(_deliver(id, _attestation(round, keccak256("old"), CAROL)));
        vm.warp(block.timestamp + 6 hours - 1);
        vm.expectRevert(MadRewards.AskStillLive.selector);
        hook.askWinner(round);
        vm.warp(block.timestamp + 1);
        bytes32 third = hook.askWinner(round);
        assertFalse(_deliver(second, _attestation(round, keccak256("old2"), CAROL)));
        assertFalse(intake.fail(second, 1, bytes32("late")));
        assertTrue(_deliver(third, _attestation(round, keccak256("new"), CAROL)));
    }

    function test_signedUuidCannotReplayAcrossRounds() public {
        uint256 r1 = _close();
        bytes32 id1 = hook.askWinner(r1);
        bytes32 uuid = keccak256("same uuid");
        assertTrue(_deliver(id1, _attestation(r1, uuid, CAROL)));
        uint256 r2 = _close();
        bytes32 id2 = hook.askWinner(r2);
        assertFalse(_deliver(id2, _attestation(r2, uuid, BOB)));
        assertTrue(_deliver(id2, _attestation(r2, keccak256("fresh uuid"), BOB)));
    }

    function test_fallbackAt72HoursAndLateAnswerCannotChangeBeneficiary() public {
        uint256 round = _close();
        bytes32 id = hook.askWinner(round);
        vm.warp(block.timestamp + 72 hours - 1);
        vm.expectRevert(MadRewards.TooEarly.selector);
        hook.award(round);
        vm.warp(block.timestamp + 1);
        assertFalse(_deliver(id, _attestation(round, keccak256("late"), CAROL)));
        assertTrue(hook.award(round));
        assertEq(nft.ownerOf(1), ALICE);
        assertFalse(_deliver(id, _attestation(round, keccak256("later"), CAROL)));
    }

    function test_rejectedWinnerDeliveryRetriesAndReentrancyCannotDoubleAward() public {
        uint256 round = _close();
        bytes32 id = hook.askWinner(round);
        RetryReceiver winner = new RetryReceiver();
        assertTrue(_deliver(id, _attestation(round, keccak256("uuid"), address(winner))));
        assertFalse(hook.award(round));
        assertEq(nft.ownerOf(1), address(rewards));
        (,,, address locked, bool awarded,) = rewards.rounds(round);
        assertEq(locked, address(winner));
        assertFalse(awarded);
        winner.setReject(false);
        winner.setAttack(address(hook), abi.encodeCall(hook.award, (round)));
        assertTrue(hook.award(round));
        assertEq(nft.ownerOf(1), address(winner));
        assertFalse(winner.reentered());
        vm.expectRevert(MadRewards.AlreadyAwarded.selector);
        hook.award(round);
    }

    function test_fallbackFailedTransferPreservesWinnerForRetry() public {
        uint256 round = _close();
        nft.setRejectTransfers(true);
        vm.warp(block.timestamp + 72 hours);
        assertFalse(hook.award(round));
        assertEq(nft.ownerOf(1), address(rewards));
        nft.setRejectTransfers(false);
        assertTrue(hook.award(round));
        assertEq(nft.ownerOf(1), ALICE);
    }

    function test_budgetAndOwnerRestrictions() public {
        vm.expectRevert(MadRewards.Unauthorized.selector);
        rewards.setFwaV2(pool);
        vm.expectRevert(MadRewards.Unauthorized.selector);
        rewards.setAcquisitionBounds(0, 0);
        vm.expectRevert(MadRewards.Unauthorized.selector);
        rewards.setOracleSettings(intake, bytes32("other"), imd, 0, ALICE);
        vm.expectRevert(MadHook.Unauthorized.selector);
        hook.redeemNftETH(1);
        (bool ok,) =
            address(rewards).call(abi.encodeWithSignature("withdraw(address,address,uint256)", address(imd), OWNER, 1));
        assertFalse(ok);
        uint256 round = _close();
        intake.setPrice(2 ether);
        vm.expectRevert(MadRewards.InsufficientBudget.selector);
        hook.askWinner(round);
    }

    function _contains(string memory haystack, string memory needle) private pure returns (bool) {
        bytes memory h = bytes(haystack);
        bytes memory n = bytes(needle);
        for (uint256 i; i + n.length <= h.length; ++i) {
            bool found = true;
            for (uint256 j; j < n.length; ++j) {
                if (h[i + j] != n[j]) {
                    found = false;
                    break;
                }
            }
            if (found) return true;
        }
        return false;
    }
}
