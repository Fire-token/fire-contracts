# FIRE (Fire) 토큰 개발 및 거래소 상장 종합 가이드라인

> **문서 기준일:** 2026-10-08 · **대상 네트워크:** Base 메인넷 (Chain ID 8453) · **컨트랙트 라이브러리:** OpenZeppelin Contracts v5.7.0

본 문서는 해외 법인 설립 없이 1인(소수) 오픈소스 빌더로서 규제 리스크를 낮추고, 온체인 신뢰 기반의 토크노믹스를 구축하여 탈중앙화 거래소(DEX) 및 중앙화 거래소(CEX) 상장까지 도달하기 위한 실전 실행 가이드입니다.

> **면책 고지:** 본 문서는 법률·세무 자문이 아닙니다. 법령 해석과 입법 동향은 2026년 10월 기준이며, 메인넷 배포 전 반드시 가상자산 전문 변호사·세무사의 검토를 받으십시오.

---

## 1. 프로젝트 개요 및 기반 인프라 선정

### 1.1 기본 정보
* **프로젝트명:** Fire
* **토큰 티커:** FIRE
* **토큰 표준:** ERC-20 (EVM 호환) + ERC-20 Permit (EIP-2612, 가스리스 승인용 선택 기능)
* **총 발행량 (Max Supply):** 1,000,000,000 FIRE (10억 개 고정, 추가 발행 불가)
* **소수점 (Decimals):** 18 (1 FIRE = 10^18 최소 단위)
* **컨트랙트 권한:** 소유자(Owner) 없음. 민팅·일시정지(Pause)·블랙리스트·거래세(Tax) 기능 없음

### 1.2 기반 네트워크: Base (Ethereum L2) 선정 배경
비트코인(BTC L1) 또는 자체 메인넷 구축 대신 **Base (이더리움 레이어 2)**를 최종 메인넷으로 채택합니다.

* **비트코인 L1(Runes/BRC-20)의 한계 극복:** 비트코인 L1은 튜링 완전 스마트 컨트랙트를 지원하지 않아, 개발자 물량을 온체인 코드로 강제 동결(Vesting)하거나 유니스왑(Uniswap) 방식의 자동화된 유동성 풀(AMM)을 구현하는 데 제약이 큽니다.
* **초저렴한 수수료 및 고속 처리:** 건당 수십 원 단위의 가스비와 1~2초 이내의 트랜잭션 확정성으로 소액 트레이더 유입에 유리합니다.
* **인프라 호환성:** 이더리움 가상머신(EVM) 100% 호환 체인이므로, Uniswap V2/V3, Aerodrome, UNCX, Team Finance, DexScreener, Safe(멀티시그) 등 글로벌 표준 디파이 인프라를 즉시 활용할 수 있습니다.
* **테스트넷:** Base Sepolia (Chain ID 84532) — 메인넷 배포 전 전체 절차를 반드시 리허설합니다.

### 1.3 토큰 유틸리티 및 오픈소스 로드맵 정의
FIRE는 단순 밈코인이 아닌, **Base 생태계 오픈소스 온체인 유틸리티 도구의 접근권(Access), 소각(Burn), 거버넌스(Governance)를 결합한 유틸리티 토큰**으로 정의합니다. 수익 배당·이자 약속이 없어 투자계약증권 논란을 최소화하면서, 온체인 소각(`ERC20Burnable`)과 오픈소스 개발 실체로 CEX 및 규제 심사에서 유리한 위치를 확보합니다.

#### 1) 핵심 유틸리티 메커니즘
* **온체인 소각 (Deflationary Burn):**
  * 개발자가 오픈소스로 제공하는 Base 유틸리티 웹 도구(예: 다중 지갑 배치 전송기 `Fire Batch Sender`, 유동성 락커 모니터링 알림 봇 `Fire Lock Tracker`)의 고급 기능 이용 시 프로토콜 수수료로 소액의 FIRE를 지불하며, 지불된 토큰은 `burn()` 함수를 통해 즉시 영구 소각됩니다.
  * 서비스 사용량이 증가할수록 유통량이 지속적으로 감소하는 디플레이션 가치 구조를 가집니다.
* **보유자 접근권 (Token-Gating):**
  * 일정 수량(예: 10,000 FIRE 이상)을 보유한 지갑에 대해 오픈소스 프로 분석 대시보드 및 실시간 고래 이동 알림 텔레그램 봇의 무료 이용 권한을 부여합니다.
* **가스리스 거버넌스 (Signaling Governance):**
  * Snapshot.org를 연동하여 가스비 없이(Off-chain EIP-712 서명) 차기 오픈소스 도구 기능 개발 우선순위 및 커뮤니티 안건에 대한 홀더 투표를 집행합니다.

#### 2) 유틸리티 설계 시 규제·운영 유의사항
* **소각은 사용자 지갑에서 직접 실행:** 수수료 FIRE는 개발자 지갑이나 컨트랙트가 먼저 받지 않습니다. 사용자가 도구 컨트랙트에 FIRE 사용을 승인(approve)하면, 도구 실행과 **같은 트랜잭션 안에서** `burnFrom(사용자, 수수료)`로 사용자 지갑에서 곧바로 소각됩니다 (`FireBatchSender` 구현, 3.4절). 개발자가 토큰을 수취·보관하지 않으므로 특금법상 수탁 논란과 개발자 측 소득 발생을 모두 피할 수 있고, 소각 사실은 같은 트랜잭션의 `Transfer(사용자 → 0 주소)` 기록과 `totalSupply()` 감소로 누구나 확인할 수 있습니다.
* **소각을 가격 상승 장치로 홍보하지 않음:** 백서·웹사이트·SNS에서 소각은 "이용 수수료 처리 방식"으로만 기술합니다. "소각으로 가격이 오른다"는 표현은 타인의 노력에 의한 수익 기대를 만들어 증권성 판단에 불리합니다.
* **비수탁(Non-custodial) 원칙:** `Fire Batch Sender`를 포함한 모든 도구는 사용자 자산을 컨트랙트에 보관하지 않고 단일 트랜잭션 안에서 전송만 수행하도록 설계합니다. 개발자가 사용자 자산을 통제·중개할 수 있는 구조가 되면 가상자산사업자 신고 대상이 될 수 있습니다 (2.1절).
* **Token-Gating 기준 수량은 조정 가능하게:** 런칭 시 10,000 FIRE는 약 0.00004 ETH에 불과하고, 가격이 오르면 반대로 진입 장벽이 과도해집니다. 기준 수량을 코드에 고정하지 말고 Snapshot 투표로 조정하는 절차를 백서에 명시합니다.
* **Snapshot 스페이스 준비:** 스페이스 생성에는 이더리움 메인넷 ENS 이름이 필요하므로 런칭 전에 확보합니다. Snapshot 투표는 시그널링(비구속)이며 실행은 개발자가 수행한다는 점을 공개합니다.

#### 3) 분기별 오픈소스 개발 로드맵
* **2026 Q4 (런칭 및 인프라 구축):**
  * Base 메인넷 컨트랙트 배포, Uniswap V3 풀 시딩(3 ETH) 및 LP 포지션 1년 온체인 락업
  * GitHub 오픈소스 레포지토리(MIT 라이선스) 공개 및 소스코드 검증(Verify)
  * 1차 에어드롭 2%(2,000만 FIRE): 초기 테스터·기여자 대상 Merkle 클레임 오픈 (클레임 기한 90일)
  * 2차 에어드롭용 3%(3,000만 FIRE)는 에어드롭 전용 지갑에 보관, Base Safe 트레저리 5% 온체인 예치
  * Snapshot 거버넌스 스페이스 개설
* **2027 Q1 (유틸리티 도구 v1 런칭):**
  * `Fire Batch Sender` (Base 체인 저가스 다중 토큰 전송 도구) 배포 및 FIRE 소각 연동
  * DexScreener / DEXTools 공식 프로필 인증 및 커뮤니티 홀더 1,000명 달성
  * 2차 에어드롭 3%(3,000만 FIRE) 지급 기준 공개: `Fire Batch Sender` 등 유틸리티 도구 실사용 지갑 대상
* **2027 Q2 (유틸리티 확장 및 Tier 3/2 CEX 타겟):**
  * `Fire Lock Tracker` (L2 신규 토큰 유동성 락커 상태 추적 봇) 런칭 및 Token-Gating 적용
  * 2차 에어드롭 스냅샷 및 Merkle 클레임 오픈
  * 온체인 거래량 기반 MEXC, Bitget 등 해외 CEX 상장 제안 대응 (트레저리 5% 활용)
* **2027 Q3~Q4 (생태계 다변화 및 법인화 검토):**
  * 개발자 지분 베스팅 클리프 종료(배포 시각 + 180일, 2026년 11~12월 배포 기준 2027년 5~6월) 후 해제분에 대한 7.2절 매도 정책 준수. 매도 정책은 클리프 종료 **전**에 게시
  * 상장 규모 확대 시 해외 재단/법인 설립(KYB) 및 대형 거래소 파이프라인 진입

---

