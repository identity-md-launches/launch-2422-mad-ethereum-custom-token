// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @dev Test-only settlement harness. The active payer is always the entry point's caller.
contract TestRouter is IUnlockCallback {
    using SafeERC20 for IERC20;
    IPoolManager public immutable manager;
    address private payer;

    constructor(IPoolManager m) {
        manager = m;
    }

    function swap(PoolKey memory key, SwapParams memory p) external payable returns (BalanceDelta d) {
        require(payer == address(0));
        payer = msg.sender;
        d = abi.decode(manager.unlock(abi.encode(uint8(0), key, abi.encode(p))), (BalanceDelta));
        delete payer;
        _refund();
    }

    function modify(PoolKey memory key, ModifyLiquidityParams memory p) external payable returns (BalanceDelta d) {
        require(payer == address(0));
        payer = msg.sender;
        d = abi.decode(manager.unlock(abi.encode(uint8(1), key, abi.encode(p))), (BalanceDelta));
        delete payer;
        _refund();
    }

    function _refund() private {
        if (address(this).balance != 0) {
            (bool ok,) = msg.sender.call{value: address(this).balance}("");
            require(ok);
        }
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager) && payer != address(0));
        (uint8 action, PoolKey memory key, bytes memory args) = abi.decode(data, (uint8, PoolKey, bytes));
        BalanceDelta d;
        if (action == 0) d = manager.swap(key, abi.decode(args, (SwapParams)), "");
        else (d,) = manager.modifyLiquidity(key, abi.decode(args, (ModifyLiquidityParams)), "");
        _settle(key.currency0, d.amount0());
        _settle(key.currency1, d.amount1());
        return abi.encode(d);
    }

    function _settle(Currency c, int128 d) private {
        if (d < 0) {
            uint256 value = uint256(-int256(d));
            manager.sync(c);
            if (c.isAddressZero()) {
                manager.settle{value: value}();
            } else {
                IERC20(Currency.unwrap(c)).safeTransferFrom(payer, address(manager), value);
                manager.settle();
            }
        } else if (d > 0) {
            manager.take(c, payer, uint256(int256(d)));
        }
    }
    receive() external payable {}
}
