// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Minimal Uniswap V3 pool, limited to the reads a limit order needs.
/// @dev The manager never swaps. It only asks the pool where the price is, how its ticks are spaced,
/// and which token is token0. Fills happen by closing the position, not by trading against the pool.
interface IUniswapV3Pool {
    /// @notice Returns the current price, tick, and oracle/protocol state.
    /// @dev `tick` is the only field the manager uses. It is the greatest tick whose price is still
    /// at or below the current price. The other fields are part of the deployed function's return
    /// data and have to be declared so the tuple decodes.
    function slot0()
        external
        view
        returns (
            uint160 sqrtPriceX96,
            int24 tick,
            uint16 observationIndex,
            uint16 observationCardinality,
            uint16 observationCardinalityNext,
            uint8 feeProtocol,
            bool unlocked
        );

    /// @notice Returns the pool's tick spacing.
    function tickSpacing() external view returns (int24);

    /// @notice Returns the numerically lower token address.
    function token0() external view returns (address);

    /// @notice Returns the numerically higher token address.
    function token1() external view returns (address);
}
