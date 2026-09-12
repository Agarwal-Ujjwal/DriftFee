# CROPS trust-assumptions audit — DriftFee

Reviewed at commit `12cf7b1` (branch `main`), against the working tree. Everything below was read
from source in this repo and its pinned submodules, not from `README.md`. Where a claim in the
contract's own NatSpec is contradicted by the code, the code is reported.

CROPS is applied as five pillars — Censorship resistance, Open, Free as in freedom, Privacy,
Security — each with the risk, the mitigation actually present in code, and the route a user has out
if the mitigation fails.

> **Status note, added after the audit.** This audit was performed against the pre-redesign
> contract. Two of its findings have since been addressed, and the audit text below has been left
> as written rather than edited, so the record of what was found stays intact:
>
> - **The flat-rate hole is closed.** `minFee == baseFee == maxFee == MAX_CONFIGURABLE_FEE` was a
>   valid curve, giving a flat 10% fee in both directions with the drift mechanism disabled.
>   `baseFee` (and so `minFee`) is now independently capped by `MAX_BASE_FEE` (1%), and
>   `MAX_CONFIGURABLE_FEE` dropped to 3%. See `test_setParams_cannotFlattenPoolToASingleExtractiveRate`.
> - **The `OWNER` default is gone.** `script/Deploy.s.sol` now requires `OWNER` explicitly
>   (`OwnerMustBeSet`) and rejects an owner with no code unless `ALLOW_EOA_OWNER=true` is set
>   outright (`OwnerIsNotAContract`), so deploying under a bare EOA is a stated choice rather than
>   the default. A multisig-behind-timelock still cannot be enforced onchain; that remains an
>   operational requirement, documented in `README.md`.
>
> Separately, the fee rule itself has been replaced **twice** since this audit. It now prices the
> average distance from equilibrium over a swap's whole price path, after the second rule (drift
> created, measured endpoint-to-endpoint) was defeated by trade splitting. The hook gained
> `afterSwap` and `afterSwapReturnDelta` permissions along the way, which changed its deployed
> address. The Security and
> Censorship-resistance pillars below should be re-read with that in mind — in particular, the hook
> now takes a fee delta and calls `donate`, where previously it made no state-changing external
> calls at all. **This warrants a fresh audit rather than an amended one.**

---

## Architecture and its CROPS-aligned rationale

**DriftFee is a single, immutable, non-custodial Uniswap v4 `beforeSwap` fee-override hook with an
owner-tunable, hard-capped parameter set. There is no frontend, no backend, no relayer, no indexer,
no proxy, no token, and no treasury.** One contract, `src/DriftFee.sol`, deployed once per chain at a
CREATE2-mined address whose low 14 bits encode its two permissions (`afterInitialize`, `beforeSwap`).

The properties that follow from that shape, each verified against code:

- **No custody.** `src/DriftFee.sol` contains no `transfer`, no `call{...}`, no `receive`/`payable`,
  no ERC-6909 `take`/`settle`, no `delegatecall`, and no `selfdestruct` (grepped; zero hits). The
  inherited `BaseOverrideFee.getHookPermissions()` sets `beforeSwapReturnDelta: false`, so the hook
  structurally cannot claim a balance delta from a swap. The fee it names accrues to the pool's LPs
  through the PoolManager's own accounting; none of it reaches the hook or its owner.
- **No liquidity gating.** The same `getHookPermissions()` sets all four
  `before/afterAdd/RemoveLiquidity` flags to `false`. `modifyLiquidity` therefore never calls this
  hook. LP withdrawal is outside the hook's reach under every possible owner action and every
  possible hook failure. This is the single most important CROPS property in the design.
- **No per-address logic.** `_getFee(address, PoolKey calldata, SwapParams calldata, bytes calldata)`
  discards its `sender` parameter — it is unnamed in the signature. No mapping in the contract is
  keyed by address; the only two are keyed by `PoolId`. The fee is a pure function of pool state and
  swap direction, so the contract cannot express "this address pays more" even if its owner wanted to.
