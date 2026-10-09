# 보안 정책 (FIRE 컨트랙트)

**[English](SECURITY.en.md)** | **[한국어](SECURITY.md)**

이 문서는 FIRE 컨트랙트의 신뢰 모델, 테스트가 실제로 증명하는 범위, 남은 위험과 운영 전제, 정적 분석 결과,
취약점 제보 방법을 정리합니다. 기준 시점: 2026-10-08 (OpenZeppelin Contracts v5.7.0, solc 0.8.30, Foundry v1.8.5).

## 1. 범위

| 구분 | 대상 | 비고 |
| :--- | :--- | :--- |
| 온체인 | `src/FireToken.sol`, `src/FireVesting.sol`, `src/FireMerkleDistributor.sol`, `src/FireBatchSender.sol` | 업그레이드·일시정지 기능이 없어 배포 후 코드를 바꿀 수 없음 |
| 오프체인 (운영 도구) | `script/` forge 스크립트, `airdrop/` 목록 생성·검증 도구 | 배포되지 않지만 잘못된 주소·수량·순서로 실제 자산 손실을 낼 수 있으므로 범위에 포함 |
| 범위 밖 | Uniswap V3, WETH, Safe, UNCX·Team Finance 락커, Base 시스템 컨트랙트·시퀀서, 지갑·프론트엔드 | 외부 시스템으로서 신뢰 전제에만 포함 |

## 2. 감사 현황

- **외부 보안 감사를 받지 않았습니다.** (2026-10-08 기준)
- 런칭 컨트랙트(`FireToken`, `FireVesting`)는 감사받은 OpenZeppelin Contracts v5.7.0을 **라이브러리 코드 수정 없이**
  상속하며, 직접 추가한 코드는 생성자 검사와 소유권 보호 몇 줄뿐입니다. `lib/openzeppelin-contracts`는 태그 v5.7.0
  커밋 `cab19933c33c2ad1d4c7a84864a3601dddfd16f3`에 고정되어 있습니다(`foundry.lock`, CI가 대조).
- 자체 검증: 단위·퍼즈·불변식·포크 테스트(4절), `forge lint`(경고 0건), Slither(6절). 이는 감사를 대신하지 않습니다.

## 3. 신뢰 모델

### 3.1 FireToken

- **특권 주체가 없습니다.** owner·admin·minter·pauser·업그레이드·블랙리스트·거래세가 없고, 발행은 생성자에서만 일어납니다
  (2억 → `vesting` 인자 주소, 8억 → 생성자를 실행한 `msg.sender`). 보유자는 자기 토큰의 전송·승인·소각만 할 수 있습니다.
- 생성자의 `vesting` 검사(코드 존재, `start() ≥ 현재 시각`, `duration() > 0`)는 **실수 방지용**입니다. 일반 지갑·Safe·
  EIP-7702 위임 지갑 주소는 거부하지만, 악의적인 배포자가 만든 가짜 베스팅 컨트랙트까지 막지는 못합니다. 2억 FIRE가
  실제로 잠겨 있는지는 BaseScan 소스 검증(`FireVesting` 코드·생성자 인자)과 `PostDeployCheck` 보고서로 확인해야 합니다.
  `PostDeployCheck`는 기록이 가리키는 `FireVesting`·`FireToken`의 런타임 코드를 이 저장소에서 컴파일한 코드와 대조하고
  (immutable 값은 같은 값으로 다시 만들어 비교), 두 주소가 배포 지갑의 연속된 CREATE 주소인지 확인하므로, 베스팅처럼
  응답하지만 인출 함수가 있는 컨트랙트나 숨은 함수를 붙인 토큰은 FAIL로 드러납니다.
- 8억 FIRE는 `msg.sender`에게 발행되므로 CREATE2 팩토리·Safe 등 다른 컨트랙트를 거쳐 배포하면 그 컨트랙트가 받습니다.
  `script/Deploy.s.sol`은 배포 지갑에서 직접(일반 CREATE) 배포하고 같은 브로드캐스트에서 트레저리·에어드롭 몫을 나눕니다.
  풀 생성 전까지 배포 지갑이 7억 FIRE를 보유하는 구간은 배포 지갑 키 보안에 의존합니다.
- `ERC20Permit`(EIP-2612): 오프체인 서명만으로 승인이 생기므로, 사용자는 피싱 사이트의 permit 서명 요청에 주의해야 합니다.

### 3.2 FireVesting

- owner(= 수익자)만 해제분을 받습니다. `release()`는 누구나 호출할 수 있지만 토큰은 항상 그 시점의 `owner()`에게 갑니다.
  owner도 일정(클리프 180일 → 540일 선형)보다 먼저 꺼낼 수 없습니다.
