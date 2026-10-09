# FIRE 에어드롭 Merkle 도구 (`airdrop/`)

**[English](README.en.md)** | **[한국어](README.md)**

FIRE 에어드롭을 **회차별 Merkle 클레임**으로 지급하기 위한 목록 생성·검증 도구와 운영 절차입니다.
온체인 부분은 [`src/FireMerkleDistributor.sol`](../src/FireMerkleDistributor.sol)과 배포 스크립트
[`script/DeployAirdrop.s.sol`](../script/DeployAirdrop.s.sol)입니다. (가이드 2.2·2.4절, 4장 Step 8)

## 구조 요약

```
수령자 CSV ──(generate.mjs)──> tree.json · merkle.json · recipients.csv ──(GitHub에 먼저 공개)
                                     │
                                     ▼ Merkle Root
             에어드롭 지갑이 FireMerkleDistributor 배포 + total만큼 FIRE 예치 (DeployAirdrop.s.sol)
                                     │
        ┌────────────────────────────┴────────────────────────────┐
  기한까지(마감 시각 포함): claim(account, amount, proof)     기한 이후: 누구나 sweep()
  - 누구나 대신 제출 가능, 토큰은 항상 목록상 주소로         - 미청구 잔액 전부 → 에어드롭 지갑
  - 주소당 1회                                                - 다음 회차로 이월, 이월 수량 공개
```

- **관리자 권한 없음:** owner·admin·pause·업그레이드가 없고 모든 설정값(토큰, Merkle Root, 마감 시각, 회수 주소)이
  immutable입니다. 배포 후에는 개발자를 포함한 누구도 목록·수량·기한·회수 주소를 바꿀 수 없습니다.
- **leaf 형식:** OpenZeppelin `StandardMerkleTree` `["address","uint256"]`
  = `keccak256(bytes.concat(keccak256(abi.encode(account, amount))))` (이중 해시로 second-preimage 공격 차단).
- **기한 경계:** `block.timestamp <= CLAIM_DEADLINE` 동안만 claim, `block.timestamp > CLAIM_DEADLINE`부터 sweep.
  두 구간이 겹치지 않아 같은 블록에서 claim과 sweep이 경합하지 않습니다. 마감 시각은 배포 시점부터 최대 365일입니다.
- **누구나 대신 claim 가능 (사양):** 토큰은 항상 목록상 주소로 가지만, 수령 시점을 제3자가 정할 수 있고 목록에 잘못
  들어간 항목의 물량도 마감 전에 그 주소로 보내질 수 있어 sweep으로 회수된다는 보장이 없습니다 (8절).

### 회차 계획 (가이드 2.4절)

| 회차 | 수량 | 시기 | 대상 | `--expected-total` |
| :--- | :--- | :--- | :--- | :--- |
| 1차 | 20,000,000 FIRE (2%) | 2026 Q4 런칭 직후 | 테스트넷 리허설 참여자, GitHub 기여자, 초기 커뮤니티 | `20000000` |
| 2차 | 30,000,000 FIRE (3%) + 1차 미청구 이월분 | 2027 Q1 기준 공개, Q2 스냅샷·지급 | `Fire Batch Sender` 등 도구 실사용 지갑 | `30000000` + 이월분 |

- 클레임 기한은 회차마다 기본 **90일**입니다 (`AIRDROP_CLAIM_DAYS`).
- 1차 미청구분은 기한 후 `sweep()`으로 에어드롭 지갑에 돌아오며, 그 수량을 공개하고 2차 총량에 더합니다.
  예: 1차 미청구 1,234,567.5 FIRE → 2차 `--expected-total 31234567.5`.
- 회수분은 에어드롭 지갑에만 둡니다. 개발자 개인 지갑이나 트레저리로 옮기지 않습니다.

## 설치

```bash
cd airdrop
npm ci      # package-lock.json의 정확한 버전으로 설치 (.npmrc: ignore-scripts=true, save-exact=true)
npm test    # 도구 자체 테스트 (node:test)
```

- Node.js 20.10 이상 (v24.21에서 검증). 의존성은 정확한 버전으로 고정:
  `@openzeppelin/merkle-tree@1.0.8`, `viem@2.56.8`.
