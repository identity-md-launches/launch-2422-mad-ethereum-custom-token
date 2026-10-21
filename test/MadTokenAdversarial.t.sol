// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {MadToken} from "src/MadToken.sol";
import {MadTestBase} from "./Base.t.sol";

contract MadTokenBoundaryTest is Test {
    MadToken internal token;
    address internal alice;
    address internal bob;
    address internal spender;

    function setUp() public {
        vm.warp(1_800_000_000);
        token = new MadToken();
        alice = makeAddr("boundary alice");
        bob = makeAddr("boundary bob");
        spender = makeAddr("boundary spender");
    }

    function test_insufficientSecondFreezeDebitRollsBackBurnAndRoundAccounting() public {
        token.transfer(alice, 2);
        token.transfer(bob, 300); // cost 3: the burn of 1 can succeed, the following payment cannot.
        uint256 supply = token.totalSupply();
        vm.prank(alice);
        vm.expectRevert();
        token.freeze(bob);
        assertEq(token.totalSupply(), supply);
        assertEq(token.balanceOf(alice), 2);
        assertEq(token.balanceOf(bob), 300);
        assertEq(token.frozenUntil(bob), 0);
        assertEq(token.spent(1, alice), 0);
        assertEq(token.leader(1), address(0));
    }

    function test_minimumFreezeCostsOneWeiAndBurnsZero() public {
        token.transfer(alice, 1);
        token.transfer(bob, 99);
        vm.prank(alice);
        vm.expectRevert(MadToken.ZeroCost.selector);
        token.freeze(bob);
        token.transfer(bob, 1);
        uint256 supply = token.totalSupply();
        vm.prank(alice);
        token.freeze(bob);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(bob), 101);
        assertEq(token.totalSupply(), supply);
        assertEq(token.spent(1, alice), 1);
    }

    function test_frozenTransferFromRollsBackFiniteAllowanceAndCanRetryAtExpiry() public {
        token.transfer(alice, 1000);
        token.transfer(bob, 1000);
        vm.prank(alice);
        token.approve(spender, 7);
        vm.prank(bob);
        token.freeze(alice);
        uint256 held = token.balanceOf(alice);
        uint64 until = token.frozenUntil(alice);
        vm.warp(until - 1);
        vm.prank(spender);
        vm.expectRevert(abi.encodeWithSelector(MadToken.WalletFrozen.selector, alice, until));
        token.transferFrom(alice, spender, 7);
        assertEq(token.allowance(alice, spender), 7);
        assertEq(token.balanceOf(alice), held);
        vm.warp(until);
        vm.prank(spender);
        token.transferFrom(alice, spender, 7);
        assertEq(token.allowance(alice, spender), 0);
        assertEq(token.balanceOf(alice), held - 7);
        assertEq(token.balanceOf(spender), 7);
    }

    function test_freezeCannotSpendApprovedTokensFromSomeoneElse() public {
        token.transfer(alice, 10_000);
        token.transfer(bob, 10_000);
        vm.prank(alice);
        token.approve(spender, type(uint256).max);
        vm.prank(spender);
        vm.expectRevert();
        token.freeze(bob);
        assertEq(token.balanceOf(alice), 10_000);
        assertEq(token.allowance(alice, spender), type(uint256).max);
        assertEq(token.spent(1, spender), 0);
        assertEq(token.frozenUntil(bob), 0);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_codeLengthAndPrefixAreBothRequired(uint8 rawLength, bytes3 prefix) public {
        uint256 length = bound(rawLength, 0, 64);
        bytes memory code = new bytes(length);
        for (uint256 i; i < length; ++i) {
            code[i] = i < 3 ? prefix[i] : bytes1(uint8(i));
        }
        vm.etch(bob, code);
        token.transfer(bob, 1000);
        token.transfer(alice, 10);
        bool wallet = length == 0 || (length == 23 && prefix == hex"ef0100");
        assertEq(token.isWallet(bob), wallet);
        vm.prank(alice);
        if (!wallet) vm.expectRevert(MadToken.InvalidTarget.selector);
        token.freeze(bob);
        assertEq(token.frozenUntil(bob), wallet ? block.timestamp + 24 hours : 0);
    }

    function test_delegationChangeAndRevocationDoNotRemoveFreeze() public {
        token.transfer(alice, 1000);
        token.transfer(bob, 1000);
        vm.etch(bob, abi.encodePacked(hex"ef0100", spender));
        vm.prank(alice);
        token.freeze(bob);
        uint64 until = token.frozenUntil(bob);
        vm.etch(bob, abi.encodePacked(hex"ef0100", alice));
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(MadToken.WalletFrozen.selector, bob, until));
        token.transfer(alice, 1);
        vm.etch(bob, "");
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(MadToken.WalletFrozen.selector, bob, until));
        token.transfer(alice, 1);
        vm.prank(bob);
        token.freeze(alice);
        assertEq(token.frozenUntil(bob), until);
    }
}

