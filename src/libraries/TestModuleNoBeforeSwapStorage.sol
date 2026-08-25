library TestModuleNoBeforeSwapStorage {

    bytes32 internal constant STORAGE_LOCATION =
        keccak256("hookmesh.module.test-no-before-swap");

    struct Layout {
        uint256 calls;
    }

    function layout()
        internal
        pure
        returns (Layout storage l)
    {
        bytes32 slot = STORAGE_LOCATION;

        assembly {
            l.slot := slot
        }
    }
}