- 수령 지갑 교체는 `Ownable2Step`(현재 owner가 `transferOwnership` → 새 지갑이 `acceptOwnership`)으로만 가능하고,
  `renounceOwnership()`은 항상 실패합니다(owner가 0 주소가 되어 잔여 물량이 동결되는 사고 방지).
- **최초 수익자는 생성자에서 수락 절차 없이 곧바로 owner가 됩니다.** 오타·통제하지 않는 주소(예: 다른 체인에만 배포된
  Safe 주소)를 넣으면 2억 FIRE가 영구히 묶입니다 → 5.1절.
- owner 키를 잃으면 남은 물량을 꺼낼 수 없습니다. 하드웨어 지갑 또는 Base에 배포된 Safe를 수익자로 쓰십시오.
- OpenZeppelin `VestingWallet`은 나중에 들어온 입금도 처음부터 있던 것처럼 일정에 따라 계산합니다. 해제가 시작된 뒤
  추가로 보낸 FIRE·ETH·다른 토큰은 일부가 즉시 해제 가능해지므로 2억 FIRE 외에는 보내지 마십시오.

### 3.3 FireMerkleDistributor

- **관리자 권한이 없습니다.** 토큰·Merkle Root·마감 시각·회수 주소가 immutable이라 배포 후 누구도(개발자 포함) 목록·수량·
  기한·회수처를 바꿀 수 없습니다. 반대로 목록 오류도 고칠 수 없으므로, 방어선은 배포 전 검증·공개·이의 제기 기간뿐입니다
  (`airdrop/README.md`).
- 마감 시각까지(포함) `claim`, 그 이후 `sweep`만 가능하고 두 구간은 겹치지 않습니다. 마감은 배포 시점부터 365일 이내입니다.
- 예치가 부족하면 해당 claim만 되돌려지고(청구 기록 포함) 누구나 FIRE를 더 보내 채울 수 있으며, 초과분은 마감 후
  `sweep`으로 회수됩니다.
- 같은 Root의 분배 컨트랙트가 둘이면 모든 수령자가 두 번 받을 수 있습니다. `DeployAirdrop`은 같은 지갑·토큰·Root의
  이전 배포가 체인에 있으면 거부합니다.

### 3.4 FireBatchSender

- owner(트레저리 Safe)의 권한은 `freeRecipientLimit`(0~300)과 `burnFee`(0~`MAX_BURN_FEE` = 100만 FIRE) 변경뿐입니다.
  사용자 자산을 옮기거나, 일시정지하거나, 컨트랙트 잔액을 출금하는 함수가 없습니다. 모든 전송의 `from`은 호출자 본인이라,
  무한 승인을 해 둔 지갑이라도 본인이 직접 호출하지 않는 한 owner나 제3자가 그 지갑의 토큰을 옮길 수 없습니다.
- 수수료는 송신자 지갑에서 `burnFrom`으로 같은 트랜잭션에서 소각되며 누구에게도 지급되지 않습니다. 사용자는 호출마다
  `maxBurnFee`로 상한을 정하므로, 수수료 인상 트랜잭션이 먼저 처리되어도 상한을 넘는 수수료는 청구되지 않습니다.
- 수령자 정책: 0 주소·프리컴파일·하위 예약 대역, OP Stack 프리디플로이 대역(WETH·L2ToL1MessagePasser 등), 이 컨트랙트,
  FIRE 토큰, 송신자 자신, 전송 대상 토큰 자신, 금액 0 행을 행 번호와 함께 거부합니다. ETH 수령자에게는 30,000 gas
  (+2,300 stipend)만 전달하므로 그보다 많이 쓰는 수령자 컨트랙트는 그 행 번호로 실패합니다.
- 받은 ETH를 `msg.sender` 명의로 적립하는 임의의 컨트랙트(WETH형 래퍼, 예치형 볼트 등)에 보낸 행은 그 자산이 이
  컨트랙트 명의로 쌓여 회수할 수 없습니다. 알려진 대역 밖의 컨트랙트 수령자는 프론트엔드가 경고해야 합니다.
- 수령자 후크가 있는 토큰(ERC-777형)은 수령자가 가스를 태워 배치를 실패시킬 수 있고(자금 손실은 없음), 전송 수수료형
  토큰은 수령자가 요청보다 적게 받습니다. 프론트엔드는 `eth_estimateGas`로 확인하고 필요하면 배치를 나눠야 합니다.

## 4. 테스트가 증명하는 것

수치는 2026-10-08 로컬 실행 기준입니다: 17개 스위트 534건(RPC 없이 493건 통과 + 포크 41건 skip, 공개 RPC로 534건 통과),
에어드롭 도구 54건.

