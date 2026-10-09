// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {FireToken} from "./FireToken.sol";

/**
 * @title FireGameVault
 * @notice Deflationary Game Economy Engine for $FIRE on Base.
 * @dev Manages player deposits, automated on-chain deflationary burns (50% burn on item forge / raid entry),
 *      prize pool accumulation (30%), and secure ECDSA-signed reward payouts.
 */
contract FireGameVault is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // --- State Variables ---
    FireToken public immutable TOKEN;
    address public immutable TREASURY;
    address public gameOperator;

    // Default fee split: 50% Burn, 30% Prize Pool, 20% Treasury
    uint256 public constant BURN_BPS = 5000;      // 50.00%
    uint256 public constant PRIZE_POOL_BPS = 3000; // 30.00%
    uint256 public constant TREASURY_BPS = 2000;   // 20.00%
    uint256 public constant BPS_DENOMINATOR = 10000;

    uint256 public totalBurnedByGame;
    uint256 public rewardPoolBalance;

    // Player in-game deposited balance
    mapping(address => uint256) public playerBalances;

    // Anti-replay mapping for reward claiming
    mapping(address => mapping(uint256 => bool)) public usedNonces;

    // --- Events ---
    event GameDeposited(address indexed player, uint256 amount, uint256 newBalance);
    event GameActionBurned(
        address indexed player,
        string action,
        uint256 totalSpent,
        uint256 burnedAmount,
        uint256 prizePoolAmount,
        uint256 treasuryAmount
    );
    event GameRewardClaimed(address indexed player, uint256 amount, uint256 nonce);
    event GameOperatorUpdated(address indexed previousOperator, address indexed newOperator);

    // --- Errors ---
    error InvalidZeroAddress();
    error InvalidAmount();
    error InsufficientBalance();
    error NonceAlreadyUsed();
    error InvalidSignature();
    error Unauthorized();

    modifier onlyOperator() {
        if (msg.sender != gameOperator) revert Unauthorized();
        _;
    }

    constructor(address tokenAddress, address treasuryAddress, address operatorAddress) {
        if (tokenAddress == address(0) || treasuryAddress == address(0) || operatorAddress == address(0)) {
            revert InvalidZeroAddress();
        }
        TOKEN = FireToken(tokenAddress);
        TREASURY = treasuryAddress;
        gameOperator = operatorAddress;
    }

    /**
     * @notice Deposit $FIRE from player wallet into the game vault.
     * @param amount Amount of $FIRE to deposit (requires ERC20 approve first).
     */
    function deposit(uint256 amount) external nonReentrant {
        if (amount == 0) revert InvalidAmount();

        IERC20(address(TOKEN)).safeTransferFrom(msg.sender, address(this), amount);
        playerBalances[msg.sender] += amount;

        emit GameDeposited(msg.sender, amount, playerBalances[msg.sender]);
    }

    /**
     * @notice Direct in-game action execution with automated burning (e.g. Forge Item, Raid Entry).
     * @dev Deducts from player balance, permanently burns 50% on-chain, puts 30% into prize pool, sends 20% to treasury.
     * @param player Target player address
     * @param amount Amount of $FIRE consumed for action
     * @param action Identifier tag (e.g. "FORGE_UPGRADE", "RAID_TICKET", "GACHA")
     */
    function executeGameAction(
        address player,
        uint256 amount,
        string calldata action
    ) external onlyOperator nonReentrant {
        if (amount == 0) revert InvalidAmount();
        if (playerBalances[player] < amount) revert InsufficientBalance();

        playerBalances[player] -= amount;

        // Calculate splits
        uint256 burnAmount = (amount * BURN_BPS) / BPS_DENOMINATOR;
        uint256 prizePoolAmount = (amount * PRIZE_POOL_BPS) / BPS_DENOMINATOR;
        uint256 treasuryAmount = amount - burnAmount - prizePoolAmount;

        // 1. Permanent On-Chain Burn
        TOKEN.burn(burnAmount);
        totalBurnedByGame += burnAmount;

        // 2. Prize Pool Accumulation
        rewardPoolBalance += prizePoolAmount;

        // 3. Treasury Transfer
        if (treasuryAmount > 0) {
            IERC20(address(TOKEN)).safeTransfer(TREASURY, treasuryAmount);
        }

        emit GameActionBurned(player, action, amount, burnAmount, prizePoolAmount, treasuryAmount);
    }

    /**
     * @notice Claim verified game rewards directly to player's wallet.
     * @param amount Reward amount in $FIRE
     * @param nonce Unique single-use nonce
     * @param signature Cryptographic signature by gameOperator
     */
    function claimReward(
        uint256 amount,
        uint256 nonce,
        bytes calldata signature
    ) external nonReentrant {
        if (amount == 0) revert InvalidAmount();
        if (usedNonces[msg.sender][nonce]) revert NonceAlreadyUsed();
        if (rewardPoolBalance < amount) revert InsufficientBalance();

        // Verify EIP-191 personal_sign
        bytes32 messageHash = keccak256(
            abi.encodePacked(
                "FIRE_GAME_REWARD",
                block.chainid,
                address(this),
                msg.sender,
                amount,
                nonce
            )
        );
        bytes32 ethSignedMessageHash = MessageHashUtils.toEthSignedMessageHash(messageHash);
        address recoveredSigner = ECDSA.recover(ethSignedMessageHash, signature);

        if (recoveredSigner != gameOperator) revert InvalidSignature();

        usedNonces[msg.sender][nonce] = true;
        rewardPoolBalance -= amount;

        IERC20(address(TOKEN)).safeTransfer(msg.sender, amount);

        emit GameRewardClaimed(msg.sender, amount, nonce);
    }

    /**
     * @notice Allows operator update.
     */
    function setOperator(address newOperator) external onlyOperator {
        if (newOperator == address(0)) revert InvalidZeroAddress();
        emit GameOperatorUpdated(gameOperator, newOperator);
        gameOperator = newOperator;
    }
}