- **Not upgradeable.** No proxy, no initializer, no implementation slot. `poolManager` is `immutable`
  in `BaseHook`. The deployed bytecode is the final bytecode.

This is the right shape for CROPS, and most of the audit below is short *because* of it. That is not
the same as "too simple to audit" — the owner powers in §5 are a real and currently unmitigated
centralisation risk, and they are the main finding of this document.

---

## 1. Censorship Resistance

**Risk.** Who can prevent a valid user from swapping or exiting?

Reviewed for the usual levers and found none: there is no pause function, no kill switch, no
blacklist or allowlist, no guardian role, and no emergency mode anywhere in `src/DriftFee.sol`. The
complete privileged surface is three functions — `setDefaultParams`, `setPoolParams`,
`clearPoolParams` — all `onlyOwner`, all of which write parameters and nothing else.

The residual question is whether the owner can *induce* a revert and so block swaps indirectly. It
cannot, and this is load-bearing enough to show the chain of reasoning:

- `_validatedParams` rejects any curve with `maxFee > MAX_CONFIGURABLE_FEE` (`1e5`).
- `_feeFor` clamps the surcharge branch to `p.maxFee` and the discount branch to `p.minFee`, and
  `_validatedParams` enforces `minFee <= baseFee <= maxFee`. Every returned fee is therefore `<= 1e5`.
- `BaseOverrideFee._beforeSwap` returns `fee | LPFeeLibrary.OVERRIDE_FEE_FLAG`, and the PoolManager
  runs it through `LPFeeLibrary.removeOverrideFlagAndValidate`, which reverts `LPFeeTooLarge` only
  above `MAX_LP_FEE = 1_000_000`.

`1e5 < 1e6` with a factor of ten to spare, so **no owner-reachable parameter set can make the hook
revert a swap.** The owner can make swapping expensive (§5); it cannot make swapping impossible.

Non-owner censorship vectors are equally thin. There is no relayer, sequencer, RPC, frontend, or
indexer in this project — it ships contracts only, so the frontend-availability class of censorship
does not apply here rather than being mitigated here. Users reach the hook by calling the v4
`PoolManager` singleton, through any router or directly via `unlock`; the hook is passive and has no
entrypoint a user must pass through. The `.fork` test suite demonstrates the direct path against the
live mainnet manager.

**Mitigation.** The absence of the powers, which is stronger than their being guarded. Plus the
hook's inability to return an invalid fee, shown above.

**Escape route.**
- *LPs:* `modifyLiquidity` with a negative delta never touches this hook (all four liquidity
  permission flags are `false`). An LP can withdraw at any time, under any parameter set, even if the
  hook's swap path were entirely broken. No owner action and no bug in `_getFee` can trap liquidity.
- *Traders:* v4 pool creation is permissionless and the hook address is part of `PoolKey`, so an
  otherwise identical pool on the same pair with `hooks: address(0)` or a different hook is always
  available. Nothing in this repo can make the hooked pool the only venue for a pair.
- *Everyone:* the contract is MIT (§3) and non-custodial, so a redeployment with a different owner —
  or no owner — is a few hundred dollars of gas and a re-mined salt, using `script/Deploy.s.sol`
  unchanged.

**Accepted compromise.** DriftFee inherits the v4 `PoolManager`'s trust model. That singleton is
governed by Uniswap governance, which controls the protocol fee controller. This is not reducible by
a hook and is the price of building on v4 at all; the PoolManager has no pause and cannot freeze
positions, so the inherited exposure is to fee policy, not to censorship.

---

## 2. Open (Visibility)

**Risk.** A reviewer cannot rebuild the deployed artefact from a public commit, or some part of the
stack is opaque.

Etherscan verification is explicitly *not* accepted here as evidence of openness, and in any case
there is nothing deployed yet to verify — `README.md` states "Unaudited and undeployed," and the only
thing under `broadcast/` is a chain-1 *dry run*, which `.gitignore` excludes from the repo. So this
pillar is assessed on rebuildability.

What was reviewed:

