// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable2Step.sol";

/// @title MockPriceOracle
/// @notice A minimal, owner-settable price feed standing in for a real
///         oracle (e.g. Chainlink) for demonstration and testing purposes.
/// @dev DO NOT use this in any deployment holding real value. A single
///      owner-controlled price is a critical centralization and
///      manipulation risk — production lending protocols use decentralized
///      oracle networks (Chainlink Price Feeds, Pyth, etc.) specifically to
///      avoid any single party being able to move the price and trigger
///      unfair liquidations or under-collateralized borrowing.
contract MockPriceOracle is Ownable2Step {
    /// @notice Price of 1 unit of collateral, denominated in the borrow
    ///         token, scaled to 18 decimals (e.g. 2000e18 = 1 collateral
    ///         token is worth 2000 borrow tokens).
    uint256 public price;

    event PriceUpdated(uint256 oldPrice, uint256 newPrice);

    error ZeroPrice();

    constructor(uint256 initialPrice, address initialOwner) Ownable(initialOwner) {
        if (initialPrice == 0) revert ZeroPrice();
        price = initialPrice;
    }

    /// @notice Update the price. Only callable by the owner.
    /// @dev In production this function would not exist — price would come
    ///      from a decentralized oracle network instead of a single admin.
    function setPrice(uint256 newPrice) external onlyOwner {
        if (newPrice == 0) revert ZeroPrice();
        emit PriceUpdated(price, newPrice);
        price = newPrice;
    }
}