- `.npmrc`가 설치 스크립트 실행을 막습니다 (공급망 공격 완화). 의존성을 바꿀 때만 `npm install`을 쓰고,
  평소에는 항상 `npm ci`를 쓰십시오.
- `npm audit`가 `uuid` moderate 경고(GHSA-w5hq-g745-h8pq)를 표시합니다. 경로는
  `@openzeppelin/merkle-tree → @metamask/abi-utils → @metamask/utils → uuid@9`이며, 이 도구는 네트워크를 쓰지 않고
  해당 기능(uuid v3/v5/v6에 `buf` 인자 전달)을 호출하지 않으므로 영향이 없습니다.
  `npm audit fix --force`는 merkle-tree를 구버전으로 내리므로 실행하지 마십시오.

## 1. 수령자 CSV 준비

```csv
address,amount
0x2BDD29789433CbF687f4c7c42Fa0d6ADBEA2080b,250
0xd2fe2ff9d9e611a2e83441d3b67291182e8f8cbc,100
0x5476367F1f3eFCcf2be5b6526f42021c2A6F3102,49.999999999999999999
```

| 항목 | 규칙 |
| :--- | :--- |
| 헤더 | 첫 줄은 `address,amount` (대소문자·앞뒤 공백 무시) |
| address | `0x` + 16진수 40자리. **대소문자가 섞여 있으면 EIP-55 체크섬이 정확해야 함** (틀리면 오타로 보고 거부). 전부 소문자 또는 전부 대문자는 허용. 0 주소·예약 대역 금지 (아래) |
| 중복 | 같은 주소는 한 번만 (대소문자 무시) |
| amount | **FIRE 단위 10진수** (wei 아님). 소수점 이하 최대 18자리, 0 초과. 천 단위 쉼표·지수 표기(`1E+07`)·부호·따옴표 금지 |
| 합계 | `--expected-total`과 정확히 같아야 함 |
| 인코딩 | UTF-8 (BOM 허용), LF/CRLF 모두 허용, 빈 줄은 무시 (행 번호는 원본 기준으로 보고) |

- **행 순서는 결과에 영향이 없습니다.** 주소순으로 정렬해 트리를 만들므로 같은 (주소, 수량) 집합이면 항상 같은
  Merkle Root와 바이트 단위로 같은 출력 파일이 나옵니다.
- 체크섬 오류가 나면 **대소문자만 고치지 마십시오.** 오타 난 주소도 대소문자를 맞추면 "정상 주소"처럼 보이게 됩니다.
  원본 출처(신청서, 온체인 기록)에서 주소를 다시 복사하십시오.
- 스프레드시트에서 내보낼 때 수량 열이 `1E+07`이나 `1,000`으로 바뀌지 않도록 텍스트 서식으로 저장하십시오.
- 수령 주소는 **개인 지갑**이어야 합니다. 거래소 입금 주소는 넣지 마십시오. 스마트 컨트랙트 지갑(Safe 등)은
  **Base에 같은 주소로 배포되어 있는지** 확인하십시오 (다른 체인에만 있는 Safe 주소로는 수령할 수 없습니다).
- **예약 대역은 항상 거부합니다** (`ADDRESS_RESERVED`, `FireBatchSender`의 수령자 정책과 같음): `0x0000…0000` ~
  `0x0000…FFFF`(프리컴파일, `0x…dEaD` 같은 소각용 주소 등)와 `0x4200…0000` ~ `0x4200…FFFF`(Base·OP Stack 시스템
  컨트랙트: WETH, L2ToL1MessagePasser 등). claim은 누구나 대신 제출할 수 있으므로 이런 주소의 몫은 그 주소로 보내져
  영구히 사라지고 sweep으로도 돌아오지 않습니다.
- 알려진 컨트랙트 주소(FIRE 토큰, FireVesting, 이전 회차 분배 컨트랙트, 트레저리 Safe 등)는 `--deny`로 넘기면 해당 행을
  `DENIED`로 거부합니다(아래 2절).
- **목록 오류는 배포 후에 바로잡을 수 없고, 잘못 들어간 항목의 물량은 회수된다는 보장도 없습니다** (8절).
  배포 전 검증·공개·이의 제기 기간이 유일한 방어선입니다.

