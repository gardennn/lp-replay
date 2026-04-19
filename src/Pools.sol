// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Hardcoded Uniswap V3 pool and token addresses on Ethereum mainnet.
/// @dev Pool names follow the convention `<TOKEN0>_<TOKEN1>_<FEE_BPS>`, where fee is in
///      hundredths of a bip (100 = 0.01%, 500 = 0.05%, 3000 = 0.30%, 10000 = 1.00%).
///      Token ordering matches the pool's actual `token0`/`token1` on-chain (sorted by address).
library Pools {
    // ---------- Tokens ----------

    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address internal constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;

    // ---------- Pools ----------

    /// @dev USDC/WETH 0.05% — most liquid ETH pool on mainnet. token0 = USDC, token1 = WETH.
    address internal constant ETH_USDC_005 = 0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640;

    /// @dev USDC/WETH 0.30%. token0 = USDC, token1 = WETH.
    address internal constant ETH_USDC_030 = 0x8ad599c3A0ff1De082011EFDDc58f1908eb6e6D8;

    /// @dev WBTC/WETH 0.30%. token0 = WBTC, token1 = WETH.
    address internal constant WBTC_ETH_030 = 0xCBCdF9626bC03E24f779434178A73a0B4bad62eD;

    /// @dev USDC/USDT 0.01%. token0 = USDC, token1 = USDT.
    address internal constant USDC_USDT_001 = 0x3416cF6C708Da44DB2624D63ea0AAef7113527C6;
}
