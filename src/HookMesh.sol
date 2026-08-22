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
import {BaseHook} from "v4-hooks-public/src/utils/BaseHook.sol";



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

    error HookMesh__DelegateCallFailed();

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

        permissions.beforeSwap = true;

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
         * Verify that the implementation explicitly declares
         * HookMesh compatibility.
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
         * A storage namespace can only belong to one
         * implementation.
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

        s.modules[index] =
            HookMeshStorage.ModuleRecord({
                implementation: implementation,
                moduleId: moduleId,
                namespace: namespace,
                lifecycleMask: lifecycleMask,

                /*
                 * Registration automatically enables the module.
                 */
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

    /**
     * @notice Enable a previously registered module.
     *
     * Only the owner reported by the module implementation may
     * enable it.
     */
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

    /**
     * @notice Disable a previously registered module.
     *
     * Only the owner reported by the module implementation may
     * disable it.
     */
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
     * @dev Executes a module only when:
     *
     *      1. the module is enabled; and
     *      2. the module declares support for the lifecycle.
     *
     * This function deliberately performs the checks inside
     * HookMesh rather than relying on the implementation.
     */
    function _executeModule(
        HookMeshStorage.ModuleRecord storage module,
        uint256 lifecycleFlag,
        bytes memory callData
    )
        internal
        returns (bytes memory returnData)
    {
        /*
         * Runtime enable/disable gate.
         */
        if (!module.enabled) {
            return "";
        }

        /*
         * Lifecycle capability gate.
         *
         * Example:
         *
         * lifecycleMask = BEFORE_SWAP_FLAG
         *
         * means:
         *
         * lifecycleMask & BEFORE_SWAP_FLAG != 0
         *
         * and therefore beforeSwap may execute.
         */
        if (
            (module.lifecycleMask & lifecycleFlag) == 0
        ) {
            return "";
        }

        /*
         * delegatecall deliberately preserves msg.sender.
         *
         * PoolManager
         *      ↓
         * HookMesh
         *      ↓ delegatecall
         * Module
         *
         * Therefore the module observes PoolManager as
         * msg.sender.
         */
        (
            bool success,
            bytes memory data
        ) =
            module.implementation.delegatecall(
                callData
            );

        if (!success) {
            /*
             * Bubble the original module revert data rather
             * than hiding the module's failure behind a generic
             * error.
             */
            assembly {
                revert(
                    add(data, 0x20),
                    mload(data)
                )
            }
        }

        returnData = data;
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
        override
        returns (
            bytes4,
            BeforeSwapDelta,
            uint24
        )
    {
        if (
            msg.sender != address(poolManager)
        ) {
            revert HookMesh__NotPoolManager();
        }

        HookMeshStorage.Layout storage s =
            HookMeshStorage.layout();

        /*
         * Every registered module is considered.
         *
         * _executeModule() performs:
         *
         *     enabled check
         *     lifecycle-mask check
         *     delegatecall
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
         * HookMesh itself does not modify the swap delta or
         * dynamic fee in this routing test.
         *
         * Therefore return the standard zero values.
         */
        return (
            IHooks.beforeSwap.selector,
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
        return HookMeshStorage
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
            HookMeshStorage.layout().modules[index];

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
        return HookMeshStorage
            .layout()
            .namespaceOwner[namespace];
    }

    /*//////////////////////////////////////////////////////////////
                         MODULE STATE
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Executes the registered module's getModuleState()
     *         function using delegatecall.
     *
     * This is primarily useful for the TestModule integration
     * tests.
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

        /*
         * State inspection is deliberately independent of
         * enabled/lifecycle execution status.
         *
         * A disabled module's state must still be readable.
         */
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

        return data;
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

    /*//////////////////////////////////////////////////////////////
                        UNSUPPORTED HOOKS
    //////////////////////////////////////////////////////////////*/

    function beforeInitialize(
        address,
        PoolKey calldata,
        uint160
    )
        external
        pure
        override
        returns (bytes4)
    {
        revert HookMesh__InvalidModule();
    }

    function afterInitialize(
        address,
        PoolKey calldata,
        uint160,
        int24
    )
        external
        pure
        override
        returns (bytes4)
    {
        revert HookMesh__InvalidModule();
    }

    // fS

    // function afterAddLiquidity(
    //     address,
    //     PoolKey calldata,
    //     IPoolManager.ModifyLiquidityParams calldata,
    //     BalanceDelta,
    //     BalanceDelta,
    //     bytes calldata
    // )
    //     external
    //     pure
    //     override
    //     returns (
    //         bytes4,
    //         BalanceDelta
    //     )
    // {
    //     revert HookMesh__InvalidModule();
    // }

    // function beforeRemoveLiquidity(
    //     address,
    //     PoolKey calldata,
    //     IPoolManager.ModifyLiquidityParams calldata,
    //     bytes calldata
    // )
    //     external
    //     pure
    //     override
    //     returns (
    //         bytes4,
    //         BeforeSwapDelta
    //     )
    // {
    //     revert HookMesh__InvalidModule();
    // }

    // function afterRemoveLiquidity(
    //     address,
    //     PoolKey calldata,
    //     IPoolManager.ModifyLiquidityParams calldata,
    //     BalanceDelta,
    //     BalanceDelta,
    //     bytes calldata
    // )
    //     external
    //     pure
    //     override
    //     returns (
    //         bytes4,
    //         BalanceDelta
    //     )
    // {
    //     revert HookMesh__InvalidModule();
    // }

    // function afterSwap(
    //     address,
    //     PoolKey calldata,
    //     IPoolManager.SwapParams calldata,
    //     BalanceDelta,
    //     bytes calldata
    // )
    //     external
    //     pure
    //     override
    //     returns (bytes4, int128)
    // {
    //     revert HookMesh__InvalidModule();
    // }

    function beforeDonate(
        address,
        PoolKey calldata,
        uint256,
        uint256,
        bytes calldata
    )
        external
        pure
        override
        returns (bytes4)
    {
        revert HookMesh__InvalidModule();
    }

    function afterDonate(
        address,
        PoolKey calldata,
        uint256,
        uint256,
        bytes calldata
    )
        external
        pure
        override
        returns (bytes4)
    {
        revert HookMesh__InvalidModule();
    }
}