## 2. 무(無)법인 빌더 전략 및 토크노믹스

### 2.1 규제 리스크 최소화 대원칙 (Fair Launch)
해외 재단을 세우지 않고 개인이 프로젝트를 진행할 때 리스크를 가장 낮추는 원칙은 **"외부 투자금을 일절 받지 않는 것(No Pre-sale, No ICO, No Private Round)"**입니다.

* **투자금 수취 금지:** 사전에 투자자로부터 돈(ETH, USDT, 원화 등)을 받으면 자본시장법(투자계약증권 해당 시 증권신고 의무 위반) 및 유사수신행위규제법 위반으로 처벌받을 수 있습니다.
* **오픈소스 배포 + 본인 자금 시딩:** 개발자가 오픈소스 코드를 온체인에 배포하고 **본인 자금으로만 DEX 풀을 시딩(Seeding)**하는 방식은 투자계약이 성립하지 않는다는 유력한 논거가 됩니다. 다만 금융당국이 이를 공식적으로 "규제 대상 아님"으로 분류한 선례는 없으므로, 리스크를 **최소화**하는 것이지 **제거**하는 것은 아닙니다.
* **현행 적용 법령 (2026년 10월 기준):**
  * **가상자산이용자보호법 (2024년 7월 시행):** 불공정거래 금지 조항(미공개중요정보 이용, 시세조종, 부정거래)은 발행자·개발자에게도 적용됩니다. 본인 지갑 간 거래로 거래량을 부풀리는 워시트레이딩, 중요 발표 직전 매도는 금지 행위에 해당할 수 있습니다.
  * **특정금융정보법(특금법):** 가상자산사업자(VASP) 신고 의무는 타인을 위한 매매·교환·이전·보관 **영업**에 적용됩니다. 단순 발행 + 본인 유동성 공급은 통상 해당하지 않으나, 타인 자산을 보관·중개하는 서비스로 확장하면 신고 대상이 될 수 있습니다.
* **입법 동향 (반드시 배포 직전 재확인):** **디지털자산기본법**이 국회 정무위원회에 계류 중이며(2026년 10월 현재 미통과), 의원안에는 **발행신고제**와 허위공시 손해배상책임이 포함되어 있습니다. 시행은 2027~2028년으로 전망되나, 통과 시 국내 거주자의 신규 토큰 발행에 신고 의무가 생길 수 있습니다. 배포 시점에 국회 의안정보시스템과 금융위원회 발표를 확인하십시오.

### 2.2 공급량 분배 구조

스마트 컨트랙트 코드 수정 없이 배포 시점의 전송 분리를 통해 **CEX 상장 및 마켓메이커(MM) 지원용 트레저리 5%**를 확보한 최적화 구조입니다.

| 배분 항목 | 수량 (FIRE) | 비율 | 집행 및 보관 방식 | 목적 |
| :--- | :--- | :---: | :--- | :--- |
| **DEX 초기 유동성 풀** | 700,000,000 | 70% | Uniswap V3 전체 범위(Full Range) 포지션 생성 후 **LP 포지션 NFT 1년 락업** | 러그풀 의혹 차단 및 거래 활성화 |
| **개발자 지분 (본인)** | 200,000,000 | 20% | 토큰 생성자에서 `FireVesting` 컨트랙트로 직접 발행 (**180일 클리프: 해제 0 → 이후 540일 선형 해제**, 총 720일. 본 문서의 "6개월·18개월·24개월"은 30일 환산 표기) | 개발자 장기 자산화 및 덤핑 공포 불식 |
| **커뮤니티 및 에어드롭** | 50,000,000 | 5% | 에어드롭 전용 지갑으로 이체 후 **2회 분할 지급**: 1차 2,000만(2%, 런칭 시 초기 테스터·기여자) + 2차 3,000만(3%, 2027년 도구 실사용자 보상). 각 회차는 Merkle 클레임 컨트랙트로 지급 | 초기 지갑 홀더 수(1,000+) 확보 및 실사용자 유입 |
| **CEX 상장 & MM 트레저리** | 50,000,000 | 5% | **Base Safe(구 Gnosis Safe) 멀티시그 지갑** 보관 | CEX 상장 마케팅 바운티 및 MM 유동성 대여 |

> **트레저리 운영 및 온체인 신뢰 원칙:**
> * CEX 상장 시 거래소가 요구하는 마케팅 에어드롭/입금 이벤트 물량(보통 총량의 1~3%) 및 오더북 유동성 대여(MM Loan)를 충당하기 위해 필수적인 예비분입니다.
> * 배포자 개인 지갑에 두지 않고 **Base Safe 멀티시그 지갑**에 이체한 뒤 주소를 백서에 공개합니다. "공식 CEX 상장 계약 체결 시에만 거래소로 전송되며, 시장에 무단 매도되지 않는다"는 운영 원칙을 명시하여 덤핑 의혹을 원천 차단합니다.
> * 1인 프로젝트라도 서명자를 최소 **2-of-3**(하드웨어 지갑 2개 + 신뢰할 수 있는 제3자 1인 등)으로 구성해야 멀티시그로서 의미가 있으며, 서명자 구성을 백서에 공개합니다. 서명자 전원이 본인 기기라면 "개발자 단독 통제 지갑"임을 숨기지 말고 명시합니다.
> * 배포 스크립트는 메인넷에서 트레저리가 서명 임계값 2 이상·소유자 3명 이상이고 **모듈이 없는** Safe인지 확인하고, 아니면 배포를 거부합니다. 모듈은 서명 없이 자산을 옮길 수 있는 통로라 허용하지 않습니다.
> * MM 유동성 대여 계약은 통상 법인 명의로 체결되므로, 실제 집행은 2단계 법인 설립 이후가 됩니다. 그 전까지 트레저리는 거래소 주관 마케팅 이벤트 물량 제공에만 사용합니다.
> * 트레저리 5%의 실질 가치는 FIRE 시세에 연동됩니다 (런칭 FDV 기준 약 0.21 ETH). Tier 1 상장 비용을 충당하려면 가격 상승이 선행되어야 하므로, 부족분은 7.1절 수익원으로 보충합니다.
> * 스마트 컨트랙트(`FireToken.sol`)는 배포자가 8억 개를 수령하므로, 배포 직후 7억 개는 LP 풀에 공급하고 5,000만 개는 에어드롭 지갑, 5,000만 개는 Safe 트레저리로 전송하면 코드를 수정할 필요가 없습니다.

### 2.3 초기 가격 및 FDV 설계 (3 ETH 시딩 권장)
Uniswap 풀의 초기 가격은 **예치한 ETH ÷ 예치한 FIRE** 비율로 결정됩니다. 7억 FIRE를 예치하므로 완전희석가치(FDV)는 시딩 ETH의 약 1.43배(= 10억 ÷ 7억)가 됩니다.

| 시딩 ETH | 초기 가격 (1 FIRE) | 초기 FDV | 풀 총 유동성 (ETH $2,500 가정) | 평가 및 특성 |
| :---: | :--- | :---: | :---: | :--- |
| 1 ETH | 1 ÷ 700,000,000 ETH | 약 1.43 ETH | 약 $5,000 | 자금 부담은 적으나 유동성이 얇아 트레이더들의 '유동성 $10k 이상' 필터에서 제외되어 노출이 급감함 |
| **3 ETH**<br>**(★ 확정 권장)** | **3 ÷ 700,000,000 ETH**<br>(약 4.286 × 10⁻⁹ ETH) | **약 4.29 ETH**<br>(약 $10,725) | **약 $15,000** | **Golden Balance:** DexScreener 정상 토큰 노출, 스나이퍼 봇 방어력 확보, 일반 매수 슬리피지 안정 |
| 5 ETH | 5 ÷ 700,000,000 ETH | 약 7.14 ETH | 약 $25,000 | 유동성이 매우 탄탄하나 1인 빌더에게 1년간 잠기는 자금 부담 큼 |

