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
 * ## How the fee is charged
 *
 * The fee is a function of the **path** a swap traces relative to equilibrium: the average distance
 * from equilibrium over the swap, priced as a surcharge where that distance grows and a discount
 * where it shrinks. A swap that crosses equilibrium is split at the crossing and each half priced in
 * its own direction.
 *
 * That path is not knowable in `beforeSwap`, so charging happens in two steps. `beforeSwap`
 * overrides the pool's fee with {Params-minFee}, the floor everyone pays, which flows to liquidity
 * providers through the pool's own accounting. `afterSwap` then measures where the swap actually
 * landed, prices the path, and takes the remainder from the swap's unspecified currency, donating it
 * immediately to the in-range liquidity providers. This contract never ends a call holding a
 * balance, so the owner never becomes the beneficiary of the fee it sets.
 *
 * ## Two rules this replaced, and why both failed
 *
 * Both earlier attempts priced on the **endpoints** of the drift path rather than integrating over
 * it, and both were broken by adversarial review:
 *
 * 1. Pricing on the drift a swap *started from* meant a swap beginning at equilibrium paid the base
 *    rate however far it moved the price. Since the legs of a trade need not be the same size, a
 *    trader could pay base on a small pre-move and run a much larger main leg back at the floor.
 * 2. Pricing on `|drift after| - |drift before|` is linear in the marginal drift while the fee is a
 *    rate on notional, so slicing a trade N ways collapsed the drift term as `k·D·V/N`. A 40-way
 *    split came within 3.4bps of a pool with no hook at all.
 *
 * Averaging over the path fixes both, and the fix is arithmetic rather than a tuning choice: slicing
 * telescopes to the same total, and the far endpoint is always counted. See
 * `test_splittingDoesNotDefeatTheSurcharge` and `test_premovingNoLongerBuysTheDiscount`.
 *
 * NOTE: a residual remains. The trapezoid assumes drift moves linearly in volume within a slice, and
 * on a constant-product curve it does not, so very fine slicing tracks the true integral slightly
 * better -- measured at ~10bps on a 40-way split, against 67bps under the rule this replaced.
 *
 * NOTE: the floor is charged on the swap and the remainder on its output, so the two compound rather
 * than summing exactly. The difference is second-order at these rates.
 *
 * WARNING: the drift surcharge is donated to whoever is in range when the swap ends, not to the
 * liquidity that filled it, so just-in-time liquidity can capture a disproportionate share of it.
 * Addressing that needs liquidity-side hooks, which this contract does not implement.
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
    /// @dev Derived per pool rather than kept in one global slot. Today `PoolManager.swap` runs
    /// `beforeSwap -> _swap -> afterSwap` with no external call in between, so a single slot could
    /// not be mispaired — but that is an invariant of v4-core's internals, not of anything this hook
    /// enforces, and keying by pool costs nothing.
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

    /// @dev Surcharge taken but not yet handed to liquidity providers, per pool and currency.
    ///
    /// A swap can end on a tick where no position is in range, and `donate` has nobody to pay. The
    /// fee is held as ERC-6909 claims until a later swap finds liquidity in range, rather than
    /// waived: the trader chooses the terminal tick via `sqrtPriceLimitX96`, so a waiver is a
    /// discount they can award themselves, and sweeping an entire liquidity band is exactly the
    /// trade that should be paying the most.
    mapping(PoolId id => mapping(Currency currency => uint256 amount)) private _pendingDonations;

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
     * @notice The fee a swap would pay for moving the pool from `driftBefore` to `driftAfter`, both
     * signed distances from equilibrium in ticks.
     *
     * @dev The fee depends on the whole path a swap traces, so a quote needs both endpoints: its
     * size and the pool's liquidity decide where it lands. Callers should estimate the post-swap
     * tick themselves and pass the resulting drift.
     */
    function quoteFeeForPath(PoolKey calldata key, int24 driftBefore, int24 driftAfter) external view returns (uint24) {
        return
            _feeForPath(_effectiveParams(key.toId()), int256(driftBefore) * TICK_SCALE, int256(driftAfter) * TICK_SCALE);
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

        // Carry the pre-swap drift into {_afterSwap}, which is the only place the path this swap
        // traces can be measured. Signed, because a swap that crosses equilibrium repairs drift on
        // one side and creates it on the other, and those two halves are priced differently.
        // Transient storage is correct here rather than merely cheap: the value is meaningless
        // outside this one swap.
        _setPendingDrift(id, _signedDrift(referenceScaled, currentTick));

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

        // Casting the literal zero to `int128` is safe; the other branch returns `int128` already.
        // forge-lint: disable-next-line(unsafe-typecast)
        int128 hookDelta = outstanding == 0 ? int128(0) : _collect(key, swapParams, delta, outstanding);

        // Flushed unconditionally, not only when this swap owes something. A swap that merely
        // repairs drift owes nothing itself, but it is exactly the kind of swap that brings the
        // price back into range and so makes an earlier deferred surcharge payable.
        _flushDonations(key, key.toId());

        return (this.afterSwap.selector, hookDelta);
    }

    /**
     * @dev Measure the drift this swap created and return the fee still outstanding, in hundredths
     * of a bip, over and above the floor the pool already charged.
     */
    function _priceDriftCreated(PoolKey calldata key) private returns (uint24 outstanding) {
        PoolId id = key.toId();

        int256 driftBefore = _pendingDrift(id);
        _setPendingDrift(id, 0);

        Params memory p = _effectiveParams(id);

        // slither-disable-next-line unused-return
        (, int24 tickAfter,,) = poolManager.getSlot0(id);
        int256 driftAfter = _signedDrift(int256(_driftStates[id].referenceTickScaled), tickAfter);

        uint24 totalFee = _feeForPath(p, driftBefore, driftAfter);

        // `minFee` was already charged by the pool's own fee path.
        outstanding = totalFee - p.minFee;

        emit DriftFeeApplied(id, (driftAfter / TICK_SCALE).toInt24(), totalFee, _abs(driftAfter) > _abs(driftBefore));
    }

    /**
     * @dev Take `outstanding` from the swap's unspecified currency and hand it straight to the
     * in-range liquidity providers.
     *
     * The positive hook delta and the donation cancel out, so this contract never ends the call
     * holding a balance and the owner never becomes the beneficiary of the fee it sets.
     */
    function _collect(PoolKey calldata key, SwapParams calldata swapParams, BalanceDelta delta, uint24 outstanding)
        private
        returns (int128)
    {
        (Currency unspecified, int128 unspecifiedAmount) = (swapParams.amountSpecified < 0) == swapParams.zeroForOne
            ? (key.currency1, delta.amount1())
            : (key.currency0, delta.amount0());

        if (unspecifiedAmount < 0) unspecifiedAmount = -unspecifiedAmount;

        // Casting to `uint128` is safe because the sign was stripped immediately above, and
        // `TICK_SCALE` is a positive constant.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 feeAmount = (uint256(uint128(unspecifiedAmount)) * outstanding) / MAX_PIPS;

        if (feeAmount > 0) {
            // Credited before the claims are minted, so state is settled ahead of the external
            // call. `take` with `claims` set mints ERC-6909 and calls back into nothing, but
            // ordering it this way keeps the contract checks-effects-interactions throughout.
            _pendingDonations[key.toId()][unspecified] += feeAmount;
            unspecified.take(poolManager, address(this), feeAmount, true);
        }

        return feeAmount.toInt256().toInt128();
    }

    /**
     * @dev Hand everything held for `id` to the liquidity providers currently in range.
     *
     * A no-op when nothing is owed or when nobody is in range to receive it — `donate` reverts
     * without in-range liquidity, and a swap must not fail because of that. Whatever is owed simply
     * waits for the next swap that finds liquidity, so a trader who steers the price out of every
     * position defers the surcharge rather than escaping it.
     */
    function _flushDonations(PoolKey calldata key, PoolId id) private {
        if (poolManager.getLiquidity(id) == 0) return;

        uint256 amount0 = _pendingDonations[id][key.currency0];
        uint256 amount1 = _pendingDonations[id][key.currency1];

        if (amount0 == 0 && amount1 == 0) return;

        if (amount0 > 0) delete _pendingDonations[id][key.currency0];
        if (amount1 > 0) delete _pendingDonations[id][key.currency1];

        // The returned delta is deliberately ignored: it is the debit this donation creates, which
        // the settlements below clear using the claims already taken. Any mismatch would leave a
        // non-zero delta and the manager would revert at the end of the unlock.
        // slither-disable-next-line unused-return
        poolManager.donate(key, amount0, amount1, "");

        if (amount0 > 0) key.currency0.settle(poolManager, address(this), amount0, true);
        if (amount1 > 0) key.currency1.settle(poolManager, address(this), amount1, true);
    }

    /// @notice Surcharge taken for `key` that is still waiting for in-range liquidity to receive it.
    function pendingDonations(PoolKey calldata key) external view returns (uint256 amount0, uint256 amount1) {
        PoolId id = key.toId();

        return (_pendingDonations[id][key.currency0], _pendingDonations[id][key.currency1]);
    }

    /// @dev Signal `afterSwap` and its delta on top of what {BaseOverrideFee} already requires.
    function getHookPermissions() public pure virtual override returns (Hooks.Permissions memory permissions) {
        permissions = super.getHookPermissions();

        permissions.afterSwap = true;
        permissions.afterSwapReturnDelta = true;
    }

    /// @dev Signed distance from equilibrium, scaled by {TICK_SCALE}.
    function _signedDrift(int256 referenceScaled, int24 tick) private pure returns (int256) {
        return int256(tick) * TICK_SCALE - referenceScaled;
    }

    function _abs(int256 value) private pure returns (uint256) {
        return uint256(value < 0 ? -value : value);
    }

    function _pendingDrift(PoolId id) private view returns (int256) {
        return PENDING_DRIFT_SLOT.deriveMapping(PoolId.unwrap(id)).asInt256().tload();
    }

    function _setPendingDrift(PoolId id, int256 value) private {
        PENDING_DRIFT_SLOT.deriveMapping(PoolId.unwrap(id)).asInt256().tstore(value);
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
     * @dev Price a swap from the drift path it traced, as the average distance from equilibrium over
     * the swap rather than any function of its endpoints alone.
     *
     * ## Why an average and not a difference
     *
     * Charging on `|drift after| - |drift before|` is defeated by splitting. That quantity is linear
     * in the marginal drift while the fee is levied as a rate on notional, so cutting a trade into
     * N slices leaves each slice creating `D/N` of drift on `V/N` of notional and the drift term
     * collapses as `k·D·V/N`. Measured before this change: a 40-way split landed within 3.4bps of a
     * pool with no hook at all.
     *
     * The average is a trapezoid rule over the same path, so slicing telescopes to the same total.
     * For a move from `0` to `D` in N equal steps the drift term sums to `k·V·D/2` for every N,
     * because `sum(2i-1) == N^2`. Split-invariance here is arithmetic, not a tuning choice.
     *
     * ## Crossing equilibrium
     *
     * A swap from `+d0` to `-d1` repairs `d0` of drift and then creates `d1` on the far side. Taking
     * only the endpoints would call that a net repair and discount it, which is how a single swap
     * could move the price hundreds of ticks and still be charged below the neutral rate. So the
     * path is split at the crossing and each half priced in its own direction, weighted by the share
     * of the tick distance it accounts for.
     *
     * @param driftBefore Signed distance from equilibrium before the swap, scaled by {TICK_SCALE}.
     * @param driftAfter Signed distance after, same scale.
     */
    function _feeForPath(Params memory p, int256 driftBefore, int256 driftAfter) internal pure returns (uint24 fee) {
        uint256 absBefore = _abs(driftBefore);
        uint256 absAfter = _abs(driftAfter);

        // Crossing equilibrium, i.e. the path passes through zero with real distance on both sides.
        if ((driftBefore > 0) != (driftAfter > 0) && absBefore != 0 && absAfter != 0) {
            // Priced as though the swap had started at equilibrium and created `absAfter`: the full
            // surcharge for the far side, and no discount for the near one.
            //
            // Crediting the repaired half, or diluting the surcharge by the repaired distance,
            // hands an attacker the same lever either way: manufacture repair distance with a small
            // trade, then spend it against a much larger one. The legs of a trade need not be the
            // same size, so any credit that is bought with distance but paid out on notional is
            // exploitable. Declining to discount a swap that ends further from equilibrium than it
            // started costs an honest trader nothing they cannot get by stopping at equilibrium and
            // trading again.
            return _applyAdjustments(p, _averageAdjustment(p, 0, absAfter), 0);
        }

        // No crossing: the distance from equilibrium moves monotonically, so the whole swap is
        // either creating drift or repairing it, integrated between the two endpoints.
        (uint256 low, uint256 high) = absAfter >= absBefore ? (absBefore, absAfter) : (absAfter, absBefore);
        uint256 averageScaled = _averageAdjustment(p, low, high);

        return absAfter >= absBefore ? _applyAdjustments(p, averageScaled, 0) : _applyAdjustments(p, 0, averageScaled);
    }

    /**
     * @dev Combine a surcharge for `createdScaled` of drift with a discount for `repairedScaled`,
     * and clamp the result to the configured band.
     *
     * Both inputs are drift magnitudes scaled by {TICK_SCALE}, already averaged over the portion of
     * the swap they apply to.
     */
    function _applyAdjustments(Params memory p, uint256 createdScaled, uint256 repairedScaled)
        private
        pure
        returns (uint24)
    {
        // Both adjustments stay scaled until the final division, so a sub-unit adjustment is not
        // rounded away before `discountBps` applies to it.
        // Casting {TICK_SCALE} is safe because it is a positive constant.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 surcharge = createdScaled / uint256(TICK_SCALE);
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 discount = (repairedScaled * p.discountBps) / (uint256(TICK_SCALE) * BPS_DENOMINATOR);

        uint256 raised = uint256(p.baseFee) + surcharge;

        // The discount is subtracted after the surcharge, so a crossing swap is charged the net of
        // the two. `discountBps <= BPS_DENOMINATOR` keeps the credit for repairing a given distance
        // no larger than the charge for creating it, which is what stops a two-leg round trip from
        // being cheaper than not trading.
        uint256 result = raised > discount ? raised - discount : 0;

        if (result > p.maxFee) return p.maxFee;
        if (result < p.minFee) return p.minFee;

        // Casting to `uint24` is safe because `result` is bounded by `maxFee` immediately above.
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint24(result);
    }

    /**
     * @dev Average adjustment over a drift interval, scaled by {TICK_SCALE}.
     *
     * The cap belongs *inside* the integral. Clamping a whole swap's adjustment instead makes the
     * fee concave in the drift travelled, and Jensen's inequality then pays traders to slice: N
     * slices are charged the mean of a concave function where one swap is charged the function of
     * the mean, a gap of `maxAdjustment / 4` at its worst and reachable with as few as four slices.
     * Integrating `min(maxAdjustment, feePerTick * x)` over the interval is split-invariant by
     * construction, because an integral over a path is additive over its pieces.
     *
     * @param lowScaled Lower end of the drift interval, scaled by {TICK_SCALE}.
     * @param highScaled Upper end, same scale. Must be at least `lowScaled`.
     */
    function _averageAdjustment(Params memory p, uint256 lowScaled, uint256 highScaled) private pure returns (uint256) {
        if (p.feePerTick == 0) return 0;

        // Casting {TICK_SCALE} is safe because it is a positive constant.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 capScaled = uint256(p.maxAdjustment) * uint256(TICK_SCALE);

        // Drift at which the cap starts to bind, in the same scale as the interval.
        uint256 kneeScaled = capScaled / p.feePerTick;

        // Entirely past the knee: the cap binds across the whole interval.
        if (lowScaled >= kneeScaled) return capScaled;

        // Entirely below it: the average of a linear function is its midpoint.
        if (highScaled <= kneeScaled) return ((lowScaled + highScaled) * p.feePerTick) / 2;

        // Straddling it: a trapezoid up to the knee, a rectangle beyond.
        uint256 rising = ((kneeScaled + lowScaled) * p.feePerTick * (kneeScaled - lowScaled)) / 2;
        uint256 flat = capScaled * (highScaled - kneeScaled);

        return (rising + flat) / (highScaled - lowScaled);
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
