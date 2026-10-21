// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {IMadToken} from "./interfaces/IMadToken.sol";
import {MadRewards} from "./MadRewards.sol";

interface IFWABurn {
    function burn(uint256 amount) external;
}

/// @notice Immutable MAD fee policy; the launch owner controls only opening and conversion bounds.
contract MadHook is ReentrancyGuard, IUnlockCallback {
    using StateLibrary for IPoolManager;

    error Unauthorized();
    error InvalidPool();
    error InvalidConfig();
    error TradingClosed();
    error AlreadyEnabled();
    error AlreadyInitialized();
    error InvalidSwap();
    error PartialSpecifiedFill();
    error Slippage();
    error NoRoundReward();
    error InvalidUnlock();

    event TradingEnabled(uint64 openedAt);
    event MarketSet(PoolId indexed poolId);
    event ConversionBoundsSet(uint160 sqrtPriceLimitX96, uint256 minEthPerFwaX128);
    event FeeCharged(uint256 fwaBase, uint256 totalFee, uint256 playground, uint256 nft, uint256 burned);
    event NFTConverted(uint256 sold, uint256 ethReceived, uint256 unsold);
    event PlaygroundPaid(uint256 amount);
    event NFTEthRedeemed(uint256 amount);

    address public constant FWA = 0xa0Df17B5aC76ABaBA36E1450E2cbCd18A620C845;
    address public immutable receiver = 0x4E2B3F2D201666d29bf1CE7aA665C8fdF768b481;
    uint256 public constant RATE_DENOMINATOR = 10_000 * 1800;
    uint160 public constant HOOK_FLAGS = (1 << 13) | (1 << 7) | (1 << 6) | (1 << 3) | (1 << 2);
    IPoolManager public immutable poolManager;
    IMadToken public immutable mad;
    address public immutable owner;
    address public immutable launchFactory;
    MadRewards public immutable rewards;

    PoolId public poolId;
    bool public initialized;
    bool public bindingActive;
    bool public tradingEnabled;
    uint64 public openedAt;
    PoolKey public ethFwaPool;
    uint160 public sqrtPriceLimitX96;
    uint256 public minEthPerFwaX128;
    uint256 public playgroundClaims;
    uint256 public nftFwaClaims;
    uint256 public nftEthClaims;
    bool private swapActive;
    bytes32 private swapContext;
    uint256 private expectedSpecifiedFwa;
    uint8 private unlockOperation;

    /// @param manager_ Resolved as $poolManager; never infer it from a chain-specific literal.
    /// @param mad_ Resolved as $token, deployed immediately before this hook.
    /// @param owner_ Resolved as $owner, the explicit launching wallet.
    /// @param factory_ Resolved as $factory; it also calls PoolManager.initialize.
    constructor(IPoolManager manager_, IMadToken mad_, address owner_, address factory_) {
        if (
            address(manager_) == address(0) || address(mad_) == address(0) || owner_ == address(0)
                || factory_ == address(0) || address(mad_) == FWA
        ) revert InvalidConfig();
        poolManager = manager_;
        mad = mad_;
        owner = owner_;
        launchFactory = factory_;
        rewards = new MadRewards(owner_, mad_);
        ethFwaPool = PoolKey(
            Currency.wrap(address(0)), Currency.wrap(FWA), 0, 60, IHooks(0x2C67ebA8A50AF0dB5Fba55F725247a75CbDA6444)
        );
        Hooks.validateHookPermissions(IHooks(address(this)), getHookPermissions());
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }
    modifier onlyManager() {
        if (msg.sender != address(poolManager)) revert Unauthorized();
        _;
    }

    function getHookPermissions() public pure returns (Hooks.Permissions memory p) {
        p.beforeInitialize = true;
        p.beforeSwap = true;
        p.afterSwap = true;
        p.beforeSwapReturnDelta = true;
        p.afterSwapReturnDelta = true;
    }

    function beforeInitialize(address sender, PoolKey calldata key, uint160)
        external
        onlyManager
        nonReentrant
        returns (bytes4)
    {
        if (initialized) revert AlreadyInitialized();
        if (sender != launchFactory || mad.launchFactory() != launchFactory) revert Unauthorized();
        address a = Currency.unwrap(key.currency0);
        address b = Currency.unwrap(key.currency1);
        if (
            a >= b || !((a == address(mad) && b == FWA) || (a == FWA && b == address(mad))) || key.fee != 12_500
                || key.tickSpacing != 60 || address(key.hooks) != address(this)
        ) revert InvalidPool();
        poolId = key.toId();
        initialized = true;
        bindingActive = true;
        mad.bindHook();
        bindingActive = false;
        return this.beforeInitialize.selector;
    }

    function enableTrading() external onlyOwner nonReentrant {
        if (tradingEnabled) revert AlreadyEnabled();
        if (!initialized) revert InvalidPool();
        tradingEnabled = true;
        openedAt = uint64(block.timestamp);
        emit TradingEnabled(openedAt);
    }

    /// @notice The rational fee rate avoids prematurely rounding the linear decay to basis points.
    function feeNumerator() public view returns (uint256) {
        uint256 elapsed = tradingEnabled ? block.timestamp - openedAt : 0;
        if (elapsed >= 1800) return 100 * 1800;
        return 9900 * 1800 - 9800 * elapsed;
    }

    function feeFor(uint256 fwaBase) public view returns (uint256) {
        return Math.mulDiv(fwaBase, feeNumerator(), RATE_DENOMINATOR);
    }

    function setEthFwaPool(PoolKey calldata key) external onlyOwner nonReentrant {
        if (
            !key.currency0.isAddressZero() || Currency.unwrap(key.currency1) != FWA || key.fee > 1_000_000
                || key.tickSpacing <= 0 || address(key.hooks) == address(0) || address(key.hooks) == address(this)
        ) {
            revert InvalidPool();
        }
        ethFwaPool = key;
        // A limit for a previous market must not silently authorize a sale on its replacement.
        sqrtPriceLimitX96 = 0;
        minEthPerFwaX128 = 0;
        emit MarketSet(key.toId());
    }

    function setConversionBounds(uint160 limit, uint256 minimumEthPerFwaX128) external onlyOwner nonReentrant {
        if (limit <= TickMath.MIN_SQRT_PRICE || limit >= TickMath.MAX_SQRT_PRICE || minimumEthPerFwaX128 == 0) {
            revert InvalidConfig();
        }
        sqrtPriceLimitX96 = limit;
        minEthPerFwaX128 = minimumEthPerFwaX128;
        emit ConversionBoundsSet(limit, minimumEthPerFwaX128);
    }

    function _checkPool(PoolKey calldata key) private view {
        if (!initialized || PoolId.unwrap(key.toId()) != PoolId.unwrap(poolId)) revert InvalidPool();
    }

    function _fwaSpecified(PoolKey calldata key, SwapParams calldata params) private pure returns (bool) {
        bool fwaIsInput = params.zeroForOne == (Currency.unwrap(key.currency0) == FWA);
        return (params.amountSpecified < 0) == fwaIsInput;
    }

    function beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        external
        onlyManager
        nonReentrant
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        _checkPool(key);
        if (!tradingEnabled) revert TradingClosed();
        if (
            swapActive || params.amountSpecified == 0 || params.amountSpecified > type(int128).max
                || params.amountSpecified < -int256(type(int128).max)
        ) revert InvalidSwap();
        swapActive = true;
        swapContext = keccak256(abi.encode(sender, key, params));
        uint256 fee;
        if (_fwaSpecified(key, params)) {
            bool exactInput = params.amountSpecified < 0;
            uint256 amount = uint256(exactInput ? -params.amountSpecified : params.amountSpecified);
            uint256 base = amount;
            if (exactInput) {
                fee = feeFor(amount); // floor, deducted from the specified gross FWA input
                expectedSpecifiedFwa = amount - fee;
            } else {
                // Gross up specified NET FWA output. Ceiling ensures the requested output survives the tax.
                uint256 rate = feeNumerator();
                fee = Math.mulDiv(amount, rate, RATE_DENOMINATOR - rate, Math.Rounding.Ceil);
                base = amount + fee;
                expectedSpecifiedFwa = base;
            }
            if (expectedSpecifiedFwa > uint256(uint128(type(int128).max)) || fee > uint256(uint128(type(int128).max))) {
                revert InvalidSwap();
            }
            _collect(base, fee);
        }
        return (this.beforeSwap.selector, toBeforeSwapDelta(int128(int256(fee)), 0), 0);
    }

    function afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) external onlyManager nonReentrant returns (bytes4, int128) {
        _checkPool(key);
        if (!swapActive || swapContext != keccak256(abi.encode(sender, key, params))) revert InvalidSwap();
        int128 fwaDelta = Currency.unwrap(key.currency0) == FWA ? delta.amount0() : delta.amount1();
        uint256 base = fwaDelta < 0 ? uint256(-int256(fwaDelta)) : uint256(int256(fwaDelta));
        uint256 fee;
        if (_fwaSpecified(key, params)) {
            // A specified-side delta cannot be refunded in afterSwap. Refuse an underfill atomically.
            if (base != expectedSpecifiedFwa) revert PartialSpecifiedFill();
        } else {
            fee = feeFor(base); // floor of actual FWA exchanged by the pool
            _collect(base, fee);
        }
        swapActive = false;
        delete swapContext;
        delete expectedSpecifiedFwa;
        return (this.afterSwap.selector, int128(int256(fee)));
    }

    function _collect(uint256 base, uint256 fee) private {
        uint256 share = base / 200; // exactly 0.50%, rounded down independently for equal shares
        uint256 burned = fee - 2 * share; // indivisible rounding dust is burned, never assigned to another recipient
        Currency fwa = Currency.wrap(FWA);
        if (share != 0) {
            playgroundClaims += share;
            nftFwaClaims += share;
            poolManager.mint(address(this), fwa.toId(), 2 * share);
        }
        if (burned != 0) {
            poolManager.take(fwa, address(this), burned);
            IFWABurn(FWA).burn(burned);
        }
        emit FeeCharged(base, fee, share, share, burned);
        _convertNFT();
    }

    function _convertNFT() private {
        uint256 available = nftFwaClaims;
        uint160 limit = sqrtPriceLimitX96;
        if (available == 0 || limit == 0) return;
        PoolKey memory market = ethFwaPool;
        (uint160 current,,,) = poolManager.getSlot0(market.toId());
        // Sells move the native/FWA sqrt price upwards. A stale bound retains claims for a later swap.
        if (current == 0 || current >= limit) return;
        uint256 offered = Math.min(available, uint256(uint128(type(int128).max)));
        BalanceDelta d = poolManager.swap(market, SwapParams(false, -int256(offered), limit), "");
        if (d.amount1() > 0 || d.amount0() < 0) revert InvalidSwap();
        uint256 sold = uint256(-int256(d.amount1()));
        uint256 proceeds = uint256(int256(d.amount0()));
        if (
            sold > offered
                || (sold > 0
                    && (proceeds == 0 || proceeds < Math.mulDiv(sold, minEthPerFwaX128, 1 << 128, Math.Rounding.Ceil)))
        ) revert Slippage();
        if (sold != 0) {
            nftFwaClaims = available - sold;
            poolManager.burn(address(this), Currency.wrap(FWA).toId(), sold);
        }
        if (proceeds != 0) {
            if (address(poolManager).balance >= proceeds) {
                poolManager.take(Currency.wrap(address(0)), address(rewards), proceeds);
            } else {
                nftEthClaims += proceeds;
                poolManager.mint(address(this), 0, proceeds);
            }
        }
        emit NFTConverted(sold, proceeds, nftFwaClaims);
    }

    function payout() external nonReentrant returns (uint256 amount) {
        amount = playgroundClaims;
        if (amount == 0) return 0;
        playgroundClaims = 0;
        unlockOperation = 1;
        poolManager.unlock(abi.encode(amount));
        unlockOperation = 0;
        emit PlaygroundPaid(amount);
    }

    function redeemNftETH(uint256 amount) external nonReentrant {
        if (msg.sender != address(rewards)) revert Unauthorized();
        _redeemNftETH(amount);
    }

    function flushNftETH() external nonReentrant {
        _redeemNftETH(nftEthClaims);
    }

    function _redeemNftETH(uint256 amount) private {
        if (amount == 0) return;
        nftEthClaims -= amount;
        unlockOperation = 2;
        poolManager.unlock(abi.encode(amount));
        unlockOperation = 0;
        emit NFTEthRedeemed(amount);
    }

    function unlockCallback(bytes calldata data) external onlyManager returns (bytes memory) {
        uint256 amount = abi.decode(data, (uint256));
        if (unlockOperation == 1) {
            Currency fwa = Currency.wrap(FWA);
            poolManager.burn(address(this), fwa.toId(), amount);
            poolManager.take(fwa, receiver, amount);
        } else if (unlockOperation == 2) {
            poolManager.burn(address(this), 0, amount);
            poolManager.take(Currency.wrap(address(0)), address(rewards), amount);
        } else {
            revert InvalidUnlock();
        }
        return "";
    }

    function closeRound() external nonReentrant returns (uint256 round) {
        round = mad.currentRound();
        if (mad.leader(round) == address(0) || !rewards.hasUnassignedNFT()) revert NoRoundReward();
        mad.closeRound();
        rewards.assignRound(round);
    }

    // Permissionless convenience entry points. The helper owns the reentrancy lock and the assets.
    function buy() external returns (uint256) {
        return rewards.buy();
    }

    function claim(uint256 requestId) external {
        rewards.claim(requestId);
    }

    function askWinner(uint256 round) external returns (bytes32) {
        return rewards.askWinner(round);
    }

    function award(uint256 round) external returns (bool) {
        return rewards.award(round);
    }
}
