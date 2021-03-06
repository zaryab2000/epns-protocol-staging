const fs = require("fs");
const chalk = require("chalk");
const { config, ethers } = require("hardhat");
const { versionVerifier, upgradeVersion } = require('../loaders/versionVerifier')

const { bn, tokens, bnToInt, timeInDays, timeInDate, readArgumentsFile, deployContract, verifyAllContracts } = require('../helpers/utils')

async function main() {
  // Version Check
  console.log(chalk.bgBlack.bold.green(`\nāļø  Running Version Checks \n-----------------------\n`))
  const versionDetails = versionVerifier(["epnsProxyAddress"])
  console.log(chalk.bgWhite.bold.black(`\n\t\t\t\n Version Control Passed \n\t\t\t\n`))

  // First deploy all contracts
  console.log(chalk.bgBlack.bold.green(`\nš” Deploying Contracts \n-----------------------\n`))
  const deployedContracts = await setupAllContracts(versionDetails)
  console.log(chalk.bgWhite.bold.black(`\n\t\t\t\n All Contracts Deployed \n\t\t\t\n`))

  // Try to verify
  console.log(chalk.bgBlack.bold.green(`\nš” Verifying Contracts \n-----------------------\n`))
  await verifyAllContracts(deployedContracts, versionDetails)
  console.log(chalk.bgWhite.bold.black(`\n\t\t\t\n All Contracts Verified \n\t\t\t\n`))

  // Upgrade Version
  console.log(chalk.bgBlack.bold.green(`\nš Upgrading Version   \n-----------------------\n`))
  upgradeVersion()
  console.log(chalk.bgWhite.bold.black(`\n\t\t\t\n ā Version upgraded    \n\t\t\t\n`))
}

async function setupAllContracts(versionDetails) {
  let deployedContracts = []
  console.log("š” Deploy \n");
  // auto deploy to read contract directory and deploy them all (add ".args" files for arguments)
  // await autoDeploy();
  // OR
  // custom deploy (to use deployed addresses dynamically for example:)
  const [adminSigner, aliceSigner, bobSigner, eventualAdmin] = await ethers.getSigners();

  const EPNSCoreV3 = await deployContract("EPNSCoreV3", [], "EPNSCoreV3");
  deployedContracts.push(EPNSCoreV3)

  const EPNSProxy = await ethers.getContractFactory("EPNSProxy")
  const epnsProxyInstance = EPNSProxy.attach(versionDetails.deploy.args.epnsProxyAddress)

  console.log(chalk.bgWhite.bold.black(`\n\t\t\t\n ā Upgrading Contract to`), chalk.magenta(`${EPNSCoreV3.address} \n\t\t\t\n`))
  await epnsProxyInstance.upgradeTo(EPNSCoreV3.address);
  console.log(chalk.bgWhite.bold.black(`\n\t\t\t\n ā Contracts Upgraded  \n\t\t\t\n`))

  return deployedContracts
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
