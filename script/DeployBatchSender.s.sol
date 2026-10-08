// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {console} from "forge-std/console.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {FireToken} from "../src/FireToken.sol";
import {FireBatchSender} from "../src/FireBatchSender.sol";
import {GuardedScript} from "./lib/GuardedScript.sol";
import {LaunchGuards} from "./lib/LaunchGuards.sol";
import {LaunchParams} from "./lib/LaunchParams.sol";

/**
 * @title DeployBatchSender (Fire Batch Sender 배포, 로드맵 2027 Q1)
 * @dev 개인 키는 코드·.env에 두지 않고 --ledger 또는 --account(cast wallet 키스토어)로 서명.
 *      배포자는 어떤 권한도 갖지 않음: 소유자(수수료 설정 권한)는 생성자에서 곧바로 지정.
 *
 *      입력 (환경 변수의 빈 값은 미설정으로 취급 → .env.example의 `KEY=` 줄을 그대로 둬도 기본값·기록값 적용).
 *      주소는 EIP-55 체크섬 표기 그대로: 대소문자 한 글자 오타는 모든 체인에서, 체크섬 없는(전부 소문자) 주소는
 *      Base 메인넷에서 거부함. 스크립트 실행 중에는 RPC의 eth_chainId가 시뮬레이션 체인과 같아야 함
 *      (--chain / FOUNDRY_CHAIN_ID로 메인넷 RPC를 테스트넷으로 위장하는 것을 차단, LaunchGuards).
 *        FIRE_TOKEN             FireToken 주소. 비우면 deployments/<chainId>.json의 contracts.FireToken.
 *                               둘 다 있는데 서로 다르면 모든 체인에서 중단(오래된 .env 방지).
 *                               Base 메인넷(8453)은 Deploy가 쓴 런칭 기록(deployments/8453.json, deployer·deployerNonce
 *                               포함)이 반드시 있어야 하고, 기록의 토큰이 CREATE(deployer, deployerNonce + 1)이며 그 값과 같아야 함.
 *        BATCH_SENDER_OWNER     수수료 설정 권한자 = CEX/MM 트레저리 Safe. 비우면 기록 파일의 wallets.treasurySafe.
 *                               8453: 기록된 트레저리 Safe와 같아야 하고(기록이 있을 때), getThreshold() ≥ 2·getOwners() ≥ 3이며
 *                               활성화된 모듈이 없는 Safe여야 함. EIP-7702 위임 EOA(코드 0xef0100…, 단일 키)는 거부.
 *                               84532·31337: 리허설용으로 EOA·기록과 다른 주소 허용(경고 출력).
 *        BATCH_FREE_RECIPIENTS  (선택, 기본 25) 수수료 없이 보낼 수 있는 최대 수령자 수 (0 ~ 300, 생성자가 검증)
 *        BATCH_BURN_FEE_FIRE    (선택, 기본 10000) 유료 배치 1회당 소각 FIRE, 정수 FIRE 단위 (0 ~ 1,000,000, 생성자가 검증)
 *        CONFIRM_MAINNET        (8453에서 필수) 정확히 I_UNDERSTAND
 *      FIRE_TOKEN 검증(모든 체인): 코드 존재, name "Fire", symbol "FIRE", decimals 18, TOTAL_SUPPLY() 10억,
 *      VESTING_SUPPLY() 2억, 0 < totalSupply() ≤ 10억. 바이트코드를 그대로 복제한 토큰은 이 검사를 통과하므로
 *      메인넷은 런칭 기록의 주소로 고정함.
 *
 *      실행 예
 *        # 시뮬레이션만 (브로드캐스트 없음)
 *        forge script script/DeployBatchSender.s.sol:DeployBatchSender --rpc-url base_sepolia --sender <배포자>
 *        # Base Sepolia 리허설 (트랜잭션 1건이지만 다른 스크립트와 같이 --slow를 붙임)
 *        forge script script/DeployBatchSender.s.sol:DeployBatchSender --rpc-url base_sepolia \
 *          --account <키스토어> --sender <배포자> --broadcast --slow --verify
 *        # Base 메인넷 (FIRE_TOKEN·BATCH_SENDER_OWNER는 deployments/8453.json에서 읽거나 같은 값으로 지정).
 *        # 메인넷은 시뮬레이션에도 CONFIRM_MAINNET이 필요함.
 *        CONFIRM_MAINNET=I_UNDERSTAND forge script script/DeployBatchSender.s.sol:DeployBatchSender \
 *          --rpc-url base --ledger --sender <배포자> --broadcast --slow --verify
 */
