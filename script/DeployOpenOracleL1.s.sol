// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {OpenOracle} from "../src/OpenOracleL1.sol";

/**
 * @title DeployOpenOracleL1
 * @notice Deployment script for OpenOracleL1 contract with automatic verification
 * @dev Run with: forge script script/DeployOpenOracleL1.s.sol --broadcast --private-key <YOUR_PRIVATE_KEY> --verify
 * @dev Note: For Etherscan verification $ETHERSCAN_API_KEY must be set in the environment variables
 */
contract DeployOpenOracleL1 is Script {
    function run() external returns (OpenOracle oracle) {
        // Start broadcasting transactions
        vm.startBroadcast();

        // Deploy the OpenOracle contract
        oracle = new OpenOracle();

        // Stop broadcasting
        vm.stopBroadcast();

        // Log deployment information
        console.log("OpenOracle deployed at:", address(oracle));
        console.log("Protocol fee recipient:", oracle.protocolFeeRecipient());
        console.log("Owner:", oracle.owner());
        
        return oracle;
    }
}