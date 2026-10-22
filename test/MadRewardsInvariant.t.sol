// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {MadRewardsFixture} from "./MadRewards.t.sol";
import {MadHook} from "src/MadHook.sol";
import {MadToken} from "src/MadToken.sol";
import {MadRewards} from "src/MadRewards.sol";
import {OracleAttestation} from "src/oracle/OracleAttestation.sol";
import {MockFWAV2} from "./mocks/MockFWAV2.sol";
import {MockNFT, RetryReceiver} from "./mocks/MockNFT.sol";
import {MockIntake, MockIMD} from "./mocks/MockIntake.sol";

/// @dev Ghost totals come from the amounts sent and the selected mock outcomes, not changes in
/// the balances under test. Invalid operations are asserted to fail, never swallowed in a catch.
contract MadRewardsLifecycleHandler is Test {
    uint256 private constant SIGNER_KEY = 0x1234;
    MadHook public immutable hook;
    MadToken public immutable token;
    MadRewards public immutable rewards;
    MockFWAV2 public immutable pool;
    MockNFT public immutable nft;
    MockIntake public immutable intake;
    MockIMD public immutable imd;
    RetryReceiver public immutable receiver;
    address[2] public freezers;
    uint256 public immutable initialEth;
    uint256 public immutable initialImd;
    uint256 public donatedEth;
    uint256 public donatedImd;
    uint256 public acquisitionSpent;
    uint256 public refundsPaid;
    uint256 public refundsCredited;
    uint256 public oracleSpent;
    uint256 public closedCount;
    uint256 public deliveredCount;
    uint256 public awardedCount;
    uint256 public failedAwards;
    uint256 public failedAsks;
    uint256 public retryCount;
    uint256 public uuidNonce;
    uint256[] public requestIds;
    uint256[] public keptIds;
    mapping(uint256 => uint8) public status; // 1 pending, 2 fulfilled, 3 kept, 4 refunded
    mapping(uint256 => uint256) public escrow;
    mapping(uint256 => uint256) public allocatedAt;
    mapping(uint256 => address) public fallbackWinner;
    mapping(uint256 => address) public answerWinner;
    mapping(uint256 => address) public lockedWinner;
    mapping(uint256 => bool) public wasAwarded;
    mapping(uint256 => uint64) public closedAt;
    mapping(uint256 => uint64) public lastBlock;
    mapping(uint256 => bytes32) public liveAsk;
    mapping(uint256 => uint64) public askedAt;
    mapping(uint256 => bytes32) public successfulUuid;

    constructor(MadHook h, MadToken t, MockFWAV2 p, MockNFT n, MockIntake i, MockIMD asset, address[2] memory actors) {
        hook = h;
        token = t;
        rewards = h.rewards();
        pool = p;
        nft = n;
        intake = i;
        imd = asset;
        freezers = actors;
        receiver = new RetryReceiver();
        initialEth = address(rewards).balance;
        initialImd = asset.balanceOf(address(rewards));
    }

    function donate(uint96 ethSeed, uint96 imdSeed) external {
        uint256 ethAmount = _bound(ethSeed, 0, 0.2 ether);
        uint256 imdAmount = _bound(imdSeed, 0, 2 ether);
        (bool ok,) = address(rewards).call{value: ethAmount}("");
        assertTrue(ok);
        assertTrue(imd.transfer(address(rewards), imdAmount));
        donatedEth += ethAmount;
        donatedImd += imdAmount;
    }

    function buy(uint96 feeSeed, uint96 vrfSeed, uint96 discountSeed, bool blackout) external {
        uint256 fee = _bound(feeSeed, 1e14, 0.02 ether);
        uint256 vrf = _bound(vrfSeed, 0, 0.001 ether);
        uint256 discount = _bound(discountSeed, 0, fee - 1);
        pool.setQuote(fee, vrf);
        pool.setDiscount(discount);
        pool.setBlackout(blackout);
        bool expected = !blackout && initialEth + donatedEth + refundsPaid >= acquisitionSpent + fee + vrf;
        (bool ok, bytes memory data) = address(hook).call(abi.encodeCall(hook.buy, ()));
        assertEq(ok, expected, "buy must use only funded ETH and respect blackout");
        if (!ok) return;
        uint256 id = abi.decode(data, (uint256));
        assertEq(status[id], 0, "unique purchase");
        requestIds.push(id);
        status[id] = 1;
        escrow[id] = fee - discount;
        acquisitionSpent += fee + vrf - discount;
    }

    function resolveDraw(uint256 seed, bool refund) external {
        if (requestIds.length == 0) return;
        uint256 id = requestIds[seed % requestIds.length];
        if (status[id] != 1) return;
        if (refund) {
            pool.refund(id);
            refundsCredited += escrow[id];
            status[id] = 4;
        } else {
            pool.fulfill(id);
            status[id] = 2;
            allocatedAt[id] = vm.getBlockTimestamp();
        }
    }

    function withdrawRefund() external {
        uint256 amount = refundsCredited - refundsPaid;
        (bool ok, bytes memory data) =
            address(rewards).call(abi.encodeCall(rewards.withdrawAcquisitionRefund, (address(pool))));
        assertEq(ok, amount > 0, "only existing refund credit can be withdrawn");
        if (ok) {
            assertEq(abi.decode(data, (uint256)), amount);
            refundsPaid += amount;
        }
    }

    function claim(uint256 seed) external {
        if (requestIds.length == 0) return;
        uint256 id = requestIds[seed % requestIds.length];
        bool expected = status[id] == 2 && vm.getBlockTimestamp() < allocatedAt[id] + 3600;
        (bool ok,) = address(hook).call(abi.encodeCall(hook.claim, (id)));
        assertEq(ok, expected, "keep only owned allocations within settlement window, once");
        if (ok) {
            status[id] = 3;
            keptIds.push(id);
        }
    }

    function freezeAndClose(bool bob) external {
        // The next round cannot have freezes or close in the remainder of the old round's block.
        (uint64 first,) = token.roundBlocks(token.currentRound());
        if (vm.getBlockNumber() < first) return;
        if (closedCount >= keptIds.length) {
            vm.expectRevert(MadHook.NoRoundReward.selector);
            hook.closeRound();
            return;
        }
        address freezer = freezers[bob ? 1 : 0];
        address target = freezers[bob ? 0 : 1];
        if (token.balanceOf(freezer) < token.freezeCost(target)) return;
        vm.prank(freezer);
        token.freeze(target);
        // The revised hook also requires MIN_ROUND_BLOCKS and MIN_LEADER_SPEND, which the brief does
        // not specify (reported in .imd-findings.json). Satisfy them without asserting they are right.
        uint256 earliest = uint256(first) + hook.MIN_ROUND_BLOCKS() - 1;
        if (vm.getBlockNumber() < earliest) vm.roll(earliest);
        uint256 r = hook.closeRound();
        assertEq(r, ++closedCount);
        fallbackWinner[r] = freezer;
        closedAt[r] = uint64(vm.getBlockTimestamp());
        lastBlock[r] = uint64(vm.getBlockNumber());
    }

    function ask(uint256 seed, uint96 priceSeed) external {
        if (closedCount == 0) return;
        uint256 r = 1 + seed % closedCount;
        uint256 price = _bound(priceSeed, 1, 1.2 ether);
        intake.setPrice(price);
        bool active = liveAsk[r] != bytes32(0);
        bool expected = answerWinner[r] == address(0) && lockedWinner[r] == address(0) && !wasAwarded[r]
            && vm.getBlockTimestamp() < uint256(closedAt[r]) + 72 hours
            && vm.getBlockNumber() >= uint256(lastBlock[r]) + 8
            && (!active || vm.getBlockTimestamp() >= uint256(askedAt[r]) + 6 hours) && price <= 1 ether
            && initialImd + donatedImd >= oracleSpent + price;
        (bool ok, bytes memory data) = address(hook).call(abi.encodeCall(hook.askWinner, (r)));
        assertEq(ok, expected, "ask timing, existing state and donated IMD budget");
        if (!ok) return;
        if (active) {
            (,,,,, bool oldActive) = rewards.pending(liveAsk[r]);
            assertFalse(oldActive);
            ++retryCount;
        }
        liveAsk[r] = abi.decode(data, (bytes32));
        askedAt[r] = uint64(vm.getBlockTimestamp());
        oracleSpent += price;
    }

    function failure(uint256 seed, bool refused) external {
        if (closedCount == 0) return;
        uint256 r = 1 + seed % closedCount;
        bytes32 id = liveAsk[r];
        if (id == bytes32(0)) return;
        assertTrue(intake.fail(id, refused ? 1 : 2, bytes32("no_result")));
        liveAsk[r] = bytes32(0);
        ++failedAsks;
    }

    function answer(uint256 seed, bool useContract, bool corrupt) external {
        if (closedCount == 0) return;
        uint256 r = 1 + seed % closedCount;
        bytes32 id = liveAsk[r];
        if (id == bytes32(0)) return;
        address winner = useContract ? address(receiver) : freezers[0];
        (, bytes32 hash) = rewards.questionBody(r);
        (uint64 first, uint64 last) = token.roundBlocks(r);
        address[] memory list = new address[](1);
        list[0] = winner;
        bytes32 uuid = keccak256(abi.encode("lifecycle UUID", ++uuidNonce));
        OracleAttestation.Attestation memory a = OracleAttestation.Attestation(
            uuid,
            1,
            corrupt ? bytes32(uint256(hash) ^ 1) : hash,
            4,
            abi.encode(list),
            0,
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
        (uint8 v, bytes32 rr, bytes32 s) = vm.sign(SIGNER_KEY, rewards.attestationDigest(a));
        (bool ok,) = intake.deliver(id, a, abi.encodePacked(rr, s, v));
        bool expected = !corrupt && vm.getBlockTimestamp() < uint256(closedAt[r]) + 72 hours;
        assertEq(ok, expected, "only valid timely response may settle live ask");
        if (ok) {
            answerWinner[r] = winner;
            successfulUuid[r] = uuid;
            liveAsk[r] = bytes32(0);
            ++deliveredCount;
        } else {
            assertFalse(rewards.consumed(uuid));
        }
    }

    function award(uint256 seed, bool reject) external {
        if (closedCount == 0) return;
        uint256 r = 1 + seed % closedCount;
        receiver.setReject(reject);
        bool eligible = !wasAwarded[r]
            && (answerWinner[r] != address(0) || vm.getBlockTimestamp() >= uint256(closedAt[r]) + 72 hours);
        address beneficiary = lockedWinner[r];
        if (beneficiary == address(0)) {
            beneficiary = answerWinner[r] == address(0) ? fallbackWinner[r] : answerWinner[r];
        }
        (bool ok, bytes memory data) = address(hook).call(abi.encodeCall(hook.award, (r)));
        assertEq(ok, eligible, "only eligible unawarded rounds can attempt delivery");
        if (!ok) return;
        lockedWinner[r] = beneficiary;
        liveAsk[r] = bytes32(0);
        bool success = abi.decode(data, (bool));
        assertEq(success, beneficiary != address(receiver) || !reject, "failed delivery remains retryable");
        if (success) {
            wasAwarded[r] = true;
            ++awardedCount;
        } else {
            ++failedAwards;
        }
    }

    function advance(uint32 secondsSeed, uint8 blocksSeed) external {
        vm.warp(vm.getBlockTimestamp() + _bound(secondsSeed, 0, 24 hours));
        vm.roll(vm.getBlockNumber() + _bound(blocksSeed, 0, 20));
    }

    function requestCount() external view returns (uint256) {
        return requestIds.length;
    }

    function keptCount() external view returns (uint256) {
        return keptIds.length;
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 80
/// forge-config: default.invariant.fail-on-revert = true
contract MadRewardsInvariantTest is MadRewardsFixture {
    MadRewardsLifecycleHandler internal handler;

    function setUp() public override {
        super.setUp();
        handler = new MadRewardsLifecycleHandler(hook, token, pool, nft, intake, imd, [ALICE, BOB]);
        vm.deal(address(handler), 1000 ether);
        imd.mint(address(handler), 1000 ether);
        // Seed a live ask, an unasked round, a pending draw and a refund. Random call sequences
        // can reach all lifecycle branches without depending on a lucky setup ordering.
        for (uint256 i; i < 2; ++i) {
            handler.buy(0.01 ether, 0.001 ether, 0, false);
            handler.resolveDraw(i, false);
            handler.claim(i);
            handler.freezeAndClose(i == 1);
            handler.advance(1, 8);
        }
        handler.ask(0, 0.5 ether);
        handler.buy(0.01 ether, 0.001 ether, 0, false);
        handler.buy(0.01 ether, 0.001 ether, 0, false);
        handler.resolveDraw(3, true);
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](11);
        selectors[0] = handler.donate.selector;
        selectors[1] = handler.buy.selector;
        selectors[2] = handler.resolveDraw.selector;
        selectors[3] = handler.withdrawRefund.selector;
        selectors[4] = handler.claim.selector;
        selectors[5] = handler.freezeAndClose.selector;
        selectors[6] = handler.ask.selector;
        selectors[7] = handler.failure.selector;
        selectors[8] = handler.answer.selector;
        selectors[9] = handler.award.selector;
        selectors[10] = handler.advance.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function invariant_ethAndImdConservationNoOutstandingOracleAllowance() public view {
        assertEq(
            address(rewards).balance + handler.acquisitionSpent(),
            handler.initialEth() + handler.donatedEth() + handler.refundsPaid()
        );
        assertEq(address(pool).balance + handler.refundsPaid(), handler.acquisitionSpent());
        assertEq(pool.acquisitionRefundCredit(address(rewards)), handler.refundsCredited() - handler.refundsPaid());
        assertEq(imd.balanceOf(address(rewards)) + handler.oracleSpent(), handler.initialImd() + handler.donatedImd());
        assertEq(imd.balanceOf(address(intake)), handler.oracleSpent());
        assertEq(imd.allowance(address(rewards), address(intake)), 0);
        assertEq(hook.playgroundClaims(), 0, "reward keeper actions cannot create or spend Playground revenue");
    }

    function invariant_everyKeptNFTIsHeldOrAwardedExactlyOnce() public view {
        assertEq(rewards.nextUnassigned(), handler.closedCount());
        assertEq(rewards.hasUnassignedNFT(), handler.keptCount() > handler.closedCount());
        for (uint256 i; i < handler.keptCount(); ++i) {
            uint256 id = handler.keptIds(i);
            (address collection, uint256 tokenId) = rewards.keptNFTs(i);
            assertEq(collection, address(nft));
            assertEq(tokenId, id, "FIFO follows keep order");
            (address purchasePool, bool claimed) = rewards.purchases(id);
            assertEq(purchasePool, address(pool));
            assertTrue(claimed);
            bool awarded = i < handler.closedCount() && handler.wasAwarded(i + 1);
            assertEq(nft.ownerOf(id), awarded ? handler.lockedWinner(i + 1) : address(rewards));
            assertEq(rewards.recordedNFT(keccak256(abi.encode(address(nft), id))), !awarded);
        }
    }

    function invariant_roundsFollowIndependentOracleAndAwardState() public view {
        assertEq(token.currentRound(), handler.closedCount() + 1);
        for (uint256 r = 1; r <= handler.closedCount(); ++r) {
            (uint256 index, uint64 closedAt, address winner, address beneficiary, bool awarded, bytes32 live) =
                rewards.rounds(r);
            assertEq(index, r);
            assertEq(closedAt, handler.closedAt(r));
            assertEq(winner, handler.answerWinner(r));
            assertEq(beneficiary, handler.lockedWinner(r));
            assertEq(awarded, handler.wasAwarded(r));
            assertEq(live, handler.liveAsk(r));
            assertEq(token.leader(r), handler.fallbackWinner(r));
            bytes32 uuid = handler.successfulUuid(r);
            if (uuid != bytes32(0)) assertTrue(rewards.consumed(uuid));
            if (live != bytes32(0)) {
                (uint256 round,,,,, bool active) = rewards.pending(live);
                assertEq(round, r);
                assertTrue(active);
            }
        }
    }

    function test_lifecycleHandlerExercisesRefundRetryRejectedAwardAndFallback() public {
        handler.withdrawRefund();
        handler.answer(0, true, true); // bad hash cannot consume the live request
        handler.failure(0, true);
        handler.ask(0, 0.5 ether);
        handler.advance(6 hours, 8);
        handler.ask(0, 0.5 ether); // unanswered ask is superseded
        handler.answer(0, true, false);
        handler.award(0, true);
        handler.award(0, false);
        handler.award(0, false); // no second delivery
        for (uint256 i; i < 3; ++i) {
            handler.advance(24 hours, 8);
        }
        handler.award(1, false); // fallback for the other round
        invariant_ethAndImdConservationNoOutstandingOracleAllowance();
        invariant_everyKeptNFTIsHeldOrAwardedExactlyOnce();
        invariant_roundsFollowIndependentOracleAndAwardState();
        assertEq(handler.awardedCount(), 2);
        assertEq(handler.failedAwards(), 1);
        assertEq(handler.failedAsks(), 1);
        assertEq(handler.retryCount(), 1);
        assertEq(handler.deliveredCount(), 1);
        assertGt(handler.refundsPaid(), 0);
    }
}
