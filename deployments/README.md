# deployments/ — FIRE 공개 배포 기록

**[English](README.en.md)** | **[한국어](README.md)**

이 폴더의 `<chainId>.json` 파일은 FIRE 런칭의 **공개 기록**입니다. 컨트랙트 주소, 지갑 주소, 베스팅 일정,
분배 수량, Uniswap V3 풀·LP 포지션·락업 정보를 담으며, 웹사이트·GitHub README·Litepaper에 그대로 링크할 수 있도록
만들어졌습니다 (가이드 5장 5항, 7.2절 "지갑 공개"). 개인 키나 비밀 값은 절대 들어가지 않습니다.

| 파일 | 네트워크 | 커밋 여부 |
| :--- | :--- | :--- |
| `8453.json` | Base 메인넷 | **`status`와 `pool.status`가 모두 `confirmed`이고 `lpLock`이 기록된 뒤 커밋·공개** (공식 기록) |
| `84532.json` | Base Sepolia (리허설) | **메인넷 런칭이 끝난 뒤** 커밋 (리허설 증빙, 1차 에어드롭 대상 선정 근거). 아래 "선점 방지" 참고 |
| `31337.json` | 로컬 anvil | 커밋하지 않음 (`.gitignore`가 무시) |
| `permit-<chainId>.json` | permit 서명 입력 (임시) | 커밋하지 않음 (`.gitignore`가 무시). 서명 후 삭제 (비밀 값은 아니지만 공개 기록이 아님) |
| `test-*.json` | 테스트 임시 파일 | 커밋하지 않음 (`.gitignore`가 무시, 테스트가 스스로 지움) |

Base 메인넷에서는 이 기록이 이후 스크립트의 기준입니다: `CreatePool`·`DeployAirdrop`·`DeployBatchSender`는
`8453.json`(Deploy가 쓴 기록, `deployer`·`deployerNonce` 포함)이 없으면 실행되지 않고, 기록의 토큰이
`CREATE(deployer, deployerNonce + 1)`인지 확인합니다. 다른 PC에서 실행하려면 이 파일을 함께 복사하십시오.

## 배포 전 소유 증명 (BENEFICIARY · AIRDROP_WALLET)

`FireVesting`의 최초 수익자(`BENEFICIARY`)는 **수락 절차 없이 배포 즉시 owner**가 되고, 에어드롭 물량 5,000만 FIRE는
`AIRDROP_WALLET`으로 단순 전송됩니다. 주소에 오타가 있거나 운영자가 통제하지 못하는 주소(예: 다른 체인에만 배포된
Safe 주소, 주소 오염용으로 만든 비슷한 주소)를 넣으면 2억 / 5,000만 FIRE가 영구히 묶입니다. 그래서
`script/Deploy.s.sol`은 트랜잭션을 만들기 전에 두 주소의 **소유 증명**을 확인합니다 (실패하면 아무것도 전송하지 않음).

서명할 메시지 (한 줄, EIP-191 `personal_sign`, `cast wallet sign`의 기본 방식):

```text
FIRE launch control proof | role=<ROLE> | address=<EIP-55 주소> | chainId=<10진 체인 ID>
```

- `ROLE`은 `BENEFICIARY` 또는 `AIRDROP_WALLET`, 주소는 EIP-55 체크섬 표기 그대로, 체인 ID는 `8453`(메인넷) /
  `84532`(Sepolia). 역할·주소·체인 ID가 메시지에 들어 있으므로 **Sepolia 리허설 서명은 메인넷에서 통하지 않습니다**
  (메인넷용으로 다시 서명).
- 서명 결과(`0x` + 16진수 130자, 65바이트)를 `BENEFICIARY_PROOF_SIG`, `AIRDROP_WALLET_PROOF_SIG`에 넣습니다.
  Safe 주소면 소유자들의 서명을 `0x` 하나 뒤에 이어 붙입니다(서명 1개당 130자, 순서 무관, 최대 16개).
  서명은 비밀이 아니고 이 메시지 외에는 쓸 곳이 없지만, `.env` 파일 자체는 커밋하지 마십시오.

| 주소 종류 | 판별 | 필요한 것 |
| :--- | :--- | :--- |
| EOA (코드 없음) | 주소에 코드가 없음 | 그 주소 키의 서명 1개 |
| EIP-7702 위임 EOA | 코드 = `0xef0100` ‖ 위임 대상 주소 (23바이트) | 그 EOA 자신의 키 서명 1개. 위임 대상이 Safe처럼 응답해도 Safe로 보지 않음 |
| Safe (이 체인에 배포됨) | `getThreshold()` ≥ 1, `getOwners()`가 비어 있지 않음 | 같은 메시지(address = Safe 주소)에 **현재 소유자들이 각자 서명**한 값을 이어 붙임 (서로 다른 소유자 서명 ≥ 임계값). 메인넷은 **활성화된 모듈이 없어야 함** |
| 그 밖의 컨트랙트 | 위에 해당하지 않는 코드 | 메인넷에서 거부 (`DeployProofAccountNotSafe`) |

