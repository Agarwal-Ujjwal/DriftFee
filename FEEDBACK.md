# Developer Feedback — Building DriftFee on Uniswap v4

Running log of genuine friction encountered while building DriftFee, a Uniswap v4
directional dynamic-fee hook. Entries are added as they happen, not retroactively.

Environment: Foundry 1.7.1 (`4072e487`, 2026-05-08), macOS (darwin 24.6.0),
v4-core `v4.0.0-19-gd153b048`, OpenZeppelin uniswap-hooks `v1.2.1`.

---

## 2026-09-08 — Phase 1: environment and dependency setup

### 1. Foundry's default `evm_version` is now three forks ahead of what v4 targets

A fresh `forge init` on Foundry 1.7.1 resolves to `evm_version = "osaka"`. The entire
v4 stack — v4-core, v4-periphery, and OpenZeppelin's uniswap-hooks — pins
`evm_version = "cancun"` in its own `foundry.toml`. Nothing in the toolchain warns about
the mismatch, and the project compiles fine either way, so the discrepancy is invisible
until you deploy bytecode targeting a fork the chain may not have.

Confirming this required reading `forge config` output line by line and comparing against
the vendored library's `foundry.toml`. A note in the v4 hook docs saying "set
`evm_version = "cancun"` explicitly, do not rely on the Foundry default" would have saved
the investigation. This is likely to bite every new hook developer as Foundry's default
keeps advancing past cancun.

### 2. v4 arrives as a transitive dependency two levels deep, in two copies

Installing only `OpenZeppelin/uniswap-hooks` pulls v4 in implicitly:
`lib/uniswap-hooks/lib/v4-core`. `git submodule status --recursive` reports 30+ nested
submodules, and **two different copies of v4-core at different commits**:

- `lib/uniswap-hooks/lib/v4-core` → `v4.0.0-19-gd153b048`
- `lib/uniswap-hooks/lib/v4-periphery/lib/v4-core` → `v4.0.0-12-g59d3ecf5`

Which one your `@uniswap/v4-core/...` imports actually resolve to is not discoverable from
the source tree; it takes `forge remappings` to find out (the uniswap-hooks copy wins).
For a first-time v4 developer this is genuinely confusing — you cannot tell which v4-core
you are building against by looking at the repo. Flattening these, or documenting the
intended resolution, would help.

### 3. Unpinned `solc` silently produces a mixed-compiler build

With no `solc` pin, Foundry selected **0.8.35** for uniswap-hooks sources (`pragma ^0.8.26`)
and auto-installed **0.8.26** for v4-core (`pragma 0.8.26`, pinned exactly) in the same
project. Two compilers, one build, no warning. v4-core's exact pragma pin is the right
call, but combined with the caret pragmas upstream it makes an unpinned downstream project
non-reproducible by default. Worth calling out in hook-development docs.

### 4. `DYNAMIC_FEE_FLAG` and `OVERRIDE_FEE_FLAG` are easy to confuse, and guessing wrong fails silently

`LPFeeLibrary` defines two similar `uint24` flags used at different points in a pool's life
(`lib/uniswap-hooks/lib/v4-core/src/libraries/LPFeeLibrary.sol:15,19`):

- `DYNAMIC_FEE_FLAG = 0x800000` — goes in `PoolKey.fee` at pool initialization
- `OVERRIDE_FEE_FLAG = 0x400000` — what `beforeSwap` ORs into its returned fee

Returning `fee | 0x800000` from `beforeSwap` — the wrong one — does **not** revert. The
override bit is simply unset, `isOverride()` returns false, and the pool quietly keeps
charging its stored fee. A dynamic-fee hook built this way looks deployed and functional
while doing nothing at all, with no error to debug.

Third-party guides and LLM-generated hook samples do get this wrong, which suggests the
confusion is widespread. Two mitigations would help: name the constants less
symmetrically, and have `beforeSwap`'s return path revert (or emit) when a hook with the
`BEFORE_SWAP_FLAG` returns a nonzero fee without the override bit set, rather than
discarding it silently.

Addressed in DriftFee's tests by reading the fee off the pool manager's own `Swap` event
rather than trusting the hook's return value — see `test_swap_atEquilibrium_poolChargesBaseFee`.

### 5. Stale `SwapParams` import path across published examples

Current v4-core defines `SwapParams` in `src/types/PoolOperation.sol`, but a large share of
published tutorials, blog posts, and generated code still use `IPoolManager.SwapParams`.
The compiler error is clear once you hit it, but it makes nearly every external `beforeSwap`
example non-compiling against current v4-core. A short "API changes since the v4 examples
you may have read" section in the docs would help newcomers calibrate which guides are current.

---

## 2026-09-11 — Phase 2: writing and testing the hook