## 2. 목록 생성

```bash
cd airdrop
node generate.mjs --input round1.csv --out out/round-1 --expected-total 20000000 --round 1
```

| 옵션 | 설명 |
| :--- | :--- |
| `--input` | 수령자 CSV |
| `--out` | 출력 디렉터리. **forge 배포 스크립트가 읽을 수 있도록 `out/` 하위**를 쓰십시오 (`foundry.toml` `fs_permissions`) |
| `--expected-total` | CSV 합계와 정확히 같아야 하는 총량 (FIRE 단위) |
| `--round` | 회차 번호 (기본 1). merkle.json에 기록 |
| `--deny` | 수령자가 될 수 없는 주소 (쉼표로 구분, 여러 번 지정 가능). 예: `--deny <FireToken>,<FireVesting>,<1차 분배 컨트랙트>,<트레저리 Safe>` |
| `--force` | 기존 출력 덮어쓰기 허용. **이미 공개한 회차는 덮어쓰지 말고 새 디렉터리를 쓰십시오** |

검증에 실패하면 아무 파일도 쓰지 않고, 모든 오류를 행 번호와 함께 한 번에 출력합니다 (종료 코드 1, 사용법 오류는 2).

```
✖ 입력 검증 실패: round1.csv (3건)
  - 2행 [ADDRESS_CHECKSUM] EIP-55 체크섬 불일치 "0x2BDD…080B": 주소 오타일 가능성이 높습니다. …
  - 5행 [DUPLICATE] 중복 주소 0x2bdd…080b: 2행과 같은 주소입니다 (대소문자 무시). …
  - 9행 [AMOUNT_DECIMALS] amount "1.0000000000000000001": 소수점 이하 19자리 (최대 18자리)
```

생성 직후 디스크에 쓴 파일을 다시 읽어 `verify.mjs`와 같은 전수 검증을 자동으로 수행합니다.
2만 명 목록도 약 18초에 생성·검증됩니다 (로컬 측정). 성공하면 다음 단계(검증 명령, GitHub 공개, 시뮬레이션 → 전송
순서의 `DeployAirdrop` 명령)를 출력합니다.

## 3. 출력물

| 파일 | 용도 |
| :--- | :--- |
| `tree.json` | OpenZeppelin `StandardMerkleTree` dump (전체 트리). 누구나 `StandardMerkleTree.load()`로 root를 재계산할 수 있음 |
| `merkle.json` | 배포 스크립트와 클레임 안내용. `{ round, root, total(wei 문자열), totalFire, count, claims: { 체크섬 주소: { amount(wei 문자열), proof: [...] } } }` |
| `recipients.csv` | 공개용 정규화 목록 (EIP-55 표기, 주소순, FIRE 단위). 입력과 같은 형식이라 **이 파일만으로 같은 root를 재현**할 수 있음 |

```json
{
  "round": 1,
  "root": "0xdc68…7f2a",
  "total": "1000000000000000000000",
  "totalFire": "1000",
  "count": 9,
  "claims": {
    "0x2BDD29789433CbF687f4c7c42Fa0d6ADBEA2080b": {
      "amount": "250000000000000000000",
      "proof": ["0xbcb0…4b2c", "0x3760…2f77", "0x9359…d727"]
    }
  }
}
```

- **`merkle.json`을 다른 도구로 다시 포맷하거나 손으로 고치지 마십시오.** 배포 스크립트는 파일 크기와 무관하게
  동작하도록 위 형식의 첫 7줄(헤더)만 읽으며, 형식이 다르면 `DeployAirdropInvalidMerkleJson(…, "layout")`으로
  거부합니다. 목록을 바꿔야 하면 CSV를 고쳐 새 디렉터리로 다시 생성하십시오.

## 4. 검증 (운영자·제3자 공통)

```bash
node verify.mjs --dir out/round-1 --expected-total 20000000 --round 1
# 또는 파일을 직접 지정
node verify.mjs --tree out/round-1/tree.json --merkle out/round-1/merkle.json --recipients out/round-1/recipients.csv
# 생성 때 쓴 --deny 목록도 같이 확인 (생성 명령이 출력한 1번 명령에 들어 있음)
node verify.mjs --dir out/round-1 --expected-total 20000000 --round 1 --deny <주소,…>
```