Safe에도 서명을 요구하는 이유: 누구나 아무 소유자 구성으로 Safe를 만들 수 있으므로, 주소만 보고 받으면 다른 사람이
만든 비슷한 주소의 Safe가 2억 FIRE 베스팅의 owner가 될 수 있습니다. 소유자 서명은 그 Safe를 운영자 측 서명자가
실제로 통제한다는 증명입니다. 모듈은 소유자 서명 없이 Safe의 자산·권한(베스팅 owner 권한 포함)을 옮길 수 있으므로
메인넷에서 거부합니다.

| 체인 | 정책 |
| :--- | :--- |
| Base 메인넷 (8453) | **필수.** 서명이 없으면 서명할 정확한 메시지를 출력하고 중단(`DeployProofMissing`), 틀리면 중단 |
| Base Sepolia (84532) | 제출하면 메인넷과 똑같이 검증, 없으면 경고만 (리허설에서도 제출해 메인넷 절차를 그대로 연습할 것) |
| 로컬 anvil (31337) | 생략 |

절차 (서명·전송 없이 메시지·소유자 목록과 명령을 출력하는 `printProofMessages()`부터):

```bash
# 1) 메시지와 바로 실행할 명령 출력. 메시지에 chainId가 들어가므로 반드시 배포할 네트워크의 --rpc-url로 실행
forge script script/Deploy.s.sol:Deploy --sig "printProofMessages()" --rpc-url base    # 환경 변수 BENEFICIARY, AIRDROP_WALLET

# 2) 각 주소의 키로 서명. Ledger 화면에 메시지 원문이 표시되므로 role·address·chainId를 확인하고 승인
cast wallet sign --ledger "FIRE launch control proof | role=BENEFICIARY | address=0x… | chainId=8453"
cast wallet sign --account <키스토어 이름> "FIRE launch control proof | role=AIRDROP_WALLET | address=0x… | chainId=8453"
#    Ledger의 첫 계정이 아니면 cast에는 --mnemonic-derivation-path "m/44'/60'/<n>'/0/0" 를 붙임
#    (먼저 cast wallet address --ledger --mnemonic-derivation-path "…" 로 주소가 맞는지 확인.
#     forge script에는 복수형 --mnemonic-derivation-paths 또는 --mnemonic-indexes <n>)
#    Safe 주소: printProofMessages가 출력한 소유자 각자가 같은 메시지(address = Safe)에 자기 키로 서명

# 3) 확인 후 환경 변수로 설정
cast wallet verify --address 0x… "FIRE launch control proof | role=BENEFICIARY | address=0x… | chainId=8453" 0x<서명>
export BENEFICIARY_PROOF_SIG=0x<서명>
export AIRDROP_WALLET_PROOF_SIG=0x<서명>
#    Safe 주소: export BENEFICIARY_PROOF_SIG=0x<소유자1 서명에서 0x를 뺀 130자><소유자2 서명 130자>

# 4) 다시 출력해 두 줄 모두 "status  : … verified"인지 확인한 뒤 Deploy 실행
forge script script/Deploy.s.sol:Deploy --sig "printProofMessages()" --rpc-url base
```

- `AIRDROP_WALLET`은 하드웨어 지갑 EOA를 권장합니다. `script/DeployAirdrop.s.sol`은 `AIRDROP_WALLET`이 직접
  브로드캐스트해야 하므로, Safe로 두면 분배 컨트랙트 배포·예치를 Safe 트랜잭션으로 따로 해야 합니다(Deploy가 안내 출력).
- 메인넷 `TREASURY_SAFE`는 **이 체인에 배포된 Safe이며 임계값 ≥ 2, 소유자 ≥ 3, 활성화된 모듈 없음**이어야 합니다
  (가이드 2.2절 2-of-3, `DeployBatchSender`의 소유자 규칙과 같음). EIP-7702 위임 EOA는 거부합니다. 테스트넷은 경고만 합니다.
- 메인넷 **배포 지갑(브로드캐스터)은 코드가 없는 EOA**여야 합니다. 8억 FIRE와 LP NFT를 받는 지갑이 EIP-7702로 위임돼
  있으면(유출된 키에 흔히 붙는 스위퍼 포함) 위임 코드가 잔액을 옮길 수 있으므로 중단합니다(`DeployBroadcasterHasCode`,
  `CreatePool`도 같은 규칙). 테스트넷은 경고만 합니다.