* **3 ETH 채택 이유:** 덱스 애그리게이터(DexScreener, DEXTools)에서 일반 트레이더들은 보통 "유동성 $10,000 이상" 필터를 적용합니다. 3 ETH(양방향 풀 합산 약 $15,000)를 공급해야 스캠 탐지 필터를 통과하고 자연 매수세가 유입됩니다.
* **ETH 시세 변동 대응:** 위 달러 환산은 ETH $2,500 가정입니다. 실제 기준은 ETH 개수가 아니라 **풀 총 유동성 $15,000 이상**이므로, 배포 당일 ETH 시세로 환산하여 3 ETH가 부족하면 ETH를 늘리고, 충분히 높으면 3 ETH를 유지합니다.
* **준비 자금 (총 약 3.15 ETH 권장):** 풀 시딩용 3 ETH 외에 UNCX 락업 고정 수수료 0.1 ETH와 가스비를 감안해 배포 지갑에 **3.15 ETH 내외**를 준비하십시오. UNCX는 이와 별도로 락업할 때 LP의 0.5%를 떼어 가므로, 실제로 잠기는 유동성은 약 99.5%입니다 (5장 3항).
* **정확한 초기 가격:** 3 ETH 시딩 시 1 FIRE = 0.000000004285714285 ETH, FDV 약 4.2857 ETH입니다. `CreatePool` 스크립트가 같은 값을 계산해 출력하므로 배포 전에 대조합니다.
* 시딩 ETH는 1년 락업되므로, **1년간 회수하지 않아도 되는 금액**으로만 시딩하십시오.
* **스나이퍼·풀 선점 대응:** 토큰 주소는 배포 지갑 주소와 nonce로 미리 계산할 수 있고, 토큰 배포의 첫 트랜잭션이 블록에 들어가는 순간 공개됩니다. 그때부터 누군가 엉뚱한 가격으로 풀을 먼저 만들어 둘 수 있습니다. 메인넷 배포 지갑은 리허설에 쓰지 않은 **새 지갑**으로 하고 런칭 전에 공개하지 않으며, 토큰 배포 직후 곧바로 풀 생성까지 진행하고 소스 검증·홍보는 LP 락업 이후로 미룹니다. 이렇게 해도 노출 시간을 줄일 뿐 선점을 완전히 막지는 못합니다. 풀 생성 스크립트는 다른 가격의 풀을 발견하면 아무것도 보내지 않고 중단하므로 자금 손실은 없습니다 (5장 "남은 위험").

### 2.4 에어드롭 운영 원칙
* **지급 대상·기준을 사전에 공개**하고, 지급 후 수령 지갑 목록을 공개합니다 (공정성 입증).
* **Sybil(다중 지갑) 필터링:** 지갑 생성일, 온체인 활동 이력, 최소 잔고 등 객관적 기준을 적용합니다.
* **세금:** 국세청은 2022년 유권해석에서 가상자산 에어드롭을 수령자에 대한 **증여세 과세 대상**으로 본 바 있습니다. 국내 거주자에게 지급하는 경우 수령자 측 세무 이슈가 있음을 공지문에 명시하십시오.
* **투자금 수취 금지 원칙 유지:** 에어드롭 참여 조건으로 금전·토큰 입금을 요구하지 않습니다.
* **분할 지급 (확정):** 5%(5,000만 FIRE)를 런칭 시 일괄 지급하면 초기 매도 압력이 집중되므로 2회로 나눕니다.

| 회차 | 수량 | 시기 | 대상 | 방식 |
| :--- | :--- | :--- | :--- | :--- |
| 1차 | 20,000,000 FIRE (2%) | 2026 Q4 런칭 직후 | 테스트넷 리허설 참여자, GitHub 기여자, 초기 커뮤니티 | Merkle 클레임 컨트랙트, 클레임 기한 90일 |
| 2차 | 30,000,000 FIRE (3%) | 2027 Q1 기준 공개, Q2 스냅샷·지급 | `Fire Batch Sender` 등 유틸리티 도구 실사용 지갑 | Merkle 클레임 컨트랙트, 지급 기준 사전 공개 |

* **미청구 물량 처리:** 클레임 기한이 지난 미청구 물량은 에어드롭 전용 지갑으로 회수하여 다음 회차에 이월하며, 이월 수량을 공개합니다. 개발자 개인 지갑이나 트레저리로 옮기지 않습니다.
* **Merkle 클레임 방식의 의미:** 지급 대상과 수량 목록 전체를 사전에 공개하고 그 해시(Merkle Root)를 컨트랙트에 고정하므로, 배포 후에는 개발자도 목록·수량·기한·회수처를 바꿀 수 없습니다. 분배 컨트랙트(`FireMerkleDistributor`, 3.3절)에는 관리자 권한이 전혀 없습니다.
* **청구 방식:** 수령자가 직접 청구하는 것이 원칙이지만, 컨트랙트상 **누구나 대신 제출**할 수 있고 토큰은 항상 목록에 적힌 주소로만 갑니다. 따라서 수령 시점을 제3자가 정할 수 있다는 점을 세무 공지에 함께 적습니다.
* **기한 규칙:** 마감 시각까지(마감 시각 포함) 청구할 수 있고, 그다음부터는 누구나 `sweep()`을 호출해 미청구분 전부를 에어드롭 지갑으로 회수할 수 있습니다. 마감은 배포 시점부터 최대 365일로 컨트랙트가 제한합니다.
* **2차 회차 수량:** 2차 목록의 총량은 3,000만 FIRE에 1차 회수량을 더한 값입니다. 회수량과 이월 내역을 공개합니다.
* **목록 오류는 배포 후 고칠 수 없음:** 오류를 발견하면 마감까지 두고 회수한 뒤, 누락·정정 항목만 담은 새 목록으로 다시 배포합니다. 이미 청구한 주소를 다시 넣으면 이중 지급되므로 주의합니다. 거래소 입금 주소와 다른 체인에만 있는 Safe 주소는 목록에 넣지 않습니다.

---

## 3. 스마트 컨트랙트 아키텍처

구현 레포지토리는 `fire-contracts`이며, 이 문서도 그 저장소 루트에 함께 보관합니다. 컨트랙트는 4종이며 배포 시기가 다릅니다.

| 컨트랙트 | 역할 | 배포 시기 | 관리자 권한 |
| :--- | :--- | :--- | :--- |
| `FireVesting` | 개발자 지분 2억 개 락업·선형 해제 | 런칭 (토큰보다 먼저) | 수익자 지갑 교체(2단계)만 가능 |
| `FireToken` | FIRE 토큰 10억 개 일괄 발행 | 런칭 | 없음 |
| `FireMerkleDistributor` | 회차별 에어드롭 클레임 | 1차: 런칭 직후, 2차: 2027 Q2 | 없음 |
| `FireBatchSender` | 다중 전송 도구 + FIRE 소각 수수료 | 2027 Q1 | 수수료 값 조정만 가능 (Safe 소유) |

베스팅 컨트랙트는 토큰 주소를 필요로 하지 않으므로 **먼저** 배포하고, 토큰 생성자가 개발자 지분 2억 개를 베스팅 컨트랙트로 **직접 발행**합니다. 이렇게 하면 배포자 지갑이 10억 개 전량을 보유하는 구간이 사라지고, 개발자 물량이 잠겨 있다는 사실이 발행 트랜잭션 자체로 증명됩니다.

> **라이브러리·컴파일러 버전 고정:** 아래 코드는 구현 레포지토리 `fire-contracts/src/`의 파일과 동일하며, OpenZeppelin Contracts v5.7.0과 solc 0.8.30(EVM `cancun`, Optimizer 200 runs)으로 컴파일·테스트되었습니다. OpenZeppelin v5.7.0의 `ERC20Permit`은 **solc 0.8.24 이상**을 요구하므로 0.8.20~0.8.23으로는 컴파일되지 않습니다. 배포는 4장의 Foundry 스크립트로만 합니다. Remix 같은 수동 배포는 주소 검증·통제 증명·잔고 확인 같은 스크립트의 안전장치가 모두 빠지므로 사용하지 않습니다.

### 3.1 개발자 물량 베스팅 컨트랙트 (`FireVesting.sol`)
```solidity
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
```

**이전 자체 구현 대비 변경 이유**
1. **클리프 수식 오류 수정:** 이전 코드는 선형 해제의 기준점이 클리프 종료가 아닌 배포 시각(`start`)이었습니다. 24개월 전체를 분모로 쓰면서 클리프 6개월이 지나는 순간 **전체의 25%(5,000만 FIRE)가 한 번에 해제**되어 "6개월 완전 락업 후 18개월 선형"이라는 공개 약속과 어긋났습니다. 새 구조는 클리프 종료 시점이 `start`이므로 클리프 직후 해제량이 0에서 시작합니다.
2. **감사 완료 코드 사용:** 자체 구현은 `transfer` 반환값 미확인(SafeERC20 미사용), 0 주소 검증 누락 등이 있었습니다. 해제 로직은 OpenZeppelin `VestingWallet`을 그대로 사용하고, 추가한 코드는 아래 소유권 보호 장치뿐입니다.
3. **수령 지갑 교체 가능 (2단계 방식):** 이전 코드는 수익자가 `immutable`이라 개인 키 분실 시 2억 FIRE가 영구 동결되었습니다. 새 코드는 `Ownable2Step`을 결합하여, 현재 수령 지갑이 `transferOwnership(새 주소)`를 호출하고 **새 지갑이 직접 `acceptOwnership()`을 호출해야** 교체가 완료됩니다. 주소를 잘못 입력해도 그 주소가 수락하지 않는 한 소유권이 넘어가지 않으며, 수락 전에는 다른 주소로 다시 지정하거나 0 주소로 지정해 취소할 수 있습니다.
   * **단, 최초 수익자는 이 보호 밖입니다.** 생성자에 넣은 수익자 주소는 수락 절차 없이 즉시 owner가 됩니다. 오타 주소나 Base에 없는 Safe 주소를 넣으면 2억 FIRE를 영구히 잃습니다. 그래서 메인넷 배포 스크립트는 수익자 지갑이 직접 서명한 **통제 증명**(Safe라면 Base에 실제로 배포된 Safe인지 확인)이 없으면 배포를 거부합니다 (4장).
