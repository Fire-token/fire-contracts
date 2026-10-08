// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {console} from "forge-std/console.sol";
import {FireToken} from "../src/FireToken.sol";
import {FireVesting} from "../src/FireVesting.sol";
import {ControlProof} from "./lib/ControlProof.sol";
import {LaunchBase} from "./lib/LaunchBase.sol";
import {LaunchGuards} from "./lib/LaunchGuards.sol";
import {LaunchParams} from "./lib/LaunchParams.sol";
import {UniswapV3Addresses} from "./lib/UniswapV3Addresses.sol";
import {IUniswapV3Factory} from "./lib/IUniswapV3.sol";

/**
 * @title Deploy — FIRE 런칭 배포 (가이드 4장 Step 3·4)
 * @notice 환경 변수: BENEFICIARY, TREASURY_SAFE, AIRDROP_WALLET (필수), CONFIRM_MAINNET (메인넷 전용),
 *         BENEFICIARY_PROOF_SIG, AIRDROP_WALLET_PROOF_SIG (소유 증명 서명, 메인넷에서 EOA면 필수).
 *         메인넷에서는 세 주소 모두 EIP-55 체크섬 표기(대소문자 혼합)여야 함.
 *         소유 증명: FireVesting의 최초 수익자는 수락 절차 없이 곧바로 owner가 되므로(에어드롭 물량도 단순 전송),
 *         오타나 통제하지 않는 주소를 넣으면 2억 / 5,000만 FIRE가 영구히 묶임. 그래서 배포 전에 증명을 확인함:
 *           - 코드 없음(EOA) 또는 EIP-7702 위임 EOA → 그 키로 서명한 ControlProof 메시지 필요
 *             (메시지·명령 출력: forge script script/Deploy.s.sol:Deploy --sig "printProofMessages()" --rpc-url <별칭>)
 *           - 그 밖의 컨트랙트 → 이 체인에 배포된 Safe여야 하고, 같은 메시지(address = Safe)에 Safe 소유자들이 각자 서명한
 *             값을 이어 붙여 제출 (서로 다른 소유자 서명 ≥ 임계값). 메인넷은 모듈이 활성화된 Safe도 거부.
 *           - 체인별: Base 메인넷 필수 · Base Sepolia 제출 시 검증(미제출이면 경고) · 로컬 anvil 생략
 *         메인넷 TREASURY_SAFE는 임계값 2 이상·소유자 3명 이상이고 모듈이 없는 Safe여야 함 (EIP-7702 위임 EOA 거부).
 *         메인넷 배포 지갑(브로드캐스터)은 코드가 없는 일반 EOA여야 함 (EIP-7702 위임 EOA 거부, 테스트넷은 경고).
 * @dev 하나의 브로드캐스트 안에서 순서대로 실행:
 *        1) FireVesting(BENEFICIARY, 180일, 540일) 배포
 *        2) FireToken(vesting) 배포 → 2억은 베스팅 컨트랙트로, 8억은 배포자에게 발행
 *        3) 5,000만 FIRE → TREASURY_SAFE,  4) 5,000만 FIRE → AIRDROP_WALLET
 *        5) 사후 조건: 배포자 7억 / 베스팅 2억 / 트레저리 5,000만 / 에어드롭 5,000만,
 *           vesting.owner() == BENEFICIARY, duration == 540일, start == 배포 블록 시각 + 180일
 *      가드·사후 조건은 forge의 시뮬레이션 단계에서 평가되며, 하나라도 실패하면 스크립트 전체가 revert되어
 *      어떤 트랜잭션도 전송되지 않음.
 *      기록: --broadcast 실행은 전송 전에 deployments/<chainId>.json 을 status "pending"으로 씀(주소는 CREATE로
 *      결정되어 확정적이지만 블록·시각은 시뮬레이션 값). 트랜잭션이 채굴된 뒤 confirm()이 온체인 상태를 확인하고
 *      실제 vesting.start/end를 써서 "confirmed"로 바꿈.
 */
