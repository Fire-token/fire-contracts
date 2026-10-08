// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {console} from "forge-std/console.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {FireMerkleDistributor} from "../src/FireMerkleDistributor.sol";
import {GuardedScript} from "./lib/GuardedScript.sol";

/**
 * @title DeployAirdrop (에어드롭 회차 배포 + 예치)
 * @notice 에어드롭 전용 지갑(브로드캐스터)이 FireMerkleDistributor를 배포하고 merkle.json의 total만큼 FIRE를 예치함.
 * @dev 메인넷 브로드캐스터는 토큰 배포자 지갑이 아니라 5,000만 FIRE를 보관하는 에어드롭 전용 지갑이어야 함
 *      (가이드 2.2절·4장 Step 8). 회차마다 한 번씩 실행함 (1차 2,000만 / 2차 3,000만 + 1차 미청구 이월분).
 *
 *      환경 변수 (빈 문자열은 미설정으로 취급). 주소는 EIP-55 체크섬 표기 그대로 붙여 넣을 것: 대소문자 한 글자
 *      오타는 모든 체인에서 거부하고, Base 메인넷에서는 체크섬이 없는(전부 소문자) 주소도 거부함 (LaunchGuards).
 *        FIRE_TOKEN               FIRE 토큰 주소. 비우면 배포 기록 deployments/<chainId>.json의 contracts.FireToken.
 *                                 둘 다 있는데 서로 다르면 모든 체인에서 중단. 기록이 없는 테스트넷·로컬에서는 필수.
 *        AIRDROP_MERKLE_JSON      (필수) airdrop/generate.mjs가 만든 merkle.json 경로. 프로젝트 루트 기준이며
 *                                 foundry.toml fs_permissions상 ./airdrop/out 또는 ./test/fixtures 하위를 읽음
 *        AIRDROP_WALLET           (메인넷 필수) 에어드롭 전용 지갑. 설정하면 모든 체인에서 브로드캐스터와 같아야 함
 *        AIRDROP_EXPECTED_ROOT    (메인넷 필수) GitHub에 공개한 Merkle Root. 설정하면 merkle.json root와 같아야 함
 *        AIRDROP_CLAIM_DAYS       (선택) 클레임 기간(일), 기본 90, 허용 1~365
 *        AIRDROP_SWEEP_RECIPIENT  (선택) 기한 후 미청구분 회수 주소, 기본 = 브로드캐스터(에어드롭 지갑)
 *        CONFIRM_MAINNET          (메인넷 필수) Base 메인넷(8453)에서는 "I_UNDERSTAND"
 *
 *      실행 예 (Base Sepolia 리허설, 하드웨어 지갑). 먼저 전송 플래그 없이 시뮬레이션해 로그를 확인하고, 전송할 때는
 *      반드시 --slow를 붙임 (배포 성공 영수증을 확인한 뒤에만 예치 트랜잭션을 보냄):
 *        forge script script/DeployAirdrop.s.sol:DeployAirdrop --rpc-url base_sepolia \
 *          --ledger --sender <에어드롭 지갑> --broadcast --slow --verify
 *      전송 도중 실패하면 같은 명령을 다시 실행하지 말고 --resume으로 남은 트랜잭션만 보냄.
 *
 *      클레임 마감 = 시뮬레이션 시점 block.timestamp + AIRDROP_CLAIM_DAYS일 (정확한 값은 로그로 출력되며 공개해야 함).
 *
 *      안전장치
 *        - 스크립트 실행 중에는 RPC의 eth_chainId가 시뮬레이션 체인과 같아야 함: --chain / FOUNDRY_CHAIN_ID로
 *          메인넷 RPC를 테스트넷으로 위장해 메인넷 가드를 건너뛰는 것을 막음. --rpc-url만 사용할 것.
 *        - Base 메인넷은 Deploy가 쓴 런칭 기록(deployments/8453.json)이 반드시 있어야 하고, FIRE_TOKEN은 기록의
 *          contracts.FireToken(= CREATE(deployer, deployerNonce + 1)), AIRDROP_WALLET은 기록의 wallets.airdropWallet과
 *          같아야 함. 이름·심볼·바이트코드가 같은 복제 토큰(주소 오염)으로 회차를 집행하는 사고 방지.
 *        - 토큰 확인: 코드, 심볼 FIRE, decimals 18, FireToken 고유 상수(TOTAL_SUPPLY 10억, VESTING_SUPPLY 2억).
 *        - merkle.json은 헤더(첫 7줄: round·root·total·totalFire·count)만 스트리밍으로 읽음 → 수령자 수와 무관한 가스.
 *          수령자 목록의 내용 검증은 airdrop/verify.mjs의 몫이며, 메인넷에서는 공개 root(AIRDROP_EXPECTED_ROOT)와
 *          일치해야 배포함. 샘플 목록(SAMPLE_MERKLE_ROOT)은 경로와 무관하게 메인넷에서 거부함.
 *        - 같은 지갑이 같은 토큰·같은 root로 이미 배포한 분배 컨트랙트가 체인에 있으면 거부함 (재실행·이전 회차 파일
 *          재사용으로 같은 목록에 두 번 지급하는 사고 방지).
 *        - 배포 전에 예측 가능한 배포 주소로 누군가 FIRE를 보내 두었어도 막히지 않음: 그 잔액(preexisting)을 더해
 *          정확히 total만 예치됐는지 확인하고, 초과분은 마감 후 sweep으로 회수됨.
 *        - 모든 확인은 forge의 시뮬레이션 단계에서 평가됨. 실패하면 아무 트랜잭션도 전송하지 않음.
 *          단, 전송 후의 온체인 결과는 시뮬레이션이 보장하지 않으므로 cast code·balanceOf로 다시 확인해야 함.
 */