| 오류 | 원인 | 조치 |
| :--- | :--- | :--- |
| `DeployProofMissing(env, message)` | 메인넷인데 서명이 없음 | 오류에 담긴 메시지에 그대로 서명해 `env`에 설정 (Safe면 소유자들이 각자 서명해 이어 붙임) |
| `DeployProofInvalid(env, reason)` | `0x`+130자×n 형식 아님, EOA인데 서명이 65바이트가 아님, ecrecover 실패, s가 상위 절반(가변 서명), 같은 Safe 소유자가 두 번 서명 | `cast wallet sign`으로 다시 서명 |
| `DeployProofWrongSigner(env, expected, recovered)` | 다른 키로 서명했거나 메시지(역할·주소·체인 ID·대소문자)가 다름. Safe면 `recovered`가 그 Safe의 소유자가 아님 | 그 주소(Safe면 그 소유자)의 키로 출력된 메시지를 그대로 다시 서명 |
| `DeployProofNotEnoughOwners(env, signers, threshold)` | Safe 소유자 서명 수가 임계값보다 적음 | 서로 다른 소유자의 서명을 더 이어 붙임 |
| `DeployProofSafeHasModules(role, account)` | 수령 Safe에 모듈이 활성화돼 있음(또는 조회 불가, 메인넷) | Safe 앱에서 모듈을 끄거나 모듈 없는 Safe 사용 |
| `DeployProofAccountNotSafe(role, account)` | 코드가 있지만 Safe가 아닌 주소 (메인넷) | 하드웨어 지갑 EOA(서명) 또는 Base에 배포된 Safe 사용 |
| `DeployTreasurySafeTooWeak(safe, threshold, owners)` | 메인넷 `TREASURY_SAFE`가 2-of-3 미만 | Safe 설정을 임계값 ≥ 2, 소유자 ≥ 3으로 변경 |
| `DeployTreasurySafeHasModules(safe)` | 메인넷 `TREASURY_SAFE`에 모듈이 있음(또는 조회 불가) | 모듈을 끈 Safe 사용 |
| `DeployTreasuryIsDelegatedEOA(account)` | `TREASURY_SAFE`가 EIP-7702 위임 EOA | 실제 Safe 주소 사용 |
| `DeployBroadcasterHasCode(deployer)` | 배포 지갑에 코드가 있음(EIP-7702 위임, 메인넷) | 위임을 해제하거나 새 하드웨어 지갑 EOA 사용 |

## 기록의 두 단계: pending → confirmed

forge 스크립트는 Solidity 코드를 **먼저 로컬에서 시뮬레이션**한 뒤 그 결과로 만든 트랜잭션을 전송합니다.
`--broadcast` 실행이 쓰는 기록은 전송 **전**에 만들어지므로 그대로 믿을 수 없습니다.

- 서명자가 없거나(지갑 옵션 누락), Ledger에서 거절하거나, 트랜잭션이 실패하면 기록만 남고 체인에는 아무것도 없을 수 있습니다.
- **LP NFT id는 Base 전체가 공유하는 카운터**에서 정해집니다. 시뮬레이션과 실제 포함 사이에 다른 사람이 LP를 발행하면
  (Base 메인넷에서 분당 약 6~11건 측정) 실제 id가 달라집니다. 시뮬레이션 id를 그대로 공개하면 남의 NFT를 가리키게 됩니다.
- 시뮬레이션 뒤에 누군가 풀을 먼저 초기화하면 실제 가격·유동성·예치량도 달라집니다 (슬리피지 범위 안이면 체인에서는 성공).

그래서 기록은 두 단계로 씁니다.

1. **pending** — `--broadcast` 실행이 전송 직전에 씀. 결정적인 값만 담습니다: CREATE로 정해지는 컨트랙트 주소, 지갑,
   계획(수수료 등급·틱·목표 가격·투입량·슬리피지·풀 주소). 블록·시각은 시뮬레이션 값이고 **LP NFT id·유동성·예치량은
   쓰지 않습니다.**
2. **confirmed** — 트랜잭션이 채굴된 뒤 `confirm()`을 실행하면(서명·전송 없음) 체인에서 직접 확인해 갱신합니다.
   - `Deploy --sig "confirm()"`: 두 주소가 배포 지갑의 `CREATE(deployerNonce)`·`CREATE(deployerNonce + 1)`인지,
     두 컨트랙트 코드·FireToken 고유 상수·베스팅 소유자/기간/물량, 배포자 nonce가 4건 모두 채굴된 만큼 늘었는지 확인 →
     실제 `vesting.start`/`end`, `deployedAt` 기록.
   - `CreatePool --sig "confirm()"`: 배포 지갑이 가진 NFT(ERC721Enumerable, 가장 오래된 것부터)에서 유동성 있는 FIRE/WETH
     **전체 범위** 포지션 중 **런칭 크기**인 것을 찾아 실제 `tokenId`·`liquidity`를 기록하고, `eth_getLogs`로 mint 이벤트
     (실제 예치량·발행 당시 유동성·트랜잭션 해시)와 풀의 Initialize 이벤트(실제 초기 가격)를 찾아 기록. 이미 락업해 배포
     지갑에 NFT가 없으면 `LP_TOKEN_ID=<id>`로 지정.
   - 탐색은 배포 지갑의 가장 오래된 NFT 100개까지입니다. 런칭 뒤에 들어온 NFT는 런칭 포지션 뒤에 붙어 영향이 없지만, 배포
     지갑 주소는 자금을 받을 때부터 공개되므로 누군가 **런칭 전에** NFT를 100개 넘게 보내 두면 런칭 포지션이 범위 밖에
     놓입니다. 이때 `confirm()`은 다른 포지션을 고르지 않고 `CreatePoolPositionNotFound(<배포 지갑>, <보유 NFT 수>)`로
     멈추며 안내를 출력합니다. CreatePool multicall 트랜잭션의 `IncreaseLiquidity` 이벤트(BaseScan의 Logs 탭, 또는
     ERC-721 전송 내역)에서 id를 확인해 `LP_TOKEN_ID=<id>`로 다시 실행하십시오. 지정한 id도 아래의 런칭 크기 검사를 거칩니다.
   - **런칭 크기:** `NonfungiblePositionManager.mint`는 수령자를 제한하지 않아 누구나 배포 지갑으로 소액 FIRE/WETH 전체 범위
     포지션을 보낼 수 있습니다. 그래서 기록된 계획(`lpFireAmount`·`seedEth`·`slippageBps`)으로 mint의 최소 예치량을 다시
     계산하고, 거기서 나오는 유동성 하한 `pool.minLiquidity`(= ⌊√((amount0Min − 2)(amount1Min − 1))⌋, 발행 가격과 무관한
     하한) 이상인 포지션만 런칭 포지션으로 봅니다. 현재 유동성은 하한 × 99%(락커 수수료 허용 1%) 이상, mint 이벤트를 찾았으면
     발행 당시 유동성 ≥ 하한이고 예치량 ≥ 최소 예치량이어야 합니다. 아니면 `CreatePoolPositionBelowPlan`으로 중단합니다.