contract Deploy is LaunchBase {
    uint64 public constant CLIFF = LaunchParams.CLIFF;
    uint64 public constant LINEAR = LaunchParams.LINEAR;
    uint256 public constant TREASURY_AMOUNT = LaunchParams.TREASURY_AMOUNT;
    uint256 public constant AIRDROP_AMOUNT = LaunchParams.AIRDROP_AMOUNT;
    uint256 public constant LP_AMOUNT = LaunchParams.LP_AMOUNT;
    /// @dev 런칭 브로드캐스트의 트랜잭션 수 (베스팅 배포, 토큰 배포, 트레저리 전송, 에어드롭 전송).
    uint256 public constant LAUNCH_TX_COUNT = 4;
    /// @dev 소유 증명 서명(0x로 시작하는 65바이트, personal_sign)을 담는 환경 변수.
    string public constant BENEFICIARY_PROOF_ENV = "BENEFICIARY_PROOF_SIG";
    string public constant AIRDROP_WALLET_PROOF_ENV = "AIRDROP_WALLET_PROOF_SIG";
    /// @dev 소유 증명 환경 변수 형식 오류 메시지 (EOA는 서명 1개, Safe는 소유자 서명 여러 개를 이어 붙임).
    string public constant PROOF_FORMAT = "expected 0x followed by 130 hex characters per 65-byte signature (max 16)";

    struct DeployConfig {
        address beneficiary;
        address treasurySafe;
        address airdropWallet;
        bool mainnetConfirmed;
        bytes beneficiaryProof; // BENEFICIARY_PROOF_SIG (비어 있으면 미제출)
        bytes airdropWalletProof; // AIRDROP_WALLET_PROOF_SIG (비어 있으면 미제출)
    }

    struct DeployResult {
        address vesting;
        address token;
        address deployer;
        address beneficiary;
        address treasurySafe;
        address airdropWallet;
        uint256 chainId;
        uint256 blockNumber;
        uint256 blockTimestamp;
        uint256 vestingStart;
        uint256 vestingEnd;
        uint256 deployerNonce; // 첫 트랜잭션(FireVesting 배포)의 nonce
    }

    error DeployZeroAddress(string role);
    error DeployDuplicateAddress(string roleA, string roleB);
    error DeployRecipientIsBroadcaster(string role);
    error DeployRecipientIsNewContract(string role);
    error DeployTreasuryNotContract(address treasurySafe);
    error DeployTreasuryNotSafe(address treasurySafe);
    error DeployTreasuryIsDelegatedEOA(address treasurySafe);
    error DeployTreasurySafeTooWeak(address treasurySafe, uint256 threshold, uint256 ownerCount);
    error DeployTreasurySafeHasModules(address treasurySafe);
    error DeployBroadcasterHasCode(address deployer);
    error DeployProofMissing(string envName, string message);
    error DeployProofInvalid(string envName, string reason);
    error DeployProofWrongSigner(string envName, address expected, address recovered);
    error DeployProofAccountNotSafe(string role, address account);
    error DeployProofSafeHasModules(string role, address account);
    error DeployProofNotEnoughOwners(string envName, uint256 signers, uint256 threshold);
    error DeployAlreadyDeployed(address token);
    error DeployPoolPreempted(address predictedToken, uint24 fee, address pool);
    error DeployPostConditionFailed(string check);
    error DeployRecordMissing(string path);
    error DeployConfirmFailed(string check);

    // ───────────────────────── 진입점 ─────────────────────────

    function run() external returns (DeployResult memory result) {
        _requireSupportedChain(true);
        DeployConfig memory cfg = loadConfig();
        string memory path = deploymentPath(block.chainid);
        requireNotDeployed(path);
        result = deploy(cfg, address(0));
        string memory json = recordJson(result);
        if (_isBroadcastRun()) {
            vm.writeJson(json, path);
            console.log("Deployment record written (status: pending):", path);
            console.log("  Addresses are final; block/time values are from the simulation until step 1 below.");
        } else {
            console.log("Dry run: deployment record NOT written (would be %s):", path);
            console.log(json);
        }
        _logNextSteps(result);
    }

    /**
     * @notice 트랜잭션 4건이 채굴된 뒤 실행(서명·전송 없음): 기록의 주소를 온체인에서 확인하고 실제 일정으로 갱신.
     *         forge script script/Deploy.s.sol:Deploy --sig "confirm()" --rpc-url <base | base_sepolia>
     */
    function confirm() external returns (DeployResult memory r) {
        _requireSupportedChain(true);
        r = confirmRecord(deploymentPath(block.chainid));
    }

    /**
     * @notice 수익자·에어드롭 지갑의 소유 증명 메시지와 서명 명령을 출력 (서명·전송·파일 쓰기 없음).
     *         forge script script/Deploy.s.sol:Deploy --sig "printProofMessages()" --rpc-url <base | base_sepolia>
     *         메시지의 chainId는 RPC 체인 기준이므로 실제로 배포할 네트워크의 --rpc-url로 실행할 것.
     *         BENEFICIARY_PROOF_SIG / AIRDROP_WALLET_PROOF_SIG가 이미 설정돼 있으면 검증 결과도 출력함.
     */
    function printProofMessages() external returns (string memory beneficiaryMessage, string memory airdropMessage) {
        _requireSupportedChain(true);
        bool strict = _isMainnet();
        address beneficiary = _envAddressRequired("BENEFICIARY", strict);
        address airdropWallet = _envAddressRequired("AIRDROP_WALLET", strict);
        console.log(
            "=== FIRE launch: proof of control (%s, chainId %s) ===", _networkName(block.chainid), block.chainid
        );
        console.log("BENEFICIARY becomes the vesting owner at once (200,000,000 FIRE); AIRDROP_WALLET gets 50,000,000.");
        console.log("Sign each message with the key of that address (personal_sign, EIP-191). The Ledger screen");
        console.log("shows the text: check role, address and chainId before approving.");
        beneficiaryMessage = _printProof(ControlProof.ROLE_BENEFICIARY, BENEFICIARY_PROOF_ENV, beneficiary);
        airdropMessage = _printProof(ControlProof.ROLE_AIRDROP_WALLET, AIRDROP_WALLET_PROOF_ENV, airdropWallet);
        console.log("");
        console.log("Ledger account other than the first: add --mnemonic-derivation-path \"m/44'/60'/<n>'/0/0\"");
        console.log("  to cast (check it first: cast wallet address --ledger --mnemonic-derivation-path \"...\");");
        console.log("  forge script takes the plural --mnemonic-derivation-paths \"...\" (or --mnemonic-indexes <n>).");
        if (block.chainid == LaunchParams.LOCAL_ANVIL) {
            console.log("NOTE: local anvil skips the proof; run with --rpc-url base_sepolia or base for real messages.");
        }
    }

    function loadConfig() public view returns (DeployConfig memory cfg) {
        bool strict = _isMainnet(); // 메인넷: 오타 한 글자가 2억 FIRE 영구 동결로 이어지므로 체크섬 필수
        cfg.beneficiary = _envAddressRequired("BENEFICIARY", strict);
        cfg.treasurySafe = _envAddressRequired("TREASURY_SAFE", strict);
        cfg.airdropWallet = _envAddressRequired("AIRDROP_WALLET", strict);
        cfg.mainnetConfirmed = _envMainnetConfirmed();
        cfg.beneficiaryProof = _envProof(BENEFICIARY_PROOF_ENV);
        cfg.airdropWalletProof = _envProof(AIRDROP_WALLET_PROOF_ENV);
    }

    /// @dev 소유 증명 환경 변수 → 65바이트 서명 1개(EOA) 또는 Safe 소유자 서명 여러 개를 이어 붙인 바이트
    ///      (비어 있으면 미제출). 형식이 틀리면 모든 체인에서 중단.
    function _envProof(string memory envName) private view returns (bytes memory signatures) {
        string memory raw = _envString(envName);
        if (bytes(raw).length == 0) return "";
        bool ok;
        (ok, signatures) = ControlProof.parseSignatures(raw);
        if (!ok) revert DeployProofInvalid(envName, PROOF_FORMAT);
    }

    /// @notice 메인넷에 이미 기록된 FireToken이 존재하면 중복 배포를 막음(테스트넷·로컬은 경고 후 덮어씀).
    ///         기록 파일이 없어도 deploy()의 requireNoPriorDeployment가 체인을 직접 확인함.
    function requireNotDeployed(string memory path) public view {
        (bool exists, string memory json) = _readJsonIfExists(path);
        if (!exists) return;
        address existing = _jsonAddressOr(json, ".contracts.FireToken", address(0));
        if (existing == address(0) || existing.code.length == 0) return;
        if (_isMainnet()) revert DeployAlreadyDeployed(existing);
        console.log("WARNING: %s already records a live FireToken at %s; it will be overwritten.", path, existing);
    }

    /**
     * @notice 배포 본체. 테스트는 sender에 주소를 넘기고, run()은 address(0)을 넘겨 CLI 서명자를 사용.
     */
    function deploy(DeployConfig memory cfg, address sender) public returns (DeployResult memory r) {
        _requireSupportedChain(true);
        _requireMainnetConfirmation(cfg.mainnetConfirmed);

        address deployer = _resolveBroadcaster(sender);
        _checkDeployerAccount(deployer);
        uint256 nonce = vm.getNonce(deployer);
        address predictedVesting = vm.computeCreateAddress(deployer, nonce);
        address predictedToken = vm.computeCreateAddress(deployer, nonce + 1);
        _logPlan(cfg, deployer, predictedVesting, predictedToken);
        validate(cfg, deployer, predictedVesting, predictedToken);
        requireNoPriorDeployment(deployer, nonce);
        requireNoPreemptedPool(predictedToken);

        vm.startBroadcast(deployer);
        FireVesting vesting = new FireVesting(cfg.beneficiary, CLIFF, LINEAR);
        FireToken token = new FireToken(address(vesting));
        _transfer(token, cfg.treasurySafe, TREASURY_AMOUNT);
        _transfer(token, cfg.airdropWallet, AIRDROP_AMOUNT);
        vm.stopBroadcast();

        r = DeployResult({
            vesting: address(vesting),
            token: address(token),
            deployer: deployer,
            beneficiary: cfg.beneficiary,
            treasurySafe: cfg.treasurySafe,
            airdropWallet: cfg.airdropWallet,
            chainId: block.chainid,
            blockNumber: block.number,
            blockTimestamp: block.timestamp,
            vestingStart: vesting.start(),
            vestingEnd: vesting.end(),
            deployerNonce: nonce
        });
        if (r.vesting != predictedVesting || r.token != predictedToken) {
            revert DeployPostConditionFailed("deployed address != predicted CREATE address");
        }
        checkPostConditions(r);
        _logResult(r);
    }

    // ───────────────────────── 가드 ─────────────────────────

    /// @notice 전송 전 입력 검증. 실패 시 아무 트랜잭션도 만들어지지 않음.
    function validate(DeployConfig memory cfg, address deployer, address predictedVesting, address predictedToken)
        public
        view
    {
        _requireNonZero(cfg.beneficiary, "BENEFICIARY");
        _requireNonZero(cfg.treasurySafe, "TREASURY_SAFE");
        _requireNonZero(cfg.airdropWallet, "AIRDROP_WALLET");

        if (cfg.beneficiary == cfg.treasurySafe) revert DeployDuplicateAddress("BENEFICIARY", "TREASURY_SAFE");
        if (cfg.beneficiary == cfg.airdropWallet) revert DeployDuplicateAddress("BENEFICIARY", "AIRDROP_WALLET");
        if (cfg.treasurySafe == cfg.airdropWallet) revert DeployDuplicateAddress("TREASURY_SAFE", "AIRDROP_WALLET");

        _requireNotSelf(cfg.beneficiary, "BENEFICIARY", deployer, predictedVesting, predictedToken);
        _requireNotSelf(cfg.treasurySafe, "TREASURY_SAFE", deployer, predictedVesting, predictedToken);
        _requireNotSelf(cfg.airdropWallet, "AIRDROP_WALLET", deployer, predictedVesting, predictedToken);

        _checkTreasury(cfg.treasurySafe);
        requireControlProofs(cfg);
    }

    /**
     * @notice BENEFICIARY·AIRDROP_WALLET 소유 증명 (FireVesting 수익자는 수락 절차 없이 즉시 owner가 됨).
     * @dev 주소 종류별:
     *        - 코드 없음(EOA) 또는 EIP-7702 위임 EOA(코드 = 0xef0100 ‖ 주소) → 그 키의 ControlProof 서명 필요.
     *          위임 대상이 Safe처럼 응답해도 원래 키 하나로 통제되므로 Safe로 보지 않음.
     *        - 그 밖의 컨트랙트 → 이 체인에 배포된 Safe(getThreshold() ≥ 1, getOwners() 비어 있지 않음)여야 하며 서명 불필요.
     *          다른 체인에만 있는 Safe 주소는 이 체인에서 코드가 없으므로 서명을 요구받게 되어(만들 수 없음) 걸러짐.
     *      체인별: 8453 필수(없거나 틀리면 중단, 서명할 메시지 출력) · 84532 제출 시 검증, 미제출이면 경고 · 31337 생략.
     */
    function requireControlProofs(DeployConfig memory cfg) public view {
        _requireControl(ControlProof.ROLE_BENEFICIARY, BENEFICIARY_PROOF_ENV, cfg.beneficiary, cfg.beneficiaryProof);
        _requireControl(
            ControlProof.ROLE_AIRDROP_WALLET, AIRDROP_WALLET_PROOF_ENV, cfg.airdropWallet, cfg.airdropWalletProof
        );
    }

    /**
     * @notice 이 배포자가 최근 CREATE로 이미 FireToken을 만들었으면 메인넷에서 중단(테스트넷은 경고).
     * @dev 로컬 기록 파일(requireNotDeployed)은 삭제·미커밋·다른 PC 실행 등으로 없을 수 있으므로 체인을 직접 확인:
     *      nonce-1부터 최대 MAX_PRIOR_NONCE_SCAN개의 CREATE 주소에 FireToken 고유 상수
     *      (TOTAL_SUPPLY 10억, VESTING_SUPPLY 2억)를 돌려주는 컨트랙트가 있는지 봄.
     *      중단된 브로드캐스트는 재실행이 아니라 같은 명령에 --resume을 붙여 마무리해야 함.
     */
    function requireNoPriorDeployment(address deployer, uint256 nonce) public view {
        uint256 stop = nonce > LaunchParams.MAX_PRIOR_NONCE_SCAN ? nonce - LaunchParams.MAX_PRIOR_NONCE_SCAN : 0;
        for (uint256 n = nonce; n > stop;) {
            --n;
            address candidate = vm.computeCreateAddress(deployer, n);
            if (!_isFireToken(candidate)) continue;
            if (_isMainnet()) {
                console.log("ABORT: deployer %s already created a FireToken at %s.", deployer, candidate);
                console.log("  To finish an interrupted launch, re-run the same command with --resume instead.");
                revert DeployAlreadyDeployed(candidate);
            }
            console.log("WARNING: this deployer already created a FireToken at %s; deploying another one.", candidate);
            return;
        }
    }

    /**
     * @notice 곧 배포할 FireToken 주소(배포자 nonce + 1)로 FIRE/WETH 풀이 이미 있으면 메인넷에서 중단(테스트넷은 경고).
     * @dev CREATE 주소는 배포자와 nonce로 미리 계산되고, Uniswap 팩토리는 코드가 없는 토큰 주소로도 풀 생성·초기화를
     *      허용함. 배포자 주소가 알려져 있으면(예: 같은 지갑으로 한 리허설의 공개 기록) 누군가 1%·0.3% 등급 모두에 엉뚱한
     *      가격과 WETH 단독 유동성을 미리 넣어 CreatePool을 막을 수 있음. 토큰을 배포하기 전에 감지하면 아무것도
     *      공개하지 않은 채 새 배포 지갑으로 바꿀 수 있음.
     *      한계: 이 검사는 forge의 시뮬레이션 시점에만 실행됨. 첫 트랜잭션(FireVesting 배포, nonce n)이 체인에 포함되면
     *      배포자와 nonce가 공개되어 토큰 주소 CREATE(배포자, n + 1)도 확정되므로, 그때부터 CreatePool이 포함될 때까지는
     *      같은 선점이 가능함(SECURITY.md 5.2, deployments/README.md "풀 선점 방지와 대응").
     */
    function requireNoPreemptedPool(address predictedToken) public view {
        if (!UniswapV3Addresses.isSupported(block.chainid)) return;
        UniswapV3Addresses.Deployment memory uni = UniswapV3Addresses.forChain(block.chainid);
        if (uni.factory.code.length == 0) {
            console.log("WARNING: Uniswap V3 factory %s has no code; pre-created pool check skipped.", uni.factory);
            return;
        }
        uint24[2] memory fees = [LaunchParams.FEE_TIER_1_PERCENT, LaunchParams.FEE_TIER_0_3_PERCENT];
        for (uint256 i; i < fees.length; ++i) {
            address pool = IUniswapV3Factory(uni.factory).getPool(predictedToken, uni.weth, fees[i]);
            if (pool == address(0)) continue;
            console.log("A FIRE/WETH pool for the not-yet-deployed token %s already exists:", predictedToken);
            console.log("  fee %s, pool %s", fees[i], pool);
            if (_isMainnet()) {
                console.log("ABORT: someone predicted the token address from this deployer's address and nonce.");
                console.log("  Nothing was sent. Use a fresh deployer wallet that never appeared in public records.");
                revert DeployPoolPreempted(predictedToken, fees[i], pool);
            }
            console.log("WARNING: continuing on a testnet.");
        }
    }

    function _isFireToken(address candidate) private view returns (bool) {
        (bool ok, uint256 total) = _staticUint(candidate, abi.encodeWithSignature("TOTAL_SUPPLY()"));
        if (!ok || total != LaunchParams.TOTAL_SUPPLY) return false;
        (bool ok2, uint256 vestingSupply) = _staticUint(candidate, abi.encodeWithSignature("VESTING_SUPPLY()"));
        return ok2 && vestingSupply == LaunchParams.VESTING_AMOUNT;
    }

    function _requireNonZero(address account, string memory role) private pure {
        if (account == address(0)) revert DeployZeroAddress(role);
    }

    function _requireNotSelf(
        address account,
        string memory role,
        address deployer,
        address predictedVesting,
        address predictedToken
    ) private pure {
        if (account == deployer) revert DeployRecipientIsBroadcaster(role);
        if (account == predictedVesting || account == predictedToken) revert DeployRecipientIsNewContract(role);
    }

    /**
     * @dev TREASURY_SAFE. 메인넷: 이 체인에 배포된 Safe이며 임계값 ≥ 2·소유자 ≥ 3 (가이드 2.2절 2-of-3, DeployBatchSender의
     *      소유자 규칙과 같음). EIP-7702 위임 EOA는 위임 대상이 Safe처럼 응답해도 키 하나로 통제되므로 거부.
     *      테스트넷·로컬: 같은 조건을 경고로만 알림(리허설 편의).
     */
    function _checkTreasury(address treasury) private view {
        bool mainnet = _isMainnet();
        if (LaunchGuards.isDelegatedEOA(treasury)) {
            if (mainnet) revert DeployTreasuryIsDelegatedEOA(treasury);
            console.log("WARNING: TREASURY_SAFE %s is an EIP-7702 delegated EOA (rejected on Base mainnet).", treasury);
            return;
        }
        if (treasury.code.length == 0) {
            if (mainnet) revert DeployTreasuryNotContract(treasury);
            console.log("WARNING: TREASURY_SAFE %s has no code (allowed on testnets only).", treasury);
            return;
        }
        (bool isSafe, uint256 threshold, uint256 owners) = LaunchGuards.probeSafe(treasury);
        if (!isSafe) {
            if (mainnet) revert DeployTreasuryNotSafe(treasury);
            console.log("WARNING: TREASURY_SAFE %s is a contract but did not answer as a Safe.", treasury);
            return;
        }
        console.log("TREASURY_SAFE is a Safe: threshold %s of %s owners", threshold, owners);
        if (threshold < LaunchParams.SAFE_MIN_THRESHOLD || owners < LaunchParams.SAFE_MIN_OWNERS) {
            if (mainnet) revert DeployTreasurySafeTooWeak(treasury, threshold, owners);
            console.log("WARNING: the Safe is below the guide's 2-of-3 minimum (rejected on Base mainnet).");
        }
        // 모듈은 소유자 서명 없이 Safe 자산을 옮길 수 있으므로 2-of-3 규칙을 무력화함 (조회 불가도 같은 취급)
        (bool modulesKnown, bool hasModules) = LaunchGuards.safeHasModules(treasury);
        if (modulesKnown && !hasModules) return;
        if (mainnet) {
            console.log("ABORT: TREASURY_SAFE %s has enabled modules (or they cannot be read).", treasury);
            console.log("  A module can move the 50,000,000 FIRE without owner signatures; disable it in the Safe app.");
            revert DeployTreasurySafeHasModules(treasury);
        }
        console.log("WARNING: TREASURY_SAFE has enabled modules or they cannot be read (rejected on Base mainnet).");
    }

    /**
     * @dev 배포 지갑(브로드캐스터)은 8억 FIRE와 이후 LP NFT를 받으므로 코드가 없는 새 하드웨어 지갑 EOA여야 함.
     *      코드가 있으면 EIP-7702 위임 EOA(위임 대상 코드가 잔액을 옮길 수 있음, 예: 유출된 키에 붙는 스위퍼)이므로
     *      메인넷에서 중단하고 테스트넷은 경고만 함. anvil 기본 개발 계정은 Base 메인넷에서 스위퍼에 위임되어 있음.
     */
    function _checkDeployerAccount(address deployer) private view {
        if (deployer.code.length == 0) return;
        string memory kind =
            LaunchGuards.isDelegatedEOA(deployer) ? "an EIP-7702 delegated EOA" : "an account with contract code";
        if (_isMainnet()) {
            console.log(string.concat("ABORT: the deployer %s is ", kind, "."), deployer);
            console.log("  Use a fresh hardware-wallet EOA with no code (it receives 800,000,000 FIRE and the LP NFT).");
            revert DeployBroadcasterHasCode(deployer);
        }
        console.log(string.concat("WARNING: the deployer %s is ", kind, " (rejected on Base mainnet)."), deployer);
    }

    // ───────────────────────── 소유 증명 ─────────────────────────

    function _requireControl(string memory role, string memory envName, address account, bytes memory proof)
        private
        view
    {
        if (block.chainid == LaunchParams.LOCAL_ANVIL) {
            console.log("NOTE: local chain - %s proof of control skipped.", role);
            return;
        }
        string memory text = ControlProof.message(role, account, block.chainid);
        if (account.code.length != 0 && !LaunchGuards.isDelegatedEOA(account)) {
            _requireSafeControl(role, envName, account, text, proof);
            return;
        }
        (ControlProof.Result result, address recovered) = ControlProof.check(text, account, proof);
        if (result == ControlProof.Result.Valid) {
            console.log("%s %s: proof of control verified", role, account);
            return;
        }
        if (result == ControlProof.Result.Missing) {
            console.log("%s %s needs a proof-of-control signature in %s:", role, account, envName);
            _logSigningSteps(envName, account, text);
            if (_isMainnet()) revert DeployProofMissing(envName, text);
            console.log("WARNING: %s not set; allowed on testnets only (required on Base mainnet).", envName);
            return;
        }
        _logProofAbort(envName, role, account, text, result);
        if (result == ControlProof.Result.WrongSigner) revert DeployProofWrongSigner(envName, account, recovered);
        revert DeployProofInvalid(envName, ControlProof.describe(result));
    }

    /**
     * @dev 코드가 있는(EIP-7702 아님) 수령 주소: 이 체인에 배포된 Safe여야 하고(아니면 메인넷 중단), 같은 메시지
     *      (address = Safe 주소)에 Safe의 현재 소유자들이 각자 서명한 값을 이어 붙여 envName에 넣어야 함(서로 다른 소유자
     *      서명 ≥ 임계값). 다른 사람이 만든 비슷한 주소의 Safe는 소유자가 달라 운영자 키의 서명으로 통과할 수 없음.
     *      모듈이 활성화된 Safe는 모듈 하나가 서명 없이 자산(베스팅 owner 권한 포함)을 옮길 수 있으므로 메인넷에서 거부.
     *      테스트넷: 같은 조건을 경고로만 알림(제출한 서명은 메인넷과 같이 검증).
     */
    function _requireSafeControl(
        string memory role,
        string memory envName,
        address account,
        string memory text,
        bytes memory proof
    ) private view {
        if (!_checkSafeRecipient(role, account)) return;
        (, uint256 threshold,) = LaunchGuards.probeSafe(account);
        (, address[] memory owners) = LaunchGuards.safeOwners(account);
        (ControlProof.Result result, uint256 signers, address offender) =
            ControlProof.checkOwners(text, owners, threshold, proof);
        if (result == ControlProof.Result.Valid) {
            console.log("%s Safe %s: proof of control verified (%s owner signatures)", role, account, signers);
            if (_sameString(role, ControlProof.ROLE_AIRDROP_WALLET)) {
                console.log("NOTE: DeployAirdrop.s.sol must be broadcast by AIRDROP_WALLET itself; with a Safe,");
                console.log("      deploy and fund the Merkle distributor through the Safe instead.");
            }
            return;
        }
        if (result == ControlProof.Result.Missing) {
            console.log("%s Safe %s needs owner signatures in %s:", role, account, envName);
            _logSafeSigningSteps(envName, owners, threshold, text);
            if (_isMainnet()) revert DeployProofMissing(envName, text);
            console.log("WARNING: %s not set; allowed on testnets only (required on Base mainnet).", envName);
            return;
        }
        _logProofAbort(envName, role, account, text, result);
        if (result == ControlProof.Result.WrongSigner) revert DeployProofWrongSigner(envName, account, offender);
        if (result == ControlProof.Result.NotEnoughOwners) {
            revert DeployProofNotEnoughOwners(envName, signers, threshold);
        }
        revert DeployProofInvalid(envName, ControlProof.describe(result));
    }

    /// @dev Safe 수령 주소의 형태 확인: Safe가 아니면 메인넷 중단·테스트넷 경고(false 반환), 모듈이 있으면 메인넷 중단.
    function _checkSafeRecipient(string memory role, address account) private view returns (bool isSafe) {
        bool mainnet = _isMainnet();
        uint256 threshold;
        uint256 ownerCount;
        (isSafe, threshold, ownerCount) = LaunchGuards.probeSafe(account);
        if (!isSafe) {
            if (mainnet) {
                console.log("ABORT: %s %s has code but is not a Safe on this chain.", role, account);
                console.log("  Use an EOA / hardware wallet address (with a signature) or a Safe deployed on Base.");
                revert DeployProofAccountNotSafe(role, account);
            }
            console.log("WARNING: %s %s is a contract but not a Safe (rejected on Base mainnet).", role, account);
            return false;
        }
        console.log(string.concat(role, " is a Safe: threshold %s of %s owners"), threshold, ownerCount);
        (bool modulesKnown, bool hasModules) = LaunchGuards.safeHasModules(account);
        if (modulesKnown && !hasModules) return true;
        if (mainnet) {
            console.log("ABORT: %s Safe %s has enabled modules (or they cannot be read).", role, account);
            console.log("  A module can move funds and the vesting ownership without owner signatures.");
            revert DeployProofSafeHasModules(role, account);
        }
        console.log("WARNING: the %s Safe has enabled modules or they cannot be read (rejected on mainnet).", role);
    }

    function _logProofAbort(
        string memory envName,
        string memory role,
        address account,
        string memory text,
        ControlProof.Result result
    ) private pure {
        console.log("ABORT: %s does not prove control of %s %s:", envName, role, account);
        console.log(string.concat("  ", ControlProof.describe(result)));
        console.log(string.concat("  expected message: ", text));
    }

    /// @dev printProofMessages()의 역할별 출력. 이미 설정된 서명은 검증 결과까지 보여 줌(revert 없음).
    function _printProof(string memory role, string memory envName, address account)
        private
        view
        returns (string memory text)
    {
        text = ControlProof.message(role, account, block.chainid);
        console.log("");
        bool delegated = LaunchGuards.isDelegatedEOA(account);
        if (account.code.length != 0 && !delegated) {
            _printSafeProof(role, envName, account, text);
            return text;
        }
        console.log(
            "[%s] %s: %s - signature required",
            role,
            account,
            delegated ? "EIP-7702 delegated EOA (sign with its own key)" : "EOA"
        );
        _logSigningSteps(envName, account, text);
        (bool provided, bool ok, bytes memory signature) = _printEnvSignature(envName);
        if (!provided || !ok) return text;
        (ControlProof.Result result,) = ControlProof.check(text, account, signature);
        console.log(
            "  status  : %s %s",
            envName,
            result == ControlProof.Result.Valid ? "verified" : ControlProof.describe(result)
        );
    }

    /// @dev printProofMessages()의 Safe 수령 주소 출력: 소유자·임계값·모듈, 소유자별 서명 방법, 설정된 서명의 검증 결과.
    function _printSafeProof(string memory role, string memory envName, address account, string memory text)
        private
        view
    {
        (bool isSafe, uint256 threshold, uint256 ownerCount) = LaunchGuards.probeSafe(account);
        if (!isSafe) {
            console.log("[%s] %s: contract that is NOT a Safe - rejected on Base mainnet", role, account);
            return;
        }
        console.log(
            string.concat("[", role, "] %s: Safe on this chain - signatures of %s of its %s owners required"),
            account,
            threshold,
            ownerCount
        );
        (bool modulesKnown, bool hasModules) = LaunchGuards.safeHasModules(account);
        if (!modulesKnown || hasModules) {
            console.log("  modules : enabled or unreadable - rejected on Base mainnet (disable them first)");
        } else {
            console.log("  modules : none");
        }
        (, address[] memory owners) = LaunchGuards.safeOwners(account);
        _logSafeSigningSteps(envName, owners, threshold, text);
        (bool provided, bool ok, bytes memory signatures) = _printEnvSignature(envName);
        if (!provided || !ok) return;
        (ControlProof.Result result, uint256 signers,) = ControlProof.checkOwners(text, owners, threshold, signatures);
        if (result == ControlProof.Result.Valid) {
            console.log("  status  : %s verified (%s owner signatures)", envName, signers);
        } else {
            console.log(string.concat("  status  : ", envName, " ", ControlProof.describe(result)));
        }
    }

    /// @dev printProofMessages()용: 환경 변수에 서명이 있는지·형식이 맞는지 출력 (revert 없음).
    function _printEnvSignature(string memory envName)
        private
        view
        returns (bool provided, bool ok, bytes memory signatures)
    {
        string memory raw = _envString(envName);
        provided = bytes(raw).length != 0;
        if (!provided) {
            console.log("  status  : %s not set", envName);
            return (false, false, "");
        }
        (ok, signatures) = ControlProof.parseSignatures(raw);
        if (!ok) console.log("  status  : %s is malformed (expected 0x + 130 hex characters per signature)", envName);
    }

    /// @dev 서명할 메시지와 바로 실행할 수 있는 명령 (Ledger / 키스토어 서명, 서명 확인, 환경 변수 설정).
    function _logSigningSteps(string memory envName, address account, string memory text) private pure {
        string memory quoted = string.concat("\"", text, "\"");
        console.log(string.concat("  message : ", text));
        console.log(string.concat("  Ledger  : cast wallet sign --ledger ", quoted));
        console.log(string.concat("  keystore: cast wallet sign --account <name> ", quoted));
        console.log(
            string.concat(
                "  verify  : cast wallet verify --address ", vm.toString(account), " ", quoted, " <signature>"
            )
        );
        console.log(string.concat("  export  : export ", envName, "=<signature, 0x + 130 hex characters>"));
    }

    /// @dev Safe 수령 주소: 소유자마다 같은 메시지에 자기 키로 서명하고, 서명들을 0x 하나 뒤에 이어 붙임(순서 무관).
    function _logSafeSigningSteps(string memory envName, address[] memory owners, uint256 threshold, string memory text)
        private
        pure
    {
        string memory quoted = string.concat("\"", text, "\"");
        console.log(string.concat("  message : ", text));
        console.log("  owners  : at least %s of these must sign with their own key:", threshold);
        for (uint256 i; i < owners.length; ++i) {
            console.log("            %s", owners[i]);
        }
        console.log(string.concat("  Ledger  : cast wallet sign --ledger ", quoted, "   (run once per owner)"));
        console.log(
            string.concat("  verify  : cast wallet verify --address <owner> ", quoted, " <that owner's signature>")
        );
        console.log(
            string.concat("  export  : export ", envName, "=0x<sig1 without 0x><sig2 without 0x>...  (any order)")
        );
    }

    // ───────────────────────── 사후 조건 ─────────────────────────

    /// @notice 배포 직후 상태가 가이드 2.2절 분배표·3.1절 일정과 정확히 일치하는지 확인.
    function checkPostConditions(DeployResult memory r) public view {
        FireToken token = FireToken(r.token);
        FireVesting vesting = FireVesting(payable(r.vesting));

        _post(token.totalSupply() == LaunchParams.TOTAL_SUPPLY, "totalSupply != 1,000,000,000 FIRE");
        _post(token.balanceOf(r.deployer) == LP_AMOUNT, "deployer balance != 700,000,000 FIRE");
        _post(token.balanceOf(r.vesting) == LaunchParams.VESTING_AMOUNT, "vesting balance != 200,000,000 FIRE");
        _post(token.balanceOf(r.treasurySafe) == TREASURY_AMOUNT, "treasury balance != 50,000,000 FIRE");
        _post(token.balanceOf(r.airdropWallet) == AIRDROP_AMOUNT, "airdrop balance != 50,000,000 FIRE");
        _post(vesting.owner() == r.beneficiary, "vesting.owner() != BENEFICIARY");
        _post(vesting.pendingOwner() == address(0), "vesting.pendingOwner() != 0");
        _post(vesting.duration() == LINEAR, "vesting.duration() != LINEAR");
        _post(vesting.start() == r.blockTimestamp + CLIFF, "vesting.start() != deploy timestamp + CLIFF");
        _post(vesting.end() == vesting.start() + LINEAR, "vesting.end() != start + LINEAR");
        _post(vesting.releasable(r.token) == 0, "vesting releasable != 0 before cliff");
    }

    function _post(bool ok, string memory check) private pure {
        if (!ok) revert DeployPostConditionFailed(check);
    }

    function _transfer(FireToken token, address to, uint256 amount) private {
        if (!token.transfer(to, amount)) revert DeployPostConditionFailed("FIRE transfer returned false");
    }

    // ───────────────────────── 확인(confirm) ─────────────────────────

    /**
     * @notice pending 기록을 온체인 상태와 대조하고 confirmed로 갱신. 기록 파일 외에는 아무것도 바꾸지 않음.
     * @dev 확인 항목: 두 주소가 배포자의 CREATE 주소(deployerNonce, +1), 코드가 있고 FireToken/FireVesting이 맞음,
     *      owner == 기록된 수익자, duration == 540일,
     *      베스팅 물량 2억, 배포자 nonce가 기록된 시작 nonce + 4 이상(4건 모두 채굴), 온체인 start ≥ 기록(시뮬레이션) 값.
     *      갱신: vesting.start/end(온체인), deployedAt(= start − 180일, 실제 배포 블록 시각), status = confirmed.
     *      반환값의 vestingStart/End는 온체인 값, blockNumber/blockTimestamp는 기록된 시뮬레이션 값 그대로.
     *      다른 키(.pool, 운영자가 넣은 .lpLock)는 건드리지 않음.
     */
    function confirmRecord(string memory path) public returns (DeployResult memory r) {
        (bool exists, string memory json) = _readJsonIfExists(path);
        if (!exists) revert DeployRecordMissing(path);
        r = resultFromRecord(json);
        _confirmCheck(r.chainId == block.chainid, "record chainId != current chain");
        // 기록의 두 주소는 배포 지갑이 만든 CREATE 주소여야 함 (다른 사람이 만든 복제 토큰·베스팅으로 바꾼 기록 거부)
        _confirmCheck(
            r.vesting == vm.computeCreateAddress(r.deployer, r.deployerNonce),
            "contracts.FireVesting != CREATE(deployer, deployerNonce)"
        );
        _confirmCheck(
            r.token == vm.computeCreateAddress(r.deployer, r.deployerNonce + 1),
            "contracts.FireToken != CREATE(deployer, deployerNonce + 1)"
        );
        _confirmCheck(r.vesting.code.length != 0, "no code at the recorded FireVesting (broadcast not mined?)");
        _confirmCheck(_isFireToken(r.token), "no FireToken at the recorded address (broadcast not mined?)");
        _confirmCheck(
            vm.getNonce(r.deployer) >= r.deployerNonce + LAUNCH_TX_COUNT,
            "deployer nonce: not all 4 launch transactions were mined (finish with --resume)"
        );

        FireVesting vesting = FireVesting(payable(r.vesting));
        FireToken token = FireToken(r.token);
        _confirmCheck(vesting.owner() == r.beneficiary, "vesting.owner() != recorded beneficiary");
        _confirmCheck(vesting.duration() == LINEAR, "vesting.duration() != 540 days");
        _confirmCheck(
            token.balanceOf(r.vesting) + vesting.released(r.token) >= LaunchParams.VESTING_AMOUNT,
            "vesting does not hold 200,000,000 FIRE"
        );
        uint256 start = vesting.start();
        _confirmCheck(start >= r.vestingStart, "vesting.start() earlier than the simulated record");

        console.log("--- confirmed on-chain ---");
        console.log("inclusion delay vs simulation: %s s", start - r.vestingStart);
        _logLaunchBalance(token, r.treasurySafe, TREASURY_AMOUNT, "treasury");
        _logLaunchBalance(token, r.airdropWallet, AIRDROP_AMOUNT, "airdrop ");
        r.vestingStart = start;
        r.vestingEnd = vesting.end();
        uint256 deployedAt = start - CLIFF; // FireVesting 생성자의 block.timestamp (실제 배포 블록 시각)

        vm.writeJson(vm.toString(r.vestingStart), path, ".vesting.start");
        vm.writeJson(vm.toString(r.vestingEnd), path, ".vesting.end");
        vm.writeJson(vm.toString(deployedAt), path, ".deployedAt");
        vm.writeJson(string.concat('"', LaunchParams.RECORD_CONFIRMED, '"'), path, ".status");
        console.log("deployed at (on-chain)    : %s", _formatUtc(deployedAt));
        console.log("cliff ends (vesting.start): %s", _formatUtc(r.vestingStart));
        console.log("fully vested (vesting.end): %s", _formatUtc(r.vestingEnd));
        console.log("Record confirmed:", path);
    }

    /// @notice 기록 JSON → DeployResult (blockNumber/blockTimestamp/vesting.*은 기록된 값 그대로).
    function resultFromRecord(string memory json) public pure returns (DeployResult memory r) {
        r.vesting = vm.parseJsonAddress(json, ".contracts.FireVesting");
        r.token = vm.parseJsonAddress(json, ".contracts.FireToken");
        r.deployer = vm.parseJsonAddress(json, ".deployer");
        r.beneficiary = vm.parseJsonAddress(json, ".wallets.beneficiary");
        r.treasurySafe = vm.parseJsonAddress(json, ".wallets.treasurySafe");
        r.airdropWallet = vm.parseJsonAddress(json, ".wallets.airdropWallet");
        r.chainId = vm.parseJsonUint(json, ".chainId");
        r.blockNumber = vm.parseJsonUint(json, ".blockNumber");
        r.blockTimestamp = vm.parseJsonUint(json, ".blockTimestamp");
        r.vestingStart = vm.parseJsonUint(json, ".vesting.start");
        r.vestingEnd = vm.parseJsonUint(json, ".vesting.end");
        r.deployerNonce = vm.parseJsonUint(json, ".deployerNonce");
    }

    function _confirmCheck(bool ok, string memory check) private pure {
        if (!ok) revert DeployConfirmFailed(check);
    }

    function _logLaunchBalance(FireToken token, address account, uint256 allocation, string memory who) private view {
        uint256 balance = token.balanceOf(account);
        if (balance == allocation) {
            console.log("%s holds %s FIRE", who, _fmt(balance));
        } else {
            console.log("WARNING: %s holds %s FIRE (allocation %s)", who, _fmt(balance), _fmt(allocation));
        }
    }

    // ───────────────────────── 기록 ─────────────────────────

    /**
     * @notice deployments/<chainId>.json 내용 (status "pending"). 주소는 CREATE로 확정되지만 blockNumber/blockTimestamp/
     *         vesting.start·end는 forge가 시뮬레이션한 블록 기준 값이며, 실제 포함 블록은 그 이후임.
     *         confirm()이 온체인 값으로 vesting.start·end와 deployedAt을 채우고 status를 "confirmed"로 바꿈.
     */
    function recordJson(DeployResult memory r) public returns (string memory json) {
        _resetJson("fire.contracts");
        vm.serializeAddress("fire.contracts", "FireVesting", r.vesting);
        string memory contracts = vm.serializeAddress("fire.contracts", "FireToken", r.token);

        _resetJson("fire.wallets");
        vm.serializeAddress("fire.wallets", "beneficiary", r.beneficiary);
        vm.serializeAddress("fire.wallets", "treasurySafe", r.treasurySafe);
        string memory wallets = vm.serializeAddress("fire.wallets", "airdropWallet", r.airdropWallet);

        _resetJson("fire.vesting");
        vm.serializeUint("fire.vesting", "cliffSeconds", CLIFF);
        vm.serializeUint("fire.vesting", "linearSeconds", LINEAR);
        vm.serializeUint("fire.vesting", "start", r.vestingStart);
        string memory schedule = vm.serializeUint("fire.vesting", "end", r.vestingEnd);

        _resetJson("fire.allocation");
        _serializeAmount("fire.allocation", "totalSupply", LaunchParams.TOTAL_SUPPLY);
        _serializeAmount("fire.allocation", "vesting", LaunchParams.VESTING_AMOUNT);
        _serializeAmount("fire.allocation", "lp", LP_AMOUNT);
        _serializeAmount("fire.allocation", "treasury", TREASURY_AMOUNT);
        string memory allocation = _serializeAmount("fire.allocation", "airdrop", AIRDROP_AMOUNT);

        _resetJson("fire");
        vm.serializeString("fire", "status", LaunchParams.RECORD_PENDING);
        vm.serializeUint("fire", "chainId", r.chainId);
        vm.serializeString("fire", "network", _networkName(r.chainId));
        vm.serializeAddress("fire", "deployer", r.deployer);
        vm.serializeUint("fire", "deployerNonce", r.deployerNonce);
        vm.serializeUint("fire", "blockNumber", r.blockNumber);
        vm.serializeUint("fire", "blockTimestamp", r.blockTimestamp);
        vm.serializeString("fire", "contracts", contracts);
        vm.serializeString("fire", "wallets", wallets);
        vm.serializeString("fire", "vesting", schedule);
        json = vm.serializeString("fire", "allocation", allocation);
    }

    // ───────────────────────── 로그 ─────────────────────────

    function _logPlan(DeployConfig memory cfg, address deployer, address predictedVesting, address predictedToken)
        private
        view
    {
        console.log("=== FIRE launch deployment (%s, chainId %s) ===", _networkName(block.chainid), block.chainid);
        console.log("deployer (broadcaster):", deployer);
        console.log("BENEFICIARY    :", cfg.beneficiary);
        console.log("TREASURY_SAFE  :", cfg.treasurySafe);
        console.log("AIRDROP_WALLET :", cfg.airdropWallet);
        console.log("predicted FireVesting:", predictedVesting);
        console.log("predicted FireToken  :", predictedToken);
    }

    function _logResult(DeployResult memory r) private view {
        console.log("--- deployed (simulation; final once mined) ---");
        console.log("FireVesting:", _explorerAddress(r.vesting));
        console.log("FireToken  :", _explorerAddress(r.token));
        console.log("deployer   %s FIRE (Uniswap V3 LP)", _fmt(LP_AMOUNT));
        console.log("vesting    %s FIRE", _fmt(LaunchParams.VESTING_AMOUNT));
        console.log("treasury   %s FIRE", _fmt(TREASURY_AMOUNT));
        console.log("airdrop    %s FIRE", _fmt(AIRDROP_AMOUNT));
        console.log("vesting cliff end (start): %s (simulated block)", _formatUtc(r.vestingStart));
        console.log("vesting fully vested (end): %s (simulated block)", _formatUtc(r.vestingEnd));
        console.log("post-conditions: OK");
    }

    function _logNextSteps(DeployResult memory r) private view {
        string memory rpc = _rpcAlias(r.chainId);
        console.log("");
        console.log("=== NEXT STEPS ===");
        console.log("If the broadcast stops part-way, re-run the SAME command with --resume (never delete the record).");
        console.log("1) Once the 4 txs are mined, confirm the record (no signing, no transactions):");
        console.log(string.concat("   forge script script/Deploy.s.sol:Deploy --sig 'confirm()' --rpc-url ", rpc));
        console.log("2) Create the pool right away (add --ledger or --account <name>; see CreatePool for permit):");
        console.log(
            string.concat(
                "   ",
                _isMainnet() ? "CONFIRM_MAINNET=I_UNDERSTAND " : "",
                "forge script script/CreatePool.s.sol:CreatePool --rpc-url ",
                rpc,
                " --sender ",
                vm.toString(r.deployer),
                " --broadcast --slow"
            )
        );
        console.log("3) After the pool exists, the LP NFT is locked and CreatePool --sig 'confirmLock()' ran,");
        console.log("   verify both contracts:");
        console.log(
            string.concat(
                "   forge verify-contract ",
                vm.toString(r.vesting),
                " src/FireVesting.sol:FireVesting --chain ",
                vm.toString(r.chainId),
                " --verifier etherscan --watch --constructor-args ",
                vm.toString(abi.encode(r.beneficiary, CLIFF, LINEAR))
            )
        );
        console.log(
            string.concat(
                "   forge verify-contract ",
                vm.toString(r.token),
                " src/FireToken.sol:FireToken --chain ",
                vm.toString(r.chainId),
                " --verifier etherscan --watch --constructor-args ",
                vm.toString(abi.encode(r.vesting))
            )
        );
        console.log("4) forge script script/PostDeployCheck.s.sol:PostDeployCheck --rpc-url", rpc);
    }
}
