// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

/**
 * @title Fire Merkle Distributor (에어드롭 회차별 Merkle 클레임)
 * @notice 에어드롭 한 회차 물량을 Merkle 증명으로 지급하는 컨트랙트. 회차마다(1차 2,000만 / 2차 3,000만 FIRE) 새로 배포함.
 * @dev 관리자 권한이 전혀 없는 비수탁 구조 (owner·admin·pause·업그레이드 없음, 모든 설정값 immutable).
 *      - 수령자 목록과 수량 전체는 생성자에서 고정한 MERKLE_ROOT로 확정됨. 배포 후에는 개발자를 포함한 누구도
 *        목록·수량·기한·회수 주소를 바꿀 수 없음. 목록 원본(recipients.csv·tree.json)은 배포 전에 공개하며,
 *        누구나 airdrop/ 도구로 같은 root를 재계산해 대조할 수 있음.
 *      - leaf = keccak256(bytes.concat(keccak256(abi.encode(account, amount))))
 *        → OpenZeppelin StandardMerkleTree(["address","uint256"])와 동일. 이중 해시로 64바이트 내부 노드를
 *          leaf로 위장하는 second-preimage 공격을 차단함.
 *      - claim()은 누구나 대신 제출할 수 있으나(가스비 대납) 토큰은 항상 목록상의 account로만 전송됨.
 *        주소당 1회만 청구 가능하며, 청구 기록을 먼저 남긴 뒤 전송함.
 *        그 결과 (1) 목록에 잘못 들어간 주소(오타·개인 키 없는 주소·거래소 입금 주소 등)의 몫도 마감 전에 제3자가
 *        그 주소로 보내 버릴 수 있어 sweep으로 회수된다고 기대할 수 없고, (2) 수령 시점을 수령자가 아닌 제3자가
 *        정할 수 있음. 목록 오류를 막는 방어선은 배포 전 검증·공개·이의 제기 기간뿐임.
 *      - 기한 경계: block.timestamp <= CLAIM_DEADLINE 인 동안만 claim 가능(기한 시각 포함).
 *        block.timestamp > CLAIM_DEADLINE 이 되면 누구나 sweep()을 호출해 미청구 잔액 전부를
 *        SWEEP_RECIPIENT(에어드롭 전용 지갑)로 회수함 → 다음 회차로 이월. 두 구간이 겹치지 않으므로
 *        같은 블록에서 claim과 sweep이 경합하는 일이 없음.
 *      - 마감 시각은 배포 시점부터 MAX_CLAIM_PERIOD(365일) 이내여야 함. 밀리초 값 등 단위 실수로 sweep이 사실상
 *        영원히 불가능해져 미청구분이 잠기는 것을 막음.
 *      - 예치는 배포 후 에어드롭 지갑이 merkle.json의 total만큼 FIRE를 전송하는 방식(script/DeployAirdrop.s.sol).
 *        예치 부족 시 해당 claim만 되돌려지며(청구 기록도 함께 취소) 초과 예치분은 기한 후 sweep으로 회수됨.
 *      - forge-lint 억제 사유: block-timestamp → 기한 판정에 필수이며 시퀀서의 수 초 단위 조정은 90일 기한에
 *        의미가 없음. reentrancy-events → MerkleProof는 internal 라이브러리라 외부 호출이 아님(린트 오탐),
 *        실제 외부 호출(토큰 전송)은 이벤트 이후에 한 번만 수행함.
 */
