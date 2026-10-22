// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IMadBinding} from "./interfaces/IMadToken.sol";

/// @notice Fixed-supply MAD. Its only exceptional debit is a holder paying to freeze another wallet.
contract MadToken is ERC20 {
    error InvalidTarget();
    error ZeroCost();
    error WalletFrozen(address account, uint64 until);
    error RoundClosedForBlock();
    error UnauthorizedHook();
    error InvalidBinding();

    event Frozen(address indexed by, address indexed target, uint256 cost, uint64 until);
    event HookBound(address indexed hook);
    event RoundClosed(uint256 indexed round, uint64 first, uint64 last, address leader);

    uint256 public constant INITIAL_SUPPLY = 1_000_000_000 ether;
    uint256 private constant LAUNCH_SLOT = uint256(keccak256("mad.atomic.launch"));
    address public immutable launchFactory;
    address public hook;
    mapping(address => uint64) public frozenUntil;
    uint256 public currentRound = 1;

    struct Blocks {
        uint64 first;
        uint64 last;
    }
    mapping(uint256 => Blocks) public roundBlocks;
    mapping(uint256 => mapping(address => uint256)) public spent;
    mapping(uint256 => address) public leader;

    constructor() ERC20("Mutually Assured Destruction", "MAD") {
        launchFactory = msg.sender;
        roundBlocks[1].first = uint64(block.number);
        _mint(msg.sender, INITIAL_SUPPLY);
        // This capability exists only in the factory's atomic deployment transaction.
        // A later transaction, including another in the same block, cannot bind a hook.
        uint256 slot = LAUNCH_SLOT;
        assembly ("memory-safe") { tstore(slot, 1) }
    }

    /// @dev Called during the authenticated hook's beforeInitialize. The trusted launch factory
    /// must deploy token, deploy hook and initialize without handing control to untrusted code.
    function bindHook() external {
        uint256 active;
        uint256 slot = LAUNCH_SLOT;
        assembly ("memory-safe") { active := tload(slot) }
        if (active != 1 || hook != address(0) || msg.sender.code.length == 0) revert InvalidBinding();
        IMadBinding candidate = IMadBinding(msg.sender);
        if (
            candidate.launchFactory() != launchFactory || address(candidate.mad()) != address(this)
                || !candidate.bindingActive()
        ) revert InvalidBinding();
        assembly ("memory-safe") { tstore(slot, 0) }
        hook = msg.sender;
        emit HookBound(msg.sender);
    }

    function isWallet(address account) public view returns (bool) {
        uint256 length = account.code.length;
        if (length == 0) return true;
        if (length != 23) return false;
        bytes3 prefix;
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            extcodecopy(account, ptr, 0, 3)
            prefix := mload(ptr)
        }
        return prefix == hex"ef0100";
    }

    function freezeCost(address target) public view returns (uint256) {
        return balanceOf(target) / 100;
    }

    function freeze(address target) external {
        if (target == address(0) || target == msg.sender || !isWallet(target)) revert InvalidTarget();
        uint256 round = currentRound;
        if (block.number < roundBlocks[round].first) revert RoundClosedForBlock();
        uint256 cost = freezeCost(target);
        if (cost == 0) revert ZeroCost();
        // Call the parent directly, without a global exemption or allowance bypass.
        uint256 burned = cost / 2;
        super._update(msg.sender, address(0), burned);
        super._update(msg.sender, target, cost - burned);
        uint64 until = uint64(block.timestamp + 24 hours);
        frozenUntil[target] = until;
        uint256 total = spent[round][msg.sender] + cost;
        spent[round][msg.sender] = total;
        if (total > spent[round][leader[round]]) leader[round] = msg.sender;
        emit Frozen(msg.sender, target, cost, until);
    }

    function closeRound() external returns (uint256 round) {
        if (msg.sender != hook || hook == address(0)) revert UnauthorizedHook();
        round = currentRound;
        Blocks storage window = roundBlocks[round];
        if (block.number < window.first) revert RoundClosedForBlock();
        window.last = uint64(block.number);
        emit RoundClosed(round, window.first, window.last, leader[round]);
        currentRound = round + 1;
        roundBlocks[round + 1].first = uint64(block.number + 1);
    }

    function _update(address from, address to, uint256 amount) internal override {
        // Only wallets can be frozen (freeze checks the code at that time). A contract deployed at a
        // frozen counterfactual address afterwards stays frozen for the remainder of the window, so
        // deploying code is not an escape from a freeze that was paid for.
        if (from != address(0) && frozenUntil[from] > block.timestamp) {
            revert WalletFrozen(from, frozenUntil[from]);
        }
        super._update(from, to, amount);
    }
}
