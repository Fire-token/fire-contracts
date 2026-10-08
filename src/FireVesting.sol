// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {VestingWallet} from "@openzeppelin/contracts/finance/VestingWallet.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/**
 * @title Fire Vesting (개발자 지분 20% 온체인 락업)
 * @dev OpenZeppelin VestingWallet(감사 완료)을 상속한 얇은 래퍼.
 *      - 토큰 주소를 미리 알 필요가 없으므로 FireToken보다 먼저 배포할 수 있음.
 *      - start    = 배포 시각 + cliffSeconds → 클리프 기간 동안 해제 가능 수량 0
 *      - duration = linearSeconds           → 클리프 종료 후 초 단위 선형 해제
 *      - 수익자(beneficiary) = owner(). 생성자에 넣은 최초 수익자는 수락 절차 없이 즉시 owner가 되므로,
 *        배포 전에 그 주소를 실제로 통제하는지 반드시 증명할 것 (script/Deploy.s.sol이 메인넷에서 강제).
 *      - 배포 이후의 수령 지갑 교체는 Ownable2Step 방식만 허용
 *        (transferOwnership 후 새 지갑이 acceptOwnership 호출) → 교체 시 주소 오입력에 따른 영구 손실 방지.
 *      - renounceOwnership() 차단. 소유권을 포기하면 owner가 0 주소가 되어 잔여 물량이 영구 동결되기 때문.
 *      - release(token)은 누구나 호출할 수 있으나 토큰은 항상 owner()에게만 전송됨.
 */
contract FireVesting is VestingWallet, Ownable2Step {
    error FireVestingRenounceDisabled();

    constructor(address beneficiary, uint64 cliffSeconds, uint64 linearSeconds)
        VestingWallet(beneficiary, SafeCast.toUint64(block.timestamp) + cliffSeconds, linearSeconds)
    {}

    function renounceOwnership() public pure override {
        revert FireVestingRenounceDisabled();
    }

    /// @dev Ownable2Step의 2단계 이전을 사용 (VestingWallet과 Ownable2Step 모두 Ownable을 상속하므로 명시 필요).
    function transferOwnership(address newOwner) public override(Ownable, Ownable2Step) {
        super.transferOwnership(newOwner);
    }

    function _transferOwnership(address newOwner) internal override(Ownable, Ownable2Step) {
        super._transferOwnership(newOwner);
    }
}