contract FireMerkleDistributor {
    using SafeERC20 for IERC20;

    /// @notice 클레임 기간 상한: 마감 시각은 배포 시점부터 이 기간 이내여야 함
    uint256 public constant MAX_CLAIM_PERIOD = 365 days;

    /// @notice 지급 토큰 (FIRE)
    IERC20 public immutable TOKEN;
    /// @notice 수령자 목록 전체의 Merkle Root (배포 후 변경 불가)
    bytes32 public immutable MERKLE_ROOT;
    /// @notice 클레임 가능한 마지막 시각 (unix seconds, 이 시각 포함)
    uint64 public immutable CLAIM_DEADLINE;
    /// @notice 기한 후 미청구 물량을 회수할 주소 (에어드롭 전용 지갑)
    address public immutable SWEEP_RECIPIENT;

    /// @notice 주소별 청구 완료 여부
    mapping(address account => bool claimed) public isClaimed;

    /// @notice account에게 amount FIRE가 지급됨 (제출자와 무관하게 항상 account가 수령)
    event Claimed(address indexed account, uint256 amount);
    /// @notice 기한 후 미청구 잔액 amount FIRE가 SWEEP_RECIPIENT로 회수됨
    event Swept(uint256 amount);

    error FireMerkleDistributorInvalidToken(address token);
    error FireMerkleDistributorZeroMerkleRoot();
    error FireMerkleDistributorInvalidClaimDeadline(uint64 claimDeadline);
    error FireMerkleDistributorZeroSweepRecipient();
    error FireMerkleDistributorClaimWindowClosed(uint64 claimDeadline);
    error FireMerkleDistributorAlreadyClaimed(address account);
    error FireMerkleDistributorInvalidProof(address account, uint256 amount);
    error FireMerkleDistributorClaimWindowOpen(uint64 claimDeadline);
    error FireMerkleDistributorNothingToSweep();

    /**
     * @param token          지급 토큰 (컨트랙트 주소여야 함)
     * @param merkleRoot     airdrop/generate.mjs가 출력한 merkle.json의 root
     * @param claimDeadline  클레임 마감 시각 (unix 초). 현재 시각보다 미래이고 현재 + MAX_CLAIM_PERIOD 이하여야 함
     * @param sweepRecipient 미청구분 회수 주소 (에어드롭 전용 지갑)
     */
    constructor(IERC20 token, bytes32 merkleRoot, uint64 claimDeadline, address sweepRecipient) {
        if (address(token).code.length == 0) revert FireMerkleDistributorInvalidToken(address(token));
        if (merkleRoot == bytes32(0)) revert FireMerkleDistributorZeroMerkleRoot();
        // forge-lint: disable-next-line(block-timestamp)
        if (claimDeadline <= block.timestamp || claimDeadline > block.timestamp + MAX_CLAIM_PERIOD) {
            revert FireMerkleDistributorInvalidClaimDeadline(claimDeadline);
        }
        if (sweepRecipient == address(0)) revert FireMerkleDistributorZeroSweepRecipient();

        TOKEN = token;
        MERKLE_ROOT = merkleRoot;
        CLAIM_DEADLINE = claimDeadline;
        SWEEP_RECIPIENT = sweepRecipient;
    }

    /**
     * @notice 목록상의 account 몫을 청구함. 누구나 제출할 수 있으나 토큰은 항상 account로 전송됨.
     * @param account 수령 주소 (merkle.json claims의 키)
     * @param amount  수령 수량 (wei, merkle.json의 amount)
     * @param proof   Merkle 증명 (merkle.json의 proof)
     */
    function claim(address account, uint256 amount, bytes32[] calldata proof) external {
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp > CLAIM_DEADLINE) revert FireMerkleDistributorClaimWindowClosed(CLAIM_DEADLINE);
        if (isClaimed[account]) revert FireMerkleDistributorAlreadyClaimed(account);

        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(account, amount))));
        if (!MerkleProof.verifyCalldata(proof, MERKLE_ROOT, leaf)) {
            revert FireMerkleDistributorInvalidProof(account, amount);
        }

        isClaimed[account] = true; // 전송 전에 기록 (이중 청구·재진입 방지)
        // forge-lint: disable-next-line(reentrancy-events)
        emit Claimed(account, amount);
        TOKEN.safeTransfer(account, amount);
    }

    /**
     * @notice 클레임 기한이 지난 뒤 남은 FIRE 전부를 SWEEP_RECIPIENT(에어드롭 지갑)로 회수함. 누구나 호출 가능.
     * @dev 기한 후 잘못 입금된 FIRE도 다시 호출하면 같은 주소로 회수됨. 잔액이 0이면 되돌림.
     */
    function sweep() external {
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp <= CLAIM_DEADLINE) revert FireMerkleDistributorClaimWindowOpen(CLAIM_DEADLINE);
        uint256 amount = TOKEN.balanceOf(address(this));
        if (amount == 0) revert FireMerkleDistributorNothingToSweep();

        emit Swept(amount);
        TOKEN.safeTransfer(SWEEP_RECIPIENT, amount);
    }
}
