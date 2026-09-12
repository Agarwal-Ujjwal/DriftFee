// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {DriftFee} from "src/DriftFee.sol";
import {DriftFeeHarness} from "./utils/DriftFeeHarness.sol";
import {DriftFeeHandler} from "./utils/DriftFeeHandler.sol";

contract DriftFeeInvariantsTest is Test, Deployers {
    uint160 private constant HOOK_FLAGS = uint160(
        Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
            | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
    );

    DriftFeeHarness internal hook;
    DriftFeeHandler internal handler;
    address internal owner = makeAddr("owner");

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        hook = DriftFeeHarness(address(HOOK_FLAGS));
        deployCodeTo(
            "test/utils/DriftFeeHarness.sol:DriftFeeHarness",
            abi.encode(address(manager), owner, _params()),
            address(hook)
        );

        (key,) = initPool(currency0, currency1, IHooks(address(hook)), LPFeeLibrary.DYNAMIC_FEE_FLAG, SQRT_PRICE_1_1);

        modifyLiquidityRouter.modifyLiquidity(
            key, ModifyLiquidityParams({tickLower: -6000, tickUpper: 6000, liquidityDelta: 1e18, salt: 0}), ZERO_BYTES
        );

        handler = new DriftFeeHandler(manager, swapRouter, key);

        // Fund the handler and let the router pull from it.
        _fundHandler(currency0);
        _fundHandler(currency1);

        targetContract(address(handler));

        // Without this the fuzzer spends a third of its calls on the handler's coverage stub.
        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = DriftFeeHandler.swapExactIn.selector;
        selectors[1] = DriftFeeHandler.advanceTime.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function _params() internal pure returns (DriftFee.Params memory) {
        return DriftFee.Params({
            baseFee: 3000,
            minFee: 500,
            maxFee: 10_000,
            feePerTick: 30,
            maxAdjustment: 7000,
            discountBps: 10_000,
            referenceWindow: 1800
        });
    }

    function _fundHandler(Currency currency) private {
        MockERC20 token = MockERC20(Currency.unwrap(currency));

        token.mint(address(handler), 1e30);

        vm.prank(address(handler));
        token.approve(address(swapRouter), type(uint256).max);
    }

    /**
     * @dev Equilibrium never leaves the range of ticks the pool has actually traded at.
     *
     * This is manipulation resistance stated as a property: because the fold only ever moves the
     * reference toward a tick the pool genuinely visited, and never past it, there is no sequence of
     * swaps and delays that walks equilibrium to a price the market never reached.
     */
    function invariant_referenceStaysWithinObservedTicks() public view {
        (int24 referenceTick,,) = hook.driftState(key);

        // The fold truncates toward zero, so allow the single tick of slack that introduces.
        assertGe(int256(referenceTick), int256(handler.minObservedTick()) - 1, "equilibrium below observed range");
        assertLe(int256(referenceTick), int256(handler.maxObservedTick()) + 1, "equilibrium above observed range");
    }

    /// @dev Every quotable fee, for any drift change in either direction, stays inside the band.
    function invariant_quotedFeeStaysWithinBand() public view {
        DriftFee.Params memory p = _params();

        int24[5] memory points = [int24(-800_000), -100, 0, 100, 800_000];

        // Every pairing, so crossing paths are covered as well as monotone ones.
        for (uint256 i; i < points.length; ++i) {
            for (uint256 j; j < points.length; ++j) {
                uint24 fee = hook.quoteFeeForPath(key, points[i], points[j]);

                assertGe(fee, p.minFee, "fee below floor");
                assertLe(fee, p.maxFee, "fee above ceiling");
            }
        }
    }

    /// @dev The reference is seeded once and never un-seeded, and its clock never runs ahead.
    function invariant_referenceClockIsSane() public view {
        (, uint40 lastUpdate, bool initialized) = hook.driftState(key);

        assertTrue(initialized, "reference lost its seed");
        assertLe(uint256(lastUpdate), block.timestamp, "reference folded from the future");
    }

    /**
     * @dev Widening drift is never cheaper than narrowing it by the same amount.
     *
     * This is the property the redesign exists to guarantee. Under the old rule, which priced off
     * the drift a swap started from, a swap leaving equilibrium paid the base rate however far it
     * moved the price, so creating drift could be cheaper than repairing it.
     */
    function invariant_wideningIsNeverCheaperThanNarrowing() public view {
        int24[3] memory magnitudes = [int24(1), 100, 10_000];

        for (uint256 i; i < magnitudes.length; ++i) {
            uint24 widen = hook.quoteFeeForPath(key, 0, magnitudes[i]);
            uint24 narrow = hook.quoteFeeForPath(key, magnitudes[i], 0);

            assertGe(widen, narrow, "creating drift was cheaper than repairing it");
        }
    }
}