`verify.mjs`가 확인하는 것:

1. `tree.json`을 다시 로드해 모든 내부 노드를 재계산
2. **트리의 leaf가 정확히 공개 목록(values)뿐인지**: 노드 수 = 2 × 수령자 수 − 1, values만으로 다시 만든 트리와
   노드 단위로 일치. root에 목록에 없는 leaf(숨은 할당)가 들어 있으면 `TREE_EXTRA_LEAVES`·`TREE_REBUILD_MISMATCH`로
   실패합니다. (OpenZeppelin `load()`는 이 부분을 확인하지 않으므로 별도로 검사함)
3. 모든 수령자의 proof를 **두 가지 방식**(OpenZeppelin 라이브러리, Solidity `MerkleProof`와 같은 독립 계산)으로 검증
4. `merkle.json`의 root·total·totalFire·count·claims 대조
5. `recipients.csv`를 **주소·수량 단위로 전수 대조**(수령자 수·합계 포함)하고, 이 파일만으로 다시 만든 root도 대조
6. `--expected-total`·`--round`를 주면 그 값과도 대조
7. 모든 수령자가 예약 대역이 아니고(`TREE_ADDRESS`), `--deny` 목록에 없는지(`TREE_DENIED`)

통과하면 `트리 leaf 수 : N (… 숨은 leaf 없음)`, `recipients.csv : 일치 (N명, 주소·수량 전수 대조)`가 출력됩니다.

공개된 파일을 제3자가 검증하는 방법:

```bash
git clone <레포> && cd <레포>/airdrop && npm ci
node verify.mjs --dir out/round-1 --expected-total 20000000 --round 1
# recipients.csv만으로 root 재현 (출력 root가 컨트랙트의 MERKLE_ROOT()와 같아야 함)
node generate.mjs --input out/round-1/recipients.csv --out /tmp/fire-check --expected-total 20000000 --round 1
```

## 5. 공개 체크리스트

**배포 전**
- [ ] 지급 대상·기준·스냅샷 시점을 먼저 공지 (2차는 2027 Q1 기준 공개)
- [ ] **Sybil(다중 지갑) 필터** 적용 후 CSV 확정: 지갑 생성일, 온체인 활동 이력, 최소 잔고 등 객관적 기준.
      같은 자금 출처에서 갈라진 지갑 묶음, 같은 시각 대량 생성 지갑 등을 제외하고, 적용한 기준을 공개
- [ ] `generate.mjs` → `verify.mjs` 통과
- [ ] **`recipients.csv` · `tree.json` · `merkle.json`과 Merkle Root를 GitHub에 커밋·푸시하고 커밋 해시를 기록
      (반드시 컨트랙트 배포보다 먼저)**
  - 루트 `.gitignore`는 forge 빌드 출력을 `/out/`(루트에 앵커)으로만 무시하므로 `airdrop/out/`은 무시되지 않습니다.
    `airdrop/.gitignore`의 `!/out/`은 루트 규칙이 바뀌어도 회차 파일이 빠지지 않게 하는 이중 안전장치입니다.
    `git add airdrop/out/round-1` 후 `git status`에 세 파일이 보이는지, 푸시 후 GitHub 웹에서 열리는지 확인하십시오
    (`git check-ignore -v airdrop/out/round-1/merkle.json`은 아무것도 출력하지 않아야 함)
- [ ] 공개 후 며칠간 이의 제기 기간. 수정이 필요하면 새 디렉터리로 다시 생성하고 새 root를 다시 공개
- [ ] 공개한 root를 배포 때 `AIRDROP_EXPECTED_ROOT`로 그대로 사용 (메인넷 필수, 스크립트가 merkle.json과 대조)
- [ ] Base Sepolia에서 같은 `merkle.json`으로 배포 → claim → 기한 후 sweep 리허설
- [ ] 에어드롭 지갑에 total 이상의 FIRE와 가스용 ETH 준비

