// SPDX-License-Identifier: MIT
pragma solidity ^0.8.5;

import "@openzeppelin-upgradeable/contracts/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin-upgradeable/contracts/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin-upgradeable/contracts/security/PausableUpgradeable.sol";
import "@openzeppelin-upgradeable/contracts/access/OwnableUpgradeable.sol";
import "./interfaces/ISmartnodesMultiSig.sol";

contract SmartnodesCore is
    ERC20Upgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable,
    OwnableUpgradeable
{
    error InsufficientBalance();
    error InvalidAmount();
    error InvalidLength();
    error NoValidators();
    error NoRewards();
    error TokensStillLocked();
    error ValidatorNotFound();
    error UnauthorizedCaller();
    error ZeroAddress();
    error ValidatorAlreadyExists();
    error ContractAlreadyInitialized();
    error StateUpdateTooFrequent();

    ISmartnodesMultiSig public validatorContract;
    address public proxyAdmin;

    uint256 public constant UNLOCK_PERIOD = 1_209_600; // 14 days in seconds
    uint256 public constant VALIDATOR_REWARD_PERCENTAGE = 20;
    uint256 public constant INITIAL_LOCK_AMOUNT = 500_000e18;
    uint256 public constant INITIAL_EMISSION_RATE = 4096e18;

    uint256 public halvingPeriod;
    uint256 public tailEmission;
    uint256 public emissionRate;
    uint256 public statesSinceLastHalving;
    uint256 public totalLocked;
    uint256 public totalUnclaimed;
    uint256 public jobCounter;
    uint24 public validatorCounter;
    uint64 public userCounter;
    uint256 public lockAmount;
    uint256 public lastStateUpdateTimestamp;
    uint8 public halvingCounter;

    struct Validator {
        uint256 locked;
        uint256 unlockTime; // Changed from uint24 to uint256 for timestamp compatibility
        bytes32 publicKeyHash;
        bool exists;
    }

    struct Job {
        uint256[] capacities;
        uint256 payment;
        bool exists;
        address requester;
    }

    mapping(bytes32 => Job) public jobs;
    mapping(address => Validator) public validators;
    mapping(address => uint256) public unclaimedRewards;

    event TokensLocked(address indexed validator, uint256 amount);
    event UnlockInitiated(address indexed validator, uint256 unlockTime);
    event TokensUnlocked(address indexed validator, uint256 amount);
    event JobRequested(
        bytes32 indexed jobHash,
        bytes32 userHash,
        address indexed requester
    );
    event JobCompleted(bytes32 indexed jobHash, uint256 reward);
    event JobCancelled(bytes32 indexed jobHash, address indexed requester);
    event RewardsClaimed(address indexed sender, uint256 amount);
    event StateUpdate(
        uint256[] networkWorkers,
        uint256[] networkCapacities,
        uint24 activeValidators,
        uint64 numUsers
    );
    event EmissionRateUpdated(uint256 newRate);
    event ValidatorContractSet(address indexed validatorContract);
    event LockAmountChanged(uint256 newAmount);

    modifier onlyValidatorMultiSig() {
        if (msg.sender != address(validatorContract))
            revert UnauthorizedCaller();
        _;
    }

    modifier onlyProxyAdmin() {
        if (msg.sender != proxyAdmin) revert UnauthorizedCaller();
        _;
    }

    function initialize(address[] memory _genesisNodes) external initializer {
        __ERC20_init("Smartnodes", "SNO");
        __ReentrancyGuard_init();
        __Pausable_init();
        __Ownable_init();

        proxyAdmin = msg.sender;
        emissionRate = INITIAL_EMISSION_RATE;
        lockAmount = INITIAL_LOCK_AMOUNT;
        halvingPeriod = 8742; // 364.25 * 24
        tailEmission = 128e18;

        jobCounter = 1;
        validatorCounter = 1;
        userCounter = 1;
        lastStateUpdateTimestamp = 1;

        for (uint i = 0; i < _genesisNodes.length; ) {
            if (_genesisNodes[i] == address(0)) revert ZeroAddress();
            _mint(_genesisNodes[i], INITIAL_LOCK_AMOUNT);
            unchecked {
                ++i;
            }
        }
    }

    function requestJob(
        bytes32 userHash,
        bytes32 jobHash,
        uint256[] calldata capacities,
        uint256 paymentAmount
    ) external whenNotPaused {
        if (paymentAmount == 0) revert InvalidAmount();
        if (balanceOf(msg.sender) < paymentAmount) revert InsufficientBalance();
        if (jobs[jobHash].exists) revert("Job already exists");

        // Transfer the payment tokens to contract instead of burning
        _transfer(msg.sender, address(this), paymentAmount);

        jobs[jobHash] = Job({
            capacities: capacities,
            payment: paymentAmount,
            exists: true,
            requester: msg.sender
        });

        emit JobRequested(jobHash, userHash, msg.sender);
        unchecked {
            ++jobCounter;
        }
    }

    function cancelJob(bytes32 jobHash) external whenNotPaused nonReentrant {
        Job storage job = jobs[jobHash];
        if (!job.exists) revert InvalidAmount();
        if (job.requester != msg.sender) revert UnauthorizedCaller();

        uint256 payment = job.payment;
        delete jobs[jobHash];

        // Return tokens instead of minting new ones
        _transfer(address(this), msg.sender, payment);

        emit JobCancelled(jobHash, msg.sender);
    }

    function completeJob(
        bytes32 jobHash
    ) public onlyValidatorMultiSig whenNotPaused returns (uint256) {
        Job memory job = jobs[jobHash];
        uint256 totalReward = job.payment;

        emit JobCompleted(jobHash, totalReward);
        jobCounter += 1;

        if (!job.exists) return 0;

        delete jobs[jobHash];

        return totalReward;
    }

    function updateContract(
        bytes32[] memory jobHashes,
        address[] memory workers,
        uint256[] memory capacities,
        uint256[] memory allCapacities,
        uint256[] memory allWorkers,
        address[] memory validatorsVoted
    ) external onlyValidatorMultiSig nonReentrant whenNotPaused {
        if (workers.length != capacities.length) revert InvalidLength();
        if (validatorsVoted.length == 0) revert NoValidators();

        // Update emission rate if needed
        if (statesSinceLastHalving >= halvingPeriod) {
            if (emissionRate > tailEmission) {
                emissionRate /= 2;
                if (halvingCounter == 2) {
                    halvingPeriod *= 2;
                    halvingCounter = 3;
                } else if (halvingCounter < 2) {
                    halvingCounter++;
                }

                emit EmissionRateUpdated(emissionRate);
            }
            statesSinceLastHalving = 0;
        }

        // allCapacities contains total capacities of each network, we must summate them
        uint256 totalCapacity = 0;
        for (uint i = 0; i < allCapacities.length; i++) {
            totalCapacity += allCapacities[i];
        }

        uint256 totalWorkers = 0;
        for (uint i = 0; i < allWorkers.length; i++) {
            totalWorkers += allWorkers[i];
        }

        // Process rewards
        uint256 additionalReward = _processCompletedJobs(jobHashes);
        _distributeRewards(
            workers,
            capacities,
            validatorsVoted,
            additionalReward
        );

        emit StateUpdate(
            allWorkers,
            allCapacities,
            validatorCounter - 1,
            userCounter - 1
        );

        unchecked {
            ++statesSinceLastHalving;
        }
    }

    function _processCompletedJobs(
        bytes32[] memory jobHashes
    ) internal returns (uint256) {
        uint256 additionalReward = 0;
        for (uint i = 0; i < jobHashes.length; ) {
            additionalReward += completeJob(jobHashes[i]);
            unchecked {
                ++i;
            }
        }
        return additionalReward;
    }

    function _distributeRewards(
        address[] memory _workers,
        uint256[] memory _capacities,
        address[] memory _validatorsVoted,
        uint256 additionalReward
    ) internal {
        uint256 totalReward = emissionRate + additionalReward;
        uint256 validatorReward;
        uint256 workerReward;

        if (_workers.length == 0) {
            validatorReward = totalReward;
        } else {
            validatorReward = (totalReward * VALIDATOR_REWARD_PERCENTAGE) / 100;
            workerReward = totalReward - validatorReward;
        }

        totalUnclaimed += totalReward;

        // Distribute validator rewards
        if (_validatorsVoted.length > 0) {
            uint256 validatorShare = validatorReward / _validatorsVoted.length;
            for (uint256 i = 0; i < _validatorsVoted.length; i++) {
                unclaimedRewards[_validatorsVoted[i]] += validatorShare;
                unchecked {
                    ++i;
                }
            }
        }

        // Distribute worker rewards
        if (_workers.length > 0) {
            uint256 _totalCapacity = 0;

            // First pass: Calculate total capacity
            for (uint256 i = 0; i < _workers.length; i++) {
                _totalCapacity += _capacities[i];
            }

            // Ensure total capacity is greater than zero to avoid division by zero
            require(
                _totalCapacity > 0,
                "Total capacity must be greater than 0"
            );

            // Second pass: Distribute rewards
            for (uint256 i = 0; i < _workers.length; i++) {
                uint256 reward = (_capacities[i] * workerReward) /
                    _totalCapacity;
                unclaimedRewards[_workers[i]] += reward;
            }
        }
    }

    function claimRewards() external nonReentrant {
        uint256 amount = unclaimedRewards[msg.sender];
        if (amount == 0) revert NoRewards();

        unclaimedRewards[msg.sender] = 0;
        totalUnclaimed -= amount;
        _mint(msg.sender, amount);

        emit RewardsClaimed(msg.sender, amount);
    }

    /**
     * @dev Validator token unlocking, 14 day withdrawal period.
     */
    function _lockTokens(address sender, uint256 amount) internal {
        require(amount > 0, "Amount must be greater than zero.");
        require(balanceOf(sender) >= amount, "Insufficient balance.");
        require(
            validators[sender].publicKeyHash != bytes32(0),
            "Validator does not exist."
        );

        transferFrom(sender, address(this), amount);
        validators[sender].locked += amount;
        totalLocked += amount;

        emit TokensLocked(sender, amount);
    }

    function lockTokens(uint256 amount) external {
        _lockTokens(msg.sender, amount);
    }

    function unlockTokens(uint256 amount) external nonReentrant {
        Validator storage validator = validators[msg.sender];

        require(
            validators[msg.sender].publicKeyHash != bytes32(0),
            "Validator does not exist."
        );
        require(amount <= validator.locked, "Amount exceeds locked balance.");
        require(amount > 0, "Amount must be greater than zero.");

        // Initialize the unlock time if it's the first unlock attempt
        if (validator.unlockTime == 0) {
            if (validator.locked < lockAmount) {
                validatorContract.removeValidator(msg.sender);
            }
            validator.unlockTime = block.timestamp + UNLOCK_PERIOD; // unlocking period

            // Update multisig validator
            totalLocked -= amount;

            emit UnlockInitiated(msg.sender, validator.unlockTime); // Optional: emit an event
        } else {
            // On subsequent attempts, check if the unlock period has elapsed
            require(
                block.timestamp >= validator.unlockTime,
                "Tokens are still locked."
            );

            validator.locked -= amount;
            _transfer(address(this), msg.sender, amount);
            emit TokensUnlocked(msg.sender, amount); // Optional: emit an event when tokens are unlocked
        }
    }

    function createValidator(
        bytes32 _publicKeyHash,
        uint256 _lockAmount
    ) external {
        require(
            balanceOf(msg.sender) >= _lockAmount && _lockAmount >= lockAmount,
            "Insufficient token balance."
        );
        require(
            validators[msg.sender].publicKeyHash == bytes32(0),
            "Validator already created with this account!"
        );

        validators[msg.sender] = Validator({
            locked: 0,
            unlockTime: 0,
            publicKeyHash: _publicKeyHash,
            exists: true
        });

        _lockTokens(msg.sender, lockAmount);
        validatorCounter++;
    }

    function isLocked(address validatorAddress) external view returns (bool) {
        return validators[validatorAddress].locked >= lockAmount;
    }

    /**
     * @notice View function to check unclaimed rewards
     */
    function getUnclaimedRewards(address user) external view returns (uint256) {
        return unclaimedRewards[user];
    }

    function getLockedBalance(
        address validatorAddress
    ) external view returns (uint256) {
        Validator memory validator = validators[validatorAddress];
        return validator.locked;
    }

    function getActiveValidatorCount() external view returns (uint256) {
        return validatorContract.getNumValidators();
    }

    function getValidatorInfo(
        address validatorAddress
    ) external view returns (bool, bytes32) {
        Validator memory _validator = validators[validatorAddress];
        bool isActive = validatorContract.isActiveValidator(validatorAddress);
        return (isActive, _validator.publicKeyHash);
    }

    function setValidatorContract(address _validatorAddress) external {
        require(
            address(validatorContract) == address(0),
            "Validator address already set."
        );
        validatorContract = ISmartnodesMultiSig(_validatorAddress);
    }

    function getSupply() external view returns (uint256, uint256, uint256) {
        return (this.totalSupply(), totalLocked, totalUnclaimed);
    }

    function halveStateTime() external onlyProxyAdmin {
        // By reducing the state time in half, we must reduce emissions (ie. state reward)
        // by half, including the tail emission value
        tailEmission /= 2;
        emissionRate /= 2;
        halvingPeriod *= 2; // Double the state updates requied between halvings
        validatorContract.halvePeriod(); // Halve the time required between state updates
    }

    function doubleStateTime() external onlyProxyAdmin {
        tailEmission *= 2;
        emissionRate *= 2;
        halvingPeriod /= 2; // Double the state updates requied between halvings
        validatorContract.doublePeriod(); // Halve the time required between state updates
    }

    function changeLockAmount(uint256 amount) external onlyProxyAdmin {
        lockAmount = amount;
    }
}