4. **소유권 포기 차단:** OpenZeppelin `Ownable`의 `renounceOwnership()`을 호출하면 수령 지갑이 0 주소가 되어 남은 물량이 영구 동결됩니다. 실수 한 번으로 2억 FIRE를 잃지 않도록 이 함수는 항상 실패하게 막았습니다.

**해제 수량 계산 (총 2억 FIRE 기준)**

| 시점 (베스팅 배포 블록 기준) | 해제 가능 누적 수량 |
| :--- | :--- |
| 0 ~ 180일 | 0 |
| 181일 (클리프 + 1일) | 370,370.37 FIRE (2억 × 1일 ÷ 540일) |
| 360일 | 66,666,666.67 FIRE (전체의 1/3) |
| 720일 이후 | 200,000,000 FIRE (전량) |

* 컨트랙트 일정은 초 단위이며 달력 월과 다릅니다. 예를 들어 2026-11-16 00:00 UTC에 배포하면 클리프 종료는 2027-05-15 00:00 UTC, 전량 해제는 2028-11-05 00:00 UTC입니다.
* 배포 후 `start()`와 `end()` 값을 UTC 날짜로 바꿔 공개하고, 백서·웹사이트에는 "개월" 대신 일 단위와 이 날짜를 씁니다.
* 클리프 직후 일시 해제는 없고, 이후 초당 약 4.29 FIRE씩 늘어납니다. `release(FIRE 주소)`는 누구나 호출할 수 있지만 토큰은 항상 현재 수령 지갑으로만 갑니다.

> **주의:** `VestingWallet`은 컨트랙트에 **나중에 추가로 입금된 토큰도 처음부터 잠겨 있던 것처럼** 계산합니다. 베스팅 시작 후 토큰을 추가 입금하면 그 일부가 즉시 해제 가능해지므로, 2억 개 외의 토큰을 이 주소로 보내지 마십시오.

### 3.2 토큰 컨트랙트 (`FireToken.sol`)
* **베스팅 주소 검사:** 생성자 인자 `vesting`은 코드가 있는 주소여야 하고, `start()`·`duration()` 조회에 응답해야 하며, 발행 시점에 해제가 시작되지 않은 상태여야 합니다. 개인 지갑, Safe, EIP-7702 스마트 계정 주소를 실수로 넣으면 배포 자체가 실패합니다. 이 검사는 실수 방지용이며, 베스팅 컨트랙트의 실제 내용은 BaseScan 소스 검증으로 확인합니다.
* **8억 개의 수령자:** 나머지 8억 개는 생성자를 실행한 주소(`msg.sender`)로 발행됩니다. CREATE2 팩토리 같은 다른 컨트랙트를 거쳐 배포하면 그 컨트랙트가 8억 개를 받아 영구히 묶이므로, 반드시 배포 지갑에서 직접 배포합니다. 배포 스크립트는 이 방식으로 배포하고 잔고를 확인합니다.

```solidity
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
```

### 3.3 에어드롭 분배 컨트랙트 (`FireMerkleDistributor.sol`)
* 회차마다 새로 배포합니다. owner·관리자·일시정지·업그레이드 기능이 없고, 토큰·Merkle Root·마감 시각·회수 주소가 모두 배포 시 고정됩니다.
* 공개 함수는 `claim`, `sweep`, `isClaimed`와 고정값 조회뿐이며, 테스트가 배포된 바이트코드의 함수 목록을 고정해 숨은 관리자 함수가 끼어들 수 없음을 증명합니다.
* Merkle 잎(leaf)은 OpenZeppelin `StandardMerkleTree` 형식(`address`, `uint256` 이중 해시)이며, 목록 생성·검증 도구는 `fire-contracts/airdrop/`에 있습니다. 제3자도 `verify.mjs`로 공개 목록과 Root가 정확히 일치하는지, 숨은 할당이 없는지 확인할 수 있습니다.
* 운영 규칙은 2.4절, 배포 명령은 4장 Step 8을 따릅니다.

### 3.4 다중 전송 도구 (`FireBatchSender.sol`, 2027 Q1 배포)
* 한 트랜잭션으로 ETH 또는 임의의 ERC-20을 최대 300명에게 보냅니다. 한 건이라도 실패하면 전체가 취소됩니다.
* **비수탁:** ERC-20은 송신자에서 수령자로 직접 이동하고, ETH는 받은 금액을 그 자리에서 전부 전달합니다. 컨트랙트에는 자산이 남지 않으며, 출금·일시정지·자산 회수 기능도 없습니다.
* **소각 수수료:** 수령자 수가 무료 한도(기본 25명)를 넘으면 정액 수수료(기본 10,000 FIRE)를 사용자 지갑에서 같은 트랜잭션 안에 소각합니다. 수수료 상한 100만 FIRE가 코드에 고정되어 있고, 사용자는 `maxBurnFee`로 지불 상한을 지정하므로 수수료 인상이 먼저 처리돼도 초과 청구되지 않습니다.
* **소유자 권한:** 트레저리 Safe가 소유하며, 할 수 있는 일은 무료 한도와 수수료 값 조정뿐입니다. 소유자 교체는 2단계 방식이고 소유권 포기는 막혀 있습니다.
* **수령자 제한:** 0 주소·프리컴파일 대역, Base 시스템 컨트랙트 대역(예: WETH), 도구 자신, FIRE 토큰, 송신자 자신, 보내는 토큰 컨트랙트 자신은 거부합니다. 이런 주소로 보내면 자산이 도구 명의로 묶이거나 사라지기 때문입니다.
* **2차 에어드롭 집계 주의:** 도구가 남기는 `BatchSent` 기록은 호출자가 입력한 값이라 가치 이동의 증거가 아닙니다. 2차 에어드롭 기준은 허용 자산 목록, 같은 트랜잭션의 실제 `Transfer` 기록, 고유 수령자 수, 자금 흐름 분석으로 정하고 스냅샷 전에 공개합니다.

### 3.5 보안 및 투명성 근거
* **권한 없음 증명:** `FireToken`에는 소유자·민팅·일시정지·블랙리스트·거래세가 없습니다. 테스트는 이름 목록 대조에 그치지 않고, 배포된 코드에서 외부 함수 목록을 직접 읽어 정확히 고정하고(`test_ExternalSelectorSetIsExact`), 컴파일된 바이트코드 해시까지 고정합니다(`test_Bytecode_MatchesPinnedBuild`). 함수가 하나 늘거나 내부 로직이 바뀌면 테스트가 실패합니다. 배포 후 DexScreener·DEXTools의 GoPlus 스캔과 Token Sniffer에서 "Honeypot 아님 / 민팅 불가 / 소유자 없음"을 확인하고 화면을 보관합니다.
* **테스트 범위:** 단위·퍼즈·불변식 테스트와 Base 메인넷·Sepolia 포크 테스트를 합쳐 534개가 모두 통과합니다. 커버리지는 컨트랙트(`src/`) 4종 모두 100%, 배포 스크립트 포함 전체 라인 기준 약 97%입니다. 의도적으로 백도어를 심은 변형 13종(숨은 민팅, 일정 변경, 허가 없는 인출 등)이 모두 테스트에서 검출되는 것도 확인했습니다. 실행 방법은 저장소 `README.md`에 있습니다.
* **정적 분석·리허설:** Slither 정적 분석 결과는 모두 오탐으로 판정됐고 판정 근거는 저장소 `SECURITY.md`에 있습니다. 로컬 Base 메인넷 포크에서 실제 Safe와 실제 UNCX 락커로 배포부터 락업, 점검 PASS, 에어드롭, Batch Sender 배포까지 전 과정을 리허설했습니다.
* **배포 지갑 보안:** 배포 지갑은 8억 FIRE와 LP 포지션을 다루므로 **하드웨어 지갑**(Ledger 등)을 사용합니다. 시드 구문은 오프라인 보관합니다. 개인 키는 `.env` 파일에 넣지 않습니다.
* **테스트넷 리허설:** Base Sepolia에서 4장의 전체 절차를 실제 Ledger로 한 번 이상 완주합니다 (4장 Step 2).
* **감사(Audit):** `FireToken`·`FireVesting`은 OpenZeppelin 구성요소에 소량의 보호 코드만 더한 구조라 런칭 전 고가의 수동 감사는 필수가 아닙니다. 반면 `FireMerkleDistributor`·`FireBatchSender`는 자체 로직이 있으므로, 내부 검토와 별개로 각 배포 전에 저비용 외부 감사(Cyberscope, SolidProof 등)를 받는 것을 권장합니다. 외부 감사를 받기 전에는 "외부 감사 미실시"를 README와 웹사이트에 명시합니다.
* **컴파일러 설정 고정:** solc 0.8.30, Optimizer 200 runs, EVM `cancun`, OpenZeppelin v5.7.0입니다. 소스 검증(Verify)과 바이트코드 고정 테스트가 모두 이 설정을 기준으로 합니다.

---

## 4. 실전 배포 매뉴얼 (Foundry 스크립트)

