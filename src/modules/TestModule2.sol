// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";

import {IHookMeshModule} from "../interfaces/IHookMeshModule.sol";
import {TestModuleStorage2} from "../libraries/TestModuleStorage2.sol";
import {console2} from "forge-std/console2.sol";

contract TestModule2 is IHookMeshModule {

    /*//////////////////////////////////////////////////////////////
                              CONSTANTS
    //////////////////////////////////////////////////////////////*/

    bytes32 internal constant MODULE_ID =
        keccak256("hookmesh.test-module-2");

    bytes32 internal constant STORAGE_NAMESPACE =
        keccak256(
            abi.encode(
                keccak256("hookmesh.storage"),
                MODULE_ID
            )
        );

    uint256 internal constant BEFORE_SWAP_FLAG =
        1 << 7;

    /*//////////////////////////////////////////////////////////////
                              OWNERSHIP
    //////////////////////////////////////////////////////////////*/

    address public immutable override owner;

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
        TestModuleStorage2.Layout storage s =
            TestModuleStorage2.layout();

        s.beforeSwapCalls++;

        console2.log(
            "s.beforeSwapCalls: ",
            s.beforeSwapCalls
        );

        /*
         * Because HookMesh invokes this function through
         * delegatecall, msg.sender remains the original caller
         * of HookMesh.
         *
         * In the integration test this is PoolManager.
         */
        s.lastSender = msg.sender;

        s.lastValue = 123456;

        return "";
    }

    /*//////////////////////////////////////////////////////////////
                           TEST STATE
    //////////////////////////////////////////////////////////////*/

    function getModuleState()
        external
        view
        returns (bytes memory)
    {
        TestModuleStorage2.Layout storage s =
            TestModuleStorage2.layout();

        return abi.encode(
            s.beforeSwapCalls,
            s.lastSender,
            s.lastValue
        );
    }
}