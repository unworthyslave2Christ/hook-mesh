// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";

import {
    BeforeSwapDelta,
    BeforeSwapDeltaLibrary
} from "v4-core/src/types/BeforeSwapDelta.sol";

import {IHookMeshModule} from "./interfaces/IHookMeshModule.sol";
import {HookMeshStorage} from "./libraries/HookMeshStorage.sol";


contract HookMesh {

    /*//////////////////////////////////////////////////////////////
                              CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint256 internal constant BEFORE_SWAP_FLAG =
        1 << 7;

    /*//////////////////////////////////////////////////////////////
                              IMMUTABLES
    //////////////////////////////////////////////////////////////*/

    IPoolManager public immutable poolManager;

    /*//////////////////////////////////////////////////////////////
                               EVENTS
    //////////////////////////////////////////////////////////////*/

    event ModuleRegistered(
        uint256 indexed index,
        bytes32 indexed moduleId,
        address indexed implementation,
        bytes32 namespace,
        uint256 lifecycleMask,
        address owner
    );

    event ModuleEnabled(
        bytes32 indexed moduleId,
        address indexed owner
    );

    event ModuleDisabled(
        bytes32 indexed moduleId,
        address indexed owner
    );

    /*
     * Emitted when an eligible module reverts during a
     * lifecycle operation.
     *
     * Importantly, this event does NOT cause the lifecycle
     * operation itself to revert.
     */
    event ModuleLifecycleFailed(
        bytes32 indexed moduleId,
        address indexed implementation,
        uint256 indexed lifecycleFlag,
        bytes revertData
    );

    /*//////////////////////////////////////////////////////////////
                               ERRORS
    //////////////////////////////////////////////////////////////*/

    error HookMesh__NotPoolManager();

    error HookMesh__ModuleAlreadyRegistered();

    error HookMesh__ModuleNotRegistered();

    error HookMesh__InvalidModule();

    error HookMesh__InvalidModuleId();

    error HookMesh__InvalidNamespace();

    error HookMesh__NamespaceAlreadyOwned();

    error HookMesh__NotModuleOwner();

    error HookMesh__ModuleAlreadyEnabled();

    error HookMesh__ModuleAlreadyDisabled();

    error HookMesh__InvalidModuleImplementation();

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(
        address _poolManager
    ) {
        poolManager =
            IPoolManager(_poolManager);
    }

    /*//////////////////////////////////////////////////////////////
                          HOOK PERMISSIONS
    //////////////////////////////////////////////////////////////*/

    /*
     * HookMesh currently participates only in BEFORE_SWAP.
     *
     * This is metadata describing the lifecycle operation
     * exposed by HookMesh to PoolManager.
     */
    function getHookPermissions()
        public
        pure
        returns (
            Hooks.Permissions memory permissions
        )
    {
        permissions.beforeInitialize = false;
        permissions.afterInitialize = false;

        permissions.beforeAddLiquidity = false;
        permissions.afterAddLiquidity = false;

        permissions.beforeRemoveLiquidity = false;
        permissions.afterRemoveLiquidity = false;

        permissions.beforeSwap = true;
        permissions.afterSwap = false;

        permissions.beforeDonate = false;
        permissions.afterDonate = false;

        permissions.beforeSwapReturnDelta = false;
        permissions.afterSwapReturnDelta = false;

        permissions.afterAddLiquidityReturnDelta = false;
        permissions.afterRemoveLiquidityReturnDelta = false;

        return permissions;
    }

    /*//////////////////////////////////////////////////////////////
                         MODULE REGISTRATION
    //////////////////////////////////////////////////////////////*/

    function registerModule(
        address implementation
    )
        external
        returns (uint256 index)
    {
        if (
            implementation == address(0) ||
            implementation.code.length == 0
        ) {
            revert HookMesh__InvalidModuleImplementation();
        }

        IHookMeshModule module =
            IHookMeshModule(implementation);

        /*
         * The implementation must explicitly identify itself
         * as a HookMesh module.
         */
        if (
            module.supportsHookMesh()
                != IHookMeshModule.supportsHookMesh.selector
        ) {
            revert HookMesh__InvalidModule();
        }

        bytes32 moduleId =
            module.moduleId();

        if (moduleId == bytes32(0)) {
            revert HookMesh__InvalidModuleId();
        }

        bytes32 namespace =
            module.storageNamespace();

        if (namespace == bytes32(0)) {
            revert HookMesh__InvalidNamespace();
        }

        HookMeshStorage.Layout storage s =
            HookMeshStorage.layout();

        /*
         * A module ID can only be registered once.
         */
        if (
            s.moduleById[moduleId] != 0
        ) {
            revert HookMesh__ModuleAlreadyRegistered();
        }

        /*
         * A namespace can only belong to one module.
         */
        if (
            s.namespaceOwner[namespace] != address(0)
        ) {
            revert HookMesh__NamespaceAlreadyOwned();
        }

        uint256 lifecycleMask =
            module.lifecycleMask();

        index =
            ++s.moduleCount;

        /*
         * Registration automatically enables the module.
         */
        s.modules[index] =
            HookMeshStorage.ModuleRecord({
                implementation: implementation,
                moduleId: moduleId,
                namespace: namespace,
                lifecycleMask: lifecycleMask,
                enabled: true
            });

        s.moduleById[moduleId] =
            index;

        s.namespaceOwner[namespace] =
            implementation;

        emit ModuleRegistered(
            index,
            moduleId,
            implementation,
            namespace,
            lifecycleMask,
            module.owner()
        );
    }

    /*//////////////////////////////////////////////////////////////
                         MODULE ENABLE / DISABLE
    //////////////////////////////////////////////////////////////*/

    function enableModule(
        bytes32 moduleId
    )
        external
    {
        HookMeshStorage.Layout storage s =
            HookMeshStorage.layout();

        uint256 index =
            s.moduleById[moduleId];

        if (index == 0) {
            revert HookMesh__ModuleNotRegistered();
        }

        HookMeshStorage.ModuleRecord storage module =
            s.modules[index];

        _requireModuleOwner(
            module.implementation
        );

        if (module.enabled) {
            revert HookMesh__ModuleAlreadyEnabled();
        }

        module.enabled = true;

        emit ModuleEnabled(
            moduleId,
            msg.sender
        );
    }

    function disableModule(
        bytes32 moduleId
    )
        external
    {
        HookMeshStorage.Layout storage s =
            HookMeshStorage.layout();

        uint256 index =
            s.moduleById[moduleId];

        if (index == 0) {
            revert HookMesh__ModuleNotRegistered();
        }

        HookMeshStorage.ModuleRecord storage module =
            s.modules[index];

        _requireModuleOwner(
            module.implementation
        );

        if (!module.enabled) {
            revert HookMesh__ModuleAlreadyDisabled();
        }

        module.enabled = false;

        emit ModuleDisabled(
            moduleId,
            msg.sender
        );
    }

    /*//////////////////////////////////////////////////////////////
                         MODULE EXECUTION
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Attempts to execute one module for a lifecycle.
     *
     * A module executes only when:
     *
     *      1. it is enabled; and
     *      2. it advertises support for the lifecycle.
     *
     * If the module reverts:
     *
     *      - its failure is captured;
     *      - its revert data is recorded;
     *      - its failure is emitted;
     *      - the HookMesh lifecycle does NOT revert;
     *      - execution proceeds to the next module.
     */
    function _executeModule(
        HookMeshStorage.ModuleRecord storage module,
        uint256 lifecycleFlag,
        bytes memory callData
    )
        internal
    {
        /*
         * Disabled modules are silently skipped.
         */
        if (!module.enabled) {
            return;
        }

        /*
         * Modules that do not advertise this lifecycle are
         * also skipped.
         */
        if (
            (module.lifecycleMask & lifecycleFlag) == 0
        ) {
            return;
        }

        /*
         * delegatecall preserves the original msg.sender.
         *
         * PoolManager
         *      ↓
         * HookMesh
         *      ↓ delegatecall
         * Module
         *
         * msg.sender therefore remains PoolManager.
         */
        (
            bool success,
            bytes memory data
        ) =
            module.implementation.delegatecall(
                callData
            );

        /*
         * IMPORTANT:
         *
         * Do NOT bubble the revert.
         *
         * The purpose of HookMesh is composition. One failing
         * module must not prevent unrelated modules from
         * participating in the same lifecycle operation.
         */
        if (!success) {

            HookMeshStorage.Layout storage s =
                HookMeshStorage.layout();

            uint256 failureIndex =
                s.lastLifecycleFailureCount;

            s.lastLifecycleFailures[
                failureIndex
            ] =
                HookMeshStorage.LifecycleFailure({
                    moduleId: module.moduleId,
                    implementation: module.implementation,
                    lifecycleFlag: lifecycleFlag,
                    revertData: data
                });

            s.lastLifecycleFailureCount =
                failureIndex + 1;

            emit ModuleLifecycleFailed(
                module.moduleId,
                module.implementation,
                lifecycleFlag,
                data
            );

            /*
             * Deliberately return instead of reverting.
             *
             * The next registered module must still be given
             * an opportunity to execute.
             */
            return;
        }
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
        returns (
            bytes4,
            BeforeSwapDelta,
            uint24
        )
    {
        /*
         * Only PoolManager may invoke the lifecycle operation.
         */
        if (
            msg.sender != address(poolManager)
        ) {
            revert HookMesh__NotPoolManager();
        }

        HookMeshStorage.Layout storage s =
            HookMeshStorage.layout();

        /*
         * A lifecycle invocation begins here.
         *
         * Previous lifecycle failure information must not be
         * confused with the current invocation.
         */
        s.lastLifecycleFailureCount = 0;

        /*
         * Execute every registered module.
         *
         * _executeModule() independently handles:
         *
         *      - enabled state;
         *      - lifecycle capability;
         *      - delegatecall;
         *      - failure recording.
         *
         * Therefore a failure in module N does not prevent
         * module N+1 from executing.
         */
        for (
            uint256 i = 1;
            i <= s.moduleCount;
            i++
        ) {
            HookMeshStorage.ModuleRecord storage module =
                s.modules[i];

            _executeModule(
                module,
                BEFORE_SWAP_FLAG,
                abi.encodeCall(
                    IHookMeshModule.beforeSwapModule,
                    (
                        sender,
                        key,
                        params,
                        hookData
                    )
                )
            );
        }

        /*
         * Lifecycle return formulation currently remains
         * deliberately neutral.
         *
         * Individual module failures are recorded and emitted,
         * but are NOT inserted into the PoolManager return tuple.
         *
         * This leaves room for the eventual HookMesh lifecycle
         * aggregation model.
         *
         * msg.sig is used instead of IHooks.beforeSwap.selector,
         * so HookMesh does not need to implement/inherit IHooks.
         */
        return (
            msg.sig,
            BeforeSwapDeltaLibrary.ZERO_DELTA,
            0
        );
    }

    /*//////////////////////////////////////////////////////////////
                         MODULE INFORMATION
    //////////////////////////////////////////////////////////////*/

    function moduleCount()
        external
        view
        returns (uint256)
    {
        return
            HookMeshStorage
                .layout()
                .moduleCount;
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
            HookMeshStorage
                .layout()
                .modules[index];

        return (
            module.implementation,
            module.moduleId,
            module.namespace,
            module.lifecycleMask,
            module.enabled
        );
    }

    function getModuleById(
        bytes32 moduleId
    )
        external
        view
        returns (
            address implementation,
            bytes32 namespace,
            uint256 lifecycleMask,
            bool enabled
        )
    {
        HookMeshStorage.Layout storage s =
            HookMeshStorage.layout();

        uint256 index =
            s.moduleById[moduleId];

        if (index == 0) {
            revert HookMesh__ModuleNotRegistered();
        }

        HookMeshStorage.ModuleRecord storage module =
            s.modules[index];

        return (
            module.implementation,
            module.namespace,
            module.lifecycleMask,
            module.enabled
        );
    }

    function isModuleEnabled(
        bytes32 moduleId
    )
        external
        view
        returns (bool)
    {
        HookMeshStorage.Layout storage s =
            HookMeshStorage.layout();

        uint256 index =
            s.moduleById[moduleId];

        if (index == 0) {
            return false;
        }

        return s.modules[index].enabled;
    }

    function moduleSupportsLifecycle(
        bytes32 moduleId,
        uint256 lifecycleFlag
    )
        external
        view
        returns (bool)
    {
        HookMeshStorage.Layout storage s =
            HookMeshStorage.layout();

        uint256 index =
            s.moduleById[moduleId];

        if (index == 0) {
            return false;
        }

        return (
            s.modules[index].lifecycleMask
                & lifecycleFlag
        ) != 0;
    }

    

    function namespaceOwner(
        bytes32 namespace
    )
        external
        view
        returns (address)
    {
        return
            HookMeshStorage
                .layout()
                .namespaceOwner[namespace];
    }

    /*//////////////////////////////////////////////////////////////
                       LIFECYCLE FAILURE STATE
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Number of modules that failed during the most
     *         recently executed lifecycle operation.
     */
    function lastLifecycleFailureCount()
        external
        view
        returns (uint256)
    {
        return
            HookMeshStorage
                .layout()
                .lastLifecycleFailureCount;
    }

    /**
     * @notice Returns information about one module failure from
     *         the most recently executed lifecycle operation.
     */
    function getLastLifecycleFailure(
        uint256 index
    )
        external
        view
        returns (
            bytes32 moduleId,
            address implementation,
            uint256 lifecycleFlag,
            bytes memory revertData
        )
    {
        HookMeshStorage.LifecycleFailure storage failure =
            HookMeshStorage
                .layout()
                .lastLifecycleFailures[index];

        return (
            failure.moduleId,
            failure.implementation,
            failure.lifecycleFlag,
            failure.revertData
        );
    }

    /*//////////////////////////////////////////////////////////////
                          MODULE STATE
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Executes the registered module's getModuleState()
     *         function using delegatecall.
     *
     * This is test/integration functionality and is independent
     * of whether the module is currently enabled.
     */
    function getModuleState(
        bytes32 moduleId
    )
        external
        returns (bytes memory)
    {
        HookMeshStorage.Layout storage s =
            HookMeshStorage.layout();

        uint256 index =
            s.moduleById[moduleId];

        if (index == 0) {
            revert HookMesh__ModuleNotRegistered();
        }

        HookMeshStorage.ModuleRecord storage module =
            s.modules[index];

        (
            bool success,
            bytes memory data
        ) =
            module.implementation.delegatecall(
                abi.encodeWithSignature(
                    "getModuleState()"
                )
            );

        if (!success) {
            assembly {
                revert(
                    add(data, 0x20),
                    mload(data)
                )
            }
        }

        return abi.decode(data, (bytes));
    }

    /*//////////////////////////////////////////////////////////////
                           AUTHORIZATION
    //////////////////////////////////////////////////////////////*/

    function _requireModuleOwner(
        address implementation
    )
        internal
        view
    {
        address moduleOwner =
            IHookMeshModule(implementation)
                .owner();

        if (
            msg.sender != moduleOwner
        ) {
            revert HookMesh__NotModuleOwner();
        }
    }
}