**커버리지** (`BASE_RPC_URL=… BASE_SEPOLIA_RPC_URL=… forge coverage --report summary --no-match-coverage '^(lib|test)/'`,
레거시 코드 생성기·최적화 끔, 532건 통과 + 바이트코드 고정 테스트 2건 스스로 건너뜀): `src/` 4개 컨트랙트는 라인·구문·
분기·함수 100%(분기가 없는 `FireVesting` 제외), `src/`+`script/` 전체는 라인 96.94%(2153/2221)·구문 97.01%·분기
91.47%(579/633)·함수 96.56%. `--ir-minimum`(viaIR)으로도 532건 통과합니다. 포크 RPC 없이 측정하면 `CreatePool`·
`PostDeployCheck` 수치가 낮아집니다(포크 테스트가 그 경로를 실행함).

| 기법 | 대상 | 증명하는 것 |
| :--- | :--- | :--- |
| **외부 함수 집합 고정** (런타임 바이트코드의 디스패처에서 셀렉터 추출) | `FireToken` 17개, `FireVesting` 16개, `FireMerkleDistributor` 8개 | 이름·호출 권한과 무관하게 외부 함수가 하나라도 추가·삭제되면 실패. 특정 주소만 부를 수 있는 숨은 mint, 수익자 전용 인출 함수를 붙인 변형이 이 검사에 걸리는 것을 회귀 테스트로 확인 |
| **바이트코드 고정** (CBOR 메타데이터를 뺀 생성 코드·런타임 코드 해시) | `FireToken`, `FireVesting` | 셀렉터를 바꾸지 않는 내부 로직 변경(예: 해시로 숨긴 spender의 allowance 검사 생략)과 생성자만 바꾼 변경까지 감지. solc·OpenZeppelin·최적화 설정을 바꾸면 의도적으로 상수를 갱신해야 함. `forge coverage`(최적화 없는 별도 빌드)에서는 스스로 건너뜀 |
| **불변식** (핸들러 기반 무작위 시퀀스) | `FireToken`+`FireVesting` 7개(+종료 후 검사), `FireMerkleDistributor` 4개, `FireBatchSender` 6개, 배포 후 점검 2개 | 총공급 = 10억 − 소각량, 베스팅 잔액 + 해제량 = 2억, 해제량 ≤ 독립 계산한 일정, 베스팅 물량은 그 시점 owner만 수령, owner는 0이 될 수 없음, 청구 + 회수 + 잔액 = 예치, 클레임 기간 중 지급 능력 유지, Batch Sender는 ETH·토큰을 보관하지 않고 수수료는 소각만 되며 송신자는 보낸 만큼만 잃음 등 |
| **퍼즈** | 전 컨트랙트, 스크립트 수학(`PoolMath`) | 기본 1,000회, CI 프로필 10,000회 (불변식 1,000회 × 깊이 128) |
| **포크 테스트** (Base 메인넷 고정 블록, Sepolia) | `CreatePool`·`Deploy`·`PostDeployCheck`, `FireBatchSender` | 실제 Uniswap V3 팩토리·NPM·WETH 주소표와 인터페이스, 두 수수료 등급·두 토큰 순서의 풀 생성, multicall 안의 permit, 실패 시 승인 미잔류, 선점된 풀(가격 편차·활성 유동성) 감지와 중단, 토큰 배포 전 선점 감지, `confirm()`의 실제 NFT id·이벤트 조회, **실제 UNCX V3.1 락커의 락업(0.5% 수수료) → `confirmLock()` → PostDeployCheck PASS**, 배포 지갑으로 보낸 소액 포지션(105개 포함)이 런칭 포지션을 대신하지 못함, 배포 지갑이 만들지 않은 복제·가짜 FIRE에 시딩하지 않음, 실제 Safe v1.4.1의 모듈 거부·소유자 서명 소유 증명, 실제 Safe v1.3.0·v1.4.1·Coinbase Smart Wallet·MetaMask EIP-7702 위임 계정의 ETH 수령 가스, WETH·L2ToL1MessagePasser 거부 |
| **스크립트 가드 테스트** | 5개 스크립트 | 체인·RPC 체인 ID 대조, 메인넷 확인 문구, EIP-55, 소유 증명 서명(역할·주소·체인 ID·서명자·형식·가변 서명, Safe 소유자 서명의 임계값·중복·비소유자), Safe·모듈·EIP-7702 판별(배포 지갑 포함), 기록의 CREATE 주소 유도, 메인넷 기록 필수(CreatePool·DeployAirdrop·DeployBatchSender), 코드 동일성 대조(백도어 베스팅·변형 토큰), 중복 배포·같은 Root 재배포 차단, 사후 조건, 기록 pending → confirmed 등 모든 중단 경로 (환경 변수·기록은 하네스로 주입하므로 사용자의 `.env`·커밋된 기록과 무관) |
| **에어드롭 도구 테스트** (node:test) | `airdrop/` | CSV 검증(체크섬·중복·소수 자릿수·예약 대역 주소·`--deny`), 결정적 트리 생성, 숨은 leaf 탐지, `recipients.csv` 전수 대조, 배포 스크립트와의 형식 연동, 다음 단계 명령 형식, 저장소 문서의 운영 명령 일관성(`--slow`, forge Ledger 경로 플래그, 마감 시각 변환, 체크섬 UNCX 락커 주소, 포크 리허설 주의), `.gitignore` 규칙, 커밋된 픽스처 최신 여부 |

