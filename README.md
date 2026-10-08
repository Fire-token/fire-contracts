# FIRE (Fire) 스마트 컨트랙트

Base(Ethereum L2, Chain ID 8453)에 배포하는 **FIRE ERC-20 토큰**의 컨트랙트, 런칭 스크립트, 테스트, 에어드롭 도구입니다.
외부 투자금 없이(프리세일·ICO 없음) 개발자 본인 자금으로 Uniswap V3 풀을 시딩하는 공정 런칭(Fair Launch)을 전제로 하며,
모든 분배·락업은 온체인에서 누구나 확인할 수 있도록 설계했습니다.

기획·운영 기준 문서는 **「FIRE (Fire) 토큰 개발 및 거래소 상장 종합 가이드라인」**(이하 *가이드*,
[`fire_token_development_and_listing_guide.md`](fire_token_development_and_listing_guide.md))입니다. 아래의 "가이드 n장"은 이 문서의 절을 뜻합니다.

| 항목 | 값 |
| :--- | :--- |
| 이름 / 심볼 / 소수점 | Fire / FIRE / 18 |
| 총발행량 | 1,000,000,000 FIRE (배포 시 일괄 발행, 추가 발행 불가) |
| 네트워크 | Base 메인넷 (8453), 리허설: Base Sepolia (84532) |
| 라이브러리 | OpenZeppelin Contracts **v5.7.0** (라이브러리 코드는 수정 없이 상속만), forge-std |
| 컴파일러 설정 | solc **0.8.30**, optimizer 켬 **200 runs**, EVM **cancun**, viaIR 끔 (`foundry.toml`, 소스 검증 시 동일하게) |
| 라이선스 | MIT ([`LICENSE`](LICENSE)) |

## 공급량 분배 (가이드 2.2절)

| 배분 | 수량 (FIRE) | 비율 | 집행 방식 |
| :--- | ---: | :---: | :--- |
| DEX 초기 유동성 | 700,000,000 | 70% | Uniswap V3 FIRE/WETH 전체 범위 포지션, LP NFT 365일 락업 (`CreatePool`) |
| 개발자 지분 | 200,000,000 | 20% | 토큰 생성자가 `FireVesting`으로 직접 발행: 180일 클리프(해제 0) 후 540일 선형 해제 |
| 커뮤니티·에어드롭 | 50,000,000 | 5% | 에어드롭 전용 지갑 → 회차별 `FireMerkleDistributor` (1차 2,000만, 2차 3,000만) |
| CEX 상장·MM 트레저리 | 50,000,000 | 5% | Base Safe 멀티시그 (2-of-3 이상) |

## 컨트랙트와 보장 사항

| 컨트랙트 | 역할 | 누가 무엇을 할 수 있나 | 코드와 테스트로 보장하는 것 |
| :--- | :--- | :--- | :--- |
| [`FireToken`](src/FireToken.sol) | ERC-20 + Burnable + Permit(EIP-2612) | **특권 주체 없음.** 보유자는 자기 토큰의 전송·승인(permit 포함)·소각만 가능 | 생성자에서만 발행(2억 → `FireVesting`, 8억 → 배포자). owner·mint·pause·blacklist·거래세·업그레이드 없음. 생성자는 `vesting`이 코드가 있고 아직 해제가 시작되지 않은 베스팅 일정(`start() ≥ 현재`, `duration() > 0`)일 때만 성공. 외부 함수 17개로 고정 |
| [`FireVesting`](src/FireVesting.sol) | OZ `VestingWallet` + `Ownable2Step` | owner(= 수익자): 해제분 수령, 수령 지갑 교체 제안(새 지갑이 `acceptOwnership()`해야 완료). 누구나: `release()` 호출(토큰은 항상 owner에게) | 클리프 180일 동안 해제 0, 이후 540일 초 단위 선형. 일정보다 먼저 꺼낼 경로 없음. `renounceOwnership()` 차단(잔여 물량 동결 방지). 외부 함수 16개로 고정 |
| [`FireMerkleDistributor`](src/FireMerkleDistributor.sol) | 에어드롭 회차별 Merkle 클레임 | **관리자 없음.** 누구나: 마감까지 `claim()` 제출(토큰은 항상 목록상 주소로), 마감 후 `sweep()`(미청구분은 항상 `SWEEP_RECIPIENT`로) | 토큰·Merkle Root·마감·회수 주소가 immutable. 주소당 1회. 마감은 배포 시점부터 365일 이내. claim 구간과 sweep 구간이 겹치지 않음. 외부 함수 8개로 고정 |
| [`FireBatchSender`](src/FireBatchSender.sol) | ETH·ERC-20 다중 전송 (최대 300명) + FIRE 소각 수수료 | owner(트레저리 Safe): `freeRecipientLimit`(0~300)·`burnFee`(0~100만 FIRE) 변경만. 사용자: 본인 자산만 전송 | 자산을 보관하지 않음(호출 후 잔액 0). 수수료는 송신자 지갑에서 `burnFrom`으로 같은 트랜잭션에서 소각되고 누구에게도 지급되지 않음. 사용자가 호출마다 `maxBurnFee`로 상한 지정. 한 행이라도 실패하면 배치 전체 취소. 출금(rescue)·일시정지 없음, 소유권 포기 차단 |

