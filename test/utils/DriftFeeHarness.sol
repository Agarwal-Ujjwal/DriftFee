// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {DriftFee} from "src/DriftFee.sol";

/**
 * @dev Exposes {DriftFee}'s fee curve and reference fold as external functions, so the invariants
 * that matter can be fuzzed over the whole input domain rather than only over states a sequence of
 * swaps happens to reach.
 */
contract DriftFeeHarness is DriftFee {
    constructor(IPoolManager _poolManager, address initialOwner, Params memory initialParams)
        DriftFee(_poolManager, initialOwner, initialParams)
    {}

    function fold(int256 referenceScaled, int24 currentTick, uint256 elapsed, uint32 window)
        external
        pure
        returns (int256)
    {
        return _fold(referenceScaled, currentTick, elapsed, window);
    }

    function feeFor(int256 referenceScaled, int24 currentTick, bool zeroForOne)
        external
        view
        returns (uint24 fee, int24 drift, bool movingAway)
    {
        return _feeFor(referenceScaled, currentTick, zeroForOne);
    }

    // Exclude from the coverage report.
    function test() public {}
}