**증명하지 않는 것:** 형식 검증(formal verification)은 하지 않았습니다. 포크 테스트는 고정된 과거 블록의 상태를 쓰므로
배포 당일의 풀·가격 상태를 보장하지 않습니다(그래서 스크립트가 실행 시점에 다시 확인함). 가스 수치는 측정 조건에서의
값이며 향후 가스 재책정으로 달라질 수 있습니다. 컴파일러·OpenZeppelin·외부 시스템의 정확성, 운영자의 지갑 관리와
절차 준수, 스크립트가 쓰는 RPC의 정직성은 전제입니다.

## 5. 잔여 위험과 운영 전제

### 5.1 최초 수익자·에어드롭 지갑의 소유 증명

`FireVesting`의 최초 수익자는 수락 절차 없이 owner가 되고 에어드롭 물량은 단순 전송이므로, 잘못된 주소는 2억 /
5,000만 FIRE의 영구 손실로 이어집니다. `script/Deploy.s.sol`은 Base 메인넷에서 다음을 강제합니다.

- 세 주소(`BENEFICIARY`, `TREASURY_SAFE`, `AIRDROP_WALLET`) 모두 EIP-55 체크섬 표기(전부 소문자 거부), 서로·배포 지갑·
  새로 만들 컨트랙트 주소와 달라야 함.
- 수익자·에어드롭 지갑의 소유 증명(`BENEFICIARY_PROOF_SIG`, `AIRDROP_WALLET_PROOF_SIG`, personal_sign): EOA·EIP-7702
  위임 EOA면 그 키의 서명, Safe면 같은 메시지(address = Safe)에 Safe의 현재 소유자들이 각자 서명한 값(서로 다른 소유자
  서명 ≥ 임계값). 메시지에 역할·주소·체인 ID가 들어 있어 다른 역할·주소·체인의 서명으로는 통과하지 못하고, 누구나 만들 수
  있는 비슷한 주소의 Safe(주소 오염)는 소유자가 달라 통과하지 못함. Safe가 아닌 컨트랙트와 모듈이 활성화된 Safe는 거부.
- 트레저리는 Base에 배포된 Safe(임계값 2 이상·소유자 3명 이상·모듈 없음)여야 하고 EIP-7702 위임 EOA는 거부함.
  `DeployBatchSender`의 소유자(트레저리 Safe)도 같은 규칙. 모듈은 소유자 서명 없이 Safe 자산을 옮길 수 있음.
- 배포 지갑(브로드캐스터)은 코드가 없는 EOA여야 함(EIP-7702 위임 EOA 거부, `CreatePool`도 같음).
- 테스트넷은 같은 조건을 경고로만 알림(제출된 서명은 메인넷과 같이 검증).

남는 위험: 서명은 "그 키를 지금 쓸 수 있다"만 증명합니다. 키 백업·Safe 서명자 구성은 운영자 책임입니다. Safe의 guard·
fallback handler는 검사하지 않습니다(자산을 옮기는 권한은 아니지만 Safe 사용을 막을 수는 있음). 배포 후에 Safe 설정이
바뀌면(모듈 추가 등) `PostDeployCheck`가 WARN으로 알립니다.

### 5.2 풀 선점 (Deploy 첫 트랜잭션 ~ 풀 생성 사이)과 LP 락업

토큰 주소는 배포 지갑과 nonce로 미리 계산되고 Uniswap 팩토리는 코드가 없는 주소로도 풀 생성을 허용합니다.

- **토큰 배포 전:** `Deploy`가 시뮬레이션 시점에 예측 주소의 FIRE/WETH 풀(1%·0.3%)을 확인하고, 이미 있으면 메인넷에서
  아무것도 보내지 않고 중단합니다. 메인넷 배포 지갑은 리허설·공개 기록에 쓰지 않은 새 지갑이어야 합니다.
