// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./TransparentProxy.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @dev This is an auxiliary contract meant to be assigned as the admin of {TransparentProxy}.
 */
contract ProxyAdmin is Ownable {
    uint256 public requiredApprovals; // Number of approvals required for an action
    address[] public signers; // List of authorized signers
    mapping(address => bool) public isSigner; // Mapping to check if an address is a signer
    mapping(bytes32 => uint256) public approvals; // Tracks approvals for a specific action

    event SignerAdded(address indexed signer);
    event SignerRemoved(address indexed signer);
    event ApprovalReceived(address indexed signer, bytes32 indexed action);
    event UpgradeExecuted(TransparentProxy proxy, address implementation);

    constructor(address[] memory _signers) {
        for (uint256 i = 0; i < _signers.length; i++) {
            isSigner[_signers[i]] = true;
            signers.push(_signers[i]);
            emit SignerAdded(_signers[i]);
        }
        _updateRequiredApprovals();
    }

    modifier onlySigner() {
        require(isSigner[msg.sender], "Not an authorized signer");
        _;
    }

    function _updateRequiredApprovals() internal {
        // Calculate 50% of the total signers
        uint256 totalSigners = signers.length;
        requiredApprovals = (totalSigners * 50 + 99) / 100;
    }

    function addSigner(address signer) public onlyOwner {
        require(!isSigner[signer], "Already a signer");
        isSigner[signer] = true;
        signers.push(signer);
        emit SignerAdded(signer);
    }

    function removeSigner(address signer) public onlyOwner {
        require(isSigner[signer], "Not a signer");
        isSigner[signer] = false;

        for (uint256 i = 0; i < signers.length; i++) {
            if (signers[i] == signer) {
                signers[i] = signers[signers.length - 1];
                signers.pop();
                break;
            }
        }
        emit SignerRemoved(signer);
    }

    /**
     * @dev Returns the current implementation of `proxy`.
     * NOTE This contract must be the admin of `proxy`.
     */
    function getProxyImplementation(
        TransparentProxy proxy
    ) public view virtual returns (address) {
        // We need to manually run the static call since the getter cannot be flagged as view
        // bytes4(keccak256("implementation()")) == 0x5c60da1b
        (bool success, bytes memory returndata) = address(proxy).staticcall(
            hex"5c60da1b"
        );
        require(success);
        return abi.decode(returndata, (address));
    }

    /**
     * @dev Returns the current admin of `proxy`.
     * NOTE This contract must be the admin of `proxy`.
     */
    function getProxyAdmin(
        TransparentProxy proxy
    ) public view virtual returns (address) {
        // We need to manually run the static call since the getter cannot be flagged as view
        // bytes4(keccak256("admin()")) == 0xf851a440
        (bool success, bytes memory returndata) = address(proxy).staticcall(
            hex"f851a440"
        );
        require(success);
        return abi.decode(returndata, (address));
    }

    /**
     * @dev Changes the admin of `proxy` to `newAdmin`.
     * NOTE This contract must be the current admin of `proxy`.
     */
    function changeProxyAdmin(
        TransparentProxy proxy,
        address newAdmin
    ) public virtual onlyOwner {
        proxy.changeAdmin(newAdmin);
    }

    /**
     * @dev Upgrades `proxy` to `implementation`.
     * NOTE This contract must be the admin of `proxy`.
     */
    function approveUpgrade(
        TransparentProxy proxy,
        address implementation
    ) public onlySigner {
        bytes32 actionId = keccak256(abi.encode(proxy, implementation));
        require(approvals[actionId] < requiredApprovals, "Already approved");
        approvals[actionId]++;
        emit ApprovalReceived(msg.sender, actionId);

        if (approvals[actionId] >= requiredApprovals) {
            proxy.upgradeTo(implementation);
            emit UpgradeExecuted(proxy, implementation);
        }
    }

    /**
     * @dev Upgrades `proxy` to `implementation` and calls a function on the new implementation.
     * NOTE This contract must be the admin of `proxy`.
     */
    function upgradeAndCall(
        TransparentProxy proxy,
        address implementation,
        bytes memory data
    ) public payable virtual onlyOwner {
        proxy.upgradeToAndCall{value: msg.value}(implementation, data);
    }

    /**
     * @dev Forward a call to the proxy's implementation.
     * Requires multisig approval.
     */
    function forwardCall(
        TransparentProxy proxy,
        bytes memory data
    ) public onlySigner {
        bytes32 actionId = keccak256(abi.encode(proxy, data));
        require(approvals[actionId] < requiredApprovals, "Already approved");
        approvals[actionId]++;
        emit ApprovalReceived(msg.sender, actionId);

        if (approvals[actionId] >= requiredApprovals) {
            (bool success, ) = address(proxy).call(data);
            require(success, "Call failed");
        }
    }
}
