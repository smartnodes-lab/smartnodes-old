from brownie import accounts, config, network, Contract, SmartnodesCore, TransparentProxy, ProxyAdmin, SmartnodesMultiSig
from scripts.helpful_scripts import get_account, encode_function_data, upgrade
from eth_abi import encode
from dotenv import load_dotenv, set_key
from web3 import Web3
import random
import hashlib
import json
import time
import os

load_dotenv(".env", override=True)

private_key = os.getenv("PRIVATE_KEY")
account = accounts.add(private_key)

DEPLOY_NEW = False
UPGRADE = True


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
    if DEPLOY_NEW:
        proxy_admin = ProxyAdmin.deploy({"from": account})
        proxy_address = proxy_admin.address
    else:
        proxy_address = os.getenv("SMARTNODES_ADMIN_ADDRESS")

        if proxy_address:
            proxy_admin = Contract.from_abi("SmartnodesProxyAdmin", proxy_address, ProxyAdmin.abi)
        else:
            raise "Proxy Admin contract not found!"
    
    set_key(".env", "SMARTNODES_ADMIN_ADDRESS", proxy_address)
    return proxy_admin


def deploy_smartnodes(account, proxy_admin):
    if UPGRADE:
        new_smartnodes = SmartnodesCore.deploy({"from": account})
        smartnodes_proxy_address = os.getenv("SMARTNODES_ADDRESS")

    #     if smartnodes_proxy_address:
    #         proxy = TransparentProxy.at(smartnodes_proxy_address)
    #         upgrade_tx = proxy_admin.upgrade(proxy.address, new_smartnodes.address, {"from": account})
    #         upgrade_tx.wait(1)
    #         sno_proxy = Contract.from_abi("SmartnodesCore", smartnodes_proxy_address, SmartnodesCore.abi)
    #         smartnodes_address = sno_proxy.address
    #     else:
    #         raise Exception("Smartnodes proxy contract not found!")
    # elif DEPLOY_NEW:
    #     sno = SmartnodesCore.deploy({"from": account})
    #     encoded_init_function = encode_function_data(initializer=sno.initialize)
    #     sno_proxy = TransparentProxy.deploy(
    #         sno.address,
    #         proxy_admin.address,
    #         encoded_init_function,
    #         {"from": account}
    #     )
    #     sno_proxy = Contract.from_abi("SmartnodesCore", sno_proxy.address, SmartnodesCore.abi)
    #     smartnodes_address = sno_proxy.address
    # else:
    smartnodes_address = os.getenv("SMARTNODES_ADDRESS")
    if smartnodes_address:
        sno_proxy = Contract.from_abi("SmartnodesCore", smartnodes_address, SmartnodesCore.abi)
    else:
        raise Exception("SmartnodesCore contract not found!")

    set_key(".env", "SMARTNODES_ADDRESS", smartnodes_address)
    return sno_proxy


def deploy_smartnodesValidator(account, proxy_admin):
    if UPGRADE:
        new_smartnodes_multisig = SmartnodesMultiSig.deploy({"from": account})
        smartnodes_multisig_proxy_address = os.getenv("SMARTNODES_MULTISIG_ADDRESS")

        if smartnodes_multisig_proxy_address:
            proxy = TransparentProxy.at(smartnodes_multisig_proxy_address)
            upgrade_tx = proxy_admin.upgrade(proxy.address, new_smartnodes_multisig.address, {"from": account})
            upgrade_tx.wait(1)
            sno_multisig_proxy = Contract.from_abi("SmartnodesMultiSig", smartnodes_multisig_proxy_address, SmartnodesMultiSig.abi)
            smartnodes_multisig_address = sno_multisig_proxy.address
        else:
            raise Exception("SmartnodesMultiSig proxy contract not found!")
    elif DEPLOY_NEW:
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
    else:
        smartnodes_multisig_address = os.getenv("SMARTNODES_MULTISIG_ADDRESS")
        if smartnodes_multisig_address:
            sno_multisig_proxy = Contract.from_abi("SmartnodesMultiSig", smartnodes_multisig_address, SmartnodesMultiSig.abi)
        else:
            raise Exception("SmartnodesMultiSig contract not found!")

    set_key(".env", "SMARTNODES_MULTISIG_ADDRESS", smartnodes_multisig_address)
    return sno_multisig_proxy


