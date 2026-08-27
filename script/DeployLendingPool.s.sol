// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/SimpleLendingPool.sol";
import "../src/MockPriceOracle.sol";

/// @notice Deploys MockPriceOracle and SimpleLendingPool together.
/// @dev Reads all parameters from environment variables, same pattern as
///      DeployMyToken.s.sol, so it works identically across every network
///      defined in foundry.toml — just change --rpc-url.
contract DeployLendingPool is Script {
    function run() external returns (MockPriceOracle, SimpleLendingPool) {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address collateralToken = vm.envAddress("COLLATERAL_TOKEN_ADDRESS");
        address borrowToken = vm.envAddress("BORROW_TOKEN_ADDRESS");
        uint256 initialPrice = vm.envUint("ORACLE_INITIAL_PRICE");
        uint256 ltvBps = vm.envUint("LOAN_TO_VALUE_BPS");
        uint256 liqThresholdBps = vm.envUint("LIQUIDATION_THRESHOLD_BPS");
        uint256 liqBonusBps = vm.envUint("LIQUIDATION_BONUS_BPS");
        address owner = vm.envAddress("TOKEN_OWNER");

        vm.startBroadcast(deployerPrivateKey);

        MockPriceOracle oracle = new MockPriceOracle(initialPrice, owner);
        console.log("Oracle deployed to:", address(oracle));

        SimpleLendingPool pool = new SimpleLendingPool(
            collateralToken,
            borrowToken,
            address(oracle),
            ltvBps,
            liqThresholdBps,
            liqBonusBps,
            owner
        );
        console.log("Lending pool deployed to:", address(pool));
        console.log("Chain ID:", block.chainid);

        vm.stopBroadcast();

        return (oracle, pool);
    }
}