배포는 `fire-contracts` 저장소의 Foundry 스크립트로만 진행합니다. 스크립트는 전송 전에 시뮬레이션을 먼저 돌리고, 주소 검증·통제 증명·중복 배포 검사·사후 잔고 확인 중 하나라도 실패하면 **아무것도 전송하지 않습니다**. Remix 같은 수동 배포는 이 안전장치를 모두 건너뛰므로 금지합니다. 명령별 상세 설명과 오류 목록은 저장소의 `deployments/README.md`에 있습니다.

**모든 단계에 공통인 규칙**
* 명령은 저장소 루트에서 실행합니다. 네트워크는 `--rpc-url base` 또는 `--rpc-url base_sepolia`만 씁니다. `--chain` 옵션과 `FOUNDRY_CHAIN_ID` 환경변수는 쓰지 않습니다. 스크립트가 RPC의 실제 체인 ID와 대조해 다르면 중단합니다.
* 항상 **전송 옵션 없이 먼저 실행**해 출력과 경고를 확인한 뒤, 같은 명령에 `--broadcast --slow`를 붙여 전송합니다. 전송이 중간에 끊기면 같은 명령에 `--resume`을 붙이고, `deployments/<체인ID>.json` 기록 파일은 지우지 않습니다.
* 메인넷 명령은 시뮬레이션을 포함해 모두 앞에 `CONFIRM_MAINNET=I_UNDERSTAND`를 붙입니다. 이 값은 `.env`에 넣지 않습니다.
* 개인 키는 `.env`나 명령줄에 넣지 않고 `--ledger`(하드웨어 지갑) 또는 `--account <키스토어 이름>`을 씁니다. Ledger의 첫 계정이 아니면 `forge script`에는 `--mnemonic-derivation-paths "m/44'/60'/<n>'/0/0"`(복수형)과 `--sender`를, `cast`에는 `--mnemonic-derivation-path`(단수형)를 붙입니다.
* 주소는 지갑·BaseScan·Safe 앱에서 복사한 **EIP-55 체크섬 표기 그대로** 넣습니다. 대소문자 오타는 모든 체인에서, 전부 소문자인 주소는 메인넷에서 거부됩니다.

### Step 0: 도구와 저장소 준비
1. Foundry 1.8.5와 Node.js 24를 설치합니다.
   ```
   curl -L https://foundry.paradigm.xyz | bash && foundryup --install 1.8.5
   git clone <저장소 주소> && cd fire-contracts && git submodule update --init --recursive
   ```
2. 사전 점검을 실행합니다. 포크 테스트까지 모두 통과해야 합니다.
   ```
   forge fmt --check && forge build --sizes --deny warnings
   BASE_RPC_URL=https://mainnet.base.org BASE_SEPOLIA_RPC_URL=https://sepolia.base.org forge test
   cd airdrop && npm ci && npm test && cd ..
   ```
3. `cp .env.example .env` 후 `BASE_RPC_URL`(메인넷은 전용 RPC 권장), `BASE_SEPOLIA_RPC_URL`, `ETHERSCAN_API_KEY`, `BENEFICIARY`, `TREASURY_SAFE`, `AIRDROP_WALLET`을 채웁니다. 나머지 변수의 의미와 기본값은 `.env.example`에 적혀 있습니다.

### Step 1: 지갑 준비
| 지갑 | 조건 |
| :--- | :--- |
| 배포 지갑 | 리허설과 공개 기록에 한 번도 쓰지 않은 **새 하드웨어 지갑 EOA**. 코드가 없어야 함. 시딩 ETH(기본 3 ETH, 메인넷 최소 1 ETH)와 약 0.15 ETH를 준비. 런칭 전까지 주소 비공개 |
| 수익자 `BENEFICIARY` | 하드웨어 지갑 EOA, 또는 모듈이 없는 Base Safe |
| 트레저리 `TREASURY_SAFE` | Base에 배포된 Safe, 서명 임계값 2 이상·소유자 3명 이상, 모듈 없음 |
| 에어드롭 `AIRDROP_WALLET` | 하드웨어 지갑 EOA 권장. 에어드롭 배포 때 전송 지갑이 됨 |

### Step 2: Base Sepolia 리허설 (필수)
* Step 3~8을 `--rpc-url base_sepolia`로 끝까지 진행합니다. 지갑은 Sepolia 전용으로 따로 쓰고, 시딩은 소액으로 합니다(예: `SEED_ETH=10000000000000000`, 0.01 ETH).
* **실제 Ledger로** 통제 증명 서명, permit 서명, 토큰 배포 4건 승인, 풀 생성 트랜잭션을 각각 한 번 이상 실행합니다. 이 경로는 기기 없이 자동 테스트할 수 없습니다.
* Sepolia에서 만든 서명은 체인 ID가 달라 메인넷에서 쓸 수 없습니다. 메인넷용으로 다시 서명합니다.
* 로컬 메인넷 포크 리허설은 선택입니다. 하려면 `anvil --fork-url https://mainnet.base.org --no-storage-caching`으로 띄우고, anvil 기본 개발 계정은 쓰지 않습니다. 이 계정들은 Base 메인넷에서 EIP-7702 스위퍼에 위임되어 있어 결과가 왜곡됩니다. 상세 절차는 `deployments/README.md`에 있습니다.

### Step 3: 수령 지갑 통제 증명 (메인넷 필수)
최초 수익자는 수락 절차 없이 즉시 베스팅 owner가 되므로(3.1절), 배포 전에 수익자 지갑과 에어드롭 지갑을 실제로 통제한다는 서명을 받습니다.
1. 서명할 메시지와 명령을 출력합니다.
   ```
   forge script script/Deploy.s.sol:Deploy --sig "printProofMessages()" --rpc-url base
   ```
   메시지 형식은 `FIRE launch control proof | role=<BENEFICIARY 또는 AIRDROP_WALLET> | address=<체크섬 주소> | chainId=8453`입니다.
2. 서명합니다.
   * EOA(7702 위임 EOA 포함): 해당 지갑으로 `cast wallet sign --ledger "<메시지>"` 1회.
   * Safe: 서로 다른 현재 소유자들이 임계값 이상 각자 같은 메시지에 서명하고, `0x` 뒤에 서명들을 이어 붙입니다.
3. `cast wallet verify --address <서명자> "<메시지>" <서명>`으로 확인한 뒤 `BENEFICIARY_PROOF_SIG`, `AIRDROP_WALLET_PROOF_SIG`로 export하고, 1번 명령을 다시 실행해 두 항목이 모두 `verified`인지 확인합니다.

### Step 4: 토큰·베스팅 배포 (트랜잭션 4건)
```
CONFIRM_MAINNET=I_UNDERSTAND forge script script/Deploy.s.sol:Deploy --rpc-url base --ledger --sender <배포 지갑>
CONFIRM_MAINNET=I_UNDERSTAND forge script script/Deploy.s.sol:Deploy --rpc-url base --ledger --sender <배포 지갑> --broadcast --slow
```
* Ledger 승인 순서는 FireVesting 배포 → FireToken 배포 → 트레저리로 5,000만 → 에어드롭 지갑으로 5,000만입니다. 분배까지 한 번의 실행으로 끝납니다.
* 메인넷 가드: 배포 지갑에 코드가 없는지, 트레저리가 2-of-3 이상이고 모듈이 없는지, 통제 증명, 중복 배포, 예측 토큰 주소의 풀 선점 여부. 풀 선점으로 중단되면(`DeployPoolPreempted`) 배포 지갑 주소가 노출된 것이므로 새 배포 지갑으로 처음부터 다시 합니다.
* 전송하면 `deployments/8453.json`이 `pending` 상태로 기록됩니다. 실제 체인 값으로 확정하는 명령은 아래와 같으며, 선점 구간을 줄이려면 Step 5 전송을 마친 뒤에 실행해도 됩니다.
  ```
  forge script script/Deploy.s.sol:Deploy --sig "confirm()" --rpc-url base
  ```
* BaseScan `Holders` 탭의 기대값은 베스팅 20% / 배포 지갑 70% / 트레저리 5% / 에어드롭 지갑 5%입니다.
* 이 시점에는 소스 검증과 홍보를 하지 않습니다. 곧바로 Step 5로 넘어갑니다.

