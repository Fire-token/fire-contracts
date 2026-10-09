// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {FireToken} from "../src/FireToken.sol";
import {FireGameVault} from "../src/FireGameVault.sol";

contract MockVesting {
    function start() external view returns (uint256) {
        return block.timestamp + 1000;
    }
    function duration() external pure returns (uint256) {
        return 10000;
    }
}

contract FireGameVaultTest is Test {
    FireToken public token;
    FireGameVault public vault;
    MockVesting public vesting;

    address public deployer = address(0x1);
    address public treasury = address(0x2);
    address public player = address(0x3);
    uint256 public operatorKey = 0xABCD1234;
    address public operator;

    function setUp() public {
        operator = vm.addr(operatorKey);

        vm.startPrank(deployer);
        vesting = new MockVesting();
        token = new FireToken(address(vesting));
        vault = new FireGameVault(address(token), treasury, operator);

        // Fund player with 100,000 FIRE
        token.transfer(player, 100_000e18);
        vm.stopPrank();

        vm.prank(player);
        token.approve(address(vault), type(uint256).max);
    }

    function testDepositAndExecuteActionWithBurn() public {
        uint256 initialSupply = token.totalSupply();
        uint256 depositAmount = 10_000e18;

        // Player deposits
        vm.prank(player);
        vault.deposit(depositAmount);

        assertEq(vault.playerBalances(player), depositAmount);
        assertEq(token.balanceOf(address(vault)), depositAmount);

        // Operator executes Forge Upgrade (5,000 FIRE)
        uint256 spent = 5_000e18;
        vm.prank(operator);
        vault.executeGameAction(player, spent, "FORGE_WEAPON_LVL5");

        // Remaining balance
        assertEq(vault.playerBalances(player), 5_000e18);

        // 50% burned
        uint256 expectedBurn = 2_500e18;
        assertEq(vault.totalBurnedByGame(), expectedBurn);
        assertEq(token.totalSupply(), initialSupply - expectedBurn);

        // 30% in Prize Pool
        uint256 expectedPrizePool = 1_500e18;
        assertEq(vault.rewardPoolBalance(), expectedPrizePool);

        // 20% in Treasury
        uint256 expectedTreasury = 1_000e18;
        assertEq(token.balanceOf(treasury), expectedTreasury);
    }

    function testClaimRewardWithValidSignature() public {
        // First fund prize pool via action
        vm.prank(player);
        vault.deposit(10_000e18);

        vm.prank(operator);
        vault.executeGameAction(player, 10_000e18, "RAID_ENTRY");

        uint256 prizePool = vault.rewardPoolBalance(); // 3,000 FIRE
        assertGt(prizePool, 0);

        uint256 rewardAmount = 1_000e18;
        uint256 nonce = 1;

        // Construct signature from operator
        bytes32 messageHash = keccak256(
            abi.encodePacked(
                "FIRE_GAME_REWARD",
                block.chainid,
                address(vault),
                player,
                rewardAmount,
                nonce
            )
        );
        bytes32 ethSignedMessageHash = keccak256(
            abi.encodePacked("\x19Ethereum Signed Message:\n32", messageHash)
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(operatorKey, ethSignedMessageHash);
        bytes memory sig = abi.encodePacked(r, s, v);

        uint256 playerBalBefore = token.balanceOf(player);

        // Player claims reward
        vm.prank(player);
        vault.claimReward(rewardAmount, nonce, sig);

        assertEq(token.balanceOf(player), playerBalBefore + rewardAmount);
        assertEq(vault.rewardPoolBalance(), prizePool - rewardAmount);
        assertTrue(vault.usedNonces(player, nonce));

        // Replay attack must revert
        vm.prank(player);
        vm.expectRevert(FireGameVault.NonceAlreadyUsed.selector);
        vault.claimReward(rewardAmount, nonce, sig);
    }
}
