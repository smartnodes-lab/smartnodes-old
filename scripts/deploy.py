from brownie import accounts, config, network, Contract, SmartnodesCore, TransparentProxy, ProxyAdmin, SmartnodesMultiSig
from scripts.helpful_scripts import get_account, encode_function_data, upgrade
from eth_abi import encode
from dotenv import load_dotenv, set_key
from web3 import Web3
from gnosis.safe import SafeTx, SafeOperation, Safe
import json
import time
import random
import hashlib
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


def deploy_proxy_admin(account):
    proxy_admin = ProxyAdmin.deploy([account.address], {"from": account})
    proxy_address = proxy_admin.address
    set_key(".env", "SMARTNODES_ADMIN_ADDRESS", proxy_address)
    return proxy_admin


def deploy_smartnodes(account, proxy_admin):
    sno = SmartnodesCore.deploy({"from": account})
    
    encoded_init_function = encode_function_data(initializer=sno.initialize)
    
    sno_proxy = TransparentProxy.deploy(
        sno.address,
        proxy_admin.address,
        encoded_init_function,
        {"from": account}
    )
    sno_proxy = Contract.from_abi("SmartnodesCore", sno_proxy.address, SmartnodesCore.abi)
    smartnodes_address = sno_proxy.address

    set_key(".env", "SMARTNODES_ADDRESS", smartnodes_address)    
    return sno_proxy


def deploy_smartnodesValidator(account, proxy_admin):
    sno_multisig = SmartnodesMultiSig.deploy({"from": account})

    encoded_init_function = encode_function_data(initializer=sno_multisig.initialize)

    sno_multisig_proxy = TransparentProxy.deploy(
        sno_multisig.address,
        proxy_admin.address,
        encoded_init_function,
        {"from": account}
    )
    sno_multisig_proxy = Contract.from_abi("SmartnodesMultiSig", sno_multisig_proxy.address, SmartnodesMultiSig.abi)
    smartnodes_multisig_address = sno_multisig_proxy.address
    set_key(".env", "SMARTNODES_MULTISIG_ADDRESS", smartnodes_multisig_address)
    return sno_multisig_proxy


def initialize_contracts(account, genesis_accounts, core, multisig):
    core.initialize(genesis_accounts, {'from': account})
    multisig.initialize(core.address, {"from": account})
    core.setValidatorContract(multisig, {"from": account})
    

def main():
    # account = accounts[0]

    # Account to deploy the proxy (proxy admin, to become a DAO of sorts)
    proxy_admin = deploy_proxy_admin(account)    
    sno = deploy_smartnodes(account, proxy_admin)
    sno_multisig = deploy_smartnodesValidator(account, proxy_admin)

    # Un-comment to access existing contracts instead
    # smartnodes_multisig_address = os.getenv("SMARTNODES_MULTISIG_ADDRESS")
    # sno_multisig = Contract.from_abi("SmartnodesMultiSig", smartnodes_multisig_address, SmartnodesMultiSig.abi)
    # smartnodes_address = os.getenv("SMARTNODES_ADDRESS")
    # sno = Contract.from_abi("SmartnodesCore", smartnodes_address, SmartnodesCore.abi)
    
    seed_validators = [account, "0xA9c5307090c4F7d98541C7a444f1C395F2d7e135"]

    initialize_contracts(account, seed_validators, sno, sno_multisig)
    
    SmartnodesCore.publish_source(sno)
    SmartnodesMultiSig.publish_source(sno_multisig)

    # Optionally, add account as validator
    sno.approve(account, 500_000e18, {"from": account})
    sno.createValidator(
        os.getenv("NODE_HASH"),
        500_000e18,
        {"from": account}
    )
    sno_multisig.addValidator(account, {"from": account})


    print("\n_________________Contract State_________________")
    print(f"Validator: {sno.validators(account.address)}")
    print(f"Multisig State: {sno_multisig.getState()}")
    print(f"Outstanding Tokens: {sno.totalSupply()/1e18}\n\n")
    
    job_hashes = [
        bytes.fromhex(hashlib.sha256(str(random.random()).encode()).hexdigest()),
        bytes.fromhex(hashlib.sha256(str(random.random()).encode()).hexdigest()),
        bytes.fromhex(hashlib.sha256(str(random.random()).encode()).hexdigest()),
        bytes.fromhex(hashlib.sha256(str(random.random()).encode()).hexdigest()),
        bytes.fromhex(hashlib.sha256(str(random.random()).encode()).hexdigest()),
        bytes.fromhex(hashlib.sha256(str(random.random()).encode()).hexdigest())
    ]
    job_capacities = []
    workers = []

    for i in range(100):
        job_capacities.append(int(1e9))
        workers.append(account.address)

    # Remove validator test
    sno_multisig.createProposal(
        hash_proposal_data([], job_hashes, job_capacities, workers), {"from": account}
    )
    sno_multisig.approveTransaction(1, {"from": account})
    sno_multisig.executeProposal(
        [],
        job_hashes,
        job_capacities,
        workers,
        [sum(job_capacities)],
        {"from": account}
    )

    print("\n_________________Contract State_________________\n")
    print(f"Validator: {sno.validators(account.address)}")
    print(f"Multisig State: {sno_multisig.getState()}")
    print(f"Outstanding Tokens: {sno.totalSupply()/1e18}\n\n")