### Step 5: 유동성 풀 생성 (Step 4 직후 곧바로)
```
forge script script/CreatePool.s.sol:CreatePool --sig "permitTypedData()" --rpc-url base --sender <배포 지갑>
export PERMIT_DEADLINE=<출력된 값>
export PERMIT_SIGNATURE=$(cast wallet sign --ledger --data --from-file deployments/permit-8453.json)
CONFIRM_MAINNET=I_UNDERSTAND forge script script/CreatePool.s.sol:CreatePool --rpc-url base --ledger --sender <배포 지갑>
CONFIRM_MAINNET=I_UNDERSTAND forge script script/CreatePool.s.sol:CreatePool --rpc-url base --ledger --sender <배포 지갑> --broadcast --slow
```
* 기본값은 3 ETH + 7억 FIRE, 수수료 등급 1%, 허용 오차 0.5%입니다. 시뮬레이션 출력의 초기 가격이 2.3절 값과 같은지 확인합니다. permit 마감까지 5분 이상 남아 있어야 합니다.
* 전송 후 `rm deployments/permit-8453.json`과 `unset PERMIT_SIGNATURE PERMIT_DEADLINE`으로 정리합니다. permit 없이 실행하면 별도 approve 트랜잭션이 나가며 경고가 출력됩니다.
* 이미 다른 가격으로 풀이 있으면(`CreatePoolPoolHasLiquidity`, `CreatePoolExistingPoolPriceMismatch`) `FEE_TIER=3000`으로 한 번 다시 시도합니다. 두 등급이 모두 막힌 경우는 5장 "남은 위험"을 따릅니다.
* 실제 LP 포지션 NFT 번호를 확정합니다. 시뮬레이션에 찍힌 번호는 쓰지 않습니다.
  ```
  forge script script/CreatePool.s.sol:CreatePool --sig "confirm()" --rpc-url base
  ```

### Step 6: LP 락업과 확인
1. UNCX 공식 사이트에서 confirm이 출력한 NFT를 **365일** 락업합니다. 수수료 수취 주소는 개발자 지갑으로 지정하고, 락커 주소가 `0x231278eDd38B00B07fBd52120CEf685B9BaEBCC1`(UNCX V3.1, Base)인지 UNCX 공식 문서와 대조합니다.
2. 락업 직후 락업 상태를 확인·기록합니다. 서명이나 전송은 없습니다. 이 단계를 건너뛰면 다음 점검에서 "유동성 감소"로 실패합니다.
   ```
   LP_LOCKER=0x231278eDd38B00B07fBd52120CEf685B9BaEBCC1 forge script script/CreatePool.s.sol:CreatePool --sig "confirmLock()" --rpc-url base
   ```
   NFT가 지정한 락커에 있고, 락커가 떼어 간 유동성이 1% 이하인지 확인합니다.
3. 기록 파일의 `lpLock` 항목에 락업 트랜잭션 해시(`lockTx`), 해제 날짜(`unlockDate`), 락 페이지 주소(`url`)를 직접 추가합니다. Team Finance를 쓰면 `LP_LOCKER`에 그 락커 주소를 넣습니다.

### Step 7: 소스 검증과 공개 점검 보고서
1. 락업이 끝난 뒤에 BaseScan 소스 검증을 합니다. Step 4 실행 로그에 실제 인자가 채워진 명령이 출력되며, 형식은 아래와 같습니다.
   ```
   forge verify-contract <FireVesting 주소> src/FireVesting.sol:FireVesting --chain 8453 --verifier etherscan --watch --constructor-args $(cast abi-encode "constructor(address,uint64,uint64)" <BENEFICIARY> 15552000 46656000)
   forge verify-contract <FireToken 주소> src/FireToken.sol:FireToken --chain 8453 --verifier etherscan --watch --constructor-args $(cast abi-encode "constructor(address)" <FireVesting 주소>)
   ```
2. 읽기 전용 점검을 실행해 `=== RESULT: PASS ===`를 확인합니다.
   ```
   forge script script/PostDeployCheck.s.sol:PostDeployCheck --rpc-url base
   ```
   배포된 코드가 이 저장소의 컴파일 결과와 같은지, 공급량·베스팅 일정·소유자, 트레저리 Safe 조건, 런칭 포지션 크기와 락업 상태 등을 검사합니다.
3. 기록의 `status`와 `pool.status`가 모두 `confirmed`이고 `lpLock` 기록이 끝났으면, 점검 보고서·주소·트랜잭션·락 페이지를 공개하고 `deployments/8453.json`과 `broadcast/` 로그를 커밋합니다. `deployments/84532.json`(Sepolia 기록)은 메인넷 런칭 이후에 커밋합니다.

### Step 8: 1차 에어드롭 (2,000만 FIRE)
1. 목록을 만들고 검증합니다. FIRE 토큰·베스팅·트레저리 같은 알려진 컨트랙트는 `--deny`로 막고, 0 주소 대역과 Base 시스템 컨트랙트 대역은 도구가 항상 거부합니다.
   ```
   cd airdrop
   node generate.mjs --input round1.csv --out out/round-1 --expected-total 20000000 --round 1 --deny <FireToken>,<FireVesting>,<트레저리 Safe>
   node verify.mjs --dir out/round-1 --expected-total 20000000 --round 1 --deny <같은 목록>
   cd ..
   ```
2. `airdrop/out/round-1`의 세 파일(`recipients.csv`, `tree.json`, `merkle.json`)과 Merkle Root를 GitHub에 먼저 커밋·공개하고 이의 제기 기간을 둡니다. Sepolia에서 배포·청구·회수를 리허설합니다.
3. 에어드롭 지갑을 전송 지갑으로 배포합니다.
   ```
   export AIRDROP_MERKLE_JSON=airdrop/out/round-1/merkle.json AIRDROP_WALLET=<에어드롭 지갑> AIRDROP_EXPECTED_ROOT=<공개한 root>
   CONFIRM_MAINNET=I_UNDERSTAND forge script script/DeployAirdrop.s.sol:DeployAirdrop --rpc-url base --ledger --sender $AIRDROP_WALLET
   CONFIRM_MAINNET=I_UNDERSTAND forge script script/DeployAirdrop.s.sol:DeployAirdrop --rpc-url base --ledger --sender $AIRDROP_WALLET --broadcast --slow --verify
   ```
4. 마감 시각을 UTC와 KST로 바꿔 공지합니다.
   ```
   DL=$(cast call <분배 컨트랙트> "CLAIM_DEADLINE()(uint64)" --rpc-url base | cut -d' ' -f1)
   date -u -d @$DL; TZ=Asia/Seoul date -d @$DL
   ```
5. 마감이 지나면 누구나 `sweep()`을 호출해 미청구분을 에어드롭 지갑으로 돌려보낼 수 있습니다. 회수량을 공개하고 2차로 이월합니다.

### Step 9: Fire Batch Sender 배포 (2027 Q1)
```
CONFIRM_MAINNET=I_UNDERSTAND forge script script/DeployBatchSender.s.sol:DeployBatchSender --rpc-url base --ledger --sender <배포자>
CONFIRM_MAINNET=I_UNDERSTAND forge script script/DeployBatchSender.s.sol:DeployBatchSender --rpc-url base --ledger --sender <배포자> --broadcast --slow --verify
```
* 소유자는 런칭 기록의 트레저리 Safe이며 2-of-3 이상·모듈 없음이어야 합니다. 메인넷에서는 Step 4의 런칭 기록이 반드시 있어야 합니다.
* 무료 한도(기본 25명)와 소각 수수료(기본 10,000 FIRE)는 `BATCH_FREE_RECIPIENTS`, `BATCH_BURN_FEE_FIRE`로 바꿀 수 있습니다.
* 배포 전에 외부 감사를 받는 것을 권장합니다(3.5절).

### 사고 대응
| 상황 | 조치 |
| :--- | :--- |
| 전송 도중 중단 | 같은 명령에 `--resume`. 기록 파일은 지우지 않음 |
| Deploy confirm 실패 | 채굴 여부와 nonce 확인. 기록이 다른 토큰을 가리키면 중단하고 조사 |
| 풀 선점으로 중단 | 다른 수수료 등급으로 1회 재시도. 두 등급 모두 막히면 5장 "남은 위험" |
| 락업 후 점검이 "유동성 감소"로 실패 | Step 6의 `confirmLock()` 실행 |
| 베스팅 수령 지갑 교체 후 | `BENEFICIARY=<새 owner>`로 PostDeployCheck 재실행, 교체 트랜잭션 해시 공지 |
| 트레저리 Safe에 모듈 경고 | 모듈 해제 |
| 다른 PC에서 이어서 실행 | `deployments/8453.json`을 함께 복사 |

---

## 5. DEX 유동성 공급 및 온체인 신뢰 구축

```
[토큰 배포 완료 (4장 Step 4)]
   └── CreatePool 스크립트: 한 트랜잭션 안에서
         permit 승인 → 풀 생성·가격 초기화 → 7억 FIRE + 3 ETH 전체 범위 예치 → 남은 ETH 환불
                                             │
                                             ▼
                         confirm 단계에서 실제 LP 포지션 NFT 번호 확정
                                             │
                                             ▼
                      UNCX / Team Finance 에 365일 락업 (수수료 수취 = 개발자 지갑)
                                             │
                                             ▼
                          DexScreener / DEXTools 노출, GoPlus 스캔 확인
```

1. **풀 설계 (스크립트 기본값):**
   * 페어는 `FIRE` / `WETH`입니다. ETH 페어가 Base 신규 토큰의 표준이며 어그리게이터 노출에 유리합니다.
   * 수수료 등급 기본값은 **1%**이고 `FEE_TIER=3000`으로 0.3%를 쓸 수 있습니다. 1%는 LP 수익이 크고 봇 차익거래 압력이 낮으며, 0.3%는 거래량 유입에 유리합니다.
   * 가격 범위는 항상 **Full Range(전체 범위)**입니다. 범위를 좁히면 가격이 범위를 벗어나는 순간 한쪽 자산만 남아 거래가 멈추고, 락업 상태에서는 고칠 수 없습니다.
   * 초기 가격은 예치량 비율로 정해지며 스크립트가 출력하는 값이 2.3절과 같은지 확인합니다.