**배포 직후**
- [ ] 온체인 확인 (6절 끝의 `cast code` / `balanceOf` / `MERKLE_ROOT` / `CLAIM_DEADLINE`)
- [ ] BaseScan 소스 검증 (`--verify` 또는 로그에 출력된 `forge verify-contract` 명령)
- [ ] 배포 주소, Merkle Root, 마감 시각(UTC·KST), 배포·예치 트랜잭션 해시, 목록 커밋 해시를 README·웹사이트·X에 공개
- [ ] 수령자 공지: 본인 항목 확인 방법, **세무 고지**(국세청 2022 유권해석상 수령자 증여세 과세 대상일 수 있음),
      참여 조건으로 금전·토큰 입금을 요구하지 않는다는 점, 공식 컨트랙트 주소 외 사칭 사이트 주의,
      누구나 대신 claim을 제출할 수 있어 수령 시점이 본인 의사와 다를 수 있다는 점(7절)

**마감 이후**
- [ ] 누구나 `sweep()` 호출 → 미청구분이 에어드롭 지갑으로 반환 (`Swept(amount)` 이벤트)
- [ ] 회수 수량과 다음 회차 이월 계획 공개

## 6. 배포 (Foundry, 프로젝트 루트에서)

브로드캐스터는 **에어드롭 전용 지갑**입니다 (토큰 배포자 지갑 아님). 미청구분 회수 주소의 기본값도 이 지갑입니다.
개인 키를 `.env`나 명령줄에 넣지 말고 하드웨어 지갑(`--ledger`) 또는 키스토어(`--account`)를 쓰십시오.

| 환경 변수 | 필수 | 설명 |
| :--- | :---: | :--- |
| `FIRE_TOKEN` | 기록 없을 때 | FIRE 토큰 주소. 비우면 `deployments/<chainId>.json`의 `contracts.FireToken`. 둘 다 있으면 같아야 함. 심볼 `FIRE`, decimals 18, FireToken 고유 상수(`TOTAL_SUPPLY`·`VESTING_SUPPLY`) 확인 |
| `AIRDROP_MERKLE_JSON` | ✔ | `merkle.json` 경로 (프로젝트 루트 기준 `airdrop/out/…`. fs_permissions상 `test/fixtures/`도 읽을 수 있으나 샘플 목록은 메인넷에서 거부) |
| `AIRDROP_WALLET` | 메인넷 | 에어드롭 전용 지갑 (`.env.example`의 런칭 배포 값과 같음). 설정하면 모든 체인에서 브로드캐스터와 같아야 함. 메인넷은 기록의 `wallets.airdropWallet`과 같아야 함 |
| `AIRDROP_EXPECTED_ROOT` | 메인넷 | GitHub 공개 커밋의 Merkle Root. 설정하면 `merkle.json`의 root와 같아야 함 |
| `AIRDROP_CLAIM_DAYS` | | 클레임 기간(일), 기본 `90`, 허용 1~365 (컨트랙트도 365일을 넘는 마감을 거부) |
| `AIRDROP_SWEEP_RECIPIENT` | | 미청구분 회수 주소, 기본 = 브로드캐스터(에어드롭 지갑) |
| `CONFIRM_MAINNET` | 메인넷 | Base 메인넷(8453)에서는 `I_UNDERSTAND`. **시뮬레이션에도 필요** (명령 앞에만 붙이고 `.env`에 넣지 않음) |

빈 값(`KEY=`)은 미설정으로 취급합니다. forge는 프로젝트 루트의 `.env`를 자동으로 읽습니다.
**Base 메인넷은 Deploy가 쓴 런칭 기록(`deployments/8453.json`)이 반드시 있어야 하며**, 토큰은 기록의 `contracts.FireToken`
(= 배포 지갑의 `CREATE(deployerNonce + 1)`), 에어드롭 지갑은 기록의 `wallets.airdropWallet`이어야 합니다. 이름·바이트코드가
같은 복제 "FIRE"를 에어드롭 지갑에 뿌려 두고 그 주소를 붙여 넣게 만드는 주소 오염 공격을 막기 위한 것입니다.

