// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {MadHook} from "../src/MadHook.sol";
import {MadToken} from "../src/MadToken.sol";
import {TestRouter} from "./mocks/TestRouter.sol";
import {AtomicLaunch} from "./mocks/AtomicLaunch.sol";

/// @notice Optional real mainnet integration. No FWA/PoolManager/official-market code is mocked or etched.
contract MainnetForkTest is Test {
    using StateLibrary for IPoolManager;
    address constant FWA = 0xa0Df17B5aC76ABaBA36E1450E2cbCd18A620C845;
    address constant OWNER = 0xFc3C962FAD2C1cC77f1a0d46e7B8a2De79A21774;
    IPoolManager manager;
    TestRouter router;
    MadHook hook;
    MadToken token;
    PoolKey key;
    uint256 tradeSize;

    function setUp() public {
        // This sole optional environment read implements the brief's explicit fork opt-in.
        // All ordinary tests and builds are independent of environment variables.
        string memory rpc = vm.envOr("MAINNET_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc);
        assertEq(block.chainid, 1);
        manager = IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90);
        assertGt(address(manager).code.length, 0);
        assertGt(FWA.code.length, 0);
        router = new TestRouter(manager);
        PoolKey memory market = PoolKey(
            Currency.wrap(address(0)), Currency.wrap(FWA), 0, 60, IHooks(0x2C67ebA8A50AF0dB5Fba55F725247a75CbDA6444)
        );
        vm.deal(address(this), 10 ether);
        router.swap{value: 1 ether}(market, SwapParams(true, -1 ether, TickMath.MIN_SQRT_PRICE + 1));
        uint256 bought = IERC20(FWA).balanceOf(address(this));
        assertGt(bought, 1_000_000);
        AtomicLaunch factory = new AtomicLaunch();
        (address t, address h, PoolKey memory k) =
            factory.launch(vm.getCode("MadToken.sol:MadToken"), vm.getCode("MadHook.sol:MadHook"), manager, OWNER, FWA);
        token = MadToken(t);
        hook = MadHook(h);
        key = k;
        token.approve(address(router), type(uint256).max);
        IERC20(FWA).approve(address(router), type(uint256).max);
        uint256 liquidity = Math.min(bought / 4, token.balanceOf(address(this)) / 4);
        router.modify(key, ModifyLiquidityParams(-887220, 887220, int256(liquidity), bytes32(0)));
        tradeSize = liquidity / 10_000;
        assertGt(tradeSize, 0);
        (uint160 price,,,) = manager.getSlot0(market.toId());
        uint160 limit = uint160(Math.min(uint256(price) * 11 / 10, uint256(TickMath.MAX_SQRT_PRICE - 1)));
        uint256 minimum = Math.mulDiv(1 ether, 1 << 128, bought) / 4;
        vm.prank(OWNER);
        hook.setConversionBounds(limit, minimum);
        vm.prank(OWNER);
        hook.enableTrading();
    }

    function _trade(bool buyMad, bool exactInput) private returns (BalanceDelta d) {
        bool z = buyMad == (Currency.unwrap(key.currency0) == FWA);
        d = router.swap(
            key,
            SwapParams(
                z,
                exactInput ? -int256(tradeSize) : int256(tradeSize),
                z ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            )
        );
    }

    function testFork_realFwaDecayRestBurnSaleAndReceiver() public {
        uint256 beforeSupply = IERC20(FWA).totalSupply();
        uint256 pgBefore = hook.playgroundClaims();
        _trade(true, true);
        uint256 expectedBurn = hook.feeFor(tradeSize) - 2 * (tradeSize / 200);
        assertEq(beforeSupply - IERC20(FWA).totalSupply(), expectedBurn);
        assertEq(hook.playgroundClaims() - pgBefore, tradeSize / 200);
        for (uint256 time; time < 3; ++time) {
            vm.warp(uint256(hook.openedAt()) + time * 900);
            _trade(true, true);
            _trade(true, false);
            _trade(false, true);
            _trade(false, false);
        }
        assertGt(address(hook.rewards()).balance + hook.nftEthClaims(), 0);
        assertEq(IERC20(FWA).balanceOf(address(hook)), 0);
        address receiver = hook.receiver();
        uint256 before = IERC20(FWA).balanceOf(receiver);
        uint256 claim = hook.playgroundClaims();
        hook.payout();
        assertEq(IERC20(FWA).balanceOf(receiver) - before, claim);
        assertEq(hook.payout(), 0);
    }

    function testFork_frozenWalletCannotSellOnRealManager() public {
        address alice = makeAddr("fork alice");
        address bob = makeAddr("fork bob");
        token.transfer(alice, 1000 ether);
        token.transfer(bob, 1000 ether);
        vm.prank(alice);
        token.approve(address(router), type(uint256).max);
        vm.prank(bob);
        token.freeze(alice);
        bool z = Currency.unwrap(key.currency0) == address(token);
        vm.prank(alice);
        vm.expectRevert();
        router.swap(key, SwapParams(z, -1 ether, z ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1));
    }
    receive() external payable {}
}
