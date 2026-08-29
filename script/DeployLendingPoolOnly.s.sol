// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/SimpleLendingPool.sol";

/// @notice Deploys only SimpleLendingPool, pointing at an oracle that
///         already exists (set ORACLE_ADDRESS in .env).
contract DeployLendingPoolOnly is Script {
    function run() external returns (SimpleLendingPool) {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address collateralToken = vm.envAddress("COLLATERAL_TOKEN_ADDRESS");
        address borrowToken = vm.envAddress("BORROW_TOKEN_ADDRESS");
        address oracle = vm.envAddress("ORACLE_ADDRESS");
        uint256 ltvBps = vm.envUint("LOAN_TO_VALUE_BPS");
        uint256 liqThresholdBps = vm.envUint("LIQUIDATION_THRESHOLD_BPS");
        uint256 liqBonusBps = vm.envUint("LIQUIDATION_BONUS_BPS");
        uint256 interestRateBps = vm.envUint("ANNUAL_INTEREST_RATE_BPS");
        uint256 closeFactorBps = vm.envUint("MAX_LIQUIDATION_CLOSE_FACTOR_BPS");
        address owner = vm.envAddress("TOKEN_OWNER");

        vm.startBroadcast(deployerPrivateKey);

        SimpleLendingPool pool = new SimpleLendingPool(
            collateralToken,
            borrowToken,
            oracle,
            ltvBps,
            liqThresholdBps,
            liqBonusBps,
            interestRateBps,
            closeFactorBps,
            owner
        );
        console.log("Lending pool deployed to:", address(pool));

        vm.stopBroadcast();
        return pool;
    }
}