- **첫 Deploy 트랜잭션 포함 이후 (남은 위험, 대응 방식 결정 대기):** FireVesting 배포 트랜잭션이 포함되면 배포자와 nonce가
  공개되어 토큰 주소가 확정됩니다. 그때부터 `CreatePool`의 multicall이 포함될 때까지(`--slow` 블록 대기, `confirm()`,
  Ledger permit 서명, 시뮬레이션·승인을 합쳐 수 분) 누구나 두 수수료 등급을 모두 엉뚱한 가격으로 초기화하거나(토큰 순서와
  무관, 트랜잭션 2건) WETH 단독 활성 유동성을 넣어(FIRE 주소 > WETH) `CreatePool`을 막을 수 있습니다(리뷰 PoC: 가스 약
  1,040만 + WETH 2×10^12 wei). 자금 손실은 없지만 이 저장소의 도구로는 그 풀들에 런칭 유동성을 넣을 수 없습니다.
  "다른 수수료 등급 사용"은 한 등급만 막혔을 때만 유효하고, "곧바로 실행"은 구간을 줄일 뿐 막지 못합니다.
  선택지(운영 판단 필요):
  1. **원자적 시딩 도우미 컨트랙트**: 한 트랜잭션에서 풀 생성·가격 복구 스왑(유동성 0 구간은 무비용, 선점자의 WETH는
     런칭 가격보다 유리하게 매수)·전체 범위 mint·환불을 수행. 선점자는 런칭 전에 FIRE를 가질 수 없으므로 이 방식이면
     선점이 무력화됩니다. 대가: 메인넷에 추가 컨트랙트를 배포·검증해야 하고 승인 대상이 바뀝니다.
  2. **구간 축소**: permit을 예측 토큰 주소로 Deploy 전에 미리 서명하고 Deploy와 CreatePool 트랜잭션을 연달아 보내 구간을
     한 블록 안팎으로 줄임. Ledger는 트랜잭션마다 기기 승인이 필요해 완전히 닫지는 못합니다.
  3. **현행 유지**: 새 배포 지갑 + Deploy 직후 CreatePool + 검증·홍보는 락업 뒤. 두 등급이 모두 막히면 1의 도우미를
     그때 배포해 복구.
- LP NFT를 락커로 옮기기 전까지는 배포 지갑이 유동성을 회수할 수 있습니다. 락업은 외부 락커(UNCX / Team Finance)를
  신뢰하는 수동 단계입니다. UNCX V3.1(Base)은 락업 때 LP 유동성의 일부를 수수료로 가져가므로(DEFAULT 0.5%, LVP 0.8%,
  LLP 0.3% + 고정 0.1 ETH, 이후 수수료 수익의 1~3.5%) 락업되는 것은 나머지입니다. `CreatePool --sig "confirmLock()"`이
  락업 후 유동성과 수수료(1% 이하만 허용)를 기록에 남기고, `PostDeployCheck`가 그 값을 기준으로 이후의 감소를 FAIL로
  표시하며 보유자가 지정한 락커인지 확인합니다.
- 누구나 배포 지갑으로 FIRE/WETH 전체 범위 소액 포지션을 보낼 수 있습니다(`mint`의 수령자 제한 없음). `confirm()`과
  `PostDeployCheck`는 기록된 계획에서 계산한 유동성 하한 이상인 포지션만 런칭 포지션으로 인정하므로, 소액 포지션을
  락업해 공개 보고서를 PASS로 만들 수 없습니다. 자동 탐색은 배포 지갑의 가장 오래된 NFT 100개까지라 런칭 **전에** 그보다
  많은 NFT를 보내 두면 탐색이 멈춥니다(다른 포지션을 고르지 않음). 이때는 `LP_TOKEN_ID`로 지정하며 같은 검사를 거칩니다.

### 5.3 `BatchSent`는 가치 이동의 증명이 아님

`BatchSent(sender, token, recipients, total, burnedFee)`의 `token`·`recipients`·`total`은 호출자가 넘긴 입력 그대로입니다.
임의의 ERC-20은 아무것도 옮기지 않고 `true`를 반환할 수 있고(가짜 토큰), 전송 수수료형 토큰은 실제 수령액이 적습니다.
사용 실적 집계(예: 2차 에어드롭 기준)는 같은 트랜잭션의 토큰 `Transfer` 로그(ETH는 내부 트랜잭션 트레이스)로 실제
이동을 확인하고, 허용 자산 목록·고유 수령자 수·최소 금액·Sybil 기준을 사전에 공개해 적용해야 합니다. 본인 지갑 사이의
전송으로 실적을 부풀리는 행위는 온체인에서 완전히 막을 수 없습니다(송신자 자신에게 보내는 행만 거부).
`burnedFee`는 같은 트랜잭션의 FIRE `Transfer(송신자 → 0 주소)`로 검증할 수 있습니다.

### 5.4 누구나 대신 제출하는 claim

