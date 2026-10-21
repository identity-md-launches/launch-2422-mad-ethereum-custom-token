// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IIntake} from "../../src/interfaces/IIntake.sol";
import {OracleAttestation} from "../../src/oracle/OracleAttestation.sol";

contract MockIMD is ERC20 {
    constructor() ERC20("IMD", "IMD") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockIntake is IIntake {
    uint256 public price = 0.5 ether;
    uint256 public nonce;
    uint256 public lastPaid;
    bytes32 public lastAction;
    bytes public lastBody;
    mapping(bytes32 => Callback) public callbacks;
    mapping(bytes32 => bytes4) public failureSelectors;

    function setPrice(uint256 p) external {
        price = p;
    }

    function priceOf(bytes32, address) external view returns (uint256) {
        return price;
    }

    function requestWithFailure(
        bytes32 action,
        bytes calldata body,
        Callback calldata callback,
        bytes4 failure,
        address asset,
        uint256 amount
    ) external payable returns (bytes32 id) {
        require(msg.value == 0 && amount == price && callback.target == msg.sender);
        require(IERC20(asset).transferFrom(msg.sender, address(this), amount));
        id = keccak256(abi.encode(address(this), ++nonce));
        callbacks[id] = callback;
        failureSelectors[id] = failure;
        lastPaid = amount;
        lastAction = action;
        lastBody = body;
    }

    function deliver(bytes32 id, OracleAttestation.Attestation calldata a, bytes calldata signature)
        external
        returns (bool ok, bytes memory result)
    {
        Callback memory c = callbacks[id];
        require(c.target != address(0));
        return c.target.call{gas: 200_000}(abi.encodeWithSelector(c.selector, id, a, signature));
    }

    function fail(bytes32 id, uint8 status, bytes32 reason) external returns (bool ok) {
        (ok,) = callbacks[id].target.call{gas: 200_000}(
            abi.encodeWithSelector(failureSelectors[id], id, status, reason, uint16(0), uint16(0), bytes(""))
        );
    }
}
