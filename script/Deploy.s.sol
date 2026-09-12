// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

import {DriftFee} from "src/DriftFee.sol";

/**
 * @title Deploy
 * @notice Mines a `CREATE2` salt so the hook's address encodes its permission flags, then deploys.
 *
 * @dev A v4 hook cannot be deployed to an arbitrary address: `BaseHook`'s constructor checks that
 * the low 14 bits of its own address match the flags returned by `getHookPermissions`, so deployment
 * is a search for a salt rather than a plain `create`. `DriftFee` implements `afterInitialize` and
 * `beforeSwap`, so it needs bits 12 and 7 set.
 *
 * Usage:
 *
 * ```sh
 * forge script script/Deploy.s.sol:Deploy --rpc-url <url> --broadcast --verify
 * ```
 *
 * `POOL_MANAGER` defaults to the verified manager for the chain being deployed to; `OWNER` defaults
 * to the broadcasting account. Every curve parameter can be overridden by environment variable, and
 * all of them are validated by the constructor, so a bad value fails before broadcast rather than
 * leaving a live hook with a nonsense curve.
 */
contract Deploy is Script {
    /// @dev Foundry routes `new X{salt: s}()` in a script through this deterministic proxy, so it is
    /// the address the salt must be mined against. In a *test*, the deployer is the test contract.
    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    uint160 internal constant FLAGS = uint160(
        Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
            | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
    );

    error UnsupportedChain(uint256 chainId);
    error NoPoolManagerCode(address poolManager);
    error AddressMismatch(address expected, address actual);

    function run() external returns (DriftFee hook) {
        address poolManager = _poolManager();
        address owner = vm.envOr("OWNER", msg.sender);
        DriftFee.Params memory params = _params();

        if (poolManager.code.length == 0) revert NoPoolManagerCode(poolManager);

        bytes memory constructorArgs = abi.encode(poolManager, owner, params);
        (address predicted, bytes32 salt) =
            HookMiner.find(CREATE2_DEPLOYER, FLAGS, type(DriftFee).creationCode, constructorArgs);

        console.log("chain id      ", block.chainid);
        console.log("pool manager  ", poolManager);
        console.log("owner         ", owner);
        console.log("mined address ", predicted);
        console.logBytes32(salt);

        vm.startBroadcast();
        hook = new DriftFee{salt: salt}(IPoolManager(poolManager), owner, params);
        vm.stopBroadcast();

        // Belt and braces: the constructor already rejects a wrong address, but a mismatch here
        // would mean the mined salt and the broadcast deployer disagreed, which is worth naming.
        if (address(hook) != predicted) revert AddressMismatch(predicted, address(hook));
    }

    /**
     * @dev The v4 `PoolManager` for the current chain.
     *
     * Each of these was verified onchain rather than copied from a table: identical runtime code to
     * mainnet's, each under its own governance owner. `POOL_MANAGER` overrides, and unknown chains
     * must supply it rather than fall back to a guess.
     */
    function _poolManager() internal view virtual returns (address) {
        address overridden = vm.envOr("POOL_MANAGER", address(0));

        return overridden == address(0) ? _defaultPoolManager() : overridden;
    }

    /// @dev The verified manager for the current chain, ignoring any override. Kept separate from
    /// {_poolManager} so the table can be asserted on without touching the process environment.
    function _defaultPoolManager() internal view virtual returns (address) {
        if (block.chainid == 1) return 0x000000000004444c5dc75cB358380D2e3dE08A90; // Ethereum
        if (block.chainid == 10) return 0x9a13F98Cb987694C9F086b1F5eB990EeA8264Ec3; // Optimism
        if (block.chainid == 8453) return 0x498581fF718922c3f8e6A244956aF099B2652b2b; // Base
        if (block.chainid == 42161) return 0x360E68faCcca8cA495c1B759Fd9EEe466db9FB32; // Arbitrum

        revert UnsupportedChain(block.chainid);
    }

    /// @dev Default curve, matching the README. Every field is overridable.
    function _params() internal view virtual returns (DriftFee.Params memory) {
        return DriftFee.Params({
            baseFee: uint24(vm.envOr("BASE_FEE", uint256(3000))),
            minFee: uint24(vm.envOr("MIN_FEE", uint256(500))),
            maxFee: uint24(vm.envOr("MAX_FEE", uint256(10_000))),
            feePerTick: uint24(vm.envOr("FEE_PER_TICK", uint256(30))),
            maxAdjustment: uint24(vm.envOr("MAX_ADJUSTMENT", uint256(7000))),
            discountBps: uint16(vm.envOr("DISCOUNT_BPS", uint256(10_000))),
            referenceWindow: uint32(vm.envOr("REFERENCE_WINDOW", uint256(1800)))
        });
    }
}
