// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Minimal interface for a Chainlink price feed aggregator —
///         just the two functions this contract actually needs, rather
///         than pulling in the full Chainlink contracts package (npm:
///         chainlink slash contracts) as a dependency for two function
///         signatures.
interface AggregatorV3Interface {
    function decimals() external view returns (uint8);
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

/// @title ChainlinkPriceOracle
/// @notice Adapts a real Chainlink price feed to the same `price()`
///         interface `SimpleLendingPool` already expects from
///         `MockPriceOracle` — the pool contract itself needs no changes
///         to use this instead; only the oracle address passed to its
///         constructor changes.
/// @dev This is what a real deployment should use instead of
///      MockPriceOracle. Key differences from the mock:
///        - Price comes from Chainlink's decentralized oracle network,
///          not a single owner-controlled value
///        - Staleness is checked: if the feed hasn't updated within
///          `maxStaleness`, reads revert rather than silently returning
///          an old price
///        - The price is rescaled from the feed's native decimals
///          (commonly 8) to the 18-decimal format SimpleLendingPool expects
///      Chainlink feeds report one asset's price in a specific quote
///      currency (e.g. ETH/USD) — this oracle reports the *collateral
///      token's* price under the assumption that the collateral token
///      tracks that reference asset closely (e.g. a wrapped-ETH
///      collateral token paired with an ETH/USD feed). It does NOT
///      verify that assumption on-chain; that mapping is a deployment-time
///      decision, documented in the deploy script and README.
contract ChainlinkPriceOracle {
    AggregatorV3Interface public immutable feed;
    uint8 public immutable feedDecimals;

    /// @notice Maximum age, in seconds, a price is considered valid.
    ///         Chainlink feeds update on a "heartbeat" (commonly 1 hour for
    ///         many mainnet feeds, longer on some testnets) — this should
    ///         be set comfortably above that heartbeat, not equal to it.
    uint256 public immutable maxStaleness;

    error StalePrice(uint256 updatedAt, uint256 nowTimestamp, uint256 maxStaleness);
    error InvalidPrice(int256 answer);
    error ZeroAddress();

    constructor(address feed_, uint256 maxStaleness_) {
        if (feed_ == address(0)) revert ZeroAddress();
        feed = AggregatorV3Interface(feed_);
        feedDecimals = feed.decimals();
        maxStaleness = maxStaleness_;
    }

    /// @notice Current price, rescaled to 18 decimals, matching the format
    ///         `SimpleLendingPool` expects from `MockPriceOracle.price()`.
    /// @dev Reverts if the feed's last update is older than `maxStaleness`,
    ///      or if the feed reports a non-positive price (both are real
    ///      failure modes production systems must handle, not edge cases
    ///      to ignore).
    function price() external view returns (uint256) {
        (, int256 answer,, uint256 updatedAt,) = feed.latestRoundData();

        if (answer <= 0) revert InvalidPrice(answer);

        // A few seconds of validator-manipulable timestamp drift is immaterial
        // against a staleness window measured in minutes/hours.
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp - updatedAt > maxStaleness) {
            revert StalePrice(updatedAt, block.timestamp, maxStaleness);
        }

        // Safe: answer > 0 is enforced by the InvalidPrice check above.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 rawPrice = uint256(answer);

        if (feedDecimals < 18) {
            return rawPrice * (10 ** (18 - feedDecimals));
        } else if (feedDecimals > 18) {
            return rawPrice / (10 ** (feedDecimals - 18));
        }
        return rawPrice;
    }
}
