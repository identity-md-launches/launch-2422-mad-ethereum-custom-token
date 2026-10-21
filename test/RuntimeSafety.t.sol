// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {MadTestBase} from "./Base.t.sol";

contract RuntimeSafetyTest is MadTestBase {
    function test_noRuntimeEscapeHatches() public view {
        _scan(address(token));
        _scan(address(hook));
        _scan(address(rewards));
    }

    function _scan(address target) private view {
        bytes memory code = target.code;
        assertGt(code.length, 0);
        assertLe(code.length, 24_576);
        bool reachable = true;
        for (uint256 i; i < code.length; ++i) {
            uint8 op = uint8(code[i]);
            if (op == 0x5b) reachable = true;
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x60 + 1;
                continue;
            }
            if (reachable) assertTrue(op != 0xff && op != 0xf4 && op != 0xf2, "runtime escape opcode");
            if (op == 0x00 || op == 0x56 || op == 0xf3 || op == 0xfd || op == 0xfe || op == 0xff) reachable = false;
        }
    }
}