2. **원자적 생성 (스크립트가 보장하는 것):**
   * 승인·풀 생성·가격 초기화·유동성 예치·ETH 환불이 **한 트랜잭션**입니다. 사전 approve 트랜잭션이 없어 "곧 풀이 생긴다"는 신호가 노출되지 않고, 실패하면 승인까지 함께 되돌려집니다.
   * 시뮬레이션 시점에 누군가 이미 다른 가격으로 풀을 만들어 두었다면 아무것도 보내지 않고 중단합니다. 이때는 `FEE_TIER=3000`으로 다시 실행하고 실제 풀 주소를 공지합니다.
   * 시뮬레이션 뒤 실제 전송 사이에 누가 끼어들면 남는 방어선은 허용 오차(기본 ±0.5%)입니다. 범위 안이면 그 가격으로 예치되고, 벗어나면 트랜잭션 전체가 취소되어 자금 손실은 없습니다.
   * 두 수수료 등급이 모두 선점되는 경우는 아래 "남은 위험"을 따릅니다.
   * **대안:** Uniswap V2(Base)는 LP가 ERC-20 토큰이라 락커·탐지 도구 호환성이 가장 높고 범위 설정이 없어 단순합니다. Base 최대 DEX인 Aerodrome도 선택지입니다. 다만 이 레포지토리의 스크립트와 테스트는 Uniswap V3만 다룹니다.
3. **LP 포지션 락업 (Rug-pull 방지 증명):**
   * LP 포지션 NFT 번호는 Base 전체가 공유하는 카운터라 시뮬레이션에 찍힌 번호와 거의 항상 다릅니다. 반드시 **confirm 단계가 출력한 번호**로 락업합니다.
   * **UNCX Network** 또는 **Team Finance** → Uniswap V3 Locker → Base → 해당 NFT 선택 → 락업 기간 **365일** → 수수료 수취(Collector) 주소를 본인 지갑으로 지정합니다. 접속 도메인은 공식 주소인지 직접 확인합니다.
   * 두 서비스 모두 락업 중에도 **거래 수수료 수취는 가능**하며 유동성 인출만 차단됩니다 (UNCX V3 락커는 OpenZeppelin 감사를 받았습니다).
   * **UNCX 수수료 (V3.1 Base 락커, 2026-10 온체인 값):** 기본 옵션은 고정 0.1 ETH, 락업할 때 LP의 0.5%, 이후 수취하는 거래 수수료의 2%입니다. 다른 옵션은 LP 0.8%·수취분 1%, 또는 LP 0.3%·수취분 3.5%입니다(고정 0.1 ETH 동일). 기본 옵션이면 약 350만 FIRE와 0.015 ETH가 UNCX로 가고, 락업 시점까지 쌓인 거래 수수료는 배포 지갑으로 수령됩니다. 런칭 당일 UNCX 공식 문서에서 요율과 락커 주소를 다시 확인합니다.
   * 락업 직후 `confirmLock()`으로 락업 상태를 기록합니다(4장 Step 6). 락커가 떼어 간 유동성이 1%를 넘으면 스크립트가 중단합니다.
   * 락업 트랜잭션 해시·락 페이지 URL·락커 주소를 배포 기록(`deployments/8453.json`)과 공식 채널에 공개하고, `PostDeployCheck`로 락업 상태를 점검합니다.
4. **어그리게이터 프로필 등록:**
   * DexScreener 및 DEXTools에서 토큰 주소 검색 → 유료 프로필 업데이트 기능으로 로고, 공식 웹사이트, 공식 X(트위터) 계정, GitHub 링크 등록.
   * 두 서비스가 표시하는 GoPlus 보안 스캔 결과(Honeypot 아님, 민팅 불가, 소유자 없음, 유동성 락업)를 확인하고 스크린샷을 보관합니다.
5. **공개 자료 세트 (6장 진입 전 완비):**
   * 공식 웹사이트 (토큰 주소, 베스팅·LP 락업 트랜잭션 링크, 지갑 주소 공개, `PostDeployCheck` 결과)
   * Litepaper (유틸리티, 토크노믹스, 로드맵, 리스크 고지, 외부 감사 여부)
   * GitHub 레포지토리 (MIT 라이선스, 검증된 소스와 동일한 코드, `deployments/8453.json` 배포 기록, 에어드롭 목록)
   * 공식 X 계정 및 커뮤니티 채널
6. **남은 위험: 풀 선점 (결정 필요)**
   * 토큰 배포의 첫 트랜잭션이 블록에 들어간 뒤 풀 생성 트랜잭션이 들어가기 전까지, 누군가 적은 비용으로 1%·0.3% 두 등급의 풀을 모두 엉뚱한 가격으로 만들어 막을 수 있습니다. Ledger 서명과 `--slow` 전송 때문에 이 구간은 수 분입니다.
   * 스크립트가 중단하므로 **자금 손실은 없고**, 런칭이 지연되는 서비스 거부 위험입니다.
   * 선택지:
     1. **가격 복구 + 예치를 한 트랜잭션에서 하는 전용 컨트랙트**를 만들어 쓴다. 구간이 사라지지만 감사·검증할 컨트랙트가 하나 늘어납니다.
     2. **구간을 줄인다.** permit을 미리 서명해 두고 4장 Step 4와 Step 5를 연달아 실행합니다(현재 절차). Ledger 사용 시 최소 한 블록 이상은 남습니다.
     3. **현재 절차를 유지하되, 1번 컨트랙트를 메인넷 전에 만들어 포크 테스트까지 끝내 두고 두 등급이 모두 막혔을 때만 쓴다.**
   * 권장안은 3번입니다. 이 컨트랙트는 아직 구현되어 있지 않습니다.

---

## 6. 중앙화 거래소(CEX) 상장 파이프라인

중앙화 거래소는 단계별(Tier-by-Tier)로 접근하여 상장 비용을 절감하고 실거래량을 증명해야 합니다.

> **현실적 전제:** 대부분의 CEX 상장 신청은 법인 서류(KYB)와 법인 명의 계약을 요구합니다. 무법인 상태에서 가능한 경로는 (a) 온체인 지표를 보고 거래소가 **먼저 제안하는 무신청·커뮤니티 상장**(일부 Tier 3 거래소), (b) 프로젝트가 성장한 뒤 **법인을 설립하고** 정식 신청하는 것입니다. 2단계 진입 시점을 법인 설립 검토 시점으로 설정하십시오.

```
[1단계] 탈중앙화 거래소 (Uniswap)
   - 목표: 지갑 홀더 1,000명 이상, 일 거래량 $50,000 이상 (자연 거래량만 인정)
   - 활동: 1차 에어드롭 2% 집행 (2차 3%는 2027년 도구 실사용자 대상), DexScreener 트렌딩 진입
   - 금지: 본인 지갑 간 워시트레이딩 (가상자산이용자보호법상 시세조종 해당 가능)
        │
        ▼
[2단계] Tier 3 / Tier 2 CEX (MEXC, Bitget, LBank, Gate.io)
   - 진입 요건: 활성 온체인 거래량 증명 시 거래소 BD팀의 무료/저비용 상장 제안
   - 준비 서류: Litepaper, GitHub 오픈소스 링크, 감사 리포트, 검증된 컨트랙트 링크
   - 법인: 정식 신청 시 KYB 필요 → 이 시점에 법인 설립(국내 또는 해외) 검토
        │
        ▼
[3단계] Tier 1 CEX (Bybit, OKX, Binance)
   - 진입 요건: 법률 의견서(Legal Opinion: 비증권성 확인), 전문 MM(Market Maker) 계약, 법인 필수
   - 비용: 수억 원 단위 유동성 지원 및 마케팅 바운티 풀 → 트레저리 5%(2.2절) + 7.1절 수익원으로 사전 적립
        │
        ▼
[4단계] 국내 원화 거래소 (업비트, 빗썸, 코인원)
   - 진입 요건: DAXA 거래지원 모범사례 준수 (발행주체·대표자 명확성, 유통량 계획서, 공시 체계)
   - 현실: 무법인 1인 프로젝트는 심사 통과가 사실상 불가. 법인 설립 + 해외 CEX 상장 실적 선행 필요
```

---

## 7. 개발자 자산 회수 및 법적/세무 소명 전략

프로젝트 가치가 성장했을 때 개발자가 확보한 지분을 합법적으로 현금화하는 절차입니다.