`claim(account, amount, proof)`은 누구나 제출할 수 있고 토큰은 항상 목록상의 `account`로 갑니다. 따라서 (1) 수령 시점을
제3자가 정할 수 있고(세무상 수령 시점 판단에 유의), (2) 목록에 잘못 들어간 주소(오타, 거래소 입금 주소, 개인 키 없는
주소)의 몫도 마감 전에 그 주소로 보내질 수 있어 `sweep`으로 회수된다고 기대할 수 없습니다.

### 5.5 잘못 보낸 자산을 되찾는 기능 없음

어떤 컨트랙트에도 rescue·출금·관리자 기능이 없습니다. 잘못 보낸 자산의 결과는 다음과 같습니다.

| 받는 컨트랙트 | ETH | FIRE | 다른 ERC-20 |
| :--- | :--- | :--- | :--- |
| `FireToken` | 거부 (payable 함수 없음) | 영구 동결 | 영구 동결 |
| `FireVesting` | 베스팅 일정에 따라 owner에게 해제 (시작 후 입금분은 일부 즉시 해제) | 같음 | 같음 |
| `FireMerkleDistributor` | 거부 | 마감 후 `sweep`으로 회수 주소에 반환 | 영구 동결 |
| `FireBatchSender` | 일반 송금 거부 (selfdestruct 강제 송금분은 동결, 동작에는 영향 없음) | 영구 동결 | 영구 동결 |

### 5.6 스크립트 실행 환경

- forge는 시뮬레이션 후 전송합니다. 시뮬레이션 통과가 체인 결과를 보장하지 않으므로 기록은 pending으로 쓰고, 채굴 후
  `confirm()`이 체인에서 확인한 값으로 confirmed로 바꿉니다. 공개는 confirmed 기록, `confirmLock()`, `PostDeployCheck`
  PASS 이후에 합니다.
- Base 메인넷에서 `CreatePool`·`DeployAirdrop`·`DeployBatchSender`는 Deploy 기록(`deployments/8453.json`)을 기준으로만
  실행되고, 기록의 토큰이 배포 지갑의 `CREATE(deployerNonce + 1)`인지 확인합니다. 이름·바이트코드가 같은 복제 토큰을
  `FIRE_TOKEN`에 잘못 붙여 넣는 주소 오염 사고를 막기 위한 것입니다.
- 전송은 항상 `--slow`(앞 트랜잭션 영수증 확인 후 다음 전송), 중단되면 같은 명령에 `--resume`을 씁니다.
- `--chain`·`--chain-id`·`FOUNDRY_CHAIN_ID`는 시뮬레이션 체인만 바꿔 메인넷 가드를 우회할 수 있으므로 쓰지 않습니다.
  스크립트는 RPC의 `eth_chainId`와 대조해 다르면 중단합니다.
- `CONFIRM_MAINNET=I_UNDERSTAND`는 `.env`에 두지 않습니다(forge가 `.env`를 자동으로 읽어 이후 모든 실행에서 확인이 생략됨).
  메인넷은 시뮬레이션에도 필요합니다.
- 로컬 포크 리허설: anvil 기본 개발 계정은 Base에서 EIP-7702 스위퍼에 위임되어 있으므로 리허설 전용 키(`cast wallet new`)를
  쓰고, anvil과 forge 모두 `--no-storage-caching`으로 실행해 포크 상태가 실제 블록 번호로 RPC 캐시에 저장되지 않게 합니다
  (README "로컬 포크 리허설").
- 스크립트는 RPC가 돌려주는 상태를 믿습니다. 신뢰할 수 있는 RPC를 쓰고, 결과는 BaseScan에서 다시 확인합니다.
- 개인 키는 `.env`·명령줄에 두지 않고 `--ledger` 또는 `--account`(암호화 키스토어)로만 서명합니다.

### 5.7 컴파일러 알려진 버그 검토 (solc 0.8.30)

Solidity 공식 버그 목록(`docs/bugs_by_version.json`, 2026-10-08 조회)에 0.8.30 해당 항목은 7개이며, 이 프로젝트의 배포
빌드(레거시 코드 생성기, optimizer 200 runs, EVM cancun)에는 해당하지 않습니다.

| 버그 | 조건 | 판단 |
| :--- | :--- | :--- |
| TransientStorageClearingHelperCollision (high, 0.8.34 수정) | viaIR + cancun, `transient` 상태 변수와 일반 상태 변수를 함께 `delete` | 해당 없음: viaIR 미사용. `ReentrancyGuardTransient`는 `transient` 변수가 아닌 인라인 어셈블리(`TransientSlot`) 사용 |
| UnsoundSpillInMutualRecursion, SpillSlotCollisionAcrossMutualRecursion, MisorderedNamedParametersInRequireWithCustomErrors | viaIR | 해당 없음 |
| InheritanceOrderReversalOnStorageEndWarning (0.8.36 수정) | `layout at`으로 저장소 끝 근처를 지정해 경고가 날 때 | 해당 없음: `layout at` 미사용, 빌드 경고 0건 |
| MemoryByteArrayElementDeleteClearsWholeWord (0.8.37 수정) | 메모리 `bytes`의 원소에 `delete` | 해당 없음: 배포 컨트랙트가 쓰는 소스의 `delete`는 `Ownable2Step`의 저장소 변수 1곳뿐 |
| LostStorageArrayWriteOnSlotOverflow (0.8.32 수정) | 저장소 끝(2^256)에 걸친 배열 | 해당 없음 |

