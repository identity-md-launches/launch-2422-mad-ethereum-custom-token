// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {MadRewardsFixture} from "./MadRewards.t.sol";
import {MadRewards} from "src/MadRewards.sol";
import {OracleAttestation, OracleAttestationConsumer} from "src/oracle/OracleAttestation.sol";
import {IFWAV2} from "src/interfaces/IFWAV2.sol";
import {MockIntake, MockIMD} from "./mocks/MockIntake.sol";
import {MockFWAV2} from "./mocks/MockFWAV2.sol";
import {MockNFT, RetryReceiver} from "./mocks/MockNFT.sol";

contract MadRewardsAdversarialTest is MadRewardsFixture {
    function test_questionBodyParsesAndHashMatchesIndependentCanonicalDocument() public {
        uint256 round = _close();
        (bytes memory body, bytes32 hash) = rewards.questionBody(round);
        string memory json = string(body);
        string memory text = string.concat(
            "Who spent most MAD freezing wallets in round 1 of token ",
            _lowercase(vm.toString(address(token))),
            " on Ethereum, blocks 100 to 100 inclusive? Sum cost in MAD base units from that token's Frozen(address indexed by, address indexed target, uint256 cost, uint64 until) events, grouped by by, ranked highest sum first. Ties: first to reach that total in block/transaction/log order."
        );
        assertEq(vm.parseJsonString(json, ".question"), text);
        assertEq(vm.parseJsonUint(json, ".chainId"), 1);
        assertEq(vm.parseJsonUint(json, ".window.fromBlock"), 100);
        assertEq(vm.parseJsonUint(json, ".window.toBlock"), 100);
        assertEq(vm.parseJsonString(json, ".answerType"), "address[]");
        assertEq(vm.parseJsonUint(json, ".head"), 1);
        assertEq(vm.parseJsonString(json, ".evidence"), "chain");
        assertEq(vm.parseJsonUint(json, ".panelSize"), 30);
        assertEq(vm.parseJsonUint(json, ".quorum"), 20);
        assertEq(vm.parseJsonUint(json, ".validForSeconds"), 3600);
        assertEq(vm.parseJsonKeys(json, ".").length, 10);
        bytes memory canonical = bytes(
            string.concat(
                '{"answerType":"address[]","chainId":1,"head":1,"question":"',
                text,
                '","v":1,"window":{"fromBlock":100,"toBlock":100}}'
            )
        );
        assertEq(hash, keccak256(canonical), "hash must match the protocol document, independent of OracleQuestion");
    }

    function test_callbackFitsStipendWithColdConsumerTokenAndSigner() public {
        uint256 round = _close();
        bytes32 id = hook.askWinner(round);
        OracleAttestation.Attestation memory a = _attestation(round, keccak256("cold uuid"), CAROL);
        bytes memory sig = _signature(a);
        vm.cool(address(rewards));
        vm.cool(address(token));
        vm.cool(vm.addr(SIGNER_KEY));
        (bool ok,) = intake.deliver(id, a, sig);
        assertTrue(ok, "callback must fit the real 200000 gas stipend with cold state");
        assertEq(_winner(round), CAROL);
        assertEq(nft.ownerOf(1), address(rewards), "callback only records the answer");
    }

    /// forge-config: default.fuzz.runs = 256
    function testFuzz_malformedSignedAnswersLeavePendingRequestUsable(uint8 rawCase) public {
        uint256 round = _close();
        bytes32 id = hook.askWinner(round);
        bytes32 uuid = keccak256("malformed then valid");
        OracleAttestation.Attestation memory a = _attestation(round, uuid, CAROL);
        uint256 which = rawCase % 12;
        if (which == 0) a.answerType = 1;
        if (which == 1) a.answer = abi.encode(new address[](0));
        if (which == 2) {
            address[] memory list = new address[](2);
            list[0] = ALICE;
            list[1] = CAROL;
            a.answer = abi.encode(list);
        }
        if (which == 3) a.answer = hex"00";
        if (which == 4) a.answer = abi.encode(type(uint256).max, uint256(1), CAROL);
        if (which == 5) a.panelSize = 29;
        if (which == 6) a.agreed = 31;
        if (which == 7) a.toBlock++;
        if (which == 8) a.expiresAt = a.issuedAt - 1;
        if (which == 9) a.questionHash = bytes32(uint256(a.questionHash) ^ 1);
        if (which == 10) {
            a.issuedAt += 301;
            a.expiresAt += 301;
        }
        if (which == 11) a.chainId = 8453;
        bytes32 beforeState = _requestState(round, id);
        assertFalse(_deliver(id, a), "invalid signed response accepted");
        assertEq(_requestState(round, id), beforeState, "rejected callback mutated custody or request");
        assertFalse(rewards.consumed(uuid));
        assertTrue(_deliver(id, _attestation(round, uuid, CAROL)), "valid retry poisoned by rejected response");
        assertEq(_winner(round), CAROL);
    }

    function test_signatureForAnotherConsumerCannotSetWinner() public {
        uint256 round = _close();
        bytes32 id = hook.askWinner(round);
        OracleAttestation.Attestation memory a = _attestation(round, keccak256("other consumer"), CAROL);
        MadRewards other = new MadRewards(OWNER, rewards.mad());
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_KEY, other.attestationDigest(a));
        (bool ok,) = intake.deliver(id, a, abi.encodePacked(r, s, v));
        assertFalse(ok);
        assertEq(_winner(round), address(0));
        assertTrue(_deliver(id, a));
    }

    function test_intakeRotationDoesNotAuthorizeNewIntakeForOldRequest() public {
        uint256 round = _close();
        bytes32 id = hook.askWinner(round);
        MockIntake replacement = new MockIntake();
        vm.prank(OWNER);
        rewards.setOracleSettings(replacement, bytes32("oracle.request@oracle-2"), imd, 0, vm.addr(SIGNER_KEY));
        OracleAttestation.Attestation memory a = _attestation(round, keccak256("old intake"), CAROL);
        bytes memory sig = _signature(a);
        vm.prank(address(replacement));
        vm.expectRevert(MadRewards.UnknownRequest.selector);
        rewards.onOracleResult(id, a, sig);
        assertTrue(_deliver(id, a), "request retains the intake it paid");
        assertEq(imd.allowance(address(rewards), address(intake)), 0);
        assertEq(imd.allowance(address(rewards), address(replacement)), 0);
    }

    function test_rotatedSignerCannotRewritePendingRequestAndRetryUsesNewSigner() public {
        uint256 round = _close();
        bytes32 id = hook.askWinner(round);
        uint256 newKey = 0x5678;
        vm.prank(OWNER);
        rewards.setOracleSettings(intake, bytes32("oracle.request@oracle-1"), imd, 1 ether, vm.addr(newKey));
        OracleAttestation.Attestation memory a = _attestation(round, keccak256("rotated"), CAROL);
        assertFalse(_deliver(id, a));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(newKey, rewards.attestationDigest(a));
        (bool ok,) = intake.deliver(id, a, abi.encodePacked(r, s, v));
        assertFalse(ok);
        assertTrue(intake.fail(id, 1, bytes32("body_refused")));
        bytes32 fresh = hook.askWinner(round);
        a = _attestation(round, keccak256("fresh key request"), CAROL);
        (v, r, s) = vm.sign(newKey, rewards.attestationDigest(a));
        (ok,) = intake.deliver(fresh, a, abi.encodePacked(r, s, v));
        assertTrue(ok);
        assertEq(_winner(round), CAROL);
    }

    function test_failedRetryAtPriceCeilingLeavesOriginalRequestActive() public {
        uint256 round = _close();
        bytes32 id = hook.askWinner(round);
        vm.warp(block.timestamp + 6 hours);
        bytes32 beforeState = _requestState(round, id);
        intake.setPrice(1 ether + 1);
        vm.expectRevert(MadRewards.InsufficientBudget.selector);
        hook.askWinner(round);
        assertEq(_requestState(round, id), beforeState);
        assertTrue(_deliver(id, _attestation(round, keccak256("late but not superseded"), CAROL)));
    }

    function test_exactFallbackBoundaryInvalidatesAskBeforeAnyAwardAttempt() public {
        uint256 round = _close();
        bytes32 id = hook.askWinner(round);
        (, uint64 closedAt,,,,) = rewards.rounds(round);
        vm.warp(uint256(closedAt) + 72 hours);
        assertFalse(_deliver(id, _attestation(round, keccak256("boundary"), CAROL)));
        vm.expectRevert(MadRewards.InvalidRound.selector);
        hook.askWinner(round);
        assertTrue(hook.award(round));
        assertEq(nft.ownerOf(1), ALICE);
    }

    function test_validWinnerBeforeFallbackRemainsWinnerAfterDeadline() public {
        uint256 round = _close();
        bytes32 id = hook.askWinner(round);
        assertTrue(_deliver(id, _attestation(round, keccak256("timely"), CAROL)));
        vm.warp(block.timestamp + 73 hours);
        assertTrue(hook.award(round));
        assertEq(nft.ownerOf(1), CAROL);
    }

    function test_zeroLiveQuoteCannotSpendBudget() public {
        pool.setQuote(0, 0);
        uint256 budget = rewards.nftBudget();
        vm.expectRevert(MadRewards.InsufficientBudget.selector);
        hook.buy();
        assertEq(rewards.nftBudget(), budget);
        assertEq(pool.nonce(), 0);
    }

    function test_invalidAcquireArrayRollsBackPaymentAndCanRetry() public {
        uint256 beforeBalance = address(rewards).balance;
        uint256[] memory bad = new uint256[](0);
        vm.mockCall(address(pool), abi.encodeWithSelector(IFWAV2.acquire.selector), abi.encode(bad));
        vm.expectRevert(MadRewards.InvalidAcquisition.selector);
        hook.buy();
        assertEq(address(rewards).balance, beforeBalance);
        bad = new uint256[](2);
        bad[0] = 1;
        bad[1] = 2;
        vm.mockCall(address(pool), abi.encodeWithSelector(IFWAV2.acquire.selector), abi.encode(bad));
        vm.expectRevert(MadRewards.InvalidAcquisition.selector);
        hook.buy();
        assertEq(address(rewards).balance, beforeBalance);
        vm.clearMockedCalls();
        assertEq(hook.buy(), 1);
    }

    /// forge-config: default.fuzz.runs = 256
    function testFuzz_malformedAcquisitionOrListingCannotEnterQueue(uint8 rawCase) public {
        uint256 id = hook.buy();
        pool.fulfill(id);
        IFWAV2.Acquisition memory a = pool.acquisitions(id);
        IFWAV2.Listing memory l = pool.listings(id);
        uint256 which = rawCase % 7;
        if (which == 0) a.purchaser = ALICE;
        if (which == 1) a.listingId = 0;
        if (which == 2) a.status = 5;
        if (which == 3) l.purchaser = ALICE;
        if (which == 4) l.status = 4;
        if (which == 5) l.collection = address(0);
        if (which == 6) l.tokenId = id + 1;
        vm.mockCall(address(pool), abi.encodeCall(pool.acquisitions, (id)), abi.encode(a));
        vm.mockCall(address(pool), abi.encodeCall(pool.listings, (id)), abi.encode(l));
        vm.expectRevert();
        hook.claim(id);
        (, bool claimed) = rewards.purchases(id);
        assertFalse(claimed);
        assertFalse(rewards.hasUnassignedNFT());
        assertEq(nft.ownerOf(id), address(pool));
        vm.clearMockedCalls();
        hook.claim(id);
        assertEq(nft.ownerOf(id), address(rewards));
        assertTrue(rewards.hasUnassignedNFT());
    }

    function test_keepReturningWithoutDeliveryCannotCreatePhantomNFT() public {
        uint256 id = hook.buy();
        pool.fulfill(id);
        vm.mockCall(address(pool), abi.encodeCall(pool.keepNFT, (id)), "");
        vm.expectRevert(MadRewards.InvalidAcquisition.selector);
        hook.claim(id);
        (, bool claimed) = rewards.purchases(id);
        assertFalse(claimed);
        assertFalse(rewards.recordedNFT(keccak256(abi.encode(address(nft), id))));
        vm.clearMockedCalls();
        hook.claim(id);
        assertEq(nft.ownerOf(id), address(rewards));
    }

    function test_liveSettlementWindowAndExactBoundary() public {
        uint256 id = hook.buy();
        pool.fulfill(id);
        vm.mockCall(address(pool), abi.encodeCall(pool.settlementWindow, ()), abi.encode(uint256(60)));
        vm.warp(block.timestamp + 60);
        vm.expectRevert(MadRewards.SettlementWindowClosed.selector);
        hook.claim(id);
        (, bool claimed) = rewards.purchases(id);
        assertFalse(claimed);
        vm.mockCall(address(pool), abi.encodeCall(pool.settlementWindow, ()), abi.encode(uint256(61)));
        hook.claim(id);
        assertEq(nft.ownerOf(id), address(rewards));
    }

    function test_unsolicitedNFTCannotBecomeRoundReward() public {
        nft.mint(ALICE, 100);
        vm.prank(ALICE);
        vm.expectRevert(MadRewards.InvalidAcquisition.selector);
        nft.safeTransferFrom(ALICE, address(rewards), 100);
        assertEq(nft.ownerOf(100), ALICE);
        assertFalse(rewards.hasUnassignedNFT());
        vm.expectRevert(MadRewards.InvalidAcquisition.selector);
        rewards.onERC721Received(ALICE, ALICE, 100, "");
    }

    function test_differentRequestCannotEnqueueAnAlreadyHeldNFT() public {
        uint256 first = _keep();
        uint256 second = hook.buy();
        IFWAV2.Acquisition memory a = pool.acquisitions(first);
        IFWAV2.Listing memory l = pool.listings(first);
        l.status = 2;
        vm.mockCall(address(pool), abi.encodeCall(pool.acquisitions, (second)), abi.encode(a));
        vm.mockCall(address(pool), abi.encodeCall(pool.listings, (first)), abi.encode(l));
        vm.expectRevert(MadRewards.InvalidAcquisition.selector);
        hook.claim(second);
        (, bool claimed) = rewards.purchases(second);
        assertFalse(claimed);
        assertEq(pool.keepCalls(), 1);
        assertEq(nft.ownerOf(first), address(rewards));
        vm.clearMockedCalls();
        pool.fulfill(second);
        hook.claim(second);
        assertEq(pool.keepCalls(), 2);
    }

    function test_nftReceiverCannotReenterAcquisitionDuringAward() public {
        uint256 round = _close();
        bytes32 id = hook.askWinner(round);
        RetryReceiver winner = new RetryReceiver();
        winner.setReject(false);
        winner.setAttack(address(hook), abi.encodeCall(hook.buy, ()));
        assertTrue(_deliver(id, _attestation(round, keccak256("cross-entry reentrancy"), address(winner))));
        uint256 budget = rewards.nftBudget();
        uint256 purchases = pool.nonce();
        assertTrue(hook.award(round));
        assertFalse(winner.reentered());
        assertEq(rewards.nftBudget(), budget);
        assertEq(pool.nonce(), purchases);
        assertEq(nft.ownerOf(1), address(winner));
        assertEq(hook.buy(), purchases + 1, "guard must be released after the award");
    }

    function test_sameNFTCanBePurchasedAgainWithoutReopeningOldRound() public {
        uint256 r1 = _close();
        bytes32 id1 = hook.askWinner(r1);
        assertTrue(_deliver(id1, _attestation(r1, keccak256("first ownership"), CAROL)));
        assertTrue(hook.award(r1));
        vm.prank(CAROL);
        nft.transferFrom(CAROL, address(pool), 1);
        uint256 purchase2 = hook.buy();
        pool.fulfillExisting(purchase2, 1);
        hook.claim(purchase2);
        vm.prank(ALICE);
        token.freeze(BOB);
        uint256 r2 = hook.closeRound();
        (uint256 index,,,,,) = rewards.rounds(r2);
        assertEq(index, 2);
        assertEq(nft.ownerOf(1), address(rewards));
        vm.roll(block.number + 8);
        bytes32 id2 = hook.askWinner(r2);
        assertTrue(_deliver(id2, _attestation(r2, keccak256("second ownership"), BOB)));
        assertTrue(hook.award(r2));
        assertEq(nft.ownerOf(1), BOB);
        vm.expectRevert(MadRewards.AlreadyAwarded.selector);
        hook.award(r1);
    }

    function _requestState(uint256 round, bytes32 id) internal view returns (bytes32) {
        (uint256 index, uint64 closedAt, address winner, address beneficiary, bool awarded, bytes32 live) =
            rewards.rounds(round);
        (uint256 pendingRound, bytes32 hash, address source, address signer, uint64 askedAt, bool active) =
            rewards.pending(id);
        return keccak256(
            abi.encode(
                index,
                closedAt,
                winner,
                beneficiary,
                awarded,
                live,
                pendingRound,
                hash,
                source,
                signer,
                askedAt,
                active,
                address(rewards).balance,
                imd.balanceOf(address(rewards)),
                nft.ownerOf(1)
            )
        );
    }

    function _lowercase(string memory value) private pure returns (string memory) {
        bytes memory b = bytes(value);
        for (uint256 i; i < b.length; ++i) {
            if (b[i] >= "A" && b[i] <= "F") b[i] = bytes1(uint8(b[i]) + 32);
        }
        return string(b);
    }
}
