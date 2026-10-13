// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Minimal Uniswap V3 position manager, limited to minting and closing a position.
/// @dev The official v3-periphery package targets Solidity 0.7 and cannot be imported here.
/// These signatures match the deployed Base position manager. A position is an NFT: this
/// contract mints it to itself, and only the NFT owner can later decrease, collect, and burn it.
interface INonfungiblePositionManager {
    struct MintParams {
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        address recipient;
        uint256 deadline;
    }

    struct DecreaseLiquidityParams {
        uint256 tokenId;
        uint128 liquidity;
        uint256 amount0Min;
        uint256 amount1Min;
        uint256 deadline;
    }

    struct CollectParams {
        uint256 tokenId;
        address recipient;
        uint128 amount0Max;
        uint128 amount1Max;
    }

    /// @notice Mints a position NFT to `recipient` and pulls the tokens it needs.
    function mint(MintParams calldata params)
        external
        payable
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);

    /// @notice Burns liquidity and reports the principal owed, excluding fees.
    /// @dev Fees keep accruing inside the position. collect is what actually sends tokens out,
    /// and it sends principal and fees together. Subtracting these two return values isolates the fee.
    function decreaseLiquidity(DecreaseLiquidityParams calldata params)
        external
        payable
        returns (uint256 amount0, uint256 amount1);

    /// @notice Sends owed principal and fees to `recipient`.
    function collect(CollectParams calldata params) external payable returns (uint256 amount0, uint256 amount1);

    /// @notice Burns a position that has no liquidity and no tokens owed.
    function burn(uint256 tokenId) external payable;

    /// @notice Returns the position behind `tokenId`, including its current liquidity.
    function positions(uint256 tokenId)
        external
        view
        returns (
            uint96 nonce,
            address operator,
            address token0,
            address token1,
            uint24 fee,
            int24 tickLower,
            int24 tickUpper,
            uint128 liquidity,
            uint256 feeGrowthInside0LastX128,
            uint256 feeGrowthInside1LastX128,
            uint128 tokensOwed0,
            uint128 tokensOwed1
        );
}
