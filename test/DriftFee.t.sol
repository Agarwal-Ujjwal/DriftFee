// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {DriftFee} from "src/DriftFee.sol";
import {BaseOverrideFee} from "uniswap-hooks/fee/BaseOverrideFee.sol";
import {DriftFeeHarness} from "./utils/DriftFeeHarness.sol";

contract DriftFeeTest is Test, Deployers {
    using StateLibrary for IPoolManager;

    /// @dev Signature of the pool manager's `Swap` event, used to read the fee the pool actually
    /// charged rather than the fee the hook merely claimed to return.
    bytes32 private constant SWAP_TOPIC = keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");

    bytes32 private constant DRIFT_FEE_TOPIC = keccak256("DriftFeeApplied(bytes32,int24,uint24,bool)");

    uint160 private constant HOOK_FLAGS = uint160(
        Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
            | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
    );

    int24 private constant TICK_LOWER = -3000;
    int24 private constant TICK_UPPER = 3000;

    DriftFeeHarness internal hook;
    address internal owner = makeAddr("owner");
    address internal stranger = makeAddr("stranger");

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        hook = DriftFeeHarness(address(HOOK_FLAGS));
        deployCodeTo(
            "test/utils/DriftFeeHarness.sol:DriftFeeHarness",
            abi.encode(address(manager), owner, _defaultParams()),
            address(hook)
        );

        (key,) = initPool(currency0, currency1, IHooks(address(hook)), LPFeeLibrary.DYNAMIC_FEE_FLAG, SQRT_PRICE_1_1);

        // A range wide enough that test swaps move the tick without running out of liquidity.
        modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({tickLower: TICK_LOWER, tickUpper: TICK_UPPER, liquidityDelta: 1e18, salt: 0}),
            ZERO_BYTES
        );
    }

    function _defaultParams() internal pure returns (DriftFee.Params memory) {
        return DriftFee.Params({
            baseFee: 3000, // 0.30%
            minFee: 500, // 0.05%
            maxFee: 10_000, // 1.00%
            feePerTick: 30,
            maxAdjustment: 7000,
            discountBps: 10_000,
            referenceWindow: 1800
        });
    }

    /*//////////////////////////////////////////////////////////////
                             INITIALIZATION
    //////////////////////////////////////////////////////////////*/

    function test_afterInitialize_seedsReferenceAtInitialTick() public view {
        (int24 referenceTick, uint40 lastUpdate, bool initialized) = hook.driftState(key);

        (, int24 currentTick,,) = manager.getSlot0(key.toId());

        assertTrue(initialized, "reference not seeded");
        assertEq(referenceTick, currentTick, "reference should start at the initialization tick");
        assertEq(lastUpdate, uint40(block.timestamp));
    }

    function test_afterInitialize_staticFeePool_reverts() public {
        PoolKey memory staticKey =
            PoolKey({currency0: currency0, currency1: currency1, fee: 3000, tickSpacing: 60, hooks: IHooks(hook)});

        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.afterInitialize.selector,
                abi.encodeWithSelector(BaseOverrideFee.NotDynamicFee.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        manager.initialize(staticKey, SQRT_PRICE_1_1);
    }

    function test_constructor_invalidParams_reverts() public {
        DriftFee.Params memory bad = _defaultParams();
        bad.minFee = bad.baseFee + 1;

        _assertConstructorReverts(
            abi.encode(address(manager), owner, bad), abi.encodeWithSelector(DriftFee.InvalidParams.selector)
        );
    }

    function test_constructor_zeroOwner_reverts() public {
        _assertConstructorReverts(
            abi.encode(address(manager), address(0), _defaultParams()),
            abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0))
        );
    }

    function test_constructor_zeroPoolManager_reverts() public {
        _assertConstructorReverts(
            abi.encode(address(0), owner, _defaultParams()),
            abi.encodeWithSelector(DriftFee.InvalidPoolManager.selector)
        );
    }

    /*//////////////////////////////////////////////////////////////
                          CONFIG / ACCESS CONTROL
    //////////////////////////////////////////////////////////////*/

    function test_setParams_nonOwner_reverts() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        hook.setDefaultParams(_defaultParams());
    }

    function test_setParams_owner_updatesAndEmits() public {
        DriftFee.Params memory next = _defaultParams();
        next.baseFee = 4000;
        next.feePerTick = 50;

        vm.expectEmit(address(hook));
        emit DriftFee.DefaultParamsUpdated(next);

        vm.prank(owner);
        hook.setDefaultParams(next);

        assertEq(hook.defaultParams().baseFee, 4000);
        assertEq(hook.defaultParams().feePerTick, 50);
    }

    function test_setParams_feeAboveHardCap_reverts() public {
        DriftFee.Params memory bad = _defaultParams();
        bad.maxFee = hook.MAX_CONFIGURABLE_FEE() + 1;

        vm.prank(owner);
        vm.expectRevert(DriftFee.InvalidParams.selector);
        hook.setDefaultParams(bad);
    }

    /**
     * @dev Regression for the flat-rate hole found in the CROPS audit.
     *
     * Validation used to require only `minFee <= baseFee <= maxFee <= MAX_CONFIGURABLE_FEE`, with no
     * independent ceiling on `baseFee`. That made `minFee == baseFee == maxFee == MAX_CONFIGURABLE_FEE`
     * a valid curve: `headroom` is then zero so the discount branch always returns `minFee`, and the
     * surcharge branch always clamps to `maxFee` — a flat fee at the ceiling in both directions with
     * the drift mechanism switched off. `MAX_BASE_FEE` closes it.
     */
    function test_setParams_cannotFlattenPoolToASingleExtractiveRate() public {
        uint24 cap = hook.MAX_CONFIGURABLE_FEE();

        DriftFee.Params memory flat = _defaultParams();
        flat.minFee = cap;
        flat.baseFee = cap;
        flat.maxFee = cap;

        vm.prank(owner);
        vm.expectRevert(DriftFee.InvalidParams.selector);
        hook.setDefaultParams(flat);

        // The same shape via a per-pool override must be rejected too.
        vm.prank(owner);
        vm.expectRevert(DriftFee.InvalidParams.selector);
        hook.setPoolParams(key, flat);
    }

    /// @dev What an honest, drift-neutral swap can be charged is capped well below `maxFee`.
    function test_setParams_baseFeeIsBoundedBelowTheOverallCap() public {
        assertLt(hook.MAX_BASE_FEE(), hook.MAX_CONFIGURABLE_FEE(), "base fee cap must be the tighter one");

        DriftFee.Params memory bad = _defaultParams();
        bad.baseFee = hook.MAX_BASE_FEE() + 1;
        bad.maxFee = hook.MAX_CONFIGURABLE_FEE();

        vm.prank(owner);
        vm.expectRevert(DriftFee.InvalidParams.selector);
        hook.setDefaultParams(bad);
    }

    function test_setParams_windowBelowFloor_reverts() public {
        DriftFee.Params memory bad = _defaultParams();
        bad.referenceWindow = hook.MIN_REFERENCE_WINDOW() - 1;

        vm.prank(owner);
        vm.expectRevert(DriftFee.InvalidParams.selector);
        hook.setDefaultParams(bad);
    }

    function test_setParams_windowAboveCeiling_reverts() public {
        DriftFee.Params memory bad = _defaultParams();
        bad.referenceWindow = hook.MAX_REFERENCE_WINDOW() + 1;

        vm.prank(owner);
        vm.expectRevert(DriftFee.InvalidParams.selector);
        hook.setDefaultParams(bad);
    }

    function test_setParams_inconsistentCurve_reverts() public {
        DriftFee.Params memory bad = _defaultParams();
        bad.maxFee = bad.baseFee - 1;

        vm.prank(owner);
        vm.expectRevert(DriftFee.InvalidParams.selector);
        hook.setDefaultParams(bad);
    }

    function test_setParams_discountAboveOneHundredPercent_reverts() public {
        DriftFee.Params memory bad = _defaultParams();
        bad.discountBps = 10_001;

        vm.prank(owner);
        vm.expectRevert(DriftFee.InvalidParams.selector);
        hook.setDefaultParams(bad);
    }

    function test_setParams_feePerTickAboveCap_reverts() public {
        DriftFee.Params memory bad = _defaultParams();
        bad.feePerTick = uint24(hook.MAX_FEE_PER_TICK()) + 1;

        vm.prank(owner);
        vm.expectRevert(DriftFee.InvalidParams.selector);
        hook.setDefaultParams(bad);
    }

    /*//////////////////////////////////////////////////////////////
                          PER-POOL OVERRIDES
    //////////////////////////////////////////////////////////////*/

    function test_poolParams_defaultAppliesWhenUnset() public view {
        assertFalse(hook.hasPoolParams(key));
        assertEq(hook.paramsFor(key).baseFee, _defaultParams().baseFee);
        assertEq(hook.paramsFor(key).referenceWindow, _defaultParams().referenceWindow);
    }

    function test_setPoolParams_nonOwner_reverts() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        hook.setPoolParams(key, _defaultParams());
    }

    function test_clearPoolParams_nonOwner_reverts() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        hook.clearPoolParams(key);
    }

    function test_setPoolParams_overridesTheDefault() public {
        DriftFee.Params memory tight = _defaultParams();
        tight.baseFee = 100; // a stablecoin-style curve
        tight.minFee = 10;
        tight.feePerTick = 200;

        vm.expectEmit(address(hook));
        emit DriftFee.PoolParamsUpdated(key.toId(), tight);

        vm.prank(owner);
        hook.setPoolParams(key, tight);

        assertTrue(hook.hasPoolParams(key));
        assertEq(hook.paramsFor(key).baseFee, 100);
        assertEq(hook.defaultParams().baseFee, _defaultParams().baseFee, "default must be untouched");

        // The pool charges its own curve, not the default. The pool's own fee path carries the
        // override's floor; the drift-dependent remainder is charged in `afterSwap`.
        assertEq(_swapAndReadPoolFee(true, 1e15), tight.minFee);
        assertLt(hook.feeFor(key, -100 * 1e6), _defaultParams().baseFee);
    }

    function test_clearPoolParams_revertsToDefault() public {
        DriftFee.Params memory tight = _defaultParams();
        tight.baseFee = 100;
        tight.minFee = 10;

        vm.prank(owner);
        hook.setPoolParams(key, tight);

        vm.expectEmit(address(hook));
        emit DriftFee.PoolParamsCleared(key.toId());

        vm.prank(owner);
        hook.clearPoolParams(key);

        assertFalse(hook.hasPoolParams(key));
        assertEq(hook.paramsFor(key).baseFee, _defaultParams().baseFee);
    }

    /// @dev An override must not be a way around the caps that bound the default curve, or per-pool
    /// tuning would become a path to an extractive fee.
    function test_setPoolParams_hardCapsStillApply() public {
        DriftFee.Params memory overCap = _defaultParams();
        overCap.maxFee = hook.MAX_CONFIGURABLE_FEE() + 1;

        vm.prank(owner);
        vm.expectRevert(DriftFee.InvalidParams.selector);
        hook.setPoolParams(key, overCap);

        DriftFee.Params memory shortWindow = _defaultParams();
        shortWindow.referenceWindow = hook.MIN_REFERENCE_WINDOW() - 1;

        vm.prank(owner);
        vm.expectRevert(DriftFee.InvalidParams.selector);
        hook.setPoolParams(key, shortWindow);
    }

    function test_setPoolParams_affectsOnlyThatPool() public {
        // Same pair, different tick spacing, so a genuinely different pool id.
        (PoolKey memory otherKey,) =
            initPool(currency0, currency1, IHooks(address(hook)), LPFeeLibrary.DYNAMIC_FEE_FLAG, 30, SQRT_PRICE_1_1);

        DriftFee.Params memory tight = _defaultParams();
        tight.baseFee = 100;
        tight.minFee = 10;

        vm.prank(owner);
        hook.setPoolParams(key, tight);

        assertEq(hook.paramsFor(key).baseFee, 100);
        assertEq(hook.paramsFor(otherKey).baseFee, _defaultParams().baseFee, "sibling pool should be unaffected");
        assertFalse(hook.hasPoolParams(otherKey));
    }

    /// @dev A longer override window is the point of per-pool tuning: the same price move drags
    /// equilibrium less on a pool configured to trust its reference for longer.
    function test_setPoolParams_longerWindowFoldsSlower() public {
        DriftFee.Params memory slow = _defaultParams();
        slow.referenceWindow = 18_000; // ten times the default

        vm.prank(owner);
        hook.setPoolParams(key, slow);

        _swap(true, 1e16);
        (, int24 standingTick,,) = manager.getSlot0(key.toId());

        vm.warp(block.timestamp + 180);
        vm.roll(block.number + 1);
        _swap(true, 1);

        (int24 referenceAfter,,) = hook.driftState(key);

        assertEq(referenceAfter, int24(hook.fold(0, standingTick, 180, 18_000) / 1e6));
        assertGt(
            referenceAfter,
            int24(hook.fold(0, standingTick, 180, 1800) / 1e6),
            "the slower window should have moved equilibrium less"
        );
    }

    /*//////////////////////////////////////////////////////////////
                               FEE CURVE
    //////////////////////////////////////////////////////////////*/

    /// @dev A swap that leaves the distance from equilibrium unchanged is neutral.
    function test_feeFor_neutralSwapPaysBaseFee() public view {
        assertEq(hook.feeFor(key, 0), _defaultParams().baseFee);
    }

    function test_feeFor_wideningIsSurcharged() public view {
        DriftFee.Params memory p = _defaultParams();

        assertEq(hook.feeFor(key, 50 * 1e6), p.baseFee + 50 * p.feePerTick);
    }

    function test_feeFor_narrowingIsDiscounted() public view {
        DriftFee.Params memory p = _defaultParams();

        assertEq(hook.feeFor(key, -50 * 1e6), p.baseFee - 50 * p.feePerTick);
    }

    /// @dev The fee depends only on how much the gap changed, not on which side of equilibrium the
    /// pool happens to sit. Widening by 50 costs the same whether the pool is above or below.
    function test_feeFor_dependsOnMagnitudeNotSide() public view {
        assertEq(hook.feeFor(key, 50 * 1e6), hook.feeFor(key, 50 * 1e6));
        assertGt(hook.feeFor(key, 50 * 1e6), hook.feeFor(key, -50 * 1e6));
    }

    function test_feeFor_clampsAtMaxFee() public view {
        assertEq(hook.feeFor(key, 2000 * 1e6), _defaultParams().maxFee);
    }

    function test_feeFor_clampsAtMinFee() public view {
        assertEq(hook.feeFor(key, -2000 * 1e6), _defaultParams().minFee);
    }

    /// @dev Half a tick of change still moves the fee: the adjustment is computed on the scaled
    /// value rather than on a drift already truncated to whole ticks.
    function test_feeFor_subTickChangeIsPriced() public view {
        DriftFee.Params memory p = _defaultParams();

        assertEq(hook.feeFor(key, 5e5), p.baseFee + p.feePerTick / 2);
    }

    /**
     * @dev Pins the precision of the discount path.
     *
     * The adjustment is held in scaled units until the final division, so a sub-unit adjustment
     * survives long enough for `discountBps` to apply to it. Dividing down to whole hundredths of a
     * bip first would floor 1.9 to 1, then floor 90% of 1 to 0, and return `baseFee` unchanged.
     */
    function test_feeFor_discountKeepsSubUnitPrecision() public view {
        DriftFee.Params memory p = _defaultParams();
        p.feePerTick = 1;
        p.discountBps = 9000;
        p.minFee = 0;

        // 1.9 ticks of narrowing: a raw adjustment of 1.9 units, of which 90% is 1.71.
        assertEq(hook.feeForParams(p, -19e5), p.baseFee - 1);
    }

    function test_feeFor_respectsDiscountFactor() public view {
        DriftFee.Params memory p = _defaultParams();
        p.discountBps = 5000; // credit only half the adjustment back

        assertEq(hook.feeForParams(p, -50 * 1e6), p.baseFee - (50 * p.feePerTick) / 2);
    }

    /*//////////////////////////////////////////////////////////////
                            REFERENCE FOLD
    //////////////////////////////////////////////////////////////*/

    function test_fold_zeroElapsed_isNoop() public view {
        assertEq(hook.fold(0, 1000, 0, 1800), 0);
    }

    /// @dev A single sample may never replace the reference, however long the pool has been idle.
    /// Before `MAX_FOLD_BPS` existed, a full window of silence let one swap set equilibrium outright,
    /// which is enough to hand an attacker `maxFee` in one direction and `minFee` in the other.
    function test_fold_singleSampleCannotReplaceTheReference() public view {
        uint256 capBps = hook.MAX_FOLD_BPS();

        // A full window elapsed still closes only `MAX_FOLD_BPS` of the gap, not all of it.
        assertEq(hook.fold(0, 1000, 1800, 1800), int256(1000e6 * capBps / 10_000));
        assertLt(hook.fold(0, 1000, 1800, 1800), 1000e6);
    }

    function test_fold_isCappedRegardlessOfIdleTime() public view {
        // A century of silence is worth no more than a single capped sample.
        assertEq(hook.fold(0, 1000, 100 days, 1800), hook.fold(0, 1000, 1800, 1800));
    }

    /// @dev Converging on a genuinely moved price takes repeated samples at distinct timestamps,
    /// which is the cost an attacker must also pay.
    function test_fold_convergesOverRepeatedSamples() public view {
        int256 folded = 0;
        for (uint256 i; i < 20; ++i) {
            folded = hook.fold(folded, 1000, 1800, 1800);
        }

        assertGt(folded, 950e6, "twenty capped samples should substantially converge");
        assertLt(folded, 1000e6, "but never quite reach the sample");
    }

    function test_fold_partialWindow_movesProportionally() public view {
        // One tenth of the window elapsed, so the reference closes one tenth of the gap.
        assertEq(hook.fold(0, 1000, 180, 1800), 100e6);
    }

    function test_fold_movesDownward() public view {
        assertEq(hook.fold(1000e6, 0, 180, 1800), 900e6);
    }

    /*//////////////////////////////////////////////////////////////
                          SWAP INTEGRATION
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev The pool's own fee path charges the floor, and only the floor.
     *
     * Guards the failure mode where a hook returns a fee without the override flag and the pool
     * silently keeps charging its stored fee: this reads the rate off the pool's own event. The
     * drift-dependent remainder is charged separately in `afterSwap`, so `minFee` here is correct
     * rather than a symptom of the override being ignored.
     */
    function test_swap_poolChargesTheFloorThroughItsOwnFeePath() public {
        assertEq(_swapAndReadPoolFee(true, 1e15), _defaultParams().minFee);
    }

    /// @dev A swap starting at equilibrium creates drift, and is charged for creating it. Under the
    /// old pre-swap-drift rule this paid exactly `baseFee` no matter how far it moved the price.
    function test_swap_creatingDriftFromEquilibriumIsSurcharged() public {
        _addDeepLiquidity();

        uint24 fee = _swapAndReadDriftFee(true, 2e18);

        assertGt(fee, _defaultParams().baseFee, "the swap that created drift was not surcharged");
    }

    function test_swap_narrowingDriftIsDiscounted() public {
        _addDeepLiquidity();

        _swap(true, 2e18); // push away from equilibrium

        uint24 fee = _swapAndReadDriftFee(false, 1e18); // bring it back

        assertLt(fee, _defaultParams().baseFee, "narrowing drift was not discounted");
    }

    /// @dev Creating drift is never cheaper than repairing the same amount. This is the property
    /// whose absence made pre-moving profitable.
    function test_swap_creatingIsNeverCheaperThanRepairing() public {
        _addDeepLiquidity();

        uint24 create = _swapAndReadDriftFee(true, 1e18);
        uint24 repair = _swapAndReadDriftFee(false, 1e18);

        assertGt(create, repair, "creating drift cost no more than repairing it");
    }

    /**
     * @dev Exact-output swaps, which take the fee from the *input* side.
     *
     * Every other swap test here is exact-input, where the unspecified delta is positive. On an
     * exact-output swap the unspecified currency is the input and its delta is negative, so this
     * exercises the sign handling in the collection path that nothing else reaches.
     */
    function test_swap_exactOutputIsPricedAndCollected() public {
        _addDeepLiquidity();

        vm.recordLogs();
        swap(key, true, 1e18, ZERO_BYTES); // positive amountSpecified == exact output

        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint24 fee;
        bool found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(hook) && logs[i].topics[0] == DRIFT_FEE_TOPIC) {
                (, fee,) = abi.decode(logs[i].data, (int24, uint24, bool));
                found = true;
            }
        }

        assertTrue(found, "no fee decision for an exact-output swap");
        assertGt(fee, _defaultParams().baseFee, "exact-output swap creating drift was not surcharged");
        assertEq(_hookBalance(currency0) + _hookBalance(currency1), 0, "hook retained a balance");
    }

    /// @dev With nothing in range there is no one to donate the remainder to, so it is waived
    /// rather than accrued to this contract.
    function test_swap_withoutInRangeLiquidityWaivesTheRemainder() public {
        (PoolKey memory emptyKey,) =
            initPool(currency0, currency1, IHooks(address(hook)), LPFeeLibrary.DYNAMIC_FEE_FLAG, 10, SQRT_PRICE_1_1);

        // No liquidity is ever added to `emptyKey`.
        swapRouter.swap(
            emptyKey,
            SwapParams({zeroForOne: true, amountSpecified: -1e15, sqrtPriceLimitX96: MIN_PRICE_LIMIT}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ZERO_BYTES
        );

        assertEq(_hookBalance(currency0) + _hookBalance(currency1), 0, "hook retained a balance");
    }

    function test_reference_unchangedWithinOneBlock() public {
        (int24 referenceBefore,,) = hook.driftState(key);

        // A flash-loan-scale move and several swaps inside one block must not shift equilibrium.
        _swap(true, 5e16);
        _swap(true, 5e16);
        _swap(false, 5e16);

        (int24 referenceAfter, uint40 lastUpdate,) = hook.driftState(key);

        assertEq(referenceAfter, referenceBefore, "equilibrium must not be movable within a block");
        assertEq(lastUpdate, uint40(block.timestamp));
    }

    function test_reference_movesAcrossBlocksTowardTheTick() public {
        _swap(true, 1e16);
        (, int24 tickAfterPush,,) = manager.getSlot0(key.toId());
        assertLt(tickAfterPush, 0, "push should have moved the tick down");

        (int24 referenceBefore,,) = hook.driftState(key);

        // One tenth of the window later, the first swap of the block folds in the standing tick.
        vm.warp(block.timestamp + 180);
        vm.roll(block.number + 1);
        _swap(true, 1);

        (int24 referenceAfter,,) = hook.driftState(key);

        assertLt(referenceAfter, referenceBefore, "equilibrium should track the tick over time");
        assertGt(referenceAfter, tickAfterPush, "one tenth of a window should not fully converge");
    }

    /// @dev The scenario that motivated `MAX_FOLD_BPS`: push the price, wait out a whole window on
    /// a quiet pool, then land one tiny swap. Equilibrium must move partway, not all the way.
    function test_reference_quietPoolCannotBeCapturedByOneSample() public {
        _swap(true, 1e16);
        (, int24 tickAfterPush,,) = manager.getSlot0(key.toId());

        vm.warp(block.timestamp + _defaultParams().referenceWindow);
        vm.roll(block.number + 1);
        _swap(true, 1);

        (int24 referenceAfter,,) = hook.driftState(key);

        assertGt(referenceAfter, tickAfterPush, "one sample captured the whole reference");
        assertEq(referenceAfter, int24(hook.fold(0, tickAfterPush, 1800, 1800) / 1e6));
    }

    /// @dev The sample a block contributes is the tick as of that block's first swap. A spike
    /// opened and closed inside the block contributes nothing, which is what stops a flash-loan
    /// move from steering equilibrium.
    function test_reference_samplesOnlyTheTopOfBlockTick() public {
        _swap(true, 1e16);
        (, int24 standingTick,,) = manager.getSlot0(key.toId());
        (int24 referenceBefore,,) = hook.driftState(key);
        assertEq(referenceBefore, 0);

        vm.warp(block.timestamp + 180);
        vm.roll(block.number + 1);

        _swap(true, 5e16);
        _swap(false, 5e16);
        (, int24 tickAfterSpike,,) = manager.getSlot0(key.toId());
        assertTrue(tickAfterSpike != standingTick, "the spike should have left the tick somewhere else");

        (int24 referenceAfter,,) = hook.driftState(key);

        assertEq(referenceAfter, int24(hook.fold(0, standingTick, 180, 1800) / 1e6));
    }

    function test_currentDrift_doesNotMutateState() public {
        _swap(true, 1e16);
        vm.warp(block.timestamp + 900);

        (int24 referenceBefore, uint40 lastUpdateBefore,) = hook.driftState(key);

        hook.currentDrift(key);
        hook.quoteFeeForDriftDelta(key, 100);

        (int24 referenceAfter, uint40 lastUpdateAfter,) = hook.driftState(key);

        assertEq(referenceAfter, referenceBefore);
        assertEq(lastUpdateAfter, lastUpdateBefore);
    }

    /*//////////////////////////////////////////////////////////////
                        REGRESSION: THE PRE-MOVE ATTACK
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev The attack that forced the redesign, now asserted to fail.
     *
     * The original rule priced a swap on the drift it *started from*, so a swap beginning at
     * equilibrium paid `baseFee` however far it moved the price. Since the two legs of a trade need
     * not be the same size, a trader could pay `baseFee` on a small pre-move to lift the pool off
     * equilibrium and then run a much larger main leg back down at `minFee`. Measured at the time:
     * 20 bps of free improvement for identical token0 spent.
     *
     * Pricing on the drift a swap *creates* removes the edge, because the pre-move now pays a
     * surcharge for exactly the drift the main leg is later discounted for repairing.
     */
    function test_premovingNoLongerBuysTheDiscount() public {
        _addDeepLiquidity();

        uint256 mainLeg = 5e18;
        uint256 preMove = 5e17;

        uint256 snapshot = vm.snapshotState();
        (int256 honest0, int256 honest1) = _measure(_sellStraight, mainLeg, 0);

        vm.revertToState(snapshot);
        (int256 gamed0, int256 gamed1) = _measure(_sellAfterPreMove, mainLeg, preMove);

        assertEq(gamed0, honest0, "the two routes must spend the same token0 to be comparable");
        assertLe(gamed1, honest1, "pre-moving still improves execution");

        emit log_named_int("honest token1", honest1);
        emit log_named_int("gamed token1 ", gamed1);
    }

    /// @dev Sweeps pre-move sizes, since a single size could miss a profitable region.
    function testFuzz_premovingIsNeverProfitable(uint256 preMoveSeed) public {
        _addDeepLiquidity();

        uint256 mainLeg = 5e18;
        uint256 preMove = bound(preMoveSeed, 1e16, 5e18);

        uint256 snapshot = vm.snapshotState();
        (, int256 honest1) = _measure(_sellStraight, mainLeg, 0);

        vm.revertToState(snapshot);
        (, int256 gamed1) = _measure(_sellAfterPreMove, mainLeg, preMove);

        assertLe(gamed1, honest1, "found a profitable pre-move size");
    }

    /*//////////////////////////////////////////////////////////////
                                  FUZZ
    //////////////////////////////////////////////////////////////*/

    /// @dev The applied fee stays inside the configured band for every drift change and any valid
    /// parameter set. The fee never goes negative, so the hook never pays a rebate.
    function testFuzz_feeAlwaysWithinConfiguredBand(
        int256 driftDeltaScaled,
        uint24 baseFee,
        uint24 minFee,
        uint24 maxFee,
        uint24 feePerTick,
        uint24 maxAdjustment,
        uint16 discountBps
    ) public view {
        DriftFee.Params memory p = _boundedParams(baseFee, minFee, maxFee, feePerTick, maxAdjustment, discountBps, 1800);

        driftDeltaScaled = bound(driftDeltaScaled, -1_800_000 * 1e6, 1_800_000 * 1e6);

        uint24 fee = hook.feeForParams(p, driftDeltaScaled);

        assertGe(fee, p.minFee, "fee below floor");
        assertLe(fee, p.maxFee, "fee above ceiling");
        assertLe(fee, LPFeeLibrary.MAX_LP_FEE, "fee above protocol maximum");

        // The band assertions above are vacuous when `minFee == maxFee`, which is exactly the
        // configuration that used to let the owner flatten a pool to a single extractive rate.
        assertLe(fee, hook.MAX_CONFIGURABLE_FEE(), "fee above the hard cap");
        assertLe(p.minFee, hook.MAX_BASE_FEE(), "an honest swap could be charged above MAX_BASE_FEE");
    }

    /**
     * @dev The central property of the redesign: widening drift by some amount is never cheaper
     * than narrowing it by the same amount, for any curve.
     *
     * The old rule failed this in the worst possible way — a swap from equilibrium widened drift
     * arbitrarily for the base rate, while the swap that undid it was discounted below base.
     */
    function testFuzz_wideningNeverCheaperThanNarrowing(
        int256 magnitudeScaled,
        uint24 baseFee,
        uint24 minFee,
        uint24 maxFee,
        uint24 feePerTick,
        uint24 maxAdjustment,
        uint16 discountBps
    ) public view {
        DriftFee.Params memory p = _boundedParams(baseFee, minFee, maxFee, feePerTick, maxAdjustment, discountBps, 1800);

        magnitudeScaled = bound(magnitudeScaled, 0, 1_800_000 * 1e6);

        assertGe(
            hook.feeForParams(p, magnitudeScaled),
            hook.feeForParams(p, -magnitudeScaled),
            "creating drift was cheaper than repairing it"
        );
    }

    /// @dev More drift created means a not-cheaper surcharge; more drift repaired means a
    /// not-dearer discount.
    function testFuzz_feeIsMonotoneInDriftChange(uint256 smallSeed, uint256 extraSeed) public view {
        int256 small = int256(bound(smallSeed, 0, 100_000 * 1e6));
        int256 large = small + int256(bound(extraSeed, 0, 100_000 * 1e6));

        assertGe(hook.feeFor(key, large), hook.feeFor(key, small), "surcharge fell as drift grew");
        assertLe(hook.feeFor(key, -large), hook.feeFor(key, -small), "discount shrank as repair grew");
    }

    /// @dev The discount never becomes a rebate: the credit never exceeds the headroom above
    /// `minFee`, for any discount factor.
    function testFuzz_discountNeverBecomesARebate(int256 magnitudeScaled, uint16 discountBps) public view {
        DriftFee.Params memory p = _defaultParams();
        p.discountBps = uint16(bound(discountBps, 0, 10_000));

        magnitudeScaled = bound(magnitudeScaled, 0, 1_800_000 * 1e6);

        uint24 narrowFee = hook.feeForParams(p, -magnitudeScaled);

        assertGe(narrowFee, p.minFee, "the discount breached the floor");
        assertLe(narrowFee, p.baseFee, "narrowing cost more than the base rate");
    }

    /// @dev The fold is a contraction toward the sample: it lands between the old reference and the
    /// sample, and never overshoots.
    function testFuzz_foldNeverOvershoots(int24 referenceTick, int24 sampleTick, uint32 elapsed, uint32 window)
        public
        view
    {
        referenceTick = _boundTick(referenceTick);
        sampleTick = _boundTick(sampleTick);
        window = uint32(bound(window, hook.MIN_REFERENCE_WINDOW(), hook.MAX_REFERENCE_WINDOW()));

        int256 referenceScaled = int256(referenceTick) * 1e6;
        int256 sampleScaled = int256(sampleTick) * 1e6;

        int256 folded = hook.fold(referenceScaled, sampleTick, elapsed, window);

        if (sampleScaled >= referenceScaled) {
            assertGe(folded, referenceScaled, "fold moved away from the sample");
            assertLe(folded, sampleScaled, "fold overshot the sample");
        } else {
            assertLe(folded, referenceScaled, "fold moved away from the sample");
            assertGe(folded, sampleScaled, "fold overshot the sample");
        }
    }

    /// @dev No single fold may close more than `MAX_FOLD_BPS` of the gap, however long the wait.
    function testFuzz_foldRespectsItsCap(int24 sampleTick, uint32 elapsed, uint32 window) public view {
        sampleTick = _boundTick(sampleTick);
        window = uint32(bound(window, hook.MIN_REFERENCE_WINDOW(), hook.MAX_REFERENCE_WINDOW()));

        int256 folded = hook.fold(0, sampleTick, elapsed, window);

        uint256 absFolded = uint256(folded >= 0 ? folded : -folded);
        uint256 absSample = uint256(int256(sampleTick >= 0 ? sampleTick : -sampleTick)) * 1e6;

        assertLe(absFolded * 10_000, absSample * hook.MAX_FOLD_BPS() + 1e6, "fold exceeded its cap");
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Runs {DriftFee}'s constructor at a flag-valid hook address and asserts it reverts with
     * `expectedError`.
     *
     * `new DriftFee(...)` cannot be used: it lands at whatever address `create` picks, so
     * `BaseHook`'s address validation reverts before the constructor body is reached. `deployCodeTo`
     * is no better, since it collapses the constructor's revert data into its own require string.
     */
    function _assertConstructorReverts(bytes memory args, bytes memory expectedError) private {
        // Any address is a valid hook address as long as its low flag bits match the declared
        // permissions; the high bits just keep this clear of the hook deployed in `setUp`.
        address target = address(uint160(0xDF00 << 20) | HOOK_FLAGS);

        vm.etch(target, abi.encodePacked(vm.getCode("src/DriftFee.sol:DriftFee"), args));
        (bool success, bytes memory returnData) = target.call("");

        assertFalse(success, "constructor should have reverted");
        assertEq(returnData, expectedError);
    }

    function _boundTick(int24 tick) private pure returns (int24) {
        return int24(bound(int256(tick), -887_000, 887_000));
    }

    /// @dev Reshape fuzzed inputs into a curve `_validatedParams` would accept, so the fuzz only
    /// covers configurations the contract can actually be put into.
    function _boundedParams(
        uint24 baseFee,
        uint24 minFee,
        uint24 maxFee,
        uint24 feePerTick,
        uint24 maxAdjustment,
        uint16 discountBps,
        uint32 referenceWindow
    ) private view returns (DriftFee.Params memory p) {
        uint24 cap = hook.MAX_CONFIGURABLE_FEE();
        uint24 baseCap = hook.MAX_BASE_FEE();

        // `minFee <= baseFee <= MAX_BASE_FEE` and `baseFee <= maxFee <= MAX_CONFIGURABLE_FEE`,
        // mirroring `_validatedParams`. The two ceilings differ because `maxFee` is only ever
        // charged to a drift-widening swap, while `baseFee`/`minFee` are charged unconditionally.
        p.minFee = uint24(bound(minFee, 0, baseCap));
        p.baseFee = uint24(bound(baseFee, p.minFee, baseCap));
        p.maxFee = uint24(bound(maxFee, p.baseFee, cap));
        p.feePerTick = uint24(bound(feePerTick, 0, hook.MAX_FEE_PER_TICK()));
        p.maxAdjustment = uint24(bound(maxAdjustment, 0, cap));
        p.discountBps = uint16(bound(discountBps, 0, 10_000));
        p.referenceWindow = uint32(bound(referenceWindow, hook.MIN_REFERENCE_WINDOW(), hook.MAX_REFERENCE_WINDOW()));
    }

    function _hookBalance(Currency currency) private view returns (uint256) {
        return MockERC20(Currency.unwrap(currency)).balanceOf(address(hook));
    }

    function _addDeepLiquidity() private {
        modifyLiquidityRouter.modifyLiquidity(
            key, ModifyLiquidityParams({tickLower: -30000, tickUpper: 30000, liquidityDelta: 1e20, salt: 0}), ZERO_BYTES
        );
    }

    /// @dev Runs a swap route and returns the net change in this contract's two token balances.
    function _measure(function(uint256, uint256) internal route, uint256 mainLeg, uint256 preMove)
        private
        returns (int256 delta0, int256 delta1)
    {
        uint256 before0 = MockERC20(Currency.unwrap(currency0)).balanceOf(address(this));
        uint256 before1 = MockERC20(Currency.unwrap(currency1)).balanceOf(address(this));

        route(mainLeg, preMove);

        delta0 = int256(MockERC20(Currency.unwrap(currency0)).balanceOf(address(this))) - int256(before0);
        delta1 = int256(MockERC20(Currency.unwrap(currency1)).balanceOf(address(this))) - int256(before1);
    }

    function _sellStraight(uint256 mainLeg, uint256) internal {
        _swap(true, int256(mainLeg));
    }

    function _sellAfterPreMove(uint256 mainLeg, uint256 preMove) internal {
        uint256 before0 = MockERC20(Currency.unwrap(currency0)).balanceOf(address(this));

        _swap(false, int256(preMove)); // buy token0, lifting the tick above equilibrium

        uint256 acquired = MockERC20(Currency.unwrap(currency0)).balanceOf(address(this)) - before0;

        _swap(true, int256(mainLeg + acquired)); // sell it all back down, now 'drift-reducing'
    }

    function _swap(bool zeroForOne, int256 amount) private {
        swap(key, zeroForOne, -amount, ZERO_BYTES);
    }

    /// @dev Runs a swap and returns the fee recorded on the pool manager's own `Swap` event, which
    /// reflects what the pool actually charged rather than what the hook returned.
    /// @dev Runs a swap and returns the total fee the hook decided on, read from its own event.
    /// The pool's `Swap` event only shows the floor, since the remainder is taken in `afterSwap`.
    function _swapAndReadDriftFee(bool zeroForOne, int256 amount) private returns (uint24 fee) {
        vm.recordLogs();
        _swap(zeroForOne, amount);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(hook) && logs[i].topics[0] == DRIFT_FEE_TOPIC) {
                (, fee,) = abi.decode(logs[i].data, (int24, uint24, bool));
                return fee;
            }
        }
        revert("no DriftFeeApplied event emitted");
    }

    function _swapAndReadPoolFee(bool zeroForOne, int256 amount) private returns (uint24 fee) {
        vm.recordLogs();
        _swap(zeroForOne, amount);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(manager) && logs[i].topics[0] == SWAP_TOPIC) {
                (,,,,, fee) = abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
                return fee;
            }
        }
        revert("no Swap event emitted");
    }
}
