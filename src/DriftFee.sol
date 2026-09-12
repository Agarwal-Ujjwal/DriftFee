// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// External imports
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {TransientSlot} from "@openzeppelin/contracts/utils/TransientSlot.sol";
import {SlotDerivation} from "@openzeppelin/contracts/utils/SlotDerivation.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
// Internal imports
import {BaseOverrideFee} from "uniswap-hooks/fee/BaseOverrideFee.sol";
import {BaseHook} from "uniswap-hooks/base/BaseHook.sol";
import {CurrencySettler} from "uniswap-hooks/utils/CurrencySettler.sol";

/**
 * @title DriftFee
 * @notice A Uniswap v4 dynamic-fee hook that prices each swap by the drift it *creates*: a trade
 * that pushes the pool price further from equilibrium pays a surcharge, and one that brings it back
 * pays a discount.
 *
 * @dev ## Equilibrium reference
 *
 * The reference ("equilibrium") price is deliberately NOT the pool's spot price. A flash loan can
 * move spot within a single transaction, so a spot-derived reference would let an attacker push the
 * price, collect the discounted "reverting" fee, and unwind. Instead the reference is a time-decayed
 * moving average of *top-of-block* ticks:
 *
 * - The reference is folded forward at most once per `block.timestamp`, and the sample it folds in
 *   is read in `beforeSwap`. The first swap at a given timestamp therefore contributes the tick as
 *   it stood before any swap in that block -- the same beginning-of-block checkpoint that
 *   `AntiSandwichHook` relies on. Later swaps in the same block cannot resample.
 * - The per-update weight is `min(elapsed, window) / window`, capped at {MAX_FOLD_BPS} of the
 *   remaining gap, so no single sample can replace the reference. Moving equilibrium requires
 *   holding a price across many separate timestamps against arbitrage, not one transaction.
 *
 * ## How the fee is charged, and why in two parts
 *
 * The fee is a function of the drift a swap **creates**: `|drift after| - |drift before|`. Widening
 * that gap is surcharged, narrowing it is discounted.
 *
 * That quantity is not knowable in `beforeSwap`, so charging happens in two steps. `beforeSwap`
 * overrides the pool's fee with {Params-minFee}, the floor everyone pays, which flows to liquidity
 * providers through the pool's own accounting. `afterSwap` then measures the drift actually created,
 * prices it, and takes the remainder from the swap's unspecified currency, donating it immediately
 * to the in-range liquidity providers. This contract never ends a call holding a balance, so the
 * owner never becomes the beneficiary of the fee it sets.
 *
 * An earlier version priced on the drift a swap *started from*. That was unsound, and the reason is
 * worth keeping: a swap beginning at equilibrium took the zero-drift branch and paid the base rate
 * however far it moved the price, so the trade that caused the damage paid nothing for it while the
 * trade that repaired it was discounted. Because the two legs of a trade need not be the same size,
 * a trader could pay the base rate on a small pre-move and run a much larger main leg back at the
 * floor -- measured at 20bps of free improvement before the fix, and a loss after it. Round trips
 * were also cheaper here than on a static-fee pool, which subsidised exactly the manipulation flow
 * this hook exists to price up. See `test_premovingNoLongerBuysTheDiscount`.
 *
 * NOTE: the floor is charged on the swap and the remainder on its output, so the two compound
 * rather than summing exactly. The difference is second-order at these rates.
 *
 * ## Trust surface
 *
 * Parameters are owner-controlled, per pool with a global default. {Params-baseFee} and
 * {Params-minFee} are bounded by {MAX_BASE_FEE} and {Params-maxFee} by {MAX_CONFIGURABLE_FEE}, and
 * every window is floored at {MIN_REFERENCE_WINDOW}, so the owner cannot flatten a pool to a single
 * extractive rate or shorten a window into manipulability.
 *
 * Those caps bound the per-swap *rate* and nothing else. They do not bound cumulative extraction,
 * do not grandfather existing pools, and there is no timelock: a change applies from the next swap,
 * and because the hook address is part of `PoolKey` a pool can never migrate away from it. The owner
 * is not the beneficiary -- fees accrue to LPs and this contract has no withdrawal path -- so the
 * worst case is griefing rather than self-dealing, unless the owner is also a dominant LP. Ownership
 * belongs behind a multisig and timelock, not the EOA that ran the deploy script.
 *
 * NOTE: no reentrancy guard is applied. The hook entry points are `onlyPoolManager`, hold no funds,
 * and make no external calls other than `extsload` reads of the manager, so there is no reentrant
 * path to protect; a guard here would instead risk reverting legitimate nested manager flows.
 *
 * WARNING: unaudited, experimental software, provided as is with no warranty.
 */