## LP 락업 확인 (confirmLock)

UNCX Uniswap V3 락커(V3.1, Base `0x231278eDd38B00B07fBd52120CEf685B9BaEBCC1`)는 **락업할 때 LP 유동성의 일부를 수수료로
가져갑니다**(`decreaseLiquidity`). 2026-10-08 블록 52,317,000에서 `getFee`로 확인한 Base 요율(lpFee / collectFee /
고정 수수료): `DEFAULT` 0.5% / 2% / 0.1 ETH, `LVP` 0.8% / 1% / 0.1 ETH, `LLP` 0.3% / 3.5% / 0.1 ETH. collectFee는 이후
거래 수수료 수령 때마다 떼는 비율입니다. 락업 시 그때까지 쌓인 거래 수수료는 `dustRecipient`(배포 지갑)로 수령됩니다.
기본(`DEFAULT`)이면 런칭 LP의 99.5%가 락업되고 0.5%(약 350만 FIRE + 0.015 ETH)는 UNCX 수수료 주소로 갑니다.

락업 직후 반드시 실행합니다(서명·전송 없음):

```bash
LP_LOCKER=0x<락커> forge script script/CreatePool.s.sol:CreatePool --sig "confirmLock()" --rpc-url base
```

- 기록의 `pool.tokenId`가 락커 컨트랙트에 있는지(배포 지갑·EOA가 아님, `LP_LOCKER`를 주면 그 주소인지), 유동성 감소가
  1% 이하인지 확인하고 `lpLock.locker`, `lpLock.liquidity`(락업 후 유동성), `lpLock.lockFeeBps`, `lpLock.confirmedAtBlock`을
  씁니다. 운영자가 넣은 `lpLock`의 다른 키는 유지합니다.
- 이후 `PostDeployCheck`는 `lpLock.liquidity`를 비교 기준으로 쓰고, 락업 수수료(`pool.liquidity` → `lpLock.liquidity`)를
  공개 보고서에 표시합니다. 이 단계 없이 락업만 하면 "유동성 감소" FAIL이 납니다.
- UNCX는 Base 락커 주소를 공식 문서에 **전부 소문자로만** 공개합니다. 메인넷 스크립트는 체크섬 없는 주소를 거부하므로
  `cast to-check-sum-address <소문자 주소>`로 변환해 쓰십시오(원래 체크섬 정보가 없는 값이라 변환해도 안전함). 위 주소는
  리허설에서 락커 바이트코드(`lock` 셀렉터 `0xa35a96b8`)와 `getFee`로 확인한 값이며, 사용 전에 UNCX 공식 문서와 대조하십시오.
- 수수료 비율이 1%를 넘게 줄었으면 락커 수수료가 아니라고 보고 중단합니다(`CreatePoolLockFeeTooHigh`).
- 다시 실행해도 됩니다(같은 값이면 그대로). 다만 이미 기록된 `lpLock.liquidity`보다 줄었으면 기준을 낮추지 않고
  중단합니다(`CreatePoolLockBaselineDecreased`): 락업 이후의 감소를 기준 갱신으로 덮을 수 없습니다.

## 누가 언제 쓰나

| 순서 | 명령 | 기록 변화 |
| :--- | :--- | :--- |
| 0 | `Deploy --sig "printProofMessages()"` | 없음 (소유 증명 메시지·서명 명령 출력) |
| 1 | `Deploy --broadcast` | 파일 전체를 새로 씀 (`status: pending`). 드라이런·`forge test`는 쓰지 않고 콘솔에만 출력 |
| 2 | `Deploy --sig "confirm()"` | `status: confirmed`, `vesting.start`/`end`(온체인), `deployedAt` |
| 3 | `CreatePool --broadcast` | `pool` 키만 교체 (`pool.status: pending`, 계획 값). 파일이 없으면 테스트넷만 최소 기록 생성(메인넷은 중단) |
| 4 | `CreatePool --sig "confirm()"` | `pool.status: confirmed`, `tokenId`, `liquidity`, `minLiquidity`, 예치량, `mintTx`, `mintLiquidity` 등 |
| 5 | `CreatePool --sig "confirmLock()"` | 락업 후 `lpLock.locker`·`liquidity`·`lockFeeBps`·`confirmedAtBlock` |
| 6 | 운영자(수동) | `lpLock`에 `lockTx`·`unlockDate`·`url` 추가 |

