// SPDX-License-Identifier: MIT
pragma solidity ^0.8.5;

import "@openzeppelin-upgradeable/contracts/proxy/utils/Initializable.sol";
import "@openzeppelin-upgradeable/contracts/interfaces/IERC20Upgradeable.sol";
import "@openzeppelin-upgradeable/contracts/security/ReentrancyGuardUpgradeable.sol";
import "./interfaces/ISmartnodesCore.sol";

/** 
    * @title SmartnodesMultiSig
    * @dev A multi-signature contract composed of Smartnodes validators responsible for
     managing the Core contract
*/
contract SmartnodesMultiSig is Initializable, ReentrancyGuardUpgradeable {
    // State update constraints
    uint256 public updateTime = 1800; // 30 minutes minimum required between state updates
    uint256 public roundExpirationTime = 3600; // 60 minutes until proposal expires
    uint256 public requiredApprovalsPercentage;
    uint256 public requiredApprovals;
    uint256 public lastProposalTime; // time of last executed proposal
    uint256 public nextProposalId;

    // Metadata and bytecode for SmartNodes calls
    ISmartnodesCore private _smartnodesContractInstance;
    address public smartnodesContractAddress;

    // Counters for storage indexing / IDs
    uint8 public nValidators;
    address[] public validators;
    address[] public currentRoundValidators;
    bytes32[] public currentProposals;
    uint8[] public readyProposals;

    // Added mapping to track proposal creation times
    mapping(address => bool) public isValidator;
    mapping(address => uint8) public hasSubmittedProposal;
    mapping(address => uint8) public hasVoted;
    mapping(uint8 => uint256) public proposalVotes;

    event ProposalExecuted(
        uint256 indexed proposalId,
        bytes32 proposalHash,
        uint256[] networkCapacities,
        uint256 workers
    );
    event ProposalExpired(uint256 proposalId);
    event Deposit(address indexed sender, uint amount);
    event ValidatorAdded(address validator);
    event ValidatorRemoved(address validator);

    /**
     * @dev Ensures caller is a registered validator
     */
    modifier onlyValidator() {
        require(isValidator[msg.sender], "Not a validator");
        _;
    }

    /**
     * @dev Ensures caller is the core contract
     */
    modifier onlySmartnodesCore() {
        require(msg.sender == smartnodesContractAddress, "Not core contract");
        _;
    }

    /**
     * @dev Allows only current round validators, or any validator if round has expired.
     */
    modifier onlyEligibleValidator() {
        bool isSelectedValidator = _isCurrentRoundValidator(msg.sender);
        bool _isRoundExpired = _isCurrentRoundExpired();

        require(
            isSelectedValidator || (isValidator[msg.sender] && _isRoundExpired),
            "Not eligible to submit proposal."
        );

        require(
            hasSubmittedProposal[msg.sender] == 0,
            "Validator has already submitted a proposal this round."
        );

        if (_isRoundExpired) {
            _cleanupExpiredRound();
        }

        _;
    }

    /**
     * @notice Initializes the contract
     * @param target Address of the SmartNodes core contract
     */
    function initialize(
        address target // Address of the main contract (Smart Nodes)
    )
        public
        // address _vrfCoordinator,
        // uint64 _subscriptionId
        initializer
    {
        smartnodesContractAddress = target;
        updateTime = 1800;
        roundExpirationTime = 3600; // 1 hour until proposal expires
        _smartnodesContractInstance = ISmartnodesCore(target);

        lastProposalTime = 0;
        requiredApprovalsPercentage = 66;
        nValidators = 1;
        nextProposalId = 0;
    }

    receive() external payable {
        emit Deposit(msg.sender, msg.value);
    }

    /**
     * @notice Creates a new proposal, to update all the essential data structures given some aggregated off-chain state.
     */
    function createProposal(
        bytes32 proposalHash
    ) external onlyEligibleValidator nonReentrant {
        // Only allow proposals starting 5m from update window
        require(
            block.timestamp - lastProposalTime >= updateTime - 120,
            "Proposal must be submitted updateTime - 2mins after last execution"
        );

        currentProposals.push(proposalHash);
        uint8 proposalNum = uint8(currentProposals.length);
        hasSubmittedProposal[msg.sender] = proposalNum;
    }

    /**
     * @notice Internal function to clean up expired round
     */
    function _cleanupExpiredRound() internal {
        // Reset all validator states
        for (uint256 i = 0; i < validators.length; i++) {
            hasVoted[validators[i]] = 0;
            hasSubmittedProposal[validators[i]] = 0;
        }

        // Clear all proposals and votes
        while (currentProposals.length > 0) {
            uint8 proposalNum = uint8(currentProposals.length);
            proposalVotes[proposalNum] = 0;
            currentProposals.pop();
        }

        // Clear ready proposals
        delete readyProposals;
    }

    /**
     * @notice Checks if a round has expired
     */
    function isRoundExpired() public view returns (bool) {
        return block.timestamp - lastProposalTime > roundExpirationTime;
    }

    /**
     * @notice Allows updating the proposal expiration time
     */
    function setProposalExpirationTime(
        uint256 newExpirationTime
    ) external onlySmartnodesCore {
        require(
            newExpirationTime >= updateTime,
            "Expiration time must be >= update time"
        );
        roundExpirationTime = newExpirationTime;
    }

    /**
     * @notice Casts a vote for a proposal and executes once required approvals are met. Add Validator to storage
      if it has just registered and is not stored on MultiSig. 
     * @param proposalNum The ID of the current round proposal
     */
    function approveTransaction(uint8 proposalNum) external onlyValidator {
        require(hasVoted[msg.sender] == 0, "Validator has already voted!");
        require(
            currentProposals.length >= proposalNum && proposalNum > 0,
            "Invalid proposal number!"
        );

        if (isValidator[msg.sender] == false) {
            addValidator(msg.sender);
        }

        hasVoted[msg.sender] = proposalNum;
        proposalVotes[proposalNum]++;

        if (proposalVotes[proposalNum] >= requiredApprovals) {
            readyProposals.push(proposalNum);
        }
    }

    /**
     * @notice Executes a proposal if it has enough approvals.
     */
    function executeProposal(
        address[] memory validatorsToRemove,
        bytes32[] memory jobHashes,
        uint256[] memory jobCapacities,
        address[] memory workers,
        uint256[] memory totalCapacities
    ) external onlyValidator nonReentrant {
        uint8 proposalNum = hasSubmittedProposal[msg.sender];
        require(proposalNum > 0, "Must be a proposal creator!");
        require(
            proposalVotes[proposalNum] >= requiredApprovals,
            "Not enough proposal votes!"
        );

        // totalCapacities contains total capacities of each network, we must summate them
        uint256 totalCapacity = 0;
        for (uint i = 0; i < totalCapacities.length; i++) {
            totalCapacity += totalCapacities[i];
        }

        bytes32 providedHash = currentProposals[proposalNum - 1];
        bytes32 proposalHash = hashProposalData(
            validatorsToRemove,
            jobHashes,
            jobCapacities,
            workers,
            totalCapacity
        );
        require(
            proposalHash == providedHash,
            "Proposal data doesn't match initial hash!"
        );

        if (validatorsToRemove.length > 0) {
            for (uint i = 0; i < validatorsToRemove.length; i++) {
                _removeValidator(validatorsToRemove[i]);
            }
        }

        uint256 additionalReward = 0;

        if (jobHashes.length > 0) {
            for (uint i = 0; i < jobHashes.length; i++) {
                uint256 reward = _smartnodesContractInstance.completeJob(
                    jobHashes[i]
                );
                additionalReward += reward;
            }
        }

        address[] memory _approvedValidators = new address[](
            proposalVotes[proposalNum]
        );

        for (uint i = 0; i < validators.length; i++) {
            address validator = validators[i];

            if (hasVoted[validator] == proposalNum) {
                _approvedValidators[i] = validator;
            }
        }

        // Call mint function to generate rewards for workers and validators
        _smartnodesContractInstance.recordRewards(
            workers,
            jobCapacities,
            totalCapacity,
            _approvedValidators,
            additionalReward
        );

        emit ProposalExecuted(
            nextProposalId,
            proposalHash,
            totalCapacities,
            workers.length
        );
        _updateRound();
    }

    function hashProposalData(
        address[] memory validatorsToRemove,
        bytes32[] memory jobHashes,
        uint256[] memory jobCapacities,
        address[] memory workers,
        uint256 totalCapacity
    ) public pure returns (bytes32) {
        require(
            workers.length == jobCapacities.length,
            "Workers and capacities length mismatch"
        );

        return
            keccak256(
                abi.encode(
                    validatorsToRemove,
                    jobHashes,
                    jobCapacities,
                    workers,
                    totalCapacity
                )
            );
    }

    /**
     * @notice Adds a new validator to the contract, must be staked on SmartnodesCore.
     * @param validator The address of the new validator
     */
    function addValidator(address validator) public {
        require(
            _smartnodesContractInstance.isLocked(validator),
            "Validator must be registered and locked on SmartnodesCore!"
        );
        require(
            !isValidator[validator],
            "Validator already registered on Multsig!"
        );

        validators.push(validator);
        isValidator[validator] = true;
        _updateApprovalRequirements();

        emit ValidatorAdded(validator);
    }

    function removeValidator(address validator) external onlyValidator {
        require(msg.sender == validator, "Cannot remove another validator!");
        _removeValidator(validator);
    }

    /**
     * @dev Update the number of required approvals (66% of the active validators)
     */
    function _updateApprovalRequirements() internal {
        requiredApprovals =
            (validators.length * requiredApprovalsPercentage) /
            100;

        if (requiredApprovals < 1) {
            requiredApprovals = 1; // Ensure at least 1 approval is required
        }
    }

    function _removeValidator(address validator) private {
        require(isValidator[validator], "Validator not registered!");
        isValidator[validator] = false;

        for (uint i = 0; i < validators.length; i++) {
            if (validators[i] == validator) {
                validators[i] = validators[validators.length - 1];
                validators.pop();
                break;
            }
        }

        _updateApprovalRequirements();
        emit ValidatorRemoved(validator);
    }

    /**
     * @dev Checks if current round is expired
     */
    function _isCurrentRoundExpired() internal view returns (bool) {
        if (block.timestamp - lastProposalTime > roundExpirationTime) {
            return true;
        }
        return false;
    }

    /**
     * @dev Checks if a validator is selected for current round
     */
    function _isCurrentRoundValidator(
        address _validator
    ) internal view returns (bool) {
        for (uint i = 0; i < currentRoundValidators.length; i++) {
            if (currentRoundValidators[i] == _validator) {
                return true;
            }
        }
        return false;
    }

    function _updateRound() internal {
        _resetCurrentValidators();

        while (currentProposals.length > 0) {
            proposalVotes[uint8(currentProposals.length)] = 0;
            currentProposals.pop();
        }

        while (readyProposals.length > 0) {
            readyProposals.pop();
        }

        lastProposalTime = block.timestamp;
        nextProposalId++;
    }

    function _resetCurrentValidators() internal {
        // Clear submission status and other parameters
        for (uint256 i = 0; i < currentRoundValidators.length; i++) {
            hasSubmittedProposal[currentRoundValidators[i]] = 0;
        }

        for (uint256 i = 0; i < validators.length; i++) {
            hasVoted[validators[i]] = 0;
        }

        // If it's the genesis proposal and no round validators exist
        if (currentRoundValidators.length == 0) {
            for (uint256 i = 0; i < validators.length; i++) {
                hasSubmittedProposal[validators[i]] = 0;
            }
        }

        delete currentRoundValidators;

        require(
            validators.length >= nValidators,
            "Not enough active validators!"
        );

        // Create a temporary array to store selected validators
        address[] memory selectedValidators = new address[](nValidators);
        uint256 selectedCount = 0;
        uint nonce = 0;

        while (selectedCount < nValidators) {
            uint256 randId = uint256(
                keccak256(
                    abi.encode(
                        block.timestamp,
                        msg.sender,
                        selectedCount,
                        nonce
                    )
                )
            ) % validators.length;

            address selectedValidator = validators[randId];

            // Check if the validator is already selected
            bool alreadySelected = false;
            for (uint256 j = 0; j < selectedCount; j++) {
                if (selectedValidators[j] == selectedValidator) {
                    alreadySelected = true;
                    break;
                }
            }

            // If not selected, add to the current round and increment counter
            if (!alreadySelected) {
                selectedValidators[selectedCount] = selectedValidator;
                currentRoundValidators.push(selectedValidator);
                selectedCount++;
            }

            nonce++;
        }
    }

    function generateValidators(
        uint256 numValidators
    ) external view returns (address[] memory) {
        require(
            validators.length >= numValidators,
            "Not enough active validators!"
        );

        address[] memory selectedValidators = new address[](numValidators);
        uint256 selectedCount = 0;

        for (uint256 i = 0; i < numValidators; i++) {
            uint256 randId = uint256(
                keccak256(abi.encode(block.timestamp, msg.sender, i))
            ) % validators.length;

            selectedValidators[i] = validators[randId];
            selectedCount++;
        }

        return selectedValidators;
    }

    function halvePeriod() external onlySmartnodesCore {
        updateTime /= 2;
    }

    function doublePeriod() external onlySmartnodesCore {
        updateTime /= 2;
    }

    function getNumValidators() external view returns (uint256) {
        return validators.length;
    }

    function isActiveValidator(
        address _validatorAddress
    ) external view returns (bool) {
        return isValidator[_validatorAddress];
    }

    // function getCurrentProposal(
    //     uint8 proposalNum
    // ) external view returns (RemoveValidator[] memory, CompleteJob[] memory) {
    //     require(proposalNum < currentProposals.length, "Proposal not found!");
    //     return (
    //         currentProposals[proposalNum].validatorRemovals,
    //         currentProposals[proposalNum].jobCompletions
    //     );
    // }

    // Get basic info on the current state of the validator multisig
    function getState() external view returns (uint256, address[] memory) {
        return (nextProposalId, currentRoundValidators);
    }

    function isProposalReady(
        uint256 proposalNumber
    ) external view returns (bool) {
        for (uint i = 0; i < readyProposals.length; i++) {
            if (readyProposals[i] == proposalNumber) {
                return true;
            }
        }

        return false;
    }
}
