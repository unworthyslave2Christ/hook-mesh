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
    TestModule public module1;
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

    uint24 constant FIXED_FEE = 3000; // 0.30%

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
        module1 = new TestModule();

        module2 = new TestModule2();


        /*
         * Register both modules.
         */
        hookMesh.registerModule(
            address(module1)
        );

        hookMesh.registerModule(
            address(module2)
        );

        /*
         * Use a FIXED-FEE pool for this first integration test.
         *
         * We are testing HookMesh routing here, not dynamic fee
         * selection. Keeping the pool fee fixed isolates the
         * composition mechanism from fee logic.
         */
        poolKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(0x1234)),
            fee: FIXED_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hookMesh))
        });

        poolId =
            poolKey.toId();
    }


    /*//////////////////////////////////////////////////////////////
                     1. HOOK PERMISSION TEST
    //////////////////////////////////////////////////////////////*/

    function test_hook_mesh_has_before_swap_permission()
        public
        view
    {
        Hooks.Permissions memory permissions =
            hookMesh.getHookPermissions();

        assertTrue(
            permissions.beforeSwap
        );

        assertFalse(
            permissions.afterSwap
        );

        assertFalse(
            permissions.beforeInitialize
        );

        assertTrue(
            address(hookMesh) != address(0)
        );
    }


    /*//////////////////////////////////////////////////////////////
                     2. MODULE REGISTRATION
    //////////////////////////////////////////////////////////////*/

    function test_two_modules_are_registered()
        public
        view
    {
        assertEq(
            hookMesh.moduleCount(),
            2
        );

        (
            address implementation1,
            bytes32 id1,
            bytes32 namespace1,
            uint256 lifecycleMask1,
            bool enabled1
        ) = hookMesh.getModule(1);

        (
            address implementation2,
            bytes32 id2,
            bytes32 namespace2,
            uint256 lifecycleMask2,
            bool enabled2
        ) = hookMesh.getModule(2);

        assertEq(
            implementation1,
            address(module1)
        );

        assertEq(
            implementation2,
            address(module2)
        );

        assertEq(
            id1,
            module1.moduleId()
        );

        assertEq(
            id2,
            module2.moduleId()
        );

        assertEq(
            namespace1,
            module1.storageNamespace()
        );

        assertEq(
            namespace2,
            module2.storageNamespace()
        );

        assertTrue(enabled1);
        assertTrue(enabled2);

        /*
         * Both modules must currently be registered for
         * BEFORE_SWAP execution.
         */
        assertTrue(
            lifecycleMask1 & 1 != 0
        );

        assertTrue(
            lifecycleMask2 & 1 != 0
        );
    }


    /*//////////////////////////////////////////////////////////////
                     3. NAMESPACE OWNERSHIP
    //////////////////////////////////////////////////////////////*/

    function test_each_module_owns_unique_namespace()
        public
        view
    {
        bytes32 namespace1 =
            module1.storageNamespace();

        bytes32 namespace2 =
            module2.storageNamespace();

        /*
         * Two modules must never accidentally share the same
         * storage namespace.
         */
        assertTrue(
            namespace1 != namespace2
        );

        assertEq(
            hookMesh.namespaceOwner(namespace1),
            address(module1)
        );

        assertEq(
            hookMesh.namespaceOwner(namespace2),
            address(module2)
        );
    }


    /*//////////////////////////////////////////////////////////////
                  4. POOL INITIALIZATION
    //////////////////////////////////////////////////////////////*/

    function test_pool_uses_hook_mesh()
        public
    {
        /*
         * The PoolKey itself should identify HookMesh as the
         * pool's hook.
         */
        assertEq(
            address(poolKey.hooks),
            address(hookMesh)
        );

        /*
         * Initialize the pool.
         *
         * Because this pool uses a fixed fee, no dynamic-fee
         * machinery is involved in this test.
         */
        poolManager.initialize(
            poolKey,
            SQRT_PRICE_1_1
        );

        /*
         * If initialize succeeds, PoolManager has accepted
         * HookMesh as the pool's hook.
         */
        assertTrue(true);
    }


   
    

    /*//////////////////////////////////////////////////////////////
              6. BOTH MODULES RECEIVE THE SAME LIFECYCLE
    //////////////////////////////////////////////////////////////*/

    // function test_both_modules_execute_for_before_swap()
    //     public
    // {
    //     vm.prank(address(poolManager));

    //     hookMesh.beforeSwap(
    //         address(this),
    //         poolKey,
    //         _swapParams(),
    //         ""
    //     );

    //     /*
    //      * Module 1 must have executed exactly once.
    //      */
    //     (
    //         uint256 module1Calls,
    //         address module1Sender,
    //         uint256 module1Value
    //     ) = hookMesh.testModuleState();

    //     /*
    //      * Module 2 must have executed exactly once.
    //      */
    //     (
    //         uint256 module2Calls,
    //         address module2Sender,
    //         uint256 module2Value
    //     ) = hookMesh.testModule2State();

    //     assertEq(
    //         module1Calls,
    //         1
    //     );

    //     assertEq(
    //         module2Calls,
    //         1
    //     );

    //     /*
    //      * Both modules must see PoolManager as msg.sender.
    //      */
    //     assertEq(
    //         module1Sender,
    //         address(poolManager)
    //     );

    //     assertEq(
    //         module2Sender,
    //         address(poolManager)
    //     );

    //     /*
    //      * Confirm that both modules actually executed their
    //      * own logic rather than merely being registered.
    //      */
    //     assertEq(
    //         module1Value,
    //         123456
    //     );

    //     assertEq(
    //         module2Value,
    //         654321
    //     );
    // }


    /*//////////////////////////////////////////////////////////////
              7. EXECUTION COUNT ACROSS MULTIPLE CALLS
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

        bytes memory encodedState =
            hookMesh.getModuleState(
                module1.moduleId()
            );

        (
            uint256 calls,
            address lastSender,
            uint256 lastValue
        ) = abi.decode(
            encodedState,
            (uint256, address, uint256)
        );

        assertEq(calls, 1);
        assertEq(lastSender, address(poolManager));
        assertEq(lastValue, 123456);

        bytes memory encodedState2 =
            hookMesh.getModuleState(
                module2.moduleId()
            );

        (
            uint256 calls2,
            address lastSender2,
            uint256 lastValue2
        ) = abi.decode(
            encodedState2,
            (uint256, address, uint256)
        );

        assertEq(calls2, 1);
        assertEq(lastSender2, address(poolManager));
        assertEq(lastValue2, 654321);
    
    }

    /*//////////////////////////////////////////////////////////////
                  8. MSG.SENDER PRESERVATION
    //////////////////////////////////////////////////////////////*/

    // function test_delegatecall_preserves_pool_manager_sender()
    //     public
    // {
    //     vm.prank(address(poolManager));

    //     hookMesh.beforeSwap(
    //         address(this),
    //         poolKey,
    //         _swapParams(),
    //         ""
    //     );

    //     (
    //         ,
    //         address module1Sender,
    //     ) = hookMesh.testModuleState();

    //     (
    //         ,
    //         address module2Sender,
    //     ) = hookMesh.testModule2State();

    //     /*
    //      * delegatecall does NOT create a new msg.sender.
    //      *
    //      * Both modules therefore observe the original caller:
    //      * PoolManager.
    //      */
    //     assertEq(
    //         module1Sender,
    //         address(poolManager)
    //     );

    //     assertEq(
    //         module2Sender,
    //         address(poolManager)
    //     );
    // }


    /*//////////////////////////////////////////////////////////////
                     9. STORAGE ISOLATION
    //////////////////////////////////////////////////////////////*/

    // function test_module_storage_is_isolated()
    //     public
    // {
    //     vm.prank(address(poolManager));

    //     hookMesh.beforeSwap(
    //         address(this),
    //         poolKey,
    //         _swapParams(),
    //         ""
    //     );

    //     (
    //         uint256 module1Calls,
    //         ,
    //         uint256 module1Value
    //     ) = hookMesh.testModuleState();

    //     (
    //         uint256 module2Calls,
    //         ,
    //         uint256 module2Value
    //     ) = hookMesh.testModule2State();

    //     /*
    //      * Each module has its own state.
    //      */
    //     assertEq(
    //         module1Calls,
    //         1
    //     );

    //     assertEq(
    //         module2Calls,
    //         1
    //     );

    //     /*
    //      * The values deliberately differ so that we can detect
    //      * accidental storage collisions.
    //      */
    //     assertEq(
    //         module1Value,
    //         123456
    //     );

    //     assertEq(
    //         module2Value,
    //         654321
    //     );

    //     assertTrue(
    //         module1Value != module2Value
    //     );
    // }


    /*//////////////////////////////////////////////////////////////
                      10. ACCESS CONTROL
    //////////////////////////////////////////////////////////////*/

    function test_only_pool_manager_can_invoke_before_swap()
        public
    {
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
                   11. REPEATED CALLS PRESERVE STATE
    //////////////////////////////////////////////////////////////*/

    // function test_module_state_persists_across_calls()
    //     public
    // {
    //     vm.startPrank(address(poolManager));

    //     hookMesh.beforeSwap(
    //         address(this),
    //         poolKey,
    //         _swapParams(),
    //         ""
    //     );

    //     hookMesh.beforeSwap(
    //         address(this),
    //         poolKey,
    //         _swapParams(),
    //         ""
    //     );

    //     vm.stopPrank();

    //     bytes memory encodedState =
    //         hookMesh.getModuleState(
    //             module1.moduleId()
    //         );

    //     (
    //         uint256 module1Calls,
    //         address module1Sender,
    //         uint256 module1Value
    //     ) = abi.decode(
    //         encodedState,
    //         (uint256, address, uint256)
    //     );

    //     bytes memory encodedState2 =
    //         hookMesh.getModuleState(
    //             module1.moduleId()
    //         );

    //     (
    //         uint256 module2Calls,
    //         address moduleSender,
    //         uint256 module2Value
    //     ) = abi.decode(
    //         encodedState,
    //         (uint256, address, uint256)
    //     );

    //     assertEq(
    //         module1Calls,
    //         2
    //     );

    //     assertEq(
    //         module2Calls,
    //         2
    //     );

    //     assertEq(
    //         module1Sender,
    //         address(poolManager)
    //     );

    //     assertEq(
    //         module2Sender,
    //         address(poolManager)
    //     );

    //     assertEq(
    //         module1Value,
    //         123456
    //     );

    //     assertEq(
    //         module2Value,
    //         654321
    //     );
    // }


    /*//////////////////////////////////////////////////////////////
                         TEST HELPERS
    //////////////////////////////////////////////////////////////*/

    function _swapParams()
        internal
        pure
        returns (
            IPoolManager.SwapParams memory
        )
    {
        return IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: -1 ether,
            sqrtPriceLimitX96:
                SQRT_PRICE_1_1 - 1000
        });
    }
}