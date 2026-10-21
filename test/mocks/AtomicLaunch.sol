// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev Test harness for the real atomic CREATE / CREATE2 / initialize launch transaction.
/// Creation code is an argument to avoid embedding a second full project in this harness's runtime.
contract AtomicLaunch {
    function launch(bytes memory tokenCode, bytes memory hookCode, IPoolManager manager, address owner, address fwa)
        external
        returns (address token, address hook, PoolKey memory key)
    {
        assembly ("memory-safe") { token := create(0, add(tokenCode, 32), mload(tokenCode)) }
        require(token != address(0));
        bytes memory initCode = bytes.concat(hookCode, abi.encode(manager, token, owner, address(this)));
        bytes32 hash = keccak256(initCode);
        for (uint256 i; i < 200_000; ++i) {
            bytes32 salt = bytes32(i);
            address predicted =
                address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, hash)))));
            if (uint160(predicted) & ((1 << 14) - 1) != 0x20cc) continue;
            assembly ("memory-safe") { hook := create2(0, add(initCode, 32), mload(initCode), salt) }
            break;
        }
        require(hook != address(0));
        (address c0, address c1) = token < fwa ? (token, fwa) : (fwa, token);
        key = PoolKey(Currency.wrap(c0), Currency.wrap(c1), 12_500, 60, IHooks(hook));
        manager.initialize(key, 79228162514264337593543950336);
        require(IERC20(token).transfer(msg.sender, IERC20(token).totalSupply()));
    }
}