- **Dependency pinning is exact.** `.gitmodules` + `git submodule status` pin `lib/forge-std` to
  `bf647bd6` (v1.16.2) and `lib/uniswap-hooks` to `acbd604c`; `foundry.lock` records the same
  tags and revs. `lib/uniswap-hooks`'s own submodules are pinned in turn: `v4-core` at `d153b048`,
  `v4-periphery` at `7ebd04b1`, `openzeppelin-contracts` at `fcbae539`. Every line of every
  dependency is source in the tree — there is not one binary artefact, prebuilt library, npm runtime
  dependency, or hosted service in the production path.
- **Compiler settings are pinned.** `foundry.toml` fixes `solc = "0.8.26"`, `evm_version = "cancun"`,
  `optimizer = true`, `optimizer_runs = 200`. Combined with the pinned sources this makes the
  bytecode reproducible from the commit.
- **The production build surface is small and fully enumerated.** The build-info for
  `out/DriftFee.sol/DriftFee.json` compiles exactly 30 source files: `src/DriftFee.sol`, two
  `uniswap-hooks` files, four OpenZeppelin files, and 23 v4-core interface/library/type files. No
  surprises.
- **CI is public and runs the real suite.** `.github/workflows/test.yml` runs `forge fmt --check`,
  `forge build --sizes`, and the unit/fuzz/invariant suite, with fork tests split into a
  `continue-on-error` job so a third-party RPC outage cannot mask or manufacture a failure.

Gaps found:

1. **CI does not pin the Foundry version.** `foundry-rs/foundry-toolchain@v1` installs whatever is
   current. `solc` is pinned in `foundry.toml` so this does not move the bytecode, but it does mean
   "the CI that went green" is not itself a reproducible artefact. Pinning `version:` in the workflow
   closes it.
2. **No reproducible-build check.** Nothing in CI recomputes and asserts the init-code hash, so a
   third party rebuilding the repo has no in-repo reference value to compare against. For a hook
   whose *address* is a mined function of its init code, publishing the expected init-code hash
   alongside the eventual deployment address is cheap and directly serviceable.
3. **`ffi = true` in `foundry.toml`** lets any test or script in the tree execute arbitrary local
   shell commands on a `forge test`. Nothing in `test/` or `script/` calls `vm.ffi` today (grepped;
   zero hits), so it is currently unused capability rather than active behaviour — but it is enabled
   repo-wide, and a reviewer who clones and runs the suite is trusting that. It should be removed
   until something needs it.
4. **The vendored v4-core is not the deployed v4-core.** `README.md` says so directly, and the pin
   (`d153b048`) is a post-`v4.0.0` commit. The unit suite therefore validates against a PoolManager
   that is not byte-identical to mainnet's. This is mitigated in-repo by `test/DriftFee.fork.t.sol`,
   which runs the override path against the actual deployed manager at
   `0x000000000004444c5dc75cB358380D2e3dE08A90` — a real mitigation, and the right one.

**Mitigation.** Exact submodule and compiler pinning; an all-source dependency tree; public CI.

**Escape route.** A reviewer can `git clone --recursive`, `forge build`, and derive the bytecode
independently; nothing about the build requires the authors' cooperation or infrastructure. If the
GitHub remote (`github.com/Agarwal-Ujjwal/DriftFee`) disappears, the submodule pins reference
upstream repositories that are themselves public and mirrored, and the hook's ~400 lines are
self-contained.

**Accepted compromise.** Openness here is contingent on that remote actually being public and on the
audited commit being tagged at deployment time. Neither can be verified from inside the working tree.

---

## 3. Free as in Freedom (License)

**Risk.** The licenses do not grant real fork-and-operate rights — the headline license is permissive
but a dependency needed to build or run is source-available or non-commercial.

This is the pillar where the finding is more interesting than the top-level `LICENSE` suggests, and
it required reading per-file SPDX headers rather than the repository-level license files.