contract DeployBatchSender is GuardedScript {
    uint256 internal constant BASE_MAINNET = 8453;
    uint256 internal constant BASE_SEPOLIA = 84532;
    uint256 internal constant LOCAL_CHAIN = 31337;

    uint256 internal constant DEFAULT_FREE_RECIPIENTS = 25;
    uint256 internal constant DEFAULT_BURN_FEE_FIRE = 10_000;
    string internal constant MAINNET_CONFIRMATION = "I_UNDERSTAND";

    /// @dev FireToken 공개 상수와 같은 값 (Solidity는 다른 컨트랙트의 상수를 컴파일 시점에 참조할 수 없음).
    uint256 internal constant FIRE_TOTAL_SUPPLY = 1_000_000_000e18;
    uint256 internal constant FIRE_VESTING_SUPPLY = 200_000_000e18;

    /// @dev 메인넷 소유자 Safe의 최소 구성 (가이드 2.2절: 서명자 최소 2-of-3, Deploy의 TREASURY_SAFE 규칙과 같은 값).
    uint256 internal constant MIN_SAFE_THRESHOLD = LaunchParams.SAFE_MIN_THRESHOLD;
    uint256 internal constant MIN_SAFE_OWNERS = LaunchParams.SAFE_MIN_OWNERS;

    /// @dev 런칭 배포 기록(deployments/<chainId>.json, script/Deploy.s.sol이 작성)의 키.
    string internal constant RECORD_FIRE_TOKEN_KEY = ".contracts.FireToken";
    string internal constant RECORD_TREASURY_KEY = ".wallets.treasurySafe";

    /// @dev burnFee는 wei 단위(18 decimals). 환경 변수는 정수 FIRE 단위로 받아 변환.
    struct Config {
        address fireToken;
        address owner;
        uint256 freeRecipientLimit;
        uint256 burnFee;
    }

    error DeployBatchSenderUnsupportedChain(uint256 chainId);
    error DeployBatchSenderMainnetNotConfirmed();
    error DeployBatchSenderMissingAddress(string name);
    error DeployBatchSenderRecordMismatch(string name, address given, address recorded);
    error DeployBatchSenderFireTokenNotRecorded(string recordPath);
    error DeployBatchSenderInvalidFireToken(address fireToken);
    error DeployBatchSenderInvalidOwner(address owner);
    error DeployBatchSenderOwnerIsDelegatedEOA(address owner);
    error DeployBatchSenderOwnerNotSafe(address owner, uint256 threshold, uint256 ownerCount);
    error DeployBatchSenderOwnerHasModules(address owner);
    error DeployBatchSenderRecordNotLaunch(string recordPath);
    error DeployBatchSenderBurnFeeOverflow(uint256 feeFire);
    error DeployBatchSenderPostDeployCheckFailed(string field);

    /// @notice 환경 변수·배포 기록을 읽어 배포. 체인 확인(메인넷 확인 문구 포함)을 다른 값보다 먼저 수행.
    function run() external returns (FireBatchSender batchSender) {
        _checkChain();
        batchSender = deploy(loadConfig());
    }

    /**
     * @notice 환경 변수(+ 배포 기록) → 배포 설정. 주소는 환경 변수가 우선이고, 비어 있으면 기록값을 사용.
     *         기록과의 일치·체인별 정책은 deploy()의 검증 단계가 담당(명시적 설정으로 deploy()를 호출해도 동일하게 적용).
     * @dev 수수료 상한(MAX_BURN_FEE)·무료 수령자 상한(MAX_RECIPIENTS)은 FireBatchSender 생성자가 단일 기준으로 검증.
     *      범위를 벗어나면 forge script 시뮬레이션 단계에서 생성자 오류로 중단되어 아무것도 브로드캐스트되지 않음.
     */
    function loadConfig() public view returns (Config memory cfg) {
        string memory record = _readDeploymentRecord();
        cfg.fireToken = _envAddressOr("FIRE_TOKEN", _recordAddress(record, RECORD_FIRE_TOKEN_KEY));
        if (cfg.fireToken == address(0)) revert DeployBatchSenderMissingAddress("FIRE_TOKEN");
        cfg.owner = _envAddressOr("BATCH_SENDER_OWNER", _recordAddress(record, RECORD_TREASURY_KEY));
        if (cfg.owner == address(0)) revert DeployBatchSenderMissingAddress("BATCH_SENDER_OWNER");
        cfg.freeRecipientLimit = _envUintOr("BATCH_FREE_RECIPIENTS", DEFAULT_FREE_RECIPIENTS);
        uint256 feeFire = _envUintOr("BATCH_BURN_FEE_FIRE", DEFAULT_BURN_FEE_FIRE);
        if (feeFire > type(uint256).max / 1e18) revert DeployBatchSenderBurnFeeOverflow(feeFire);
        cfg.burnFee = feeFire * 1e18;
    }

    /// @notice 설정 검증 → 배포 → 배포 결과 재확인 → 로그.
    function deploy(Config memory cfg) public returns (FireBatchSender batchSender) {
        _checkChain();
        _validate(cfg);
        _logPlan(cfg);

        vm.startBroadcast();
        batchSender = new FireBatchSender(cfg.fireToken, cfg.owner, cfg.freeRecipientLimit, cfg.burnFee);
        vm.stopBroadcast();

        _verifyDeployment(batchSender, cfg);
        _logResult(batchSender);
    }

    /// @dev 허용 체인: Base 메인넷·Base Sepolia·로컬. RPC 체인 ID 대조(LaunchGuards) 후, 메인넷은
    ///      CONFIRM_MAINNET=I_UNDERSTAND 필요.
    function _checkChain() internal {
        uint256 chainId = block.chainid;
        if (chainId != BASE_MAINNET && chainId != BASE_SEPOLIA && chainId != LOCAL_CHAIN) {
            revert DeployBatchSenderUnsupportedChain(chainId);
        }
        _requireRpcChainMatches();
        if (chainId == BASE_MAINNET && !Strings.equal(_envString("CONFIRM_MAINNET"), MAINNET_CONFIRMATION)) {
            revert DeployBatchSenderMainnetNotConfirmed();
        }
    }

    function _validate(Config memory cfg) internal view {
        if (!_isFireToken(cfg.fireToken)) revert DeployBatchSenderInvalidFireToken(cfg.fireToken);
        if (cfg.owner == address(0)) revert DeployBatchSenderInvalidOwner(cfg.owner);

        string memory record = _readDeploymentRecord();
        address recordedToken = _recordAddress(record, RECORD_FIRE_TOKEN_KEY);
        address recordedTreasury = _recordAddress(record, RECORD_TREASURY_KEY);
        // 오래된 .env 등으로 기록과 다른 토큰을 가리키면 모든 체인에서 중단 (fireToken은 배포 후 변경 불가)
        if (recordedToken != address(0) && cfg.fireToken != recordedToken) {
            revert DeployBatchSenderRecordMismatch("FIRE_TOKEN", cfg.fireToken, recordedToken);
        }

        if (block.chainid == BASE_MAINNET) {
            // 바이트코드 복제 토큰은 식별 검사를 통과하므로 메인넷은 런칭 기록의 주소로 고정 (기록 필수)
            if (recordedToken == address(0)) revert DeployBatchSenderFireTokenNotRecorded(_deploymentRecordPath());
            _requireLaunchRecord(record, recordedToken);
            if (recordedTreasury != address(0) && cfg.owner != recordedTreasury) {
                revert DeployBatchSenderRecordMismatch("BATCH_SENDER_OWNER", cfg.owner, recordedTreasury);
            }
            _requireMultisigOwner(cfg.owner);
        } else {
            _warnRehearsalOwner(cfg.owner, recordedTreasury);
        }
    }

    /**
     * @dev 메인넷 기록은 Deploy가 쓴 런칭 기록이어야 함: deployer·deployerNonce가 있고 contracts.FireToken이
     *      CREATE(deployer, deployerNonce + 1). CreatePool이 FIRE_TOKEN 값만으로 만든 최소 기록(테스트넷 전용)이나
     *      손으로 고친 기록을 메인넷 고정 기준으로 쓰지 않음.
     */
    function _requireLaunchRecord(string memory record, address recordedToken) internal view {
        address deployer = _recordAddress(record, ".deployer");
        if (deployer == address(0) || !vm.keyExistsJson(record, ".deployerNonce")) {
            revert DeployBatchSenderRecordNotLaunch(_deploymentRecordPath());
        }
        uint256 nonce = vm.parseJsonUint(record, ".deployerNonce");
        if (recordedToken != vm.computeCreateAddress(deployer, nonce + 1)) {
            revert DeployBatchSenderRecordNotLaunch(_deploymentRecordPath());
        }
    }

    /// @dev 메인넷 소유자: 단일 키가 아닌 2-of-3 이상 Safe. 소유권 포기가 막혀 있어 잘못 지정하면 수수료 설정이 영구 동결되거나
    ///      개인 키 하나가 수수료를 통제하게 되므로, 호출할 수 없는 컨트랙트·EOA·EIP-7702 위임 EOA를 모두 거부.
    ///      모듈이 활성화된 Safe도 거부: 모듈은 소유자 서명 없이 Safe로서 setBurnFee 등을 호출할 수 있음.
    function _requireMultisigOwner(address owner) internal view {
        // 위임 EOA는 위임 대상이 Safe처럼 응답해도 원래 개인 키로 언제든 직접 서명할 수 있음
        (bool ok, bool delegated, uint256 threshold, uint256 ownerCount) =
            LaunchGuards.isMultisig(owner, MIN_SAFE_THRESHOLD, MIN_SAFE_OWNERS);
        if (delegated) revert DeployBatchSenderOwnerIsDelegatedEOA(owner);
        if (!ok) revert DeployBatchSenderOwnerNotSafe(owner, threshold, ownerCount);
        (bool modulesKnown, bool hasModules) = LaunchGuards.safeHasModules(owner);
        if (!modulesKnown || hasModules) revert DeployBatchSenderOwnerHasModules(owner);
    }

    /// @dev 테스트넷·로컬은 리허설 편의를 위해 허용하되 메인넷에서 막힐 구성은 미리 경고.
    function _warnRehearsalOwner(address owner, address recordedTreasury) internal view {
        if (recordedTreasury != address(0) && owner != recordedTreasury) {
            console.log("WARNING: owner differs from recorded treasury Safe %s (rejected on mainnet)", recordedTreasury);
        }
        (bool ok,,,) = LaunchGuards.isMultisig(owner, MIN_SAFE_THRESHOLD, MIN_SAFE_OWNERS);
        if (!ok) {
            console.log("WARNING: owner is not a 2-of-3+ Safe (allowed for rehearsal only, rejected on mainnet)");
            return;
        }
        (bool modulesKnown, bool hasModules) = LaunchGuards.safeHasModules(owner);
        if (!modulesKnown || hasModules) {
            console.log("WARNING: the owner Safe has enabled modules or they cannot be read (rejected on mainnet)");
        }
    }

    /// @dev WETH·베스팅·복제 토큰 등 다른 주소를 잘못 넣는 사고 방지: FireToken의 메타데이터·고정 상수·공급량 확인.
    function _isFireToken(address token) internal view returns (bool) {
        if (token.code.length == 0) return false;
        FireToken fire = FireToken(token);
        try fire.name() returns (string memory name) {
            if (!Strings.equal(name, "Fire")) return false;
        } catch {
            return false;
        }
        try fire.symbol() returns (string memory symbol) {
            if (!Strings.equal(symbol, "FIRE")) return false;
        } catch {
            return false;
        }
        try fire.decimals() returns (uint8 decimals) {
            if (decimals != 18) return false;
        } catch {
            return false;
        }
        try fire.TOTAL_SUPPLY() returns (uint256 maxSupply) {
            if (maxSupply != FIRE_TOTAL_SUPPLY) return false;
        } catch {
            return false;
        }
        try fire.VESTING_SUPPLY() returns (uint256 vestingSupply) {
            if (vestingSupply != FIRE_VESTING_SUPPLY) return false;
        } catch {
            return false;
        }
        // 소각으로만 줄어들 수 있음 (추가 발행 함수 없음)
        try fire.totalSupply() returns (uint256 supply) {
            return supply != 0 && supply <= FIRE_TOTAL_SUPPLY;
        } catch {
            return false;
        }
    }

    function _verifyDeployment(FireBatchSender batchSender, Config memory cfg) internal view {
        if (batchSender.fireToken() != cfg.fireToken) revert DeployBatchSenderPostDeployCheckFailed("fireToken");
        if (batchSender.owner() != cfg.owner) revert DeployBatchSenderPostDeployCheckFailed("owner");
        if (batchSender.pendingOwner() != address(0)) revert DeployBatchSenderPostDeployCheckFailed("pendingOwner");
        if (batchSender.freeRecipientLimit() != cfg.freeRecipientLimit) {
            revert DeployBatchSenderPostDeployCheckFailed("freeRecipientLimit");
        }
        if (batchSender.burnFee() != cfg.burnFee) revert DeployBatchSenderPostDeployCheckFailed("burnFee");
    }

    function _logPlan(Config memory cfg) internal view {
        console.log("== Fire Batch Sender deployment ==");
        console.log("chainId               :", block.chainid);
        console.log("deployment record     :", _deploymentRecordPath());
        console.log("deployer (no rights)  :", msg.sender);
        console.log("fireToken             :", cfg.fireToken);
        console.log("owner (treasury Safe) :", cfg.owner);
        console.log("freeRecipientLimit    :", cfg.freeRecipientLimit);
        console.log("burnFee (whole FIRE)  :", cfg.burnFee / 1e18);
        console.log("burnFee (wei)         :", cfg.burnFee);
    }

    function _logResult(FireBatchSender batchSender) internal view {
        console.log("FireBatchSender       :", address(batchSender));
        console.log("MAX_RECIPIENTS        :", batchSender.MAX_RECIPIENTS());
        console.log("ETH_RECIPIENT_GAS     :", batchSender.ETH_RECIPIENT_GAS());
        console.log("MAX_BURN_FEE (FIRE)   :", batchSender.MAX_BURN_FEE() / 1e18);
        console.log(
            unicode"다음 단계 1) BaseScan 검증 확인 (--verify 미사용 시 forge verify-contract로 별도 검증)"
        );
        console.log(
            unicode"다음 단계 2) 트레저리 Safe 기준으로 owner()·burnFee()·freeRecipientLimit()·fireToken() 재확인"
        );
        console.log(
            unicode"다음 단계 3) 컨트랙트 주소를 README·웹사이트에 공개, 프론트엔드에 quoteBurnFee 연동"
        );
    }

    // ───────── 입력 읽기 (테스트 하네스가 재정의하는 지점) ─────────
    // 환경 변수(_envString)·RPC·실행 문맥 입력 지점과 _envAddressOr / _envUintOr는 GuardedScript.
    // 테스트 하네스는 입력 지점만 재정의하므로 기본값·파싱 규칙은 실제 실행과 같은 코드로 검증됨.

    /// @notice 공개 배포 기록 경로: deployments/<chainId>.json (foundry.toml fs_permissions 범위).
    function _deploymentRecordPath() internal view virtual returns (string memory) {
        return string.concat("deployments/", vm.toString(block.chainid), ".json");
    }

    /// @dev 배포 기록 JSON. 파일이 없으면 "" (기록 없음).
    function _readDeploymentRecord() internal view virtual returns (string memory) {
        string memory path = _deploymentRecordPath();
        if (!vm.exists(path)) return "";
        // forge-lint: disable-next-line(unsafe-cheatcode)
        return vm.readFile(path);
    }

    function _recordAddress(string memory record, string memory key) internal view returns (address) {
        if (bytes(record).length == 0 || !vm.keyExistsJson(record, key)) return address(0);
        return vm.parseJsonAddress(record, key);
    }
}
