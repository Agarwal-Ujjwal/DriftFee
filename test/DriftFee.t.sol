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
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {DriftFee} from "src/DriftFee.sol";
import {BaseOverrideFee} from "uniswap-hooks/fee/BaseOverrideFee.sol";
import {DriftFeeHarness} from "./utils/DriftFeeHarness.sol";

contract DriftFeeTest is Test, Deployers {
    using StateLibrary for IPoolManager;

    /// @dev Signature of the pool manager's `Swap` event, used to read the fee the pool actually
    /// charged rather than the fee the hook merely claimed to return.
    bytes32 private constant SWAP_TOPIC = keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");

    uint160 private constant HOOK_FLAGS = uint160(Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG);

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
        (int24 referenceTick, uint32 lastUpdate, bool initialized) = hook.driftState(key);

        (, int24 currentTick,,) = manager.getSlot0(key.toId());

        assertTrue(initialized, "reference not seeded");
        assertEq(referenceTick, currentTick, "reference should start at the initialization tick");
        assertEq(lastUpdate, uint32(block.timestamp));
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

        // The pool charges its own curve, not the default.
        assertEq(_swapAndReadPoolFee(true, 1e15), 100);
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

    function test_feeFor_atEquilibrium_isBaseFee() public view {
        (uint24 feeUp, int24 drift, bool movingAway) = hook.feeFor(key, 0, 0, false);
        (uint24 feeDown,,) = hook.feeFor(key, 0, 0, true);

        assertEq(feeUp, _defaultParams().baseFee);
        assertEq(feeDown, _defaultParams().baseFee);
        assertEq(drift, 0);
        assertFalse(movingAway);
    }

    function test_feeFor_awayFromEquilibrium_surcharges() public view {
        DriftFee.Params memory p = _defaultParams();

        // Pool 50 ticks above equilibrium, swap pushes the tick up again.
        (uint24 fee, int24 drift, bool movingAway) = hook.feeFor(key, 0, 50, false);

        assertTrue(movingAway);
        assertEq(drift, 50);
        assertEq(fee, p.baseFee + 50 * p.feePerTick);
    }

    function test_feeFor_towardEquilibrium_discounts() public view {
        DriftFee.Params memory p = _defaultParams();

        // Pool 50 ticks above equilibrium, swap pushes the tick back down.
        (uint24 fee, int24 drift, bool movingAway) = hook.feeFor(key, 0, 50, true);

        assertFalse(movingAway);
        assertEq(drift, 50);
        assertEq(fee, p.baseFee - 50 * p.feePerTick);
    }

    function test_feeFor_isSymmetricBelowEquilibrium() public view {
        (uint24 awayAbove,,) = hook.feeFor(key, 0, 50, false);
        (uint24 awayBelow,,) = hook.feeFor(key, 0, -50, true);
        (uint24 towardAbove,,) = hook.feeFor(key, 0, 50, true);
        (uint24 towardBelow,,) = hook.feeFor(key, 0, -50, false);

        assertEq(awayAbove, awayBelow, "surcharge should not depend on the sign of drift");
        assertEq(towardAbove, towardBelow, "discount should not depend on the sign of drift");
    }

    function test_feeFor_clampsAtMaxFee() public view {
        (uint24 fee,,) = hook.feeFor(key, 0, 2000, false);
        assertEq(fee, _defaultParams().maxFee);
    }

    function test_feeFor_clampsAtMinFee() public view {
        (uint24 fee,,) = hook.feeFor(key, 0, 2000, true);
        assertEq(fee, _defaultParams().minFee);
    }

    function test_feeFor_subTickDriftIsPriced() public view {
        DriftFee.Params memory p = _defaultParams();

        // Reference half a tick below the current tick: drift truncates to 0 ticks, but the
        // adjustment is computed on the scaled value so half a tick of drift still prices.
        (uint24 fee, int24 drift,) = hook.feeFor(key, -5e5, 0, false);

        assertEq(drift, 0, "sub-tick drift truncates in the reported value");
        assertEq(fee, p.baseFee + p.feePerTick / 2, "sub-tick drift should still move the fee");
    }

    /**
     * @dev Pins the precision of the discount path.
     *
     * The adjustment is held in scaled units until the final division, so a sub-unit adjustment
     * survives long enough for `discountBps` to apply to it. Dividing down to whole hundredths of a
     * bip first — the obvious way to write this — would floor 1.9 to 1, then floor 90% of 1 to 0,
     * and return `baseFee` unchanged.
     */
    function test_feeFor_discountKeepsSubUnitPrecision() public view {
        DriftFee.Params memory p = _defaultParams();
        p.feePerTick = 1;
        p.discountBps = 9000;
        p.minFee = 0;

        // Reference a tenth of a tick above zero with the pool at tick 2: 1.9 ticks of drift, so a
        // raw adjustment of 1.9 units, of which 90% is 1.71.
        (uint24 fee,, bool movingAway) = hook.feeForParams(p, 1e5, 2, true);

        assertFalse(movingAway);
        assertEq(fee, p.baseFee - 1);
    }

    function test_feeFor_respectsDiscountFactor() public {
        DriftFee.Params memory p = _defaultParams();
        p.discountBps = 5000; // credit only half the adjustment back

        vm.prank(owner);
        hook.setDefaultParams(p);

        (uint24 fee,,) = hook.feeFor(key, 0, 50, true);
        assertEq(fee, p.baseFee - (50 * p.feePerTick) / 2);
    }

    /*//////////////////////////////////////////////////////////////
                            REFERENCE FOLD
    //////////////////////////////////////////////////////////////*/

    function test_fold_zeroElapsed_isNoop() public view {
        assertEq(hook.fold(0, 1000, 0, 1800), 0);
    }

    function test_fold_fullWindow_convergesToSample() public view {
        assertEq(hook.fold(0, 1000, 1800, 1800), 1000e6);
    }

    function test_fold_isCappedAtOneWindow() public view {
        assertEq(hook.fold(0, 1000, 100 days, 1800), hook.fold(0, 1000, 1800, 1800));
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

    function test_swap_atEquilibrium_poolChargesBaseFee() public {
        // Guards the failure mode where a hook returns a fee without the override flag and the pool
        // silently keeps charging its stored fee: this reads the fee off the pool's own event.
        assertEq(_swapAndReadPoolFee(true, 1e15), _defaultParams().baseFee);
    }

    function test_swap_awayFromEquilibrium_costsMoreThanBase() public {
        _swap(true, 1e16); // push the tick well below equilibrium

        uint24 fee = _swapAndReadPoolFee(true, 1e15); // keep pushing, same direction

        assertGt(fee, _defaultParams().baseFee, "widening drift should be surcharged");
    }

    function test_swap_towardEquilibrium_costsLessThanBase() public {
        _swap(true, 1e16); // push the tick well below equilibrium

        uint24 fee = _swapAndReadPoolFee(false, 1e15); // swap back toward it

        assertLt(fee, _defaultParams().baseFee, "narrowing drift should be discounted");
    }

    function test_swap_awayCostsMoreThanToward() public {
        _swap(true, 1e16);

        uint24 awayFee = hook.quoteFee(key, true);
        uint24 towardFee = hook.quoteFee(key, false);

        assertGt(awayFee, towardFee);
    }

    function test_reference_unchangedWithinOneBlock() public {
        (int24 referenceBefore,,) = hook.driftState(key);

        // A flash-loan-scale move and several swaps inside one block must not shift equilibrium.
        _swap(true, 5e16);
        _swap(true, 5e16);
        _swap(false, 5e16);

        (int24 referenceAfter, uint32 lastUpdate,) = hook.driftState(key);

        assertEq(referenceAfter, referenceBefore, "equilibrium must not be movable within a block");
        assertEq(lastUpdate, uint32(block.timestamp));
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

    function test_reference_convergesAfterFullWindow() public {
        _swap(true, 1e16);
        (, int24 tickAfterPush,,) = manager.getSlot0(key.toId());

        vm.warp(block.timestamp + _defaultParams().referenceWindow);
        vm.roll(block.number + 1);
        _swap(true, 1);

        (int24 referenceAfter,,) = hook.driftState(key);

        assertEq(referenceAfter, tickAfterPush, "a full window should converge on the standing tick");
    }

    /// @dev The sample a block contributes is the tick as of that block's first swap. A spike
    /// opened and closed inside the block contributes nothing, which is what stops a flash-loan
    /// move from steering equilibrium.
    function test_reference_samplesOnlyTheTopOfBlockTick() public {
        // Block N: move the price and leave it there. The reference is still exactly its seeded
        // value, because the fold only runs once `block.timestamp` has advanced.
        _swap(true, 1e16);
        (, int24 standingTick,,) = manager.getSlot0(key.toId());
        (int24 referenceBefore,,) = hook.driftState(key);
        assertEq(referenceBefore, 0);

        vm.warp(block.timestamp + 180);
        vm.roll(block.number + 1);

        // Block N+1: an enormous spike, unwound within the same block.
        _swap(true, 5e16);
        _swap(false, 5e16);
        (, int24 tickAfterSpike,,) = manager.getSlot0(key.toId());
        assertTrue(tickAfterSpike != standingTick, "the spike should have left the tick somewhere else");

        (int24 referenceAfter,,) = hook.driftState(key);

        // Equilibrium folded in `standingTick` and nothing else: not the spike's extreme, and not
        // where the unwind happened to land.
        assertEq(referenceAfter, int24(hook.fold(0, standingTick, 180, 1800) / 1e6));
    }

    function test_quoteFee_doesNotMutateState() public {
        _swap(true, 1e16);
        vm.warp(block.timestamp + 900);

        (int24 referenceBefore, uint32 lastUpdateBefore,) = hook.driftState(key);

        hook.quoteFee(key, true);
        hook.quoteFee(key, false);

        (int24 referenceAfter, uint32 lastUpdateAfter,) = hook.driftState(key);

        assertEq(referenceAfter, referenceBefore);
        assertEq(lastUpdateAfter, lastUpdateBefore);
    }

    function test_quoteFee_matchesTheFeeTheSwapPays() public {
        _swap(true, 1e16);

        uint24 quoted = hook.quoteFee(key, false);
        assertEq(_swapAndReadPoolFee(false, 1e15), quoted);
    }

    /*//////////////////////////////////////////////////////////////
                                  FUZZ
    //////////////////////////////////////////////////////////////*/

    /// @dev The applied fee stays inside the configured band for every reachable drift and any
    /// valid parameter set. This is what makes a discount non-extractable: the fee never goes
    /// negative, so the hook never pays a rebate.
    function testFuzz_feeAlwaysWithinConfiguredBand(
        int24 referenceTick,
        int24 currentTick,
        bool zeroForOne,
        uint24 baseFee,
        uint24 minFee,
        uint24 maxFee,
        uint24 feePerTick,
        uint24 maxAdjustment,
        uint16 discountBps
    ) public view {
        DriftFee.Params memory p = _boundedParams(baseFee, minFee, maxFee, feePerTick, maxAdjustment, discountBps, 1800);

        referenceTick = _boundTick(referenceTick);
        currentTick = _boundTick(currentTick);

        (uint24 fee,,) = hook.feeForParams(p, int256(referenceTick) * 1e6, currentTick, zeroForOne);

        assertGe(fee, p.minFee, "fee below floor");
        assertLe(fee, p.maxFee, "fee above ceiling");
        assertLe(fee, LPFeeLibrary.MAX_LP_FEE, "fee above protocol maximum");
    }

    /// @dev Drift-widening swaps never pay less than the base fee, and drift-narrowing swaps never
    /// pay more. Without this the hook would be subsidizing the direction it means to penalize.
    function testFuzz_directionalOrdering(int24 referenceTick, int24 currentTick, bool zeroForOne) public view {
        referenceTick = _boundTick(referenceTick);
        currentTick = _boundTick(currentTick);

        (uint24 fee,, bool movingAway) = hook.feeFor(key, int256(referenceTick) * 1e6, currentTick, zeroForOne);
        uint24 baseFee = _defaultParams().baseFee;

        if (movingAway) {
            assertGe(fee, baseFee);
        } else {
            assertLe(fee, baseFee);
        }
    }

    /// @dev More drift means a strictly-not-cheaper surcharge and a strictly-not-dearer discount.
    function testFuzz_feeIsMonotoneInDrift(uint24 smallDrift, uint24 extraDrift) public view {
        int24 small = int24(uint24(bound(smallDrift, 0, 100_000)));
        int24 large = small + int24(uint24(bound(extraDrift, 0, 100_000)));

        (uint24 awaySmall,,) = hook.feeFor(key, 0, small, false);
        (uint24 awayLarge,,) = hook.feeFor(key, 0, large, false);
        (uint24 towardSmall,,) = hook.feeFor(key, 0, small, true);
        (uint24 towardLarge,,) = hook.feeFor(key, 0, large, true);

        assertGe(awayLarge, awaySmall, "surcharge should not fall as drift grows");
        assertLe(towardLarge, towardSmall, "discount should not shrink as drift grows");
    }

    /// @dev The core economic invariant. Pushing the price away and then reverting it can never
    /// cost less in total than two swaps at the floor fee, so a manipulation round trip cannot be
    /// funded by the discount it creates.
    function testFuzz_roundTripNeverRebates(int24 driftTick, uint16 discountBps) public view {
        DriftFee.Params memory p = _defaultParams();
        p.discountBps = uint16(bound(discountBps, 0, 10_000));

        int24 drift = _boundTick(driftTick);

        (uint24 awayFee,,) = hook.feeForParams(p, 0, drift, drift >= 0 ? false : true);
        (uint24 towardFee,,) = hook.feeForParams(p, 0, drift, drift >= 0 ? true : false);

        assertGe(uint256(awayFee) + towardFee, uint256(p.minFee) * 2, "round trip must not be free");
        assertGe(awayFee, towardFee, "the reverting leg must never cost more than the pushing leg");
        assertLe(uint256(p.baseFee) - towardFee, uint256(p.baseFee) - p.minFee, "discount exceeded its headroom");
    }

    /// @dev The fold is a contraction toward the sample: it lands between the old reference and the
    /// sample, and never overshoots. A fold that overshot could be walked past the true price.
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

    /// @dev A single fold can never close more of the gap than `elapsed / window`, which is what
    /// bounds how fast a sustained manipulation could drag equilibrium.
    function testFuzz_foldRespectsItsTimeConstant(int24 sampleTick, uint32 elapsed) public view {
        sampleTick = _boundTick(sampleTick);
        uint32 window = 1800;
        elapsed = uint32(bound(elapsed, 0, window));

        int256 folded = hook.fold(0, sampleTick, elapsed, window);

        uint256 absFolded = uint256(folded >= 0 ? folded : -folded);
        uint256 absSample = uint256(int256(sampleTick >= 0 ? sampleTick : -sampleTick)) * 1e6;

        assertLe(absFolded * window, absSample * elapsed + 1e6, "fold closed more than its share of the gap");
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

        p.minFee = uint24(bound(minFee, 0, cap));
        p.baseFee = uint24(bound(baseFee, p.minFee, cap));
        p.maxFee = uint24(bound(maxFee, p.baseFee, cap));
        p.feePerTick = uint24(bound(feePerTick, 0, hook.MAX_FEE_PER_TICK()));
        p.maxAdjustment = uint24(bound(maxAdjustment, 0, cap));
        p.discountBps = uint16(bound(discountBps, 0, 10_000));
        p.referenceWindow = uint32(bound(referenceWindow, hook.MIN_REFERENCE_WINDOW(), hook.MAX_REFERENCE_WINDOW()));
    }

    function _swap(bool zeroForOne, int256 amount) private {
        swap(key, zeroForOne, -amount, ZERO_BYTES);
    }

    /// @dev Runs a swap and returns the fee recorded on the pool manager's own `Swap` event, which
    /// reflects what the pool actually charged rather than what the hook returned.
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