| Component | License | Verified from |
|---|---|---|
| This repo | MIT | `LICENSE`; `// SPDX-License-Identifier: MIT` on `src/DriftFee.sol` and `script/Deploy.s.sol` |
| `lib/uniswap-hooks` (OpenZeppelin) | MIT | `lib/uniswap-hooks/LICENSE`; MIT headers on `BaseHook.sol`, `BaseOverrideFee.sol` |
| `openzeppelin-contracts` | MIT | vendored `LICENSE` |
| `forge-std` | MIT **or** Apache-2.0 (dual) | `LICENSE-MIT`, `LICENSE-APACHE` |
| `v4-periphery` | MIT | `LICENSE` (Universal Navigation Inc.); `HookMiner.sol` is MIT |
| `v4-core` | **mixed** — see below | per-file SPDX headers |

`v4-core` is the one that matters. Its `src/` tree is 40 MIT files, 35 `UNLICENSED` files, 8
**BUSL-1.1** files, and 1 GPL-3.0-or-later. The BUSL-1.1 set is `PoolManager.sol`, `libraries/Pool.sol`,
`Position.sol`, `Lock.sol`, `CurrencyDelta.sol`, `CurrencyReserves.sol`, `NonzeroDeltaCount.sol`, and
`test/ProxyPoolManager.sol`. `lib/uniswap-hooks/lib/v4-core/licenses/BUSL_LICENSE` gives Licensor
Universal Navigation Inc., Change Date "the earlier of 2027-06-15 or a date specified at
`v4-core-license-date.uniswap.eth`", and Additional Use Grant at `v4-core-license-grants.uniswap.eth`.
BUSL-1.1 is source-available, not free software, and on its own would fail this pillar.

**It does not fail here, and the reason is specific and checkable: not one BUSL file is in DriftFee's
production build.** The build-info for the `DriftFee` artefact lists 30 sources; every v4-core file
among them (`IPoolManager.sol`, `IHooks.sol`, `PoolKey.sol`, `PoolId.sol`, `PoolOperation.sol`,
`StateLibrary.sol`, `Hooks.sol`, `LPFeeLibrary.sol`, `BeforeSwapDelta.sol`, `Currency.sol`,
`FullMath.sol`, `CustomRevert.sol`, and the rest) carries an MIT header. Anyone may take this repo,
fork it, modify the curve, deploy it commercially, and operate it, under MIT alone.

Two honest limits on that:

1. **Forking the whole AMM is BUSL-restricted until 2027-06-15**, because deploying your own
   `PoolManager` means deploying BUSL code. DriftFee never does this: it attaches to the PoolManager
   instance already deployed on each chain, and calling an already-deployed contract is not a
   licensed use of its source. So the fork-and-operate right that matters *for this project* is
   intact; the restricted right is one DriftFee does not exercise.
2. **The test suite depends on `UNLICENSED` code.** `test/` imports
   `@uniswap/v4-core/test/utils/Deployers.sol`, `src/test/PoolSwapTest.sol`, and
   `src/test/PoolModifyLiquidityTest.sol`; all 35 `UNLICENSED`-marked files in v4-core live under
   those test directories. A downstream fork inherits a production tree that is cleanly MIT and a
   *test* tree whose licensing is unstated. This does not impair the right to run or modify DriftFee
   itself, but it does mean "fork the repo including its test harness and redistribute it" is not as
   clean as the MIT header implies.

**Mitigation.** MIT throughout the code this project authors and compiles; no copyleft obligations,
no field-of-use restriction, no non-commercial clause, no CLA in the tree.

**Escape route.** Fork, change the owner, redeploy, operate — legally unencumbered, and mechanically
supported by `script/Deploy.s.sol` (set `POOL_MANAGER` and `OWNER`, re-mine the salt). This is the
escape route every other pillar depends on, and it is real.

**Accepted compromise.** Dependence on a BUSL-licensed PoolManager that this project does not
redistribute, whose restriction expires 2027-06-15 at the latest, and whose deployed instances are
permissionlessly callable today.

---

## 4. Privacy

**Risk.** The system makes observable something that was not already observable, or exposes it to a
party that did not already have it.

