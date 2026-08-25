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
import {TestModuleNoBeforeSwap} from "../../src/modules/TestModuleNoBeforeSwap.sol";
import {RevertingTestModule} from "../../src/modules/RevertingTestModule.sol";
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
             8. ALL MODULES EXECUTE ON EVERY LIFECYCLE CALL
    //////////////////////////////////////////////////////////////*/

    function test_all_modules_execute_once_per_lifecycle_call()
        public
    {
        /*
        * ----------------------------------------------------------
        * FIRST LIFECYCLE CALL
        * ----------------------------------------------------------
        */

        vm.prank(address(poolManager));

        hookMesh.beforeSwap(
            address(this),
            poolKey,
            _swapParams(),
            ""
        );

        bytes memory state1 =
            hookMesh.getModuleState(
                module1.moduleId()
            );

        (
            uint256 module1CallsAfterFirst,
            address module1Sender,
            uint256 module1Value
        ) = abi.decode(
            state1,
            (uint256, address, uint256)
        );

        bytes memory state2 =
            hookMesh.getModuleState(
                module2.moduleId()
            );

        (
            uint256 module2CallsAfterFirst,
            address module2Sender,
            uint256 module2Value
        ) = abi.decode(
            state2,
            (uint256, address, uint256)
        );

        assertEq(
            module1CallsAfterFirst,
            1,
            "Module 1 must execute once"
        );

        assertEq(
            module2CallsAfterFirst,
            1,
            "Module 2 must execute once"
        );

        assertEq(
            module1Sender,
            address(poolManager)
        );

        assertEq(
            module2Sender,
            address(poolManager)
        );

        assertEq(
            module1Value,
            123456
        );

        assertEq(
            module2Value,
            654321
        );


        /*
        * ----------------------------------------------------------
        * SECOND LIFECYCLE CALL
        * ----------------------------------------------------------
        */

        vm.prank(address(poolManager));

        hookMesh.beforeSwap(
            address(this),
            poolKey,
            _swapParams(),
            ""
        );


        /*
        * ----------------------------------------------------------
        * READ MODULE 1
        * ----------------------------------------------------------
        */

        state1 =
            hookMesh.getModuleState(
                module1.moduleId()
            );

        (
            uint256 module1CallsAfterSecond,
            address module1SenderAfterSecond,
            uint256 module1ValueAfterSecond
        ) = abi.decode(
            state1,
            (uint256, address, uint256)
        );


        /*
        * ----------------------------------------------------------
        * READ MODULE 2
        * ----------------------------------------------------------
        */

        state2 =
            hookMesh.getModuleState(
                module2.moduleId()
            );

        (
            uint256 module2CallsAfterSecond,
            address module2SenderAfterSecond,
            uint256 module2ValueAfterSecond
        ) = abi.decode(
            state2,
            (uint256, address, uint256)
        );


        /*
        * ----------------------------------------------------------
        * ASSERT EXACTLY ONE ADDITIONAL EXECUTION
        * ----------------------------------------------------------
        */

        assertEq(
            module1CallsAfterSecond,
            module1CallsAfterFirst + 1,
            "Module 1 must execute exactly once per lifecycle call"
        );

        assertEq(
            module2CallsAfterSecond,
            module2CallsAfterFirst + 1,
            "Module 2 must execute exactly once per lifecycle call"
        );


        /*
        * msg.sender must remain PoolManager.
        */

        assertEq(
            module1SenderAfterSecond,
            address(poolManager)
        );

        assertEq(
            module2SenderAfterSecond,
            address(poolManager)
        );


        /*
        * Each module must retain its own state.
        */

        assertEq(
            module1ValueAfterSecond,
            123456
        );

        assertEq(
            module2ValueAfterSecond,
            654321
        );
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
            12. DISABLED MODULE IS SKIPPED ON SECOND CALL
    //////////////////////////////////////////////////////////////*/

    function test_disabled_module_is_skipped_on_second_lifecycle_call()
        public
    {
        /*
        * ----------------------------------------------------------
        * FIRST LIFECYCLE CALL
        * ----------------------------------------------------------
        *
        * Both modules are registered and enabled.
        */
        vm.prank(address(poolManager));

        hookMesh.beforeSwap(
            address(this),
            poolKey,
            _swapParams(),
            ""
        );

        /*
        * Verify both modules executed once.
        */
        bytes memory state1 =
            hookMesh.getModuleState(
                module1.moduleId()
            );

        (
            uint256 module1CallsBefore,
            ,
            
        ) = abi.decode(
            state1,
            (uint256, address, uint256)
        );

        bytes memory state2 =
            hookMesh.getModuleState(
                module2.moduleId()
            );

        (
            uint256 module2CallsBefore,
            ,
            
        ) = abi.decode(
            state2,
            (uint256, address, uint256)
        );

        assertEq(module1CallsBefore, 1);
        assertEq(module2CallsBefore, 1);

        /*
        * ----------------------------------------------------------
        * DISABLE MODULE 2
        * ----------------------------------------------------------
        *
        * Test contract deployed module2, therefore this test
        * contract is the module owner.
        */
        hookMesh.disableModule(
            module2.moduleId()
        );

        assertFalse(
            hookMesh.isModuleEnabled(
                module2.moduleId()
            )
        );

        assertTrue(
            hookMesh.isModuleEnabled(
                module1.moduleId()
            )
        );

        /*
        * ----------------------------------------------------------
        * SECOND LIFECYCLE CALL
        * ----------------------------------------------------------
        *
        * module1 -> executes
        * module2 -> skipped
        */
        vm.prank(address(poolManager));

        hookMesh.beforeSwap(
            address(this),
            poolKey,
            _swapParams(),
            ""
        );

        /*
        * ----------------------------------------------------------
        * VERIFY MODULE 1 EXECUTED AGAIN
        * ----------------------------------------------------------
        */
        bytes memory state1After =
            hookMesh.getModuleState(
                module1.moduleId()
            );

        (
            uint256 module1CallsAfter,
            address module1Sender,
            uint256 module1Value
        ) = abi.decode(
            state1After,
            (uint256, address, uint256)
        );

        assertEq(module1CallsAfter, 2);
        assertEq(module1Sender, address(poolManager));
        assertEq(module1Value, 123456);

        /*
        * ----------------------------------------------------------
        * VERIFY MODULE 2 DID NOT EXECUTE AGAIN
        * ----------------------------------------------------------
        */
        bytes memory state2After =
            hookMesh.getModuleState(
                module2.moduleId()
            );

        (
            uint256 module2CallsAfter,
            address module2Sender,
            uint256 module2Value
        ) = abi.decode(
            state2After,
            (uint256, address, uint256)
        );

        assertEq(module2CallsAfter, 1);
        assertEq(module2Sender, address(poolManager));
        assertEq(module2Value, 654321);
    }

    /*//////////////////////////////////////////////////////////////
            13. MODULE WITHOUT LIFECYCLE FLAG IS SKIPPED
    //////////////////////////////////////////////////////////////*/

    function test_module_without_lifecycle_flag_is_skipped()
        public
    {
        TestModuleNoBeforeSwap module3 =
            new TestModuleNoBeforeSwap();

        hookMesh.registerModule(
            address(module3)
        );

        /*
        * Registration enables the module automatically.
        */
        assertTrue(
            hookMesh.isModuleEnabled(
                module3.moduleId()
            )
        );

        /*
        * But the module does not advertise BEFORE_SWAP.
        */
        assertFalse(
            hookMesh.moduleSupportsLifecycle(
                module3.moduleId(),
                1 << 7
            )
        );

        /*
        * BEFORE_SWAP therefore executes module1 and module2,
        * but silently skips module3.
        */
        vm.prank(address(poolManager));

        hookMesh.beforeSwap(
            address(this),
            poolKey,
            _swapParams(),
            ""
        );

        /*
        * The important assertion is that HookMesh itself did not
        * revert merely because the module lacks BEFORE_SWAP support.
        */
        assertTrue(true);
    }



    /*//////////////////////////////////////////////////////////////
            14. MODULE OWNER CAN REENABLE MODULE
    //////////////////////////////////////////////////////////////*/

    function test_module_owner_can_reenable_module()
        public
    {
        /*
        * Module starts enabled because registration enables it.
        */
        assertTrue(
            hookMesh.isModuleEnabled(
                module2.moduleId()
            )
        );

        /*
        * Disable it.
        */
        hookMesh.disableModule(
            module2.moduleId()
        );

        assertFalse(
            hookMesh.isModuleEnabled(
                module2.moduleId()
            )
        );

        /*
        * Re-enable it.
        */
        hookMesh.enableModule(
            module2.moduleId()
        );

        assertTrue(
            hookMesh.isModuleEnabled(
                module2.moduleId()
            )
        );

        /*
        * It should now participate again.
        */
        vm.prank(address(poolManager));

        hookMesh.beforeSwap(
            address(this),
            poolKey,
            _swapParams(),
            ""
        );

        bytes memory state =
            hookMesh.getModuleState(
                module2.moduleId()
            );

        (
            uint256 calls,
            address sender,
            uint256 value
        ) = abi.decode(
            state,
            (uint256, address, uint256)
        );

        assertEq(calls, 1);
        assertEq(sender, address(poolManager));
        assertEq(value, 654321);
    }

    function test_non_owner_cannot_disable_module()
        public
    {
        bytes32 moduleId = module1.moduleId();

        address nonOwner = vm.addr(999);

        vm.startPrank(nonOwner);

        vm.expectRevert(
            HookMesh.HookMesh__NotModuleOwner.selector
        );

        hookMesh.disableModule(moduleId);

        vm.stopPrank();
    }


    /*//////////////////////////////////////////////////////////////
            15. MODULE FAILURE DOES NOT STOP OTHER MODULES
    //////////////////////////////////////////////////////////////*/

    function test_module_failure_does_not_stop_remaining_modules()
        public
    {
        RevertingTestModule failingModule =
            new RevertingTestModule();

        hookMesh.registerModule(
            address(failingModule)
        );

        /*
        * Registration order:
        *
        * module1
        * module2
        * failingModule
        *
        * Both normal modules should execute despite the failure
        * of the third module.
        */

        vm.prank(address(poolManager));

        hookMesh.beforeSwap(
            address(this),
            poolKey,
            _swapParams(),
            ""
        );

        /*
        * module1 executed.
        */
        bytes memory state1 =
            hookMesh.getModuleState(
                module1.moduleId()
            );

        (
            uint256 calls1,
            ,
            
        ) = abi.decode(
            state1,
            (uint256, address, uint256)
        );

        assertEq(calls1, 1);

        /*
        * module2 executed.
        */
        bytes memory state2 =
            hookMesh.getModuleState(
                module2.moduleId()
            );

        (
            uint256 calls2,
            ,
            
        ) = abi.decode(
            state2,
            (uint256, address, uint256)
        );

        assertEq(calls2, 1);

        /*
        * The lifecycle itself did not revert. (which means the reversion was absored as expected and did not affect other modules.)
        */
        assertTrue(true);
    }


    /*//////////////////////////////////////////////////////////////
            16. MODULE FAILURE IS RECORDED
    //////////////////////////////////////////////////////////////*/

    function test_module_failure_is_recorded()
        public
    {
        RevertingTestModule failingModule =
            new RevertingTestModule();

        hookMesh.registerModule(
            address(failingModule)
        );

        vm.prank(address(poolManager));

        hookMesh.beforeSwap(
            address(this),
            poolKey,
            _swapParams(),
            ""
        );

        assertEq(
            hookMesh.lastLifecycleFailureCount(),
            1
        );

        (
            bytes32 failedModuleId,
            address implementation,
            uint256 lifecycleFlag,
            bytes memory revertData
        ) = hookMesh.getLastLifecycleFailure(0);

        assertEq(
            failedModuleId,
            failingModule.moduleId()
        );

        assertEq(
            implementation,
            address(failingModule)
        );

        assertEq(
            lifecycleFlag,
            uint256(1 << 7)
        );

        assertTrue(
            revertData.length > 0
        );
    }


    /*//////////////////////////////////////////////////////////////
            17. LIFECYCLE FAILURE STATE IS PER INVOCATION
    //////////////////////////////////////////////////////////////*/

    function test_lifecycle_failures_are_cleared_between_calls()
        public
    {
        RevertingTestModule failingModule =
            new RevertingTestModule();

        hookMesh.registerModule(
            address(failingModule)
        );

        /*
        * FIRST CALL
        *
        * Failing module reverts.
        */
        vm.prank(address(poolManager));

        hookMesh.beforeSwap(
            address(this),
            poolKey,
            _swapParams(),
            ""
        );

        assertEq(
            hookMesh.lastLifecycleFailureCount(),
            1
        );

        /*
        * Disable the failing module.
        *
        * The second invocation therefore has no failure.
        */
        hookMesh.disableModule(
            failingModule.moduleId()
        );

        /*
        * SECOND CALL
        */
        vm.prank(address(poolManager));

        hookMesh.beforeSwap(
            address(this),
            poolKey,
            _swapParams(),
            ""
        );

        /*
        * Failure state belongs to the most recent lifecycle call.
        */
        assertEq(
            hookMesh.lastLifecycleFailureCount(),
            0
        );
    }


    function test_disabled_module_is_not_a_lifecycle_failure()
        public
    {
        RevertingTestModule failingModule =
            new RevertingTestModule();

        hookMesh.registerModule(
            address(failingModule)
        );

        hookMesh.disableModule(
            failingModule.moduleId()
        );

        vm.prank(address(poolManager));

        hookMesh.beforeSwap(
            address(this),
            poolKey,
            _swapParams(),
            ""
        );

        assertEq(
            hookMesh.lastLifecycleFailureCount(),
            0
        );
    }

    function test_lifecycle_mask_is_independent_of_enabled_state()
        public
    {
        /*
        * module1 supports BEFORE_SWAP.
        */
        assertTrue(
            hookMesh.moduleSupportsLifecycle(
                module1.moduleId(),
                1 << 7
            )
        );

        /*
        * module1 is initially enabled.
        */
        assertTrue(
            hookMesh.isModuleEnabled(
                module1.moduleId()
            )
        );

        /*
        * Disable it.
        */
        hookMesh.disableModule(
            module1.moduleId()
        );

        /*
        * Disabling does NOT change its advertised lifecycle mask.
        */
        assertTrue(
            hookMesh.moduleSupportsLifecycle(
                module1.moduleId(),
                1 << 7
            )
        );

        /*
        * But execution eligibility is now false because it is
        * disabled.
        */
        assertFalse(
            hookMesh.isModuleEnabled(
                module1.moduleId()
            )
        );
    }


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