### 7.1 자산화 메커니즘
1. **LP 거래 수수료 수익:** Uniswap 풀에서 거래가 발생할 때마다 풀 생성 시 선택한 수수료 등급(0.3% 또는 1%)만큼 LP에게 적립됩니다. V3에서는 수수료가 **ETH와 FIRE 양쪽**으로 쌓이며, 락업 중에도 락커의 Collect 기능으로 인출할 수 있습니다. UNCX 기본 옵션은 수취분의 2%를 수수료로 뗍니다. 이 수익은 FIRE 가격 변동과 무관하게 거래량에 비례합니다.
2. **베스팅 물량 분할 매도:** 배포 6개월 이후부터 선형 해제되는 FIRE를 `release(token)` 호출로 수령한 뒤, 시장 충격을 주지 않는 선(일일 거래량의 1~3% 이내)에서 분할 매도합니다.
3. **현금화 경로:** FIRE가 국내 거래소에 상장되기 전까지는 **Uniswap에서 FIRE → ETH로 교환 → ETH를 국내 거래소로 입금 → 원화 환전**이 유일한 경로입니다. 따라서 국내 거래소 입금 자산은 FIRE가 아닌 ETH(또는 USDC)입니다.

### 7.2 불공정거래 예방 (가상자산이용자보호법 대응)
* **매도 정책 사전 공개:** 예를 들어 "매월 1일 해제분의 최대 50%를 그 달에 걸쳐 분할 매도"와 같은 규칙을 웹사이트에 게시하고 준수합니다.
* **중요 정보 공개 전후 매도 금지:** 상장, 파트너십, 로드맵 변경 등 가격에 영향을 줄 정보를 공개하기 전후 일정 기간(예: 전 7일, 후 2일) 매도를 중단합니다.
* **지갑 공개:** 개발자 수령 지갑, 에어드롭 지갑, Safe 트레저리 지갑, 배포자 지갑 주소를 공개하여 모든 매도가 추적 가능하게 합니다.

### 7.3 세금 (2026년 10월 기준)
* **가상자산 소득 과세:** 현행 소득세법상 **2027년 1월 1일 이후 양도·대여분**부터 기타소득으로 분리과세됩니다 (세율 22%, 지방소득세 포함 · 연 250만 원 기본공제 · 첫 신고는 2028년 5월). 추가 유예·폐지 법안이 발의되어 있으므로 매년 말 국회 결과를 확인하십시오.
* **취득가액 문제:** 본인이 발행한 토큰은 취득가액이 0원으로 평가될 가능성이 높아, 매도 금액 거의 전부가 과세소득이 될 수 있습니다.
* **LP 수수료 소득 분류:** 기타소득인지 사업소득인지 명확한 유권해석이 없습니다. 반복적·계속적 수취는 사업소득으로 볼 여지가 있으므로 세무사와 사전 협의합니다.
* **2026년 매도분:** 현행법상 과세 대상이 아니나, 이를 이유로 매도를 앞당기는 것은 7.2절의 공개 매도 정책과 충돌할 수 있습니다.
* **기록 보관:** 모든 매도·수수료 수취 트랜잭션의 해시, 일시, 수량, 당시 ETH/원화 환율을 스프레드시트로 보관합니다 (취득가액·필요경비 소명용).

### 7.4 국내 거래소 입금 및 원화 환전 소명 준비
개인 지갑에서 대규모 자산이 국내 거래소로 유입되면 트래블룰 및 이상거래탐지시스템(FDS)에 의해 입금 보류·계좌 동결이 발생할 수 있습니다.

* **사전 준비:** 거래소별 개인지갑 등록(화이트리스트) 정책을 확인하고, 입금 전에 본인 지갑을 등록합니다. 첫 입금은 소액으로 테스트합니다.
* **온체인 배포 증명:** 베스팅·토큰 배포 트랜잭션 해시, 배포자 지갑 주소, BaseScan 검증 페이지.
* **코드 기여 증명:** GitHub 레포지토리 커밋 기록 및 MIT 라이선스.
* **수익 발생 온체인 기록:** `FireVesting`에서 `release`된 트랜잭션, 락커의 수수료 수취 트랜잭션, Uniswap에서 FIRE → ETH 교환 트랜잭션 목록.
* **공개 매도 정책 링크:** 7.2절의 매도 정책 게시 페이지와 실제 매도 이력의 일치 증빙.
* **소명 논리:** *"타인에게 투자금을 모집하여 얻은 수익이 아니며, 본인이 직접 작성·공개한 오픈소스 스마트 컨트랙트의 LP 거래 수수료 및 개발자 베스팅 토큰을 사전 공개된 정책에 따라 온체인에서 분할 처분한 수익임"*을 거래소 컴플라이언스 팀에 제출합니다.

---

## 8. 배포 전·후 점검 체크리스트

**배포 전**
- [ ] 1.3절 토큰 유틸리티 및 분기 로드맵 기반 Litepaper 초안 작성
- [ ] 디지털자산기본법 통과 여부 및 발행신고제 시행 여부 재확인
- [ ] 변호사·세무사 1회 이상 상담 (투자계약증권 해당성, 세금 분류)
- [ ] 5장 "남은 위험(풀 선점)" 대응 방식 결정
- [ ] 저장소 사전 점검 통과 (`forge test` 포크 포함, `npm test`)
- [ ] 새 배포 지갑(하드웨어 EOA) 준비, 시드 구문 오프라인 보관, 주소 비공개
- [ ] 시딩 3 ETH + 약 0.15 ETH 준비, 배포 당일 ETH 시세로 풀 유동성 $15,000 이상 확인
- [ ] 트레저리 Safe 생성 (2-of-3 이상, 모듈 없음) 및 에어드롭 전용 지갑 생성
- [ ] Base Sepolia에서 실제 Ledger로 4장 Step 3~8 리허설 완료
- [ ] 수익자·에어드롭 지갑 통제 증명 서명을 메인넷용으로 다시 받고 `verified` 확인
- [ ] Snapshot 스페이스용 ENS 이름 확보
- [ ] 7.2절 매도 정책 초안 작성 (클리프 종료 전 게시)
- [ ] 저장소 `SECURITY.md`의 보안 연락처 실제 주소로 교체

**배포 당일 (순서대로)**
- [ ] 토큰·베스팅 배포 (Step 4) → 곧바로 풀 생성 (Step 5) → 두 confirm 실행
- [ ] BaseScan Holders 확인: 베스팅 20% / 배포 지갑 70% / 트레저리 5% / 에어드롭 5% (풀 생성 뒤에는 풀이 약 70%)
- [ ] LP NFT 365일 락업 → `confirmLock()` → 기록에 lockTx·unlockDate·url 추가
- [ ] 락업 뒤에 두 컨트랙트 BaseScan 소스 검증
- [ ] `PostDeployCheck` 결과 `RESULT: PASS` 확인
- [ ] GoPlus / Token Sniffer 스캔 결과 확인
- [ ] 배포 기록(`deployments/8453.json`, `broadcast/`) 커밋, 웹사이트·README에 모든 주소와 트랜잭션 링크 게시

**런칭 직후**
- [ ] 1차 에어드롭 목록·Merkle Root를 GitHub에 먼저 공개하고 이의 제기 기간 운영
- [ ] 1차 분배 컨트랙트 배포·2,000만 예치 (Step 8), 마감 시각 UTC·KST 공지
- [ ] 베스팅 `start()`·`end()`를 UTC 날짜로 변환해 공개

**운영 중**
- [ ] 매도 정책 공개 및 준수, 매도·수수료 수취 기록 보관
- [ ] 월 1회 입법·세제 변경 사항 확인
- [ ] 1차 마감 후 `sweep()` 회수량 공개 및 2차 이월
- [ ] 2단계 진입 시 법인 설립 검토
- [ ] Batch Sender 배포 전 외부 감사 (2027 Q1)

---

## 9. 참고 자료
**구현 레포지토리 (`fire-contracts/`)**
* `README.md`: 구조, 테스트·커버리지 실행 방법, 보안 메모
* `SECURITY.md`: 컨트랙트별 신뢰 모델, 테스트가 증명하는 것, 남은 위험
* `deployments/README.md`: 배포 기록 파일 형식과 배포·점검 명령 상세
* `airdrop/README.md`: 에어드롭 목록 생성·검증 도구 사용법과 공개 절차
* `.env.example`: 스크립트가 읽는 모든 환경변수와 기본값

**외부 자료**
* OpenZeppelin Contracts v5 Finance (VestingWallet): https://docs.openzeppelin.com/contracts/api/finance
* OpenZeppelin Contracts 릴리스: https://github.com/OpenZeppelin/openzeppelin-contracts/releases
* Base 공식 문서 (네트워크 정보, Faucet): https://docs.base.org
* Uniswap V3 수수료 수취 가이드: https://support.uniswap.org/hc/en-us/articles/20901267003789
* UNCX Uniswap V3 Locker 감사 보고서 (OpenZeppelin): https://www.openzeppelin.com/news/uncx-uniswapv3-liquidity-locker-audit
* 디지털자산기본법 입법 동향 (2026.9): https://www.fntimes.com/html/view.php?ud=2026092216524828280f4390e77d_18
* 가상자산 과세 일정 (2027년 시행): https://www.taxtimes.co.kr/news/article.html?no=275357
* 법률신문 「2026년 가상자산산업 10대 핵심 이슈」: https://www.lawtimes.co.kr/news/articleView.html?idxno=215219
