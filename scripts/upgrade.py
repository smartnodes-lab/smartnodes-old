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


def get_proxy_admin():
    proxy_address = os.getenv("SMARTNODES_ADMIN_ADDRESS")
    proxy_admin = Contract.from_abi("SmartnodesProxyAdmin", proxy_address, ProxyAdmin.abi)
    return proxy_admin


def deploy_new_smartnodes(account, proxy_admin):
    smartnodes_proxy_address = os.getenv("SMARTNODES_ADDRESS")
    sno_proxy = Contract.from_abi("SmartnodesCore", smartnodes_proxy_address, SmartnodesCore.abi)
    new_sno = SmartnodesCore.deploy({"from": account})

    upgrade_tx = proxy_admin.approveUpgrade(sno_proxy.address, new_sno.address, {"from": account})
    upgrade_tx.wait(1)

    new_sno = Contract.from_abi("SmartnodesCore", smartnodes_proxy_address, SmartnodesCore.abi)
    return new_sno


def deploy_new_validator(account, proxy_admin):
    validator_proxy_address = os.getenv("SMARTNODES_MULTISIG_ADDRESS")
    validator_proxy = Contract.from_abi("SmartnodesMultiSig", validator_proxy_address, SmartnodesMultiSig.abi)
    new_sno_multisig = SmartnodesMultiSig.deploy({"from": account})
    upgrade_tx = proxy_admin.approveUpgrade(validator_proxy.address, new_sno_multisig.address, {"from": account})
    upgrade_tx.wait(1)
    new_sno_multisig = Contract.from_abi("SmartnodesMultiSig", validator_proxy, SmartnodesMultiSig.abi)
    return new_sno_multisig


def main():
    # account = accounts[0]

    # Account to deploy the proxy (proxy admin, to become a DAO of sorts)
    proxy_admin = get_proxy_admin()    
    sno = deploy_new_smartnodes(account, proxy_admin)
    sno_multisig = deploy_new_validator(account, proxy_admin)
