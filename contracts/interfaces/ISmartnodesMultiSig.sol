// SPDX-License-Identifier: MIT
pragma solidity ^0.8.5;

interface ISmartnodesMultiSig {
    struct RemoveValidator {
        address validator;
    }

    struct CompleteJob {
        bytes32 jobHash;
        uint256[] capacities;
        address[] workers;
    }

    function initialize(address target) external;
    function createProposal(
        RemoveValidator[] memory _functionTypes,
        CompleteJob[] memory _data
    ) external;
    function approveTransaction(uint8 proposalNum) external;
    function removeValidator(address validator) external;
    function executeProposal(
        address[] memory validatorsToRemove,
        bytes32[] memory jobHashes,
        uint256[] memory jobCapacities,
        address[] memory workers,
        uint256 totalCapacity
    ) external;

    function generateValidators(
        uint256 numValidators
    ) external view returns (address[] memory);
    function getNumValidators() external view returns (uint256);
    function getSelectedValidators() external view returns (address[] memory);
    function getCurrentProposal(
        uint8 proposalNum
    ) external view returns (uint[] memory, bytes[] memory);
    function getState() external view returns (uint256, address[] memory);
    function halvePeriod() external;
    function doublePeriod() external;
    function isActiveValidator(
        address _validatorAddress
    ) external view returns (bool);

    event ProposalExecuted(uint256 proposalId);
    event Deposit(address indexed sender, uint amount);
    event ValidatorAdded(address validator);
    event ValidatorRemoved(address validator);
}
