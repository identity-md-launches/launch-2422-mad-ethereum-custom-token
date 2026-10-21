// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {MadHook} from "../src/MadHook.sol";
import {MadToken} from "../src/MadToken.sol";
import {MadRewards} from "../src/MadRewards.sol";
import {IMadToken} from "../src/interfaces/IMadToken.sol";
import {MockFWA} from "./mocks/MockFWA.sol";
import {MockMarketHook} from "./mocks/MockMarketHook.sol";
import {TestRouter} from "./mocks/TestRouter.sol";
import {AtomicLaunch} from "./mocks/AtomicLaunch.sol";

abstract contract MadTestBase is Test {
    address internal constant FWA = 0xa0Df17B5aC76ABaBA36E1450E2cbCd18A620C845;
    address internal constant MARKET_HOOK = 0x2C67ebA8A50AF0dB5Fba55F725247a75CbDA6444;
    address internal constant OWNER = 0xFc3C962FAD2C1cC77f1a0d46e7B8a2De79A21774;
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    address internal constant CAROL = address(0xCA201);
    uint160 internal constant Q96 = 79228162514264337593543950336;
    PoolManager internal manager;
    TestRouter internal router;
    MadToken internal token;
    MadHook internal hook;
    MadRewards internal rewards;
    MockFWA internal fwa;
    PoolKey internal key;
    PoolKey internal market;

    function setUp() public virtual {
        vm.chainId(1);
        vm.roll(100);
        vm.warp(1_800_000_000);
        manager = new PoolManager(address(this));
        router = new TestRouter(manager);
        vm.etch(FWA, address(new MockFWA(address(manager))).code);
        fwa = MockFWA(FWA);
        AtomicLaunch factory = _factory();
        (address tokenAddress, address hookAddress, PoolKey memory launchKey) =
            factory.launch(vm.getCode("MadToken.sol:MadToken"), vm.getCode("MadHook.sol:MadHook"), manager, OWNER, FWA);
        token = MadToken(tokenAddress);
        hook = MadHook(hookAddress);
        rewards = hook.rewards();
        key = launchKey;
        token.approve(address(router), type(uint256).max);
        fwa.approve(address(router), type(uint256).max);
        fwa.mint(address(this), 1_000_000_000 ether);
        router.modify(key, ModifyLiquidityParams(-887220, 887220, 1_000_000 ether, bytes32(0)));
        token.transfer(ALICE, 1_000_000 ether);
        token.transfer(BOB, 1_000_000 ether);
        token.transfer(CAROL, 1_000_000 ether);
        fwa.mint(ALICE, 1_000_000 ether);
        fwa.mint(BOB, 1_000_000 ether);
        vm.startPrank(ALICE);
        token.approve(address(router), type(uint256).max);
        fwa.approve(address(router), type(uint256).max);
        vm.stopPrank();
        vm.startPrank(BOB);
        token.approve(address(router), type(uint256).max);
        fwa.approve(address(router), type(uint256).max);
        vm.stopPrank();
    }

    function _factory() internal virtual returns (AtomicLaunch) {
        return new AtomicLaunch();
    }

    function _open(uint256 elapsed) internal {
        vm.prank(OWNER);
        hook.enableTrading();
        vm.warp(block.timestamp + elapsed);
    }

    function _swap(bool buyMad, int256 amount) internal returns (BalanceDelta) {
        bool z = buyMad == (Currency.unwrap(key.currency0) == FWA);
        vm.prank(ALICE);
        return router.swap(key, SwapParams(z, amount, z ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1));
    }

    function _market(uint160 limit) internal {
        vm.etch(MARKET_HOOK, address(new MockMarketHook(manager)).code);
        market = PoolKey(Currency.wrap(address(0)), Currency.wrap(FWA), 0, 60, IHooks(MARKET_HOOK));
        manager.initialize(market, Q96);
        vm.deal(address(this), 1000 ether);
        router.modify{value: 1000 ether}(market, ModifyLiquidityParams(-887220, 887220, 1000 ether, bytes32(0)));
        vm.prank(OWNER); // at least .25 ETH/FWA for this unit-price model
        hook.setConversionBounds(limit, 1 << 126);
    }
    receive() external payable {}
}
