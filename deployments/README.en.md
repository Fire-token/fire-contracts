# deployments/ — FIRE Public On-Chain Deployment Records

**[English](README.en.md)** | **[한국어](README.md)**

The `<chainId>.json` files in this directory constitute the **public cryptographic record** of the FIRE launch. They document deployed contract addresses, multisig configurations, vesting schedules, initial allocation distributions, and Uniswap V3 pool records without exposing private keys or sensitive credentials.

---

## File Manifest

| File | Network | Description |
| :--- | :--- | :--- |
| [`8453.json`](8453.json) | Base Mainnet | **Official live record** on Base Mainnet (`chainId: 8453`, Block `52378678`). |
| `84532.json` | Base Sepolia | Testnet rehearsal record (used for verifying deployment invariants before mainnet). |

---

## Base Mainnet Deployed Record (`8453.json`) Summary

```json
{
  "chainId": 8453,
  "network": "base",
  "status": "confirmed",
  "blockNumber": 52378678,
  "contracts": {
    "FireToken": "0xCB357A1A388a71cF4d54D3649D02bd5182c2b2E0",
    "FireVesting": "0xD579bF53E084eF8f6C130F6D35844d490bF18290"
  },
  "wallets": {
    "treasurySafe": "0x2fb79a099B7579F486F073D78e75fbCD6Ce76Ef6",
    "airdropWallet": "0xA6b3a10C51E57bcda89B89B6E7aed73e646Fa449",
    "beneficiary": "0x5eB6293A028e8958fEE345ff973CD6DCC1555711",
    "deployer": "0xB0015faBc8456a39c0A114A5a6e0363C9589B66f"
  },
  "allocation": {
    "totalSupply": "1000000000000000000000000000",
    "lp": "700000000000000000000000000",
    "vesting": "200000000000000000000000000",
    "airdrop": "50000000000000000000000000",
    "treasury": "50000000000000000000000000"
  },
  "vesting": {
    "start": 1807098717,
    "cliffSeconds": 15552000,
    "linearSeconds": 46656000,
    "end": 1853754717
  }
}
```

---

## Pre-Deployment Signature Proof Architecture

To protect against address typos and ensure that 200,000,000 FIRE vesting and 50,000,000 FIRE airdrop allocations cannot be misrouted to uncontrolled addresses:
`script/Deploy.s.sol` requires cryptographic signature verification (`EIP-191 personal_sign`) proving operational control over both the `BENEFICIARY` and `AIRDROP_WALLET` before broadcasting any transaction.

Message template:
```text
FIRE launch control proof | role=<ROLE> | address=<EIP-55_ADDRESS> | chainId=<CHAIN_ID>
```

For the 2-of-3 Base Safe Treasury (`0x2fb79a099B7579F486F073D78e75fbCD6Ce76Ef6`), threshold signatures from Safe signers were verified, and active modules were strictly verified to be zero (`0 modules`) to eliminate backdoor vectors.