### 6. A hook's own constructor validation is effectively untestable

`BaseHook`'s constructor calls `_validateHookAddress(this)`, which compares the deployed
address's low bits against `getHookPermissions()`. Base constructors run before the derived
body, so `new MyHook(badArgs)` reverts with `HookAddressNotValid` at whatever address `create`
happens to pick — the derived contract's own `revert InvalidParams()` is unreachable through
`new`, at any address. A hook cannot unit-test its own constructor input validation the
obvious way.

The standard workaround, forge-std's `deployCodeTo`, does not help either: it wraps the
deployment in `require(success, "StdCheats deployCodeTo(...): Failed to create runtime
bytecode.")`, which discards the constructor's revert data. So you can observe *that* the
constructor reverted but not *why*, and `vm.expectRevert(MyError.selector)` never matches.

Getting a real assertion required hand-rolling the deployment: `vm.etch` the creation code
plus ABI-encoded args to a flag-valid address, call it raw, and decode the returned revert
data (`_assertConstructorReverts` in `test/DriftFee.t.sol`). That is a lot of ceremony for
"check the constructor rejects bad parameters", and it is the kind of test most hook authors
will simply skip. A `deployCodeTo` variant that bubbles constructor revert data would fix this
for every hook project, not just this one.

### 7. Two OpenZeppelin conventions collide: coverage stubs become fuzz targets

uniswap-hooks marks mocks with an empty `function test() public {}` so `forge coverage`
excludes them. Reasonable in isolation. But an invariant handler is also a contract you pass
to `targetContract()`, and the fuzzer targets *all* public functions by default — so the
coverage stub becomes a fuzz target. In the first run of DriftFee's invariant suite, 666 of
2048 calls went to `test()`, silently burning a third of the budget on a no-op.

Nothing surfaces this except reading the per-selector call table and noticing a selector that
shouldn't be there. `targetSelector` fixes it, but you have to know to look. Worth a note in
the invariant-testing docs: if a handler carries a coverage-exclusion stub, restrict selectors
explicitly.

### 8. Transitive remapping paths do not match the directory tree

`MockERC20` is imported from `solmate/src/test/utils/mocks/MockERC20.sol`. The remapping is
`solmate/=lib/uniswap-hooks/lib/v4-core/lib/solmate/`, so the `src/` in the middle of the
import path is part of solmate's own layout, not something `forge remappings` shows you. The
natural guess — `solmate/test/utils/mocks/MockERC20.sol`, mirroring what the directory listing
suggests — fails with a bare "File not found".

The fix is to grep an existing v4-core test for the import and copy it. That works, but it
means the practical way to discover an import path in this dependency tree is imitation rather
than inspection. Combined with entry 2 (two copies of v4-core at different commits), imports
are the single largest papercut in v4 hook development so far.

### 9. `forge lint` has no expression-level suppression for provably-safe casts

Arithmetic on bounded values produces `unsafe-typecast` warnings even where the bound is
established a few lines earlier and the cast cannot truncate (e.g. casting a value already
clamped to `maxFee`, itself a `uint24`, back to `uint24`). Suppression is line-level only, so
a line containing two casts cannot have one justified and the other left flagged, and the
`// forge-lint: disable-next-line(...)` comments end up outnumbering the code they annotate.
Warnings are correct to raise by default; an expression-level opt-out would let a project keep
a genuinely clean lint baseline instead of learning to ignore its own output.

---

## 2026-09-12 — Phase 3: static analysis

### 10. Slither's `timestamp` detector taints unrelated comparisons in time-weighted logic

Running `slither .` on DriftFee produced 9 findings, 8 of which were noise concentrated in one
detector family. The `timestamp` detector flagged, among others:

- `surcharged > p.maxFee` — comparing a fee against a fee cap
- `adjustment > p.maxAdjustment` — comparing an adjustment against its cap
- `driftScaled > 0` — the sign of a tick difference

None of these involve `block.timestamp`. They were flagged because the enclosing function
transitively receives an `elapsed` argument derived from a timestamp, so the taint analysis marks
every comparison downstream of it. For a hook whose entire mechanism is a time-decayed average, that
means the detector lights up the fee math rather than the time handling, and the one comparison that
genuinely *is* timestamp-sensitive (`state.lastUpdate != block.timestamp`) arrives buried among six
that are not.

The practical consequence is that the detector is unusable as written on this class of contract: you
cannot triage per-finding without suppressing the real one alongside the noise, so the realistic
options are to disable it wholesale or to ignore its output. Narrowing the taint to comparisons whose
operands are actually time quantities — rather than anything reachable from one — would make it
actionable on time-weighted DeFi logic.

### 11. `slither .` runs `forge clean` and force-rebuilds, discarding the build cache

