// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IPriceOracle
/// @notice The minimal interface SimpleLendingPool needs from any price
///         source. Both MockPriceOracle (for testing/demos) and
///         ChainlinkPriceOracle (for real deployments) implement this,
///         so the pool can be pointed at either without any changes to
///         its own code — only the address passed to its constructor
///         changes.
interface IPriceOracle {
    /// @notice Price of 1 unit of collateral, denominated in the borrow
    ///         token, scaled to 18 decimals.
    function price() external view returns (uint256);
}
