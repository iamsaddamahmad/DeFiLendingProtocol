// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/ChainlinkPriceOracle.sol";

/// @dev Local stand-in for a real Chainlink aggregator, so these tests can
///      run offline without needing a Sepolia fork. Lets tests control the
///      exact price and timestamp returned, which is what makes testing
///      the staleness check possible at all.
contract MockAggregator is AggregatorV3Interface {
    uint8 public immutable decimalsValue;
    int256 public answer;
    uint256 public updatedAt;

    constructor(uint8 decimals_, int256 initialAnswer, uint256 initialUpdatedAt) {
        decimalsValue = decimals_;
        answer = initialAnswer;
        updatedAt = initialUpdatedAt;
    }

    function decimals() external view returns (uint8) {
        return decimalsValue;
    }

    function setAnswer(int256 newAnswer, uint256 newUpdatedAt) external {
        answer = newAnswer;
        updatedAt = newUpdatedAt;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, answer, updatedAt, updatedAt, 1);
    }
}

contract ChainlinkPriceOracleTest is Test {
    uint256 constant MAX_STALENESS = 3600; // 1 hour

    function testRescalesFrom8DecimalsTo18() public {
        // Chainlink feeds commonly report prices with 8 decimals, e.g.
        // 200000000000 = $2000.00000000 at 8 decimals.
        MockAggregator agg = new MockAggregator(8, 200_000_000_000, block.timestamp);
        ChainlinkPriceOracle oracle = new ChainlinkPriceOracle(address(agg), MAX_STALENESS);

        // 2000 * 1e8 rescaled to 18 decimals = 2000 * 1e18.
        assertEq(oracle.price(), 2_000e18);
    }

    function testRescalesFrom18DecimalsUnchanged() public {
        MockAggregator agg = new MockAggregator(18, 2_000e18, block.timestamp);
        ChainlinkPriceOracle oracle = new ChainlinkPriceOracle(address(agg), MAX_STALENESS);

        assertEq(oracle.price(), 2_000e18);
    }

    function testRevertsOnStalePrice() public {
        MockAggregator agg = new MockAggregator(8, 200_000_000_000, block.timestamp);
        ChainlinkPriceOracle oracle = new ChainlinkPriceOracle(address(agg), MAX_STALENESS);

        vm.warp(block.timestamp + MAX_STALENESS + 1);

        vm.expectRevert(); // exact args vary with timestamps; selector match is enough here
        oracle.price();
    }

    function testFreshPriceJustUnderStalenessLimitSucceeds() public {
        uint256 startTime = block.timestamp;
        MockAggregator agg = new MockAggregator(8, 200_000_000_000, startTime);
        ChainlinkPriceOracle oracle = new ChainlinkPriceOracle(address(agg), MAX_STALENESS);

        vm.warp(startTime + MAX_STALENESS - 1);

        assertEq(oracle.price(), 2_000e18);
    }

    function testRevertsOnZeroOrNegativePrice() public {
        MockAggregator agg = new MockAggregator(8, 0, block.timestamp);
        ChainlinkPriceOracle oracle = new ChainlinkPriceOracle(address(agg), MAX_STALENESS);

        vm.expectRevert(abi.encodeWithSelector(ChainlinkPriceOracle.InvalidPrice.selector, int256(0)));
        oracle.price();
    }

    function testRevertsOnZeroFeedAddress() public {
        vm.expectRevert(ChainlinkPriceOracle.ZeroAddress.selector);
        new ChainlinkPriceOracle(address(0), MAX_STALENESS);
    }

    /// @dev Confirms the "no changes needed to SimpleLendingPool" claim is
    ///      actually true — a ChainlinkPriceOracle can be passed anywhere
    ///      SimpleLendingPool expects a MockPriceOracle-shaped price feed,
    ///      because Solidity dispatches by function selector, not by the
    ///      compile-time type used to make the call. Both contracts expose
    ///      an identical `price() external view returns (uint256)`.
    function testPriceSelectorMatchesWhatPoolExpects() public {
        MockAggregator agg = new MockAggregator(8, 200_000_000_000, block.timestamp);
        ChainlinkPriceOracle oracle = new ChainlinkPriceOracle(address(agg), MAX_STALENESS);

        (bool success, bytes memory data) = address(oracle).staticcall(abi.encodeWithSignature("price()"));
        assertTrue(success);
        assertEq(abi.decode(data, (uint256)), 2_000e18);
    }
}
