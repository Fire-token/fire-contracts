// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

/// @dev 생성자에서 vesting 인자가 베스팅 컨트랙트인지 최소한으로 확인하기 위한 조회 인터페이스 (OpenZeppelin VestingWallet 호환).
interface IFireVestingSchedule {
    function start() external view returns (uint256);
    function duration() external view returns (uint256);
}

/**
 * @title Fire Token (FIRE)
 * @dev 총 10억 개를 배포 시점에 일괄 발행. 추가 민팅 함수·소유자(Owner)·일시정지·블랙리스트·거래세 없음.
 *      개발자 지분 2억 개는 생성자에서 곧바로 베스팅 컨트랙트로 발행되어 배포자 지갑을 거치지 않음.
 *      vesting 인자 검사(실수 방지용):
 *        - 코드가 있는 주소여야 함 (일반 지갑 주소 거부).
 *        - start()·duration() 조회에 응답해야 하고, 발행 시점에 해제가 시작되지 않았어야 함
 *          (start() >= 현재 시각, duration() > 0). Safe·EIP-7702 위임 지갑 주소를 넣으면 배포가 실패함.
 *        - 베스팅 컨트랙트의 실제 내용은 BaseScan 소스 검증으로 확인해야 함.
 *      나머지 8억 개는 생성자를 실행한 msg.sender에게 발행됨. CREATE2 팩토리 등 다른 컨트랙트를 거쳐 배포하면
 *      그 컨트랙트가 8억 개를 받으므로, 반드시 배포 지갑에서 직접(일반 CREATE) 배포할 것.
 *      ERC20Permit(EIP-2612)은 가스리스 승인용 선택 기능이며 보안에 영향을 주지 않음.
 */
contract FireToken is ERC20, ERC20Burnable, ERC20Permit {
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000 * 1e18; // 10억
    uint256 public constant VESTING_SUPPLY = 200_000_000 * 1e18; // 2억 (개발자 20%)

    constructor(address vesting) ERC20("Fire", "FIRE") ERC20Permit("Fire") {
        require(vesting.code.length > 0, "FireToken: vesting must be a contract");
        require(
            // 시각 비교는 "발행 시점에 해제가 시작되지 않았는가"만 보며, 검증자의 수 초 조정은 결과에 영향을 주지 않음.
            // forge-lint: disable-next-line(block-timestamp)
            IFireVestingSchedule(vesting).start() >= block.timestamp && IFireVestingSchedule(vesting).duration() > 0,
            "FireToken: vesting schedule must not have started"
        );
        _mint(vesting, VESTING_SUPPLY); // 2억 → FireVesting 컨트랙트
        _mint(msg.sender, TOTAL_SUPPLY - VESTING_SUPPLY); // 8억 → 배포자 (7억 LP + 5,000만 에어드롭 + 5,000만 Safe 트레저리)
    }
}