```bash
# FIRE_TOKEN은 비워 두면 deployments/<chainId>.json의 기록값 (기록이 없는 테스트넷·로컬에서만 export FIRE_TOKEN=0x...)
export AIRDROP_MERKLE_JSON=airdrop/out/round-1/merkle.json
export AIRDROP_WALLET=0x...                               # 에어드롭 전용 지갑 (= --sender)
export AIRDROP_EXPECTED_ROOT=0x...                        # 공개 커밋의 root

# Base Sepolia 리허설 1) 시뮬레이션: 전송 플래그 없이 실행해 로그·경고를 확인
forge script script/DeployAirdrop.s.sol:DeployAirdrop --rpc-url base_sepolia --ledger --sender $AIRDROP_WALLET
# 2) 전송: 반드시 --slow (배포 성공 영수증을 확인한 뒤에만 예치 트랜잭션을 보냄)
forge script script/DeployAirdrop.s.sol:DeployAirdrop --rpc-url base_sepolia --ledger --sender $AIRDROP_WALLET --broadcast --slow --verify

# Base 메인넷: 같은 순서. 시뮬레이션에도 CONFIRM_MAINNET이 필요
CONFIRM_MAINNET=I_UNDERSTAND forge script script/DeployAirdrop.s.sol:DeployAirdrop \
  --rpc-url base --ledger --sender $AIRDROP_WALLET
CONFIRM_MAINNET=I_UNDERSTAND forge script script/DeployAirdrop.s.sol:DeployAirdrop \
  --rpc-url base --ledger --sender $AIRDROP_WALLET --broadcast --slow --verify
```

- **`--slow`는 필수입니다.** 없으면 forge가 배포·예치 트랜잭션을 영수증을 기다리지 않고 연달아 보냅니다. 배포가
  체인에서 실패해도 예치는 미리 계산된 배포 주소로 그대로 실행되고, 그 주소에는 다시는 코드가 생길 수 없으므로 회차
  물량 전체가 영구히 잠깁니다. `--slow`면 배포가 실패하는 즉시 중단되어 예치를 보내지 않습니다.
- **전송 도중 실패하면 같은 명령을 다시 실행하지 말고** 같은 명령에 `--resume`을 붙여 남은 트랜잭션만 보내십시오
  (예: 영수증 대기 시간 초과, `--verify` 단계 실패). 실수로 다시 실행해도, 같은 지갑이 같은 토큰·같은 root로 배포한
  분배 컨트랙트가 체인에 있으면 스크립트가 `DeployAirdropRootAlreadyDeployed(기존 주소)`로 거부합니다.

스크립트가 하는 일 (모든 확인은 시뮬레이션 단계에서 하며, 하나라도 실패하면 아무 트랜잭션도 보내지 않음):

1. 체인 확인: 8453·84532·31337만. 메인넷은 `CONFIRM_MAINNET`, `AIRDROP_WALLET`, `AIRDROP_EXPECTED_ROOT` 필수
2. 기록 대조: 기록에 토큰이 있으면 모든 체인에서 `FIRE_TOKEN`과 같아야 함. 메인넷은 Deploy 기록 필수 + 토큰 =
   `CREATE(deployer, deployerNonce + 1)` + `AIRDROP_WALLET` = `wallets.airdropWallet`
3. 토큰 확인: 코드 존재, 심볼 `FIRE`, decimals 18, `TOTAL_SUPPLY()` 10억·`VESTING_SUPPLY()` 2억
4. `merkle.json` 헤더(첫 7줄)만 읽어 검증: round ≥ 1, root ≠ 0, 0 < total ≤ 총 발행량, totalFire = total, count ≥ 1.
   가스는 수령자 수와 무관합니다 (2만 명·25 MB 파일로 로컬 anvil 전 과정 확인). 목록 본문 검증은 `verify.mjs`의 몫입니다
5. 내용 확인: root = `AIRDROP_EXPECTED_ROOT`(설정 시). 샘플 목록의 root는 경로 표기·복사본과 무관하게 메인넷에서 거부
6. 브로드캐스터 = `AIRDROP_WALLET`(설정 시). 브로드캐스터 잔액이 5,000만 FIRE를 넘으면 배포자 지갑일 수 있다고 경고
7. 중복 배포 차단: 브로드캐스터가 이전에 만든 컨트랙트(최근 256개 nonce) 중 같은 토큰·같은 root의 분배 컨트랙트가
   있으면 거부 (마감·sweep 이후에도). root가 다른 이전 분배 컨트랙트가 아직 클레임 기간 중이면 경고
