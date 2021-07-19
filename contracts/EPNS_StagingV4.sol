pragma solidity >=0.6.0 <0.7.0;
pragma experimental ABIEncoderV2;


import "./interfaces/IUniswapV2Router.sol";
import "./interfaces/ILendingPool.sol";
import "./interfaces/ILendingPoolAddressesProvider.sol";

import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/proxy/Initializable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Strings.sol";
import "hardhat/console.sol";



contract EPNSStagingV4 is Initializable, ReentrancyGuard  {
    using SafeMath for uint;
    using SafeERC20 for IERC20;

    /* ***************
    * DEFINE ENUMS AND CONSTANTS
    *************** */
    // For Message Type
    enum ChannelType {ProtocolNonInterest, ProtocolPromotion, InterestBearingOpen, InterestBearingMutual}
    enum ChannelAction {ChannelRemoved, ChannelAdded, ChannelUpdated}
    enum SubscriberAction {SubscriberRemoved, SubscriberAdded, SubscriberUpdated}



    /* ***************
    // DEFINE STRUCTURES AND VARIABLES
    *************** */


    /* Users are everyone in the EPNS Ecosystem
     * the struct creates a registry for public key signing and maintains the users subscribed channels
    */
    struct User {
        bool userActivated; // Whether a user is activated or not
        bool publicKeyRegistered; // Will be false until public key is emitted
        bool channellized; // Marks if a user has opened a channel

        uint userStartBlock; // Events should not be polled before this block as user doesn't exist
        uint subscribedCount; // Keep track of subscribers

        uint timeWeightedBalance;

        // keep track of all subscribed channels
        mapping(address => uint) subscribed;
        mapping(uint => address) mapAddressSubscribed;
    }


    /* Channels are addresses who have wants their broadcasting network,
    * the channel can never go back to being a plain user but can be marked inactive
    */
    struct Channel {
        // Channel Type
        ChannelType channelType;

        // Flag to deactive channel
        bool deactivated;

        // Channel Pool Contribution
        uint poolContribution;
        uint memberCount;

        uint channelHistoricalZ;
        uint channelFairShareCount;
        uint channelLastUpdate; // The last update block number, used to calculate fair share

        // To calculate fair share of profit from the pool of channels generating interest
        uint channelStartBlock; // Helps in defining when channel started for pool and profit calculation
        uint channelUpdateBlock; // Helps in outlining when channel was updated
        uint channelWeight; // The individual weight to be applied as per pool contribution

        // To keep track of subscribers info
        mapping(address => bool) memberExists;

        // For iterable mapping
        mapping(address => uint) members;
        mapping(uint => address) mapAddressMember; // This maps to the user

        // To calculate fair share of profit for a subscriber
        // The historical constant that is applied with (wnx0 + wnx1 + .... + wnxZ)
        // Read more in the repo: https://github.com/ethereum-push-notification-system
        mapping(address => uint) memberLastUpdate;
    }

    // To keep track of channels
    mapping(address => Channel) public channels;
    mapping(uint => address) public mapAddressChannels;

    // To keep a track of all users
    mapping(address => User) public users;
    mapping(uint => address) public mapAddressUsers;

    // To keep track of interest claimed and interest in wallet
    mapping(address => uint) public usersInterestClaimed;
    mapping(address => uint) public usersInterestInWallet;
    
    // Delegated Notifications: Mapping to keep track of addresses allowed to send notifications on Behalf of a Channel
    mapping(address => mapping (address => bool)) public delegated_NotificationSenders;

    /// @notice A record of states for signing / validating signatures
    mapping (address => uint) public nonces;

    /**
        Address Lists
    */
    address public lendingPoolProviderAddress;
    address public daiAddress;
    address public aDaiAddress;
    address public governance;

    // Track assetCounts
    uint public channelsCount;
    uint public usersCount;

    // Helper for calculating fair share of pool, group are all channels, renamed to avoid confusion
    uint public groupNormalizedWeight;
    uint public groupHistoricalZ;
    uint public groupLastUpdate;
    uint public groupFairShareCount;

    /*
        For maintaining the #DeFi finances
    */
    uint public poolFunds;

    uint public REFERRAL_CODE;

    uint ADD_CHANNEL_MAX_POOL_CONTRIBUTION;

    uint DELEGATED_CONTRACT_FEES;

    uint ADJUST_FOR_FLOAT;
    uint ADD_CHANNEL_MIN_POOL_CONTRIBUTION;

    address private UNISWAP_V2_ROUTER;
    address private PUSH_TOKEN_ADDRESS;

    string public constant name = "EPNS STAGING V4";
     /// @notice The EIP-712 typehash for the contract's domain
    bytes32 public constant DOMAIN_TYPEHASH = keccak256("EIP712Domain(string name,uint256 chainId,address verifyingContract)");
    /// @notice The EIP-712 typehash for the SUBSCRIBE struct used by the contract
    bytes32 public constant SUBSCRIBE_TYPEHASH = keccak256("Subscribe(address channel,uint256 nonce,uint256 expiry)");
     /// @notice The EIP-712 typehash for the SUBSCRIBE struct used by the contract
    bytes32 public constant UNSUBSCRIBE_TYPEHASH = keccak256("Unsubscribe(address channel,uint256 nonce,uint256 expiry)");
    /// @notice The EIP-712 typehash for the SEND NOTIFICATION struct used by the contract
    bytes32 public constant SEND_NOTIFICATION_TYPEHASH =
        keccak256(
            "SendNotification(address channel,address delegate,address recipient,bytes identity,uint256 nonce,uint256 expiry)"
    );

    /* ************** 
    
    => IMPERATIVE EVENTS <=

    *************** */
    // For Public Key Registration Emit
    event PublicKeyRegistered(address indexed owner, bytes publickey);

    // Channel Related | // This Event is listened by on All Infra Services
    event AddChannel(address indexed channel, ChannelType indexed channelType, bytes identity);
    event UpdateChannel(address indexed channel, bytes identity);
    event DeactivateChannel(address indexed channel);

    // Subscribe / Unsubscribe | This Event is listened by on All Infra Services
    event Subscribe(address indexed channel, address indexed user);
    event Unsubscribe(address indexed channel, address indexed user);

    // Send Notification | This Event is listened by on All Infra Services
    event SendNotification(address indexed channel, address indexed recipient, bytes identity);

    // Emit Claimed Interest
    event InterestClaimed(address indexed user, uint indexed amount);

    // Withdrawl Related
    event Withdrawal(address indexed to, address token, uint amount);

    // Addition/Removal of Delegete Events
    event AddDelegate(address channel, address delegate);
    event RemoveDelegate(address channel, address delegate);

    /* ***************
    * INITIALIZER,
    *************** */

    function initialize(
        address _governance,
        address _lendingPoolProviderAddress,
        address _daiAddress,
        address _aDaiAddress,
        uint _referralCode
    ) public initializer returns (bool success) {
        // setup addresses
        governance = _governance; // multisig/timelock, also controls the proxy
        lendingPoolProviderAddress = _lendingPoolProviderAddress;
        daiAddress = _daiAddress;
        aDaiAddress = _aDaiAddress;
        REFERRAL_CODE = _referralCode;
        UNISWAP_V2_ROUTER = 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D;
        PUSH_TOKEN_ADDRESS = 0xf418588522d5dd018b425E472991E52EBBeEEEEE;


        DELEGATED_CONTRACT_FEES = 1 * 10 ** 17; // 0.1 DAI to perform any delegate call

        ADD_CHANNEL_MIN_POOL_CONTRIBUTION = 50 * 10 ** 18; // 50 DAI or above to create the channel
        ADD_CHANNEL_MAX_POOL_CONTRIBUTION = 250000 * 50 * 10 ** 18; // 250k DAI or below, we don't want channel to make a costly mistake as well

        groupLastUpdate = block.number;
        groupNormalizedWeight = ADJUST_FOR_FLOAT; // Always Starts with 1 * ADJUST FOR FLOAT

        ADJUST_FOR_FLOAT = 10 ** 7; // TODO: checkout dsmath
        channelsCount = 0;
        usersCount = 0;

        // Helper for calculating fair share of pool, group are all channels, renamed to avoid confusion
        groupNormalizedWeight = 0;
        groupHistoricalZ = 0; // Abbre
        groupLastUpdate = 0; // The last update block number, used to calculate fair share
        groupFairShareCount = 0; // They are alias to channels count but seperating them for brevity

        /*
        For maintaining the #DeFi finances
        */
        poolFunds = 0; // Always in DAI
        // Add EPNS Channels
        // First is for all users
        // Second is all channel alerter, amount deposited for both is 0
        // to save gas, emit both the events out
        // identity = payloadtype + payloadhash

        // EPNS ALL USERS
        emit AddChannel(governance, ChannelType.ProtocolNonInterest, "1+QmSbRT16JVF922yAB26YxWFD6DmGsnSHm8VBrGUQnXTS74");
        _createChannel(governance, ChannelType.ProtocolNonInterest, 0); // should the owner of the contract be the channel? should it be governance in this case?

        // EPNS ALERTER CHANNEL
        emit AddChannel(0x0000000000000000000000000000000000000000, ChannelType.ProtocolNonInterest, "1+QmTCKYL2HRbwD6nGNvFLe4wPvDNuaYGr6RiVeCvWjVpn5s");
        _createChannel(0x0000000000000000000000000000000000000000, ChannelType.ProtocolNonInterest, 0);

        // Create Channel
        success = true;
    }

    /* ************** 
    
    => FALLBACK FUNCTION <=

    *************** */

    receive() external payable {}

    /* ************** 
    
    => MODIFIERS <=

    *************** */
    modifier onlyGov() {
        require (msg.sender == governance, "EPNSCore::onlyGov, user is not governance");
        _;
    }

    modifier onlyValidUser(address _addr) {
        require(users[_addr].userActivated, "User not activated yet");
        _;
    }

    modifier onlyUserWithNoChannel() {
        require(!users[msg.sender].channellized, "User already a Channel Owner");
        _;
    }

    modifier onlyActivatedChannels(address _channel) {
        require(users[_channel].channellized && !channels[_channel].deactivated, "Channel deactivated or doesn't exists");
        _;
    }

    modifier onlyChannelOwner(address _channel) {
        require(
        ((users[_channel].channellized && msg.sender == _channel) || (msg.sender == governance && _channel == 0x0000000000000000000000000000000000000000)),
        "Channel doesn't Exists"
        );
        _;
    }

    modifier onlyUserAllowedChannelType(ChannelType _channelType) {
      require(
        (_channelType == ChannelType.InterestBearingOpen || _channelType == ChannelType.InterestBearingMutual),
        "Channel Type Invalid"
      );

      _;
    }

    modifier onlySubscribed(address _channel, address _subscriber) {
        require(channels[_channel].memberExists[_subscriber], "Subscriber doesn't Exists");
        _;
    }

    modifier onlyNonOwnerSubscribed(address _channel, address _subscriber) {
        require(_channel != _subscriber && channels[_channel].memberExists[_subscriber], "Either Channel Owner or Not Subscribed");
        _;
    }

    modifier onlyNonSubscribed(address _channel, address _subscriber) {
        require(!channels[_channel].memberExists[_subscriber], "Subscriber already Exists");
        _;
    }


    modifier onlyChannelOwnerOrAllowedDelegatesOrSelfRecipients(
        address _channel,
        address _notificationSender,
        address _recipient
    ) {
        require(
            ((users[_channel].channellized && msg.sender == _channel) ||
            (msg.sender == governance && _channel == 0x0000000000000000000000000000000000000000) ||
            (delegated_NotificationSenders[_channel][_notificationSender] && msg.sender == _notificationSender) ||
            (_recipient == msg.sender)),
            "SendNotif Error: Invalid Channel, Delegate or Subscriber"
        );
        _;
    }

    // modifier onlyChannelOwnerOrAllowedDelegates(
    //     address _channel,
    //     address _notificationSender,
    //     address _recipient,
    //     address signatory
    // ) {
    //     require(
    //         ((users[_channel].channellized && _channel == signatory) ||
    //         (delegated_NotificationSenders[_channel][_notificationSender] &&
    //            _notificationSender == signatory)),
    //         //|| (_recipient == signatory)),
    //         "SendNotif Via Sig Error: Invalid Channel, Delegate Or Subscriber"
    //     );
    //     _;
    // }

 // For DEBUGGING - Dummy Modifier
    modifier onlyChannelOwnerOrAllowedDelegates(
        address _channel,
        address _notificationSender,
        address _recipient,
        address signatory
    ) {

        require (true);
        
        // require(
        //     ((users[_channel].channellized && _channel == signatory) ||
        //     (delegated_NotificationSenders[_channel][_notificationSender] &&
        //        _notificationSender == signatory)),
        //     //|| (_recipient == signatory)),
        //     "SendNotif Via Sig Error: Invalid Channel, Delegate Or Subscriber"
        // );
        _;
    }


    /* ************** 
    
    => IMPERATIVE GETTER & SETTER FUNCTIONS <=

    *************** */

    /// @dev To check if member exists
    function memberExists(address _user, address _channel) external view returns (bool subscribed) {
        subscribed = channels[_channel].memberExists[_user];
    }

    /// @dev To fetch subscriber address for a channel
    function getChannelSubscriberAddress(address _channel, uint _subscriberId) external view returns (address subscriber) {
        subscriber = channels[_channel].mapAddressMember[_subscriberId];
    }

    /// @dev To fetch user id for a subscriber of a channel
    function getChannelSubscriberUserID(address _channel, uint _subscriberId) external view returns (uint userId) {
        userId = channels[_channel].members[channels[_channel].mapAddressMember[_subscriberId]];
    }


    /* ************** 
    
    => PUBLIC KEY BROADCASTING & USER ADDING FUNCTIONALITIES <=

    *************** */

    /// @dev Add the user to the ecosystem if they don't exists, the returned response is used to deliver a message to the user if they are recently added
    function _addUser(address _addr) private returns (bool userAlreadyAdded) {
        if (users[_addr].userActivated) {
            userAlreadyAdded = true;
        }
        else {
            // Activates the user
            users[_addr].userStartBlock = block.number;
            users[_addr].userActivated = true;
            mapAddressUsers[usersCount] = _addr;

            usersCount = usersCount.add(1);
        }
    }

    /* @dev Internal system to handle broadcasting of public key,
    * is a entry point for subscribe, or create channel but is option
    */
    function _broadcastPublicKey(address _userAddr, bytes memory _publicKey) private {
        // Add the user, will do nothing if added already, but is needed before broadcast
        _addUser(_userAddr);

        // get address from public key
        address userAddr = getWalletFromPublicKey(_publicKey);

        if (_userAddr == userAddr) {
            // Only change it when verification suceeds, else assume the channel just wants to send group message
            users[userAddr].publicKeyRegistered = true;

            // Emit the event out
            emit PublicKeyRegistered(userAddr, _publicKey);
        }
        else {
            revert("Public Key Validation Failed");
        }
    }

    /// @dev Don't forget to add 0x into it
    function getWalletFromPublicKey (bytes memory _publicKey) public pure returns (address wallet) {
        if (_publicKey.length == 64) {
            wallet = address (uint160 (uint256 (keccak256 (_publicKey))));
        }
        else {
            wallet = 0x0000000000000000000000000000000000000000;
        }
    }

    function transferGovernance(address _newGovernance) onlyGov public {
        require (_newGovernance != address(0), "EPNSCore::transferGovernance, new governance can't be none");
        require (_newGovernance != governance, "EPNSCore::transferGovernance, new governance can't be current governance");
        governance = _newGovernance;
    }

    /// @dev Performs action by the user themself to broadcast their public key
    function broadcastUserPublicKey(bytes calldata _publicKey) external {
        // Will save gas
        if (users[msg.sender].publicKeyRegistered) {
        // Nothing to do, user already registered
        return;
        }

        // broadcast it
        _broadcastPublicKey(msg.sender, _publicKey);
    }

    /* ************** 
    
    => CHANNEL CREATION FUNCTIONALITIES <=

    *************** */

    /// @dev Create channel with fees and public key
    function createChannelWithFeesAndPublicKey(ChannelType _channelType, bytes calldata _identity, bytes calldata _publickey,uint256 _amount)
        external onlyUserWithNoChannel onlyUserAllowedChannelType(_channelType) {
        // Save gas, Emit the event out
        emit AddChannel(msg.sender, _channelType, _identity);

        // Broadcast public key
        // @TODO Find a way to save cost

        // Will save gas
        if (!users[msg.sender].publicKeyRegistered) {
            _broadcastPublicKey(msg.sender, _publickey);
        }

        // Bubble down to create channel
        _createChannelWithFees(msg.sender, _channelType,_amount);
    }

    /// @dev Create channel with fees
    function createChannelWithFees(ChannelType _channelType, bytes calldata _identity,uint256 _amount)
      external onlyUserWithNoChannel onlyUserAllowedChannelType(_channelType) {
        // Save gas, Emit the event out
        emit AddChannel(msg.sender, _channelType, _identity);

        // Bubble down to create channel
        _createChannelWithFees(msg.sender, _channelType,_amount);
    }

    /// @dev One time, Create Promoter Channel
    function createPromoterChannel() external {
      // EPNS PROMOTER CHANNEL
      require(!users[address(this)].channellized, "Contract has Promoter");

      // Check the allowance and transfer funds
      IERC20(daiAddress).transferFrom(msg.sender, address(this), ADD_CHANNEL_MIN_POOL_CONTRIBUTION);

      // Then Add Promoter Channel
      emit AddChannel(address(this), ChannelType.ProtocolPromotion, "1+QmRcewnNpdt2DWYuud3LxHTwox2RqQ8uyZWDJ6eY6iHkfn");

      // Call create channel after fees transfer
      _createChannelAfterTransferOfFees(address(this), ChannelType.ProtocolPromotion, ADD_CHANNEL_MIN_POOL_CONTRIBUTION);
    }

    /// @dev To update channel, only possible if 1 subscriber is present or this is governance
    function updateChannelMeta(address _channel, bytes calldata _identity) external {
      emit UpdateChannel(_channel, _identity);

      _updateChannelMeta(_channel);
    }


    /// @dev add channel with fees
    function _createChannelWithFees(address _channel, ChannelType _channelType, uint256 _amount) private {
      // Check if it's equal or above Channel Pool Contribution
      // removed allowance -
      require(_amount >= ADD_CHANNEL_MIN_POOL_CONTRIBUTION,"Insufficient Funds or max ceiling reached");
      // Check and transfer funds
      IERC20(daiAddress).safeTransferFrom(_channel, address(this), _amount);

      // Call create channel after fees transfer
      _createChannelAfterTransferOfFees(_channel, _channelType, _amount);
    }

    function _createChannelAfterTransferOfFees(address _channel, ChannelType _channelType, uint _amount) private {
      // Deposit funds to pool
      _depositFundsToPool(_amount);

      // Call Create Channel
      _createChannel(_channel, _channelType, _amount);
    }

    /// @dev Create channel internal method that runs
    function _createChannel(address _channel, ChannelType _channelType, uint _amountDeposited) private {
        // Add the user, will do nothing if added already, but is needed for all outpoints
        bool userAlreadyAdded = _addUser(_channel);

        // Calculate channel weight
        uint _channelWeight = _amountDeposited.mul(ADJUST_FOR_FLOAT).div(ADD_CHANNEL_MIN_POOL_CONTRIBUTION);

        // Next create the channel and mark user as channellized
        users[_channel].channellized = true;

        channels[_channel].poolContribution = _amountDeposited;
        channels[_channel].channelType = _channelType;
        channels[_channel].channelStartBlock = block.number;
        channels[_channel].channelUpdateBlock = block.number;
        channels[_channel].channelWeight = _channelWeight;

        // Add to map of addresses and increment channel count
        mapAddressChannels[channelsCount] = _channel;
        channelsCount = channelsCount.add(1);

        // Readjust fair share if interest bearing
        if (
          _channelType == ChannelType.ProtocolPromotion
          || _channelType == ChannelType.InterestBearingOpen
          || _channelType == ChannelType.InterestBearingMutual
        ) {
            (groupFairShareCount, groupNormalizedWeight, groupHistoricalZ, groupLastUpdate) = _readjustFairShareOfChannels(
                ChannelAction.ChannelAdded,
                _channelWeight,
                groupFairShareCount,
                groupNormalizedWeight,
                groupHistoricalZ,
                groupLastUpdate
            );
        }

        // If this is a new user than subscribe them to EPNS Channel
        if (!userAlreadyAdded && _channel != 0x0000000000000000000000000000000000000000) {
            // Call actual subscribe, owner channel
            _subscribe(governance, _channel);
        }
        // All Channels are subscribed to EPNS Alerter as well, unless it's the EPNS Alerter channel iteself
        if (_channel != 0x0000000000000000000000000000000000000000) {
            _subscribe(0x0000000000000000000000000000000000000000, _channel);
        }

        // Subscribe them to their own channel as well
        if (_channel != governance) {
          _subscribe(_channel, _channel);
        }
    }

    /// @dev private function to update channel meta
    function _updateChannelMeta(address _channel) internal onlyChannelOwner(_channel) onlyActivatedChannels(_channel) {
      // check if special channel
      if (msg.sender == governance && (_channel == governance || _channel == 0x0000000000000000000000000000000000000000 || _channel == address(this))) {
        // don't do check for 1 as these are special channels

      }
      else {
        // do check for 1
        require (channels[_channel].memberCount == 1, "Channel has external subscribers");
      }

      channels[msg.sender].channelUpdateBlock = block.number;
    }


    /// @dev Deactivate channel
    function deactivateChannel() onlyActivatedChannels(msg.sender) external {
        channels[msg.sender].deactivated = true;
        emit DeactivateChannel(msg.sender);
    }

    /* ************** 
    
    => User & Channel Notification Settings Functionalities <=
    *************** */
    
    // FOR USERS

    //@dev - Maps the User's Address to Channel Owner's address to Deliminated Notification Settings String selected by the USER 
    mapping(address => mapping(address => string)) public userToChannelNotifs;
    
    event UserNotifcationSettingsAdded(address _channel, address _user, uint256 _notifID,string _notifSettings);

    // @notice - Deliminated Notification Settings string contains -> Decimal Representation Notif Settings + Notification Settings
    // For instance: 3+1-0+2-0+3-1+4-98
    
    // 3 -> Decimal Representation of the Notification Options selected by the User
   
    // For Boolean Type Notif Options
        // 1-0 -> 1 stands for Option 1 - 0 Means the user didn't choose that Notif Option.
        // 3-1 stands for Option 3      - 1 Means the User Selected the 3rd boolean Option

    // For SLIDER TYPE Notif Options
        // 2-0 -> 2 stands for Option 2 - 0 is user's Choice
        // 4-98-> 4 stands for Option 4 - 98is user's Choice
    
    // @param _channel - Address of the Channel for which the user is creating the Notif settings
    // @param _notifID- Decimal Representation of the Options selected by the user
    // @param _notifSettings - Deliminated string that depicts the User's Notifcation Settings

    function subscribeToSpecificNotification(address _channel,uint256 _notifID,string calldata _notifSettings) external onlySubscribed(_channel,msg.sender){
        string memory notifSetting = string(abi.encodePacked(Strings.toString(_notifID),"+",_notifSettings));
        userToChannelNotifs[msg.sender][_channel] = notifSetting;
        emit UserNotifcationSettingsAdded(_channel,msg.sender,_notifID,notifSetting);
    }

    // FOR CHANNELS

    //@dev - Maps the Channel Owner's address to Deliminated Notification Settings 
    mapping(address => string) public channelNotifSettings;

    event ChannelNotifcationSettingsAdded(address _channel, uint256 totalNotifOptions,string _notifSettings,string _notifDescription);

    // @notice - Deliminated Notification Settings string contains -> Total Notif Options + Notification Settings
    // For instance: 5+1-0+2-50-20-100+1-1+2-78-10-150
    // 5 -> Total Notification Options provided by a Channel owner
   
    // For Boolean Type Notif Options
        // 1-0 -> 1 stands for BOOLEAN type - 0 stands for Default Boolean Type for that Notifcation(set by Channel Owner), In this case FALSE.
        // 1-1 stands for BOOLEAN type - 1 stands for Default Boolean Type for that Notifcation(set by Channel Owner), In this case TRUE.

    // For SLIDER TYPE Notif Options
        // 2-50-20-100 -> 2 stands for SLIDER TYPE - 50 stands for Default Value for that Option - 20 is the Start Range of that SLIDER - 100 is the END Range of that SLIDER Option
        // 2-78-10-150 -> 2 stands for SLIDER TYPE - 78 stands for Default Value for that Option - 10 is the Start Range of that SLIDER - 150 is the END Range of that SLIDER Option
    
    // @param _notifOptions - Total Notification options provided by the Channel Owner
    // @param _notifSettings- Deliminated String of Notification Settings
    // @param _notifDescription - Description of each Notification that depicts the Purpose of that Notification

    function createChannelNotificationSettings(uint256 _notifOptions,string calldata _notifSettings, string calldata _notifDescription) external onlyActivatedChannels(msg.sender){
        string memory notifSetting = string(abi.encodePacked(Strings.toString(_notifOptions),"+",_notifSettings));
        channelNotifSettings[msg.sender] = notifSetting;
        emit ChannelNotifcationSettingsAdded(msg.sender,_notifOptions,notifSetting,_notifDescription);  
    }

    /* ************** 
    
    => SUBSCRIBE FUNCTIOANLTIES <=

    *************** */

    /// @dev subscribe to channel with public key
    function subscribeWithPublicKey(address _channel, bytes calldata _publicKey) onlyActivatedChannels(_channel) external {
        // Will save gas as it prevents calldata to be copied unless need be
        if (!users[msg.sender].publicKeyRegistered) {

        // broadcast it
        _broadcastPublicKey(msg.sender, _publicKey);
        }

        // Call actual subscribe
        _subscribe(_channel, msg.sender);
    }

    function subscribeBySignature(address channel, uint nonce, uint expiry, uint8 v, bytes32 r, bytes32 s) public {
        bytes32 domainSeparator = keccak256(abi.encode(DOMAIN_TYPEHASH, keccak256(bytes(name)), getChainId(), address(this)));
        bytes32 structHash = keccak256(abi.encode(SUBSCRIBE_TYPEHASH, channel, nonce, expiry));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
        address signatory = ecrecover(digest, v, r, s);
        require(signatory != address(0), "Invalid signature");
        require(nonce == nonces[signatory]++, "Invalid nonce");
        require(now <= expiry, "Signature expired");
        _subscribe(channel, signatory);
    }

    function unsubscribeBySignature(address channel, uint nonce, uint expiry, uint8 v, bytes32 r, bytes32 s) public {
        bytes32 domainSeparator = keccak256(abi.encode(DOMAIN_TYPEHASH, keccak256(bytes(name)), getChainId(), address(this)));
        bytes32 structHash = keccak256(abi.encode(UNSUBSCRIBE_TYPEHASH, channel, nonce, expiry));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
        address signatory = ecrecover(digest, v, r, s);
        require(signatory != address(0), "Invalid signature");
        require(nonce == nonces[signatory]++, "Invalid nonce");
        require(now <= expiry, "Signature expired");
        _unsubscribe(channel, signatory);
    }


    /// @dev subscribe to channel
    function subscribe(address _channel) onlyActivatedChannels(_channel) external {
        // Call actual subscribe
        _subscribe(_channel, msg.sender);
    }

    /// @dev unsubscribe to channel
    function unsubscribe(address _channel) onlyActivatedChannels(_channel) onlyNonOwnerSubscribed(_channel, msg.sender) external {
        // Call actual unsubscribe
        _unsubscribe(_channel, msg.sender);
    }


    /// @dev private function that eventually handles the subscribing onlyValidChannel(_channel)
    function _subscribe(address _channel, address _user) private onlyNonSubscribed(_channel, _user) {
        // Add the user, will do nothing if added already, but is needed for all outpoints
        _addUser(_user);

        User storage user = users[_user];
        Channel storage channel = channels[_channel];

        // treat the count as index and update user struct
        user.subscribed[_channel] = user.subscribedCount;
        user.mapAddressSubscribed[user.subscribedCount] = _channel;
        user.subscribedCount = user.subscribedCount.add(1); // Finally increment the subscribed count

        // Do the same for the channel to maintain sync, treat member count as index
        channel.members[_user] = channel.memberCount;
        channel.mapAddressMember[channel.memberCount] = _user;
        channel.memberCount = channel.memberCount.add(1); // Finally increment the member count

        // Set Additional flag for some conditions and set last update of member
        channel.memberLastUpdate[_user] = block.number;
        channel.memberExists[_user] = true;

        // Next readjust fair share and that's it
        (
            channels[_channel].channelFairShareCount,
            channels[_channel].channelHistoricalZ,
            channels[_channel].channelLastUpdate
        ) = _readjustFairShareOfSubscribers(
            SubscriberAction.SubscriberAdded,
            channels[_channel].channelFairShareCount,
            channels[_channel].channelHistoricalZ,
            channels[_channel].channelLastUpdate
        );

        // Emit it
        emit Subscribe(_channel, _user);
    }

   // @dev to unsubscribe from channel
    function _unsubscribe(address _channel, address _user) private returns (uint ratio) {
        // Add the channel to gray list so that it can't subscriber the user again as delegated
        User storage user = users[_user];

        // first get ratio of earning
        ratio = 0;
        ratio = calcSingleChannelEarnRatio(_channel, _user, block.number);

        // Take the fair share out

        // Remove the mappings and cleanup
        // a bit tricky, swap and delete to maintain mapping
        // Remove From Users mapping
        // Find the id of the channel and swap it with the last id, use channel.memberCount as index
        // Slack too deep fix
        // address usrSubToSwapAdrr = user.mapAddressSubscribed[user.subscribedCount];
        // uint usrSubSwapID = user.subscribed[_channel];

        // // swap to last one and then
        // user.subscribed[usrSubToSwapAdrr] = usrSubSwapID;
        // user.mapAddressSubscribed[usrSubSwapID] = usrSubToSwapAdrr;

        user.subscribed[user.mapAddressSubscribed[user.subscribedCount]] = user.subscribed[_channel];
        user.mapAddressSubscribed[user.subscribed[_channel]] = user.mapAddressSubscribed[user.subscribedCount];

        // delete the last one and substract
        delete(user.subscribed[_channel]);
        delete(user.mapAddressSubscribed[user.subscribedCount]);
        user.subscribedCount = user.subscribedCount.sub(1);

        // Remove from Channels mapping
        Channel storage channel = channels[_channel];

        // Set additional flag to false
        channel.memberExists[_user] = false;

        // Find the id of the channel and swap it with the last id, use channel.memberCount as index
        // Slack too deep fix
        // address chnMemToSwapAdrr = channel.mapAddressMember[channel.memberCount];
        // uint chnMemSwapID = channel.members[_user];

        // swap to last one and then
        channel.members[channel.mapAddressMember[channel.memberCount]] = channel.members[_user];
        channel.mapAddressMember[channel.members[_user]] = channel.mapAddressMember[channel.memberCount];

        // delete the last one and substract
        delete(channel.members[_user]);
        delete(channel.mapAddressMember[channel.memberCount]);
        channel.memberCount = channel.memberCount.sub(1);

        // Next readjust fair share
        (
            channels[_channel].channelFairShareCount,
            channels[_channel].channelHistoricalZ,
            channels[_channel].channelLastUpdate
        ) = _readjustFairShareOfSubscribers(
            SubscriberAction.SubscriberRemoved,
            channels[_channel].channelFairShareCount,
            channels[_channel].channelHistoricalZ,
            channels[_channel].channelLastUpdate
        );

        // Next calculate and send the fair share earning of the user from this channel
        if (
          channel.channelType == ChannelType.ProtocolPromotion
          || channel.channelType == ChannelType.InterestBearingOpen
          || channel.channelType == ChannelType.InterestBearingMutual
        ) {
            _withdrawFundsFromPool(ratio);
        }

        // Emit it
        emit Unsubscribe(_channel, _user);
    }

  
    /* ************** 
    
    => DEPOSIT & WITHDRAWAL of FUNDS<=

    *************** */

    function updateUniswapV2Address(address _newAddress) onlyGov external{
        UNISWAP_V2_ROUTER = _newAddress;
    }
    
    /// @dev deposit funds to pool
    function _depositFundsToPool(uint amount) private {
        // Got the funds, add it to the channels dai pool
        poolFunds = poolFunds.add(amount);

        // Next swap it via AAVE for aDAI
        // mainnet address, for other addresses: https://docs.aave.com/developers/developing-on-aave/deployed-contract-instances
        ILendingPoolAddressesProvider provider = ILendingPoolAddressesProvider(lendingPoolProviderAddress);
        ILendingPool lendingPool = ILendingPool(provider.getLendingPool());
        IERC20(daiAddress).approve(provider.getLendingPoolCore(), amount);

        // Deposit to AAVE
        lendingPool.deposit(daiAddress, amount, uint16(REFERRAL_CODE)); // set to 0 in constructor presently
    }

        /// @dev withdraw funds from pool
    function _withdrawFundsFromPool(uint ratio) private nonReentrant {
        uint totalBalanceWithProfit = IERC20(aDaiAddress).balanceOf(address(this));

        uint totalProfit = totalBalanceWithProfit.sub(poolFunds);
        uint userAmount = totalProfit.mul(ratio);

        // adjust poolFunds first
        uint userAmountAdjusted = userAmount.div(ADJUST_FOR_FLOAT);
        poolFunds = poolFunds.sub(userAmountAdjusted);

        // Add to interest claimed
        usersInterestClaimed[msg.sender] = usersInterestClaimed[msg.sender].add(userAmountAdjusted);

        // Finally SWAP aDAI to PUSH, and TRANSFER TO USER
        swapAndTransferaDaiToPUSH(msg.sender, userAmountAdjusted);
        // Emit Event
        emit InterestClaimed(msg.sender, userAmountAdjusted);
    }
    /// @dev to withraw funds coming from donate
    function withdrawEthFunds() external onlyGov {
        uint bal = address(this).balance;

        payable(governance).transfer(bal);

        // Emit Event
        emit Withdrawal(msg.sender, daiAddress, bal);
    }

    /*
     * @dev Swaps aDai to PUSH Tokens and Transfers to the USER Address
     * @param _user address of the user that will recieve the PUSH Tokens
     * @param __userAmount the amount of aDai to be swapped and transferred
    */
    function swapAndTransferaDaiToPUSH(address _user, uint256 _userAmount) internal returns(bool){
        IERC20(aDaiAddress).approve(UNISWAP_V2_ROUTER, _userAmount);

        address[] memory path;
        path[0] = aDaiAddress;
        path[1] = PUSH_TOKEN_ADDRESS;

        IUniswapV2Router(UNISWAP_V2_ROUTER).swapExactTokensForTokens(
            _userAmount,
            1,
            path,
            _user,
            block.timestamp
        );
        return true;
    }
    


    /* ************** 
    
    => FAIR SHARE RATIO CALCULATIONS <=

    *************** */

    /// @dev to get channel fair share ratio for a given block
    function getChannelFSRatio(address _channel, uint _block) public view returns (uint ratio) {
        // formula is ratio = da / z + (nxw)
        // d is the difference of blocks from given block and the last update block of the entire group
        // a is the actual weight of that specific group
        // z is the historical constant
        // n is the number of channels
        // x is the difference of blocks from given block and the last changed start block of group
        // w is the normalized weight of the groups
        uint d = _block.sub(channels[_channel].channelStartBlock); // _block.sub(groupLastUpdate);
        uint a = channels[_channel].channelWeight;
        uint z = groupHistoricalZ;
        uint n = groupFairShareCount;
        uint x = _block.sub(groupLastUpdate);
        uint w = groupNormalizedWeight;

        uint nxw = n.mul(x.mul(w));
        uint z_nxw = z.add(nxw);
        uint da = d.mul(a);

        ratio = (da.mul(ADJUST_FOR_FLOAT)).div(z_nxw);
    }

    /// @dev to get subscriber fair share ratio for a given channel at a block
    function getSubscriberFSRatio(
        address _channel,
        address _user,
        uint _block
    ) public view onlySubscribed(_channel, _user) returns (uint ratio) {
        // formula is ratio = d / z + (nx)
        // d is the difference of blocks from given block and the start block of subscriber
        // z is the historical constant
        // n is the number of subscribers of channel
        // x is the difference of blocks from given block and the last changed start block of channel

        uint d = _block.sub(channels[_channel].memberLastUpdate[_user]);
        uint z = channels[_channel].channelHistoricalZ;
        uint x = _block.sub(channels[_channel].channelLastUpdate);

        uint nx = channels[_channel].channelFairShareCount.mul(x);

        ratio = (d.mul(ADJUST_FOR_FLOAT)).div(z.add(nx)); // == d / z + n * x
    }

    /* @dev to get the fair share of user for a single channel, different from subscriber fair share
     * as it's multiplication of channel fair share with subscriber fair share
     */
    function calcSingleChannelEarnRatio(
        address _channel,
        address _user,
        uint _block
    ) public view onlySubscribed(_channel, _user) returns (uint ratio) {
        // First get the channel fair share
        if (
          channels[_channel].channelType == ChannelType.ProtocolPromotion
          || channels[_channel].channelType == ChannelType.InterestBearingOpen
          || channels[_channel].channelType == ChannelType.InterestBearingMutual
        ) {
            uint channelFS = getChannelFSRatio(_channel, _block);
            uint subscriberFS = getSubscriberFSRatio(_channel, _user, _block);

            ratio = channelFS.mul(subscriberFS).div(ADJUST_FOR_FLOAT);
        }
    }

    /// @dev to get the fair share of user overall
    function calcAllChannelsRatio(address _user, uint _block) onlyValidUser(_user) public view returns (uint ratio) {
        // loop all channels for the user
        uint subscribedCount = users[_user].subscribedCount;

        // WARN: This unbounded for loop is an anti-pattern
        for (uint i = 0; i < subscribedCount; i++) {
            if (
              channels[users[_user].mapAddressSubscribed[i]].channelType == ChannelType.ProtocolPromotion
              || channels[users[_user].mapAddressSubscribed[i]].channelType == ChannelType.InterestBearingOpen
              || channels[users[_user].mapAddressSubscribed[i]].channelType == ChannelType.InterestBearingMutual
            ) {
                uint individualChannelShare = calcSingleChannelEarnRatio(users[_user].mapAddressSubscribed[i], _user, _block);
                ratio = ratio.add(individualChannelShare);
            }
        }
    }

        /// @dev to claim fair share of all earnings
    function claimFairShare() onlyValidUser(msg.sender) external returns (uint ratio){
        // Calculate entire FS Share, since we are looping for reset... let's calculate over there
        ratio = 0;

        // Reset member last update for every channel that are interest bearing
        // WARN: This unbounded for loop is an anti-pattern
        for (uint i = 0; i < users[msg.sender].subscribedCount; i++) {
            address channel = users[msg.sender].mapAddressSubscribed[i];

            if (
                channels[channel].channelType == ChannelType.ProtocolPromotion
                || channels[channel].channelType == ChannelType.InterestBearingOpen
                || channels[channel].channelType == ChannelType.InterestBearingMutual
              ) {
                // Reset last updated block
                channels[channel].memberLastUpdate[msg.sender] = block.number;

                // Next readjust fair share and that's it
                (
                channels[channel].channelFairShareCount,
                channels[channel].channelHistoricalZ,
                channels[channel].channelLastUpdate
                ) = _readjustFairShareOfSubscribers(
                SubscriberAction.SubscriberUpdated,
                channels[channel].channelFairShareCount,
                channels[channel].channelHistoricalZ,
                channels[channel].channelLastUpdate
                );

                // Calculate share
                uint individualChannelShare = calcSingleChannelEarnRatio(channel, msg.sender, block.number);
                ratio = ratio.add(individualChannelShare);
            }

        }
        // Finally, withdraw for user
        _withdrawFundsFromPool(ratio);
    }

    /// @dev readjust fair share runs on channel addition, removal or update of channel
    function _readjustFairShareOfChannels(
        ChannelAction _action,
        uint _channelWeight,
        uint _groupFairShareCount,
        uint _groupNormalizedWeight,
        uint _groupHistoricalZ,
        uint _groupLastUpdate
    )
    private
    view
    returns (
        uint groupNewCount,
        uint groupNewNormalizedWeight,
        uint groupNewHistoricalZ,
        uint groupNewLastUpdate
    )
    {
        // readjusts the group count and do deconstruction of weight
        uint groupModCount = _groupFairShareCount;
        uint prevGroupCount = groupModCount;

        uint totalWeight;
        uint adjustedNormalizedWeight = _groupNormalizedWeight; //_groupNormalizedWeight;

        // Increment or decrement count based on flag
        if (_action == ChannelAction.ChannelAdded) {
            groupModCount = groupModCount.add(1);

            totalWeight = adjustedNormalizedWeight.mul(prevGroupCount);
            totalWeight = totalWeight.add(_channelWeight);
        }
        else if (_action == ChannelAction.ChannelRemoved) {
            groupModCount = groupModCount.sub(1);

            totalWeight = adjustedNormalizedWeight.mul(prevGroupCount);
            totalWeight = totalWeight.sub(_channelWeight);
        }
        else if (_action == ChannelAction.ChannelUpdated) {
            totalWeight = adjustedNormalizedWeight.mul(prevGroupCount.sub(1));
            totalWeight = totalWeight.add(_channelWeight);
        }
        else {
            revert("Invalid Channel Action");
        }

        // now calculate the historical constant
        // z = z + nxw
        // z is the historical constant
        // n is the previous count of group fair share
        // x is the differential between the latest block and the last update block of the group
        // w is the normalized average of the group (ie, groupA weight is 1 and groupB is 2 then w is (1+2)/2 = 1.5)
        uint n = groupModCount;
        uint x = block.number.sub(_groupLastUpdate);
        uint w = totalWeight.div(groupModCount);
        uint z = _groupHistoricalZ;

        uint nx = n.mul(x);
        uint nxw = nx.mul(w);

        // Save Historical Constant and Update Last Change Block
        z = z.add(nxw);

        if (n == 1) {
            // z should start from here as this is first channel
            z = 0;
        }

        // Update return variables
        groupNewCount = groupModCount;
        groupNewNormalizedWeight = w;
        groupNewHistoricalZ = z;
        groupNewLastUpdate = block.number;
    }

    /// @dev readjust fair share runs on user addition or removal
    function _readjustFairShareOfSubscribers(
        SubscriberAction action,
        uint _channelFairShareCount,
        uint _channelHistoricalZ,
        uint _channelLastUpdate
    )
    private
    view
    returns (
        uint channelNewFairShareCount,
        uint channelNewHistoricalZ,
        uint channelNewLastUpdate
    )
    {
        uint channelModCount = _channelFairShareCount;
        uint prevChannelCount = channelModCount;

        // Increment or decrement count based on flag
        if (action == SubscriberAction.SubscriberAdded) {
            channelModCount = channelModCount.add(1);
        }
        else if (action == SubscriberAction.SubscriberRemoved) {
            channelModCount = channelModCount.sub(1);
        }
        else if (action == SubscriberAction.SubscriberUpdated) {
        // do nothing, it's happening after a reset of subscriber last update count

        }
        else {
            revert("Invalid Channel Action");
        }

        // to calculate the historical constant
        // z = z + nx
        // z is the historical constant
        // n is the total prevoius subscriber count
        // x is the difference bewtween the last changed block and the current block
        uint x = block.number.sub(_channelLastUpdate);
        uint nx = prevChannelCount.mul(x);
        uint z = _channelHistoricalZ.add(nx);

        // Define Values
        channelNewFairShareCount = channelModCount;
        channelNewHistoricalZ = z;
        channelNewLastUpdate = block.number;
    }


    /* ************** 
    
    => SEND NOTIFICATION FUNCTIONALITIES <=

    *************** */

    /// @dev allow other addresses to send notifications using your channel
    function addDelegate(address _delegate)
        external
        onlyChannelOwner(msg.sender)
    {
        delegated_NotificationSenders[msg.sender][_delegate] = true;
        emit AddDelegate(msg.sender, _delegate);
    }

    /// @dev revoke addresses' permission to send notifications on your behalf
    function removeDelegate(address _delegate)
        external
        onlyChannelOwner(msg.sender)
    {
        delegated_NotificationSenders[msg.sender][_delegate] = false;
        emit RemoveDelegate(msg.sender, _delegate);
    }


    /// @dev to send message to reciepient of a group
    function sendNotificationAsDelegateOrOwnerOrRecipient(
        address _channel,
        address _delegate,
        address _recipient,
        bytes calldata _identity
    )
        public
        onlyChannelOwnerOrAllowedDelegatesOrSelfRecipients(_channel, _delegate, _recipient)
    {
        // Emit the message out
        emit SendNotification(_channel, _recipient, _identity);
    }


    /***
      THREE main CALLERS for this function- 
        1. Channel Owner sends Notif to Recipients
        2. Delegatee of Channel sends Notif to Recipients
        3. Recipients sends Notifs to Themselvs via a Channel
    <------------------------------------------------------------------------------------->
     
     * When a CHANNEL OWNER Calls the Function and sends a Notif-> We check "if (channel owner is the caller) and if(Is Channel Valid)",

     * When a Delegatee wants to send Notif to Recipient-> We check "if(delegate is the Caller) and If( Is delegatee Valid)":

     * When Recipient wants to Send a Notif to themselves -> We check that the If(Caller of the function is Recipient himself)
    
    */


    address public check;
    /// @dev to send message to reciepient of a group
    function _sendNotification(
        address _channel,
        address _delegate,
        address _recipient,
        address _signatory,
        bytes calldata _identity
    )
        private
        onlyChannelOwnerOrAllowedDelegates(
            _channel,
            _delegate,
            _recipient,
            _signatory
        )
    {
        check = _signatory;
        // Emit the message out
        emit SendNotification(_channel, _recipient, _identity);
    }

    /// @dev to send message to reciepient of a group via Sig

    function sendNotifBySig(
        address _channel,
        address _delegate,
        address _recipient,
        bytes calldata _identity,
        uint256 nonce,
        uint256 expiry,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external {
        bytes32 domainSeparator = keccak256(
            abi.encode(
                DOMAIN_TYPEHASH,
                keccak256(bytes(name)),
                getChainId(),
                address(this)
            )
        );
        bytes32 structHash = keccak256(
            abi.encode(
                SEND_NOTIFICATION_TYPEHASH,
                _channel,
                _delegate,
                _recipient,
                _identity,
                nonce,
                expiry
            )
        );
        bytes32 digest = keccak256(
            abi.encodePacked("\x19\x01", domainSeparator, structHash)
        );
        address signatory = ecrecover(digest, v, r, s);
        require(signatory != address(0), "Invalid signature");
        require(nonce == nonces[signatory]++, "Invalid nonce");
        require(now <= expiry, "Signature expired");
        _sendNotification(
            _channel,
            _delegate,
            _recipient,
            signatory,
            _identity
        );
    }

    function getChainId() internal pure returns (uint) {
        uint256 chainId;
        assembly { chainId := chainid() }
        return chainId;
    }
}