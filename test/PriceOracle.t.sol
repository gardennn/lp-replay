// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {PriceOracle} from "../src/PriceOracle.sol";

/// @dev Fork test: block 19_500_000 was mined 2024-03-28 (~mid-day UTC). Per CoinGecko,
///      ETH/USD closed around $3550 that day.
///      https://www.coingecko.com/en/coins/ethereum/historical_data?start=2024-03-28&end=2024-03-28
contract PriceOracleForkTest is Test {
    uint256 constant FORK_BLOCK = 19_500_000;
    uint256 constant EXPECTED_ETH_USD_1E18 = 3550e18;
    uint256 constant TOLERANCE_BPS = 500; // ±5%

    PriceOracle oracle;

    function setUp() public {
        vm.createSelectFork(vm.rpcUrl("mainnet"), FORK_BLOCK);
        oracle = new PriceOracle();
    }

    function test_getEthUsd_matchesHistorical() public view {
        uint256 price = oracle.getEthUsd();
        _assertWithinBps(price, EXPECTED_ETH_USD_1E18, TOLERANCE_BPS);
    }

    function test_getEthUsdAtBlock_matchesHistorical() public view {
        uint256 price = oracle.getEthUsdAtBlock(FORK_BLOCK);
        _assertWithinBps(price, EXPECTED_ETH_USD_1E18, TOLERANCE_BPS);
    }

    function test_getEthUsdAtBlock_revertsOnMismatch() public {
        vm.expectRevert("PriceOracle: fork not at expected block");
        oracle.getEthUsdAtBlock(FORK_BLOCK + 1);
    }

    function _assertWithinBps(uint256 actual, uint256 expected, uint256 toleranceBps) private pure {
        uint256 diff = actual > expected ? actual - expected : expected - actual;
        uint256 maxDiff = (expected * toleranceBps) / 10_000;
        require(diff <= maxDiff, "price outside tolerance");
    }
}
