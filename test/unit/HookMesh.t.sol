// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";

import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";

import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";

import {HookMiner} from "../../src/libraries/HookMiner.sol";
import {HookMesh} from "../../src/HookMesh.sol";

import {TestModule} from "../../src/modules/TestModule.sol";
import {TestModule2} from "../../src/modules/TestModule2.sol";
import {IHookMeshModule} from "../../src/interfaces/IHookMeshModule.sol";


contract HookMeshTest is Test {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;

    /*//////////////////////////////////////////////////////////////
                                STATE
    //////////////////////////////////////////////////////////////*/

    IPoolManager public poolManager;

    HookMesh public hookMesh;
    TestModule public module;
    TestModule2 public module2;

    PoolKey public poolKey;
    PoolId public poolId;

    /*//////////////////////////////////////////////////////////////
                              CONSTANTS
    //////////////////////////////////////////////////////////////*/

    address constant POOL_MANAGER =
        0x000000000004444c5dc75cB358380D2e3dE08A90;

    address constant TOKEN1 =
        address(0x1234);

    uint24 constant FIXED_LP_FEE = 3000; // 0.30%

    int24 constant TICK_SPACING = 60;

    uint160 constant SQRT_PRICE_1_1 =
        79228162514264337593543950336;

    /*//////////////////////////////////////////////////////////////
                                SETUP
    //////////////////////////////////////////////////////////////*/

    function setUp() public {
        /*
         * Use the real Uniswap v4 PoolManager.
         *
         * HookMesh must have the BEFORE_SWAP permission encoded
         * into its address because PoolManager determines hook
         * permissions from the hook address.
         */
        poolManager = IPoolManager(POOL_MANAGER);

        uint160 flags =
            uint160(Hooks.BEFORE_SWAP_FLAG);

        /*
         * Mine a CREATE2 salt that produces a HookMesh address
         * containing the BEFORE_SWAP flag.
         */
        (
            address hookAddress,
            bytes32 salt
        ) = HookMiner.find({
            deployer: address(this),
            flags: flags,
            creationCode: type(HookMesh).creationCode,
            constructorArgs: abi.encode(address(poolManager))
        });

        console2.log(
            "Expected HookMesh address:",
            hookAddress
        );

        /*
         * Deploy HookMesh at the mined address.
         */
        hookMesh =
            new HookMesh{salt: salt}(
                address(poolManager)
            );

        console2.log(
            "Deployed HookMesh:",
            address(hookMesh)
        );

        assertEq(
            address(hookMesh),
            hookAddress
        );

        /*
         * Deploy a module implementing the HookMesh module
         * interface.
         *
         * The module will later be executed through delegatecall.
         */
        module = new TestModule();

        module2 = new TestModule2();

        /*
         * Register module 1 with HookMesh.
         */
        hookMesh.registerModule(
            address(module)
        );

        /*
         * Register module 2 with HookMesh.
         */
        hookMesh.registerModule(
            address(module2)
        );

        /*
         * The important architectural point:
         *
         * The pool is using HookMesh as its actual Uniswap v4
         * hook.
         *
         * The module is NOT known to PoolManager.
         *
         * PoolManager -> HookMesh -> Module
         */
        poolKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(TOKEN1),

            /*
             * This is deliberately a FIXED fee.
             *
             * We are not testing dynamic fee selection yet.
             * The purpose of this test is to establish HookMesh
             * as the routing layer between PoolManager and modules.
             */
            fee: FIXED_LP_FEE,

            tickSpacing: TICK_SPACING,

            hooks: IHooks(address(hookMesh))
        });

        poolId = poolKey.toId();

        /*
         * Initialize the pool.
         *
         * Because HookMesh only has BEFORE_SWAP enabled, no
         * additional initialization callback is expected here.
         */
        poolManager.initialize(
            poolKey,
            SQRT_PRICE_1_1
        );
    }

    /*//////////////////////////////////////////////////////////////
                         BASIC CONFIGURATION
    //////////////////////////////////////////////////////////////*/

    function test_pool_uses_hook_mesh() public view {
        assertEq(
            address(poolKey.hooks),
            address(hookMesh)
        );
    }

    function test_pool_uses_fixed_fee() public view {
        assertEq(
            poolKey.fee,
            FIXED_LP_FEE
        );
    }

    function test_hook_mesh_has_before_swap_permission()
        public
        view
    {
        Hooks.validateHookPermissions(
            IHooks(address(hookMesh)),
            hookMesh.getHookPermissions()
        );
    }

    /*//////////////////////////////////////////////////////////////
                           MODULE REGISTRATION
    //////////////////////////////////////////////////////////////*/

    function test_modules_are_registered()
        public
        view
    {
        assertEq(
            hookMesh.moduleCount(),
            2
        );

        // Checks on first module

        (
            address implementation,
            bytes32 id,
            bytes32 namespace,
            uint256 lifecycleMask,
            bool enabled
        ) = hookMesh.getModule(1);

        assertEq(
            implementation,
            address(module)
        );

        assertEq(
            id,
            module.moduleId()
        );

        assertEq(
            namespace,
            module.storageNamespace()
        );

        /*
         * TestModule currently registers itself for BEFORE_SWAP.
         */
        assertEq(
            lifecycleMask,
            uint256(Hooks.BEFORE_SWAP_FLAG)
        );

        assertTrue(enabled);

        // Checks on second module

        
        (
            address implementation2,
            bytes32 id2,
            bytes32 namespace2,
            uint256 lifecycleMask2,
            bool enabled2
        ) = hookMesh.getModule(2);

        assertEq(
            implementation2,
            address(module2)
        );

        assertEq(
            id2,
            module2.moduleId()
        );

        assertEq(
            namespace2,
            module2.storageNamespace()
        );

        /*
         * TestModule currently registers itself for BEFORE_SWAP.
         */
        assertEq(
            lifecycleMask2,
            uint256(Hooks.BEFORE_SWAP_FLAG)
        );

        assertTrue(enabled2);
    }

    function test_namespace_belongs_to_registered_module()
        public
        view
    {
        assertEq(
            hookMesh.namespaceOwner(
                module.storageNamespace()
            ),
            address(module)
        );
    }

    /*//////////////////////////////////////////////////////////////
                       DIRECT DELEGATECALL TEST
    //////////////////////////////////////////////////////////////*/

    function test_delegatecall_preserves_pool_manager_sender()
        public
    {
        /*
         * Simulate the call that would normally originate from
         * Uniswap v4 PoolManager.
         *
         * At HookMesh:
         *
         *     msg.sender == PoolManager
         *
         * HookMesh then delegatecalls TestModule.
         *
         * Because delegatecall preserves msg.sender:
         *
         *     TestModule msg.sender == PoolManager
         */
        vm.prank(address(poolManager));

        hookMesh.beforeSwap(
            address(this),
            poolKey,
            _swapParams(),
            ""
        );

        (
            uint256 calls,
            address lastSender,
            uint256 lastValue
        ) = hookMesh.testModuleState();

        assertEq(
            calls,
            2
        );

        assertEq(
            lastSender,
            address(poolManager)
        );

        // assertEq(
        //     lastValue,
        //     123456
        // );
    }

    /*//////////////////////////////////////////////////////////////
                     MODULE EXECUTION COUNT
    //////////////////////////////////////////////////////////////*/

    function test_module_executes_once_per_lifecycle_call()
        public
    {
        vm.prank(address(poolManager));

        hookMesh.beforeSwap(
            address(this),
            poolKey,
            _swapParams(),
            ""
        );

        (
            uint256 calls,
            ,
        ) = hookMesh.testModuleState();

        assertEq(
            calls,
            2
        );
    }

    /*//////////////////////////////////////////////////////////////
                       STORAGE PERSISTENCE
    //////////////////////////////////////////////////////////////*/

    function test_delegatecall_state_persists_in_hook_mesh()
        public
    {
        /*
         * This is one of the fundamental properties of the
         * HookMesh architecture.
         *
         * TestModule does not write to its own storage.
         *
         * Because the module is executed using delegatecall,
         * its storage writes occur against HookMesh's storage.
         */
        vm.startPrank(address(poolManager));

        hookMesh.beforeSwap(
            address(this),
            poolKey,
            _swapParams(),
            ""
        );

        hookMesh.beforeSwap(
            address(this),
            poolKey,
            _swapParams(),
            ""
        );

        vm.stopPrank();

        (
            uint256 calls,
            address lastSender,
            uint256 lastValue
        ) = hookMesh.testModuleState();

        assertEq(
            calls,
            2
        );

        assertEq(
            lastSender,
            address(poolManager)
        );

        assertEq(
            lastValue,
            123456
        );
    }

    /*//////////////////////////////////////////////////////////////
                         ACCESS CONTROL
    //////////////////////////////////////////////////////////////*/

    function test_only_pool_manager_can_call_before_swap()
        public
    {
        /*
         * An arbitrary external caller must not be able to
         * invoke HookMesh's lifecycle entry point.
         */
        vm.expectRevert(
            HookMesh.HookMesh__NotPoolManager.selector
        );

        hookMesh.beforeSwap(
            address(this),
            poolKey,
            _swapParams(),
            ""
        );
    }

    /*//////////////////////////////////////////////////////////////
                        POOL ID CONSISTENCY
    //////////////////////////////////////////////////////////////*/

    function test_pool_id_is_initialized()
        public
        view
    {
        assertTrue(
            PoolId.unwrap(poolId) != bytes32(0)
        );

        assertEq(
            PoolId.unwrap(poolId),
            PoolId.unwrap(poolKey.toId())
        );
    }

    /*//////////////////////////////////////////////////////////////
                          SWAP PARAMETERS
    //////////////////////////////////////////////////////////////*/

    function _swapParams()
        internal
        pure
        returns (IPoolManager.SwapParams memory)
    {
        return IPoolManager.SwapParams({
            zeroForOne: true,

            /*
             * Exact-input swaps are represented as negative
             * amountSpecified values in PoolManager's swap params.
             */
            amountSpecified: -1 ether,

            sqrtPriceLimitX96:
                SQRT_PRICE_1_1 - 1000
        });
    }
}