- Deploy는 Base 메인넷에서 기록된 FireToken에 코드가 있으면 중단하고, **기록 파일이 없어도** 배포자의 최근 256개
  CREATE 주소에 FireToken이 있으면 중단합니다 (중복 배포 방지, 테스트넷은 경고만).
- CreatePool은 토큰 주소를 환경 변수 `FIRE_TOKEN` 또는 이 파일의 `contracts.FireToken`에서 읽으며, **둘 다 있는데 서로
  다르면 중단**합니다 (오래된 `.env` 방지). 메인넷은 기록이 필수이고, 토큰이 브로드캐스터(배포 지갑)가 직접 만든
  CREATE 주소가 아니면 중단합니다(`CreatePoolTokenNotFromBroadcaster`: 이름·바이트코드가 같은 복제 토큰에 시딩 ETH를
  넣는 사고 방지).

```json
"lpLock": {
  "locker": "0x… (confirmLock이 씀: 락커 컨트랙트 주소)",
  "liquidity": "… (confirmLock이 씀: 락업 후 유동성)",
  "lockFeeBps": 50,
  "confirmedAtBlock": 0,
  "lockTx": "0x… (운영자: 락업 트랜잭션 해시)",
  "unlockDate": "2027-10-xx",
  "url": "락 페이지 URL"
}
```

## 스키마

수량(토큰·ETH·유동성·sqrtPrice)은 모두 **10진 문자열**입니다. 2^53을 넘는 정수는 JavaScript `JSON.parse`에서
정밀도가 깨지기 때문입니다. 블록 번호·시각·틱·수수료 등급·NFT id·nonce·bp는 숫자입니다.

| 키 | 의미 |
| :--- | :--- |
| `status` | `pending` (전송 전 기록) / `confirmed` (`Deploy confirm()`이 온체인과 대조) |
| `chainId`, `network` | 8453 / `base`, 84532 / `base-sepolia`, 31337 / `anvil` |
| `deployer`, `deployerNonce` | 배포 지갑과 첫 트랜잭션(FireVesting 배포)의 nonce. 토큰 주소 = CREATE(deployer, deployerNonce + 1) (`confirm()`·`PostDeployCheck`·메인넷 스크립트가 확인) |
| `blockNumber`, `blockTimestamp` | 스크립트가 **시뮬레이션한** 블록 (실제 배포 블록의 하한, 이벤트 조회 시작점으로 사용 가능) |
| `deployedAt` | confirmed에만 있음: 실제 배포 시각 (= 온체인 `vesting.start` − 180일) |
| `contracts.FireToken`, `contracts.FireVesting` | 배포된 두 컨트랙트 |
| `wallets.beneficiary` | 베스팅 수령 지갑 (배포 시점의 `FireVesting.owner()`) |
| `wallets.treasurySafe` | CEX 상장·MM 트레저리 Safe (5,000만) |
| `wallets.airdropWallet` | 에어드롭 전용 지갑 (5,000만 = 1차 2,000만 + 2차 3,000만) |
| `vesting.cliffSeconds`, `vesting.linearSeconds` | 15,552,000 (180일), 46,656,000 (540일) |
| `vesting.start`, `vesting.end` | 클리프 종료 시각, 전량 해제 시각. pending은 시뮬레이션 값, confirmed는 **온체인 값** |
| `allocation.*` | `totalSupply` 10억, `vesting` 2억, `lp` 7억, `treasury` 5,000만, `airdrop` 5,000만 |
| `pool.status` | `pending` (CreatePool 전송 전) / `confirmed` (`CreatePool confirm()`이 실제 포지션 확인) |
| `pool.address`, `pool.factory`, `pool.positionManager`, `pool.weth` | 풀(CREATE2로 결정)과 Uniswap V3 주소 (점검은 주소표와 대조) |
| `pool.token0`, `pool.token1` | 주소 정렬 순서 (작은 주소가 token0) |
| `pool.fee`, `pool.tickSpacing`, `pool.tickLower`, `pool.tickUpper` | 10000 / 200 / -887200 / 887200 (3000이면 60 / ±887220) |
| `pool.targetSqrtPriceX96` | 계획한 초기 가격 (= sqrt(amount1 / amount0) × 2^96) |
| `pool.seedEth`, `pool.lpFireAmount`, `pool.slippageBps` | 투입하려던 ETH / FIRE, 슬리피지 한도 (런칭 크기 하한의 근거) |
| `pool.positionOwner` | LP NFT 수령자 (배포자) |
| `pool.approval` | `permit` (multicall 안의 EIP-2612 승인) / `approve` (별도 approve 트랜잭션) |
| `pool.simulatedBlockNumber` | CreatePool이 시뮬레이션한 블록 (mint 이벤트 검색 시작점) |
| `pool.tokenId`, `pool.liquidity` | confirmed에만 있음: **온체인에서 찾은** LP NFT id와 confirm 시점 유동성 |
| `pool.minLiquidity` | confirmed에만 있음: 기록된 계획에서 계산한 런칭 포지션 유동성 하한 |
| `pool.ownerAtConfirm`, `pool.confirmedAtBlock` | confirm 시점의 NFT 보유자와 블록 |
| `pool.mintTx`, `pool.mintBlock`, `pool.mintLiquidity` | confirmed + 이벤트를 찾은 경우: 실제 mint 트랜잭션과 발행 당시 유동성 |
| `pool.fireDeposited`, `pool.ethDeposited`, `pool.ethRefunded` | 실제 예치량 (mint 이벤트), 환불 ETH = `seedEth − ethDeposited` |
| `pool.initialSqrtPriceX96`, `pool.initialTick` | 풀 Initialize 이벤트의 실제 초기 가격 (시뮬레이션 이전에 초기화된 풀이면 없음) |
| `lpLock.locker`, `lpLock.liquidity`, `lpLock.lockFeeBps`, `lpLock.confirmedAtBlock` | `confirmLock()`이 확인한 락커, 락업 후 유동성, 락업 수수료(bp), 확인 블록 |
| `lpLock.lockTx`, `lpLock.unlockDate`, `lpLock.url` | 운영자가 추가하는 락업 트랜잭션·해제일·락 페이지 |