The task asks for precision here rather than inflation, so the specific comparison:

The PoolManager already emits, for every swap,
`Swap(PoolId indexed id, address indexed sender, int128 amount0, int128 amount1, uint160 sqrtPriceX96, uint128 liquidity, int24 tick, uint24 fee)`
— the pool, the caller, both signed amounts, the resulting price and tick, and **the applied fee,
which for an override pool is exactly the number DriftFee returned**.

Against that baseline, DriftFee's three events add:

- `DriftFeeApplied(PoolId indexed id, int24 drift, uint24 fee, bool movingAway)` — `fee` is already in
  `Swap.fee`. `movingAway` is fully determined by the sign of `Swap.amount0`. `drift` is
  `currentTick - referenceTick`, and `currentTick` is already in `Swap.tick`. The only genuinely new
  quantity is the hook's reference tick, which is **pool-level state, not user-level state**, and is
  in any case readable by anyone at any time via the public view `driftState(PoolKey)` — an
  `eth_call` against any node, no event needed.
- `ReferenceTickUpdated(PoolId indexed id, int24 referenceTick, int24 sampleTick)` — at most once per
  `block.timestamp` per pool (gated by `if (state.lastUpdate != block.timestamp)`), and it carries no
  address and no amount. It indexes the same pool-level reference.
- `ReferenceTickSeeded(PoolId indexed id, int24 referenceTick)` — once per pool lifetime, at
  `afterInitialize`.

**No DriftFee event contains an address.** `_getFee`'s `sender` argument is unnamed and never read,
stored, or emitted. The contract has no address-keyed storage at all — its two mappings are keyed by
`PoolId`. So there is no per-user record, and no way for DriftFee's logs to link a trader to anything
that `Swap`'s own indexed `sender` field does not already link them to.

The correct conclusion is narrow and should not be overstated in either direction: **the incremental
privacy leakage from this hook is zero at the user level, and at the pool level it is a convenience
index over state that is already public by `eth_call`.** The fee a trader pays is a deterministic
function of public pool state plus their direction, so there is also no covert channel where the fee
reveals something about the trader.

Two further points checked:

- `quoteFee` is `view` and computes the fold in memory via `_foldedReference` without writing. Asking
  for a quote leaves no trace and cannot advance a pool's equilibrium — so simulation is not
  observable and cannot be used to fingerprint a would-be trader.
- There is no frontend, no analytics, no telemetry, no hosted RPC, and no indexer in this project.
  The frontend privacy risks — IP logging, wallet-address correlation at an RPC provider, third-party
  scripts — do not exist here because the surface does not exist. A user's RPC provider still sees
  their `eth_call`s and `eth_sendRawTransaction`, but that is their chosen provider and their
  relationship with the chain, not something DriftFee introduces or can affect.

**Mitigation.** None needed beyond what the design already does — no address-keyed state, no address
in any event, view-only quoting.

**Escape route.** Standard L1 privacy hygiene: a self-hosted or privacy-preserving RPC, and a fresh
address per position. Nothing about DriftFee interferes with either.

**Accepted compromise.** All activity on a public chain is public. DriftFee does not reduce that and
structurally cannot — it must read the pool's tick to price a swap. No shielding is claimed.

---

## 5. Security

This is the pillar with the real findings.

### 5.1 Custody, upgradeability, oracles — reviewed, no material risk

- **Funds.** The hook never custodies anything. No transfer, no `call`, no `payable`, no `receive`,
  no ERC-6909 claim, and `beforeSwapReturnDelta: false` means it cannot take a balance delta. It has
  no withdrawal function because it has nothing to withdraw. Even total owner-key compromise moves
  zero tokens out of the hook, because there are none in it.
- **Upgradeability.** None. No proxy, no initializer, no `delegatecall`, no `selfdestruct`.
  `poolManager` is `immutable`. Deployment is CREATE2 at a mined address; the address commits to the
  init-code hash, so the same address cannot later host different code.