contract DriftFee is BaseOverrideFee, Ownable2Step {
    using StateLibrary for IPoolManager;
    using SafeCast for int256;
    using SafeCast for uint256;
    using TransientSlot for *;
    using SlotDerivation for *;
    using CurrencySettler for Currency;

    /// @dev keccak256(abi.encode(uint256(keccak256("driftfee.storage.pendingDrift")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant PENDING_DRIFT_SLOT = 0x9a1f9d26b6a2ec78f0c2c40e1ba4b8dcec2ec0e97eeb8fdd25e0a5d1bd3f3300;

    /// @dev Fixed-point scale for the stored reference tick, so sub-tick drift is not truncated.
    int256 private constant TICK_SCALE = 1e6;

    /// @dev Denominator for basis-point parameters.
    uint256 private constant BPS_DENOMINATOR = 10_000;

    /// @dev Denominator for fee rates, which are in hundredths of a bip.
    uint256 private constant MAX_PIPS = 1e6;

    /// @dev Hard ceiling on any configurable fee, in hundredths of a bip (3e4 = 3%). This bounds
    /// `maxFee`, which is only ever charged to a swap that widens drift.
    uint24 public constant MAX_CONFIGURABLE_FEE = 3e4;

    /// @dev Hard ceiling on {Params-baseFee}, and so transitively on {Params-minFee}, since
    /// validation requires `minFee <= baseFee`.
    ///
    /// These need a tighter bound than `maxFee`: `baseFee` is what a drift-neutral swap pays and
    /// `minFee` is what a drift-reducing swap pays, so together they are the floor on what an
    /// honest trader is charged unconditionally. Bounding only `maxFee` left
    /// `minFee == baseFee == maxFee == MAX_CONFIGURABLE_FEE` valid, which is a flat fee at the
    /// ceiling in both directions with the drift mechanism switched off entirely.
    uint24 public constant MAX_BASE_FEE = 1e4;

    /// @dev Shortest permitted reference time constant, matching the 30-minute floor for
    /// manipulation-resistant onchain price references.
    uint32 public constant MIN_REFERENCE_WINDOW = 1800;

    /// @dev Longest permitted reference time constant, so a pool cannot be handed a reference that
    /// never tracks the market.
    uint32 public constant MAX_REFERENCE_WINDOW = 7 days;

    /// @dev Ceiling on {Params-feePerTick}, bounding surcharge sensitivity.
    uint24 public constant MAX_FEE_PER_TICK = 1e3;

    /// @dev Most of the gap to a sample that any single fold may close, in basis points.
    ///
    /// Without this the weight reaches exactly 1.0 once `elapsed >= window`, so one sample replaces
    /// the reference outright and a pool that has merely been quiet for a window can have its
    /// equilibrium set by a single swap. Capping the per-fold weight restores the property the
    /// design depends on: moving equilibrium requires holding a price across many separate
    /// timestamps, not landing one sample after a lull.
    uint256 public constant MAX_FOLD_BPS = 2000;

    /**
     * @dev Fee curve configuration.
     *
     * @param baseFee Fee charged when a swap is drift-neutral, in hundredths of a bip.
     * @param minFee Floor on the applied fee; the discount can never push the fee below this.
     * @param maxFee Ceiling on the applied fee.
     * @param feePerTick Adjustment per tick of absolute drift, in hundredths of a bip.
     * @param maxAdjustment Cap on the raw drift adjustment, before the discount factor applies.
     * @param discountBps Fraction of the drift adjustment credited to drift-reducing swaps.
     * @param referenceWindow Time constant of the equilibrium average, in seconds.
     */
    struct Params {
        uint24 baseFee;
        uint24 minFee;
        uint24 maxFee;
        uint24 feePerTick;
        uint24 maxAdjustment;
        uint16 discountBps;
        uint32 referenceWindow;
    }

    /**
     * @dev Per-pool equilibrium state.
     *
     * @param referenceTickScaled The equilibrium tick, scaled by {TICK_SCALE}.
     * @param lastUpdate Timestamp at which the reference was last folded forward.
     * @param initialized Whether the reference has been seeded for this pool.
     */
    struct DriftState {
        int96 referenceTickScaled;
        // `uint40`, not `uint32`: `SafeCast.toUint32` reverts rather than truncating, so a `uint32`
        // field would brick every swap and every new pool on 2106-02-07 with no migration path,
        // since the hook address is part of `PoolKey`. 136 bits still occupies one slot.
        uint40 lastUpdate;
        bool initialized;
    }

    /// @dev Curve applied to any pool without an override.
    Params private _defaultCurve;

    /// @dev Per-pool curve overrides. A `referenceWindow` of zero means "no override", which is
    /// unambiguous because {_validatedParams} floors every stored window at {MIN_REFERENCE_WINDOW}.
    mapping(PoolId id => Params curve) private _poolCurves;

    mapping(PoolId id => DriftState state) private _driftStates;

    /// @dev The equilibrium reference for `id` moved to `referenceTick` after folding in `sampleTick`.
    event ReferenceTickUpdated(PoolId indexed id, int24 referenceTick, int24 sampleTick);

    /// @dev The equilibrium reference for `id` was seeded at `referenceTick`.
    event ReferenceTickSeeded(PoolId indexed id, int24 referenceTick);

    /// @dev A swap on `id` at `drift` ticks from equilibrium was charged `fee`; `movingAway` marks
    /// whether the swap increases absolute drift.
    event DriftFeeApplied(PoolId indexed id, int24 drift, uint24 fee, bool movingAway);

    /// @dev The default fee curve was reconfigured.
    event DefaultParamsUpdated(Params params);

    /// @dev `id` was given its own fee curve, overriding the default.
    event PoolParamsUpdated(PoolId indexed id, Params params);

    /// @dev `id` reverted to the default fee curve.
    event PoolParamsCleared(PoolId indexed id);

    /// @dev A parameter was outside its permitted range, or the curve was internally inconsistent.
    error InvalidParams();

    /// @dev The pool manager address was zero.
    error InvalidPoolManager();

    /**
     * @param _poolManager The v4 pool manager singleton.
     * @param initialOwner Account permitted to reconfigure fee curves.
     * @param initialParams Initial default fee curve, validated by {_validatedParams}.
     */
    constructor(IPoolManager _poolManager, address initialOwner, Params memory initialParams)
        BaseHook(_poolManager)
        Ownable(initialOwner)
    {
        if (address(_poolManager) == address(0)) revert InvalidPoolManager();

        _defaultCurve = _validatedParams(initialParams);

        emit DefaultParamsUpdated(initialParams);
    }

    /// @notice The curve applied to pools without an override.
    function defaultParams() external view returns (Params memory) {
        return _defaultCurve;
    }

    /// @notice The curve actually applied to `key`, whether that is its override or the default.
    function paramsFor(PoolKey calldata key) external view returns (Params memory) {
        return _effectiveParams(key.toId());
    }

    /// @notice Whether `key` has a curve of its own.
    function hasPoolParams(PoolKey calldata key) external view returns (bool) {
        return _poolCurves[key.toId()].referenceWindow != 0;
    }

    /**
     * @notice The equilibrium state tracked for `key`.
     *
     * @return referenceTick The equilibrium tick, truncated toward zero.
     * @return lastUpdate Timestamp the reference was last folded forward.
     * @return initialized Whether the reference has been seeded.
     */
    function driftState(PoolKey calldata key)
        external
        view
        returns (int24 referenceTick, uint40 lastUpdate, bool initialized)
    {
        DriftState storage state = _driftStates[key.toId()];
        return ((int256(state.referenceTickScaled) / TICK_SCALE).toInt24(), state.lastUpdate, state.initialized);
    }

    /**
     * @notice The fee a swap would pay for changing the pool's distance from equilibrium by
     * `driftDeltaTicks`.
     *
     * @dev A pre-swap quote cannot be a function of direction alone any more, and that is the fix,
     * not a regression: the fee depends on the drift a swap *creates*, which is not knowable until
     * its size and the pool's liquidity are known. Callers that want a quote should estimate the
     * post-swap tick themselves and pass `|drift after| - |drift before|` in ticks.
     *
     * Positive widens the gap and is surcharged; negative narrows it and is discounted.
     */
    function quoteFeeForDriftDelta(PoolKey calldata key, int24 driftDeltaTicks) external view returns (uint24) {
        return _feeForDriftDelta(_effectiveParams(key.toId()), int256(driftDeltaTicks) * TICK_SCALE);
    }

    /// @notice The pool's current distance from equilibrium, in ticks. Positive means the pool sits
    /// above its reference.
    function currentDrift(PoolKey calldata key) external view returns (int24) {
        PoolId id = key.toId();

        // slither-disable-next-line unused-return
        (, int24 currentTick,,) = poolManager.getSlot0(id);

        DriftState storage state = _driftStates[id];
        int256 referenceScaled = state.initialized
            ? _foldedReference(state, currentTick, _effectiveParams(id).referenceWindow)
            : int256(currentTick) * TICK_SCALE;

        return ((int256(currentTick) * TICK_SCALE - referenceScaled) / TICK_SCALE).toInt24();
    }

    /// @notice Reconfigure the curve used by pools without an override.
    function setDefaultParams(Params calldata newParams) external onlyOwner {
        _defaultCurve = _validatedParams(newParams);

        emit DefaultParamsUpdated(newParams);
    }

    /**
     * @notice Give `key` a curve of its own.
     *
     * @dev A volatile pair and a stablecoin pair want very different drift sensitivity and window
     * lengths, so one curve across every pool would mean mispricing all but one of them. Overrides
     * are validated against the same hard caps as the default, so per-pool tuning cannot be used to
     * exceed {MAX_CONFIGURABLE_FEE} or to drop below {MIN_REFERENCE_WINDOW}.
     */
    function setPoolParams(PoolKey calldata key, Params calldata newParams) external onlyOwner {
        PoolId id = key.toId();

        _poolCurves[id] = _validatedParams(newParams);

        emit PoolParamsUpdated(id, newParams);
    }

    /// @notice Return `key` to the default curve.
    function clearPoolParams(PoolKey calldata key) external onlyOwner {
        PoolId id = key.toId();

        delete _poolCurves[id];

        emit PoolParamsCleared(id);
    }

    /// @dev Seed the pool's equilibrium at the price it was initialized at, in addition to the
    /// inherited dynamic-fee check.
    function _afterInitialize(address sender, PoolKey calldata key, uint160 sqrtPriceX96, int24 tick)
        internal
        virtual
        override
        returns (bytes4)
    {
        bytes4 selector = super._afterInitialize(sender, key, sqrtPriceX96, tick);

        _seedReference(key.toId(), tick);

        return selector;
    }

    /**
     * @dev Fold the equilibrium reference forward, then price the swap by its drift direction.
     *
     * The tick read here is the pool's pre-swap tick. Because the reference is only folded when
     * `block.timestamp` has advanced, the sample it consumes is the tick as of the first swap in the
     * block, which no earlier swap in the same block could have moved.
     */
    function _getFee(address, PoolKey calldata key, SwapParams calldata, bytes calldata)
        internal
        virtual
        override
        returns (uint24 fee)
    {
        PoolId id = key.toId();
        // Only the tick is needed; the other `slot0` fields are deliberately discarded.
        // slither-disable-next-line unused-return
        (, int24 currentTick,,) = poolManager.getSlot0(id);

        Params memory p = _effectiveParams(id);
        int256 referenceScaled = _updateReference(id, currentTick, p.referenceWindow);

        // Carry the pre-swap distance from equilibrium into {_afterSwap}, which is the only place
        // the drift this swap *creates* can be measured. Transient storage is correct here rather
        // than merely cheap: the value is meaningless outside this one swap.
        _setPendingDrift(_absDrift(referenceScaled, currentTick));

        // Charge only the floor through the pool's own fee path. The drift-dependent remainder is
        // taken in {_afterSwap} once the swap's effect on the price is known.
        return p.minFee;
    }

    /**
     * @dev Charge the drift-dependent part of the fee, now that the swap's effect is observable.
     *
     * Pricing on the drift a swap *creates* rather than the drift it *starts from* is the whole
     * point of doing this here. Keying off the starting drift let a swap that began at equilibrium
     * move the price arbitrarily far for the base rate, so the trade that caused the damage paid
     * nothing for it while the trade that repaired it was discounted — which made pre-moving the
     * price a profitable way to buy the discount.
     *
     * The remainder is taken in the unspecified currency and immediately donated to the pool's
     * in-range liquidity providers, so this contract never accumulates a balance and the owner
     * never becomes the beneficiary of the fee it sets.
     */
    function _afterSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata swapParams,
        BalanceDelta delta,
        bytes calldata
    ) internal virtual override returns (bytes4, int128) {
        uint24 outstanding = _priceDriftCreated(key);
        if (outstanding == 0) return (this.afterSwap.selector, 0);

        return (this.afterSwap.selector, _collectAndDonate(key, swapParams, delta, outstanding));
    }

    /**
     * @dev Measure the drift this swap created and return the fee still outstanding, in hundredths
     * of a bip, over and above the floor the pool already charged.
     */
    function _priceDriftCreated(PoolKey calldata key) private returns (uint24 outstanding) {
        PoolId id = key.toId();

        uint256 absBefore = _pendingDrift();
        _setPendingDrift(0);

        Params memory p = _effectiveParams(id);

        // slither-disable-next-line unused-return
        (, int24 tickAfter,,) = poolManager.getSlot0(id);
        int256 driftDeltaScaled =
            int256(_absDrift(int256(_driftStates[id].referenceTickScaled), tickAfter)) - int256(absBefore);

        uint24 totalFee = _feeForDriftDelta(p, driftDeltaScaled);

        emit DriftFeeApplied(id, (driftDeltaScaled / TICK_SCALE).toInt24(), totalFee, driftDeltaScaled > 0);

        // `minFee` was already charged by the pool's own fee path.
        outstanding = totalFee - p.minFee;

        // Donating requires someone in range to receive it. With no in-range liquidity the swap
        // could not have moved the price anyway, so waiving the remainder is the honest outcome.
        if (poolManager.getLiquidity(id) == 0) outstanding = 0;
    }

    /**
     * @dev Take `outstanding` from the swap's unspecified currency and hand it straight to the
     * in-range liquidity providers.
     *
     * The positive hook delta and the donation cancel out, so this contract never ends the call
     * holding a balance and the owner never becomes the beneficiary of the fee it sets.
     */
    function _collectAndDonate(
        PoolKey calldata key,
        SwapParams calldata swapParams,
        BalanceDelta delta,
        uint24 outstanding
    ) private returns (int128) {
        (Currency unspecified, int128 unspecifiedAmount) = (swapParams.amountSpecified < 0) == swapParams.zeroForOne
            ? (key.currency1, delta.amount1())
            : (key.currency0, delta.amount0());

        if (unspecifiedAmount < 0) unspecifiedAmount = -unspecifiedAmount;

        uint256 feeAmount = (uint256(uint128(unspecifiedAmount)) * outstanding) / MAX_PIPS;
        if (feeAmount == 0) return 0;

        unspecified.take(poolManager, address(this), feeAmount, true);

        // The returned delta is deliberately ignored: it is the debit this donation creates, which
        // the `settle` below clears using the claims just taken. Any mismatch between the two would
        // leave a non-zero delta and the manager would revert at the end of the unlock, so a silent
        // discrepancy is not reachable.
        if (unspecified == key.currency0) {
            // slither-disable-next-line unused-return
            poolManager.donate(key, feeAmount, 0, "");
        } else {
            // slither-disable-next-line unused-return
            poolManager.donate(key, 0, feeAmount, "");
        }

        unspecified.settle(poolManager, address(this), feeAmount, true);

        return feeAmount.toInt256().toInt128();
    }

    /// @dev Signal `afterSwap` and its delta on top of what {BaseOverrideFee} already requires.
    function getHookPermissions() public pure virtual override returns (Hooks.Permissions memory permissions) {
        permissions = super.getHookPermissions();

        permissions.afterSwap = true;
        permissions.afterSwapReturnDelta = true;
    }

    /// @dev Absolute distance from equilibrium, scaled by {TICK_SCALE}.
    function _absDrift(int256 referenceScaled, int24 tick) private pure returns (uint256) {
        int256 driftScaled = int256(tick) * TICK_SCALE - referenceScaled;

        return uint256(driftScaled < 0 ? -driftScaled : driftScaled);
    }

    function _pendingDrift() private view returns (uint256) {
        return PENDING_DRIFT_SLOT.asUint256().tload();
    }

    function _setPendingDrift(uint256 value) private {
        PENDING_DRIFT_SLOT.asUint256().tstore(value);
    }

    /// @dev The curve applied to `id`: its override if it has one, otherwise the default.
    function _effectiveParams(PoolId id) internal view returns (Params memory) {
        Params memory p = _poolCurves[id];

        return p.referenceWindow == 0 ? _defaultCurve : p;
    }

    /**
     * @dev Fold the current tick into the pool's reference, at most once per timestamp.
     *
     * @return referenceScaled The reference after folding, scaled by {TICK_SCALE}.
     */
    function _updateReference(PoolId id, int24 currentTick, uint32 window) private returns (int256 referenceScaled) {
        DriftState storage state = _driftStates[id];

        // Unreachable in v4: the hook address is part of `PoolKey`, so any pool using this hook must
        // have passed through `afterInitialize`, which seeds. Kept because the failure mode if that
        // ever stopped holding is severe and silent — an unseeded `DriftState` reads as tick 0, a
        // 1:1 price, which would price every swap against a fabricated equilibrium. This is the one
        // branch the test suite deliberately leaves uncovered.
        if (!state.initialized) return _seedReference(id, currentTick);

        referenceScaled = _foldedReference(state, currentTick, window);

        // `lastUpdate` differing from now is exactly the condition under which the fold above
        // consumed a fresh sample, so it gates the write and the event together.
        //
        // Validator influence over `block.timestamp` is not a concern here: a few seconds of skew
        // against a window of at least {MIN_REFERENCE_WINDOW} shifts the sample weight by well
        // under a percent, and skew cannot add samples, since one is taken per timestamp at most.
        // forge-lint: disable-next-line(block-timestamp)
        if (state.lastUpdate != block.timestamp) {
            state.referenceTickScaled = referenceScaled.toInt96();
            state.lastUpdate = block.timestamp.toUint40();

            emit ReferenceTickUpdated(id, (referenceScaled / TICK_SCALE).toInt24(), currentTick);
        }
    }

    /// @dev Seed a pool's equilibrium at `tick`.
    function _seedReference(PoolId id, int24 tick) private returns (int256 referenceScaled) {
        referenceScaled = int256(tick) * TICK_SCALE;

        DriftState storage state = _driftStates[id];
        state.referenceTickScaled = referenceScaled.toInt96();
        state.lastUpdate = block.timestamp.toUint40();
        state.initialized = true;

        emit ReferenceTickSeeded(id, tick);
    }

    /// @dev Read a pool's reference and fold it forward to the current timestamp.
    function _foldedReference(DriftState storage state, int24 currentTick, uint32 window)
        private
        view
        returns (int256 referenceScaled)
    {
        // Guard the subtraction rather than assuming monotonicity: a chain that ever reports a
        // `block.timestamp` behind a recorded one would otherwise underflow and revert every swap
        // on the pool until the clock caught up.
        // forge-lint: disable-next-line(block-timestamp)
        uint256 elapsed = block.timestamp > state.lastUpdate ? block.timestamp - state.lastUpdate : 0;

        return _fold(int256(state.referenceTickScaled), currentTick, elapsed, window);
    }

    /**
     * @dev The reference fold, as arithmetic over plain values so it can be exercised directly.
     *
     * @param referenceScaled Current reference, scaled by {TICK_SCALE}.
     * @param currentTick Sample to fold in.
     * @param elapsed Seconds since the reference was last folded.
     * @param window Time constant, in seconds.
     */
    function _fold(int256 referenceScaled, int24 currentTick, uint256 elapsed, uint32 window)
        internal
        pure
        returns (int256)
    {
        if (elapsed == 0) return referenceScaled;

        // Weight the sample by elapsed time, capped at one full window. Multiplying before dividing
        // keeps sub-tick moves alive; the remaining truncation is toward zero, which can only slow
        // the reference down.
        uint256 weight = elapsed > window ? window : elapsed;

        // No single sample may close more than {MAX_FOLD_BPS} of the gap. The uncapped weight hits
        // exactly 1.0 at `elapsed >= window`, which makes one swap after a quiet spell enough to
        // replace the reference outright rather than nudge it.
        uint256 maxWeight = (uint256(window) * MAX_FOLD_BPS) / BPS_DENOMINATOR;
        if (weight > maxWeight) weight = maxWeight;

        int256 sampleScaled = int256(currentTick) * TICK_SCALE;
        // Casting `weight` and `window` to `int256` is safe because both are bounded above by
        // {MAX_REFERENCE_WINDOW}, and `window` is bounded below by {MIN_REFERENCE_WINDOW} so the
        // divisor is never zero.
        // forge-lint: disable-next-line(unsafe-typecast)
        return referenceScaled + ((sampleScaled - referenceScaled) * int256(weight)) / int256(uint256(window));
    }

    /**
     * @dev Price a swap from the change in absolute drift it caused.
     *
     * @param driftDeltaScaled `|drift after| - |drift before|`, scaled by {TICK_SCALE}. Positive
     * means the swap pushed the pool further from equilibrium; negative means it brought it back.
     *
     * @return fee The fee to charge, clamped to `[minFee, maxFee]`.
     */
    function _feeForDriftDelta(Params memory p, int256 driftDeltaScaled) internal pure returns (uint24 fee) {
        // A swap that left the distance from equilibrium unchanged is neutral: nothing to reward or
        // penalise. This also covers a swap too small to move the tick at all.
        if (driftDeltaScaled == 0) return p.baseFee;

        bool widened = driftDeltaScaled > 0;
        uint256 magnitudeScaled = uint256(widened ? driftDeltaScaled : -driftDeltaScaled);

        // As in the reference fold, the adjustment stays scaled until the final division so that a
        // sub-unit adjustment is not rounded away before `discountBps` applies to it.
        uint256 adjustmentScaled = magnitudeScaled * p.feePerTick;
        uint256 maxAdjustmentScaled = uint256(p.maxAdjustment) * uint256(TICK_SCALE);
        if (adjustmentScaled > maxAdjustmentScaled) adjustmentScaled = maxAdjustmentScaled;

        if (widened) {
            uint256 surcharged = uint256(p.baseFee) + adjustmentScaled / uint256(TICK_SCALE);
            // Casting to `uint24` is safe because the branch is only taken when `surcharged` is at
            // most `maxFee`, itself a `uint24`.
            // forge-lint: disable-next-line(unsafe-typecast)
            fee = surcharged > p.maxFee ? p.maxFee : uint24(surcharged);
        } else {
            uint256 discount = (adjustmentScaled * p.discountBps) / (uint256(TICK_SCALE) * BPS_DENOMINATOR);
            uint256 headroom = uint256(p.baseFee) - p.minFee;
            // Casting to `uint24` is safe because the branch is only taken when `discount` is below
            // `headroom`, leaving a result strictly between `minFee` and `baseFee`.
            // forge-lint: disable-next-line(unsafe-typecast)
            fee = discount >= headroom ? p.minFee : uint24(uint256(p.baseFee) - discount);
        }
    }

    /**
     * @dev Validate a fee curve, returning it so callers can assign it to the default or to a pool.
     *
     * Every caller routes through here, so the hard caps hold for per-pool overrides exactly as they
     * do for the default, and a stored `referenceWindow` is always nonzero — which is what lets zero
     * serve as the "no override" sentinel in {_poolCurves}.
     */
    function _validatedParams(Params memory newParams) private pure returns (Params memory) {
        if (
            newParams.minFee > newParams.baseFee || newParams.baseFee > newParams.maxFee
                || newParams.baseFee > MAX_BASE_FEE || newParams.maxFee > MAX_CONFIGURABLE_FEE
                || newParams.feePerTick > MAX_FEE_PER_TICK || newParams.maxAdjustment > MAX_CONFIGURABLE_FEE
                || newParams.discountBps > BPS_DENOMINATOR || newParams.referenceWindow < MIN_REFERENCE_WINDOW
                || newParams.referenceWindow > MAX_REFERENCE_WINDOW
        ) {
            revert InvalidParams();
        }

        return newParams;
    }
}