def initialize_contracts(account, genesis_accounts, core, multisig):
    if DEPLOY_NEW:
        core.initialize(genesis_accounts, {'from': account})
        multisig.initialize(core.address, {"from": account})
        core.setValidatorContract(multisig, {"from": account})
    


def main():
    # Account to deploy the proxy (proxy admin, to become a DAO of sorts)
    # account = accounts[0]

    proxy_admin = deploy_proxy_admin(account)
    sno = deploy_smartnodes(account, proxy_admin)
    sno_multisig = deploy_smartnodesValidator(account, proxy_admin)
    initialize_contracts(account, [account, "0x41baa252e27eE953Ea89BFb74d7E11b32a0e4239"], sno, sno_multisig)

    # Deploy a user and validator
    if DEPLOY_NEW:
        sno.approve(account, 500_000e18, {"from": account})
        sno.createValidator(
            "58ef79797cd451e19df4a73fbd9871797f9c6a2995783c7f6fd2406978a2ba2e",
            500_000e18,
            {"from": account}
        )
        sno_multisig.addValidator(account, {"from": account})

    # print("\n_________________Contract State_________________")
    # print(f"Validator: {sno.validators(1)}")
    # print(f"Multisig State: {sno_multisig.getState()}")
    # print(f"Outstanding Tokens: {sno.totalSupply()/1e18}\n\n")
    
    # job_hashes = [
    #     bytes.fromhex(hashlib.sha256(str(random.random()).encode()).hexdigest()),
    #     bytes.fromhex(hashlib.sha256(str(random.random()).encode()).hexdigest()),
    #     bytes.fromhex(hashlib.sha256(str(random.random()).encode()).hexdigest()),
    #     bytes.fromhex(hashlib.sha256(str(random.random()).encode()).hexdigest()),
    #     bytes.fromhex(hashlib.sha256(str(random.random()).encode()).hexdigest()),
    #     bytes.fromhex(hashlib.sha256(str(random.random()).encode()).hexdigest())
    # ]
    # job_capacities = []
    # workers = []

    # for i in range(100):
    #     job_capacities.append(int(1e9))
    #     workers.append(account.address)

    # Remove validator test
    # Job Creation Test
    # Job Creation Test
    # Job completion test

    # sno_multisig.createProposal(
    #     hash_proposal_data([], job_hashes, job_capacities, workers), {"from": account}
    # )
    # sno_multisig.approveTransaction(1, {"from": account})
    # sno_multisig.executeProposal(
    #     [],
    #     job_hashes,
    #     job_capacities,
    #     workers,
    #     sum(job_capacities),
    #     {"from": account}
    # )

    # network.web3.provider.make_request("evm_mine", [])

    # print("\n_________________Contract State_________________\n")
    # print(f"Validator: {sno.validators(1)}")
    # print(f"Multisig State: {sno_multisig.getState()}")
    # print(f"Outstanding Tokens: {sno.totalSupply()/1e18}\n\n")

    # sno_multisig.createProposal(
    #     hash_proposal_data([], job_hashes, job_capacities, workers), {"from": account}
    # )
    # sno_multisig.approveTransaction(1, {"from": account})
    # sno_multisig.executeProposal(
    #     [],
    #     job_hashes,
    #     job_capacities,
    #     workers,
    #     sum(job_capacities),
    #     {"from": account}
    # )

    # print("\n_________________Contract State_________________\n")
    # print(f"Validator: {sno.validators(1)}")
    # print(f"User: {sno.users('0d976b7e1fd59537000313e274dc6a9d035ebaf95f4b8857740f7c799abd8629')}")
    # print(f"Job: {sno.jobs(hashlib.sha256().hexdigest())}")
    # print(f"Proposal: {sno_multisig.proposals(1)}")
    # print(f"Multisig State: {sno.getState()}")
    # print(f"Outstanding Tokens: {sno.totalSupply()/1e18}\n\n")

    # sno.unlockTokens(10e18, {"from": account})

    print("\n_________________Final Contract State_________________\n")
    print(f"Validator: {sno.validators(1)}")
    print(f"Multisig State: {sno_multisig.getState()}")
    print(f"Outstanding Tokens: {sno.totalSupply()/1e18}")
    