8. 배포 + 정확히 total만큼 예치 (트랜잭션 2건) → 분배 컨트랙트 잔액 = 배포 전 잔액 + total,
   브로드캐스터 잔액 = 이전 − total 확인. 배포 주소는 미리 계산할 수 있어 누구나 배포 전에 FIRE를 보내 둘 수 있지만
   배포는 막히지 않습니다 (그 잔액은 로그에 표시되고 마감 후 sweep으로 회수됨)
9. 주소·root·마감 시각·검증용 생성자 인자·다음 단계 출력. 시뮬레이션이면 "아직 아무 트랜잭션도 전송하지 않음"으로 표시

**전송 후, 공지 전에 온체인에서 다시 확인하십시오** (시뮬레이션은 전송 결과를 보장하지 않음):

```bash
cast code <배포 주소> --rpc-url base                                    # 코드가 있어야 함
cast call <FIRE> "balanceOf(address)(uint256)" <배포 주소> --rpc-url base  # 예치량 이상
cast call <배포 주소> "MERKLE_ROOT()(bytes32)" --rpc-url base            # 공개한 root
cast call <배포 주소> "CLAIM_DEADLINE()(uint64)" --rpc-url base          # 공지할 마감 시각
```

- **클레임 마감** = 시뮬레이션 시점 블록 시각 + `AIRDROP_CLAIM_DAYS`일입니다. 위 `CLAIM_DEADLINE()` 값을 UTC·KST로
  변환해 공지하십시오. `cast call`은 큰 정수 뒤에 `[1.799e9]` 같은 표기를 덧붙이므로 첫 단어만 씁니다:
  ```bash
  DL=$(cast call <배포 주소> "CLAIM_DEADLINE()(uint64)" --rpc-url base | cut -d' ' -f1)
  date -u -d @$DL                 # UTC
  TZ=Asia/Seoul date -d @$DL      # KST
  ```
- 가스 (로컬 anvil 측정): 배포 약 48.7만, 예치 약 5.2만, claim 약 8.3만(증명 길이 4)~9.1만(증명 길이 15, 2만 명 목록),
  sweep 약 3.4만. 모두 트랜잭션당 가스 상한 16,777,216보다 훨씬 작고, claim은 수령자별 개별 트랜잭션이라 일괄 처리가 없습니다.
- 수동 배포(Remix 등)는 쓰지 마십시오. 위 확인이 모두 빠집니다. 컨트랙트 자체도 마감 시각이 배포 시점부터 365일을
  넘으면(예: 밀리초 단위 실수) 배포를 거부합니다.

## 7. 수령자 claim 방법 (공지용)

1. 공개된 `merkle.json`에서 본인 주소 항목의 `amount`(wei)와 `proof`를 찾습니다.
2. BaseScan → 배포 주소 → `Contract` → `Write Contract` → `claim(account, amount, proof)`
   (`proof`는 `["0x…","0x…"]` 형식). 또는 cast:
   ```bash
   cast send <배포 주소> "claim(address,uint256,bytes32[])" <account> <amount> "[0x…,0x…]" --rpc-url base --ledger
   ```
3. 누구나 대신 제출할 수 있으며(가스비 대납), 토큰은 항상 목록상의 `account`로 갑니다. 그래서 **수령 시점을 본인이 아닌
   제3자가 정할 수도 있습니다** (세무상 수령 시점 판단에 유의). `isClaimed(account)`로 청구 여부를 확인할 수 있습니다.
4. 마감 이후에는 claim할 수 없습니다 (`FireMerkleDistributorClaimWindowClosed`).

## 8. 주의사항

- **배포 후 목록은 바꿀 수 없고, 잘못 들어간 항목의 물량이 회수된다고 기대할 수도 없습니다.** claim은 누구나 대신
  제출할 수 있으므로(사양), 오타 주소·개인 키 없는 주소·거래소 입금 주소처럼 잘못 들어간 항목도 마감 전에 제3자(봇
  포함)가 그 주소로 보내 버릴 수 있고, 그렇게 나간 물량은 sweep으로 돌아오지 않습니다. 목록 오류를 막는 수단은
  **배포 전** 검증·공개·이의 제기 기간뿐입니다.
