// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {
    BeforeSwapDelta,
    BeforeSwapDeltaLibrary
} from "v4-core/src/types/BeforeSwapDelta.sol";

import {IHookMeshModule} from "./interfaces/IHookMeshModule.sol";
import {HookMeshStorage} from "./libraries/HookMeshStorage.sol";
import {TestModuleStorage} from "./libraries/TestModuleStorage.sol";

contract HookMesh {
    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error HookMesh__NotPoolManager();
    error HookMesh__InvalidModule();
    error HookMesh__ModuleAlreadyRegistered();
    error HookMesh__NamespaceAlreadyRegistered();
    error HookMesh__InvalidModuleInterface();
    error HookMesh__InvalidNamespace();

    /*//////////////////////////////////////////////////////////////
                            CONSTANTS
    //////////////////////////////////////////////////////////////*/

    // uint256 internal constant BEFORE_SWAP_FLAG = 1 << 0;
    uint256 internal constant BEFORE_SWAP_FLAG = 1 << 7;

    bytes32 internal constant STORAGE_NAMESPACE_PREFIX =
        keccak256("hookmesh.storage");

    /*//////////////////////////////////////////////////////////////
                              STORAGE
    //////////////////////////////////////////////////////////////*/

    IPoolManager public immutable poolManager;

    /*//////////////////////////////////////////////////////////////
                              MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) {
            revert HookMesh__NotPoolManager();
        }

        _;
    }

    /*//////////////////////////////////////////////////////////////
                            CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(address _poolManager) {
        poolManager = IPoolManager(_poolManager);

        Hooks.validateHookPermissions(
            IHooks(address(this)),
            getHookPermissions()
        );
    }

    /*//////////////////////////////////////////////////////////////
                        HOOK PERMISSIONS
    //////////////////////////////////////////////////////////////*/

    function getHookPermissions()
        public
        pure
        returns (Hooks.Permissions memory)
    {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,

            beforeAddLiquidity: false,
            afterAddLiquidity: false,

            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,

            beforeSwap: true,
            afterSwap: false,

            beforeDonate: false,
            afterDonate: false,

            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,

            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    /*//////////////////////////////////////////////////////////////
                        MODULE REGISTRATION
    //////////////////////////////////////////////////////////////*/

    function registerModule(
        address module
    ) external returns (uint256 moduleIndex) {
        if (module.code.length == 0) {    // Every module should be a contract
            revert HookMesh__InvalidModule();
        }

        IHookMeshModule candidate =
            IHookMeshModule(module);

        bytes4 supportedInterface;

        try candidate.supportsHookMesh()
            returns (bytes4 value)
        {
            supportedInterface = value;
        } catch {
            revert HookMesh__InvalidModuleInterface();
        }

        if (
            supportedInterface !=
            IHookMeshModule.supportsHookMesh.selector
        ) {
            revert HookMesh__InvalidModuleInterface();
        }

        bytes32 id = candidate.moduleId();
        bytes32 namespace = candidate.storageNamespace();

        bytes32 expectedNamespace =
            keccak256(
                abi.encode(
                    STORAGE_NAMESPACE_PREFIX,
                    id
                )
            );

        if (namespace != expectedNamespace) {
            revert HookMesh__InvalidNamespace();
        }

        HookMeshStorage.Layout storage s =
            HookMeshStorage.layout();

        if (s.moduleById[id] != 0) {
            revert HookMesh__ModuleAlreadyRegistered();
        }

        if (s.namespaceOwner[namespace] != address(0)) {
            revert HookMesh__NamespaceAlreadyRegistered();
        }

        moduleIndex = ++s.moduleCount;

        s.modules[moduleIndex] = HookMeshStorage.ModuleRecord({
            implementation: module,
            moduleId: id,
            namespace: namespace,
            lifecycleMask: candidate.lifecycleMask(),
            enabled: true
        });

        s.moduleById[id] = moduleIndex;
        s.namespaceOwner[namespace] = module;
    }

    /*//////////////////////////////////////////////////////////////
                            BEFORE SWAP
    //////////////////////////////////////////////////////////////*/

    function beforeSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        bytes calldata hookData
    )
        external
        onlyPoolManager
        returns (
            bytes4,
            BeforeSwapDelta,
            uint24
        )
    {
        HookMeshStorage.Layout storage s =
            HookMeshStorage.layout();

        for (uint256 i = 1; i <= s.moduleCount; i++) {
            HookMeshStorage.ModuleRecord storage module =
                s.modules[i];

            if (!module.enabled) {
                continue;
            }

            if (
                module.lifecycleMask & BEFORE_SWAP_FLAG
                    == 0
            ) {
                continue;
            }

            bytes memory callData = abi.encodeCall(
                IHookMeshModule.beforeSwapModule,
                (
                    sender,
                    key,
                    params,
                    hookData
                )
            );

            (
                bool success,
                bytes memory result
            ) = module.implementation.delegatecall(callData);

            if (!success) {
                assembly {
                    revert(
                        add(result, 32),
                        mload(result)
                    )
                }
            }

            // Result composition is intentionally deferred.
            //
            // For this first milestone we are proving:
            //
            // PoolManager
            //      ↓
            // HookMesh
            //      ↓ delegatecall
            // Module
            //
            // The module executes inside HookMesh's
            // storage context.
            result;
        }

        return (
            IHooks.beforeSwap.selector,
            BeforeSwapDeltaLibrary.ZERO_DELTA,
            0
        );
    }

    /*//////////////////////////////////////////////////////////////
                    TEST-ONLY STORAGE INSPECTION
    //////////////////////////////////////////////////////////////*/

    function getModuleState(
        bytes32 moduleId
    )
        external
        returns (bytes memory state)
    {
        HookMeshStorage.Layout storage s =
            HookMeshStorage.layout();

        uint256 moduleIndex = s.moduleById[moduleId];

        if (moduleIndex == 0) {
            revert HookMesh__InvalidModule();
        }

        HookMeshStorage.ModuleRecord storage module =
            s.modules[moduleIndex];

        if (!module.enabled) {
            revert HookMesh__InvalidModule();
        }

        (bool success, bytes memory result) =
            module.implementation.delegatecall(
                abi.encodeCall(
                    IHookMeshModule.getModuleState,
                    ()
                )
            );

        if (!success) {
            assembly {
                revert(
                    add(result, 32),
                    mload(result)
                )
            }
        }

        return abi.decode(result, (bytes));
    }

    /*//////////////////////////////////////////////////////////////
                          REGISTRY READERS
    //////////////////////////////////////////////////////////////*/

    function moduleCount()
        external
        view
        returns (uint256)
    {
        return HookMeshStorage.layout().moduleCount;
    }

    function getModule(
        uint256 index
    )
        external
        view
        returns (
            address implementation,
            bytes32 moduleId,
            bytes32 namespace,
            uint256 lifecycleMask,
            bool enabled
        )
    {
        HookMeshStorage.ModuleRecord storage module =
            HookMeshStorage.layout().modules[index];

        return (
            module.implementation,
            module.moduleId,
            module.namespace,
            module.lifecycleMask,
            module.enabled
        );
    }

    function namespaceOwner(
        bytes32 namespace
    )
        external
        view
        returns (address)
    {
        return HookMeshStorage
            .layout()
            .namespaceOwner[namespace];
    }
}