// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {DriftFee} from "src/DriftFee.sol";
import {DriftFeeHarness} from "./utils/DriftFeeHarness.sol";

interface IERC20Like {
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function decimals() external view returns (uint8);
}

interface IWETH is IERC20Like {
    function deposit() external payable;
}

/**
 * @dev Exercises DriftFee against the **deployed** mainnet `PoolManager` and real USDC/WETH, rather
 * than a locally compiled manager and freshly minted 18-decimal mocks.
 *
 * Two things only a fork can establish:
 *
 * 1. That the real manager honours the hook's override fee. The unit suite compiles its own
 *    `PoolManager` from the vendored v4-core, which is a *different commit* from what is deployed
 *    (see `FEEDBACK.md` entry 2 — this repo resolves two copies of v4-core at different commits).
 *    A dynamic-fee hook that silently fails to override is the exact failure mode of entry 4, so
 *    checking it against deployed bytecode is the point of this file.
 * 2. That the drift math survives a 6-decimal/18-decimal pair at a realistic price. Every unit test
 *    runs at tick 0 on two 18-decimal mocks, which is precisely the setup in which a decimals bug
 *    cannot show up.
 *
 * Runs against the latest block by default, so it needs no archive node. Set `FORK_BLOCK` to pin it.
 * Skips (rather than fails) when no RPC is reachable, so it does not break a CI run without secrets.
 */
