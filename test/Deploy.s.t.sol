// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

import {DriftFee} from "src/DriftFee.sol";
import {Deploy} from "script/Deploy.s.sol";

/// @dev Exposes the script's internals so the deployment configuration can be asserted on.
contract DeployHarness is Deploy {
    function poolManager() external view returns (address) {
        return _poolManager();
    }

    function defaultPoolManager() external view returns (address) {
        return _defaultPoolManager();
    }

    function owner() external view returns (address) {
        return _owner();
    }

    function params() external view returns (DriftFee.Params memory) {
        return _params();
    }
}

/**
 * @dev Covers `script/Deploy.s.sol`. A deploy script that is never executed is a broken deploy
 * script, and the part most likely to break — mining a salt whose address encodes the hook's
 * permission flags — fails at construction time with no partial success to inspect.
 */
contract DeployScriptTest is Test, Deployers {
    using StateLibrary for IPoolManager;

    uint160 internal constant FLAGS = uint160(
        Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
            | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
    );

    DeployHarness internal harness;

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        harness = new DeployHarness();
    }

    /// @dev The whole point of the script: mine a salt, deploy to the mined address, and have the
    /// result be a hook the pool manager will actually accept.
    function test_minedSaltDeploysAWorkingHook() public {
        DriftFee.Params memory params = harness.params();
        bytes memory constructorArgs = abi.encode(address(manager), address(this), params);

        // In a test the deployer is this contract; in the script it is the CREATE2 proxy.
        (address predicted, bytes32 salt) =
            HookMiner.find(address(this), FLAGS, type(DriftFee).creationCode, constructorArgs);

        DriftFee hook = new DriftFee{salt: salt}(manager, address(this), params);

        assertEq(address(hook), predicted, "deployed away from the mined address");
        assertEq(uint160(address(hook)) & Hooks.ALL_HOOK_MASK, FLAGS, "address does not encode the flags");

        // And it works: a dynamic-fee pool initializes against it and charges the base fee at
        // equilibrium. This is what the address-flag check exists to guarantee.
        (PoolKey memory poolKey,) =
            initPool(currency0, currency1, IHooks(address(hook)), LPFeeLibrary.DYNAMIC_FEE_FLAG, SQRT_PRICE_1_1);
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({tickLower: -3000, tickUpper: 3000, liquidityDelta: 1e18, salt: 0}),
            ZERO_BYTES
        );

        (int24 referenceTick,, bool initialized) = hook.driftState(poolKey);
        assertTrue(initialized, "hook did not seed equilibrium");
        assertEq(referenceTick, 0);

        // Confirm the hook prices the two directions differently — the behaviour the whole
        // contract exists for, running on a mined address.
        swap(poolKey, true, -1e16, ZERO_BYTES);

        assertGt(hook.quoteFeeForPath(poolKey, 0, 200), params.baseFee, "widening drift is not surcharged");
        assertLt(hook.quoteFeeForPath(poolKey, 200, 0), params.baseFee, "narrowing drift is not discounted");
    }

    function test_defaultParamsMatchTheDocumentedCurve() public view {
        DriftFee.Params memory params = harness.params();

        assertEq(params.baseFee, 3000);
        assertEq(params.minFee, 500);
        assertEq(params.maxFee, 10_000);
        assertEq(params.feePerTick, 30);
        assertEq(params.maxAdjustment, 7000);
        assertEq(params.discountBps, 10_000);
        assertEq(params.referenceWindow, 1800);
    }

    /**
     * @dev Each of these was verified onchain; this pins the transcription.
     *
     * It asserts on `_defaultPoolManager`, not `_poolManager`, deliberately. `vm.setEnv` writes to
     * the *process* environment, which is shared by every test running in the same invocation, so a
     * sibling test setting `POOL_MANAGER` would otherwise be able to decide this test's result.
     */
    function test_poolManagerTableIsCorrectPerChain() public {
        vm.chainId(1);
        assertEq(harness.defaultPoolManager(), 0x000000000004444c5dc75cB358380D2e3dE08A90, "ethereum");

        vm.chainId(10);
        assertEq(harness.defaultPoolManager(), 0x9a13F98Cb987694C9F086b1F5eB990EeA8264Ec3, "optimism");

        vm.chainId(8453);
        assertEq(harness.defaultPoolManager(), 0x498581fF718922c3f8e6A244956aF099B2652b2b, "base");

        vm.chainId(42161);
        assertEq(harness.defaultPoolManager(), 0x360E68faCcca8cA495c1B759Fd9EEe466db9FB32, "arbitrum");

        vm.chainId(11155111);
        assertEq(harness.defaultPoolManager(), 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543, "sepolia");

        vm.chainId(84532);
        assertEq(harness.defaultPoolManager(), 0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408, "base sepolia");

        vm.chainId(421614);
        assertEq(harness.defaultPoolManager(), 0xFB3e0C6F74eB1a21CC1Da29aeC80D2Dfe6C9a317, "arbitrum sepolia");
    }

    /**
     * @dev Ownership must be chosen deliberately, not inherited from whoever signed the deploy.
     *
     * All three cases live in one test on purpose: `vm.setEnv` writes to the process environment,
     * which every test in the run shares, so splitting these across tests would let them race.
     */
    function test_owner_mustBeSetAndShouldBeAContract() public {
        // Unset: refuse rather than defaulting to the broadcaster.
        vm.setEnv("OWNER", vm.toString(address(0)));
        vm.expectRevert(Deploy.OwnerMustBeSet.selector);
        harness.owner();

        // A bare EOA is refused unless the deployer says so outright.
        address eoa = makeAddr("someEOA");
        vm.setEnv("OWNER", vm.toString(eoa));
        vm.setEnv("ALLOW_EOA_OWNER", "false");
        vm.expectRevert(abi.encodeWithSelector(Deploy.OwnerIsNotAContract.selector, eoa));
        harness.owner();

        // ...and accepted when it is.
        vm.setEnv("ALLOW_EOA_OWNER", "true");
        assertEq(harness.owner(), eoa, "explicit EOA opt-in was ignored");

        // A contract owner — a multisig or timelock in practice — needs no opt-in.
        vm.setEnv("ALLOW_EOA_OWNER", "false");
        vm.setEnv("OWNER", vm.toString(address(harness)));
        assertEq(harness.owner(), address(harness), "contract owner was rejected");

        vm.setEnv("OWNER", vm.toString(address(0)));
    }

    /// @dev An unknown chain must not silently fall back to some other chain's manager.
    function test_unknownChainReverts() public {
        vm.chainId(1337);

        vm.expectRevert(abi.encodeWithSelector(Deploy.UnsupportedChain.selector, uint256(1337)));
        harness.defaultPoolManager();
    }

    function test_poolManagerEnvOverrideWins() public {
        address custom = makeAddr("customManager");

        vm.chainId(1);
        vm.setEnv("POOL_MANAGER", vm.toString(custom));

        assertEq(harness.poolManager(), custom, "env override ignored");

        _clearPoolManagerEnv();
    }

    /// @dev There is no cheatcode to unset an environment variable, and setting it to the empty
    /// string does not clear it either. The zero address is the sentinel `_poolManager` falls
    /// through on, so it is the only way to hand the process back in a neutral state.
    function _clearPoolManagerEnv() private {
        vm.setEnv("POOL_MANAGER", vm.toString(address(0)));
    }
}
