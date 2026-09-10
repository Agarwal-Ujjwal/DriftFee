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
