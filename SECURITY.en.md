# Security Policy (FIRE Smart Contracts)

**English** | **[한국어](SECURITY.md)**

This document details the trust model, test verification coverage, remaining risks, operational assumptions, static analysis results, and responsible vulnerability disclosure process for FIRE smart contracts on Base (OpenZeppelin Contracts v5.7.0, solc 0.8.30, Foundry v1.8.5).

---

## 1. Scope

| Category | Targets | Notes |
| :--- | :--- | :--- |
| **On-chain** | `src/FireToken.sol`, `src/FireVesting.sol`, `src/FireMerkleDistributor.sol`, `src/FireBatchSender.sol` | No proxies or upgradeability; code is immutable post-deployment. |
| **Off-chain Tools** | `script/` (Foundry deployment & check scripts), `airdrop/` (Merkle tree generation) | Not deployed on-chain, but included in scope as errors could cause loss of funds. |
| **Out of Scope** | Uniswap V3, WETH, Safe, Liquidity Lockers, Base sequencer / L2 system contracts, third-party wallets | External dependencies; treated under trust assumptions. |

---

## 2. Audit Status

- **External Audit Status:** No third-party security audit has been performed as of launch.
- **Inherited Code:** Launch contracts (`FireToken`, `FireVesting`) strictly inherit OpenZeppelin Contracts **v5.7.0** without modifying any library internals. OpenZeppelin submodules are locked to commit `cab19933c33c2ad1d4c7a84864a3601dddfd16f3` (verified via `foundry.lock` and CI). Custom code is restricted to constructor guards and two-step ownership protections.
- **Verification:** Unit tests, fuzz tests, invariant tests, and Base fork tests (534 tests), Slither static analysis, and live on-chain invariant validation (`PostDeployCheck: 21 PASS / 0 FAIL`).

---

## 3. Trust Model & System Invariants

### 3.1 FireToken
- **Zero Privileged Roles:** There is no owner, admin, minter, pauser, blacklist, transaction fee/tax, or upgrade mechanism.
- **Minting Restrictions:** Minting occurs exclusively inside the constructor (200,000,000 FIRE to `FireVesting`, 800,000,000 FIRE to `deployer`).
- **Constructor Guards:** Enforces that `vesting` is a deployed contract with `start() >= block.timestamp` and `duration() > 0`.
- **ERC-20 Permit (EIP-2612):** Supports gasless off-chain approvals; users should beware of phishing signatures on malicious third-party websites.

### 3.2 FireVesting
- **Beneficiary Access Only:** Only the contract owner (= beneficiary) receives unlocked tokens. Anyone may invoke `release()`, but tokens always transfer directly to the current owner.
- **Strict Schedule:** 180-day cliff (0 tokens unlocked), followed by 540-day second-by-second linear release. No early withdrawal function exists.
- **Two-Step Ownership:** Requires current owner to call `transferOwnership()` and the prospective owner to call `acceptOwnership()`.
- **Zero Renunciation:** `renounceOwnership()` is disabled to prevent accidental permanent locking of tokens.

### 3.3 FireMerkleDistributor
- **No Administrator:** Token, Merkle root, deadline, and sweep recipient are immutable once deployed.
- **Double-Hash Standard:** Uses OpenZeppelin `StandardMerkleTree` (`keccak256(bytes.concat(keccak256(abi.encode(account, amount))))`) to prevent second-preimage attacks.
- **Window Isolation:** Claims are only permitted when `block.timestamp <= CLAIM_DEADLINE`. Sweeping is only permitted when `block.timestamp > CLAIM_DEADLINE`.
- **Third-Party Claiming:** Anyone may submit a valid Merkle claim proof on behalf of a recipient; tokens always route strictly to the recipient's address.

### 3.4 FireBatchSender
- **Non-Custodial Design:** The contract holds zero token balances after transaction execution.
- **On-Chain Fee Burn:** $FIRE burn fees are collected via `burnFrom` and destroyed in the same transaction; fees are never paid out to any person or address.
- **Atomic Execution:** Any individual failure reverts the entire batch.

---

## 4. Test Verification Coverage

The test suite consists of 534 automated tests across four categories:
1. **Unit Tests:** State transitions, reverts, edge conditions, boundary timestamps.
2. **Fuzz Tests:** Random recipient sets, varying amounts, randomized block timestamps.
3. **Invariant Tests:** Continuous preservation of total supply cap, vesting mathematical bounds, and contract balance conservation over thousands of random call sequences.
4. **Base Fork Tests:** Realistic execution against live Base Mainnet state, simulating Uniswap V3 initialization, Safe multisig transfers, and Merkle distribution.

---

## 5. Known Operational Assumptions & Residual Risks

1. **Beneficiary Immediate Ownership:** The beneficiary address supplied at deployment becomes the vesting owner immediately without an accept step. If an incorrect address is provided, 200M FIRE is permanently unrecoverable (mitigated via pre-deployment signature proof).
2. **Uniswap V3 Pool Frontrunning:** Between token deployment and pool creation, an external party could attempt to initialize the pool with an erroneous price ratio. Mitigated by atomic multicall pool initialization scripts.
3. **No Asset Recovery (Rescue):** Neither `FireToken` nor `FireVesting` has a sweep or rescue function for arbitrarily mis-sent ERC-20 tokens or ETH. Tokens accidentally sent directly to the contract cannot be retrieved.

---

## 6. Static Analysis

- **Slither:** Analyzed with default and high-severity detectors. All flagged warnings were triaged as false positives relating to intentional OpenZeppelin inheritance patterns.
- **Formatting & Linters:** Clean compilation with 0 warnings under solc 0.8.30.

---

## 7. Vulnerability Disclosure & Contact

If you discover a potential vulnerability in the FIRE smart contracts or deployment infrastructure, please disclose it responsibly:

- **Security Inquiries / Reports:** Open a private security advisory on GitHub: [https://github.com/Fire-token/fire-contracts/security/advisories](https://github.com/Fire-token/fire-contracts/security/advisories)
- **Guidelines:** Provide clear reproduction steps (PoC in Foundry). Allow reasonable time to evaluate before public disclosure.
