const fs = require("fs");
const chalk = require("chalk");
const { config, ethers } = require("hardhat");
const { versionVerifier, upgradeVersion } = require('../loaders/versionVerifier')

const { bn, tokens, bnToInt, timeInDays, timeInDate, readArgumentsFile, deployContract, verifyAllContracts } = require('../helpers/utils')

async function main() {
  // Version Check
  console.log(chalk.bgBlack.bold.green(`\nāļø  Running Version Checks \n-----------------------\n`))
  const versionDetails = versionVerifier(["mock"])
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

async function setupAllContracts() {
  let deployedContracts = []
  console.log("š” Deploy \n");
  // auto deploy to read contract directory and deploy them all (add ".args" files for arguments)
  // await autoDeploy();
  // OR
  // custom deploy (to use deployed addresses dynamically for example:)
  const [adminSigner, aliceSigner, bobSigner, eventualAdmin] = await ethers.getSigners();

  // const admin = '0xA1bFBd2062f298a46f3E4160C89BEDa0716a3F51'; //admin of timelock, gets handed over to the governor.
  const AAVE_LENDING_POOL = "0x1c8756FD2B28e9426CDBDcC7E3c4d64fa9A54728";
  const DAI = "0xf80A32A835F79D7787E8a8ee5721D0fEaFd78108";
  const ADAI = "0xcB1Fe6F440c49E9290c3eb7f158534c2dC374201";
  const referralCode = 0;
  const delay = 0; // uint for the timelock delay

  // const epns = await deploy("EPNS");
  const epns = await deployContract("EPNS", [], "EPNS");
  deployedContracts.push(epns)

  const EPNSCoreV1 = await deployContract("EPNSCoreV1", [], "EPNSCoreV1");
  deployedContracts.push(EPNSCoreV1)

  // const timelock = await deployContract("Timelock", [adminSigner.address, delay], "Timelock"); // governor and a guardian,
  // deployedContracts.push(timelock)

  // const governorAlpha = await deployContract("GovernorAlpha", [
  //   timelock.address,
  //   epns.address,
  //   adminSigner.address
  // ]
  // , "GovernorAlpha");
  // deployedContracts.push(governorAlpha)

  // const currBlock = await ethers.provider.getBlock('latest');
  
  // const eta = currBlock.timestamp;
  // const coder = new ethers.utils.AbiCoder();

  // let data = coder.encode(['address'], [governorAlpha.address]);

  // await timelock.functions.queueTransaction(timelock.address, '0', 'setPendingAdmin(address)', data, (eta + 1));
  // await ethers.provider.send('evm_mine');
  // await ethers.provider.send('evm_mine');
  // await timelock.functions.executeTransaction(timelock.address, '0', 'setPendingAdmin(address)', data, (eta + 1));

  const EPNSProxy = await deployContract("EPNSProxy", [
    EPNSCoreV1.address,
    adminSigner.address,
    AAVE_LENDING_POOL,
    DAI,
    ADAI,
    referralCode,
  ], "EPNSProxy");

  deployedContracts.push(EPNSProxy)

  return deployedContracts
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