contract DriftFeeForkTest is Test {
    using StateLibrary for IPoolManager;

    /// @dev Verified onchain: 24KB of code, owner is the Uniswap timelock.
    address internal constant POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;

    /// @dev Verified onchain: 6 decimals, not 18.
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    string internal constant FALLBACK_RPC = "https://ethereum-rpc.publicnode.com";

    uint160 internal constant HOOK_FLAGS = uint160(Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG);

    bytes32 private constant SWAP_TOPIC = keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");

    /// @dev USDC sorts below WETH, so USDC is currency0 and the price is WETH-per-USDC.
    int24 internal constant INITIAL_TICK = 193_380; // ~4000 USDC per WETH
    int24 internal constant TICK_SPACING = 60;
    int24 internal constant RANGE = 6000;

    bool internal forkLive;

    IPoolManager internal manager;
    PoolSwapTest internal swapRouter;
    PoolModifyLiquidityTest internal liquidityRouter;
    DriftFeeHarness internal hook;
    PoolKey internal key;

    address internal owner = makeAddr("owner");

    /// @dev `PoolModifyLiquidityTest` refunds leftover native value to `msg.sender`, so the test
    /// contract has to be able to receive it.
    receive() external payable {}

    function setUp() public {
        if (!_selectFork()) return;

        manager = IPoolManager(POOL_MANAGER);
        require(POOL_MANAGER.code.length > 0, "no PoolManager code on this fork");

        // The manager is the deployed one; only the peripheral routers are ours.
        swapRouter = new PoolSwapTest(manager);
        liquidityRouter = new PoolModifyLiquidityTest(manager);

        hook = DriftFeeHarness(address(HOOK_FLAGS));
        deployCodeTo(
            "test/utils/DriftFeeHarness.sol:DriftFeeHarness", abi.encode(POOL_MANAGER, owner, _params()), address(hook)
        );

        key = PoolKey({
            currency0: Currency.wrap(USDC),
            currency1: Currency.wrap(WETH),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });

        manager.initialize(key, TickMath.getSqrtPriceAtTick(INITIAL_TICK));

        _fund();
        liquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: INITIAL_TICK - RANGE, tickUpper: INITIAL_TICK + RANGE, liquidityDelta: 1e16, salt: 0
            }),
            ""
        );

        forkLive = true;
    }

    function _params() internal pure returns (DriftFee.Params memory) {
        return DriftFee.Params({
            baseFee: 3000,
            minFee: 500,
            maxFee: 10_000,
            feePerTick: 30,
            maxAdjustment: 7000,
            discountBps: 10_000,
            referenceWindow: 1800
        });
    }

    /*//////////////////////////////////////////////////////////////
                                 TESTS
    //////////////////////////////////////////////////////////////*/

    /// @dev Sanity-checks the fixture itself: if the 6-vs-18-decimal pair were set up wrongly, the
    /// implied price would be off by orders of magnitude and every drift assertion below would be
    /// measuring nonsense.
    function test_fork_poolPriceIsRealistic() public {
        _requireFork();

        (uint160 sqrtPriceX96, int24 tick,,) = manager.getSlot0(key.toId());

        assertEq(tick, INITIAL_TICK, "pool did not initialize at the intended tick");
        assertEq(IERC20Like(USDC).decimals(), 6, "USDC is not 6 decimals on this fork");
        assertEq(IERC20Like(WETH).decimals(), 18, "WETH is not 18 decimals on this fork");

        // price = token1/token0 in raw units = wei per USDC unit. USDC per WETH is then
        // 1e18 / (price * 1e6) = 1e12 / price.
        uint256 priceX96 = FullMath.mulDiv(sqrtPriceX96, sqrtPriceX96, FixedPoint96.Q96);
        uint256 usdcPerEth = FullMath.mulDiv(1e12, FixedPoint96.Q96, priceX96);

        assertGt(usdcPerEth, 100, "implied ETH price implausibly low; check decimals");
        assertLt(usdcPerEth, 100_000, "implied ETH price implausibly high; check decimals");
    }

    function test_fork_seedsEquilibriumAtInitializationTick() public {
        _requireFork();

        (int24 referenceTick, uint32 lastUpdate, bool initialized) = hook.driftState(key);

        assertTrue(initialized);
        assertEq(referenceTick, INITIAL_TICK);
        assertEq(lastUpdate, uint32(block.timestamp));
    }

    /**
     * @dev The load-bearing fork assertion: the deployed manager applies the fee the hook returns.
     *
     * If the override flag were wrong, this would still pass compilation, still emit the hook's own
     * event, and still look deployed — the pool would just quietly charge its stored fee of 0. So
     * the fee is read off the manager's own `Swap` event.
     */
    function test_fork_deployedManagerAppliesOverrideFee() public {
        _requireFork();

        assertEq(_swapAndReadPoolFee(true, 1e10), _params().baseFee);
    }

    function test_fork_awayFromEquilibriumIsSurcharged() public {
        _requireFork();

        _swap(true, 2e11); // push the tick down, away from equilibrium

        (, int24 tickAfter,,) = manager.getSlot0(key.toId());
        assertLt(tickAfter, INITIAL_TICK, "swap did not move the price");

        assertGt(_swapAndReadPoolFee(true, 1e10), _params().baseFee);
    }

    function test_fork_towardEquilibriumIsDiscounted() public {
        _requireFork();

        _swap(true, 2e11);

        assertLt(_swapAndReadPoolFee(false, 1e16), _params().baseFee);
    }

    /// @dev Manipulation resistance against the real manager: no amount of intra-block trading moves
    /// equilibrium, because the reference only folds once `block.timestamp` advances.
    function test_fork_equilibriumIsNotMovableWithinABlock() public {
        _requireFork();

        (int24 referenceBefore,,) = hook.driftState(key);

        _swap(true, 5e11);
        _swap(false, 1e17);
        _swap(true, 5e11);

        (int24 referenceAfter,,) = hook.driftState(key);

        assertEq(referenceAfter, referenceBefore, "equilibrium moved inside a single block");
    }

    function test_fork_equilibriumFoldsAcrossBlocks() public {
        _requireFork();

        _swap(true, 2e11);
        (, int24 standingTick,,) = manager.getSlot0(key.toId());

        vm.warp(block.timestamp + 180);
        vm.roll(block.number + 1);
        _swap(true, 1e6);

        (int24 referenceAfter,,) = hook.driftState(key);

        assertEq(
            referenceAfter,
            int24(hook.fold(int256(INITIAL_TICK) * 1e6, standingTick, 180, 1800) / 1e6),
            "fold against the real manager did not match the expected reference"
        );
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev Selects a mainnet fork, returning false if none is reachable so the suite can skip.
    function _selectFork() private returns (bool) {
        // Treat an empty value as unset, not as a URL: CI sets `MAINNET_RPC_URL` to the empty
        // string when the secret is absent, which `envOr` reports as present.
        string memory rpc = vm.envOr("MAINNET_RPC_URL", string(""));
        if (bytes(rpc).length == 0) rpc = FALLBACK_RPC;

        uint256 pinned = vm.envOr("FORK_BLOCK", uint256(0));

        if (pinned == 0) {
            // Latest block: this test depends only on the manager's and tokens' code, never on
            // historical state, so an archive node is not required.
            try vm.createSelectFork(rpc) {
                return true;
            } catch {
                return false;
            }
        }

        try vm.createSelectFork(rpc, pinned) {
            return true;
        } catch {
            return false;
        }
    }

    function _requireFork() private {
        vm.skip(!forkLive);
    }

    function _fund() private {
        deal(USDC, address(this), 1e14); // 100M USDC
        vm.deal(address(this), 1e23);
        IWETH(WETH).deposit{value: 1e23}(); // 100k WETH

        IERC20Like(USDC).approve(address(swapRouter), type(uint256).max);
        IERC20Like(USDC).approve(address(liquidityRouter), type(uint256).max);
        IERC20Like(WETH).approve(address(swapRouter), type(uint256).max);
        IERC20Like(WETH).approve(address(liquidityRouter), type(uint256).max);
    }

    function _swap(bool zeroForOne, int256 amount) private {
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -amount,
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    function _swapAndReadPoolFee(bool zeroForOne, int256 amount) private returns (uint24 fee) {
        vm.recordLogs();
        _swap(zeroForOne, amount);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == POOL_MANAGER && logs[i].topics[0] == SWAP_TOPIC) {
                (,,,,, fee) = abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
                return fee;
            }
        }
        revert("no Swap event from the deployed manager");
    }
}
