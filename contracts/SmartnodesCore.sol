// SPDX-License-Identifier: MIT
pragma solidity ^0.8.5;

import "@openzeppelin-upgradeable/contracts/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin-upgradeable/contracts/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin-upgradeable/contracts/security/PausableUpgradeable.sol";
import "./interfaces/ISmartnodesMultiSig.sol";

contract SmartnodesCore is
    ERC20Upgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable
{
    ISmartnodesMultiSig public validatorContract;
    address public proxyAdmin;

    uint256 public tailEmission = 64e18;
    uint256 public constant UNLOCK_PERIOD = 1_209_600; // 14 days in seconds

    uint256 public emissionRate;
    uint256 public lockAmount;
    uint256 public halvingPeriod;
    uint256 public statesSinceLastHalving;
    uint256 public totalLocked;

    struct Validator {
        uint256 locked;
        uint256 unlockTime;
        bytes32 publicKeyHash;
    }

    struct Job {
        uint256[] capacities;
        uint256 payment;
    }

    mapping(bytes32 => Job) public jobs;
    mapping(address => Validator) public validators;
    mapping(address => uint256) public unclaimedRewards;

    uint256 public jobCounter;
    uint24 public validatorCounter;
    uint256 public userCounter;

    event TokensLocked(address validator, uint256 amount);
    event UnlockInitiated(address indexed validator, uint256 unlockTime);
    event TokensUnlocked(address indexed validator, uint256 amount);
    event JobRequested(bytes32 jobHash, bytes32 userHash);
    event JobCompleted(bytes32 jobHash);
    event JobDisputed(bytes32 indexed jobHash, uint256 timestamp);
    event RewardsClaimed(address indexed sender, uint256 amount);

    modifier onlyValidatorMultiSig() {
        require(
            msg.sender == address(validatorContract),
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
        __ReentrancyGuard_init();
        __Pausable_init();

        proxyAdmin = msg.sender;

        // Set initial values with validation
        emissionRate = 2048e18;
        lockAmount = 500_000e18;
        halvingPeriod = 8742; // 364.25 * 24 (once a year if done every hour)

        tailEmission = 64e18;
        statesSinceLastHalving = 0;
        jobCounter = 1;
        validatorCounter = 1;
        userCounter = 1;

        for (uint i = 0; i < _genesisNodes.length; i++) {
            _mint(_genesisNodes[i], lockAmount);
        }
    }

    // Request a job and associate a payment with it
    // function requestJob(
    //     bytes32 userHash,
    //     bytes32 jobHash,
    //     uint256[] calldata capacities,
    //     uint256 paymentAmount // Accept payment in tokens
    // ) external {
    //     require(jobHashToId[jobHash] == 0, "Job already created!");
    //     require(capacities.length > 0, "Job must have a capacity.");
    //     jobHashToId[jobHash] = jobCounter;

    //     // Require a payment for the job
    //     require(paymentAmount > 0, "Payment must be greater than zero.");
    //     require(
    //         balanceOf(msg.sender) >= paymentAmount,
    //         "Insufficient token balance."
    //     );
    //     require(capacities.length > 0, "");

    //     // Transfer the payment tokens and burn them
    //     _transfer(msg.sender, address(0), paymentAmount); // Burn the tokens by sending to zero address

    //     // Store the job with associated payment
    //     jobs[jobCounter] = Job({
    //         capacities: capacities,
    //         payment: paymentAmount // Store the payment amount
    //     });

    //     emit JobRequested(jobCounter, jobHash, userHash);
    //     jobCounter++;
    // }

    // Complete the job and distribute payment to validators/workers
    function completeJob(
        bytes32 jobHash
    ) external onlyValidatorMultiSig returns (uint256) {
        // Get the job and calculate reward
        Job memory job = jobs[jobHash];

        // If we have free a p2p-requested job, update counter
        if (job.payment == 0) {
            jobCounter++;
            emit JobCompleted(jobHash);
            return 0;
        }

        uint256 totalReward = job.payment;
        delete jobs[jobHash];
        emit JobCompleted(jobHash);
        return totalReward;
    }

    /**
     * @notice Records rewards for later claiming by workers/validators thru mint function
     */
    function recordRewards(
        address[] memory _workers,
        uint256[] memory _capacities,
        uint256 _totalCapacity,
        address[] memory _validatorsVoted,
        uint256 additionalReward
    ) external onlyValidatorMultiSig nonReentrant whenNotPaused {
        require(_workers.length == _capacities.length, "Length mismatch");
        require(_validatorsVoted.length > 0, "No validators");
        require(_totalCapacity > 0 || _workers.length == 0, "Invalid capacity");

        if (statesSinceLastHalving >= halvingPeriod) {
            // If we have hit the halving period, reduce the reward by half
            if (emissionRate > tailEmission) {
                emissionRate /= 2;
            }
            statesSinceLastHalving = 0;
        }

        // Calculate total amount to allocate to workers and validators
        uint256 validatorReward;
        uint256 workerReward;
        uint256 totalReward = emissionRate + additionalReward;

        if (_workers.length == 0) {
            validatorReward = totalReward;
            workerReward = 0;
        } else {
            validatorReward = (totalReward * 20) / 100;
            workerReward = totalReward - validatorReward;
        }

        // Record validator rewards
        uint256 validatorShare = validatorReward / _validatorsVoted.length;
        for (uint256 v = 0; v < _validatorsVoted.length; v++) {
            address validator = _validatorsVoted[v];
            unclaimedRewards[validator] += validatorShare;
        }

        // Record worker rewards
        if (_workers.length > 0) {
            uint256 remainingWorkerReward = workerReward;
            for (uint256 i = 0; i < _workers.length - 1; i++) {
                address worker = _workers[i];
                uint256 reward = (_capacities[i] * workerReward) /
                    _totalCapacity;
                unclaimedRewards[worker] += reward;
                remainingWorkerReward -= reward;
            }
            // Give remaining reward to last worker to handle rounding
            unclaimedRewards[
                _workers[_workers.length - 1]
            ] += remainingWorkerReward;
        }

        statesSinceLastHalving++;
    }

    /**
     * @notice Allows users to claim their accumulated rewards
     */
    function claimRewards() external {
        uint256 amount = unclaimedRewards[msg.sender];
        require(amount > 0, "No rewards to claim");

        unclaimedRewards[msg.sender] = 0;
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
            publicKeyHash: _publicKeyHash
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
