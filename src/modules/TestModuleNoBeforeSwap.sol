// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";

import {IHookMeshModule} from "../interfaces/IHookMeshModule.sol";

import {TestModuleNoBeforeSwapStorage} from "../libraries/TestModuleNoBeforeSwapStorage.sol";


// contract TestModuleNoBeforeSwap is IHookMeshModule { // TestModuleNoBeforeSwap lacks beforeSwapModule as specified in IHookMeshModule, and hence cannot implement IHookMeshModule

contract TestModuleNoBeforeSwap {

    /*//////////////////////////////////////////////////////////////
                              CONSTANTS
    //////////////////////////////////////////////////////////////*/

    bytes32 internal constant MODULE_ID =
        keccak256("hookmesh.test-module-no-before-swap");

    bytes32 internal constant STORAGE_NAMESPACE =
        keccak256(
            abi.encode(
                keccak256("hookmesh.storage"),
                MODULE_ID
            )
        );

    /*//////////////////////////////////////////////////////////////
                              OWNERSHIP
    //////////////////////////////////////////////////////////////*/

    address public immutable  owner;

    /*//////////////////////////////////////////////////////////////
                           CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor() {
        owner = msg.sender;
    }

    /*//////////////////////////////////////////////////////////////
                          MODULE METADATA
    //////////////////////////////////////////////////////////////*/

    function moduleId()
        external
        pure
        returns (bytes32)
    {
        return MODULE_ID;
    }

    function moduleVersion()
        external
        pure
        returns (uint256)
    {
        return 1;
    }

    function storageNamespace()
        external
        pure
        returns (bytes32)
    {
        return STORAGE_NAMESPACE;
    }

    /*
     * This module deliberately advertises NO lifecycle.
     */
    function lifecycleMask()
        external
        pure
        returns (uint256)
    {
        return 0;
    }

    function supportsHookMesh()
        external
        pure
        returns (bytes4)
    {
        return IHookMeshModule.supportsHookMesh.selector;
    }

    function getModuleState()
        external
        view
        returns (uint256)
    {
        return TestModuleNoBeforeSwapStorage
            .layout()
            .calls;
    }

    /*
     * No beforeSwapModule() implementation is required because
     * this module does not advertise BEFORE_SWAP support.
     */
}