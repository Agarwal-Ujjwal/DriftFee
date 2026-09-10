// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {CommonBase} from "forge-std/Base.sol";
import {StdUtils} from "forge-std/StdUtils.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

/**
 * @dev Drives random swap sequences and time advances against a `DriftFee` pool, recording the
 * range of ticks the pool has actually visited so the invariant suite can assert that equilibrium
 * never escapes it.
 */
contract DriftFeeHandler is CommonBase, StdUtils {
    using StateLibrary for IPoolManager;

    IPoolManager private immutable _manager;
    PoolSwapTest private immutable _swapRouter;
    PoolKey private _key;

    int24 public minObservedTick;
    int24 public maxObservedTick;
    uint256 public swapCount;
    uint256 public timeAdvanceCount;

    constructor(IPoolManager manager_, PoolSwapTest swapRouter_, PoolKey memory key_) {
        _manager = manager_;
        _swapRouter = swapRouter_;
        _key = key_;

        (, int24 tick,,) = manager_.getSlot0(key_.toId());
        minObservedTick = tick;
        maxObservedTick = tick;
    }

    /// @dev Swap in either direction with a bounded amount, tolerating swaps the pool rejects.
    function swapExactIn(uint256 amountSeed, bool zeroForOne) external {
        _observe();

        int256 amount = -int256(bound(amountSeed, 1e12, 5e16));

        try _swapRouter.swap(
            _key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amount,
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        ) {
            ++swapCount;
        } catch {}

        _observe();
    }

    /// @dev Advance the clock, which is the only thing that lets equilibrium move at all.
    function advanceTime(uint256 secondsSeed) external {
        uint256 delta = bound(secondsSeed, 1, 4 hours);

        vm.warp(block.timestamp + delta);
        vm.roll(block.number + 1 + delta / 12);

        ++timeAdvanceCount;
    }

    function _observe() private {
        (, int24 tick,,) = _manager.getSlot0(_key.toId());

        if (tick < minObservedTick) minObservedTick = tick;
        if (tick > maxObservedTick) maxObservedTick = tick;
    }

    // Exclude from the coverage report.
    function test() public {}
}
