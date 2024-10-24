// SPDX-License-Identifier: MIT
pragma solidity ^0.8.5;

import "@openzeppelin-upgradeable/contracts/token/ERC20/ERC20Upgradeable.sol";
import "./interfaces/ISmartnodesMultiSig.sol";

/**
 * @title SmartNodes
 * @dev An ERC20 contract for managing off-chain networks
 */
contract SmartnodesCore is ERC20Upgradeable {
    // Validator multi-sig address
    ISmartnodesMultiSig private _validatorContractInstance;
    address public validatorContractAddress;
    address public proxyAdmin;

    // Counters for storage indexing / IDs
    uint256 public validatorIdCounter;
    uint256 public userCounter;
    uint256 public jobCounter;
    uint256 public activeValidators;
    uint256 public minValidators;
    uint256 public maxValidators;
    uint256 public totalLocked;

    // Events
    event TokensLocked(address indexed validator, uint256 amount);
    event UnlockInitiated(address indexed validator, uint256 unlockTime);
    event TokensUnlocked(address indexed validtor, uint256 amount);
    event JobRequested(
        bytes32 indexed jobHash,
        uint256 timestamp,
        address[] seedValidators
    );
    event JobCompleted(bytes32 indexed jobId, uint256 timestamp);
    event JobDisputed(bytes32 indexed jobId, uint256 timestamp);

    // User data with key information (address, RSA key hash, reputation)
    struct User {
        address userAddress;
        bytes32 publicKeyHash;
        uint8 reputation;
    }

    // Validator data with key information (address, RSA key hash, locked value, reputation, activity)
    struct Validator {
        bytes32 publicKeyHash;
        address validatorAddress;
        uint256 locked;
        uint256 unlockTime;
        uint8 reputation;
    }

    // Information for  a generic off-chain job (job hash [key for kademlia lookup], seed validators, participants, author, etc)
    struct Job {
        address author;
        address[] seedValidators;
        address[] workers;
        uint256[] capacities;
        bool activity;
    }

    // ERC20 token supply metrics
    uint256 TAIL_EMISSION = 8e18;

    uint256 public halving; // number of state updates until next halving (~1 year)
    uint256 public emissionRate; // amount of tokens to be emitted per state update
    uint256 public lockAmount; // minimum validator locked tokens required
    uint256 public unlockPeriod;
    uint256 public statesSinceLastHalving;

    // Main datastructure mappings via id lookup
    mapping(bytes32 => User) public users;
    mapping(bytes32 => address) public workers;
    mapping(bytes32 => address) public validatorAddressByHash;
    mapping(uint256 => Validator) public validators;
    mapping(bytes32 => Job) public jobs;
    uint256[] public activeJobs;

    // Helpful mappings
    mapping(address => bytes32) public userHashByAddress;
    mapping(address => uint256) public validatorIdByAddress;

    modifier onlyValidatorMultiSig() {
        require(
            msg.sender == validatorContractAddress,
            "Caller must be the SmartnodesMultiSig."
        );
        _;
    }

    modifier onlyProxyAdmin() {
        require(msg.sender == proxyAdmin, "Caller must be the proxy admin.");
        _;
    }

    function initialize(address[] memory _genesisNodes) public initializer {
        __ERC20_init("Smartnodes", "SNO");

        // Set the proxy admin as the address that calls the initialize function
        proxyAdmin = msg.sender;

        // Set all counters to 1 (when looking up values, 0 = Not found)
        userCounter = 1;
        jobCounter = 1;
        validatorIdCounter = 1;

        // Set ERC20 token parameters
        emissionRate = 2048e18; // amount of tokens to be emitted per state update
        lockAmount = 100_000e18; // minimum validator locked tokens required
        halving = 8742; // Number of state updates before reward halving
        unlockPeriod = 1_209_600; // (seconds)
        statesSinceLastHalving = 0;

        for (uint i = 0; i < _genesisNodes.length; i++) {
            _mint(_genesisNodes[i], lockAmount);
        }

        // Other parameters
        minValidators = 1;
        maxValidators = 5;
    }

    function setValidatorContract(address validatorAddress) external {
        require(
            validatorContractAddress == address(0),
            "Validator address already set."
        );
        _validatorContractInstance = ISmartnodesMultiSig(validatorAddress);
        validatorContractAddress = validatorAddress;
    }

    /**
     * @dev Create a User, limit one per address & public key hash (RSA)
     */
    function createUser(bytes32 _publicKeyHash) public {
        // Only one address & public key hash per user.
        require(
            userHashByAddress[msg.sender] == bytes32(0),
            "User already registered."
        );

        users[_publicKeyHash] = User({
            userAddress: msg.sender,
            publicKeyHash: _publicKeyHash,
            reputation: 50
        });

        userHashByAddress[msg.sender] = _publicKeyHash;
        userCounter++;
    }

    /**
     * @dev Create a Validator, limit one per address & public key hash (RSA), requires locking up sno
     */
    function createValidator(
        bytes32 _publicKeyHash,
        uint256 _lockAmount
    ) external {
        require(
            validatorIdByAddress[msg.sender] == 0,
            "Validator already exists."
        );

        require(
            balanceOf(msg.sender) >= _lockAmount && _lockAmount >= lockAmount,
            "Insufficient token balance."
        );

        // Create validator on SmartnodesCore
        validators[validatorIdCounter] = Validator({
            publicKeyHash: _publicKeyHash,
            validatorAddress: msg.sender,
            locked: lockAmount,
            unlockTime: 0,
            reputation: 50
        });

        validatorIdByAddress[msg.sender] = validatorIdCounter;
        validatorAddressByHash[_publicKeyHash] = msg.sender;

        // Lock token in contract
        _lockTokens(msg.sender, lockAmount);

        validatorIdCounter++;
    }

    // User Job Requesting Via Chainlink VRF TODO
    function requestJob(
        bytes32 userHash,
        bytes32 jobHash,
        uint256[] calldata _capacities
    ) external returns (uint256[] memory validatorIds) {
        // If user directly requests a job, register if they have not already done so
        if (msg.sender != validatorContractAddress) {
            if (userHashByAddress[msg.sender] == bytes32(0)) {
                createUser(userHash);
                userHash = userHashByAddress[msg.sender];
            }
        }

        require(userHash != bytes32(0), "User not registered!");
        require(jobs[jobHash].author == address(0), "Job already created.");
        // require(_capacities[0] > 0, "Capacity must be greater zero.");

        address[] memory _seedValidators = _validatorContractInstance
            .generateValidators(1);
        uint256[] memory _validatorIds = new uint256[](1); // (_seedValidators.length);

        for (uint256 i = 0; i < _seedValidators.length; i++) {
            _validatorIds[i] = validatorIdByAddress[_seedValidators[i]];
        }

        // Store the job in the jobs mapping
        jobs[jobHash] = Job({
            author: msg.sender,
            seedValidators: _seedValidators,
            workers: new address[](_capacities.length),
            capacities: _capacities,
            activity: true
        });

        emit JobRequested(jobHash, block.timestamp, _seedValidators);
        jobCounter++;

        return _validatorIds;
    }

    function completeJob(
        bytes32 jobHash,
        address[] memory _workers
    ) external onlyValidatorMultiSig returns (uint256[] memory) {
        require(_workers.length == jobs[jobHash].capacities.length);

        jobs[jobHash].workers = _workers;
        jobs[jobHash].activity = false;
        // jobIdByUserHash[userIdHash] = 0;

        emit JobCompleted(jobHash, block.timestamp);

        return jobs[jobHash].capacities;
    }

    function disputeJob(bytes32 jobHash) external onlyValidatorMultiSig {
        Job storage job = jobs[jobHash];
        job.activity = false;
        emit JobDisputed(jobHash, block.timestamp);
    }

    /**
     * @dev Internal function to lock tokens, callable from other functions
     */
    function _lockTokens(address sender, uint256 amount) internal {
        require(amount > 0, "Amount must be greater than zero.");
        require(balanceOf(sender) >= amount, "Insufficient balance.");

        uint256 validatorId = validatorIdByAddress[sender];
        require(validatorId != 0, "Validator does not exist.");

        transferFrom(sender, address(this), amount);
        validators[validatorId].locked += amount;
        uint256 _totalLocked = validators[validatorId].locked;
        totalLocked += _totalLocked;

        emit TokensLocked(sender, amount);
    }

    /**
     * @dev Validator token unlocking, 30 day withdrawal period.
     */
    function lockTokens(uint256 amount) external {
        _lockTokens(msg.sender, amount);
    }

    function unlockTokens(uint256 amount) external {
        uint256 validatorId = validatorIdByAddress[msg.sender];
        require(validatorId > 0, "Not a registered validator.");

        Validator storage validator = validators[validatorId];

        require(amount <= validator.locked, "Amount exceeds locked balance.");
        require(amount > 0, "Amount must be greater than zero.");

        // Initialize the unlock time if it's the first unlock attempt
        if (validator.unlockTime == 0) {
            validator.unlockTime = block.timestamp + unlockPeriod; // unlocking period

            // Update multisig validator
            // uint256 _totalLocked = validator.locked - amount;
            totalLocked -= amount;

            emit UnlockInitiated(msg.sender, validator.unlockTime); // Optional: emit an event
        } else {
            // On subsequent attempts, check if the unlock period has elapsed
            require(
                block.timestamp >= validator.unlockTime,
                "Tokens are still locked."
            );

            validator.locked -= amount;
            _mint(msg.sender, amount); // Mint tokens back to the validator's address

            emit TokensUnlocked(msg.sender, amount); // Optional: emit an event when tokens are unlocked
        }
    }

    /**
     * @dev Mint tokens for updating state rewards, distribute 40/60 among validators and workers
     * Updates the emission rate and halving accordingly
     */
    function mintTokens(
        address[] memory _workers,
        uint256[] memory _workerCapacities,
        uint256 _totalCapacity,
        address[] memory _validatorsVoted
    ) external onlyValidatorMultiSig {
        if (statesSinceLastHalving >= halving) {
            if (emissionRate > TAIL_EMISSION) {
                emissionRate /= 2;
            }
        }

        uint256 validatorRewardTotal = (emissionRate * 20) / 100;
        uint256 workerRewardTotal = (emissionRate * 80) / 100;

        // Distribute rewards for validators equally
        uint256 validatorReward = validatorRewardTotal /
            _validatorsVoted.length;

        for (uint256 v = 0; v < _validatorsVoted.length; v++) {
            _mint(_validatorsVoted[v], validatorReward);
        }

        // Distribute rewards for workers
        for (uint256 w = 0; w < _workers.length; w++) {
            uint256 reward = ((_workerCapacities[w] * workerRewardTotal) /
                _totalCapacity);
            _mint(_workers[w], reward);
        }

        statesSinceLastHalving++;
    }

    function halveStateTime() external onlyProxyAdmin {
        emissionRate /= 2; // Halve the emission rate
        halving *= 2; // Double the state updates requied between halvings
        _validatorContractInstance.halvePeriod(); // Halve the time required between state updates
    }

    function getValidatorInfo(
        uint256 _validatorId
    ) external view returns (bool, bytes32, address) {
        require(_validatorId < validatorIdCounter, "Invalid ID.");
        Validator memory _validator = validators[_validatorId];
        bool isActive = _validatorContractInstance.isActiveValidator(
            _validator.validatorAddress
        );
        return (
            isActive,
            _validator.publicKeyHash,
            _validator.validatorAddress
        );
    }

    function getValidatorBytes(
        address validatorAddress
    ) external view returns (bytes32) {
        uint256 validatorId = validatorIdByAddress[validatorAddress];
        require(validatorId > 0, "Validator does not exist.");

        return validators[validatorId].publicKeyHash;
    }

    function getUserCount() external view returns (uint256) {
        return userCounter - 1;
    }

    function getValidatorCount() external view returns (uint256) {
        return validatorIdCounter - 1;
    }

    function getActiveValidatorCount() external view returns (uint256) {
        return _validatorContractInstance.getNumValidators();
    }

    function getEmissionRate() external view returns (uint256) {
        return emissionRate;
    }

    function getSupply() external view returns (uint256) {
        return this.totalSupply();
    }

    function isLocked(address validatorAddr) external view returns (bool) {
        uint256 _id = validatorIdByAddress[validatorAddr];
        return validators[_id].locked >= lockAmount;
    }

    function getProposees() external view returns (address[] memory) {
        return _validatorContractInstance.getSelectedValidators();
    }

    function getState()
        external
        view
        returns (uint256, uint256, uint256, address[] memory)
    {
        return _validatorContractInstance.getState();
    }
}
