const { ethers } = require("hardhat");
const { use, expect } = require("chai");
const { solidity } = require("ethereum-waffle");
const {
  advanceBlockTo,
  latestBlock,
  advanceBlock,
  increase,
  increaseTo,
  latest,
} = require("../time");
const { calcChannelFairShare, calcSubscriberFairShare, getPubKey, bn, tokens, tokensBN, bnToInt, ChannelAction, readjustFairShareOfChannels, SubscriberAction, readjustFairShareOfSubscribers } = require("../../helpers/utils");

use(solidity);

describe("EPNSStagingV4 tests", function () {
  const AAVE_LENDING_POOL = "0x1c8756FD2B28e9426CDBDcC7E3c4d64fa9A54728";
  const DAI = "0xf80A32A835F79D7787E8a8ee5721D0fEaFd78108";
  const ADAI = "0xcB1Fe6F440c49E9290c3eb7f158534c2dC374201";
  const referralCode = 0;
  const ADD_CHANNEL_MIN_POOL_CONTRIBUTION = tokensBN(50)
  const ADD_CHANNEL_MAX_POOL_CONTRIBUTION = tokensBN(250000 * 50)
  const DELEGATED_CONTRACT_FEES = ethers.utils.parseEther("0.1");
  const ADJUST_FOR_FLOAT = bn(10 ** 7)
  const delay = 0; // uint for the timelock delay

  const forkAddress = {
    address: "0xe2a6cf5f463df94147a0f0a302c879eb349cb2cd",
  };

  let EPNS;
  let GOVERNOR;
  let PROXYADMIN;
  let LOGIC;
  let LOGICV2;
  let LOGICV3;
  let EPNSProxy;
  let EPNSCoreV1Proxy;
  let TIMELOCK;
  let ADMIN;
  let MOCKDAI;
  let ADAICONTRACT;
  let ALICE;
  let BOB;
  let CHARLIE;
  let CHANNEL_CREATOR;
  let ADMINSIGNER;
  let ALICESIGNER;
  let BOBSIGNER;
  let CHARLIESIGNER;
  let CHANNEL_CREATORSIGNER;
  const ADMIN_OVERRIDE = "";

  const coder = new ethers.utils.AbiCoder();
  // `beforeEach` will run before each test, re-deploying the contract every
  // time. It receives a callback, which can be async.

  before(async function (){
    const MOCKDAITOKEN = await ethers.getContractFactory("MockDAI");
    MOCKDAI = MOCKDAITOKEN.attach(DAI);

    const ADAITOKENS = await ethers.getContractFactory("MockDAI");
    ADAICONTRACT = ADAITOKENS.attach(ADAI);
  });

  beforeEach(async function () {
    // Get the ContractFactory and Signers here.
    const [
      adminSigner,
      aliceSigner,
      bobSigner,
      charlieSigner,
      channelCreatorSigner,
    ] = await ethers.getSigners();

    ADMINSIGNER = adminSigner;
    ALICESIGNER = aliceSigner;
    BOBSIGNER = bobSigner;
    CHARLIESIGNER = charlieSigner;
    CHANNEL_CREATORSIGNER = channelCreatorSigner;

    ADMIN = await adminSigner.getAddress();
    ALICE = await aliceSigner.getAddress();
    BOB = await bobSigner.getAddress();
    CHARLIE = await charlieSigner.getAddress();
    CHANNEL_CREATOR = await channelCreatorSigner.getAddress();

    const EPNSTOKEN = await ethers.getContractFactory("EPNS");
    EPNS = await EPNSTOKEN.deploy(ADMIN);

    const EPNSStagingV4 = await ethers.getContractFactory("EPNSStagingV4");
    LOGIC = await EPNSStagingV4.deploy();

    const TimeLock = await ethers.getContractFactory("Timelock");
    TIMELOCK = await TimeLock.deploy(ADMIN, delay);

    const proxyAdmin = await ethers.getContractFactory("EPNSAdmin");
    PROXYADMIN = await proxyAdmin.deploy();
    await PROXYADMIN.transferOwnership(TIMELOCK.address);

    const EPNSPROXYContract = await ethers.getContractFactory("EPNSProxy");
    EPNSProxy = await EPNSPROXYContract.deploy(
      LOGIC.address,
      ADMINSIGNER.address,
      AAVE_LENDING_POOL,
      DAI,
      ADAI,
      referralCode
    );

    await EPNSProxy.changeAdmin(ALICESIGNER.address);
    EPNSCoreV1Proxy = EPNSStagingV4.attach(EPNSProxy.address)
  });

  afterEach(function () {
    EPNS = null
    LOGIC = null
    TIMELOCK = null
    EPNSProxy = null
    EPNSCoreV1Proxy = null
  });


  /***
   * CHECKPOINTS FOR sendNotificationAsDelegateOrOwnerOrRecipient Function
   * Channel Must be Valid and Caller Must be Channel Owner
   * Channel Owner can send notif to any address including him/her self
   * Or, Delegate Should be valid and Caller should be delegate
   * Or, Recipient Can be the Caller Him/Herself
   * If Recipient(or any Random Address) is the Caller of this Function, he/she must send notif to Him/Her self.
   * 
   */
  // describe("Testing send Notification related functions", function(){
  //   describe("Testing sendNotificationAsDelegateOrOwnerOrRecipient", function(){
  //        beforeEach(async function(){
  //       const CHANNEL_TYPE = 2;
  //       const testChannel = ethers.utils.toUtf8Bytes("test-channel-hello-world");

  //       //await EPNSCoreV1Proxy.connect(ADMINSIGNER).addToChannelizationWhitelist(CHANNEL_CREATOR, {gasLimit: 500000});

  //       await MOCKDAI.connect(CHANNEL_CREATORSIGNER).mint(ADD_CHANNEL_MIN_POOL_CONTRIBUTION);
  //       await MOCKDAI.connect(CHANNEL_CREATORSIGNER).approve(EPNSCoreV1Proxy.address, ADD_CHANNEL_MIN_POOL_CONTRIBUTION);
  //       await EPNSCoreV1Proxy.connect(CHANNEL_CREATORSIGNER).createChannelWithFees(CHANNEL_TYPE, testChannel,ADD_CHANNEL_MIN_POOL_CONTRIBUTION);
  //     });

  //     it("Should Revert is Caller is Random Address But The Recipient is NOT The Caller itself", async function(){
  //       const msg = ethers.utils.toUtf8Bytes("This is notification message");
  //       const tx = EPNSCoreV1Proxy.connect(CHARLIESIGNER).sendNotificationAsDelegateOrOwnerOrRecipient(CHARLIE, BOB, ALICE, msg);
  //       await expect(tx).to.be.revertedWith("SendNotif Error: Invalid Channel, Delegate or Subscriber");
  //     });

  //     it("Should Pass if Caller is Random Address but Recipient is also the Same Address", async function(){
  //       const msg = ethers.utils.toUtf8Bytes("This is notification message");
  //       const tx = EPNSCoreV1Proxy.connect(CHARLIESIGNER).sendNotificationAsDelegateOrOwnerOrRecipient(CHANNEL_CREATOR, ALICE, CHARLIE, msg);

  //       await expect(tx)
  //         .to.emit(EPNSCoreV1Proxy, 'SendNotification')
  //         .withArgs(CHANNEL_CREATOR, CHARLIE, ethers.utils.hexlify(msg));
  //     });

  //     it("Channel Owner should be able to emit Notif to any address", async function(){
  //       const msg = ethers.utils.toUtf8Bytes("This is notification message");
  //       const tx = EPNSCoreV1Proxy.connect(CHANNEL_CREATORSIGNER).sendNotificationAsDelegateOrOwnerOrRecipient(CHANNEL_CREATOR, ALICE, BOB, msg);

  //       await expect(tx)
  //         .to.emit(EPNSCoreV1Proxy, 'SendNotification')
  //         .withArgs(CHANNEL_CREATOR, BOB, ethers.utils.hexlify(msg));
  //     });


  //     it("Channel Owner should be able to emit Notif to His/Her own address", async function(){
  //       const msg = ethers.utils.toUtf8Bytes("This is notification message");
  //       const tx = EPNSCoreV1Proxy.connect(CHANNEL_CREATORSIGNER).sendNotificationAsDelegateOrOwnerOrRecipient(CHANNEL_CREATOR, ALICE, CHANNEL_CREATOR, msg);

  //       await expect(tx)
  //         .to.emit(EPNSCoreV1Proxy, 'SendNotification')
  //         .withArgs(CHANNEL_CREATOR, CHANNEL_CREATOR, ethers.utils.hexlify(msg));
  //     });

  //      it("Invalid Delegate Addresses should not be able to Send Notif", async function(){
  //       const msg = ethers.utils.toUtf8Bytes("This is DELAGATED notification message");
  //       const tx =  EPNSCoreV1Proxy.connect(BOBSIGNER).sendNotificationAsDelegateOrOwnerOrRecipient(CHANNEL_CREATOR, BOB, ALICE, msg);
  //       await expect(tx).to.be.revertedWith("SendNotif Error: Invalid Channel, Delegate or Subscriber");
  //     });

  //     it("Valid Delegatee's Address must match with the Caller Delegatee of the Function", async function(){
  //       const msg = ethers.utils.toUtf8Bytes("This is DELAGATED notification message");

  //         // Adding BOB As Delate Notification Seder
  //       const tx_addDelegate =  await EPNSCoreV1Proxy.connect(CHANNEL_CREATORSIGNER).addDelegate(BOB);
  //       const isBobAllowed = await EPNSCoreV1Proxy.connect(CHANNEL_CREATORSIGNER).delegated_NotificationSenders(CHANNEL_CREATOR,BOB);

  //       const tx =  EPNSCoreV1Proxy.connect(CHARLIESIGNER).sendNotificationAsDelegateOrOwnerOrRecipient(CHANNEL_CREATOR, BOB, ALICE, msg);
  //       await expect(tx).to.be.revertedWith("SendNotif Error: Invalid Channel, Delegate or Subscriber");
  //     });


  //     it("BOB Should be able to Send Delegated Notification once Approved as Delegatee", async function(){
  //       // Adding BOB As Delate Notification Seder
  //       const tx_addDelegate =  await EPNSCoreV1Proxy.connect(CHANNEL_CREATORSIGNER).addDelegate(BOB);
  //       const isBobAllowed = await EPNSCoreV1Proxy.connect(CHANNEL_CREATORSIGNER).delegated_NotificationSenders(CHANNEL_CREATOR,BOB);

  //       // BOB Sending Delegated Notification
  //       const msg = ethers.utils.toUtf8Bytes("This is DELAGATED notification message");
  //       const tx_sendNotif =  await EPNSCoreV1Proxy.connect(BOBSIGNER).sendNotificationAsDelegateOrOwnerOrRecipient(CHANNEL_CREATOR, BOB, ALICE, msg);

  //       await expect(tx_sendNotif)
  //         .to.emit(EPNSCoreV1Proxy, 'SendNotification')
  //         .withArgs(CHANNEL_CREATOR, ALICE, ethers.utils.hexlify(msg));
  //       await expect(isBobAllowed).to.be.equal(true);
  //       await expect(tx_addDelegate)
  //         .to.emit(EPNSCoreV1Proxy, 'AddDelegate')
  //         .withArgs(CHANNEL_CREATOR, BOB);
  //     })


  //      it("BOB Should NOT be able to Send Delegated Notification once Permission is Revoked", async function(){
  //       // Revoking Permission from BOB
  //       const tx_removeDelegate =  EPNSCoreV1Proxy.connect(CHANNEL_CREATORSIGNER).removeDelegate(BOB);
  //       const isBobAllowed = await EPNSCoreV1Proxy.connect(CHANNEL_CREATORSIGNER).delegated_NotificationSenders(CHANNEL_CREATOR,BOB);

  //       // BOB Sending Delegated Notification
  //        const msg = ethers.utils.toUtf8Bytes("This is DELAGATED notification message");
  //       const tx_sendNotif =  EPNSCoreV1Proxy.connect(BOBSIGNER).sendNotificationAsDelegateOrOwnerOrRecipient(CHANNEL_CREATOR, BOB, ALICE, msg);


  //       await expect(tx_sendNotif).to.be.revertedWith("SendNotif Error: Invalid Channel, Delegate or Subscriber");
  //       await expect(isBobAllowed).to.be.equal(false);
  //         await expect(tx_removeDelegate)
  //         .to.emit(EPNSCoreV1Proxy, 'RemoveDelegate')
  //         .withArgs(CHANNEL_CREATOR, BOB);
  //     })

  //   });

  /***
   * CHECKPOINTS FOR sendNotifBySig Function
   * Signature should be valid
   * Nonce should be valid
   * Transaction shouldn't expire
   * Channel Must be Valid and Caller Must be Channel Owner
   * Channel Owner can send notif to any address including him/her self
   * Or, Delegate Should be valid and Caller should be delegate
   * Or, Recipient Can be the Caller Him/Herself
   * If Recipient(or any Random Address) is the Caller of this Function, he/she must send notif to Him/Her self.
   * 
   */
    describe('Testing Subscribe with Meta Transaction function', function () {
    let contractName
    let spender
    let transmitter
    let channelAddress
    let nonce
    let deadline

    let domain
    let types
    let val

    beforeEach(async function () {
      contractName = await EPNSCoreV1Proxy.name();
      const { chainId } = await ethers.provider.getNetwork()

      USER = BOBSIGNER
      TRANSMITTER = CHARLIESIGNER
      nonce = await EPNSCoreV1Proxy.nonces(CHANNEL_CREATOR)
      deadline = ethers.constants.MaxUint256


      domain = {
        name: contractName,
        chainId: chainId,
        verifyingContract: EPNSCoreV1Proxy.address.toString()
      }

      types = {
        SendNotification: [
          {name: "channel", type: "address"},
          {name: "delegate", type: "address"},
          {name: "recipient", type: "address"},
          {name: "identity", type: "bytes"},
          {name: "nonce", type: "uint256"},
          {name: "expiry", type: "uint256"},
        ]
      }

      val = {
        'channel': CHANNEL_CREATOR.toString(),
        'delegate': BOB.toString(),
        'recipient': ALICE.toString(),
        'identity' : '0x6162636400000000000000000000000000000000000000000000000000000000',
        'nonce': nonce.toString(),
        'expiry': deadline.toString()
      }

        const CHANNEL_TYPE = 2;
        const testChannel = ethers.utils.toUtf8Bytes("test-channel-hello-world");

        await MOCKDAI.connect(CHANNEL_CREATORSIGNER).mint(ADD_CHANNEL_MIN_POOL_CONTRIBUTION);
        await MOCKDAI.connect(CHANNEL_CREATORSIGNER).approve(EPNSCoreV1Proxy.address, ADD_CHANNEL_MIN_POOL_CONTRIBUTION);
        await EPNSCoreV1Proxy.connect(CHANNEL_CREATORSIGNER).createChannelWithFees(CHANNEL_TYPE, testChannel, ADD_CHANNEL_MIN_POOL_CONTRIBUTION);

        await MOCKDAI.connect(CHANNEL_CREATORSIGNER).mint(DELEGATED_CONTRACT_FEES);
        await MOCKDAI.connect(CHANNEL_CREATORSIGNER).approve(EPNSCoreV1Proxy.address, DELEGATED_CONTRACT_FEES);

    })
    
      it('Checking Signatory', async function () {
      const msgData = '0x6162636400000000000000000000000000000000000000000000000000000000'
      const signer = CHANNEL_CREATORSIGNER 
      const signature = await signer._signTypedData(domain, types, val)
      let sig = ethers.utils.splitSignature(signature)

      const tx = await EPNSCoreV1Proxy.connect(TRANSMITTER).sendNotifBySig(CHANNEL_CREATOR, BOB, ALICE, msgData, nonce, deadline, sig.v, sig.r, sig.s)
     
      const check = await EPNSCoreV1Proxy.check()
      
      // For SOME Reason the Signator Address doesn't match the Actual Address of the Channel Creator. This leads to unwanted errors
      console.log(`Signatory Address of Channel Owner- ${check}`)
      console.log(`Actual Address of Channel Owner- ${CHANNEL_CREATOR}`) 

      // await expect(EPNSCoreV1Proxy.connect(TRANSMITTER).sendNotifBySig(CHANNEL_CREATOR, BOB, ALICE, msgData, nonce, deadline, sig.v, sig.r, sig.s))
      //   .to.be.revertedWith("Invalid signature")
    })
    // it('Function should revert on Unauthorized request', async function () {
    //   const signer = CHANNEL_CREATORSIGNER // owner is 0 and should be the signer
    //   const signature = await signer._signTypedData(domain, types, val)
    //   let sig = ethers.utils.splitSignature(signature)
    //   sig.v = 0
    //   sig.r = '0xbadbadbadbadbadbadbadbadbadbadbadbadbadbadbadbadbadbadbadbadbad0'
    //   sig.s = '0xbadbadbadbadbadbadbadbadbadbadbadbadbadbadbadbadbadbadbadbadbad0'

    //   await expect(EPNSCoreV1Proxy.connect(TRANSMITTER).subscribeBySignature(CHANNEL_CREATOR, nonce,deadline,sig.v, sig.r, sig.s))
    //     .to.be.revertedWith("Invalid signature")
    // })

    // it('Function should Abort if Nonce is Invalid', async function () {
    //   nonce = await EPNSCoreV1Proxy.nonces(BOB) + 1
    //   val['nonce'] = nonce.toString()

    //   const signer = BOBSIGNER
    //   const signature = await signer._signTypedData(domain, types, val)
    //   let sig = ethers.utils.splitSignature(signature)

    //   await expect(EPNSCoreV1Proxy.connect(TRANSMITTER).subscribeBySignature(CHANNEL_CREATOR, nonce,deadline,sig.v, sig.r, sig.s))
    //     .to.be.revertedWith('Invalid nonce')
    // })

    

  })


  });
