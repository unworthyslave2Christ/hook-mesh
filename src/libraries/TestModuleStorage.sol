// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

library TestModuleStorage {
    bytes32 internal constant STORAGE_LOCATION =
        keccak256("hookmesh.module.test");

    struct Layout {
        uint256 beforeSwapCalls;
        address lastSender;
        uint256 lastValue;
    }

    function layout()
        internal
        pure
        returns (Layout storage l)
    {
        bytes32 slot = STORAGE_LOCATION;

        assembly {
            l.slot := slot
        }
    }
}