CI의 `forge coverage`도 레거시 코드 생성기(최적화 끔)를 쓰므로 viaIR 전용 버그와 무관합니다. 컴파일러를 올리려면
바이트코드 고정 상수와 가이드 3장의 검증 설정을 함께 갱신해야 합니다.

### 5.8 공급망

- 서브모듈은 커밋으로 고정(`foundry.lock`)되고 CI가 체크아웃 커밋과 대조합니다. CI 액션은 모두 전체 커밋 SHA로 고정했고
  Foundry는 v1.8.5(커밋 `51a52c59…`)로 고정해 설치 후 확인합니다. Foundry 설치 도구(foundryup)는 GitHub 릴리스 증명
  (attestation) 해시로 바이너리를 검증합니다.
- `airdrop/`은 정확한 버전과 lockfile(`npm ci`), 설치 스크립트 금지(`ignore-scripts`)를 쓰고 CI에서
  `npm audit signatures`로 레지스트리 서명을 확인합니다. 알려진 `npm audit` 경고(uuid, moderate)는 도구가 해당 기능을
  쓰지 않아 영향이 없습니다(`airdrop/README.md`).

### 5.9 L2 특성

Base 시퀀서는 중앙화되어 있어 트랜잭션을 지연·누락시킬 수 있습니다(예: 마감 직전의 claim). 블록 시각은 OP Stack 규칙으로
정해져 임의 조정 여지가 거의 없고, 수 초 단위 차이는 90일 기한·180일 클리프 판정에 의미가 없습니다. 가스가 큰 경로
(풀 생성 multicall, 300명 배치 전송)는 EIP-7825 트랜잭션 가스 상한(16,777,216) 안에 드는지 스크립트·테스트가
측정·검사합니다.

## 6. 정적 분석

- `forge lint`: 경고 0건, 사용되지 않는 억제 주석 0건(`--report-unused-suppressions`). 억제 주석은 의도된 예외에만
  쓰였습니다(기한 판정의 `block-timestamp`, 행 번호와 함께 배치 전체를 취소하는 `require-revert-in-loop`, 요구사항 ABI·
  외부 인터페이스 이름의 대소문자 규칙, 반환 데이터를 복사하지 않는 `inline-assembly`, 허용 경로 안의 파일 접근 등).
- **Slither 0.11.6** (crytic-compile 0.4.2, Foundry 빌드, `slither .` 기본 설정 = `src/`와 의존성): 41개 컨트랙트, 102개
  탐지기, **107건 → 실제 문제 0건**.

| 탐지기 (영향/신뢰도) | 건수 | 위치 | 판정과 근거 |
| :--- | ---: | :--- | :--- |
| incorrect-equality (Medium/High) | 1 | `FireMerkleDistributor.sweep`의 `amount == 0` | 오탐. 빈 sweep을 막는 가드일 뿐이며, 잔액을 0이 아니게 만드는 입금은 그 FIRE를 회수 주소로 보낼 뿐이고 잔액을 0으로 만들 방법은 없어 sweep을 막을 수 없음 |
| timestamp (Low/Medium) | 4 | `FireMerkleDistributor` 생성자·`claim`·`sweep`, `FireToken` 생성자 | 오탐(의도). 기한·일정 판정에 블록 시각이 필요하며 수 초 차이는 결과에 의미가 없음. 경계(마감 시각 포함/초과)는 테스트로 고정 |
| assembly (Informational) | 1 | `FireBatchSender._sendValue` | 의도. 가스 상한과 반환 데이터 미복사(returndata bomb 방지)를 위한 단일 `call`, memory-safe |
| naming-convention (Informational) | 4 | `FireMerkleDistributor`의 immutable `TOKEN` 등 | 스타일. forge-lint 권장(immutable 대문자) 표기 |
| pragma (Informational) | 1 | `^0.8.24`와 OpenZeppelin 범위 지정 | 오탐. 모든 파일을 `foundry.toml`의 solc 0.8.30 하나로 컴파일 |
| solc-version (Informational) | 4 | OpenZeppelin 인터페이스의 넓은 pragma | 오탐. 실제 컴파일러는 0.8.30이며 해당 버그 검토는 5.7절 |
| incorrect-exp (High/Medium) | 1 | OZ `Math.mulDiv`의 `(3 * denominator) ^ 2` | 오탐. 모듈러 역원 초깃값을 위한 의도적 XOR (OpenZeppelin 주석에 명시) |
| divide-before-multiply (Medium/Medium) | 9 | OZ `Math.mulDiv`, `Math.invMod` | 오탐. 512비트 정밀 곱셈·나눗셈 알고리즘의 의도된 단계 |
| missing-zero-check (Low/Medium) | 1 | OZ `Ownable2Step.transferOwnership` | 오탐. 0 주소 지정은 대기 중인 이전을 취소하는 설계이며 0 주소는 `acceptOwnership`을 호출할 수 없음 |
| shadowing-local (Low/High) | 1 | OZ `ERC20Permit` 생성자 인자 `name` | 오탐. 생성자 지역 인자일 뿐 동작 영향 없음 |
| timestamp (Low/Medium) | 2 | OZ `VestingWallet._vestingSchedule`, `ERC20Permit.permit` | 오탐(의도). 베스팅 일정·permit 마감 판정 |
| naming-convention / too-many-digits (Informational) | 4 / 7 | OZ `DOMAIN_SEPARATOR` 등, 비트마스크 상수 | 스타일 |
| assembly (Informational) | 67 | OZ `SafeERC20`, `Math`, `Strings`, `StorageSlot`, `TransientSlot`, `ECDSA` 등 | 감사받은 라이브러리의 의도된 어셈블리 |