## 주의

- **기록 파일을 지우지 마십시오.** 브로드캐스트가 중간에 멈추면(Ledger 거절, 시간 초과 등) **같은 명령에 `--resume`을
  붙여** 남은 트랜잭션만 보내십시오. `--resume`은 스크립트를 다시 실행하지 않으므로 pending 기록이 그대로 남고, 끝난 뒤
  `confirm()`을 실행하면 됩니다. 배포자 nonce를 다른 트랜잭션에 써 버려 `--resume`이 불가능하면, 남은 전송은
  `cast send`로 직접 보내고 `confirm()`으로 확인합니다.
- `confirm()`이 실패하면 기록과 체인이 어긋난 것입니다. 메시지대로 원인을 해결하고(미채굴, 일부만 채굴 등) 다시 실행합니다.
- CreatePool의 multicall이 체인에서 실패했다면(예: 시뮬레이션 뒤 누군가 풀을 엉뚱한 가격으로 초기화):
  - `approval: permit` — 승인도 함께 되돌려졌으므로 정리할 것이 없습니다.
  - `approval: approve` — 7억 승인이 남습니다. `cast send <FIRE> "approve(address,uint256)" <NPM> 0`으로 지우십시오
    (`PostDeployCheck`가 남은 승인을 WARN으로 표시합니다).
  - 이후 다른 `FEE_TIER`로 CreatePool을 다시 실행하면 `pool` 키가 새 pending 값으로 교체됩니다.
- 정확한 트랜잭션 해시·블록·가스는 `broadcast/<스크립트>/<chainId>/run-latest.json`에도 남습니다
  (`.gitignore`가 `/broadcast`를 추적하도록 설정되어 있음, 31337은 무시).
- forge 스크립트에 **`--chain` / `--chain-id`나 `FOUNDRY_CHAIN_ID`를 주지 마십시오.** 시뮬레이션의 체인 ID만 바뀌고
  전송은 RPC의 실제 체인으로 가기 때문에 메인넷 보호 장치를 우회하게 됩니다. 모든 스크립트(Deploy·CreatePool·
  PostDeployCheck·DeployAirdrop·DeployBatchSender)는 RPC의 `eth_chainId`와 대조해 다르면 중단합니다
  (`LaunchChainIdMismatch`, 공통 라이브러리 `script/lib/LaunchGuards.sol`). (`forge verify-contract --chain …`은
  전송이 없으므로 괜찮습니다.)
- 메인넷에서 트랜잭션을 만드는 스크립트(Deploy·CreatePool·DeployAirdrop·DeployBatchSender)는 **시뮬레이션에도**
  `CONFIRM_MAINNET=I_UNDERSTAND`가 필요합니다(없으면 아무것도 보내지 않고 중단).
- 환경 변수의 주소는 **EIP-55 체크섬 표기**(대소문자 혼합) 그대로 붙여 넣으십시오. 체크섬이 틀리면(한 글자 오타) 모든
  스크립트가 중단하고(`LaunchBadChecksum`), Base 메인넷에서는 모든 스크립트가 전부 소문자인 주소도 거부합니다
  (`LaunchChecksumRequired`). 공식 출처가 전부 소문자로만 공개한 주소는 `cast to-check-sum-address`로 변환해 씁니다.

## PostDeployCheck가 이 파일을 쓰는 방법

```bash
forge script script/PostDeployCheck.s.sol:PostDeployCheck --rpc-url base          # 메인넷 (lpLock.locker를 기록에서 읽음)
forge script script/PostDeployCheck.s.sol:PostDeployCheck --rpc-url base_sepolia  # 리허설
LP_LOCKER=0x<락커> forge script script/PostDeployCheck.s.sol:PostDeployCheck --rpc-url base
```

- 읽기 전용입니다 (브로드캐스트 없음, 서명 불필요, 파일도 쓰지 않음). 코드 대조용 참조 컨트랙트는 forge의 로컬
  시뮬레이션 안에서만 만들어집니다. `deployments/<chainId>.json`을 읽고, 같은 이름의 환경 변수가 있으면 그 값이
  우선합니다: `FIRE_TOKEN`, `FIRE_VESTING`, `DEPLOYER`, `BENEFICIARY`, `TREASURY_SAFE`, `AIRDROP_WALLET`, `LP_TOKEN_ID`,
  `LP_LOCKER`. 값이 기록과 다르면 `NOTE: env … overrides …`를 출력합니다. 기록 파일이 없으면 환경 변수만으로도 실행됩니다.
