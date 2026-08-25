// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";

import {IHookMeshModule} from "../interfaces/IHookMeshModule.sol";

// import {TestModuleStorage} from "../libraries/TestModuleStorage.sol";

import {console2} from "forge-std/console2.sol";



// contract RevertingTestModule is IHookMeshModule {
contract RevertingTestModule {

    bytes32 internal constant MODULE_ID =
        keccak256("hookmesh.reverting-test-module");

    bytes32 internal constant STORAGE_NAMESPACE =
        keccak256(
            abi.encode(
                keccak256("hookmesh.storage"),
                MODULE_ID
            )
        );

    address public immutable owner;

    uint256 internal constant BEFORE_SWAP_FLAG = 1 << 7;

    constructor() {
        owner = msg.sender;
    }

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

    function beforeSwapModule(
        address,
        PoolKey calldata,
        IPoolManager.SwapParams calldata,
        bytes calldata
    )
        external
        pure
        returns (bytes memory)
    {
        revert("TEST_MODULE_REVERTED");
    }
}