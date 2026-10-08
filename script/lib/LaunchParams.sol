// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title LaunchParams
 * @dev FIRE 런칭 파라미터의 단일 출처 (가이드 2.2절 공급량 분배 · 2.3절 시딩 · 3.1절 베스팅 · 5장 DEX).
 *      Deploy / CreatePool / PostDeployCheck 스크립트와 테스트가 모두 이 값을 참조함.
 */
library LaunchParams {
    // ── 체인 ──
    uint256 internal constant BASE_MAINNET = 8453;
    uint256 internal constant BASE_SEPOLIA = 84532;
    uint256 internal constant LOCAL_ANVIL = 31337;

    /// @dev Base 메인넷 브로드캐스트 시 환경 변수 CONFIRM_MAINNET에 이 문구를 정확히 넣어야 함.
    string internal constant CONFIRM_MAINNET_PHRASE = "I_UNDERSTAND";

    // ── 멀티시그 (2.2절: 서명자 최소 2-of-3) ──
    /// @dev 메인넷 TREASURY_SAFE(Deploy)와 BATCH_SENDER_OWNER(DeployBatchSender)의 최소 Safe 구성.
    uint256 internal constant SAFE_MIN_THRESHOLD = 2;
    uint256 internal constant SAFE_MIN_OWNERS = 3;

    // ── 베스팅 (3.1절) ──
    uint64 internal constant CLIFF = 180 days; // 15,552,000초: 이 기간 해제량 0
    uint64 internal constant LINEAR = 540 days; // 46,656,000초: 클리프 종료 후 초 단위 선형 해제

    // ── 공급량 분배 (2.2절, 18 decimals) ──
    uint256 internal constant TOTAL_SUPPLY = 1_000_000_000e18;
    uint256 internal constant VESTING_AMOUNT = 200_000_000e18; // 20%: 토큰 생성자가 FireVesting으로 직접 발행
    uint256 internal constant LP_AMOUNT = 700_000_000e18; // 70%: Uniswap V3 전체 범위 포지션
    uint256 internal constant TREASURY_AMOUNT = 50_000_000e18; // 5%: Safe 멀티시그 (CEX 상장·MM 예비분)
    uint256 internal constant AIRDROP_AMOUNT = 50_000_000e18; // 5%: 에어드롭 전용 지갑 (1차 2,000만 + 2차 3,000만)

    // ── DEX 시딩 (2.3절, 5장) ──
    uint256 internal constant DEFAULT_SEED_ETH = 3 ether;
    uint256 internal constant MIN_SEED_ETH = 0.001 ether; // wei/ETH 단위 혼동(예: SEED_ETH=3) 차단용 하한
    uint256 internal constant MAINNET_MIN_SEED_ETH = 1 ether; // 2.3절 표의 최소 선택지
    uint24 internal constant FEE_TIER_1_PERCENT = 10_000; // 기본값
    uint24 internal constant FEE_TIER_0_3_PERCENT = 3000; // 대안
    int24 internal constant TICK_SPACING_1_PERCENT = 200;
    int24 internal constant TICK_SPACING_0_3_PERCENT = 60;
    uint256 internal constant DEFAULT_SLIPPAGE_BPS = 50;
    uint256 internal constant MAX_SLIPPAGE_BPS = 100;
    uint256 internal constant MAX_PRICE_DEVIATION_BPS = 100; // 기존(유동성 0) 풀 가격 허용 편차 1%
    uint256 internal constant MINT_DEADLINE = 30 minutes;
    uint256 internal constant LP_LOCK_DAYS = 365;
    /// @dev 락커가 락업 시점에 LP 유동성에서 떼어 가는 수수료의 허용 상한(1%). UNCX V3.1(Base) 실측 lpFee:
    ///      DEFAULT 0.5% · LVP 0.8% · LLP 0.3% (getFee, 블록 52,317,000). 이보다 크게 줄었으면 락커 수수료가 아니라고 봄.
    uint256 internal constant MAX_LOCK_FEE_BPS = 100;

    /// @dev EIP-7825 트랜잭션당 가스 상한. Base에 적용될 수 있으므로 모든 트랜잭션을 이 아래로 유지.
    uint256 internal constant TX_GAS_CAP = 16_777_216;
    /// @dev forge script 기본 가스 추정 배수(130%). 추정치 × 배수가 상한을 넘지 않는지 확인할 때 사용.
    uint256 internal constant GAS_ESTIMATE_MULTIPLIER_PERCENT = 130;

    // ── 공개 기록 (deployments/<chainId>.json) ──
    /// @dev forge는 스크립트를 먼저 시뮬레이션한 뒤 전송하므로 --broadcast 실행이 쓰는 기록은 "pending"(전송 전 값)임.
    ///      전송이 채굴된 뒤 각 스크립트의 confirm()이 온체인 값으로 다시 써서 "confirmed"로 바꿈.
    string internal constant RECORD_PENDING = "pending";
    string internal constant RECORD_CONFIRMED = "confirmed";
    /// @dev 기록된 vesting.start(시뮬레이션 블록 기준)와 온체인 값의 허용 차이(pending 기록의 트랜잭션 포함 지연).
    uint256 internal constant MAX_INCLUSION_DELAY = 1 days;

    // ── 온체인 조회 한도 ──
    /// @dev 중복 배포 검사: 배포자의 최근 CREATE 주소를 몇 개까지 거슬러 확인할지.
    uint256 internal constant MAX_PRIOR_NONCE_SCAN = 256;
    /// @dev LP NFT 탐색: 소유자의 NFT를 가장 오래된 것(인덱스 0)부터 몇 개까지 확인할지. 런칭 뒤에 제3자가 배포 지갑으로
    ///      보내는 NFT는 항상 런칭 포지션 뒤 인덱스에 붙으므로 대량으로 보내도 밀려나지 않음. 런칭 전에 이보다 많이 보내 두면
    ///      런칭 포지션이 범위 밖에 놓이며, 이때 confirm()/PostDeployCheck는 LP_TOKEN_ID 지정을 안내함.
    uint256 internal constant MAX_POSITION_SCAN = 100;
    /// @dev eth_getLogs 블록 구간 크기. Base 공개 RPC는 한 번에 500블록까지만 허용함.
    uint256 internal constant LOG_WINDOW_BLOCKS = 500;
    /// @dev confirm()이 mint/Initialize 이벤트를 찾는 최대 구간 수 (500 × 40 = 20,000블록 ≈ 11시간).
    uint256 internal constant MAX_LOG_WINDOWS = 40;
}
