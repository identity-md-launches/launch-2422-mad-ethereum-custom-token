// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockFWA is ERC20 {
    error InvalidTransfer();
    address public immutable manager;
    uint256 public burned;
    address public lastTransferFrom;
    address public lastTransferTo;
    uint256 public lastTransferAmount;

    constructor(address m) ERC20("Fake World Assets", "FWA") {
        manager = m;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burn(uint256 amount) external {
        burned += amount;
        _burn(msg.sender, amount);
    }

    function _update(address from, address to, uint256 amount) internal override {
        if (from != address(0) && to != address(0) && from != manager && to != manager) revert InvalidTransfer();
        lastTransferFrom = from;
        lastTransferTo = to;
        lastTransferAmount = amount;
        super._update(from, to, amount);
    }
}
