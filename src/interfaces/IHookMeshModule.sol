// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";

interface IHookMeshModule {
    function moduleId()
        external
        pure
        returns (bytes32);

    function moduleVersion()
        external
        pure
        returns (uint256);

    function storageNamespace()
        external
        pure
        returns (bytes32);

    function lifecycleMask()
        external
        pure
        returns (uint256);

    function supportsHookMesh()
        external
        pure
        returns (bytes4);

    function beforeSwapModule(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        bytes calldata hookData
    ) external returns (bytes memory);

    function getModuleState()
        external
        returns (bytes memory);
}