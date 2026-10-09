# FIRE Merkle Airdrop Tool (`airdrop/`)

**[English](README.en.md)** | **[한국어](README.md)**

Tools and operational workflows for generating and verifying **round-based Merkle claim trees** for FIRE airdrop distributions on Base.
The on-chain contracts are [`src/FireMerkleDistributor.sol`](../src/FireMerkleDistributor.sol) and deployment script [`script/DeployAirdrop.s.sol`](../script/DeployAirdrop.s.sol).

---

## Architecture Overview

```
Recipient CSV ──(generate.mjs)──> tree.json · merkle.json · recipients.csv ──(Published on GitHub first)
                                       │
                                       ▼ Merkle Root
               Airdrop Wallet deploys FireMerkleDistributor + deposits FIRE total (DeployAirdrop.s.sol)
                                       │
         ┌─────────────────────────────┴─────────────────────────────┐
   Before Deadline (inclusive): claim(account, amount, proof)      After Deadline: Anyone can call sweep()
   - Third parties can submit proofs for recipients                - Unclaimed FIRE returns strictly to Airdrop Wallet
   - Exactly 1 claim per address                                   - Rolled over to subsequent airdrop rounds
```

- **Zero Admin Privileges:** No owner, no admin, no pause, no upgrades. All parameters (`TOKEN`, `MERKLE_ROOT`, `CLAIM_DEADLINE`, `SWEEP_RECIPIENT`) are immutable.
- **Leaf Hashing Format:** OpenZeppelin `StandardMerkleTree` with `["address", "uint256"]` format:
  `keccak256(bytes.concat(keccak256(abi.encode(account, amount))))` (Double-hash protects against second-preimage attacks).
- **Mutually Exclusive Windows:** Claiming is permitted only while `block.timestamp <= CLAIM_DEADLINE`. Sweeping is permitted only when `block.timestamp > CLAIM_DEADLINE`.

---

## Planned Rounds

| Round | Allocation | Schedule | Target Audience | Expected Total Flag |
| :--- | :--- | :--- | :--- | :--- |
| **Round 1** | 20,000,000 FIRE (2%) | Immediate (Post-Launch) | Testnet rehearsal participants, GitHub contributors, early community | `--expected-total 20000000` |
| **Round 2** | 30,000,000 FIRE (3%) + Unclaimed Rollover | 2027 Q1 Criteria / Q2 Distribution | Active users of ecosystem utilities (e.g., Base Batch Sender) | `--expected-total 30000000` + Rollover |

- Default claim window is **90 days** (`AIRDROP_CLAIM_DAYS`).
- Unclaimed tokens return strictly to the dedicated airdrop wallet and are added to Round 2. Tokens are never diverted to personal team wallets or treasury.

---

## Setup & Installation

```bash
cd airdrop
npm ci      # Install strictly pinned dependencies (.npmrc: ignore-scripts=true, save-exact=true)
npm test    # Run automated Merkle generation and verification tests (node:test)
```

- **Prerequisites:** Node.js 20.10+ / 24 LTS.
- Dependencies: `@openzeppelin/merkle-tree@1.0.8`, `viem@2.56.8`.

---

## Step-by-Step Execution Workflow

### 1. Prepare Recipient CSV (`recipients.csv`)
CSV must contain two columns: `address` and `amount` (in ether unit, e.g. `1000` for 1,000 FIRE):
```csv
address,amount
0x2BDD29789433CbF687f4c7c42Fa0d6ADBEA2080b,250
0x32f0078130232F41Ef3b69f002F925e377f2F374,200
```

### 2. Generate Merkle Tree
```bash
node generate.mjs \
  --input recipients.csv \
  --out out/round-1 \
  --expected-total 20000000 \
  --round 1
```

Generates:
- `tree.json`: Full tree representation.
- `merkle.json`: Lightweight claim file containing proofs for each address and root hash.
- `recipients.csv`: Normalized, checksummed recipient list.

### 3. Verify Generated Tree
```bash
node verify.mjs --input out/round-1/merkle.json --expected-total 20000000 --round 1
```

### 4. Deploy On-Chain Distributor
Commit and publish `merkle.json` to GitHub first to ensure cryptographic transparency, then broadcast deployment on Base Mainnet:
```bash
export AIRDROP_MERKLE_JSON=airdrop/out/round-1/merkle.json
export AIRDROP_WALLET=0xA6b3a10C51E57bcda89B89B6E7aed73e646Fa449

CONFIRM_MAINNET=I_UNDERSTAND forge script script/DeployAirdrop.s.sol:DeployAirdrop \
  --rpc-url https://mainnet.base.org \
  --account airdrop-wallet \
  --broadcast --slow
```

