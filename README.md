# FIRE ($FIRE) Smart Contracts

**English** | **[한국어](README.ko.md)**

Smart contracts, deployment scripts, tests, and airdrop verification tools for **FIRE ($FIRE)** deployed on **Base (Ethereum L2, Chain ID: 8453)**.

FIRE is an open-source, community-driven deflationary utility token designed for transparent fair launch with zero pre-sale, zero ICO, and immutable on-chain rules. Every token distribution, vesting schedule, and burn mechanism is verifiable on-chain.

- **Website**: [https://fire-token.github.io](https://fire-token.github.io)
- **Token Contract**: [`0xCB357A1A388a71cF4d54D3649D02bd5182c2b2E0`](https://basescan.org/address/0xCB357A1A388a71cF4d54D3649D02bd5182c2b2E0)
- **License**: MIT ([`LICENSE`](LICENSE))

---

## Token Overview

| Parameter | Value |
| :--- | :--- |
| **Token Name** | Fire |
| **Symbol** | FIRE |
| **Decimals** | 18 |
| **Total Supply** | 1,000,000,000 FIRE (Fixed cap, minted at deployment, no mint function) |
| **Network** | Base Mainnet (Chain ID: `8453`) |
| **Library** | OpenZeppelin Contracts **v5.7.0** (Strict inheritance without modifying library source) |
| **Solidity Compiler** | solc **0.8.30**, Optimizer **200 runs**, EVM **cancun**, viaIR disabled |
| **Verification** | Verified on [Sourcify](https://sourcify.dev) (`exact_match`) and [BaseScan](https://basescan.org/address/0xCB357A1A388a71cF4d54D3649D02bd5182c2b2E0) |

---

## Supply Allocation

| Allocation | Amount (FIRE) | Ratio | Execution & Mechanism |
| :--- | ---: | :---: | :--- |
| **DEX Initial Liquidity** | 700,000,000 | 70% | Uniswap V3 full-range FIRE/WETH pool with 365-day LP lock (`Deployer` wallet) |
| **Developer / Team Vesting** | 200,000,000 | 20% | Minted directly to `FireVesting`: 180-day cliff (0 release) + 540-day linear vesting |
| **Community Airdrop** | 50,000,000 | 5% | Dedicated Airdrop Wallet → Round-based `FireMerkleDistributor` (Round 1: 20M, Round 2: 30M) |
| **CEX Listing & Treasury** | 50,000,000 | 5% | Base Safe Multisig (2-of-3 threshold) |

---

## Official Base Mainnet Addresses

Successfully deployed and verified on Base Mainnet on **October 9, 2026** (Block `52378678`). All 21 on-chain invariant checks passed (`PostDeployCheck: 21 PASS / 0 WARN / 0 FAIL`).

| Contract / Account | Address | Explorer / Link |
| :--- | :--- | :--- |
| **FireToken** | `0xCB357A1A388a71cF4d54D3649D02bd5182c2b2E0` | [BaseScan](https://basescan.org/address/0xCB357A1A388a71cF4d54D3649D02bd5182c2b2E0) |
| **FireVesting** | `0xD579bF53E084eF8f6C130F6D35844d490bF18290` | [BaseScan](https://basescan.org/address/0xD579bF53E084eF8f6C130F6D35844d490bF18290) |
| **Treasury Safe (2-of-3)** | `0x2fb79a099B7579F486F073D78e75fbCD6Ce76Ef6` | [BaseScan](https://basescan.org/address/0x2fb79a099B7579F486F073D78e75fbCD6Ce76Ef6) |
| **Airdrop Wallet** | `0xA6b3a10C51E57bcda89B89B6E7aed73e646Fa449` | [BaseScan](https://basescan.org/address/0xA6b3a10C51E57bcda89B89B6E7aed73e646Fa449) |
| **Vesting Beneficiary** | `0x5eB6293A028e8958fEE345ff973CD6DCC1555711` | [BaseScan](https://basescan.org/address/0x5eB6293A028e8958fEE345ff973CD6DCC1555711) |
| **Deployer Wallet** | `0xB0015faBc8456a39c0A114A5a6e0363C9589B66f` | [BaseScan](https://basescan.org/address/0xB0015faBc8456a39c0A114A5a6e0363C9589B66f) |

---

## Contract Architecture & Invariant Guarantees

| Contract | Role | Permissions & Access | Technical Invariant Guarantees |
| :--- | :--- | :--- | :--- |
| [`FireToken`](src/FireToken.sol) | ERC-20 + Burnable + Permit (EIP-2612) | **Zero privileged entities.** Holders can only transfer, approve (incl. permit), and burn their own tokens. | Initial supply minted strictly in constructor (200M to `FireVesting`, 800M to `deployer`). No owner, no mint, no pause, no blacklist, no transaction fees/taxes, no proxy/upgrade. Constructor enforces that `vesting` is a deployed contract with `start() >= now` and `duration() > 0`. Exactly 17 external functions. |
| [`FireVesting`](src/FireVesting.sol) | OZ `VestingWallet` + `Ownable2Step` | Owner (= Beneficiary): Receives unlocked tokens; can initiate 2-step ownership transfer (`acceptOwnership` required). Anyone: Can trigger `release()` (tokens always transfer directly to the owner). | 180-day cliff (0 tokens unlocked), followed by 540-day second-by-second linear release. Zero bypass mechanisms. `renounceOwnership()` is disabled to prevent accidental permanent locking. Exactly 16 external functions. |
| [`FireMerkleDistributor`](src/FireMerkleDistributor.sol) | Per-round Merkle airdrop distributor | **Zero admin rights.** Anyone: Can submit valid `claim()` until deadline (tokens go strictly to leaf recipient); can trigger `sweep()` after deadline (unclaimed tokens transfer strictly to `SWEEP_RECIPIENT`). | Immutable token, Merkle root, deadline, and sweep recipient. One claim per address. Deadline cannot exceed 365 days from deployment. Claim window and sweep window are mutually exclusive. Exactly 8 external functions. |
| [`FireBatchSender`](src/FireBatchSender.sol) | Bulk multi-send (up to 300 recipients) for ETH/ERC-20 + FIRE Burn Fee | Owner (Treasury Safe): Adjust `freeRecipientLimit` (0–300) and `burnFee` (0–1,000,000 FIRE). User: Transfer own assets. | Non-custodial (contract holds 0 balance after transaction). Burn fee is permanently destroyed via `burnFrom` within the same transaction and cannot be collected by anyone. User sets `maxBurnFee` per call. Atomic revert on any row failure. No rescue, no pause, no ownership renunciation. |

Full threat model, invariant proofs, and remaining risks are documented in [`SECURITY.md`](SECURITY.md).

---

## Repository Structure

```
fire-contracts/
├── src/                        # On-chain smart contracts (FireToken, FireVesting, FireMerkleDistributor, FireBatchSender)
├── script/                     # Foundry deployment, verification, and proof scripts
│   ├── Deploy.s.sol            # Launch deployment: FireVesting -> FireToken -> Safe / Airdrop distribution
│   ├── CreatePool.s.sol        # Uniswap V3 pool initialization + full-range liquidity position
│   ├── PostDeployCheck.s.sol   # Read-only post-deployment audit report (PASS/WARN/FAIL)
│   ├── DeployAirdrop.s.sol     # Airdrop distributor deployment and funding
│   ├── DeployBatchSender.s.sol # Bulk sender utility deployment
│   └── lib/                    # Common guards, bytecode comparison, Uniswap math & address tables
├── test/                       # Foundry tests (Unit, Fuzz, Invariants, and Fork tests)
│   ├── fork/                   # Base Mainnet & Sepolia live fork tests
│   ├── invariant/              # Invariant handler tests for FireToken and FireVesting
│   └── fixtures/               # Sample Merkle fixtures
├── airdrop/                    # Node.js Merkle tree generation & validation tools (StandardMerkleTree)
├── deployments/                # Public on-chain deployment records (8453.json)
├── lib/                        # Git submodules: forge-std, openzeppelin-contracts (v5.7.0)
├── foundry.toml                # Compiler settings, gas optimizer, and EVM configuration
└── SECURITY.md                 # Security model, audit scope, and responsible disclosure
```

---

## Development & Testing

### Prerequisites
- **Foundry v1.8.5**
  ```bash
  foundryup --install 1.8.5
  forge --version
  ```
- **Node.js 20.10+ / 24 LTS** (for airdrop tools)
  ```bash
  cd airdrop && npm ci && cd ..
  ```

### Build & Run Tests
```bash
# 1. Compile contracts
forge build

# 2. Run all unit, fuzz, and invariant tests
forge test

# 3. Run invariant tests with extended depth
forge test --match-path test/invariant/* -vvv

# 4. Run Base Mainnet fork tests
forge test --match-path test/fork/* --fork-url https://mainnet.base.org -vvv
```

### On-Chain Deployment Audit
Verify live on-chain deployment against local compiled bytecode and invariant rules:
```bash
forge script script/PostDeployCheck.s.sol:PostDeployCheck --rpc-url base
# Expected output: RESULT: PASS (21 passed / 0 warned / 0 failed)
```

---

## Utility & Roadmap

1. **Base Batch Sender (Utility & Burn Engine)**:
   - Bulk-transfer ETH and ERC-20 tokens to up to 300 addresses in a single atomic transaction.
   - Saves up to 70% in L2 transaction fees.
   - Requires $FIRE for batches over the free tier; **100% of collected fees are burned on-chain immediately**.

2. **VIP Whale & Lockup Tracker**:
   - Automated alerts on Base whale wallet movements and liquidity lockup expirations.
   - Token-gated access holding a minimum balance of $FIRE.

3. **Round 2 Ecosystem Airdrop (30,000,000 $FIRE)**:
   - Distributed to active users of the utility ecosystem.

---

## License

This project is licensed under the **MIT License** — see the [`LICENSE`](LICENSE) file for details.
