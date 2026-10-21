// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {MadHookTest} from "./MadHook.t.sol";
import {AtomicLaunch} from "./mocks/AtomicLaunch.sol";
import {Currency} from "v4-core/src/types/Currency.sol";

/// @dev Reuses the accounting suite with a different CREATE-derived token ordering.
contract MadCurrencyOrderTest is MadHookTest {
    function _factory() internal override returns (AtomicLaunch factory) {
        for (uint256 i = 1; i < 100; ++i) {
            address at = address(uint160(0x100000 + i));
            // deployCodeTo does not create the account; explicitly set its contract nonce.
            address predicted = vm.computeCreateAddress(at, 1);
            if (predicted < FWA) continue;
            deployCodeTo("AtomicLaunch.sol:AtomicLaunch", at);
            vm.setNonce(at, 1);
            return AtomicLaunch(at);
        }
        revert("no reversed ordering");
    }

    function test_fwaSortsFirst() public view {
        assertEq(Currency.unwrap(key.currency0), FWA);
    }
}
