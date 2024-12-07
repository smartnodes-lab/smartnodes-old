from brownie import accounts, config, network, Contract, SmartnodesCore, TransparentProxy, ProxyAdmin, SmartnodesMultiSig
from scripts.helpful_scripts import get_account, encode_function_data, upgrade
from eth_abi import encode
from dotenv import load_dotenv, set_key
from web3 import Web3
from gnosis.safe import SafeTx, SafeOperation, Safe
import json
import time
import os


load_dotenv(".env", override=True)

private_key = os.getenv("PRIVATE_KEY")
account = accounts.add(private_key)


def deploy_proxy_admin(account):
    proxy_admin = ProxyAdmin.deploy({"from": account})
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


def initialize_contracts(account, core, multisig):
    core.initialize(accounts[:3], account, {'from': account})
    multisig.initialize(core.address, {"from": account})
    core.setValidatorContract(multisig, {"from": account})


def main():
    # Account to deploy the proxy (proxy admin, to become a DAO of sorts)
    proxy_admin = deploy_proxy_admin(account)    
    sno = deploy_smartnodes(account, proxy_admin)
    sno_multisig = deploy_smartnodesValidator(account, proxy_admin)
    initialize_contracts(account, sno, sno_multisig)