Each invocation runs `forge clean` followed by `forge build --force`, so every static-analysis run
throws away the compilation cache and the next `forge test` pays a full 94-file rebuild. On this
project that is a few seconds, but it makes an analyse-then-test loop noticeably worse than it needs
to be, and it is surprising: nothing in `slither .` suggests it is destructive to build state.

Reading existing artifacts, or at least offering a flag to skip the clean when the artifacts are
current, would make static analysis cheap enough to run on every change rather than in batches.

### 12. One real finding out of nine, and it was the quietest one

For the record of what the tool was worth: the single genuine finding was `divide-before-multiply` in
the discount path. The code computed `adjustment` in whole hundredths of a bip and *then* scaled it
by `discountBps`, so a drift-reducing swap whose raw adjustment was, say, 1.9 units had it floored to
1 before taking 90% of it, flooring again to 0 — the discount silently vanished. Keeping the
adjustment scaled until the final division fixes it.

That finding is also the least alarming-looking of the nine, which is the useful lesson: the
high-severity-sounding output was all noise, and the one worth acting on was filed as a
precision nit.

### 13. Slither and Mythril cannot share a virtualenv

The pre-deploy checklists that name static analysis name both of these tools, so the natural move is
to install both. Doing that into one venv silently degrades the first: `pip install mythril` into the
Slither venv downgraded `eth-typing` (5.x -> 3.5.2), `eth-utils` (5.x -> 2.3.2), `eth-abi`,
`eth-account` and `hexbytes` below the floors `slither-analyzer 0.11.4` declares, printing eight
"is incompatible" lines and leaving an environment pip itself considers broken.

Slither kept working afterwards, but only because it does not exercise the downgraded APIs — nothing
verified that, and nothing warned that the tool installed *first* is the one degraded. Each needs its
own virtualenv. That is easy once you know, and invisible until something misbehaves; a note in
either tool's install docs would cover it.

### 14. `myth foundry` looks for Hardhat's artifact directory

Mythril 0.24.8 ships a `foundry` subcommand. On a Foundry project it fails immediately:

```
FileNotFoundError: [Errno 2] No such file or directory:
  '.../DriftFee/artifacts/contracts/build-info'
```

`artifacts/contracts/build-info` is Hardhat's layout; Foundry writes `out/build-info`. Symlinking one
to the other gets it past that, and straight into a second failure:

```
KeyError: 95
  in soliditycontract.py:356, _is_autogenerated_code
    in self.solc_indices[file_index].full_contract_src_maps
```

— it indexes its source-map table by a file index it never registered, so the subcommand is unusable
on a project with this many sources regardless of where the artifacts live.

What does work is the generic path: `myth analyze src/DriftFee.sol:DriftFee --solc-json <settings>`
with `solc` on `PATH`. That needs the project's remappings, optimizer settings and `evmVersion`
restated by hand in a solc standard-json `settings` blob, because Mythril does not read
`foundry.toml` — generated here from `forge remappings` into `myth-solc.json`. Given the subcommand
exists and is named `foundry`, the failure mode is worse than not having it: it looks like the
supported route and gives no hint that the generic one is the working one.

---

## 2026-09-12 — Phase 4: deployment

### 15. `vm.setEnv` writes to the process environment, which every test in the run shares

A deploy script naturally reads configuration from environment variables, so testing it means
setting them. `vm.setEnv` does not write to a per-test sandbox: it writes to the process
environment, shared by every test in the invocation. Forge rolls back EVM state between tests; it
does not and cannot roll back `setenv`.

This surfaced as a test that passed alone and failed in the suite, with the *other* test's value:

```
[FAIL: optimism: 0x7D67...327f != 0x9a13...4Ec3] test_poolManagerTableIsCorrectPerChain()
```

`0x7D67...` is `makeAddr("customManager")` from a sibling test that sets `POOL_MANAGER`. Clearing it
at the end of that test did not help, and neither did clearing it at the start of the reader — the
two tests are not ordered with respect to each other in a way a test author can rely on.

Two things make this sharper than ordinary shared state. There is no cheatcode to *unset* a
variable, and setting it to the empty string does not clear it — `vm.envOr` still reports it as
present, so a sentinel value is the only way to hand the environment back neutral. And the failure
is order-dependent, so it appears as a flake rather than as a bug.

The fix that actually holds is structural: don't let a test depend on a value another test can write.
Splitting the override lookup from the chain table, and asserting against the table directly, removed
the shared-state dependency entirely. But it took a confusing debugging detour to get there, and a
warning in the `setEnv` docs that the write is process-global and not rolled back would have short-
circuited it.

### 16. Deploying a hook costs a salt search, and nothing in the toolchain says so

