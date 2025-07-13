const { ethers, run, network } = require("hardhat");

// This script deploys the OracleSwapFacility contract to the Arbitrum One network
// Run with: npx hardhat run script/deploySwapFacility.js --network arbitrumOne
async function main() {
  console.log("Deploying OracleSwapFacility contract...");

  // Oracle address
  const ORACLE_ADDRESS = "0x5cD66C034214A9958E55178A728452D4FA752Af7";
  console.log("Using Oracle at:", ORACLE_ADDRESS);

  // Deploy the contract with oracle address
  const OracleSwapFacility = await ethers.getContractFactory("OracleSwapFacility");
  const swapFacility = await OracleSwapFacility.deploy(ORACLE_ADDRESS);

  // Wait for deployment to complete
  await swapFacility.waitForDeployment();

  const contractAddress = await swapFacility.getAddress();
  console.log("OracleSwapFacility deployed to:", contractAddress);

  // Get deployment info
  const oracleAddress = await swapFacility.oracle();
  console.log("Connected to Oracle at:", oracleAddress);

  // Wait for a few block confirmations before verification
  console.log("Waiting for block confirmations...");
  await swapFacility.deploymentTransaction().wait(5);

  // Verify the contract on Etherscan/Arbiscan
  try {
    console.log("Verifying contract...");
    await run("verify:verify", {
      address: contractAddress,
      constructorArguments: [ORACLE_ADDRESS],
    });
    console.log("Contract verified successfully!");
  } catch (error) {
    if (error.message.toLowerCase().includes("already verified")) {
      console.log("Contract is already verified!");
    } else {
      console.error("Error verifying contract:", error.message);
    }
  }

  // Save deployment info
  console.log("\nDeployment completed successfully!");
  console.log("Contract address:", contractAddress);
  console.log("Network:", network.name);
  console.log("Oracle address:", oracleAddress);
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });