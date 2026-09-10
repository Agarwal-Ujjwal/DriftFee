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

### 5. Stale `SwapParams` import path across published examples

Current v4-core defines `SwapParams` in `src/types/PoolOperation.sol`, but a large share of
published tutorials, blog posts, and generated code still use `IPoolManager.SwapParams`.
The compiler error is clear once you hit it, but it makes nearly every external `beforeSwap`
example non-compiling against current v4-core. A short "API changes since the v4 examples
you may have read" section in the docs would help newcomers calibrate which guides are current.
