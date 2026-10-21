// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

contract MockNFT is ERC721 {
    bool public rejectTransfers;
    constructor() ERC721("Test NFT", "NFT") {}

    function mint(address to, uint256 id) external {
        _mint(to, id);
    }

    function setRejectTransfers(bool reject) external {
        rejectTransfers = reject;
    }

    function _update(address to, uint256 id, address auth) internal override returns (address) {
        require(!rejectTransfers, "transfer unavailable");
        return super._update(to, id, auth);
    }
}

contract RetryReceiver is IERC721Receiver {
    bool public reject = true;
    bool public reentered;
    address public attackTarget;
    bytes public attackData;

    function setReject(bool value) external {
        reject = value;
    }

    function setAttack(address target, bytes calldata data) external {
        attackTarget = target;
        attackData = data;
    }

    function onERC721Received(address, address, uint256, bytes calldata) external returns (bytes4) {
        require(!reject, "recipient unavailable");
        if (attackTarget != address(0)) (reentered,) = attackTarget.call(attackData);
        return this.onERC721Received.selector;
    }
}