신뢰 모델, 테스트가 증명하는 범위, 남은 위험은 [`SECURITY.md`](SECURITY.md)에 정리되어 있습니다.

## 공식 주소 (Base 메인넷)

**아직 배포 전입니다.** 배포 후 `deployments/8453.json`(공개 기록)과 이 표를 함께 갱신하고 BaseScan 링크를 겁니다.

| 항목 | 주소 |
| :--- | :--- |
| FireToken | (배포 전) |
| FireVesting | (배포 전) |
| Uniswap V3 FIRE/WETH 풀 · LP NFT · 락업 | (배포 전) |
| 트레저리 Safe / 에어드롭 지갑 / 수익자 지갑 / 배포 지갑 | (배포 전) |

## 저장소 구조

```
fire-contracts/
├── src/                        온체인 컨트랙트 4개 (위 표)
├── script/                     forge 배포·점검 스크립트 (개인 키를 다루지 않음, 서명은 --ledger / --account)
│   ├── Deploy.s.sol              런칭 배포: FireVesting → FireToken → 트레저리·에어드롭 분배, confirm()
│   ├── CreatePool.s.sol          Uniswap V3 풀 생성 + 전체 범위 유동성 (permit + multicall 1건), confirm(), confirmLock()
│   ├── PostDeployCheck.s.sol     배포 후 온체인 점검 보고서 (PASS/WARN/FAIL, 읽기 전용)
│   ├── DeployAirdrop.s.sol       에어드롭 회차 분배 컨트랙트 배포 + 예치
│   ├── DeployBatchSender.s.sol   Fire Batch Sender 배포 (로드맵 2027 Q1)
│   └── lib/                      공통 가드(체인·RPC·EIP-55·Safe·소유 증명), 코드 동일성 대조, 런칭 파라미터, Uniswap 주소표·수학
├── test/                       Foundry 테스트 (단위·퍼즈·불변식·포크)
│   ├── fork/                     Base 메인넷·Sepolia 포크 테스트
│   ├── invariant/                FireToken + FireVesting 불변식
│   └── fixtures/                 에어드롭 샘플 픽스처 (airdrop/에서 생성)
├── airdrop/                    에어드롭 목록 생성·검증 Node 도구 → airdrop/README.md
├── deployments/                공개 배포 기록 <chainId>.json → deployments/README.md
├── lib/                        git 서브모듈: forge-std, openzeppelin-contracts (v5.7.0)
├── .github/workflows/test.yml  CI
├── foundry.toml, foundry.lock  컴파일러·테스트 설정, 의존성 커밋 고정
├── .env.example                모든 스크립트의 환경 변수 목록·단위·기본값
└── SECURITY.md                 보안 모델·잔여 위험·취약점 제보
```

## 개발 환경 준비

```bash
git clone --recurse-submodules <저장소 URL> fire-contracts
cd fire-contracts
git submodule update --init --recursive    # 이미 클론했다면 (lib/forge-std, lib/openzeppelin-contracts)
git submodule status                       # forge-std 0258fe8…, openzeppelin-contracts cab1993… (v5.7.0) 확인
```