`BaseHook`'s constructor validates that the deployer chose an address whose low 14 bits encode the
hook's permissions, which makes `new MyHook(...)` unusable as a deployment strategy — the deployment
path is genuinely different in kind from every other contract. `HookMiner` exists in v4-periphery and
does the job well, but it is in `src/utils` of a package most hook projects pull in only
transitively, and nothing in `BaseHook`'s revert (`HookAddressNotValid`) points at it.

Worth noting for calibration: the search is cheap. Two flag bits means roughly 1 in 16,384 salts
qualifies, and a mainnet dry run found one at salt `0xa27` — 2,599 iterations. Deployment came to
about 0.0004 ETH. Both numbers are far smaller than the "mining an address" framing suggests, and
saying so in the hook docs would save people budgeting for something expensive.

---

## 2026-09-12 — Phase 5: redesigning the fee rule

### 17. A fee that depends on a swap's *outcome* cannot use the dynamic-fee mechanism at all

v4's dynamic LP fee is set in `beforeSwap`, which means it can only ever be a function of state the
swap has not yet touched. DriftFee needed the opposite — a fee priced on the drift a swap *creates* —
and no amount of parameter tuning gets there, because the quantity does not exist yet at the moment
the mechanism demands an answer.

The workaround is to charge in two places: override the LP fee to the floor in `beforeSwap` so it
flows through the pool's own accounting, then take the remainder in `afterSwap` via
`afterSwapReturnDelta` and donate it to in-range LPs. That works, and the take-and-donate pair
cancels so the hook never holds a balance. But it is three mechanisms (fee override, hook delta,
donate) doing the job of one, the two components compound rather than sum, and the pool's `Swap`
event now reports only the floor — so any offchain consumer reading `fee` from the event sees a
number that is not what the swapper paid. That last part is a silent trap for indexers.

Worth saying plainly in the hook docs: **outcome-dependent fees are not what the dynamic-fee flag is
for**, and the `afterSwap` + donate composition is the supported shape.

### 18. `BaseDynamicAfterFee` looks like the right base class and is not

Its name and description ("dynamic target hook fees applied after swaps") match this use case almost
exactly, and it already implements the transient-storage plumbing, the ERC-6909 take, and the
handler callback that an `afterSwap` fee needs. But `_getTargetUnspecified` is invoked from
`_beforeSwap` — the target is computed *before* the swap and merely *enforced* afterwards. So it
carries the same pre-swap-knowledge constraint as the fee override, and cannot express a fee that
depends on where the swap actually landed.

That is only discoverable by reading the implementation; the contract-level documentation describes
it in terms of "after swaps" throughout. A sentence noting that the target is fixed before execution
would have saved the detour.

### 19. Hook `afterSwap` implementations hit stack-too-deep almost immediately

`_afterSwap` receives five parameters and returns two. Adding the pool id, the effective parameters,
the pre- and post-swap drift, the fee, the unspecified currency and its amount was enough to exceed
the stack with the optimizer on, at `solc 0.8.26` without `via_ir`:

```
Error: Compiler error (LValue.cpp:55): Stack too deep.
```

Splitting the body into a pricing function and a collection function fixed it, and the result reads
better, so this is a mild push toward good structure rather than a real obstacle. But the error
arrives with no indication of which variables are at fault, and the natural first reaction —
enabling `via_ir` — is a heavier change than the situation warrants. Hooks are unusually prone to
this because the callback signatures are fixed and wide; a note in the hook docs suggesting a
split-by-default structure would land better than the compiler's suggestion.

### 20. Nothing in the hook tooling prompts you to test a fee rule against trade splitting

Two fee rules shipped here with full unit, fuzz, invariant and fork coverage, and both were defeated
by the same trivially available manoeuvre: cut the trade into N pieces. The second rule went from
"passes 74 tests including 10,000-run fuzzing" to "within 3.4bps of having no hook at all" under a
40-way split.

No tooling suggests this. `forge test` has no notion of it, none of the example hooks demonstrate it,
and the v4 hook documentation discusses dynamic fees purely in terms of what a single swap should be
charged. Yet **split-invariance is close to a correctness requirement for any hook that charges a
rate on notional derived from pool state**: if `fee(V) != sum(fee(V/N))`, the larger of the two is
advisory only, because execution algos already slice by default.

The underlying rule is simple enough to state: a fee that is a function of the *endpoints* of a
swap's price path, charged as a rate on notional, is split-exploitable. It has to be an integral over
the path. That is not obvious from anything in the docs, and the failure is silent — the mechanism
keeps working, just not for anyone who slices.

Two cheap things would help every hook author: a worked splitting attack in the dynamic-fee hook
examples, and a note in the docs that a fee derived from a price *delta* needs a split-invariance
argument. A reusable `assertSplitInvariant(pool, notional, slices)` test helper would be better still.
