// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

library HookMeshStorage {
    bytes32 internal constant STORAGE_LOCATION =
        keccak256("hookmesh.core.storage");

    struct ModuleRecord {
        address implementation;
        bytes32 moduleId;
        bytes32 namespace;
        uint256 lifecycleMask;
        bool enabled;
    }

    struct Layout {
        uint256 moduleCount;

        mapping(uint256 => ModuleRecord) modules;

        // moduleId => module index
        mapping(bytes32 => uint256) moduleById;

        // namespace => module implementation
        mapping(bytes32 => address) namespaceOwner;
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