// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

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

    /// @dev Prices an explicit curve against an explicit drift path, so the fee rule can be fuzzed
    /// over its whole domain without a storage write per run.
    function feeForParams(Params memory p, int256 beforeScaled, int256 afterScaled) external pure returns (uint24) {
        return _feeForPath(p, beforeScaled, afterScaled);
    }

    /// @dev Prices against the curve a pool would actually use.
    function feeFor(PoolKey calldata key, int256 beforeScaled, int256 afterScaled) external view returns (uint24) {
        return _feeForPath(_effectiveParams(key.toId()), beforeScaled, afterScaled);
    }

    // Exclude from the coverage report.
    function test() public {}
}