- 배포 후 오류를 발견하면: 그 컨트랙트는 마감까지 그대로 두고(중단할 방법 없음), 마감 후 `sweep()`으로 미청구분을
  회수한 뒤, **누락·정정이 필요한 항목만** 담은 새 목록(새 root)으로 배포합니다. 이미 청구한 주소(`isClaimed`)를 정정
  목록에 다시 넣으면 두 번 지급됩니다. 같은 root는 스크립트가 다시 배포하지 않습니다.
- 예치는 `merkle.json`의 total만큼만 합니다 (스크립트가 강제). 예치가 부족하면 일부 claim이 되돌려지고(청구 기록도 함께
  취소) 누구나 FIRE를 더 보내 채울 수 있으며, 초과분은 마감 후 sweep으로 에어드롭 지갑에 돌아옵니다.
- 마감 후에도 실수로 입금된 FIRE는 `sweep()`을 다시 호출하면 회수됩니다. **FIRE 외의 토큰**을 이 컨트랙트로 보내면
  회수할 방법이 없습니다 (관리자 기능 없음).
- `test/fixtures/airdrop-sample.json`은 테스트용 주소(개인 키 없음)이므로 절대 실제 배포에 쓰지 마십시오.
  메인넷에서는 스크립트가 경로 표기나 복사본과 관계없이 내용(root)으로 차단합니다.

## 9. 샘플·테스트

- `sample.csv`: `keccak256("fire-airdrop-sample-<n>")`의 하위 20바이트로 만든 9개 테스트 주소(개인 키 없음),
  합계 1000 FIRE. 소문자 주소 1개와 소수점 18자리 수량을 포함하며, leaf가 9개라 증명 길이가 3과 4로 섞인
  불균형 트리를 만듭니다.
- `npm run fixture`: `sample.csv`로 Foundry 픽스처 재생성
  (`test/fixtures/airdrop-sample.json` = merkle.json 형식, `test/fixtures/airdrop-sample-tree.json` = tree.json 형식).
  `npm run fixture:check`는 커밋된 픽스처가 최신인지 확인합니다 (`npm test`에도 포함).
- `npm test` (54건): CSV 검증(예약 대역·`--deny` 포함), 트리 생성, 숨은 leaf·recipients.csv 전수 대조 등 검증기, CLI
  (다음 단계 명령이 시뮬레이션 → `--broadcast --slow` 순서인지 포함), 배포 스크립트·저장소 문서와의 연동(merkle.json 헤더
  형식, 문서의 `--broadcast --slow`, forge의 Ledger 경로 플래그(복수형), 마감 시각 변환의 `cut -d' ' -f1`, 체크섬 표기
  UNCX 락커 주소, 로컬 포크 리허설의 캐시·개발 계정 주의, `.gitignore`: `airdrop/out/` 추적·`deployments/31337.json`·
  `lcov.info` 무시), 픽스처 최신 여부.
- Solidity 테스트: `forge test --match-path 'test/{FireMerkleDistributor,DeployAirdrop}.t.sol'`
  (픽스처의 모든 claim 성공, 트리 전체 해시 재계산 비교, 실패 경로, 기한 경계·365일 상한, 공개 함수 목록(디스패처
  선택자) 고정, 퍼즈, 불변식, 배포 스크립트의 모든 가드·merkle.json 헤더 검증·12 MB 파일 읽기·run() 환경 변수).
  배포 스크립트 테스트는 헤더 변형 파일을 실행 중에 `deployments/test-airdrop-*.json`으로 만들고 끝에서 지웁니다
  (테스트가 중간에 실패해 남으면 지워도 됩니다).

```
airdrop/
├── generate.mjs       목록 생성 CLI
├── verify.mjs         독립 검증 CLI
├── fixture.mjs        Foundry 테스트 픽스처 생성
├── lib/airdrop.mjs    공통 로직 (CSV 검증, 트리 생성, 전수 검증)
├── test/              node:test 테스트
├── sample.csv         샘플 목록 (테스트 주소)
├── out/               생성 결과 (회차별 디렉터리, 공개용으로 커밋)
├── .gitignore         airdrop/out/을 명시적으로 포함 (루트 /out/ 규칙과 별개인 이중 안전장치)
├── package.json · package-lock.json · .npmrc
└── README.md
```
