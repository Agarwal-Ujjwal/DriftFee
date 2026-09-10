# DriftFee

A Uniswap v4 hook that adjusts swap fees by *direction*: a trade that pushes the pool price further
away from equilibrium pays a surcharge, and a trade that brings it back pays a discount.

The point is to charge for the thing that actually costs liquidity providers money. LPs lose to
adverse selection — informed flow that walks the pool away from the true price — and are helped by
flow that restores it. A single static fee prices both identically. DriftFee splits them.

## How equilibrium is measured

The reference price is deliberately **not** the pool's spot price. A flash loan can move spot inside
one transaction, so a spot-derived reference would let an attacker push the price, collect the
discounted "reverting" fee, and unwind at a profit.

Instead the reference is a time-decayed moving average of **top-of-block** ticks:

- It is folded forward at most once per `block.timestamp`, using the tick read in `beforeSwap`. The
  first swap at a given timestamp therefore contributes the tick as it stood *before* any swap in
  that block. Later swaps in the same block cannot resample. This is the beginning-of-block
  checkpoint that OpenZeppelin's `AntiSandwichHook` relies on.
- Each fold closes `min(elapsed, window) / window` of the gap, giving the reference a time constant
  of `referenceWindow` seconds — at least 30 minutes, and independent of the chain's block time.

So moving equilibrium requires *holding* a manipulated price across many blocks against arbitrage,
not moving it for one transaction. `test_reference_samplesOnlyTheTopOfBlockTick` pins this down: a
spike opened and unwound inside a block contributes nothing at all.

## Why the discount can't be farmed

The fee is clamped to `[minFee, maxFee]` with `minFee >= 0`, so the hook never pays a rebate. An
attacker who pushes the price away from equilibrium to mint a discount for the reverting leg pays at
least `baseFee` on the pushing leg over comparable volume, while the discount on the reverting leg is
capped at `baseFee - minFee`. The round trip cannot come out ahead, before price impact and gas.

Both halves of that argument are fuzzed as invariants — see `testFuzz_roundTripNeverRebates` and
`testFuzz_feeAlwaysWithinConfiguredBand`.

## The fee curve

| Parameter         | Meaning                                                          | Default |
| ----------------- | ---------------------------------------------------------------- | ------- |
| `baseFee`         | Charged when the pool sits at equilibrium                        | 0.30%   |
| `minFee`          | Floor; the discount can never breach it                          | 0.05%   |
| `maxFee`          | Ceiling                                                          | 1.00%   |
| `feePerTick`      | Adjustment per tick of absolute drift                            | 0.003%  |
| `maxAdjustment`   | Cap on the raw adjustment before the discount factor             | 0.70%   |
| `discountBps`     | Share of the adjustment credited back to drift-reducing swaps    | 100%    |
| `referenceWindow` | Time constant of the equilibrium average                         | 30 min  |

Parameters are owner-controlled, but every configurable fee is hard-capped at
`MAX_CONFIGURABLE_FEE` (10%), so the owner cannot raise fees to an extractive level on pools that
have already opted in. `referenceWindow` is likewise floored at 30 minutes.

Pools must be initialized with `LPFeeLibrary.DYNAMIC_FEE_FLAG`; `afterInitialize` rejects anything
else and seeds equilibrium at the initialization tick.

## Layout

```
src/DriftFee.sol                  the hook
test/DriftFee.t.sol               unit + fuzz tests
test/DriftFee.invariants.t.sol    handler-driven invariants
test/utils/DriftFeeHarness.sol    exposes the fee curve and fold for direct fuzzing
test/utils/DriftFeeHandler.sol    random swap/time sequences for the invariant runner
FEEDBACK.md                       running log of v4 development friction
```

## Development

```sh
forge build
forge test
FOUNDRY_PROFILE=deep forge test    # 10k fuzz runs, 256 invariant runs
```

`foundry.toml` pins `solc 0.8.26` and `evm_version = "cancun"` to match the v4 stack. Both pins are
load-bearing — see `FEEDBACK.md`.

## Status

Unaudited and undeployed. There is no deployment script yet: deploying a v4 hook requires mining a
`CREATE2` salt so the address encodes the hook's permission flags, which is the next piece of work.

Not production software. No warranty.