/// @dev An independent ledger of transfers, allowances, paid costs and event order. The hook
/// identity is used solely to exercise MadToken's round boundary; reward assignment is exercised
/// through the real hook in MadRewardsInvariant.t.sol.
contract MadTokenLedgerHandler is Test {
    MadToken public immutable token;
    address public immutable boundHook;
    address[4] public actors;
    mapping(address => uint256) public balance;
    mapping(address => uint64) public until;
    mapping(address => mapping(address => uint256)) public allowance;
    mapping(uint256 => mapping(address => uint256)) public costs;
    mapping(uint256 => mapping(address => uint256)) public reached;
    mapping(uint256 => uint64) public first;
    mapping(uint256 => uint64) public last;
    uint256 public round = 1;
    uint256 public burned;
    uint256 public sequence;
    uint256 public freezes;
    uint256 public transfers;
    uint256 public rejected;
    uint256 public immutable outsideBalance;

    constructor(MadToken t, address h, address[4] memory a) {
        token = t;
        boundHook = h;
        actors = a;
        uint256 sum;
        for (uint256 i; i < 4; ++i) {
            balance[a[i]] = t.balanceOf(a[i]);
            sum += balance[a[i]];
        }
        outsideBalance = t.totalSupply() - sum;
        (first[1],) = t.roundBlocks(1);
    }

    function move(uint8 fromSeed, uint8 toSeed, uint96 raw) external {
        address from = actors[fromSeed % 4];
        address to = actors[toSeed % 4];
        uint256 amount = _bound(raw, 0, balance[from] + 1);
        bool expected = until[from] <= vm.getBlockTimestamp() && amount <= balance[from];
        vm.prank(from);
        (bool ok,) = address(token).call(abi.encodeCall(token.transfer, (to, amount)));
        assertEq(ok, expected, "direct send authorization");
        if (ok) {
            balance[from] -= amount;
            balance[to] += amount;
            ++transfers;
        } else {
            ++rejected;
        }
    }

    function approve(uint8 ownerSeed, uint8 spenderSeed, uint96 raw, bool infinite) external {
        address owner = actors[ownerSeed % 4];
        address spender = actors[spenderSeed % 4];
        uint256 amount = infinite ? type(uint256).max : _bound(raw, 0, balance[owner] + 1);
        vm.prank(owner);
        assertTrue(token.approve(spender, amount));
        allowance[owner][spender] = amount;
    }

    function delegatedMove(uint8 ownerSeed, uint8 spenderSeed, uint8 toSeed, uint96 raw) external {
        address owner = actors[ownerSeed % 4];
        address spender = actors[spenderSeed % 4];
        address to = actors[toSeed % 4];
        uint256 amount = _bound(raw, 0, balance[owner] + 1);
        bool expected =
            until[owner] <= vm.getBlockTimestamp() && amount <= balance[owner] && amount <= allowance[owner][spender];
        vm.prank(spender);
        (bool ok,) = address(token).call(abi.encodeCall(token.transferFrom, (owner, to, amount)));
        assertEq(ok, expected, "delegated send authorization");
        if (ok) {
            balance[owner] -= amount;
            balance[to] += amount;
            if (allowance[owner][spender] != type(uint256).max) allowance[owner][spender] -= amount;
            ++transfers;
        } else {
            ++rejected;
        }
    }

    function freeze(uint8 fromSeed, uint8 toSeed) external {
        address from = actors[fromSeed % 4];
        address to = actors[toSeed % 4];
        uint256 cost = balance[to] / 100;
        bool expected = from != to && cost > 0 && cost <= balance[from] && vm.getBlockNumber() >= first[round];
        vm.prank(from);
        (bool ok,) = address(token).call(abi.encodeCall(token.freeze, (to)));
        assertEq(ok, expected, "freeze authorization and solvency");
        if (ok) {
            balance[from] -= cost;
            balance[to] += cost - cost / 2;
            burned += cost / 2;
            costs[round][from] += cost;
            reached[round][from] = ++sequence;
            until[to] = uint64(vm.getBlockTimestamp() + 24 hours);
            ++freezes;
        } else {
            ++rejected;
        }
    }

    function advance(uint32 secondsSeed, uint8 blocksSeed) external {
        vm.warp(vm.getBlockTimestamp() + _bound(secondsSeed, 0, 2 days));
        vm.roll(vm.getBlockNumber() + _bound(blocksSeed, 0, 10));
    }

    function close() external {
        bool expected = vm.getBlockNumber() >= first[round];
        vm.prank(boundHook);
        (bool ok, bytes memory data) = address(token).call(abi.encodeCall(token.closeRound, ()));
        assertEq(ok, expected, "close cannot overlap rounds");
        if (ok) {
            assertEq(abi.decode(data, (uint256)), round);
            last[round] = uint64(vm.getBlockNumber());
            first[++round] = uint64(vm.getBlockNumber() + 1);
        } else {
            ++rejected;
        }
    }

    function expectedLeader(uint256 r) external view returns (address best) {
        for (uint256 i; i < 4; ++i) {
            address candidate = actors[i];
            uint256 spend = costs[r][candidate];
            if (
                spend > costs[r][best]
                    || (spend != 0 && spend == costs[r][best] && reached[r][candidate] < reached[r][best])
            ) {
                best = candidate;
            }
        }
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 80
/// forge-config: default.invariant.fail-on-revert = true
contract MadTokenLedgerInvariantTest is MadTestBase {
    MadTokenLedgerHandler internal handler;

    function setUp() public override {
        super.setUp();
        address delegated = makeAddr("ledger delegated");
        vm.etch(delegated, abi.encodePacked(hex"ef0100", address(router)));
        token.transfer(delegated, 1_000_000 ether);
        handler = new MadTokenLedgerHandler(token, address(hook), [ALICE, BOB, CAROL, delegated]);
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = handler.move.selector;
        selectors[1] = handler.approve.selector;
        selectors[2] = handler.delegatedMove.selector;
        selectors[3] = handler.freeze.selector;
        selectors[4] = handler.advance.selector;
        selectors[5] = handler.close.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function invariant_balancesAllowancesAndSupplyMatchIndependentLedger() public view {
        uint256 sum = handler.outsideBalance();
        for (uint256 i; i < 4; ++i) {
            address a = handler.actors(i);
            assertEq(token.balanceOf(a), handler.balance(a));
            assertEq(token.frozenUntil(a), handler.until(a));
            sum += token.balanceOf(a);
            for (uint256 j; j < 4; ++j) {
                address spender = handler.actors(j);
                assertEq(token.allowance(a, spender), handler.allowance(a, spender));
            }
        }
        assertEq(token.totalSupply(), sum);
        assertEq(token.totalSupply() + handler.burned(), token.INITIAL_SUPPLY());
    }

    function invariant_roundWindowsAndLeadersMatchPaidCostsAndOrder() public view {
        assertEq(token.currentRound(), handler.round());
        for (uint256 r = 1; r <= handler.round(); ++r) {
            (uint64 first, uint64 last) = token.roundBlocks(r);
            assertEq(first, handler.first(r));
            assertEq(last, handler.last(r));
            assertEq(token.leader(r), handler.expectedLeader(r));
            for (uint256 i; i < 4; ++i) {
                address actor = handler.actors(i);
                assertEq(token.spent(r, actor), handler.costs(r, actor));
            }
        }
    }

    function test_ledgerHandlerReachesSuccessFailureAndRoundTransition() public {
        handler.freeze(0, 1);
        handler.move(1, 2, 1); // frozen
        handler.freeze(1, 0); // internal payment remains usable
        handler.approve(0, 2, 50, false);
        handler.delegatedMove(0, 2, 3, 20); // frozen, allowance must survive
        handler.advance(24 hours, 1);
        handler.delegatedMove(0, 2, 3, 20);
        handler.close();
        handler.freeze(0, 1); // closing block
        handler.advance(1, 1);
        handler.freeze(0, 1);
        invariant_balancesAllowancesAndSupplyMatchIndependentLedger();
        invariant_roundWindowsAndLeadersMatchPaidCostsAndOrder();
        assertEq(handler.freezes(), 3);
        assertEq(handler.transfers(), 1);
        assertEq(handler.rejected(), 3);
    }
}