- **Oracles.** No external oracle. The only external reads are `poolManager.getSlot0(id)` via
  `StateLibrary`, i.e. `extsload` against the manager the hook is bound to. There is no price feed to
  go stale, no keeper to stop running, no signature to forge, and no off-chain component of any kind.
  The equilibrium reference is derived entirely from top-of-block ticks of the pool itself
  (`_updateReference` folds at most one sample per `block.timestamp`, per the
  `state.lastUpdate != block.timestamp` gate), so there is no external liveness dependency.
- **Reentrancy.** Entrypoints are `onlyPoolManager` via `BaseHook`; the hook makes no external call
  other than `extsload` reads and holds no funds. The contract's stated reasoning for omitting a
  guard checks out against the code.

### 5.2 The `Ownable2Step` owner — material, currently unmitigated

The owner holds `setDefaultParams`, `setPoolParams`, and `clearPoolParams`. `Ownable2Step` means
handover requires the recipient to `acceptOwnership`, which prevents a fat-fingered transfer to a
dead address. `renounceOwnership` is inherited from `Ownable` and is **not** overridden, so the owner
can permanently relinquish control — relevant below, in both directions.

**What `_validatedParams` actually bounds.** Reading the guard itself rather than the docblock:

```solidity
if (
    newParams.minFee > newParams.baseFee || newParams.baseFee > newParams.maxFee
        || newParams.maxFee > MAX_CONFIGURABLE_FEE || newParams.feePerTick > MAX_FEE_PER_TICK
        || newParams.maxAdjustment > MAX_CONFIGURABLE_FEE || newParams.discountBps > BPS_DENOMINATOR
        || newParams.referenceWindow < MIN_REFERENCE_WINDOW || newParams.referenceWindow > MAX_REFERENCE_WINDOW
) revert InvalidParams();
```

It bounds exactly four things: the ordering `minFee <= baseFee <= maxFee`; the ceiling
`maxFee <= MAX_CONFIGURABLE_FEE = 1e5`; the ramp rate (`feePerTick <= 1e3`,
`maxAdjustment <= 1e5`, `discountBps <= 1e4`); and the window to `[1800, 604800]` seconds.

**What it does not bound, and the concrete worst case.** v4 fees are in hundredths of a bip, so
`MAX_LP_FEE = 1e6` is 100% and `MAX_CONFIGURABLE_FEE = 1e5` is **10% per swap**. Critically,
`minFee` has no independent ceiling — it is only required to be `<= baseFee`. So this passes
validation:

```solidity
Params({baseFee: 100_000, minFee: 100_000, maxFee: 100_000,
        feePerTick: 0, maxAdjustment: 0, discountBps: 0, referenceWindow: 1800})
```

`minFee > baseFee` is false, `baseFee > maxFee` is false, `maxFee > 1e5` is false. And tracing
`_feeFor` with it: the `movingAway` branch computes `surcharged >= 100_000` and clamps to
`p.maxFee = 100_000`; the discount branch computes `headroom = baseFee - minFee = 0`, so
`discount >= headroom` is true for every drift and the fee is `p.minFee = 100_000`. **Both branches
return 10%.** The worst-case owner action against an existing, liquid pool is therefore a flat,
unconditional, bidirectional 10% swap fee — 33x the deployment default of `baseFee = 3000` (0.30%) —
applied to a specific pool via `setPoolParams(key, ...)` with no opt-in from that pool's LPs or
traders, effective in the next block, and with the entire drift mechanism that is the point of the
hook switched off.

The `MIN_REFERENCE_WINDOW = 1800` floor is genuine and does what it says: no owner can shorten a
window into single-transaction manipulability. But the *other* end is the exploitable one — the owner
may set `referenceWindow` up to `MAX_REFERENCE_WINDOW = 7 days`, and changing it does **not** reset
`_driftStates`. On a volatile pair a 7-day reference goes stale, so ordinary price movement registers
as large drift, pinning one direction at `maxFee` and the other at `minFee`. That is a way to make a
pool sharply asymmetric without appearing to raise `maxFee` at all.

