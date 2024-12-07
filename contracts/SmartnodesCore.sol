// SPDX-License-Identifier: MIT
pragma solidity ^0.8.5;

import "@openzeppelin-upgradeable/contracts/token/ERC20/ERC20Upgradeable.sol";
import "./interfaces/ISmartnodesMultiSig.sol";

contract SmartnodesCore is ERC20Upgradeable {
    ISmartnodesMultiSig public validatorContract;
    address public proxyAdmin;

    uint256 public tailEmission = 8e18; // a relative number as the state-time can be adjusted. Equivalent to
    uint256 public constant UNLOCK_PERIOD = 1_209_600; // 14 days in seconds

    uint256 public emissionRate;
    uint256 public lockAmount;
    uint256 public halvingPeriod;
    uint256 public statesSinceLastHalving;
    uint256 public totalLocked;
    uint256 public unlockPeriod;

    struct Validator {
        address _address;
        uint256 locked;
        uint256 unlockTime;
        bytes32 publicKeyHash;
    }

    struct Job {
        uint256[] capacities;
        uint256 payment;
    }

    mapping(bytes32 => uint256) public jobHashToId;
    mapping(uint256 => Job) public jobs;
    mapping(uint256 => Validator) public validators;
    mapping(address => uint256) public validatorIdByAddress;

    uint256 public jobCounter;
    uint256 public userCounter;
    uint256 public validatorCounter;
    uint256 public availableCapacity;

    event TokensLocked(address validator, uint256 amount);
    event UnlockInitiated(address indexed validator, uint256 unlockTime);
    event TokensUnlocked(address indexed validator, uint256 amount);
    event JobRequested(uint256 jobId, bytes32 jobHash, bytes32 userHash);
    event JobCompleted(uint256 jobId, bytes32 jobHash);
    event JobDisputed(bytes32 indexed jobId, uint256 timestamp);

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
        proxyAdmin = msg.sender;
        emissionRate = 2048e18;
        lockAmount = 500_000e18;
        halvingPeriod = 8742; // 364.25 * 24
        statesSinceLastHalving = 0;
        unlockPeriod = 1_209_600; // (14 days in seconds)

        jobCounter = 1;
        validatorCounter = 1;
        userCounter = 1;

        for (uint i = 0; i < _genesisNodes.length; i++) {
            _mint(_genesisNodes[i], lockAmount);
        }
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
        uint256 jobId = jobHashToId[jobHash];

        // If we have a user-requested job
        if (jobId == 0) {
            // If not, we can log the job counter
            jobCounter++;
            emit JobCompleted(jobId, jobHash);
            return 0;
        }

        // Get the job and calculate reward
        Job memory job = jobs[jobId];
        uint256 totalReward = job.payment;

        // Cleanup
        delete jobs[jobId];
        delete jobHashToId[jobHash];
        emit JobCompleted(jobId, jobHash);
        return totalReward;
    }

    function mintTokens(
        address[] memory _workers,
        uint256[] memory _capacities,
        uint256 _totalCapacity,
        address[] memory _validatorsVoted,
        uint256 additionalReward
    ) external onlyValidatorMultiSig {
        if (statesSinceLastHalving >= halvingPeriod) {
            if (emissionRate > tailEmission) {
                emissionRate /= 2;
            }
        }

        uint256 validatorReward;
        uint256 workerReward;

        if (_workers.length == 0) {
            validatorReward = emissionRate + additionalReward;
            workerReward = 0;
        } else {
            validatorReward = ((emissionRate + additionalReward) * 25) / 100;
            workerReward = ((emissionRate + additionalReward) * 75) / 100;
        }

        for (uint256 v = 0; v < _validatorsVoted.length; v++) {
            _mint(
                _validatorsVoted[v],
                validatorReward / _validatorsVoted.length
            );
        }

        if (_workers.length > 0) {
            for (uint256 w = 0; w < _workers.length; w++) {
                uint256 reward = ((_capacities[w] * workerReward) /
                    _totalCapacity);
                _mint(_workers[w], reward);
            }
        }

        statesSinceLastHalving++;
    }

    /**
     * @dev Validator token unlocking, 14 day withdrawal period.
     */
    function _lockTokens(address sender, uint256 amount) internal {
        require(amount > 0, "Amount must be greater than zero.");
        require(balanceOf(sender) >= amount, "Insufficient balance.");

        uint256 validatorId = validatorIdByAddress[sender];
        require(validatorId != 0, "Validator does not exist.");

        transferFrom(sender, address(this), amount);
        validators[validatorId].locked += amount;
        totalLocked += amount;

        emit TokensLocked(sender, amount);
    }

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
            if (validator.locked < lockAmount) {
                validatorContract.removeValidator(msg.sender);
            }
            validator.unlockTime = block.timestamp + unlockPeriod; // unlocking period

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
            transferFrom(address(this), msg.sender, amount); // Mint tokens back to the validator's address

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
            validatorIdByAddress[msg.sender] == 0,
            "Validator already created with this account!"
        );

        validators[validatorCounter] = Validator({
            _address: msg.sender,
            locked: 0,
            unlockTime: 0,
            publicKeyHash: _publicKeyHash
        });

        validatorIdByAddress[msg.sender] = validatorCounter;
        _lockTokens(msg.sender, lockAmount);

        validatorCounter++;
    }

    function isLocked(address validatorAddress) external view returns (bool) {
        uint256 id = validatorIdByAddress[validatorAddress];
        return validators[id].locked >= lockAmount;
    }

    function getActiveValidatorCount() external view returns (uint256) {
        return validatorContract.getNumValidators();
    }

    function getValidatorInfo(
        uint256 _validatorId
    ) external view returns (bool, bytes32, address) {
        require(_validatorId < validatorCounter, "Invalid ID.");
        Validator memory _validator = validators[_validatorId];
        bool isActive = validatorContract.isActiveValidator(
            _validator._address
        );
        return (isActive, _validator.publicKeyHash, _validator._address);
    }
}
