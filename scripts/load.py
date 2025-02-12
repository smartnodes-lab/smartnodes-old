from brownie import accounts, config, network, Contract, SmartnodesCore, TransparentProxy, ProxyAdmin, SmartnodesMultiSig
from scripts.helpful_scripts import get_account, encode_function_data, upgrade
from eth_abi import encode
from dotenv import load_dotenv, set_key
from web3 import Web3
from gnosis.safe import SafeTx, SafeOperation, Safe
import hashlib
import random
import json
import time
import os


load_dotenv(".env", override=True)

private_key = os.getenv("PRIVATE_KEY")
account = accounts.add(private_key)


def hash_proposal_data(
    validators_to_remove, 
    job_hashes, 
    job_capacities, 
    workers
):
    total_capacity = sum(job_capacities)
    encoded_data = encode(
        ["address[]", "bytes32[]", "uint256[]", "address[]", "uint256"],
        [
            validators_to_remove,
            job_hashes,
            job_capacities,
            workers,
            total_capacity
        ]
    )

    return Web3.keccak(encoded_data)


def get_proxy_admin():
    proxy_address = os.getenv("SMARTNODES_ADMIN_ADDRESS")
    proxy_admin = Contract.from_abi("SmartnodesProxyAdmin", proxy_address, ProxyAdmin.abi)
    return proxy_admin


def get_smartnodes():
    smartnodes_proxy_address = os.getenv("SMARTNODES_ADDRESS")
    sno_proxy = Contract.from_abi("SmartnodesCore", smartnodes_proxy_address, SmartnodesCore.abi)
    return sno_proxy


def get_validator():
    validator_proxy_address = os.getenv("SMARTNODES_MULTISIG_ADDRESS")
    validator_proxy = Contract.from_abi("SmartnodesMultiSig", validator_proxy_address, SmartnodesMultiSig.abi)
    return validator_proxy


def main():
    sno = get_smartnodes()
    sno_multisig = get_validator()

    # Add whatever you need to interact with the contracts
    