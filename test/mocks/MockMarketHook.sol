// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";

/// @dev Models the official market's exact-input restriction and 1% ETH fee. Claims keep tests
/// of an empty native reserve independent of the official hook's separate ETH fee recipient.
contract MockMarketHook {
    IPoolManager public immutable manager;
    uint256 public swaps;

    constructor(IPoolManager m) {
        manager = m;
    }

    function beforeInitialize(address, PoolKey calldata, uint160) external view returns (bytes4) {
        require(msg.sender == address(manager));
        return this.beforeInitialize.selector;
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external view returns (bytes4, BalanceDelta) {
        require(msg.sender == address(manager));
        return (this.afterAddLiquidity.selector, BalanceDelta.wrap(0));
    }

    function afterSwap(address, PoolKey calldata, SwapParams calldata p, BalanceDelta d, bytes calldata)
        external
        returns (bytes4, int128)
    {
        require(msg.sender == address(manager));
        require(p.amountSpecified < 0 && !p.zeroForOne, "only exact-input sells in this model");
        swaps++;
        uint256 fee = uint256(int256(d.amount0())) / 100;
        manager.mint(address(this), 0, fee);
        return (this.afterSwap.selector, int128(int256(fee)));
    }
}