Summarising precisely, since the contract's own "Trust surface" docblock claims the owner "cannot
raise fees to an extractive level, nor shorten a reference window into manipulability, on pools that
have already opted in" — **the second clause is true, the first is not.** The caps bound the *rate*
at 10% per swap. They do not bound:

- **cumulative extraction**, which is 10% x volume, unbounded;
- **which pools** — `setPoolParams` accepts any `PoolKey`, including live pools with liquidity; there
  is no grandfathering, no per-pool consent, and no "frozen after first swap";
- **when it takes effect** — no timelock, no delay, no announcement period; a change can land in the
  same block as a victim's swap;
- **how often** — no rate limit and no maximum delta per update;
- **whether the discount exists at all** — `discountBps = 0` is valid and disables the headline
  behaviour of the product.

**The one genuine structural mitigation** is that the owner is not the beneficiary. The overridden
LP fee accrues to the pool's LPs through the PoolManager (less any protocol fee set by Uniswap
governance's fee controller); DriftFee has no fee recipient, no `take`, and no delta. So the worst
case is correctly characterised as *griefing traders and redirecting value to LPs*, not self-dealing —
**unless the owner is also a dominant LP in the affected pool**, in which case exactly the same
action becomes a directed transfer from traders to the owner, and the caps do not prevent it. That
conditional is the honest statement of the risk, and nothing in the code prevents the condition.

### 5.3 The EOA owner in `script/Deploy.s.sol` — the specific finding

```solidity
address owner = vm.envOr("OWNER", msg.sender);
```

`OWNER` **defaults to the broadcasting account** — a plain EOA, in practice the deployer's hot key.
Against the least-authority standard this fails on three counts, none of which is theoretical:

1. **Single point of compromise.** One private key holds `setPoolParams` over every pool that uses
   the hook, on that chain, forever. Compromise of that key is immediately the §5.2 worst case.
2. **No delay, so no user recourse.** Because the powers take effect in the next block, the
   `PoolParamsUpdated` event gives notice only *after* the fact. Users get zero window to withdraw or
   reroute. A delay is what converts an event into a warning.
3. **Silent by default.** The failure mode is that a deployer who never sets `OWNER` gets an EOA
   owner without being asked — the default is the unsafe choice, and `README.md` documents it as a
   convenience rather than flagging it.

**What it should be instead.** Two acceptable configurations:

- **Governed:** a multisig (k-of-n, independent signers, e.g. a Safe) holding `proposer` on an
  OpenZeppelin `TimelockController` — already available in the vendored tree at
  `lib/uniswap-hooks/lib/openzeppelin-contracts/contracts/governance/TimelockController.sol` — with
  the timelock as the hook's `owner`. The delay should be at least as long as an LP needs to observe
  a queued change and exit; 48 hours is the conventional figure, but the property that matters is
  that the delay is nonzero, so `PoolParamsUpdated` becomes advance notice rather than a receipt.
- **Ossified:** deploy with the intended curve and immediately call `renounceOwnership()`. The hook
  becomes fully immutable and §5.2 evaporates entirely. The contract supports this today, since
  `Ownable2Step` does not override `renounceOwnership`. The cost is that the curve can never be
  recalibrated — and `README.md` is candid that the defaults are "reasoned, not fitted," so this is
  premature *right now*, but it is the correct end state once a curve is calibrated.

In both cases `script/Deploy.s.sol` should **require** `OWNER` — `vm.envAddress("OWNER")`, which
reverts when unset — rather than `vm.envOr("OWNER", msg.sender)`. Choosing the owner of a live fee
mechanism should not be something a deployer can do by omission. The same script already takes this
posture for the PoolManager, reverting `UnsupportedChain` rather than guessing; the owner deserves at
least the same treatment.

The mirror of `renounceOwnership` not being overridden is that an owner can renounce *accidentally*,
freezing a bad curve forever. With a timelock as owner this is a non-issue; with an EOA it is one
more reason not to use an EOA.

### 5.4 Vendor liveness — if the team disappears

