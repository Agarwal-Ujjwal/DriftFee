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
- Each fold closes `min(elapsed, window) / window` of the gap, capped at `MAX_FOLD_BPS` (20%) so no
  single sample can replace the reference. Without that cap, a pool merely *quiet* for one window
  could have its equilibrium set outright by a single swap.

So moving equilibrium requires *holding* a manipulated price across many separate timestamps against
arbitrage, not moving it for one transaction. `test_reference_samplesOnlyTheTopOfBlockTick` pins this
down: a spike opened and unwound inside a block contributes nothing at all.

## How the fee is charged, and why in two parts

The fee is a function of the drift a swap **creates** — `|drift after| - |drift before|`. Widening
that gap is surcharged; narrowing it is discounted.

That quantity isn't knowable in `beforeSwap`, so charging happens in two steps:

1. **`beforeSwap`** overrides the pool's fee with `minFee`, the floor everyone pays, which reaches
   LPs through the pool's own accounting.
2. **`afterSwap`** measures the drift actually created, prices it, takes the remainder from the
   swap's unspecified currency, and **donates it immediately to the in-range LPs**. The hook never
   ends a call holding a balance, so the owner never becomes the beneficiary of the fee it sets
   (`test_fork_hookRetainsNoBalance` checks this against the real mainnet manager).

### The bug this replaced

The first version priced each swap on the drift it *started from*. An adversarial review broke it,
and the reasoning is worth keeping:

A swap beginning at equilibrium took the zero-drift branch and paid `baseFee` **however far it moved
the price**. So the trade that caused the damage paid nothing for it, while the trade that repaired
it was discounted. Since the two legs of a trade need not be the same size, a trader could pay
`baseFee` on a small pre-move and then run a much larger main leg back at `minFee` — **+20 bps of
free improvement**, flash-loanable, in a single transaction. Round trips came out ~41% cheaper than
on a static pool of the same base fee, which subsidised precisely the manipulation and sandwich flow
the hook was meant to price up.

`test_premovingNoLongerBuysTheDiscount` replays that exact attack and asserts it now **loses** money
(~16 bps worse than trading honestly, a ~36 bps swing), and `testFuzz_premovingIsNeverProfitable`
sweeps pre-move sizes rather than trusting one. The invariant behind it —
`testFuzz_wideningNeverCheaperThanNarrowing` — is that creating drift is never cheaper than repairing
the same amount, for any curve.

The hook still never pays a rebate: the fee is clamped to `[minFee, maxFee]` with `minFee >= 0`.

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

Curves are set **per pool, over a global default**. A volatile ETH pair and a stablecoin pair want
very different drift sensitivity and window lengths, so a single curve across every pool would mean
mispricing all but one of them. `setPoolParams` overrides a pool; `clearPoolParams` returns it to the
default.

Both paths validate against the same hard caps. `baseFee` — and so `minFee`, since
`minFee <= baseFee` — is capped at `MAX_BASE_FEE` (1%), while `maxFee` is capped at
`MAX_CONFIGURABLE_FEE` (3%). The two ceilings differ deliberately: `maxFee` only ever lands on a
drift-widening swap, whereas `baseFee`/`minFee` are what an honest trader pays unconditionally.
`referenceWindow` is floored at 30 minutes.

Those caps bound the per-swap **rate** and nothing else. They do not bound cumulative extraction, do
not grandfather existing pools, and there is no timelock — a change applies from the next swap, and
since the hook address is part of `PoolKey` a pool can never migrate away. The owner is not the
beneficiary (fees accrue to LPs; there is no withdrawal path), so the worst case is griefing rather
than self-dealing — unless the owner is also a dominant LP. **Ownership belongs behind a multisig and
timelock, not the EOA that ran the deploy script**, which is what `OWNER` currently defaults to.

An earlier version capped only `maxFee`, which left `minFee == baseFee == maxFee == cap` valid: a
flat fee at the ceiling in both directions with the drift mechanism switched off. See
`test_setParams_cannotFlattenPoolToASingleExtractiveRate`.

Pools must be initialized with `LPFeeLibrary.DYNAMIC_FEE_FLAG`; `afterInitialize` rejects anything
else and seeds equilibrium at the initialization tick.

## Layout

```
src/DriftFee.sol                  the hook
script/Deploy.s.sol               CREATE2 salt mining + deployment
test/DriftFee.t.sol               unit + fuzz tests
test/Deploy.s.t.sol               covers the deploy script
test/DriftFee.invariants.t.sol    handler-driven invariants
test/DriftFee.fork.t.sol          against the deployed mainnet PoolManager and real USDC/WETH
test/utils/DriftFeeHarness.sol    exposes the fee curve and fold for direct fuzzing
test/utils/DriftFeeHandler.sol    random swap/time sequences for the invariant runner
FEEDBACK.md                       running log of v4 development friction
```

## Development

```sh
forge build
forge test
FOUNDRY_PROFILE=deep forge test              # 10k fuzz runs, 256 invariant runs
forge test --no-match-path 'test/*.fork.t.sol'   # skip the network
```

`foundry.toml` pins `solc 0.8.26` and `evm_version = "cancun"` to match the v4 stack. Both pins are
load-bearing — see `FEEDBACK.md`.

### Fork tests

The fork suite creates a fresh USDC/WETH pool on the **deployed** mainnet `PoolManager`
(`0x0000...8A90`, verified onchain) and trades against it. It covers two things the unit tests
structurally cannot:

