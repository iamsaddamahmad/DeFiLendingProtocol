// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "./IPriceOracle.sol";

/// @title MockPriceOracle
/// @notice A minimal, owner-settable price feed standing in for a real
///         oracle (e.g. Chainlink) for demonstration and testing purposes.
/// @dev DO NOT use this in any deployment holding real value. A single
///      owner-controlled price is a critical centralization and
///      manipulation risk — see ChainlinkPriceOracle.sol for the
///      production-appropriate alternative, used wherever a real feed
///      exists for the asset pair in question.
contract MockPriceOracle is IPriceOracle, Ownable2Step {
    uint256 public price_;

    event PriceUpdated(uint256 oldPrice, uint256 newPrice);

    error ZeroPrice();

    constructor(uint256 initialPrice, address initialOwner) Ownable(initialOwner) {
        if (initialPrice == 0) revert ZeroPrice();
        price_ = initialPrice;
    }

    /// @notice Update the price. Only callable by the owner.
    /// @dev In production this function would not exist — price would come
    ///      from a decentralized oracle network instead of a single admin.
    function setPrice(uint256 newPrice) external onlyOwner {
        if (newPrice == 0) revert ZeroPrice();
        emit PriceUpdated(price_, newPrice);
        price_ = newPrice;
    }

    /// @inheritdoc IPriceOracle
    function price() external view returns (uint256) {
        return price_;
    }
}
