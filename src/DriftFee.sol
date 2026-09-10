// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// External imports
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
// Internal imports
import {BaseOverrideFee} from "uniswap-hooks/fee/BaseOverrideFee.sol";
import {BaseHook} from "uniswap-hooks/base/BaseHook.sol";

/**
 * @title DriftFee
 * @notice A Uniswap v4 dynamic-fee hook that prices swaps by their *direction* relative to the
 * pool's equilibrium: trades that push the pool price further away from equilibrium pay a
 * surcharge, trades that return it toward equilibrium pay a discount.
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
 * - The per-update weight is `min(elapsed, window) / window`, giving the reference a time constant
 *   of {Params-referenceWindow} seconds (at least {MIN_REFERENCE_WINDOW} = 30 minutes) that is
 *   independent of block time. Moving it meaningfully requires holding a manipulated price across
 *   many blocks against arbitrage, not one transaction.
 *
 * ## Why the discount is not extractable
 *
 * The discount is bounded so the applied fee can never fall below {Params-minFee} (>= 0): the hook
 * never pays a rebate. An attacker who pushes the price away from equilibrium to mint a discount for
 * the reverting leg pays at least {Params-baseFee} on the pushing leg over comparable volume, while
 * the discount on the reverting leg is capped at `baseFee - minFee`. The round trip is therefore
 * never net-negative, before price impact and gas. See `test/DriftFee.t.sol` for the fuzzed
 * statements of these invariants.
 *
 * ## Trust surface
 *
 * Parameters are owner-controlled, but every fee the owner can configure is hard-capped at
 * {MAX_CONFIGURABLE_FEE}, so the owner cannot raise fees to an extractive level on pools that have
 * already opted in.
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

    /// @dev Fixed-point scale for the stored reference tick, so sub-tick drift is not truncated.
    int256 private constant TICK_SCALE = 1e6;

    /// @dev Denominator for basis-point parameters.
    uint256 private constant BPS_DENOMINATOR = 10_000;

    /// @dev Hard ceiling on any configurable fee, in hundredths of a bip (1e5 = 10%).
    uint24 public constant MAX_CONFIGURABLE_FEE = 1e5;

    /// @dev Shortest permitted reference time constant, matching the 30-minute floor for
    /// manipulation-resistant onchain price references.
    uint32 public constant MIN_REFERENCE_WINDOW = 1800;

    /// @dev Longest permitted reference time constant, so a pool cannot be handed a reference that
    /// never tracks the market.
    uint32 public constant MAX_REFERENCE_WINDOW = 7 days;

    /// @dev Ceiling on {Params-feePerTick}, bounding surcharge sensitivity.
    uint24 public constant MAX_FEE_PER_TICK = 1e3;

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
        uint32 lastUpdate;
        bool initialized;
    }

    Params private _params;

    mapping(PoolId id => DriftState state) private _driftStates;

    /// @dev The equilibrium reference for `id` moved to `referenceTick` after folding in `sampleTick`.
    event ReferenceTickUpdated(PoolId indexed id, int24 referenceTick, int24 sampleTick);

    /// @dev The equilibrium reference for `id` was seeded at `referenceTick`.
    event ReferenceTickSeeded(PoolId indexed id, int24 referenceTick);

    /// @dev A swap on `id` at `drift` ticks from equilibrium was charged `fee`; `movingAway` marks
    /// whether the swap increases absolute drift.
    event DriftFeeApplied(PoolId indexed id, int24 drift, uint24 fee, bool movingAway);

    /// @dev The fee curve was reconfigured.
    event ParamsUpdated(Params params);

    /// @dev A parameter was outside its permitted range, or the curve was internally inconsistent.
    error InvalidParams();

    /// @dev The pool manager address was zero.
    error InvalidPoolManager();

    /**
     * @param _poolManager The v4 pool manager singleton.
     * @param initialOwner Account permitted to reconfigure the fee curve.
     * @param initialParams Initial fee curve, validated by {_setParams}.
     */
    constructor(IPoolManager _poolManager, address initialOwner, Params memory initialParams)
        BaseHook(_poolManager)
        Ownable(initialOwner)
    {
        if (address(_poolManager) == address(0)) revert InvalidPoolManager();
        _setParams(initialParams);
    }

    /// @notice The active fee curve.
    function params() external view returns (Params memory) {
        return _params;
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
        returns (int24 referenceTick, uint32 lastUpdate, bool initialized)
    {
        DriftState storage state = _driftStates[key.toId()];
        return ((int256(state.referenceTickScaled) / TICK_SCALE).toInt24(), state.lastUpdate, state.initialized);
    }

    /**
     * @notice The fee `key` would charge right now for a swap in the given direction.
     *
     * @dev View-only mirror of {_getFee}: it folds the reference forward in memory but writes
     * nothing, so quoting cannot advance a pool's equilibrium.
     */
    function quoteFee(PoolKey calldata key, bool zeroForOne) external view returns (uint24 fee) {
        PoolId id = key.toId();
        (, int24 currentTick,,) = poolManager.getSlot0(id);

        DriftState storage state = _driftStates[id];
        int256 referenceScaled = state.initialized
            ? _foldedReference(state, currentTick, _params.referenceWindow)
            : int256(currentTick) * TICK_SCALE;

        (fee,,) = _feeFor(referenceScaled, currentTick, zeroForOne);
    }

    /// @notice Reconfigure the fee curve.
    function setParams(Params calldata newParams) external onlyOwner {
        _setParams(newParams);
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
    function _getFee(address, PoolKey calldata key, SwapParams calldata swapParams, bytes calldata)
        internal
        virtual
        override
        returns (uint24 fee)
    {
        PoolId id = key.toId();
        (, int24 currentTick,,) = poolManager.getSlot0(id);

        int256 referenceScaled = _updateReference(id, currentTick);

        int24 drift;
        bool movingAway;
        (fee, drift, movingAway) = _feeFor(referenceScaled, currentTick, swapParams.zeroForOne);

        emit DriftFeeApplied(id, drift, fee, movingAway);
    }

    /**
     * @dev Fold the current tick into the pool's reference, at most once per timestamp.
     *
     * @return referenceScaled The reference after folding, scaled by {TICK_SCALE}.
     */
    function _updateReference(PoolId id, int24 currentTick) private returns (int256 referenceScaled) {
        DriftState storage state = _driftStates[id];

        // A pool can only reach `beforeSwap` through `afterInitialize`, but seed defensively so a
        // missing reference can never be read as tick 0, i.e. a 1:1 price.
        if (!state.initialized) return _seedReference(id, currentTick);

        uint32 window = _params.referenceWindow;
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
            state.lastUpdate = block.timestamp.toUint32();

            emit ReferenceTickUpdated(id, (referenceScaled / TICK_SCALE).toInt24(), currentTick);
        }
    }

    /// @dev Seed a pool's equilibrium at `tick`.
    function _seedReference(PoolId id, int24 tick) private returns (int256 referenceScaled) {
        referenceScaled = int256(tick) * TICK_SCALE;

        DriftState storage state = _driftStates[id];
        state.referenceTickScaled = referenceScaled.toInt96();
        state.lastUpdate = block.timestamp.toUint32();
        state.initialized = true;

        emit ReferenceTickSeeded(id, tick);
    }

    /// @dev Read a pool's reference and fold it forward to the current timestamp.
    function _foldedReference(DriftState storage state, int24 currentTick, uint32 window)
        private
        view
        returns (int256 referenceScaled)
    {
        return _fold(int256(state.referenceTickScaled), currentTick, block.timestamp - state.lastUpdate, window);
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
        int256 sampleScaled = int256(currentTick) * TICK_SCALE;
        // Casting `weight` and `window` to `int256` is safe because both are bounded above by
        // {MAX_REFERENCE_WINDOW}, and `window` is bounded below by {MIN_REFERENCE_WINDOW} so the
        // divisor is never zero.
        // forge-lint: disable-next-line(unsafe-typecast)
        return referenceScaled + ((sampleScaled - referenceScaled) * int256(weight)) / int256(uint256(window));
    }

    /**
     * @dev Price a swap from its drift and direction.
     *
     * @return fee The fee to charge, clamped to `[minFee, maxFee]`.
     * @return drift Signed distance from equilibrium in ticks, truncated toward zero.
     * @return movingAway Whether the swap increases absolute drift.
     */
    function _feeFor(int256 referenceScaled, int24 currentTick, bool zeroForOne)
        internal
        view
        returns (uint24 fee, int24 drift, bool movingAway)
    {
        Params memory p = _params;

        int256 driftScaled = int256(currentTick) * TICK_SCALE - referenceScaled;
        drift = (driftScaled / TICK_SCALE).toInt24();

        // With the pool exactly at equilibrium there is no direction to reward or penalize.
        if (driftScaled == 0) return (p.baseFee, 0, false);

        // `zeroForOne` sells token0 for token1, lowering the price of token0 and so lowering the
        // tick. The swap widens the gap when it moves the tick the way drift already points.
        movingAway = (driftScaled > 0) == !zeroForOne;

        uint256 absDriftScaled = uint256(driftScaled > 0 ? driftScaled : -driftScaled);
        // Casting {TICK_SCALE} is safe because it is a positive constant.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 adjustment = (absDriftScaled * p.feePerTick) / uint256(TICK_SCALE);
        if (adjustment > p.maxAdjustment) adjustment = p.maxAdjustment;

        if (movingAway) {
            uint256 surcharged = uint256(p.baseFee) + adjustment;
            // Casting to `uint24` is safe because the branch is only taken when `surcharged` is at
            // most `maxFee`, itself a `uint24`.
            // forge-lint: disable-next-line(unsafe-typecast)
            fee = surcharged > p.maxFee ? p.maxFee : uint24(surcharged);
        } else {
            uint256 discount = (adjustment * p.discountBps) / BPS_DENOMINATOR;
            uint256 headroom = uint256(p.baseFee) - p.minFee;
            // Casting to `uint24` is safe because the branch is only taken when `discount` is below
            // `headroom`, leaving a result strictly between `minFee` and `baseFee`.
            // forge-lint: disable-next-line(unsafe-typecast)
            fee = discount >= headroom ? p.minFee : uint24(uint256(p.baseFee) - discount);
        }
    }

    /// @dev Validate and store a fee curve.
    function _setParams(Params memory newParams) private {
        if (
            newParams.minFee > newParams.baseFee || newParams.baseFee > newParams.maxFee
                || newParams.maxFee > MAX_CONFIGURABLE_FEE || newParams.feePerTick > MAX_FEE_PER_TICK
                || newParams.maxAdjustment > MAX_CONFIGURABLE_FEE || newParams.discountBps > BPS_DENOMINATOR
                || newParams.referenceWindow < MIN_REFERENCE_WINDOW || newParams.referenceWindow > MAX_REFERENCE_WINDOW
        ) {
            revert InvalidParams();
        }

        _params = newParams;

        emit ParamsUpdated(newParams);
    }
}