- that the real manager honours the override fee. The unit suite compiles its own `PoolManager` from
  vendored v4-core, at a *different commit* than what is deployed — and a hook that fails to
  override looks perfectly healthy while charging nothing (`FEEDBACK.md` entry 4).
- that the drift math holds on a 6-decimal/18-decimal pair at a realistic price. Every unit test runs
  at tick 0 on two 18-decimal mocks, which is exactly where a decimals bug hides.

It runs against the latest block, so no archive node is needed, and **skips rather than fails** when
no RPC is reachable:

```sh
forge test --match-path 'test/*.fork.t.sol'           # uses a public endpoint
MAINNET_RPC_URL=<url> forge test --match-path 'test/*.fork.t.sol'
FORK_BLOCK=25956318 forge test --match-path 'test/*.fork.t.sol'   # pin for reproducibility
```

CI runs the fork suite as a separate, non-blocking job, so a third-party RPC outage cannot redden a
PR that broke nothing.

### Static analysis

```sh
python3 -m venv .venv-slither && .venv-slither/bin/pip install slither-analyzer
.venv-slither/bin/slither .
```

Slither reads `slither.config.json`; Mythril reads `myth-solc.json`, which carries this project's
remappings, optimizer settings and `evmVersion`, since Mythril does not read `foundry.toml`.

Both analyzers the pre-deploy checklist calls for are clean. Slither reports **0 findings**;
Mythril reports no issues:

```sh
ln -sf "$HOME/Library/Application Support/svm/0.8.26/solc-0.8.26" .venv-slither/bin/solc
PATH="$PWD/.venv-slither/bin:$PATH" myth analyze src/DriftFee.sol:DriftFee \
  --solc-json myth-solc.json --execution-timeout 240
```

Treat the Mythril result as weak evidence rather than a clean bill of health: every hook entry point
is `onlyPoolManager`, so symbolic execution from an arbitrary sender bounces off the access-control
guard before it reaches the fee math. The fuzz and invariant suites cover that math far better.
Mythril also needs its own virtualenv in practice — it and Slither pin mutually incompatible `eth-*`
versions (see `FEEDBACK.md`).

On the Slither side: `slither.config.json` filters `lib/` and `test/` and excludes two
detectors, which is worth being explicit about, since an excluded detector hides future findings too:

| Excluded              | Why                                                                                                                                                                                                |
| --------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `timestamp`           | Time decay *is* the mechanism here. The skew a validator can introduce is a few seconds against a window of at least 1800, and skew cannot add samples, since at most one is taken per timestamp.     |
| `incorrect-equality`  | The flagged comparisons are `driftScaled == 0` (exactly at equilibrium), `elapsed == 0` (nothing to fold), and a boolean equality. None involve a balance or a rounding boundary.                     |

`unused-return` is deliberately **left enabled** — unchecked return values are a real bug class — so
its two imprecise hits (destructuring `slot0` for the tick alone) are suppressed inline instead.

One earlier finding was real and is fixed: the discount path divided down to whole hundredths of a bip
before applying `discountBps`, discarding up to a full unit. The adjustment now stays scaled until the
final division. `test_feeFor_discountKeepsSubUnitPrecision` pins it.

## Deploying

A v4 hook cannot go to an arbitrary address: `BaseHook`'s constructor checks that the low 14 bits of
its own address match its declared permissions, so deployment is a *search for a salt* rather than a
plain `create`. `DriftFee` needs bits 12, 7, 6 and 2 — `afterInitialize`, `beforeSwap`, `afterSwap`
and `afterSwapReturnDelta`.

```sh
forge script script/Deploy.s.sol:Deploy --rpc-url <url>              # simulate
forge script script/Deploy.s.sol:Deploy --rpc-url <url> --broadcast --verify
```

The `PoolManager` defaults to the verified address for the chain being deployed to (Ethereum,
Optimism, Base, Arbitrum); `POOL_MANAGER` overrides it, and an unrecognised chain reverts rather than
falling back to a guess. `OWNER` defaults to the broadcasting account. Every curve parameter can be
set by environment variable and is validated by the constructor, so a bad value fails before
broadcast rather than leaving a live hook with a nonsense curve.

A mainnet dry run mines a salt in a couple of thousand iterations (most recently `0x920`, giving
`0x727fC80D…90c4`, whose low 14 bits are `0x10c4` as required) and costs roughly 0.0004 ETH to
deploy. `test/Deploy.s.t.sol` exercises the mining and deployment path, then initializes a pool
against the mined address and checks the hook prices both directions — an unexecuted deploy script is
a broken deploy script.

Note that four permission bits means roughly 1 in 16,384 salts qualifies, same as before: the flag
count does not change the search difficulty, only *which* addresses qualify.

## Status

Unaudited and undeployed. Reviewed adversarially (see `CROPS.md` for the trust-assumptions audit);
the design flaw that review found has been fixed and is covered by regression tests, but the
contract has not been re-reviewed *since* the fix, which is the obvious next step.

The fee curve is also **uncalibrated**: the defaults are reasoned, not fitted, and nothing here yet
demonstrates that the directional split leaves LPs better off than a static fee. That wants a
backtest against historical swap flow, not another test.

Ownership should be a multisig behind a timelock. `OWNER` currently defaults to the broadcasting
EOA, which is convenient and wrong for anything real.

Not production software. No warranty.
