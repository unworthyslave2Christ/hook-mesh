// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";

import {IHookMeshModule} from "../interfaces/IHookMeshModule.sol";
import {TestModuleStorage} from "../libraries/TestModuleStorage.sol";
import {console2} from "forge-std/console2.sol";

contract TestModule is IHookMeshModule {

    /*//////////////////////////////////////////////////////////////
                              CONSTANTS
    //////////////////////////////////////////////////////////////*/

    bytes32 internal constant MODULE_ID =
        keccak256("hookmesh.test-module");

    bytes32 internal constant STORAGE_NAMESPACE =
        keccak256(
            abi.encode(
                keccak256("hookmesh.storage"),
                MODULE_ID
            )
        );

    uint256 internal constant BEFORE_SWAP_FLAG = 1 << 7;

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

    function lifecycleMask()
        external
        pure
        returns (uint256)
    {
        return BEFORE_SWAP_FLAG;
    }

    function supportsHookMesh()
        external
        pure
        returns (bytes4)
    {
        return IHookMeshModule.supportsHookMesh.selector;
    }

    /*//////////////////////////////////////////////////////////////
                           BEFORE SWAP
    //////////////////////////////////////////////////////////////*/

    function beforeSwapModule(
        address,
        PoolKey calldata,
        IPoolManager.SwapParams calldata,
        bytes calldata
    )
        external
        returns (bytes memory)
    {
        TestModuleStorage.Layout storage s =
            TestModuleStorage.layout();

        s.beforeSwapCalls++;
        console2.log("s.beforeSwapCalls: ", s.beforeSwapCalls);

        /*
         * This is the critical assertion we are proving.
         *
         * Because HookMesh uses delegatecall:
         *
         * msg.sender is still PoolManager.
         */
        s.lastSender = msg.sender;

        s.lastValue = 123456;

        return "";
    }

    function getModuleState()
        external
        returns (bytes memory)
    {
        TestModuleStorage.Layout storage s =
            TestModuleStorage.layout();

        return abi.encode(
            s.beforeSwapCalls,
            s.lastSender,
            s.lastValue
        );
    }
}