Nothing breaks. There is no server, no keeper, no oracle, no subscription, and no upgrade cadence to
maintain. The hook keeps pricing swaps from pool state indefinitely. LPs exit via `modifyLiquidity`,
which never calls the hook at all. Traders keep swapping, or move to an unhooked pool. The only thing
lost is recalibration — which, if the owner is a timelock whose signers have vanished, means the curve
ossifies at its last value. For a contract that holds no funds, ossification is an acceptable terminal
state, and it is strictly better than the EOA case where the same disappearance leaves a live,
unrecoverable key.

One bounded-horizon note, stated without inflation: `_seedReference` and `_updateReference` call
`block.timestamp.toUint32()`, which reverts once `block.timestamp` exceeds `type(uint32).max` in
February 2106. From that point `beforeSwap` reverts and swaps on hooked pools fail. Liquidity
withdrawal is unaffected, for the same reason as everywhere else in this document. Not actionable
today; recorded for completeness.

**Escape route (Security).** LP withdrawal is unconditionally available and never routes through the
hook. Traders can use an unhooked pool on the same pair. Anyone can redeploy the MIT-licensed hook
with a timelock owner, or with no owner, and pool creators can point new pools at that instance
instead. No user's exit depends on the owner's cooperation, the deployer's key, or the authors'
continued existence.

---

## Accepted compromises

Listed explicitly, each with its justification:

1. **An owner exists at all, and can move an existing pool to a flat 10% fee with immediate effect
   (§5.2).** Justified only by the fact that the curve is admittedly uncalibrated — `README.md`
   concedes the defaults are "reasoned, not fitted" — so a tuning power is genuinely needed for now.
   It is *not* justified in its present form: the power needs a timelock and a multisig, and the
   long-run answer is `renounceOwnership()` once a curve is fitted. The cap bounds the rate at 10%
   per swap; it does not bound total extraction, scope, or timing.
2. **`OWNER` defaults to an EOA (§5.3).** Not justified. It should be a required parameter, and the
   value should be a timelock. This is the single change with the largest CROPS effect in the repo.
3. **Dependence on the v4 `PoolManager` singleton and Uniswap governance's protocol fee controller
   (§1).** Irreducible for a v4 hook, and the exposure is to fee policy, not to censorship or custody.
4. **A BUSL-1.1 `PoolManager` in the dependency graph (§3).** Not redistributed, not in DriftFee's
   production build (verified: all 30 compiled sources are MIT), restriction expires 2027-06-15 at
   the latest, and the deployed instances are permissionlessly callable regardless.
5. **`UNLICENSED` v4-core test helpers in the test path (§3).** Affects redistribution of the test
   harness only; the production tree is cleanly MIT and the right to fork and operate DriftFee is
   unimpaired.
6. **`ffi = true` repo-wide (§2).** Currently unused. Should be removed, not justified.
7. **The vendored v4-core is not byte-identical to the deployed PoolManager (§2).** Mitigated by
   `test/DriftFee.fork.t.sol` exercising the override against the live mainnet manager.
8. **Full public observability of all swap activity (§4).** Inherent to a public chain and not
   something a fee hook can or should attempt to change. DriftFee adds no user-level leakage on top
   of the PoolManager's own `Swap` event.

## Recommended changes, in priority order

1. Make `OWNER` required in `script/Deploy.s.sol` (`vm.envAddress`, not `vm.envOr(..., msg.sender)`),
   and deploy with a multisig-behind-`TimelockController` as owner.
2. Give `minFee` an independent ceiling in `_validatedParams`, or introduce a per-update rate limit,
   so the flat-`MAX_CONFIGURABLE_FEE` configuration in §5.2 is unreachable and the contract's own
   "cannot raise fees to an extractive level" docblock becomes true.
3. Correct that docblock in `src/DriftFee.sol` in the meantime — an inaccurate trust-surface claim in
   the source is worse than no claim, because reviewers read it instead of `_validatedParams`.
4. Remove `ffi = true` from `foundry.toml`; pin the Foundry version in `.github/workflows/test.yml`;
   publish the expected init-code hash with the deployment.
