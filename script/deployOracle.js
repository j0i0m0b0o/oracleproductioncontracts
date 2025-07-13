const { ethers, run, network } = require("hardhat");

// This script deploys the OpenOracle contract to the Arbitrum One network
// Run with: npx hardhat run script/deployOracle.js --network arbitrumOne
async function main() {
  console.log("Deploying OpenOracle contract...");

  // Deploy the contract
  const OpenOracle = await ethers.getContractFactory("OpenOracle");
  const oracle = await OpenOracle.deploy();

  // Wait for deployment to complete
  await oracle.waitForDeployment();

  const contractAddress = await oracle.getAddress();
  console.log("OpenOracle deployed to:", contractAddress);

  // Get deployment info
  const protocolFeeRecipient = await oracle.protocolFeeRecipient();
  const owner = await oracle.owner();

  console.log("Protocol fee recipient:", protocolFeeRecipient);
  console.log("Owner:", owner);

  // Wait for a few block confirmations before verification
  console.log("Waiting for block confirmations...");
  await oracle.deploymentTransaction().wait(5);

  // Verify the contract on Etherscan/Arbiscan
  try {
    console.log("Verifying contract...");
    await run("verify:verify", {
      address: contractAddress,
      constructorArguments: [],
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
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });