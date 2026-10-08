// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

/**
 * @title Fire Batch Sender (Base 다중 지갑 배치 전송기)
 * @dev 사용자 자산을 보관하지 않는(Non-custodial) 다중 전송 도구. ETH 또는 임의의 ERC-20을 한 트랜잭션으로
 *      최대 MAX_RECIPIENTS 개 지갑에 전송하며, 한 건이라도 실패하면 배치 전체가 취소(revert)됨.
 *      - ERC-20: SafeERC20.safeTransferFrom(송신자 → 수령자)으로 직접 이동. 이 컨트랙트를 경유하지 않음.
 *      - ETH: msg.value가 amounts 합계와 정확히 같아야 하며 같은 트랜잭션 안에서 전액 전달됨. 수령자마다 가스를
 *        ETH_RECIPIENT_GAS로 제한하므로, 수령자 때문에 실패하면 항상 그 행 번호가 오류에 포함됨.
 *        receive()/fallback()이 없으므로 일반 송금으로는 ETH를 받을 수 없음. selfdestruct 등으로 강제 송금된 ETH는
 *        회수할 수 없지만 로직은 address(this).balance를 쓰지 않으므로 전송 동작에 영향이 없음.
 *      - 소각 수수료: 수령자 수가 freeRecipientLimit를 "초과"하면 burnFee 만큼의 FIRE를 송신자 지갑에서
 *        ERC20Burnable.burnFrom으로 같은 트랜잭션 안에서 즉시 소각(사용자가 이 컨트랙트에 FIRE를 approve).
 *        수수료 FIRE는 소유자·이 컨트랙트를 포함해 누구에게도 전송되지 않으며 FIRE totalSupply 감소로 검증 가능.
 *      - 소유자(트레저리 Safe) 권한은 freeRecipientLimit·burnFee 변경뿐. 사용자 자산을 옮기는 함수, 출금(rescue)·
 *        일시정지 기능은 없음. burnFee는 MAX_BURN_FEE를 넘을 수 없고, 사용자는 호출마다 maxBurnFee로 지불 상한을
 *        지정하므로 수수료 인상 트랜잭션이 먼저 처리되어도 상한을 넘는 수수료는 청구되지 않음(배치 전체 취소).
 *      - 모든 토큰 이동의 from은 항상 msg.sender. 무한 승인을 해 둔 지갑이라도 본인이 직접 호출하지 않는 한
 *        소유자·제3자가 그 지갑의 토큰을 옮길 수 없음.
 *      - 입력 정책: 아래 수령자는 행 번호와 함께 배치 전체를 거부(FireBatchSenderInvalidRecipient).
 *        (1) 0x0000…0000 ~ 0x0000…FFFF: 0 주소(ETH 영구 소실), 프리컴파일(0x01~0x11, Base P256VERIFY 0x100: 값을
 *            받고 성공하므로 ETH가 소실됨), 0x…dEaD 등 하위 예약 대역 (소각이 목적이면 토큰의 burn을 사용).
 *        (2) 0x4200…0000 ~ 0x4200…FFFF: OP Stack(Base) 프리디플로이 대역. WETH(0x…0006)는 받은 ETH를 이 컨트랙트
 *            명의의 WETH로 적립해 영구 동결하고, L2ToL1MessagePasser(0x…0016)는 이 컨트랙트 주소로 L1 출금을 시작하며,
 *            수수료 볼트는 운영자에게 귀속됨. (1)·(2)는 개인 키·사용자 컨트랙트가 존재할 수 없는 대역이라 정상 수령자를 막지 않음.
 *        (3) 이 컨트랙트, (4) FIRE 토큰 컨트랙트: 회수(rescue) 함수가 없어 보낸 자산이 영구 동결.
 *        (5) 송신자 자신(msg.sender): 가치 이동 없이 사용 실적·거래량만 부풀리는 자기 송금.
 *        (6) sendERC20의 token 컨트랙트 자신: 토큰을 그 토큰 컨트랙트로 보내는 대표적 붙여넣기 실수(대부분 회수 불가).
 *        금액 0은 CSV 파싱 오류 가능성이 높고 0원 전송 이벤트 스팸(주소 오염 피싱)에 악용될 수 있어 거부.
 *        같은 주소 중복은 정상 사용(분할 지급)으로 보고 허용.
 *      - 잔여 위험(온체인에서 일반적으로 판별 불가): ETH를 받으면 msg.sender 명의로 자산을 적립하는 임의의 컨트랙트
 *        (WETH형 래퍼, ETH를 예치·민팅하는 볼트 등)로 보낸 행은 그 자산이 이 컨트랙트 명의로 적립되어 회수할 수 없음.
 *        알려진 대역 (2)는 거부하며, 그 밖의 컨트랙트 수령자는 프론트엔드가 지갑 종류를 확인하고 경고해야 함.
 *      - nonReentrant(EIP-1153 transient storage)로 두 전송 함수 모두 재진입 차단. Base는 Cancun(Ecotone)부터 지원.
 */
contract FireBatchSender is Ownable2Step, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    /**
     * @notice 배치 1회당 최대 수령자 수.
     * @dev EIP-7825 트랜잭션 가스 상한 16,777,216 대비 15% 이상 여유(14,260,633 gas 이하)를 두도록 실측으로 결정.
     *      측정 조건: forge 1.8.5 isolate 모드(호출 1건 = 트랜잭션 1건, 기본 21,000 포함), EVM cancun(7702 항목은 prague),
     *      FIRE 소각 수수료 부과, 수령자 전원 cold. 수치는 calldata 전 바이트를 0이 아닌 값으로 가정한 최악 상한이며
     *      test_Gas_* 테스트가 매 실행마다 재검증함 (괄호는 상한 16,777,216 대비 비율).
     *      - ETH → 신규 계정(잔고·nonce·코드 없음): 100명 3,706,866 / 300명 11,014,994 gas (65.7%), 수령자당 약 36,500
     *      - ERC-20(FIRE, OpenZeppelin ERC20) → 신규 보유자: 100명 2,918,474 / 300명 8,648,482 gas (51.5%), 수령자당 약 28,700
     *      - ETH → 받은 가스(ETH_RECIPIENT_GAS + stipend)를 모두 태우는 컨트랙트 300개: 13,061,638 gas (77.9%)
     *      - ETH → 서로 다른 소각 컨트랙트에 위임한 EIP-7702 EOA 300개(위임 대상 cold 접근 추가): 13,841,478 gas (82.5%)
     *      - 참고: Base USDC(FiatToken 프록시) → 신규 보유자 300명 9,342,629 gas (55.7%), 수령자당 약 30,900
     *        (Base 메인넷 포크 블록 52,319,000 실측)
     *      즉 어떤 수령자 조합이든 300명 배치는 상한의 85% 이내. 350명은 신규 계정 기준 약 76.5%지만 위임 EOA 소각 기준
     *      약 96%로 여유 기준을 넘고, 400명은 신규 계정만으로도 약 87.4%라 기준 미달. 후크·프록시가 무거운 토큰이나 향후
     *      가스 재책정(예: EIP-8037)은 수령자당 비용을 바꿀 수 있으므로 프론트엔드는 eth_estimateGas로 확인하고 필요하면
     *      배치를 나눠야 함.
     */
    uint256 public constant MAX_RECIPIENTS = 300;

    /**
     * @notice ETH 수령자 1명에게 전달하는 최대 가스. 값이 있는 호출이므로 EVM이 2,300 stipend를 더해 수령자는 최대
     *         32,300 gas로 실행됨.
     * @dev 남은 가스를 모두 넘기면 수령자가 63/64를 태우고 정상 반환하는 것만으로 다음 행에서 행 번호 없는 out-of-gas가
     *      나고 송신자는 가스 한도 전체를 지불함(그리핑, 300명 배치의 3번 행이면 16M 가스로도 불가능했음). 상한을 두면
     *      (a) 수령자 때문에 실패하면 항상 FireBatchSenderETHTransferFailed(index, recipient)가 나오고
     *          (무한 루프 수령자: 30명 배치 기준 약 25만 gas에서 행 번호와 함께 취소),
     *      (b) 수령자 1명이 늘릴 수 있는 비용이 제한되며(같은 300명 배치가 약 1,090만 gas로 완료),
     *      (c) 전원이 가스를 태우는 최악의 300명 배치도 상한의 85% 이내(MAX_RECIPIENTS 실측 참고).
     *      Base 메인넷 포크(블록 52,319,000) 실측, ETH 수령에 필요한 최소 가스 인자(stipend 별도):
     *        Safe v1.3.0·v1.4.1 프록시 4,029 / Coinbase Smart Wallet 2,507 / EIP-7702 위임 EOA(MetaMask 위임 컨트랙트) 0 /
     *        일반 EOA 0 → 가장 무거운 Safe(4,029) 대비 7배 이상 여유. 포크 테스트(FireBatchSenderForkTest)가 재확인.
     *      수령 시 신규 저장소 슬롯을 2개 이상 쓰는 등 32,300 gas를 넘게 쓰는 컨트랙트는 해당 행 번호로 실패하므로
     *      목록에서 빼고 별도로 송금해야 함.
     */
    uint256 public constant ETH_RECIPIENT_GAS = 30_000;

    /**
     * @notice burnFee의 하드 상한: 1,000,000 FIRE (총발행량의 0.1%, 기본 수수료 1만 FIRE의 100배).
     * @dev 사용자는 maxBurnFee로 이미 보호되지만 상한을 코드에 고정하는 이유:
     *      (1) maxBurnFee에 type(uint256).max를 넘기는 부주의한 연동(스크립트·봇)의 최대 손실을 제한,
     *      (2) 소유자(Safe) 키가 탈취되어도 사용자가 낼 수 있는 수수료의 절대 상한을 공개적으로 보장,
     *      (3) "수수료는 어떤 경우에도 100만 FIRE를 넘지 않음"을 백서가 아닌 코드로 증명.
     *      FIRE 가격이 1/100로 떨어져도 수수료 가치를 유지할 여유를 둔 값이며, 인하(0 포함)는 언제든 가능.
     */
    uint256 public constant MAX_BURN_FEE = 1_000_000 * 1e18;

    /// @dev 수령자 거부 대역 (1): 0 주소·프리컴파일·하위 예약 대역의 마지막 주소 0x…FFFF.
    address private constant _LAST_RESERVED_ADDRESS = 0x000000000000000000000000000000000000FFff;
    /// @dev 수령자 거부 대역 (2): OP Stack 프리디플로이 네임스페이스 0x4200…0000 ~ 0x4200…FFFF.
    ///      Base 메인넷에는 0x4200…0000 ~ 0x4200…0800에 프록시가 배치되어 있으며, 향후 추가분까지 포함하도록 넓게 잡음.
    address private constant _FIRST_OP_PREDEPLOY = 0x4200000000000000000000000000000000000000;
    address private constant _LAST_OP_PREDEPLOY = 0x420000000000000000000000000000000000FffF;

    // 요구사항 ABI(fireToken())와 같은 이름을 유지. immutable 대문자 표기 lint 규칙의 의도된 예외.
    // forge-lint: disable-next-item(screaming-snake-case-immutable)
    /// @notice 소각 수수료로 쓰는 FIRE 토큰 주소 (배포 후 변경 불가).
    address public immutable fireToken;

    /// @notice 수수료 없이 보낼 수 있는 최대 수령자 수. 수령자 수가 이 값을 초과할 때만 burnFee 부과.
    uint256 public freeRecipientLimit;

    /// @notice 유료 배치 1회당 소각되는 FIRE 수량(wei 단위, 18 decimals). 0이면 모든 배치 무료.
    uint256 public burnFee;

    /**
     * @notice 배치 전송 완료. 전송·소각과 같은 트랜잭션에 기록되므로 트랜잭션이 성공했다면 모든 전송 호출도 성공한 것.
     * @dev token·recipients·total은 호출자가 넘긴 입력을 그대로 기록한 값이며 가치 이동의 증명이 아님.
     *      임의의 ERC-20은 transferFrom이 아무것도 옮기지 않고 true를 반환할 수 있음(가짜 토큰). 사용 실적 집계
     *      (예: 2차 에어드롭 기준)는 같은 트랜잭션의 토큰 Transfer 로그(ETH는 내부 트랜잭션 트레이스)로 실제 이동을 확인하고,
     *      허용 자산 목록·고유 수령자 수·최소 금액 등 사전 공개 기준을 적용해야 함. burnedFee는 같은 트랜잭션의
     *      FIRE Transfer(송신자 → 0 주소) 로그로 검증 가능.
     * @param sender 자산을 보낸 지갑 (수수료 FIRE도 이 지갑에서 소각)
     * @param token 전송한 ERC-20 주소(호출자 지정). ETH 배치는 address(0)
     * @param recipients 행 수(같은 주소 중복 포함)
     * @param total 요청 전송 총액(수수료 제외). 전송 수수료형 토큰은 실수령액이 더 적고, 가짜 토큰은 실제 이동이 0일 수 있음
     * @param burnedFee 소각된 FIRE 수량 (무료 배치는 0)
     */
    event BatchSent(
        address indexed sender, address indexed token, uint256 recipients, uint256 total, uint256 burnedFee
    );

    /// @notice 무료 수령자 수 한도 변경 (생성자에서도 1회 발생).
    event FreeRecipientLimitUpdated(uint256 previousLimit, uint256 newLimit);

    /// @notice 소각 수수료 변경 (생성자에서도 1회 발생).
    event BurnFeeUpdated(uint256 previousFee, uint256 newFee);

    /// @dev FIRE 토큰 주소가 0이거나 코드가 없음.
    error FireBatchSenderInvalidFireToken(address fireToken);
    /// @dev 무료 수령자 수 한도가 MAX_RECIPIENTS를 초과.
    error FireBatchSenderFreeRecipientLimitTooHigh(uint256 limit, uint256 maxLimit);
    /// @dev 소각 수수료가 MAX_BURN_FEE를 초과.
    error FireBatchSenderBurnFeeTooHigh(uint256 fee, uint256 maxFee);
    /// @dev 소유권 포기는 수수료 설정을 영구 동결하므로 차단 (아래 renounceOwnership 참고).
    error FireBatchSenderRenounceDisabled();
    /// @dev recipients와 amounts 길이가 다름.
    error FireBatchSenderLengthMismatch(uint256 recipients, uint256 amounts);
    /// @dev 수령자가 없음.
    error FireBatchSenderEmptyBatch();
    /// @dev 수령자 수가 MAX_RECIPIENTS를 초과.
    error FireBatchSenderTooManyRecipients(uint256 recipients, uint256 maxRecipients);
    /// @dev index 번째 수령자가 입력 정책(컨트랙트 설명의 (1)~(6))에 따라 거부됨.
    error FireBatchSenderInvalidRecipient(uint256 index, address recipient);
    /// @dev index 번째 금액이 0.
    error FireBatchSenderZeroAmount(uint256 index);
    /// @dev msg.value가 amounts 합계와 다름 (초과·부족 모두).
    error FireBatchSenderValueMismatch(uint256 expected, uint256 received);
    /// @dev 현재 수수료가 사용자가 지정한 maxBurnFee를 초과 (호출 직전 수수료 인상 등).
    error FireBatchSenderBurnFeeExceedsMax(uint256 fee, uint256 maxBurnFee);
    /// @dev index 번째 수령자에게 ETH 전송 실패 (수령 거부, ETH_RECIPIENT_GAS 초과 사용, 재진입 시도 등).
    error FireBatchSenderETHTransferFailed(uint256 index, address recipient);

    /**
     * @param fireToken_ FIRE 토큰 주소 (컨트랙트만 허용)
     * @param initialOwner 수수료 설정 권한자. 운영 시 트레저리 Safe 멀티시그 (0 주소 불가)
     * @param initialFreeRecipientLimit 무료 수령자 수 한도 (0 ~ MAX_RECIPIENTS)
     * @param initialBurnFee 유료 배치 1회당 소각 FIRE (wei 단위, 0 ~ MAX_BURN_FEE)
     */
    constructor(address fireToken_, address initialOwner, uint256 initialFreeRecipientLimit, uint256 initialBurnFee)
        Ownable(initialOwner)
    {
        if (fireToken_ == address(0) || fireToken_.code.length == 0) {
            revert FireBatchSenderInvalidFireToken(fireToken_);
        }
        fireToken = fireToken_;
        _setFreeRecipientLimit(initialFreeRecipientLimit);
        _setBurnFee(initialBurnFee);
    }

    // 함수명은 요구사항(sendETH/sendERC20 ABI) 그대로 유지. ETH는 ERC처럼 약어이므로 mixedCase 예외로 처리.
    // forge-lint: disable-next-item(mixed-case-function)
    /**
     * @notice ETH를 여러 지갑에 한 번에 전송.
     * @dev msg.value == sum(amounts) 이어야 함(초과·부족 모두 거부 → 컨트랙트에 ETH가 남지 않음).
     *      수령자마다 ETH_RECIPIENT_GAS(+2,300 stipend)까지만 전달하므로 Safe·스마트 지갑·EIP-7702 위임 EOA는 수령 가능하고,
     *      수령자가 거부하거나 상한을 넘게 쓰면 FireBatchSenderETHTransferFailed(index, recipient)로 배치 전체 취소.
     *      가스를 태우고 정상 반환하는 수령자도 상한만큼만 비용을 늘릴 수 있음. 수령자의 반환 데이터는 메모리로
     *      복사하지 않음(returndata bomb 방지).
     * @param recipients 수령자 목록 (1 ~ MAX_RECIPIENTS 명, 컨트랙트 설명의 거부 대상 불가, 중복 허용)
     * @param amounts 수령자별 금액(wei, 0 불가)
     * @param maxBurnFee 지불 의사가 있는 FIRE 소각 수수료 상한. quoteBurnFee(recipients.length) 이상이어야 함
     */
    function sendETH(address[] calldata recipients, uint256[] calldata amounts, uint256 maxBurnFee)
        external
        payable
        nonReentrant
    {
        // ETH 배치에는 추가 거부 주소가 없음(address(0)은 이미 거부 대역 (1)에 포함)
        (uint256 total, uint256 fee) = _checkBatch(recipients, amounts, maxBurnFee, address(0));
        if (msg.value != total) revert FireBatchSenderValueMismatch(total, msg.value);

        emit BatchSent(msg.sender, address(0), recipients.length, total, fee);
        _chargeBurnFee(fee);

        for (uint256 i = 0; i < recipients.length; ++i) {
            if (!_sendValue(recipients[i], amounts[i])) {
                // 원자적 배치(전부 성공 또는 전부 취소)가 요구사항이므로 루프 안 revert는 의도된 동작.
                // forge-lint: disable-next-line(require-revert-in-loop)
                revert FireBatchSenderETHTransferFailed(i, recipients[i]);
            }
        }
    }

    /**
     * @notice ERC-20 토큰을 여러 지갑에 한 번에 전송.
     * @dev 송신자는 사전에 token을 이 컨트랙트에 sum(amounts) 이상 approve해야 함
     *      (token이 FIRE이고 수수료가 부과되면 sum(amounts) + 수수료).
     *      반환값이 없는 토큰(USDT형)은 SafeERC20으로 지원. false를 반환하면 SafeERC20FailedOperation,
     *      revert하면 토큰 자신의 오류(예: ERC20InsufficientAllowance)가 그대로 전달되어 배치 전체 취소
     *      (이 경우 실패 인덱스는 포함되지 않으므로 프론트엔드에서 잔고·승인액·차단 목록을 사전 검증 권장).
     *      토큰 호출에는 가스 상한을 두지 않음(프록시·후크가 무거운 정상 토큰을 깨뜨리지 않기 위해). 따라서 수령자 후크를
     *      호출하는 토큰(ERC-777형)은 수령자가 가스를 태워 배치를 실패시킬 수 있음 → eth_estimateGas·트레이스로 확인.
     *      전송 수수료(fee-on-transfer) 토큰은 수령자가 amounts보다 적게 받으며 BatchSent.total은 요청 총액.
     *      token 주소에 코드가 없으면 SafeERC20FailedOperation으로 거부.
     * @param token 전송할 ERC-20
     * @param recipients 수령자 목록 (1 ~ MAX_RECIPIENTS 명, 컨트랙트 설명의 거부 대상과 token 자신 불가, 중복 허용)
     * @param amounts 수령자별 금액(토큰 최소 단위, 0 불가)
     * @param maxBurnFee 지불 의사가 있는 FIRE 소각 수수료 상한. quoteBurnFee(recipients.length) 이상이어야 함
     */
    function sendERC20(IERC20 token, address[] calldata recipients, uint256[] calldata amounts, uint256 maxBurnFee)
        external
        nonReentrant
    {
        (uint256 total, uint256 fee) = _checkBatch(recipients, amounts, maxBurnFee, address(token));

        emit BatchSent(msg.sender, address(token), recipients.length, total, fee);
        _chargeBurnFee(fee);

        for (uint256 i = 0; i < recipients.length; ++i) {
            token.safeTransferFrom(msg.sender, recipients[i], amounts[i]);
        }
    }

    /**
     * @notice recipientCount 명 배치에 부과될 FIRE 소각 수수료. 프론트엔드의 maxBurnFee·FIRE approve 계산용.
     * @dev 수령자 수가 freeRecipientLimit 이하이면 0, 초과하면 burnFee (수령자 수와 무관한 정액).
     */
    function quoteBurnFee(uint256 recipientCount) public view returns (uint256) {
        return recipientCount > freeRecipientLimit ? burnFee : 0;
    }

    /// @notice 무료 수령자 수 한도 변경 (소유자 전용, 0 ~ MAX_RECIPIENTS). 0이면 모든 배치 유료.
    function setFreeRecipientLimit(uint256 newLimit) external onlyOwner {
        _setFreeRecipientLimit(newLimit);
    }

    /// @notice 유료 배치 소각 수수료 변경 (소유자 전용, wei 단위, 0 ~ MAX_BURN_FEE).
    function setBurnFee(uint256 newFee) external onlyOwner {
        _setBurnFee(newFee);
    }

    /**
     * @notice 항상 revert. 소유권 포기 불가.
     * @dev 소유권을 포기하면 FIRE 수량으로 고정된 수수료를 가격 변동에 맞춰 조정할 수 없게 됨
     *      (가이드 1.3: FIRE 기준 수량은 코드에 고정하지 않고 조정 가능하게). 사용자 자산과는 무관하며,
     *      소유자 교체는 Ownable2Step(transferOwnership → 새 소유자 acceptOwnership)으로만 가능.
     */
    function renounceOwnership() public pure override {
        revert FireBatchSenderRenounceDisabled();
    }

    function _setFreeRecipientLimit(uint256 newLimit) private {
        if (newLimit > MAX_RECIPIENTS) revert FireBatchSenderFreeRecipientLimitTooHigh(newLimit, MAX_RECIPIENTS);
        emit FreeRecipientLimitUpdated(freeRecipientLimit, newLimit);
        freeRecipientLimit = newLimit;
    }

    function _setBurnFee(uint256 newFee) private {
        if (newFee > MAX_BURN_FEE) revert FireBatchSenderBurnFeeTooHigh(newFee, MAX_BURN_FEE);
        emit BurnFeeUpdated(burnFee, newFee);
        burnFee = newFee;
    }

    /// @dev 수수료를 송신자 지갑에서 직접 소각. FIRE가 이 컨트랙트나 소유자를 거치는 경로는 없음.
    function _chargeBurnFee(uint256 fee) private {
        if (fee != 0) ERC20Burnable(fireToken).burnFrom(msg.sender, fee);
    }

    /// @dev 빈 calldata로 수령자의 receive()를 호출. 가스는 ETH_RECIPIENT_GAS로 제한하고 반환 데이터는 복사하지 않음.
    ///      OZ LowLevelCall에는 가스 지정 함수가 없고, Solidity의 call{gas: ...}는 반환 데이터를 메모리로 복사할 수 있어
    ///      (returndata bomb) 메모리를 건드리지 않는 단일 call 명령만 사용.
    function _sendValue(address recipient, uint256 amount) private returns (bool success) {
        // forge-lint: disable-next-line(inline-assembly)
        assembly ("memory-safe") {
            success := call(ETH_RECIPIENT_GAS, recipient, amount, 0, 0, 0, 0)
        }
    }

    /**
     * @dev 외부 호출 전에 모든 입력을 검증(Checks-Effects-Interactions)하고 요청 총액과 수수료를 계산.
     *      합계 오버플로는 Solidity 0.8 산술 검사로 revert(Panic 0x11).
     * @param excluded 이 배치에서 추가로 거부할 주소 (sendERC20: token 컨트랙트 자신)
     */
    function _checkBatch(
        address[] calldata recipients,
        uint256[] calldata amounts,
        uint256 maxBurnFee,
        address excluded
    ) private view returns (uint256 total, uint256 fee) {
        uint256 count = recipients.length;
        if (count != amounts.length) revert FireBatchSenderLengthMismatch(count, amounts.length);
        if (count == 0) revert FireBatchSenderEmptyBatch();
        if (count > MAX_RECIPIENTS) revert FireBatchSenderTooManyRecipients(count, MAX_RECIPIENTS);

        for (uint256 i = 0; i < count; ++i) {
            address recipient = recipients[i];
            uint256 amount = amounts[i];
            // 잘못된 행이 하나라도 있으면 배치 전체를 거부하고 행 번호를 알려 주는 것이 의도된 동작.
            if (_isRejectedRecipient(recipient, excluded)) {
                // forge-lint: disable-next-line(require-revert-in-loop)
                revert FireBatchSenderInvalidRecipient(i, recipient);
            }
            // forge-lint: disable-next-line(require-revert-in-loop)
            if (amount == 0) revert FireBatchSenderZeroAmount(i);
            total += amount;
        }

        fee = quoteBurnFee(count);
        if (fee > maxBurnFee) revert FireBatchSenderBurnFeeExceedsMax(fee, maxBurnFee);
    }

    /// @dev 컨트랙트 설명의 입력 정책 (1)~(6).
    function _isRejectedRecipient(address recipient, address excluded) private view returns (bool) {
        return recipient <= _LAST_RESERVED_ADDRESS
            || (recipient >= _FIRST_OP_PREDEPLOY && recipient <= _LAST_OP_PREDEPLOY) || recipient == address(this)
            || recipient == fireToken || recipient == msg.sender || recipient == excluded;
    }
}