- 기록의 `status`/`pool.status`가 `pending`이면 WARN으로 알립니다. **공개용 보고서는 둘 다 `confirmed`이고 `confirmLock()`을
  마친 상태에서 만드십시오.**
- 기록을 쓴 배포자 자신도 점검 대상이므로 기록 값을 그대로 믿지 않습니다:
  - **코드 동일성:** FireToken·FireVesting의 런타임 코드를 이 저장소에서 컴파일한 코드와 대조합니다(immutable 값은 같은
    값으로 다시 만들어 비교, 끝의 CBOR 메타데이터 제외). 베스팅처럼 응답하지만 인출 함수가 있는 컨트랙트, 숨은 함수를
    붙인 토큰은 FAIL입니다.
  - **주소 유도:** 기록에 `deployerNonce`가 있으면 두 주소가 배포 지갑의 `CREATE(deployerNonce)`·`CREATE(deployerNonce + 1)`
    인지 확인합니다.
  - **Uniswap 주소:** `pool.positionManager`는 이 체인의 Uniswap V3 NonfungiblePositionManager(주소표)여야 하고, LP 점검은
    항상 주소표의 NPM으로 합니다(가짜 NPM의 응답을 믿지 않음).
  - **LP 포지션:** id(기록·`LP_TOKEN_ID`)가 FIRE/WETH 전체 범위 포지션이고 런칭 크기(`pool.minLiquidity` × 99%) 이상인지
    확인합니다. id가 없거나(pending, WARN) 틀리면(FAIL) 배포 지갑의 NFT에서 런칭 크기 포지션을 찾아 그 id로 나머지
    점검을 계속하며, 소액 포지션은 고르지 않습니다. 존재하지 않는 id여도 보고서는 끝까지 출력됩니다.
  - **배포 지갑 잔액:** 풀이 기록됐는데 배포 지갑이 7억 FIRE 이상을 가지면 FAIL(런칭 LP가 배포 지갑에서 나가지 않았거나 회수됨).
- 유동성 비교 기준: `lpLock.liquidity`(confirmLock)가 있으면 그 값, 없으면 confirmed 기록의 `pool.liquidity`.
- 등급
  - **FAIL**: 영구히 성립해야 하는 성질 위반 — 공급량·메타데이터·코드 동일성·CREATE 주소 유도, 토큰 `owner()` 부재,
    베스팅 소유자·기간·일정(confirmed 기록은 `vesting.start`가 정확히 같아야 함), `잔액 + 해제량 = 2억`, 클리프 전 해제
    가능량 0, 메인넷 트레저리가 Safe인지(EIP-7702 위임 EOA면 FAIL), NPM 주소표 일치, LP id가 FIRE/WETH 전체 범위
    포지션인지, 런칭 크기, 포지션이 없음, **LP 유동성 감소**(락업 수수료는 confirmLock 기록으로 공개되고 1% 초과면
    FAIL), 지정한 락커가 NFT를 보유하는지, 풀이 있는데 배포 지갑이 7억 이상 보유. 1건이라도 있으면 보고서를 끝까지
    출력한 뒤 종료 코드 1로 끝납니다.
  - **WARN**: 런칭 시점과 달라졌지만 정상 운영으로도 생기는 변화 또는 미확정 기록 — pending 기록, 트레저리·에어드롭 잔액
    변화(예: 1차 Merkle 분배 컨트랙트에 2,000만 예치 후 에어드롭 지갑 3,000만), LP NFT 미락업, 남은 승인, 대기 중인
    베스팅 소유권 이전, 베스팅 컨트랙트로의 추가 입금, 트레저리 Safe가 2-of-3 미만이거나 모듈이 활성화됨(또는 조회 불가)
    (배포 시점에는 Deploy가 메인넷에서 거부하지만 이후 Safe 설정은 바뀔 수 있음).
  - **INFO**: 현재 가격, 초기 가격, 소각량, 실제 베스팅 일정(UTC), 해제 가능량, 락업 후 배포 지갑 잔액(반올림 잔량과
    락업 때 수령한 거래 수수료).
- **베스팅 수령 지갑을 정상 교체한 뒤**(현재 owner가 `transferOwnership`, 새 지갑이 `acceptOwnership`): 기록의
  `wallets.beneficiary`는 배포 시점 값이므로 "owner() is <새 지갑>, expected beneficiary <기록 값>" FAIL이 납니다. 교체
  트랜잭션을 확인한 뒤 `BENEFICIARY=<새 지갑>`을 주고 다시 실행하고, 교체 사실(트랜잭션 해시)을 기록·공지에 남기십시오.
- 출력되는 `=== RESULT: PASS ===` 보고서(주소는 BaseScan 링크)는 그대로 공지·README에 붙여 넣을 수 있습니다.

## 풀 선점 방지와 대응

### 토큰 배포 전 선점 (배포 지갑 주소가 알려진 경우)