contract DeployAirdrop is GuardedScript {
    using SafeERC20 for IERC20;

    uint256 public constant DEFAULT_CLAIM_DAYS = 90;
    /// @dev FireMerkleDistributor.MAX_CLAIM_PERIOD(365일)와 같아야 함 (테스트로 고정)
    uint256 public constant MAX_CLAIM_DAYS = 365;
    uint256 public constant BASE_MAINNET_CHAIN_ID = 8453;
    uint256 public constant BASE_SEPOLIA_CHAIN_ID = 84532;
    uint256 public constant LOCAL_CHAIN_ID = 31337;
    string public constant MAINNET_CONFIRMATION = "I_UNDERSTAND";
    /// @dev FIRE 총 발행량. merkle.json total의 상한이자 FireToken.TOTAL_SUPPLY() 기대값
    uint256 public constant FIRE_TOTAL_SUPPLY = 1_000_000_000e18;
    /// @dev FireToken.VESTING_SUPPLY() 기대값 (개발자 지분 2억)
    uint256 public constant FIRE_VESTING_SUPPLY = 200_000_000e18;
    /// @dev 에어드롭 지갑 배정량 (가이드 2.2절). 브로드캐스터 잔액이 이보다 많으면 배포자 지갑일 가능성을 경고함
    uint256 public constant AIRDROP_ALLOCATION = 50_000_000e18;
    /// @dev 이전 배포 검사 범위: 브로드캐스터의 최근 nonce 개수 (에어드롭 전용 지갑은 nonce가 매우 작음)
    uint256 public constant MAX_NONCES_SCANNED = 256;
    /// @dev airdrop/sample.csv(개인 키 없는 테스트 주소)로 만든 test/fixtures/airdrop-sample.json의 root.
    ///      경로를 어떻게 적든(복사본 포함) 메인넷 배포를 거부함. 픽스처가 바뀌면 테스트가 실패해 갱신을 강제함.
    bytes32 public constant SAMPLE_MERKLE_ROOT = 0xdc689dd4b907a53b68728da0ddd42751e91de97aa7e5b4bf29ded18d938c7f2a;

    /// @dev generate.mjs가 쓰는 merkle.json 레이아웃: 1행 "{", 2~6행 헤더 필드(쉼표로 끝남), 7행 claims 시작
    uint256 private constant HEADER_FIELD_COUNT = 5;
    string private constant HEADER_CLAIMS_LINE = '  "claims": {';

    struct Params {
        address token;
        string merkleJsonPath;
        uint256 claimDays;
        address sweepRecipient; // address(0)이면 브로드캐스터
        address airdropWallet; // AIRDROP_WALLET, address(0)이면 미설정
        bytes32 expectedRoot; // AIRDROP_EXPECTED_ROOT, bytes32(0)이면 미설정
        string confirmMainnet;
    }

    struct MerkleInfo {
        uint256 round;
        bytes32 root;
        uint256 total;
        string totalFire;
        uint256 count;
    }

    struct Deployment {
        FireMerkleDistributor distributor;
        address broadcaster;
        address sweepRecipient;
        uint64 claimDeadline;
        uint256 preexisting; // 배포 전부터 배포 주소에 있던 FIRE (마감 후 sweep으로 회수)
    }

    error DeployAirdropUnsupportedChain(uint256 chainId);
    error DeployAirdropMainnetNotConfirmed();
    error DeployAirdropMissingEnv(string name);
    error DeployAirdropSampleListOnMainnet(bytes32 root);
    error DeployAirdropUnexpectedRoot(bytes32 root, bytes32 expectedRoot);
    error DeployAirdropInvalidToken(address token);
    error DeployAirdropInvalidClaimDays(uint256 claimDays);
    error DeployAirdropMerkleJsonNotFound(string merkleJsonPath);
    error DeployAirdropInvalidMerkleJson(string merkleJsonPath, string reason);
    error DeployAirdropBroadcasterNotAirdropWallet(address broadcaster, address airdropWallet);
    error DeployAirdropInvalidSweepRecipient(address sweepRecipient);
    error DeployAirdropRootAlreadyDeployed(address existingDistributor);
    error DeployAirdropInsufficientBalance(address broadcaster, uint256 balance, uint256 required);
    error DeployAirdropFundingMismatch(uint256 distributorBalance, uint256 expected);
    error DeployAirdropBroadcasterBalanceMismatch(uint256 balance, uint256 expected);
    error DeployAirdropLaunchRecordRequired(string recordPath);
    error DeployAirdropRecordMismatch(string name, address given, address recorded);

    // ───────────────────────── 진입점 ─────────────────────────

    function run() external returns (FireMerkleDistributor distributor) {
        distributor = deploy(paramsFromEnv(), _broadcaster());
    }

    /// @notice 환경 변수(+ 배포 기록) → Params. FIRE_TOKEN이 비어 있으면 기록의 contracts.FireToken.
    function paramsFromEnv() public view returns (Params memory params) {
        address recordToken = _recordAddress(_readDeploymentRecord(), ".contracts.FireToken");
        params.token = _envAddressOr("FIRE_TOKEN", recordToken);
        if (params.token == address(0)) revert DeployAirdropMissingEnv("FIRE_TOKEN");
        if (recordToken != address(0) && params.token != recordToken) {
            revert DeployAirdropRecordMismatch("FIRE_TOKEN", params.token, recordToken);
        }
        params.merkleJsonPath = _envStringRequired("AIRDROP_MERKLE_JSON");
        params.claimDays = _envUintOr("AIRDROP_CLAIM_DAYS", DEFAULT_CLAIM_DAYS);
        params.sweepRecipient = _envAddressOr("AIRDROP_SWEEP_RECIPIENT", address(0));
        params.airdropWallet = _envAddressOr("AIRDROP_WALLET", address(0));
        params.expectedRoot = _envBytes32Or("AIRDROP_EXPECTED_ROOT", bytes32(0));
        params.confirmMainnet = _envString("CONFIRM_MAINNET");
    }

    /**
     * @notice 검증 → 배포 → 예치 → 사후 확인 → 로그. broadcaster가 배포·예치 트랜잭션 2건을 서명함.
     * @dev 확인이 하나라도 실패하면 forge script는 시뮬레이션 단계에서 중단되어 아무 트랜잭션도 전송하지 않음.
     */
    function deploy(Params memory params, address broadcaster) public returns (FireMerkleDistributor) {
        _checkChain(params);
        _checkLaunchRecord(params);
        _checkToken(params.token);
        MerkleInfo memory info = readMerkleJson(params.merkleJsonPath);
        _checkMerkleContent(params, info);
        if (params.claimDays == 0 || params.claimDays > MAX_CLAIM_DAYS) {
            revert DeployAirdropInvalidClaimDays(params.claimDays);
        }
        _checkBroadcaster(params, broadcaster);
        _checkPreviousDeployments(params.token, info.root, broadcaster);

        Deployment memory d;
        d.broadcaster = broadcaster;
        d.sweepRecipient = params.sweepRecipient == address(0) ? broadcaster : params.sweepRecipient;
        if (d.sweepRecipient == params.token) revert DeployAirdropInvalidSweepRecipient(d.sweepRecipient);
        d.claimDeadline = SafeCast.toUint64(block.timestamp + params.claimDays * 1 days);

        IERC20 token = IERC20(params.token);
        uint256 balanceBefore = token.balanceOf(broadcaster);
        if (balanceBefore < info.total) {
            revert DeployAirdropInsufficientBalance(broadcaster, balanceBefore, info.total);
        }

        // 트랜잭션 1: 배포
        vm.startBroadcast(broadcaster);
        d.distributor = new FireMerkleDistributor(token, info.root, d.claimDeadline, d.sweepRecipient);
        vm.stopBroadcast();
        // 배포 주소는 (지갑, nonce)로 예측 가능하므로 배포 전에 누구나 FIRE를 보내 둘 수 있음. 이 잔액은 막지 않고
        // 기록만 함 (마감 후 sweep으로 회수됨)
        d.preexisting = token.balanceOf(address(d.distributor));

        // 트랜잭션 2: 예치 (정확히 total)
        vm.startBroadcast(broadcaster);
        token.safeTransfer(address(d.distributor), info.total);
        vm.stopBroadcast();

        uint256 funded = token.balanceOf(address(d.distributor));
        if (funded != d.preexisting + info.total) {
            revert DeployAirdropFundingMismatch(funded, d.preexisting + info.total);
        }
        uint256 balanceAfter = token.balanceOf(broadcaster);
        if (balanceAfter != balanceBefore - info.total) {
            revert DeployAirdropBroadcasterBalanceMismatch(balanceAfter, balanceBefore - info.total);
        }

        _logSummary(params, info, d);
        return d.distributor;
    }

    // ───────────────────────── merkle.json 헤더 ─────────────────────────

    /**
     * @notice merkle.json의 헤더(round·root·total·totalFire·count)만 읽고 검증함.
     * @dev 파일 전체를 EVM 메모리로 읽으면 메모리 비용이 크기의 제곱으로 늘어 수천 명 규모에서 가스가 부족해짐.
     *      그래서 generate.mjs의 고정 레이아웃(첫 7줄)만 vm.readLine으로 읽음. 수정·재포맷한 파일은 거부함.
     *      claims(목록 본문)와 root·total의 일치는 airdrop/verify.mjs가 검증함.
     */
    function readMerkleJson(string memory merkleJsonPath) public returns (MerkleInfo memory info) {
        if (!vm.exists(merkleJsonPath)) revert DeployAirdropMerkleJsonNotFound(merkleJsonPath);
        string memory header = _readHeader(merkleJsonPath);

        try vm.parseJsonKeys(header, "$") returns (string[] memory keys) {
            if (!_isExpectedHeaderKeys(keys)) revert DeployAirdropInvalidMerkleJson(merkleJsonPath, "header");
        } catch {
            revert DeployAirdropInvalidMerkleJson(merkleJsonPath, "header");
        }
        info.round = vm.parseJsonUint(header, ".round");
        info.root = vm.parseJsonBytes32(header, ".root");
        info.total = vm.parseJsonUint(header, ".total");
        info.totalFire = vm.parseJsonString(header, ".totalFire");
        info.count = vm.parseJsonUint(header, ".count");

        if (info.round == 0) revert DeployAirdropInvalidMerkleJson(merkleJsonPath, "round");
        if (info.root == bytes32(0)) revert DeployAirdropInvalidMerkleJson(merkleJsonPath, "root");
        if (info.total == 0 || info.total > FIRE_TOTAL_SUPPLY) {
            revert DeployAirdropInvalidMerkleJson(merkleJsonPath, "total");
        }
        // generate.mjs는 total(wei)과 totalFire(FIRE)를 항상 함께 씀. 한쪽만 고친 파일을 거부함
        if (!_sameString(info.totalFire, _formatFire(info.total))) {
            revert DeployAirdropInvalidMerkleJson(merkleJsonPath, "totalFire");
        }
        if (info.count == 0) revert DeployAirdropInvalidMerkleJson(merkleJsonPath, "count");
    }

    /// @dev 첫 7줄을 읽어 헤더 필드만 담은 JSON 객체 문자열로 만듦. 레이아웃이 다르면 되돌림.
    ///      읽기 전용 파일 접근이며 경로는 foundry.toml fs_permissions(airdrop/out, test/fixtures 등)로 제한됨.
    // forge-lint: disable-next-item(unsafe-cheatcode)
    function _readHeader(string memory merkleJsonPath) private returns (string memory) {
        vm.closeFile(merkleJsonPath); // 같은 파일을 앞서 읽었더라도 처음부터 읽도록 초기화
        bool layoutOk = _sameString(vm.readLine(merkleJsonPath), "{");
        bytes memory fields = "{";
        for (uint256 i = 1; layoutOk && i <= HEADER_FIELD_COUNT; ++i) {
            bytes memory line = bytes(vm.readLine(merkleJsonPath));
            if (line.length == 0 || line[line.length - 1] != ",") {
                layoutOk = false;
            } else {
                // 마지막 필드의 쉼표는 객체를 닫기 위해 제거
                fields = bytes.concat(fields, i == HEADER_FIELD_COUNT ? _withoutLastByte(line) : line);
            }
        }
        layoutOk = layoutOk && _sameString(vm.readLine(merkleJsonPath), HEADER_CLAIMS_LINE);
        vm.closeFile(merkleJsonPath);
        if (!layoutOk) revert DeployAirdropInvalidMerkleJson(merkleJsonPath, "layout");
        return string(bytes.concat(fields, "}"));
    }

    function _isExpectedHeaderKeys(string[] memory keys) private pure returns (bool) {
        return keys.length == HEADER_FIELD_COUNT && _sameString(keys[0], "round") && _sameString(keys[1], "root")
            && _sameString(keys[2], "total") && _sameString(keys[3], "totalFire") && _sameString(keys[4], "count");
    }

    // ───────────────────────── 가드 ─────────────────────────

    /// @dev 지원 체인 → RPC 체인 ID 대조(LaunchGuards) → 메인넷 확인 문구 순서.
    function _checkChain(Params memory params) internal {
        uint256 chainId = block.chainid;
        if (chainId != BASE_MAINNET_CHAIN_ID && chainId != BASE_SEPOLIA_CHAIN_ID && chainId != LOCAL_CHAIN_ID) {
            revert DeployAirdropUnsupportedChain(chainId);
        }
        _requireRpcChainMatches();
        if (chainId == BASE_MAINNET_CHAIN_ID && !_sameString(params.confirmMainnet, MAINNET_CONFIRMATION)) {
            revert DeployAirdropMainnetNotConfirmed();
        }
    }

    /**
     * @dev 런칭 기록 대조: 기록에 토큰이 있으면 모든 체인에서 같은 토큰이어야 함. Base 메인넷은 Deploy 기록(deployer·
     *      deployerNonce·wallets.airdropWallet 포함)이 반드시 있어야 하고, 기록의 토큰이 CREATE(deployer, deployerNonce + 1)
     *      이며 AIRDROP_WALLET이 기록의 에어드롭 지갑과 같아야 함.
     */
    function _checkLaunchRecord(Params memory params) internal view {
        string memory record = _readDeploymentRecord();
        address recordToken = _recordAddress(record, ".contracts.FireToken");
        if (recordToken != address(0) && params.token != recordToken) {
            revert DeployAirdropRecordMismatch("FIRE_TOKEN", params.token, recordToken);
        }
        if (block.chainid != BASE_MAINNET_CHAIN_ID) return;
        address deployer = _recordAddress(record, ".deployer");
        address recordWallet = _recordAddress(record, ".wallets.airdropWallet");
        if (recordToken == address(0) || deployer == address(0) || recordWallet == address(0)) {
            revert DeployAirdropLaunchRecordRequired(_deploymentRecordPath());
        }
        if (!vm.keyExistsJson(record, ".deployerNonce")) {
            revert DeployAirdropLaunchRecordRequired(_deploymentRecordPath());
        }
        uint256 deployerNonce = vm.parseJsonUint(record, ".deployerNonce");
        if (recordToken != vm.computeCreateAddress(deployer, deployerNonce + 1)) {
            revert DeployAirdropRecordMismatch(
                "contracts.FireToken", recordToken, vm.computeCreateAddress(deployer, deployerNonce + 1)
            );
        }
        if (params.airdropWallet != address(0) && params.airdropWallet != recordWallet) {
            revert DeployAirdropRecordMismatch("AIRDROP_WALLET", params.airdropWallet, recordWallet);
        }
    }

    /// @dev 토큰 확인: 코드, 심볼 FIRE, decimals 18, FireToken 고유 상수 (이름만 흉내 낸 토큰 거부).
    function _checkToken(address token) internal view {
        if (token.code.length == 0) revert DeployAirdropInvalidToken(token);
        if (!_sameString(IERC20Metadata(token).symbol(), "FIRE")) revert DeployAirdropInvalidToken(token);
        if (IERC20Metadata(token).decimals() != 18) revert DeployAirdropInvalidToken(token);
        bool constantsOk = _readWord(token, bytes4(keccak256("TOTAL_SUPPLY()"))) == FIRE_TOTAL_SUPPLY
            && _readWord(token, bytes4(keccak256("VESTING_SUPPLY()"))) == FIRE_VESTING_SUPPLY;
        if (!constantsOk) revert DeployAirdropInvalidToken(token);
    }

    /// @dev 내용 기준 확인: 공개 root와의 일치(메인넷 필수), 샘플 목록의 메인넷 배포 차단 (경로 표기와 무관)
    function _checkMerkleContent(Params memory params, MerkleInfo memory info) internal view {
        if (block.chainid == BASE_MAINNET_CHAIN_ID) {
            if (info.root == SAMPLE_MERKLE_ROOT) revert DeployAirdropSampleListOnMainnet(info.root);
            if (params.expectedRoot == bytes32(0)) revert DeployAirdropMissingEnv("AIRDROP_EXPECTED_ROOT");
        }
        if (params.expectedRoot != bytes32(0) && params.expectedRoot != info.root) {
            revert DeployAirdropUnexpectedRoot(info.root, params.expectedRoot);
        }
    }

    /// @dev 브로드캐스터 = 에어드롭 전용 지갑 확인 (가이드 2.4절: 예치·회수는 에어드롭 지갑만)
    function _checkBroadcaster(Params memory params, address broadcaster) internal view {
        if (params.airdropWallet == address(0)) {
            if (block.chainid == BASE_MAINNET_CHAIN_ID) revert DeployAirdropMissingEnv("AIRDROP_WALLET");
            console.log(
                unicode"주의: AIRDROP_WALLET 미설정 - 브로드캐스터가 에어드롭 전용 지갑인지 확인하지 않았습니다."
            );
        } else if (broadcaster != params.airdropWallet) {
            revert DeployAirdropBroadcasterNotAirdropWallet(broadcaster, params.airdropWallet);
        }
        if (IERC20(params.token).balanceOf(broadcaster) > AIRDROP_ALLOCATION) {
            console.log(
                unicode"주의: 브로드캐스터 잔액이 에어드롭 배정량(5,000만 FIRE)보다 많습니다. 토큰 배포자 지갑이 아닌지 확인하십시오."
            );
        }
    }

    /**
     * @dev 같은 지갑이 같은 토큰·같은 root로 배포한 분배 컨트랙트가 이미 있으면 거부함. 같은 root의 컨트랙트가 둘이면
     *      목록의 모든 주소가 양쪽에서 한 번씩 청구할 수 있음 (이중 지급, 되돌릴 수 없음). 로컬 기록 파일이 아니라
     *      체인 상태(브로드캐스터의 과거 CREATE 주소)를 보므로 다른 PC에서 실행해도, 기한·sweep 이후에도 유효함.
     *      root가 다른 이전 컨트랙트가 아직 클레임 기간 중이면 경고만 함 (두 목록에 모두 있는 주소는 양쪽에서 수령).
     */
    function _checkPreviousDeployments(address token, bytes32 root, address broadcaster) internal view {
        uint256 nonce = vm.getNonce(broadcaster);
        uint256 first = nonce > MAX_NONCES_SCANNED ? nonce - MAX_NONCES_SCANNED : 0;
        for (uint256 n = first; n < nonce; ++n) {
            address previous = vm.computeCreateAddress(broadcaster, n);
            if (previous.code.length == 0) continue;
            if (_readWord(previous, FireMerkleDistributor(previous).TOKEN.selector) != uint256(uint160(token))) {
                continue;
            }
            if (bytes32(_readWord(previous, FireMerkleDistributor(previous).MERKLE_ROOT.selector)) == root) {
                revert DeployAirdropRootAlreadyDeployed(previous);
            }
            // forge-lint: disable-next-line(block-timestamp)
            if (_readWord(previous, FireMerkleDistributor(previous).CLAIM_DEADLINE.selector) >= block.timestamp) {
                console.log(
                    unicode"주의: 이 지갑이 배포한 다른 분배 컨트랙트가 아직 클레임 기간 중입니다:",
                    previous
                );
            }
        }
        if (first > 0) {
            console.log(
                unicode"주의: 브로드캐스터의 최근 nonce만 검사했습니다 (개수):", MAX_NONCES_SCANNED
            );
        }
    }

    /// @dev 인자 없는 view 함수의 32바이트 반환값. 실패하거나 형식이 다르면 0
    function _readWord(address target, bytes4 selector) private view returns (uint256 word) {
        (bool ok, bytes memory data) = target.staticcall(abi.encodeWithSelector(selector));
        if (ok && data.length == 32) word = abi.decode(data, (uint256));
    }

    // ───────────────────────── 배포 기록 (테스트 하네스가 재정의하는 지점) ─────────────────────────

    /// @notice 런칭 배포 기록 경로: deployments/<chainId>.json (script/Deploy.s.sol이 작성, fs_permissions 범위).
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

    // ───────────────────────── 환경 변수 ─────────────────────────
    // _envString(테스트가 재정의하는 단일 입력 지점) / _envAddressOr / _envUintOr는 GuardedScript.

    function _envStringRequired(string memory name) internal view returns (string memory value) {
        value = _envString(name);
        if (bytes(value).length == 0) revert DeployAirdropMissingEnv(name);
    }

    function _envBytes32Or(string memory name, bytes32 defaultValue) internal view returns (bytes32) {
        string memory raw = _envString(name);
        return bytes(raw).length == 0 ? defaultValue : vm.parseBytes32(raw);
    }

    /// @dev 현재 forge script의 서명 지갑(--ledger/--account/--private-key 또는 --sender) 주소
    function _broadcaster() internal returns (address broadcaster) {
        vm.startBroadcast();
        (, broadcaster,) = vm.readCallers();
        vm.stopBroadcast();
    }

    // ───────────────────────── 로그 ─────────────────────────

    function _logSummary(Params memory params, MerkleInfo memory info, Deployment memory d) internal view {
        console.log(
            _isBroadcastRun()
                ? unicode"== FIRE 에어드롭 배포 + 예치: 시뮬레이션 통과, 트랜잭션 2건 전송 (온체인 결과는 아래 2번으로 확인) =="
                : unicode"== FIRE 에어드롭 배포 + 예치 시뮬레이션 (아직 아무 트랜잭션도 전송하지 않음) =="
        );
        console.log(unicode"체인 ID                    :", block.chainid);
        console.log(unicode"회차 (round)               :", info.round);
        console.log(unicode"merkle.json                :", params.merkleJsonPath);
        console.log(unicode"Merkle Root                :", vm.toString(info.root));
        console.log(unicode"수령자 수 (count)          :", info.count);
        console.log(unicode"예치량 (FIRE)              :", info.totalFire);
        console.log(unicode"예치량 (wei)               :", info.total);
        console.log(unicode"FireMerkleDistributor      :", address(d.distributor));
        console.log(unicode"FIRE 토큰                  :", params.token);
        console.log(unicode"브로드캐스터               :", d.broadcaster);
        console.log(
            unicode"AIRDROP_WALLET 일치        :",
            params.airdropWallet == address(0) ? unicode"확인 안 함 (미설정)" : unicode"일치"
        );
        console.log(unicode"미청구분 회수 주소         :", d.sweepRecipient);
        console.log(unicode"클레임 마감 (unix, 포함)   :", uint256(d.claimDeadline));
        console.log(
            unicode"생성자 인자 (검증용)       :",
            vm.toString(abi.encode(params.token, info.root, d.claimDeadline, d.sweepRecipient))
        );
        if (d.preexisting > 0) {
            console.log(
                unicode"주의: 배포 전부터 배포 주소에 있던 FIRE (wei, 마감 후 sweep으로 회수):",
                d.preexisting
            );
        }
        if (d.sweepRecipient != d.broadcaster) {
            console.log(
                unicode"주의: 회수 주소가 브로드캐스터와 다릅니다. 에어드롭 전용 지갑이 맞는지 확인하십시오."
            );
        }
        _logNextSteps(params, d);
    }

    function _logNextSteps(Params memory params, Deployment memory d) internal view {
        string memory rpc = block.chainid == BASE_MAINNET_CHAIN_ID
            ? "base"
            : block.chainid == BASE_SEPOLIA_CHAIN_ID ? "base_sepolia" : "http://127.0.0.1:8545";
        string memory distributor = vm.toString(address(d.distributor));
        console.log("");
        console.log(unicode"다음 단계:");
        console.log(
            unicode" 1. 시뮬레이션이었다면 같은 명령에 --broadcast --slow 를 붙여 전송 (--slow: 배포 성공을 확인한 뒤에만 예치)."
        );
        console.log(
            unicode"    전송 도중 실패하면 명령을 다시 실행하지 말고 --resume 으로 남은 트랜잭션만 보냄."
        );
        console.log(
            string.concat(
                unicode" 2. 온체인 확인 (공지 전 필수): cast code ",
                distributor,
                " --rpc-url ",
                rpc,
                unicode" (코드가 있어야 함), cast call ",
                vm.toString(params.token),
                ' "balanceOf(address)(uint256)" ',
                distributor,
                " --rpc-url ",
                rpc,
                unicode" (예치량 이상이어야 함)"
            )
        );
        console.log(
            string.concat(
                unicode" 3. 마감 시각 확인 (UTC/KST로 공지): date -u -d @$(cast call ",
                distributor,
                ' "CLAIM_DEADLINE()(uint64)" --rpc-url ',
                rpc,
                unicode" | cut -d' ' -f1)   (KST: TZ=Asia/Seoul date -d @<같은 값>)"
            )
        );
        console.log(
            unicode" 4. BaseScan 소스 검증 (--verify 미사용 시): forge verify-contract <배포 주소> "
            unicode"src/FireMerkleDistributor.sol:FireMerkleDistributor --chain <base|base-sepolia> "
            unicode"--constructor-args <위 생성자 인자>"
        );
        console.log(
            unicode" 5. 배포 주소·Merkle Root·마감 시각·배포/예치 트랜잭션 해시를 GitHub README와 공식 채널에 공개"
        );
        console.log(
            unicode" 6. merkle.json을 클레임 안내에 게시: claim(account, amount, proof) 호출 (누구나 대신 제출 가능)"
        );
        console.log(
            unicode" 7. 마감 이후 누구나 sweep() 호출 → 미청구분이 회수 주소로 반환 → 회수량 공개 후 다음 회차로 이월"
        );
    }

    // ───────────────────────── 보조 함수 ─────────────────────────

    /// @dev wei → "1234.5" 형태의 FIRE 10진 문자열 (generate.mjs의 totalFire와 같은 표기)
    function _formatFire(uint256 amount) internal pure returns (string memory) {
        string memory whole = vm.toString(amount / 1e18);
        uint256 fraction = amount % 1e18;
        if (fraction == 0) return whole;
        bytes memory digits = new bytes(18);
        for (uint256 i = 18; i > 0; --i) {
            digits[i - 1] = bytes1(uint8(48 + fraction % 10));
            fraction /= 10;
        }
        uint256 length = 18;
        while (digits[length - 1] == "0") {
            --length;
        }
        bytes memory trimmed = new bytes(length);
        for (uint256 i; i < length; ++i) {
            trimmed[i] = digits[i];
        }
        return string.concat(whole, ".", string(trimmed));
    }

    function _withoutLastByte(bytes memory data) private pure returns (bytes memory out) {
        out = new bytes(data.length - 1);
        for (uint256 i; i < out.length; ++i) {
            out[i] = data[i];
        }
    }
}
