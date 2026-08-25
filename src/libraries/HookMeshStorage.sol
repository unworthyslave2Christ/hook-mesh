// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

library HookMeshStorage {

    /*//////////////////////////////////////////////////////////////
                              STORAGE
    //////////////////////////////////////////////////////////////*/

    bytes32 internal constant STORAGE_LOCATION =
        keccak256("hookmesh.core.storage");

    /*//////////////////////////////////////////////////////////////
                         MODULE RECORD
    //////////////////////////////////////////////////////////////*/

    struct ModuleRecord {
        address implementation;
        bytes32 moduleId;
        bytes32 namespace;
        uint256 lifecycleMask;
        bool enabled;
    }

    /*//////////////////////////////////////////////////////////////
                        LIFECYCLE FAILURE
    //////////////////////////////////////////////////////////////*/

    struct LifecycleFailure {
        bytes32 moduleId;
        address implementation;
        uint256 lifecycleFlag;
        bytes revertData;
    }

    /*//////////////////////////////////////////////////////////////
                              LAYOUT
    //////////////////////////////////////////////////////////////*/

    struct Layout {

        /*
         * Registered module count.
         */
        uint256 moduleCount;

        /*
         * 1-based module registry.
         */
        mapping(uint256 => ModuleRecord) modules;

        /*
         * moduleId => module index.
         */
        mapping(bytes32 => uint256) moduleById;

        /*
         * namespace => module implementation.
         */
        mapping(bytes32 => address) namespaceOwner;

        /*
         * Number of modules that failed during the most
         * recently executed lifecycle operation.
         */
        uint256 lastLifecycleFailureCount;

        /*
         * Failure information from the most recently executed
         * lifecycle operation.
         *
         * The array is represented as a mapping because the
         * number of failures is dynamic.
         */
        mapping(uint256 => LifecycleFailure) lastLifecycleFailures;
    }

    /*//////////////////////////////////////////////////////////////
                               ACCESSOR
    //////////////////////////////////////////////////////////////*/

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