FireToken 주소는 `CREATE(배포자, nonce + 1)`로 **미리 계산**됩니다. Uniswap 팩토리는 코드가 없는 토큰 주소로도 풀
생성·초기화를 허용하므로, 배포 지갑 주소를 아는 사람은 토큰이 생기기 전에 1%·0.3% 두 등급 모두 엉뚱한 가격으로
초기화하거나(토큰 순서와 무관) WETH 단독 유동성을 넣어 둘 수 있습니다(FIRE 주소가 WETH보다 크면). 그러면 CreatePool은
두 등급 모두 중단됩니다.

- **메인넷 배포 지갑은 리허설에 쓰지 않은 새 지갑**을 쓰십시오. 리허설 기록(`84532.json`)에는 배포자 주소가 들어 있으므로
  메인넷 런칭 전에는 공개하지 마십시오.
- Deploy는 토큰을 배포하기 **전에**(시뮬레이션 시점) 예측 주소의 FIRE/WETH 풀(10000·3000)을 확인해, 이미 있으면 메인넷에서
  아무것도 보내지 않고 중단합니다(`DeployPoolPreempted`). 이때는 새 배포 지갑으로 다시 시작하십시오.

### 토큰 배포 후 선점 (Deploy 첫 트랜잭션 ~ CreatePool)

**Deploy의 첫 트랜잭션(FireVesting 배포, nonce n)이 체인에 포함되는 순간** 배포자와 nonce가 공개되어 토큰 주소
`CREATE(배포자, n + 1)`가 확정됩니다. 그때부터 CreatePool의 multicall이 포함될 때까지(`--slow`의 블록 대기, `confirm()`,
permit 서명, CreatePool 시뮬레이션·승인을 합친 수 분) 누구나 두 등급을 모두 선점할 수 있습니다. 비용은 매우 작습니다
(리뷰 PoC: 두 등급 가스 약 1,040만 + WETH 2×10^12 wei, 또는 초기화만 2건). Deploy의 사전 검사는 시뮬레이션 시점에만
실행되므로 이 구간은 막지 못합니다.

- Deploy가 끝나면 **바로** CreatePool을 실행하고, 소스 검증(`forge verify-contract`)·홍보는 풀 생성·락업 뒤로 미루십시오.
  이것은 구간을 줄일 뿐 막지는 못합니다.
- CreatePool은 permit(EIP-2612)을 multicall 안에 넣어 사전 approve 트랜잭션 없이 한 번에 풀 생성·초기화·유동성 공급을
  합니다. 시뮬레이션 단계에서 이미 풀이 있으면 아래 표대로 판단하며, 시뮬레이션 뒤에 생긴 풀은 체인에서
  `amountMin`(목표 가격 대비 `SLIPPAGE_BPS`)으로만 막습니다 — 그 범위 안이면 그 가격에 공급되고(`confirm()`이 실제 값을
  기록), 벗어나면 multicall 전체가 실패합니다(자금 손실 없음).

| 상황 (시뮬레이션 시점) | 동작 |
| :--- | :--- |
| 풀만 생성되고 초기화 안 됨 | 그대로 진행 (같은 multicall이 목표 가격으로 초기화) |
| 활성 유동성이 이미 있음 | 중단 (`CreatePoolPoolHasLiquidity`) |
| 유동성 0, 가격 편차 > 1% | 중단 (`CreatePoolExistingPoolPriceMismatch`) |
| 유동성 0, 편차 > `SLIPPAGE_BPS` | 중단 (`CreatePoolExistingPoolPriceBeyondSlippage`) — `SLIPPAGE_BPS`를 편차 이상(최대 100)으로 올리면 기존 가격으로 진행 |
| 유동성 0, 편차 ≤ `SLIPPAGE_BPS` | 기존 가격으로 진행 (경고 출력) |

선택지 (선점된 경우):

- **(a) 다른 수수료 등급 사용** — 한 등급만 막혔다면 `FEE_TIER=3000`(또는 10000)으로 다시 실행하고, 실제 런칭 풀 주소를
  공식 채널에 공지합니다. 포크 테스트에서 검증된 경로입니다. **두 등급을 모두 노린 선점에는 효과가 없습니다.**
- **(b) 가격 복구 + 유동성 공급을 한 트랜잭션에서 (이 저장소에는 없음)** — 유동성이 0인 구간의 스왑은 토큰을 소모하지
  않고 가격만 `sqrtPriceLimitX96`까지 옮기며, 선점자는 런칭 전에 FIRE를 가질 수 없어 WETH 단독 유동성만 넣을 수
  있으므로 복구 스왑은 선점자의 WETH를 런칭 목표 가격보다 유리한 가격에 사들이는 것뿐입니다. 다만 `pool.swap` 콜백을
  처리하는 전용 컨트랙트가 필요하고(Uniswap SwapRouter/SwapRouter02는 유동성 0 구간 스왑을 콜백에서 거부), 복구와 mint가
  별도 트랜잭션이면 그 사이에 다시 선점할 수 있으므로 복구 + mint를 한 트랜잭션에서 해야 합니다. 메인넷에 추가
  컨트랙트를 배포하는 일이라 **운영 판단이 필요한 미결 사항**입니다(SECURITY.md 5.2절의 선택지).