1. **Foundry v1.8.5** (CI와 같은 버전): [Foundry 설치 안내](https://getfoundry.sh)대로 `foundryup`을 설치한 뒤
   ```bash
   foundryup --install 1.8.5
   forge --version     # forge Version: 1.8.5 / Commit SHA: 51a52c59cffd940f76eddd0b4bb1791aa4b5ac7f
   ```
   solc 0.8.30은 첫 빌드 때 자동으로 내려받습니다.
2. **Node.js 24 LTS** (에어드롭 도구, `airdrop/package.json`의 engines는 `>=20.10`, CI는 24로 검증):
   ```bash
   cd airdrop && npm ci && cd ..    # .npmrc: 설치 스크립트 실행 금지, 정확한 버전 고정
   ```
3. **환경 변수**: `cp .env.example .env` 후 필요한 값만 채웁니다. 개인 키는 절대 넣지 마십시오.
   forge는 `.env`를 모든 명령에서 자동으로 읽으며, 셸에서 export한 값이 우선합니다. 항목별 설명은
   [`.env.example`](.env.example)에 있습니다.

## 빌드와 테스트

```bash
forge fmt --check                      # 포맷 검사
forge build --sizes --deny warnings    # 컴파일러 경고와 forge lint 경고를 오류로 처리 (CI와 동일)
forge lint                             # 린트만 따로 실행 (현재 경고 0건)

forge test                             # 기본 실행 (아래 설명)
FOUNDRY_PROFILE=ci forge test          # CI 프로필: 퍼즈 10,000회, 불변식 1,000회 × 깊이 128 (약 30초)

# 포크 테스트 포함 전체 실행 (Base 공개 RPC, 고정 블록)
BASE_RPC_URL=https://mainnet.base.org BASE_SEPOLIA_RPC_URL=https://sepolia.base.org forge test
# 포크 테스트만 (3개 스위트 41건)
BASE_RPC_URL=https://mainnet.base.org BASE_SEPOLIA_RPC_URL=https://sepolia.base.org \
  forge test --match-contract 'ForkTest$'
# .env에 RPC URL이 있어도 오프라인으로 실행 (빈 값을 셸에서 주면 .env 값이 적용되지 않음)
BASE_RPC_URL= BASE_SEPOLIA_RPC_URL= forge test

# 커버리지 (CI coverage 잡은 포크 RPC를 주고 --report lcov도 함께 써서 lcov.info를 아티팩트로 올림)
forge coverage --report summary --no-match-coverage '^(lib|test)/'

# 에어드롭 도구 테스트
cd airdrop && npm test
```

- **테스트 수 (2026-10-08 기준, 로컬 측정):** 17개 스위트 534건. RPC 변수가 비어 있으면 493건 통과 + 포크 테스트
  41건 건너뜀(skip). 공개 RPC를 주면 534건 모두 통과. 에어드롭 도구는 54건 통과.
- **포크 테스트:** `test/fork/CreatePool.fork.t.sol`(Base 메인넷 38건 + Sepolia 1건)과
  `test/FireBatchSender.t.sol`의 `FireBatchSenderForkTest`(2건). 실제 Uniswap V3·WETH·Safe v1.4.1·UNCX V3.1 락커
  컨트랙트를 씁니다. `BASE_RPC_URL` / `BASE_SEPOLIA_RPC_URL`이 비어 있으면
  건너뜁니다. 포크 블록은 테스트에 고정되어 있어 결과가 재현되고 forge의 RPC 캐시(`~/.foundry/cache`)가 재사용됩니다.
  `BASE_FORK_BLOCK` / `BASE_SEPOLIA_FORK_BLOCK`으로 바꿀 수 있으며 `0`이면 최신 블록입니다. 포크는 로컬에서만
  실행되며 어떤 트랜잭션도 전송하지 않습니다.
- **`.env.example`을 그대로 복사하면** RPC URL이 채워져 있으므로 `forge test`가 포크 테스트까지 실행합니다(네트워크
  필요, 캐시가 없을 때 약 30초).
- **커버리지:** `forge coverage`는 최적화를 끈 별도 빌드라 바이트코드 고정 테스트 2건이 스스로 건너뜁니다(일반
  `forge test`에서는 실행). 기본 명령은 위의 `forge coverage`(레거시 코드 생성기)입니다. `--ir-minimum`(viaIR)도
  동작합니다: 디스패처 셀렉터 검사가 레거시·viaIR(최적화 유무 모두) 바이트코드를 해석합니다. 포크 RPC를 주지
  않으면 `CreatePool`·`PostDeployCheck` 커버리지가 낮게 나옵니다(포크 테스트가 이 경로를 실행함). 측정값은
  [`SECURITY.md`](SECURITY.md) 4절에 있습니다.
- **정적 분석:** `forge lint` 경고 0건. Slither 결과의 분류는 [`SECURITY.md`](SECURITY.md)의 "정적 분석" 절에 있습니다.

## CI

[`.github/workflows/test.yml`](.github/workflows/test.yml): `main`/`master` 푸시, PR, 수동 실행, 매주 월요일 예약 실행.
모든 액션은 커밋 SHA로 고정했고 Foundry는 v1.8.5로 고정합니다(설치 직후 커밋 SHA까지 확인). 기본 권한은 없음,
각 잡은 `contents: read`만 씁니다.

| 잡 | 내용 | 브랜치 보호 |
| :--- | :--- | :---: |
| `forge` | 서브모듈 커밋 = `foundry.lock` 확인, `forge fmt --check`, `forge build --sizes --deny warnings`, `FOUNDRY_PROFILE=ci forge test` | 필수 |
| `fork` | 공개 RPC로 전체 테스트, 건너뛴 테스트가 있으면 실패. 최대 3회 시도 + RPC 응답 캐시 | 필수 |
| `airdrop` | Node 24: `npm ci` → `npm audit signatures` → `npm test` | 필수 |
| `coverage` | `forge coverage` (포크 포함) 요약을 작업 요약에 표시, `lcov.info` 아티팩트 14일 보관 | 참고용 |

`fork`를 필수로 두는 이유: 런칭 스크립트와 `FireBatchSender`를 실제 Base의 Uniswap V3·WETH·Safe·UNCX 락커·스마트 지갑
코드에 대해 검증하는 유일한 자동 검사이기 때문입니다. 블록이 고정되어 결과가 결정적이고, 일시적 RPC 오류는 재시도와
캐시로 흡수합니다. 공개 RPC 장애가 길어지면 해당 잡만 다시 실행하십시오. `coverage`는 최적화를 끈 별도 빌드라
정확성 판정 기준으로 쓰지 않습니다.

## 배포 개요

실제 절차와 판단 기준은 가이드 4장(Step 0~9)·5장(DEX·락업)·8장(체크리스트), 배포 기록·소유 증명·풀 선점·락업 확인은
[`deployments/README.md`](deployments/README.md), 에어드롭 운영은 [`airdrop/README.md`](airdrop/README.md)를 따릅니다.
메인넷 전에 **Base Sepolia에서 같은 절차를 끝까지 리허설**합니다(가이드 4장 Step 2). Ledger 경로(소유 증명 서명,
permit EIP-712 서명, Deploy 4건 승인)는 리허설에서 실제 기기로 한 번 이상 실행해 두십시오.

1. **지갑 준비:** 리허설·공개 기록에 한 번도 쓰지 않은 **새 배포 지갑**(코드가 없는 하드웨어 지갑 EOA. EIP-7702 위임
   EOA는 메인넷에서 거부), 베스팅 수령 지갑, Base에 배포된 트레저리 Safe(2-of-3 이상, **모듈 없음**), 에어드롭 전용
   지갑. 배포 지갑에는 시딩 ETH + 약 0.15 ETH(가스 + UNCX 고정 수수료 0.1 ETH).
2. **소유 증명:** 수익자·에어드롭 지갑마다 확인 메시지에 서명해 `BENEFICIARY_PROOF_SIG`, `AIRDROP_WALLET_PROOF_SIG`에
   넣습니다(메인넷 필수). EOA(EIP-7702 위임 EOA 포함)는 그 키로 1개, Safe는 그 Safe 소유자들이 각자 서명한 값을 이어
   붙입니다(서로 다른 소유자 서명 ≥ 임계값). 메시지·소유자 목록·명령은
   `forge script script/Deploy.s.sol:Deploy --sig "printProofMessages()" --rpc-url base`가 출력합니다
   (절차·오류 표: [`deployments/README.md`](deployments/README.md)의 "배포 전 소유 증명").
3. **런칭 배포:** 전송 플래그 없이 시뮬레이션해 로그를 확인한 뒤 `--broadcast --slow`로 전송합니다. 메인넷은
   시뮬레이션에도 `CONFIRM_MAINNET=I_UNDERSTAND`가 필요합니다:
   `CONFIRM_MAINNET=I_UNDERSTAND forge script script/Deploy.s.sol:Deploy --rpc-url base --ledger --sender <배포 지갑> [--broadcast --slow]`.
   채굴 후 `--sig "confirm()"`으로 기록을 확정합니다.
4. **곧바로 풀 생성:** `CreatePool`(permit + multicall, 기본 3 ETH + 7억 FIRE, 수수료 1%) → `--sig "confirm()"`.
   메인넷은 Deploy 기록(`deployments/8453.json`)이 있어야 실행됩니다. 첫 Deploy 트랜잭션이 포함되는 순간부터 토큰 주소가
   계산 가능하므로 3과 4 사이에 다른 작업을 하지 않습니다(남은 위험: [`SECURITY.md`](SECURITY.md) 5.2절).
5. **LP NFT 365일 락업** (UNCX 또는 Team Finance, 공식 도메인으로 접속) → 곧바로
   `LP_LOCKER=<락커> forge script script/CreatePool.s.sol:CreatePool --sig "confirmLock()" --rpc-url base`로 락업 후
   유동성을 기록하고, `lpLock`에 락 트랜잭션·해제일·URL을 추가합니다. UNCX는 락업 때 LP 유동성의 일부를 수수료로
   가져갑니다(Base 실측: DEFAULT 0.5% + 고정 0.1 ETH, 이후 수수료 수익의 2%). 락업되는 것은 나머지 약 99.5%입니다.
6. **소스 검증:** 락업 후 `Deploy`가 출력한 `forge verify-contract` 명령으로 두 컨트랙트 검증.
7. **점검·공개:** `forge script script/PostDeployCheck.s.sol:PostDeployCheck --rpc-url base`가
   `RESULT: PASS`인지 확인하고 보고서·주소·트랜잭션 링크를 공개합니다.
8. **1차 에어드롭:** `airdrop/` 도구로 목록 생성·검증 → GitHub에 먼저 공개 → 에어드롭 지갑으로 `DeployAirdrop`
   (메인넷은 토큰·에어드롭 지갑이 Deploy 기록과 같아야 함).
9. **(2027 Q1) Fire Batch Sender:** `DeployBatchSender` (owner = 트레저리 Safe, 모듈 없음).

**로컬 포크 리허설 (선택, 공개 테스트넷 리허설 전):** `anvil --fork-url https://sepolia.base.org --no-storage-caching`
(메인넷 규칙을 보려면 `https://mainnet.base.org`)으로 체인 상태를 로컬에 복제한 뒤, 위 명령의 `--rpc-url`만
`http://127.0.0.1:8545`로 바꾸고 **모든 `forge script`에 `--no-storage-caching`을 붙여** 실행합니다. 주의할 점:

- **anvil 기본 개발 계정을 그대로 쓰지 마십시오.** Base 메인넷에서는 10개 모두, Sepolia에서는 일부가 EIP-7702로
  스위퍼(받은 ETH를 제3자에게 넘기는 코드)에 위임되어 있습니다. Deploy·CreatePool은 메인넷 규칙에서 이런 배포
  지갑을 거부하고, 포크 안에서 그 계정으로 보낸 ETH는 사라집니다. `cast wallet new`로 만든 리허설 전용 키에
  `cast rpc anvil_setBalance <주소> <wei 16진수>`로 ETH를 넣어 쓰거나, 위임을 지우려면
  `cast rpc anvil_setCode <주소> 0x`와 `cast rpc evm_mine`을 차례로 실행합니다. 실제 지갑 키는 쓰지 마십시오.
- anvil은 실제 체인 ID(8453/84532)를 보고하므로 forge가 포크 안의 상태를 실제 블록 번호로 RPC 캐시
  (`~/.foundry/cache/rpc/base*`)에 저장합니다. 그러면 리허설 중에 바꾼 상태(`anvil_set*`)가 보이지 않거나 캐시가
  오염됩니다. anvil과 forge 모두 `--no-storage-caching`을 쓰고, `anvil_set*` 뒤에는 `cast rpc evm_mine`으로 블록을
  하나 만드십시오. 이미 캐시가 생겼다면 `forge cache clean base --blocks <블록>`으로 지웁니다.
- 첫 anvil 블록 시각은 현재 시각이라 오래된 블록에서 포크하면 시간이 크게 건너뜁니다. 최신 블록에서 포크하십시오.
- 락업 단계도 포크에서 연습할 수 있습니다(UNCX V3.1 락커가 Base에 있음). `cast send <NPM> "approve(address,uint256)"`
  후 락커의 `lock(...)`을 0.1 ETH와 함께 호출하고 `confirmLock()` → PostDeployCheck `RESULT: PASS`를 확인합니다.
  2026-10-08 메인넷 포크 리허설에서 Deploy → CreatePool → UNCX DEFAULT 락업(0.50%) → `confirmLock()` →
  PostDeployCheck PASS(29/0/0) → DeployAirdrop → DeployBatchSender를 끝까지 확인했습니다.
- 리허설은 `deployments/84532.json`·`8453.json`과 `broadcast/*/8453/`·`broadcast/*/84532/`(커밋 대상 경로)를 실제
  기록과 같은 이름으로 쓰므로 **저장소의 별도 복사본에서 실행하고 끝나면 지우십시오.** 스크립트가 출력하는
  "다음 단계" 명령은 실제 네트워크 별칭(`--rpc-url base` 등)을 가리키므로 리허설 중에는 그대로 복사해 실행하지
  마십시오.

공통 규칙: 개인 키를 `.env`나 명령줄에 넣지 않고 `--ledger` 또는 `--account`로 서명합니다(Ledger의 첫 계정이
아니면 forge는 `--mnemonic-derivation-paths`(복수형) 또는 `--mnemonic-indexes`, cast는 `--mnemonic-derivation-path`).
전송은 항상 `--slow`, 중간에 멈추면 같은 명령에 `--resume`을 붙입니다(기록 파일을 지우지 않음). `--chain`·
`FOUNDRY_CHAIN_ID`를 쓰지 않고 `--rpc-url`만 씁니다. `CONFIRM_MAINNET`은 `.env`에 넣지 않고 메인넷 명령(시뮬레이션
포함) 앞에만 붙입니다.

## 보안 요약

- **외부 감사를 받지 않았습니다.** 런칭 컨트랙트는 감사받은 OpenZeppelin v5.7.0을 수정 없이 상속하고 추가 코드를
  최소화했으며, 테스트·포크 테스트·정적 분석 결과는 [`SECURITY.md`](SECURITY.md)에 있습니다.
- 주요 잔여 위험: 수익자 주소는 수락 절차 없이 곧바로 베스팅 owner가 됨(배포 전 소유 증명으로 대응: EOA는 그 키,
  Safe는 소유자들의 서명), 첫 Deploy 트랜잭션 포함부터 풀 생성까지의 풀 선점(두 수수료 등급을 모두 엉뚱한 가격으로
  초기화하면 이 저장소의 도구로는 복구할 수 없음, 대응 방식은 결정 대기: SECURITY.md 5.2절), `BatchSent` 이벤트는
  호출자가 넘긴 값이라 가치 이동의 증명이 아님, 에어드롭 claim은 누구나 대신 제출할 수 있음, 어떤 컨트랙트에도 잘못
  보낸 자산을 되찾는 기능이 없음.
- `PostDeployCheck`는 공개 기록을 그대로 믿지 않습니다: 두 컨트랙트의 런타임 코드를 이 저장소의 컴파일 결과와
  대조하고, 기록의 Uniswap 주소를 주소표와 대조하며, LP 포지션이 기록된 계획의 런칭 크기인지 확인합니다.
- 취약점은 공개 이슈가 아니라 [`SECURITY.md`](SECURITY.md)의 비공개 제보 경로로 알려 주십시오.

## 라이선스

[MIT](LICENSE)