- 보조 실행(`--foundry-compile-all`, `lib/`·`test/` 제외로 `script/` 포함, 177개 컨트랙트, 2026-10-08 재측정): 130건.
  `src/` 10건은 위와 같은 항목이고, `script/` 120건(unused-return 52, incorrect-equality 23, calls-loop 17, timestamp 14,
  reentrancy-balance 6, uninitialized-local 4, low-level-calls 2, arbitrary-send-eth 1, assembly 1)은 모두 오탐입니다:
  forge JSON 직렬화의 중간 반환값과 필요한 값만 꺼내는 튜플 분해(Safe·포지션 조회 결과 포함, 실패하면 빈 값이라 검사가
  중단 쪽으로 동작), 사후 조건의 의도적 일치 검사, `vm` 치트코드 호출을 외부 호출로 본 경우(reentrancy-balance,
  calls-loop의 `vm.keyExistsJson` 등), `try` 반환·조건 분기로 대입되는 지역 변수, 검증된 Uniswap
  NonfungiblePositionManager로의 시딩 ETH 전송, 서명 분해·코드 비교용 어셈블리 등이며 스크립트는 배포되지 않습니다.

재현 방법 (가상 환경은 저장소 밖에 만듦, `slither .`은 `forge clean` 후 다시 빌드함):

```bash
python3 -m venv ~/.venvs/slither && ~/.venvs/slither/bin/pip install slither-analyzer==0.11.6
~/.venvs/slither/bin/slither .                                                    # src/ + 의존성 (107건)
~/.venvs/slither/bin/slither . --foundry-compile-all --filter-paths "lib/|test/"   # script/ 포함 (130건)
forge lint --report-unused-suppressions
```

## 7. 취약점 제보

**공개 이슈·PR·SNS에 올리지 마십시오.** 다음 경로로 비공개 제보해 주십시오.

- GitHub 저장소의 **Security → Report a vulnerability** (비공개 취약점 제보, 저장소 설정에서 활성화 필요)
- 이메일: `security@<프로젝트 도메인>` — **메인넷 배포 전에 실제 주소로 교체할 자리 표시자입니다.** (PGP 키: 준비 중)

포함해 주실 내용: 대상 파일·함수와 커밋 해시, 재현 방법(가능하면 Foundry 테스트 또는 로컬 anvil 포크 PoC), 영향 범위,
제안하는 완화책.

- 응답 목표(1인 유지보수, 최선 노력): 접수 확인 72시간 이내, 1차 평가 7일 이내.
- 선의의 연구를 환영합니다. 로컬 환경(anvil, `anvil --fork-url`)에서만 재현하고, 메인넷·테스트넷의 실제 자산이나 다른
  사용자에게 영향을 주는 시험, 개인정보 접근, 서비스 방해는 하지 마십시오. 공개는 수정·공지 이후에 협의해 주십시오.
- 현재 공식 버그 바운티는 없습니다.
- 배포된 컨트랙트는 업그레이드·일시정지가 불가능하므로, 대응은 사용자 공지, 프론트엔드·운영 절차 변경, 토큰이 아닌
  컨트랙트(Batch Sender, 다음 회차 분배 컨트랙트)의 새 버전 배포로 한정됩니다.
