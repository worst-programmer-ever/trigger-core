// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Minimal Uniswap V3 factory, limited to pool lookup.
/// @dev This is the only way the manager discovers a pool. The caller passes two tokens and a fee
/// tier (500 for 0.05%, 3000 for 0.30%). The factory sorts the tokens and returns the canonical
/// pool, or address(0) when that market was never created.
interface IUniswapV3Factory {
    /// @notice Returns the pool for a pair and fee, or address(0) when none exists.
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address pool);
}
