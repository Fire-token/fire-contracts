// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {FireToken} from "../src/FireToken.sol";
import {FireVesting} from "../src/FireVesting.sol";
import {Deploy} from "../script/Deploy.s.sol";
import {CreatePool} from "../script/CreatePool.s.sol";
import {PostDeployCheck} from "../script/PostDeployCheck.s.sol";
import {ControlProof} from "../script/lib/ControlProof.sol";
import {GuardedScript} from "../script/lib/GuardedScript.sol";
import {LaunchBase} from "../script/lib/LaunchBase.sol";
import {LaunchCode} from "../script/lib/LaunchCode.sol";
import {LaunchGuards} from "../script/lib/LaunchGuards.sol";
import {LaunchParams} from "../script/lib/LaunchParams.sol";
import {LaunchPositions} from "../script/lib/LaunchPositions.sol";
import {PoolMath} from "../script/lib/PoolMath.sol";
import {UniswapV3Addresses} from "../script/lib/UniswapV3Addresses.sol";

// ───────────────────────── 테스트 보조 컨트랙트 (Deploy 접두사) ─────────────────────────

/// @dev getThreshold/getOwners/getModulesPaginated만 흉내 낸 Safe (setModule로 모듈 1개를 활성화한 상태도 흉내 냄).
contract DeployMockSafe {
    uint256 private immutable _threshold;
    address[] private _owners;
    address public module;

    constructor(uint256 threshold_, address[] memory owners_) {
        _threshold = threshold_;
        _owners = owners_;
    }

    function setModule(address module_) external {
        module = module_;
    }

    function getThreshold() external view returns (uint256) {
        return _threshold;
    }

    function getOwners() external view returns (address[] memory) {
        return _owners;
    }

    /// @dev Safe ModuleManager와 같은 반환 형식 (page, next). 모듈이 없으면 빈 배열 + SENTINEL(0x1).
    function getModulesPaginated(address, uint256) external view returns (address[] memory page, address next) {
        if (module == address(0)) return (new address[](0), address(0x1));
        page = new address[](1);
        page[0] = module;
        next = address(0x1);
    }
}

/// @dev getThreshold/getOwners만 있고 getModulesPaginated가 없는 Safe 대역 (모듈 상태를 확인할 수 없음).
contract DeployLegacySafe {
    function getThreshold() external pure returns (uint256) {
        return 2;
    }

    function getOwners() external pure returns (address[] memory owners) {
        owners = new address[](3);
        owners[0] = address(0x5AFE01);
        owners[1] = address(0x5AFE02);
        owners[2] = address(0x5AFE03);
    }
}

/// @dev getModulesPaginated에 형식이 틀린 값을 돌려주는 컨트랙트 (mode 0: revert, 1: 64바이트, 2: 오프셋 0x20,
///      3: 배열 길이가 반환 데이터보다 큼). LaunchGuards.safeHasModules가 revert 없이 ok=false를 돌려주는지 확인.
contract DeployBadModules {
    uint256 private immutable _MODE;

    constructor(uint256 mode) {
        _MODE = mode;
    }

    fallback() external {
        uint256 mode = _MODE;
        assembly ("memory-safe") {
            if eq(mode, 0) { revert(0, 0) }
            mstore(0, 0x40)
            mstore(0x20, 1)
            mstore(0x40, 5)
            if eq(mode, 1) { return(0, 0x40) }
            if eq(mode, 2) {
                mstore(0, 0x20)
                return(0, 0x60)
            }
            return(0, 0x60)
        }
    }
}

/// @dev getOwners()가 주소 범위를 넘는 값(2^200)을 담아 돌려주는 Safe 대역 (형식은 맞아 probeSafe는 Safe로 봄).
contract DeployDirtyOwners {
    function getThreshold() external pure returns (uint256) {
        return 1;
    }

    fallback() external {
        assembly ("memory-safe") {
            mstore(0, 0x20)
            mstore(0x20, 1)
            mstore(0x40, shl(200, 1))
            return(0, 0x60)
        }
    }
}

/// @dev start()만 원하는 값으로 응답하는 컨트랙트 (LaunchCode.vestingStatus의 범위 검사).
contract DeployFakeStart {
    uint256 public immutable start;

    constructor(uint256 start_) {
        start = start_;
    }
}

/// @dev 코드는 있지만 Safe가 아닌 컨트랙트.
contract DeployNotASafe {
    uint256 public value;
}

/// @dev 어떤 호출에도 빈 값으로 성공하는 컨트랙트 (ABI 디코딩 실패 유도용).
contract DeploySilentFallback {
    fallback() external {}
}

/// @dev 저장소를 쓰지 않는 Safe 대역: EIP-7702 위임 대상으로 써도 같은 값(임계값·소유자 수)을 응답함.
contract DeployConstantSafe {
    uint256 private immutable _THRESHOLD;
    uint256 private immutable _OWNER_COUNT;

    constructor(uint256 threshold, uint256 ownerCount) {
        _THRESHOLD = threshold;
        _OWNER_COUNT = ownerCount;
    }

    function getThreshold() external view returns (uint256) {
        return _THRESHOLD;
    }

    function getOwners() external view returns (address[] memory owners) {
        owners = new address[](_OWNER_COUNT);
        for (uint256 i; i < _OWNER_COUNT; ++i) {
            owners[i] = address(uint160(0x5AFE0000 + i + 1));
        }
    }

    function getModulesPaginated(address, uint256) external pure returns (address[] memory, address) {
        return (new address[](0), address(0x1));
    }
}

/// @dev getThreshold()는 정상이지만 getOwners()가 형식이 틀린 값을 돌려주는 컨트랙트 (probeSafe가 revert하지 않는지).
///      returnSize는 반환 바이트 수(0x40 = 오프셋·길이 두 워드, 0x20 = 한 워드만).
contract DeployMalformedOwners {
    uint256 private immutable _OFFSET;
    uint256 private immutable _LENGTH;
    uint256 private immutable _RETURN_SIZE;

    constructor(uint256 offset, uint256 length, uint256 returnSize) {
        _OFFSET = offset;
        _LENGTH = length;
        _RETURN_SIZE = returnSize;
    }

    function getThreshold() external pure returns (uint256) {
        return 2;
    }

    fallback() external {
        uint256 offset = _OFFSET;
        uint256 length = _LENGTH;
        uint256 size = _RETURN_SIZE;
        assembly ("memory-safe") {
            mstore(0, offset)
            mstore(0x20, length)
            return(0, size)
        }
    }
}

/**
 * @dev 프로세스 전역 환경 변수 대신 저장소 맵에서 값을 읽게 하는 믹스인.
 *      forge는 테스트를 병렬 실행하므로 vm.setEnv는 다른 테스트(다른 컴포넌트 포함)와 경쟁 상태를 만든다.
 *      같은 이유로 기록 경로·실행 문맥(--broadcast 여부)·RPC 체인 ID도 주입할 수 있게 함.
 */
abstract contract DeployFakeEnv is LaunchBase {
    mapping(string => string) private _fakeEnv;
    string private _recordPath;
    bool private _broadcastContext;
    bool private _rpcCheck;
    bool private _rpcOk;
    uint256 private _rpcId;

    function setFakeEnv(string calldata name, string calldata value) external {
        _fakeEnv[name] = value;
    }

    /// @dev 비워 두면 기본 경로(deployments/<chainId>.json).
    function setRecordPath(string calldata path) external {
        _recordPath = path;
    }

    /// @dev true면 `forge script --broadcast` 문맥처럼 동작.
    function setBroadcastContext(bool on) external {
        _broadcastContext = on;
    }

    /// @dev RPC 대조를 강제하고, RPC의 eth_chainId 응답(ok=false면 RPC 없음)을 흉내 냄.
    function setRpcChainId(bool ok, uint256 chainId) external {
        _rpcCheck = true;
        _rpcOk = ok;
        _rpcId = chainId;
    }

    function requireUsableSigner(address broadcaster) external view {
        _requireUsableSigner(broadcaster);
    }

    function _envString(string memory name) internal view virtual override returns (string memory) {
        return _fakeEnv[name];
    }

    function deploymentPath(uint256 chainId) public view virtual override returns (string memory) {
        return bytes(_recordPath).length == 0 ? super.deploymentPath(chainId) : _recordPath;
    }

    function _isBroadcastRun() internal view virtual override returns (bool) {
        return _broadcastContext;
    }

    function _enforceRpcChainCheck() internal view virtual override returns (bool) {
        return _rpcCheck;
    }

    function _rpcChainId() internal virtual override returns (bool, uint256) {
        return (_rpcOk, _rpcId);
    }
}

contract DeployEnvHarness is Deploy, DeployFakeEnv {
    function _envString(string memory name)
        internal
        view
        override(GuardedScript, DeployFakeEnv)
        returns (string memory)
    {
        return DeployFakeEnv._envString(name);
    }

    function deploymentPath(uint256 chainId) public view override(LaunchBase, DeployFakeEnv) returns (string memory) {
        return DeployFakeEnv.deploymentPath(chainId);
    }

    function _isBroadcastRun() internal view override(GuardedScript, DeployFakeEnv) returns (bool) {
        return DeployFakeEnv._isBroadcastRun();
    }

    function _enforceRpcChainCheck() internal view override(GuardedScript, DeployFakeEnv) returns (bool) {
        return DeployFakeEnv._enforceRpcChainCheck();
    }

    function _rpcChainId() internal override(GuardedScript, DeployFakeEnv) returns (bool, uint256) {
        return DeployFakeEnv._rpcChainId();
    }
}

contract DeployCreatePoolEnvHarness is CreatePool, DeployFakeEnv {
    function _envString(string memory name)
        internal
        view
        override(GuardedScript, DeployFakeEnv)
        returns (string memory)
    {
        return DeployFakeEnv._envString(name);
    }

    function deploymentPath(uint256 chainId) public view override(LaunchBase, DeployFakeEnv) returns (string memory) {
        return DeployFakeEnv.deploymentPath(chainId);
    }

    function _isBroadcastRun() internal view override(GuardedScript, DeployFakeEnv) returns (bool) {
        return DeployFakeEnv._isBroadcastRun();
    }

    function _enforceRpcChainCheck() internal view override(GuardedScript, DeployFakeEnv) returns (bool) {
        return DeployFakeEnv._enforceRpcChainCheck();
    }

    function _rpcChainId() internal override(GuardedScript, DeployFakeEnv) returns (bool, uint256) {
        return DeployFakeEnv._rpcChainId();
    }
}

contract DeployCheckEnvHarness is PostDeployCheck, DeployFakeEnv {
    function _envString(string memory name)
        internal
        view
        override(GuardedScript, DeployFakeEnv)
        returns (string memory)
    {
        return DeployFakeEnv._envString(name);
    }

    function deploymentPath(uint256 chainId) public view override(LaunchBase, DeployFakeEnv) returns (string memory) {
        return DeployFakeEnv.deploymentPath(chainId);
    }

    function _isBroadcastRun() internal view override(GuardedScript, DeployFakeEnv) returns (bool) {
        return DeployFakeEnv._isBroadcastRun();
    }

    function _enforceRpcChainCheck() internal view override(GuardedScript, DeployFakeEnv) returns (bool) {
        return DeployFakeEnv._enforceRpcChainCheck();
    }

    function _rpcChainId() internal override(GuardedScript, DeployFakeEnv) returns (bool, uint256) {
        return DeployFakeEnv._rpcChainId();
    }
}

/// @dev LaunchBase의 internal 헬퍼 노출 (실제 환경 변수 경로 포함).
contract DeployLaunchBaseHarness is LaunchBase {
    function formatUtc(uint256 timestamp) external pure returns (string memory) {
        return _formatUtc(timestamp);
    }

    function formatUnits(uint256 value, uint8 decimals) external pure returns (string memory) {
        return _formatUnits(value, decimals);
    }

    function fmtBps(uint256 bps) external pure returns (string memory) {
        return _fmtBps(bps);
    }

    function probeSafe(address account) external view returns (bool, uint256, uint256) {
        return LaunchGuards.probeSafe(account);
    }

    function isDelegatedEOA(address account) external view returns (bool) {
        return LaunchGuards.isDelegatedEOA(account);
    }

    function isMultisig(address account) external view returns (bool, bool, uint256, uint256) {
        return LaunchGuards.isMultisig(account, LaunchParams.SAFE_MIN_THRESHOLD, LaunchParams.SAFE_MIN_OWNERS);
    }

    function proofMessage(string calldata role, address account, uint256 chainId)
        external
        pure
        returns (string memory)
    {
        return ControlProof.message(role, account, chainId);
    }

    function parseProof(string calldata raw) external pure returns (bool, bytes memory) {
        return ControlProof.parseSignatures(raw);
    }

    function checkProof(string calldata text, address account, bytes calldata signature)
        external
        pure
        returns (ControlProof.Result, address)
    {
        return ControlProof.check(text, account, signature);
    }

    function describeProof(ControlProof.Result result) external pure returns (string memory) {
        return ControlProof.describe(result);
    }

    function envAddressOr(string calldata name, address defaultValue) external view returns (address) {
        return _envAddressOr(name, defaultValue);
    }

    function envUintOr(string calldata name, uint256 defaultValue) external view returns (uint256) {
        return _envUintOr(name, defaultValue);
    }

    function parseAddress(string calldata name, string calldata raw, bool requireChecksum)
        external
        pure
        returns (address)
    {
        return LaunchGuards.parseAddress(name, raw, requireChecksum);
    }

    function decodeRpcQuantity(bytes calldata raw) external pure returns (bool, uint256) {
        return LaunchGuards.decodeRpcQuantity(raw);
    }

    /// @dev 실제 vm.rpc 경로 (포크가 없으면 ok=false).
    function rpcChainId() external returns (bool, uint256) {
        return _rpcChainId();
    }

    function safeOwners(address account) external view returns (bool, address[] memory) {
        return LaunchGuards.safeOwners(account);
    }

    function safeHasModules(address account) external view returns (bool, bool) {
        return LaunchGuards.safeHasModules(account);
    }

    function createdBy(address account, address creator, uint256 creatorNonce, uint256 maxScan)
        external
        pure
        returns (bool, uint256)
    {
        return LaunchGuards.createdBy(account, creator, creatorNonce, maxScan);
    }

    function checkOwners(string calldata text, address[] calldata owners, uint256 threshold, bytes calldata sigs)
        external
        pure
        returns (ControlProof.Result, uint256, address)
    {
        return ControlProof.checkOwners(text, owners, threshold, sigs);
    }

    function vestingStatus(address vesting) external returns (uint8) {
        return LaunchCode.vestingStatus(vesting);
    }

    function tokenStatus(address token) external returns (uint8) {
        return LaunchCode.tokenStatus(token);
    }

    function executableLength(bytes calldata code) external pure returns (uint256) {
        return LaunchCode.executableLength(code);
    }

    function replaceWord(bytes calldata code, bytes32 from, bytes32 to) external pure returns (uint256, bytes memory) {
        bytes memory copy = code;
        uint256 replaced = LaunchCode.replaceWord(copy, from, to);
        return (replaced, copy);
    }

    function sameExecutable(bytes calldata a, bytes calldata b) external pure returns (bool) {
        return LaunchCode.sameExecutable(a, b);
    }

    function planMinLiquidity(bool fireIsToken0, uint256 lpFireAmount, uint256 seedEth, uint256 slippageBps)
        external
        pure
        returns (uint256)
    {
        return LaunchPositions.planMinLiquidity(fireIsToken0, lpFireAmount, seedEth, slippageBps);
    }
}

/// @dev Uniswap V3 주소표 라이브러리의 revert를 외부 호출로 확인하기 위한 래퍼.
contract DeployAddressTableHarness {
    function forChain(uint256 chainId) external pure returns (UniswapV3Addresses.Deployment memory) {
        return UniswapV3Addresses.forChain(chainId);
    }
}

/**
 * @dev 리뷰 PoC(F4): FireVesting처럼 응답하지만 언제든 전량을 인출할 수 있는 "베스팅". FireToken 생성자 검사
 *      (start ≥ 현재, duration > 0)를 통과하고, released()를 꾸며 "잔액 + 해제량 = 2억" 검사도 통과함.
 */
contract DeployBackdooredVesting {
    address public immutable owner;
    uint256 public immutable start;
    uint256 public immutable duration;
    address private immutable _admin;

    constructor(address owner_, address admin_) {
        owner = owner_;
        _admin = admin_;
        start = block.timestamp + 180 days;
        duration = 540 days;
    }

    function pendingOwner() external pure returns (address) {
        return address(0);
    }

    function end() external view returns (uint256) {
        return start + duration;
    }

    function released(address token) external view returns (uint256) {
        uint256 balance = FireToken(token).balanceOf(address(this));
        return balance >= 200_000_000e18 ? 0 : 200_000_000e18 - balance;
    }

    function releasable(address) external pure returns (uint256) {
        return 0;
    }

    function drain(address token) external {
        require(msg.sender == _admin, "only admin");
        require(FireToken(token).transfer(_admin, FireToken(token).balanceOf(address(this))), "transfer");
    }
}

/// @dev FireToken에 숨은 발행 함수를 붙인 변형 (메타데이터·상수·잔액은 진짜와 같음).
contract DeployMutantFireToken is FireToken {
    address private immutable _MINTER;

    constructor(address vesting) FireToken(vesting) {
        _MINTER = msg.sender;
    }

    function topUp(uint256 amount) external {
        require(msg.sender == _MINTER, "minter");
        _mint(msg.sender, amount);
    }
}

// ───────────────────────── 공통 픽스처 ─────────────────────────

abstract contract DeployFixture is Test {
    uint256 internal constant LAUNCH_TIME = 1_790_000_000; // 2026-09-21 14:13:20 UTC
    uint256 internal constant M = 1e6 * 1e18; // 100만 FIRE

    address internal deployer = makeAddr("deployer");
    address internal treasury = makeAddr("treasury");
    /// @dev 수익자·에어드롭 지갑은 소유 증명 서명을 위해 테스트 전용 키를 가짐 (makeAddr와 같은 주소).
    address internal beneficiary;
    uint256 internal beneficiaryKey;
    address internal airdrop;
    uint256 internal airdropKey;

    Deploy internal script;

    function setUp() public virtual {
        (beneficiary, beneficiaryKey) = makeAddrAndKey("beneficiary");
        (airdrop, airdropKey) = makeAddrAndKey("airdrop");
        vm.warp(LAUNCH_TIME);
        script = new Deploy();
    }

    /// @dev 소유 증명 없는 기본 설정 (로컬 31337은 증명을 생략하므로 그대로 배포됨).
    function _cfg() internal view returns (Deploy.DeployConfig memory cfg) {
        cfg.beneficiary = beneficiary;
        cfg.treasurySafe = treasury;
        cfg.airdropWallet = airdrop;
    }

    /// @dev 현재 체인 기준 두 소유 증명을 채운 설정.
    function _proven(Deploy.DeployConfig memory cfg) internal view returns (Deploy.DeployConfig memory) {
        cfg.beneficiaryProof = _signProof(beneficiaryKey, "BENEFICIARY", cfg.beneficiary);
        cfg.airdropWalletProof = _signProof(airdropKey, "AIRDROP_WALLET", cfg.airdropWallet);
        return cfg;
    }

    /// @dev 메인넷(8453) 배포가 통과하는 설정: CONFIRM_MAINNET, 2-of-3 Safe 트레저리, 두 소유 증명.
    function _mainnetCfg() internal returns (Deploy.DeployConfig memory cfg) {
        vm.chainId(8453);
        cfg = _cfg();
        cfg.mainnetConfirmed = true;
        cfg.treasurySafe = _safe(2);
        cfg = _proven(cfg);
    }

    /// @dev 스크립트와 독립적으로 만든 기대 메시지 (형식이 바뀌면 테스트가 깨지도록).
    function _proofText(string memory role, address account, uint256 chainId) internal pure returns (string memory) {
        return string.concat(
            "FIRE launch control proof | role=",
            role,
            " | address=",
            vm.toString(account),
            " | chainId=",
            vm.toString(chainId)
        );
    }

    /// @dev cast wallet sign과 같은 personal_sign 서명 (r ‖ s ‖ v, v = 27/28).
    function _signText(uint256 key, string memory text) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, MessageHashUtils.toEthSignedMessageHash(bytes(text)));
        return abi.encodePacked(r, s, v);
    }

    function _signProof(uint256 key, string memory role, address account) internal view returns (bytes memory) {
        return _signText(key, _proofText(role, account, block.chainid));
    }

    function _safe(uint256 threshold) internal returns (address) {
        return _safeWith(threshold, 3);
    }

    function _safeWith(uint256 threshold, uint256 ownerCount) internal returns (address) {
        address[] memory owners = new address[](ownerCount);
        for (uint256 i; i < ownerCount; ++i) {
            owners[i] = makeAddr(string.concat("signer-", vm.toString(i + 1)));
        }
        return address(new DeployMockSafe(threshold, owners));
    }

    /// @dev _safeWith가 만든 Safe의 i번째(1부터) 소유자 키 (makeAddr와 같은 주소).
    function _ownerKey(uint256 i) internal returns (uint256 key) {
        (, key) = makeAddrAndKey(string.concat("signer-", vm.toString(i)));
    }

    /// @dev Safe 수령 주소의 소유 증명: 지정한 소유자들이 각자 서명한 65바이트 서명을 순서대로 이어 붙임.
    function _ownerProof(string memory role, address safe, uint256[] memory ownerIndexes)
        internal
        returns (bytes memory proof)
    {
        for (uint256 i; i < ownerIndexes.length; ++i) {
            proof = bytes.concat(proof, _signProof(_ownerKey(ownerIndexes[i]), role, safe));
        }
    }

    function _indexes(uint256 a) internal pure returns (uint256[] memory list) {
        list = new uint256[](1);
        list[0] = a;
    }

    function _indexes(uint256 a, uint256 b) internal pure returns (uint256[] memory list) {
        list = new uint256[](2);
        (list[0], list[1]) = (a, b);
    }

    /// @dev 테스트가 만든 ./deployments/test-deploy-*.json 임시 파일만 읽고 지움 (fs_permissions 범위).
    function _readFile(string memory path) internal view returns (string memory) {
        // forge-lint: disable-next-line(unsafe-cheatcode)
        return vm.readFile(path);
    }

    function _removeFile(string memory path) internal {
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.removeFile(path);
    }

    /// @dev 이 파일 전용의 고유한 변수명에만 사용 (다른 테스트와 경쟁 없음).
    function _setUniqueEnv(string memory name, string memory value) internal {
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv(name, value);
    }

    /// @dev 병렬 테스트끼리 겹치지 않는 임시 기록 경로 (./deployments 만 쓰기 허용).
    function _tmpPath(string memory tag) internal pure returns (string memory) {
        return string.concat("deployments/test-deploy-", tag, ".json");
    }

    /// @dev 세 주소가 EIP-55 체크섬 표기로 들어 있는 가짜 환경 + 임시 기록 경로.
    function _envHarness() internal returns (DeployEnvHarness harness) {
        harness = new DeployEnvHarness();
        harness.setFakeEnv("BENEFICIARY", vm.toString(beneficiary));
        harness.setFakeEnv("TREASURY_SAFE", vm.toString(treasury));
        harness.setFakeEnv("AIRDROP_WALLET", vm.toString(airdrop));
    }

    function _inputs(Deploy.DeployResult memory r) internal pure returns (PostDeployCheck.CheckInputs memory inputs) {
        inputs.token = r.token;
        inputs.vesting = r.vesting;
        inputs.deployer = r.deployer;
        inputs.beneficiary = r.beneficiary;
        inputs.treasurySafe = r.treasurySafe;
        inputs.airdropWallet = r.airdropWallet;
        inputs.recordedVestingStart = r.vestingStart;
    }
}

// ───────────────────────── Deploy 스크립트 ─────────────────────────

contract DeployTest is DeployFixture {
    function test_Constants_MatchGuide() public view {
        assertEq(script.CLIFF(), 15_552_000);
        assertEq(script.LINEAR(), 46_656_000);
        assertEq(script.LP_AMOUNT(), 700_000_000e18);
        assertEq(script.TREASURY_AMOUNT(), 50_000_000e18);
        assertEq(script.AIRDROP_AMOUNT(), 50_000_000e18);
        assertEq(
            script.LP_AMOUNT() + script.TREASURY_AMOUNT() + script.AIRDROP_AMOUNT() + LaunchParams.VESTING_AMOUNT,
            LaunchParams.TOTAL_SUPPLY
        );
    }

    function test_Deploy_Local_AllPostConditions() public {
        uint256 nonce = vm.getNonce(deployer);
        Deploy.DeployResult memory r = script.deploy(_cfg(), deployer);
        FireToken token = FireToken(r.token);
        FireVesting vesting = FireVesting(payable(r.vesting));

        // 주소: 베스팅이 먼저(nonce), 토큰이 그다음(nonce + 1). 트랜잭션 4건.
        assertEq(r.vesting, vm.computeCreateAddress(deployer, nonce));
        assertEq(r.token, vm.computeCreateAddress(deployer, nonce + 1));
        assertEq(vm.getNonce(deployer), nonce + 4);

        assertEq(token.name(), "Fire");
        assertEq(token.symbol(), "FIRE");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), 1_000_000_000e18);
        assertEq(token.balanceOf(deployer), 700_000_000e18);
        assertEq(token.balanceOf(r.vesting), 200_000_000e18);
        assertEq(token.balanceOf(treasury), 50_000_000e18);
        assertEq(token.balanceOf(airdrop), 50_000_000e18);

        assertEq(vesting.owner(), beneficiary);
        assertEq(vesting.pendingOwner(), address(0));
        assertEq(vesting.duration(), 540 days);
        assertEq(vesting.start(), LAUNCH_TIME + 180 days);
        assertEq(vesting.end(), LAUNCH_TIME + 720 days);
        assertEq(vesting.releasable(r.token), 0);

        assertEq(r.deployer, deployer);
        assertEq(r.chainId, 31_337);
        assertEq(r.blockTimestamp, LAUNCH_TIME);
        assertEq(r.vestingStart, LAUNCH_TIME + 180 days);
        assertEq(r.vestingEnd, LAUNCH_TIME + 720 days);
    }

    /// @dev 가이드 3.1절 해제 표와 일치하는지 (클리프 직전 0, +1일 ≈ 370,370, 12개월 ≈ 1/3, 24개월 전량).
    function test_Deploy_VestingScheduleMatchesGuideTable() public {
        Deploy.DeployResult memory r = script.deploy(_cfg(), deployer);
        FireVesting vesting = FireVesting(payable(r.vesting));
        vm.warp(r.vestingStart - 1);
        assertEq(vesting.releasable(r.token), 0);
        vm.warp(r.vestingStart + 1 days);
        assertEq(vesting.releasable(r.token), uint256(200_000_000e18) / 540);
        vm.warp(LAUNCH_TIME + 360 days);
        assertEq(vesting.releasable(r.token), uint256(200_000_000e18) / 3);
        vm.warp(r.vestingEnd);
        assertEq(vesting.releasable(r.token), 200_000_000e18);
    }

    // ── 체인 · 메인넷 가드 ──

    function test_RevertWhen_UnsupportedChain() public {
        vm.chainId(1);
        vm.expectRevert(abi.encodeWithSelector(LaunchBase.LaunchUnsupportedChain.selector, 1));
        script.deploy(_cfg(), deployer);
    }

    function test_RevertWhen_MainnetWithoutConfirmation() public {
        vm.chainId(8453);
        Deploy.DeployConfig memory cfg = _cfg();
        cfg.treasurySafe = _safe(2);
        vm.expectRevert(LaunchBase.LaunchMainnetNotConfirmed.selector);
        script.deploy(cfg, deployer);
    }

    function test_RevertWhen_MainnetTreasuryHasNoCode() public {
        vm.chainId(8453);
        Deploy.DeployConfig memory cfg = _cfg();
        cfg.mainnetConfirmed = true;
        vm.expectRevert(abi.encodeWithSelector(Deploy.DeployTreasuryNotContract.selector, treasury));
        script.deploy(cfg, deployer);
    }

    function test_RevertWhen_MainnetTreasuryIsNotSafe() public {
        vm.chainId(8453);
        Deploy.DeployConfig memory cfg = _cfg();
        cfg.mainnetConfirmed = true;
        cfg.treasurySafe = address(new DeployNotASafe());
        vm.expectRevert(abi.encodeWithSelector(Deploy.DeployTreasuryNotSafe.selector, cfg.treasurySafe));
        script.deploy(cfg, deployer);

        cfg.treasurySafe = address(new DeploySilentFallback());
        vm.expectRevert(abi.encodeWithSelector(Deploy.DeployTreasuryNotSafe.selector, cfg.treasurySafe));
        script.deploy(cfg, deployer);

        cfg.treasurySafe = _safe(0); // threshold 0은 Safe로 보지 않음
        vm.expectRevert(abi.encodeWithSelector(Deploy.DeployTreasuryNotSafe.selector, cfg.treasurySafe));
        script.deploy(cfg, deployer);
    }

    function test_Deploy_Mainnet_ConfirmedWithSafeTreasury() public {
        Deploy.DeployConfig memory cfg = _mainnetCfg();
        Deploy.DeployResult memory r = script.deploy(cfg, deployer);
        assertEq(r.chainId, 8453);
        assertEq(FireToken(r.token).balanceOf(cfg.treasurySafe), 50_000_000e18);
        assertEq(FireToken(r.token).balanceOf(deployer), 700_000_000e18);
        assertEq(FireVesting(payable(r.vesting)).owner(), beneficiary);
    }

    /// @dev 메인넷 TREASURY_SAFE는 2-of-3 이상 (DeployBatchSender 소유자 규칙과 같음). 1-of-3, 2-of-2, 1-of-1 거부.
    function test_RevertWhen_MainnetTreasurySafeBelowTwoOfThree() public {
        Deploy.DeployConfig memory cfg = _mainnetCfg();
        uint256[2][3] memory weak = [[uint256(1), 3], [uint256(2), 2], [uint256(1), 1]];
        for (uint256 i; i < weak.length; ++i) {
            cfg.treasurySafe = _safeWith(weak[i][0], weak[i][1]);
            vm.expectRevert(
                abi.encodeWithSelector(
                    Deploy.DeployTreasurySafeTooWeak.selector, cfg.treasurySafe, weak[i][0], weak[i][1]
                )
            );
            script.deploy(cfg, deployer);
        }
        cfg.treasurySafe = _safeWith(3, 5); // 3-of-5는 허용
        assertEq(script.deploy(cfg, deployer).chainId, 8453);
    }

    /**
     * @dev 리허설 B1 회귀: 배포 지갑(브로드캐스터)이 EIP-7702 위임 EOA면(예: Base 메인넷의 anvil 개발 계정은 ETH를 제3자로
     *      넘기는 스위퍼에 위임됨) 8억 FIRE와 LP NFT를 받을 지갑으로 부적합 → 메인넷 중단(아무것도 전송 안 함), 테스트넷 경고.
     */
    function test_RevertWhen_MainnetDeployerHasCode() public {
        vm.setEvmVersion("prague");
        address delegated = makeAddr("deployer-7702");
        vm.etch(delegated, abi.encodePacked(hex"ef0100", address(new DeployNotASafe())));
        Deploy.DeployConfig memory cfg = _mainnetCfg();
        vm.expectRevert(abi.encodeWithSelector(Deploy.DeployBroadcasterHasCode.selector, delegated));
        script.deploy(cfg, delegated);
        assertEq(vm.getNonce(delegated), 0);

        vm.chainId(84_532);
        cfg = _proven(_cfg());
        Deploy.DeployResult memory r = script.deploy(cfg, delegated); // 테스트넷: 경고만
        assertEq(FireToken(r.token).balanceOf(delegated), 700_000_000e18);
    }

    /// @dev EIP-7702 위임 EOA는 위임 대상이 2-of-3 Safe처럼 응답해도 키 하나로 통제되므로 메인넷 트레저리로 거부.
    function test_RevertWhen_MainnetTreasuryIsDelegatedEOA() public {
        vm.setEvmVersion("prague");
        Deploy.DeployConfig memory cfg = _mainnetCfg();
        address delegated = makeAddr("treasury-7702");
        vm.etch(delegated, abi.encodePacked(hex"ef0100", address(new DeployConstantSafe(2, 3))));
        (bool isSafe,,) = new DeployLaunchBaseHarness().probeSafe(delegated);
        assertTrue(isSafe, "the delegate answers like a Safe");
        cfg.treasurySafe = delegated;
        vm.expectRevert(abi.encodeWithSelector(Deploy.DeployTreasuryIsDelegatedEOA.selector, delegated));
        script.deploy(cfg, deployer);
    }

    /// @dev 테스트넷은 리허설 편의를 위해 약한 Safe·EIP-7702 트레저리도 경고만.
    function test_Deploy_Sepolia_WeakOrDelegatedTreasuryOnlyWarns() public {
        vm.setEvmVersion("prague");
        vm.chainId(84_532);
        Deploy.DeployConfig memory cfg = _proven(_cfg());
        cfg.treasurySafe = _safe(1);
        script.deploy(cfg, deployer);
        address delegated = makeAddr("treasury-7702-sepolia");
        vm.etch(delegated, abi.encodePacked(hex"ef0100", cfg.treasurySafe));
        cfg.treasurySafe = delegated;
        assertEq(FireToken(script.deploy(cfg, makeAddr("deployer-2")).token).balanceOf(delegated), 50_000_000e18);
        cfg.treasurySafe = address(new DeployNotASafe()); // Safe가 아닌 컨트랙트도 테스트넷은 경고만
        assertEq(script.deploy(cfg, makeAddr("deployer-3")).chainId, 84_532);
    }

    function test_Deploy_Sepolia_TreasuryWithoutCodeOnlyWarns() public {
        vm.chainId(84_532);
        Deploy.DeployResult memory r = script.deploy(_cfg(), deployer);
        assertEq(r.chainId, 84_532);
        assertEq(FireToken(r.token).balanceOf(treasury), 50_000_000e18);
    }

    // ── 주소 가드 ──

    function test_RevertWhen_BeneficiaryIsZero() public {
        Deploy.DeployConfig memory cfg = _cfg();
        cfg.beneficiary = address(0);
        _expectDeployRevert(cfg, abi.encodeWithSelector(Deploy.DeployZeroAddress.selector, "BENEFICIARY"));
    }

    function test_RevertWhen_TreasuryIsZero() public {
        Deploy.DeployConfig memory cfg = _cfg();
        cfg.treasurySafe = address(0);
        _expectDeployRevert(cfg, abi.encodeWithSelector(Deploy.DeployZeroAddress.selector, "TREASURY_SAFE"));
    }

    function test_RevertWhen_AirdropIsZero() public {
        Deploy.DeployConfig memory cfg = _cfg();
        cfg.airdropWallet = address(0);
        _expectDeployRevert(cfg, abi.encodeWithSelector(Deploy.DeployZeroAddress.selector, "AIRDROP_WALLET"));
    }

    function test_RevertWhen_BeneficiaryEqualsTreasury() public {
        Deploy.DeployConfig memory cfg = _cfg();
        cfg.treasurySafe = beneficiary;
        _expectDeployRevert(
            cfg, abi.encodeWithSelector(Deploy.DeployDuplicateAddress.selector, "BENEFICIARY", "TREASURY_SAFE")
        );
    }

    function test_RevertWhen_BeneficiaryEqualsAirdrop() public {
        Deploy.DeployConfig memory cfg = _cfg();
        cfg.airdropWallet = beneficiary;
        _expectDeployRevert(
            cfg, abi.encodeWithSelector(Deploy.DeployDuplicateAddress.selector, "BENEFICIARY", "AIRDROP_WALLET")
        );
    }

    function test_RevertWhen_TreasuryEqualsAirdrop() public {
        Deploy.DeployConfig memory cfg = _cfg();
        cfg.airdropWallet = treasury;
        _expectDeployRevert(
            cfg, abi.encodeWithSelector(Deploy.DeployDuplicateAddress.selector, "TREASURY_SAFE", "AIRDROP_WALLET")
        );
    }

    function test_RevertWhen_BeneficiaryIsBroadcaster() public {
        Deploy.DeployConfig memory cfg = _cfg();
        cfg.beneficiary = deployer;
        _expectDeployRevert(cfg, abi.encodeWithSelector(Deploy.DeployRecipientIsBroadcaster.selector, "BENEFICIARY"));
    }

    function test_RevertWhen_TreasuryIsBroadcaster() public {
        Deploy.DeployConfig memory cfg = _cfg();
        cfg.treasurySafe = deployer;
        _expectDeployRevert(cfg, abi.encodeWithSelector(Deploy.DeployRecipientIsBroadcaster.selector, "TREASURY_SAFE"));
    }

    function test_RevertWhen_AirdropIsBroadcaster() public {
        Deploy.DeployConfig memory cfg = _cfg();
        cfg.airdropWallet = deployer;
        _expectDeployRevert(cfg, abi.encodeWithSelector(Deploy.DeployRecipientIsBroadcaster.selector, "AIRDROP_WALLET"));
    }

    /// @dev 수령 주소가 곧 배포될 베스팅/토큰 주소면 물량이 영구 동결되므로 차단.
    function test_RevertWhen_RecipientIsPredictedContract() public {
        Deploy.DeployConfig memory cfg = _cfg();
        cfg.beneficiary = vm.computeCreateAddress(deployer, vm.getNonce(deployer));
        _expectDeployRevert(cfg, abi.encodeWithSelector(Deploy.DeployRecipientIsNewContract.selector, "BENEFICIARY"));

        cfg = _cfg();
        cfg.airdropWallet = vm.computeCreateAddress(deployer, vm.getNonce(deployer) + 1);
        _expectDeployRevert(cfg, abi.encodeWithSelector(Deploy.DeployRecipientIsNewContract.selector, "AIRDROP_WALLET"));
    }

    function _expectDeployRevert(Deploy.DeployConfig memory cfg, bytes memory reason) internal {
        vm.expectRevert(reason);
        script.deploy(cfg, deployer);
    }

    /// @dev 사후 조건 검사 자체가 변조를 잡아내는지 확인.
    function test_RevertWhen_PostConditionsSeeTampering() public {
        Deploy.DeployResult memory r = script.deploy(_cfg(), deployer);
        script.checkPostConditions(r);
        vm.prank(treasury);
        assertTrue(FireToken(r.token).transfer(airdrop, 1));
        vm.expectRevert(
            abi.encodeWithSelector(Deploy.DeployPostConditionFailed.selector, "treasury balance != 50,000,000 FIRE")
        );
        script.checkPostConditions(r);
    }

    function testFuzz_Deploy_AnyValidRecipientsAndTime(address b, address t, address a, uint256 timestamp) public {
        timestamp = bound(timestamp, 1, type(uint64).max - 180 days);
        vm.warp(timestamp);
        address predictedVesting = vm.computeCreateAddress(deployer, vm.getNonce(deployer));
        address predictedToken = vm.computeCreateAddress(deployer, vm.getNonce(deployer) + 1);
        address[3] memory recipients = [b, t, a];
        for (uint256 i; i < 3; ++i) {
            vm.assume(recipients[i] != address(0) && recipients[i] != deployer);
            vm.assume(recipients[i] != predictedVesting && recipients[i] != predictedToken);
            assumeNotForgeAddress(recipients[i]);
        }
        vm.assume(b != t && b != a && t != a);

        Deploy.DeployConfig memory cfg;
        (cfg.beneficiary, cfg.treasurySafe, cfg.airdropWallet) = (b, t, a);
        Deploy.DeployResult memory r = script.deploy(cfg, deployer);
        FireToken token = FireToken(r.token);
        assertEq(token.balanceOf(deployer), 700_000_000e18);
        assertEq(token.balanceOf(t), 50_000_000e18);
        assertEq(token.balanceOf(a), 50_000_000e18);
        assertEq(FireVesting(payable(r.vesting)).owner(), b);
        assertEq(r.vestingStart, timestamp + 180 days);
    }

    // ── 기록 ──

    function test_RecordJson_RoundTrip() public {
        Deploy.DeployResult memory r = script.deploy(_cfg(), deployer);
        string memory path = _tmpPath("roundtrip");
        vm.writeJson(script.recordJson(r), path);
        string memory json = _readFile(path);
        _removeFile(path);

        assertEq(vm.parseJsonString(json, ".status"), "pending"); // 전송 전(시뮬레이션) 기록
        assertFalse(vm.keyExistsJson(json, ".deployedAt")); // confirm()이 채움
        assertEq(vm.parseJsonUint(json, ".chainId"), 31_337);
        assertEq(vm.parseJsonString(json, ".network"), "anvil");
        assertEq(vm.parseJsonAddress(json, ".deployer"), deployer);
        assertEq(vm.parseJsonUint(json, ".deployerNonce"), r.deployerNonce);
        assertEq(vm.parseJsonUint(json, ".blockNumber"), block.number);
        assertEq(vm.parseJsonUint(json, ".blockTimestamp"), LAUNCH_TIME);
        assertEq(vm.parseJsonAddress(json, ".contracts.FireToken"), r.token);
        assertEq(vm.parseJsonAddress(json, ".contracts.FireVesting"), r.vesting);
        assertEq(vm.parseJsonAddress(json, ".wallets.beneficiary"), beneficiary);
        assertEq(vm.parseJsonAddress(json, ".wallets.treasurySafe"), treasury);
        assertEq(vm.parseJsonAddress(json, ".wallets.airdropWallet"), airdrop);
        assertEq(vm.parseJsonUint(json, ".vesting.cliffSeconds"), 15_552_000);
        assertEq(vm.parseJsonUint(json, ".vesting.linearSeconds"), 46_656_000);
        assertEq(vm.parseJsonUint(json, ".vesting.start"), r.vestingStart);
        assertEq(vm.parseJsonUint(json, ".vesting.end"), r.vestingEnd);
        assertEq(vm.parseJsonUint(json, ".allocation.totalSupply"), 1_000_000_000e18);
        assertEq(vm.parseJsonUint(json, ".allocation.lp"), 700_000_000e18);
        assertEq(vm.parseJsonUint(json, ".allocation.vesting"), 200_000_000e18);
        assertEq(vm.parseJsonUint(json, ".allocation.treasury"), 50_000_000e18);
        assertEq(vm.parseJsonUint(json, ".allocation.airdrop"), 50_000_000e18);
        // 수량은 JavaScript에서 정밀도가 깨지지 않도록 10진 문자열로 기록
        assertEq(vm.parseJsonString(json, ".allocation.lp"), "700000000000000000000000000");
        assertEq(vm.parseJsonString(json, ".allocation.treasury"), "50000000000000000000000000");
    }

    function test_RequireNotDeployed_BlocksMainnetRedeploy() public {
        Deploy.DeployResult memory r = script.deploy(_cfg(), deployer);
        string memory path = _tmpPath("redeploy");
        script.requireNotDeployed(path); // 파일 없음 → 통과
        vm.writeJson(script.recordJson(r), path);
        script.requireNotDeployed(path); // 로컬: 경고만
        vm.chainId(8453);
        vm.expectRevert(abi.encodeWithSelector(Deploy.DeployAlreadyDeployed.selector, r.token));
        script.requireNotDeployed(path);
        _removeFile(path);
    }

    // ── 환경 변수 (가짜 환경 주입: 병렬 테스트와 경쟁 없음) ──

    function test_Env_LoadConfig() public {
        DeployEnvHarness harness = _envHarness();

        Deploy.DeployConfig memory cfg = harness.loadConfig();
        assertEq(cfg.beneficiary, beneficiary);
        assertEq(cfg.treasurySafe, treasury);
        assertEq(cfg.airdropWallet, airdrop);
        assertFalse(cfg.mainnetConfirmed);

        harness.setFakeEnv("CONFIRM_MAINNET", "yes");
        assertFalse(harness.loadConfig().mainnetConfirmed);
        harness.setFakeEnv("CONFIRM_MAINNET", "i_understand");
        assertFalse(harness.loadConfig().mainnetConfirmed);
        harness.setFakeEnv("CONFIRM_MAINNET", "I_UNDERSTAND");
        assertTrue(harness.loadConfig().mainnetConfirmed);

        harness.setFakeEnv("BENEFICIARY", ""); // .env.example 그대로 복사한 경우
        vm.expectRevert(abi.encodeWithSelector(LaunchBase.LaunchMissingEnv.selector, "BENEFICIARY"));
        harness.loadConfig();

        harness.setFakeEnv("BENEFICIARY", "not-an-address");
        vm.expectRevert(abi.encodeWithSelector(LaunchGuards.LaunchInvalidAddress.selector, "BENEFICIARY"));
        harness.loadConfig();
    }

    /// @dev run()은 테스트·드라이런 문맥에서 기록 파일을 쓰지 않음 (실제 --broadcast 에서만 씀).
    function test_Env_RunDoesNotWriteRecordOutsideBroadcast() public {
        DeployEnvHarness harness = _envHarness();
        string memory path = _tmpPath("run-dry");
        harness.setRecordPath(path);

        Deploy.DeployResult memory r = harness.run();
        assertEq(r.deployer, DEFAULT_SENDER); // CLI 서명자가 없으면 forge 기본 sender (드라이런은 경고만)
        assertEq(FireToken(r.token).balanceOf(DEFAULT_SENDER), 700_000_000e18);
        assertFalse(vm.exists(path));
    }

    /// @dev --broadcast 문맥에서는 pending 기록을 씀 (서명자는 명시적 sender로 대신함: 기본 sender는 거부되므로).
    function test_Env_BroadcastRunWritesPendingRecord() public {
        DeployEnvHarness harness = _envHarness();
        string memory path = _tmpPath("run-broadcast");
        harness.setRecordPath(path);
        harness.setBroadcastContext(true);
        vm.expectRevert(LaunchBase.LaunchNoSigner.selector); // 리뷰 PoC: 지갑 옵션 없는 --broadcast
        harness.run();
        assertFalse(vm.exists(path)); // 시뮬레이션 전에 중단 → 가짜 공개 기록이 남지 않음
    }

    /// @dev CLI 서명자가 로드된 --broadcast 실행: 서명자 주소로 배포하고 pending 기록을 씀(run()의 기록 쓰기 경로).
    function test_Env_BroadcastRunWithSignerWritesPendingRecord() public {
        DeployEnvHarness harness = _envHarness();
        string memory path = _tmpPath("run-broadcast-signer");
        harness.setRecordPath(path);
        harness.setBroadcastContext(true);
        (address signer, uint256 key) = makeAddrAndKey("cli-signer");
        vm.rememberKey(key);
        Deploy.DeployResult memory r = harness.run();
        string memory json = _readFile(path);
        _removeFile(path);
        assertEq(r.deployer, signer);
        assertEq(vm.parseJsonString(json, ".status"), "pending");
        assertEq(vm.parseJsonAddress(json, ".deployer"), signer);
        assertEq(vm.parseJsonAddress(json, ".contracts.FireToken"), r.token);
    }

    /// @dev confirm() 진입점: 체인 확인 후 deploymentPath(block.chainid)의 기록을 확정.
    function test_Confirm_EntryPointConfirmsRecordAtDeploymentPath() public {
        Deploy.DeployResult memory r = script.deploy(_cfg(), deployer);
        DeployEnvHarness harness = _envHarness();
        string memory path = _tmpPath("confirm-entry");
        harness.setRecordPath(path);
        vm.writeJson(script.recordJson(r), path);
        Deploy.DeployResult memory c = harness.confirm();
        string memory json = _readFile(path);
        _removeFile(path);
        assertEq(c.token, r.token);
        assertEq(vm.parseJsonString(json, ".status"), "confirmed");
    }

    /// @dev 실제 vm.envOr 경로 확인. 다른 테스트와 겹치지 않는 고유 변수명만 사용.
    function test_RealEnvPath_UniqueVariable() public {
        DeployLaunchBaseHarness h = new DeployLaunchBaseHarness();
        assertEq(h.envAddressOr("FIRE_DEPLOY_TEST_PROBE_ADDR", address(7)), address(7));
        _setUniqueEnv("FIRE_DEPLOY_TEST_PROBE_ADDR", vm.toString(beneficiary));
        assertEq(h.envAddressOr("FIRE_DEPLOY_TEST_PROBE_ADDR", address(7)), beneficiary);
        _setUniqueEnv("FIRE_DEPLOY_TEST_PROBE_UINT", "");
        assertEq(h.envUintOr("FIRE_DEPLOY_TEST_PROBE_UINT", 42), 42);
        _setUniqueEnv("FIRE_DEPLOY_TEST_PROBE_UINT", "3000000000000000000");
        assertEq(h.envUintOr("FIRE_DEPLOY_TEST_PROBE_UINT", 42), 3 ether);
    }

    /// @dev CreatePool.loadConfig: FIRE_TOKEN(env)과 기록 중 하나를 쓰고, 둘이 다르면 중단.
    function test_Env_CreatePoolLoadConfig() public {
        DeployCreatePoolEnvHarness harness = new DeployCreatePoolEnvHarness();
        string memory path = _tmpPath("createpool-config");
        address recorded = makeAddr("recorded-fire");
        vm.writeJson(string.concat('{"contracts":{"FireToken":"', vm.toString(recorded), '"}}'), path);

        CreatePool.PoolConfig memory cfg = harness.loadConfig(path);
        assertEq(cfg.fireToken, recorded);
        assertEq(cfg.seedEth, 3 ether);
        assertEq(cfg.lpFireAmount, 700_000_000e18);
        assertEq(cfg.feeTier, 10_000);
        assertEq(cfg.slippageBps, 50);
        assertFalse(cfg.mainnetConfirmed);

        harness.setFakeEnv("FIRE_TOKEN", vm.toString(recorded));
        harness.setFakeEnv("SEED_ETH", "5000000000000000000");
        harness.setFakeEnv("LP_FIRE_AMOUNT", "1000000000000000000000");
        harness.setFakeEnv("FEE_TIER", "3000");
        harness.setFakeEnv("SLIPPAGE_BPS", "100");
        harness.setFakeEnv("CONFIRM_MAINNET", "I_UNDERSTAND");
        cfg = harness.loadConfig(path);
        assertEq(cfg.fireToken, recorded);
        assertEq(cfg.seedEth, 5 ether);
        assertEq(cfg.lpFireAmount, 1000e18);
        assertEq(cfg.feeTier, 3000);
        assertEq(cfg.slippageBps, 100);
        assertTrue(cfg.mainnetConfirmed);

        address stale = makeAddr("stale-fire");
        harness.setFakeEnv("FIRE_TOKEN", vm.toString(stale));
        vm.expectRevert(abi.encodeWithSelector(CreatePool.CreatePoolTokenSourceMismatch.selector, stale, recorded));
        harness.loadConfig(path);

        harness.setFakeEnv("FIRE_TOKEN", "");
        harness.setFakeEnv("FEE_TIER", "16777216"); // uint24 초과
        vm.expectRevert();
        harness.loadConfig(path);

        _removeFile(path);
        harness.setFakeEnv("FEE_TIER", "");
        vm.expectRevert(CreatePool.CreatePoolMissingFireToken.selector);
        harness.loadConfig(path);
        harness.setFakeEnv("FIRE_TOKEN", vm.toString(stale));
        assertEq(harness.loadConfig(path).fireToken, stale);
    }

    /**
     * @dev 리뷰 PoC(F2) 회귀: 메인넷 CreatePool은 Deploy 기록(contracts.FireToken·deployer·deployerNonce)이 있어야 하고
     *      기록의 토큰 = CREATE(deployer, deployerNonce + 1). FIRE_TOKEN만으로는 실행할 수 없음(주소 오염용 가짜 토큰에
     *      시딩 ETH를 넣는 사고 방지). 메인넷에서는 FIRE_TOKEN 값만 담은 최소 기록도 만들지 않음.
     */
    function test_CreatePool_MainnetNeedsLaunchRecord() public {
        Deploy.DeployResult memory r = script.deploy(_cfg(), deployer);
        DeployCreatePoolEnvHarness harness = new DeployCreatePoolEnvHarness();
        string memory path = _tmpPath("createpool-mainnet-record");
        vm.chainId(8453);
        harness.setFakeEnv("FIRE_TOKEN", vm.toString(r.token));
        vm.expectRevert(abi.encodeWithSelector(CreatePool.CreatePoolLaunchRecordRequired.selector, path));
        harness.loadConfig(path);

        vm.writeJson(string.concat('{"contracts":{"FireToken":"', vm.toString(r.token), '"}}'), path);
        vm.expectRevert(abi.encodeWithSelector(CreatePool.CreatePoolLaunchRecordRequired.selector, path));
        harness.loadConfig(path); // 배포자 정보 없는 기록

        vm.writeJson(script.recordJson(r), path);
        assertEq(harness.loadConfig(path).fireToken, r.token);

        vm.writeJson(string.concat('"', vm.toString(r.vesting), '"'), path, ".contracts.FireToken");
        harness.setFakeEnv("FIRE_TOKEN", "");
        vm.expectRevert(
            abi.encodeWithSelector(
                CreatePool.CreatePoolRecordMismatch.selector,
                "contracts.FireToken != CREATE(deployer, deployerNonce + 1)"
            )
        );
        harness.loadConfig(path);
        vm.chainId(84_532); // 기록의 유도 확인은 모든 체인에서
        vm.expectRevert(
            abi.encodeWithSelector(
                CreatePool.CreatePoolRecordMismatch.selector,
                "contracts.FireToken != CREATE(deployer, deployerNonce + 1)"
            )
        );
        harness.loadConfig(path);
        _removeFile(path);

        vm.chainId(8453);
        vm.expectRevert(abi.encodeWithSelector(CreatePool.CreatePoolLaunchRecordRequired.selector, path));
        harness.writePoolRecord('{"status":"pending"}', r.token, path);
        assertFalse(vm.exists(path));
    }

    function test_CreatePool_RevertWhen_NoUniswapOnChain() public {
        CreatePool pool = new CreatePool();
        CreatePool.PoolConfig memory cfg;
        vm.expectRevert(abi.encodeWithSelector(LaunchBase.LaunchUnsupportedChain.selector, 31_337));
        pool.createPool(cfg, deployer);
        vm.chainId(8453);
        vm.expectRevert(LaunchBase.LaunchMainnetNotConfirmed.selector);
        pool.createPool(cfg, deployer);
    }

    // ── EIP-55 체크섬 (주소 한 글자 오타 방지) ──

    /// @dev 리뷰 PoC: anvil 계정 1(...79C8)의 마지막 글자 오타. vm.parseAddress는 다른 주소로 받아들이지만 거부해야 함.
    function test_RevertWhen_BeneficiaryHasChecksumTypo() public {
        string memory typo = "0x70997970C51812dc3A010C7d01b50e0d17dc79C9";
        assertEq(vm.parseAddress(typo), vm.parseAddress(vm.toLowercase(typo))); // forge 자체는 그대로 통과시킴
        DeployEnvHarness harness = _envHarness();
        harness.setFakeEnv("BENEFICIARY", typo);
        vm.expectRevert(abi.encodeWithSelector(LaunchGuards.LaunchBadChecksum.selector, "BENEFICIARY"));
        harness.loadConfig();
        vm.chainId(8453);
        vm.expectRevert(abi.encodeWithSelector(LaunchGuards.LaunchBadChecksum.selector, "BENEFICIARY"));
        harness.loadConfig();
    }

    /// @dev 전부 소문자인 주소에는 체크섬 정보가 없음: 테스트넷은 허용, 메인넷은 세 수령 주소 모두 체크섬 필수.
    function test_Env_LowercaseAddressesOnlyOffMainnet() public {
        DeployEnvHarness harness = _envHarness();
        harness.setFakeEnv("AIRDROP_WALLET", vm.toLowercase(vm.toString(airdrop)));
        assertEq(harness.loadConfig().airdropWallet, airdrop);
        vm.chainId(8453);
        vm.expectRevert(abi.encodeWithSelector(LaunchGuards.LaunchChecksumRequired.selector, "AIRDROP_WALLET"));
        harness.loadConfig();
        harness.setFakeEnv("AIRDROP_WALLET", vm.toString(airdrop));
        assertEq(harness.loadConfig().airdropWallet, airdrop);
    }

    function test_ParseAddress_Formats() public {
        DeployLaunchBaseHarness h = new DeployLaunchBaseHarness();
        address account1 = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;
        assertEq(h.parseAddress("X", "0x70997970C51812dc3A010C7d01b50e0d17dc79C8", true), account1);
        assertEq(h.parseAddress("X", "0x70997970c51812dc3a010c7d01b50e0d17dc79c8", false), account1);
        assertEq(h.parseAddress("X", "0x0000000000000000000000000000000000000001", true), address(1)); // 문자 없음
        // EIP-55 표기 자체가 전부 소문자인 드문 주소(퍼즈로 발견)는 체크섬 필수 모드에서도 통과
        assertEq(vm.toString(address(0x378d)), "0x000000000000000000000000000000000000378d");
        assertEq(h.parseAddress("X", "0x000000000000000000000000000000000000378d", true), address(0x378d));
        _expectParseRevert(
            h, "0x70997970c51812dc3a010c7d01b50e0d17dc79c8", true, LaunchGuards.LaunchChecksumRequired.selector
        );
        _expectParseRevert(
            h, "0x70997970C51812DC3A010C7D01B50E0D17DC79C8", false, LaunchGuards.LaunchBadChecksum.selector
        );
        _expectParseRevert(
            h, "70997970C51812dc3A010C7d01b50e0d17dc79C8", false, LaunchGuards.LaunchInvalidAddress.selector
        );
        _expectParseRevert(
            h, "0X70997970C51812dc3A010C7d01b50e0d17dc79C8", false, LaunchGuards.LaunchInvalidAddress.selector
        );
        _expectParseRevert(
            h, "0x70997970C51812dc3A010C7d01b50e0d17dc79C", false, LaunchGuards.LaunchInvalidAddress.selector
        );
        _expectParseRevert(
            h, "0x70997970C51812dc3A010C7d01b50e0d17dc79Cg", false, LaunchGuards.LaunchInvalidAddress.selector
        );
        _expectParseRevert(
            h, " 0x70997970C51812dc3A010C7d01b50e0d17dc79C8", false, LaunchGuards.LaunchInvalidAddress.selector
        );
    }

    function _expectParseRevert(DeployLaunchBaseHarness h, string memory raw, bool strict, bytes4 selector) internal {
        vm.expectRevert(abi.encodeWithSelector(selector, "X"));
        h.parseAddress("X", raw, strict);
    }

    /// @dev EIP-55 표기는 그대로 통과하고, 그중 문자 하나의 대소문자만 바뀌어도 거부됨(전부 소문자가 되면 체크섬 없음).
    function testFuzz_ParseAddress_ChecksumRoundTripAndCaseFlip(address account, uint256 pick) public {
        DeployLaunchBaseHarness h = new DeployLaunchBaseHarness();
        string memory checksummed = vm.toString(account);
        assertEq(h.parseAddress("X", checksummed, true), account);
        bytes memory b = bytes(checksummed);
        uint256[] memory letters = new uint256[](40);
        uint256 count;
        for (uint256 i = 2; i < 42; ++i) {
            if (b[i] >= "A") letters[count++] = i; // 16진 문자(A-F, a-f)는 모두 숫자보다 큼
        }
        if (count == 0) return; // 숫자만 있는 주소 (사실상 없음)
        uint256 flip = letters[pick % count];
        b[flip] = bytes1(uint8(b[flip]) ^ 0x20);
        bool hasUpper;
        for (uint256 i = 2; i < 42; ++i) {
            if (b[i] >= "A" && b[i] <= "F") hasUpper = true;
        }
        if (hasUpper) {
            vm.expectRevert(abi.encodeWithSelector(LaunchGuards.LaunchBadChecksum.selector, "X"));
            h.parseAddress("X", string(b), false);
        } else {
            assertEq(h.parseAddress("X", string(b), false), account);
            vm.expectRevert(abi.encodeWithSelector(LaunchGuards.LaunchChecksumRequired.selector, "X"));
            h.parseAddress("X", string(b), true);
        }
    }

    // ── RPC 체인 ID 대조 (--chain / FOUNDRY_CHAIN_ID 위장 방지) ──

    /// @dev 리뷰 PoC: --rpc-url base --chain base-sepolia → 스크립트는 84532로 보고 메인넷 보호를 건너뛰지만 전송은 8453.
    function test_RevertWhen_ChainFlagSpoofsTestnetOnMainnetRpc() public {
        DeployEnvHarness harness = _envHarness();
        harness.setRecordPath(_tmpPath("chain-spoof"));
        vm.chainId(84_532);
        harness.setRpcChainId(true, 8453);
        vm.expectRevert(abi.encodeWithSelector(LaunchGuards.LaunchChainIdMismatch.selector, 84_532, 8453));
        harness.run();
        vm.expectRevert(abi.encodeWithSelector(LaunchGuards.LaunchChainIdMismatch.selector, 84_532, 8453));
        harness.deploy(_cfg(), deployer);
        vm.expectRevert(abi.encodeWithSelector(LaunchGuards.LaunchChainIdMismatch.selector, 84_532, 8453));
        harness.confirm();
    }

    function test_ChainCheck_MatchingRpcProceeds() public {
        DeployEnvHarness harness = _envHarness();
        vm.chainId(84_532);
        harness.setRpcChainId(true, 84_532);
        assertEq(harness.deploy(_cfg(), deployer).chainId, 84_532);
    }

    /// @dev RPC가 없는 로컬 드라이런은 전송이 없으므로 진행, --broadcast인데 RPC를 조회할 수 없으면 중단.
    function test_ChainCheck_NoRpc_DryRunProceedsBroadcastReverts() public {
        DeployEnvHarness harness = _envHarness();
        harness.setRpcChainId(false, 0);
        harness.deploy(_cfg(), deployer);
        harness.setBroadcastContext(true);
        vm.expectRevert(LaunchGuards.LaunchRpcUnavailable.selector);
        harness.deploy(_cfg(), makeAddr("deployer-2"));
    }

    function test_ChainCheck_CreatePoolAndPostDeployCheck() public {
        vm.chainId(84_532);
        DeployCreatePoolEnvHarness pool = new DeployCreatePoolEnvHarness();
        pool.setRpcChainId(true, 8453);
        CreatePool.PoolConfig memory cfg;
        bytes memory mismatch = abi.encodeWithSelector(LaunchGuards.LaunchChainIdMismatch.selector, 84_532, 8453);
        vm.expectRevert(mismatch);
        pool.createPool(cfg, deployer);
        vm.expectRevert(mismatch);
        pool.confirm();
        vm.expectRevert(mismatch);
        pool.permitTypedData();
        DeployCheckEnvHarness check = new DeployCheckEnvHarness();
        check.setRpcChainId(true, 8453);
        vm.expectRevert(mismatch);
        check.run();
    }

    function test_DecodeRpcQuantity() public {
        DeployLaunchBaseHarness h = new DeployLaunchBaseHarness();
        (bool ok, uint256 value) = h.decodeRpcQuantity(hex"2105");
        assertTrue(ok);
        assertEq(value, 8453);
        (ok, value) = h.decodeRpcQuantity(hex"014a34"); // "0x14a34" (홀수 자리)는 앞에 0이 붙은 3바이트로 옴
        assertEq(value, 84_532);
        (ok, value) = h.decodeRpcQuantity(hex"7a69");
        assertEq(value, 31_337);
        (ok,) = h.decodeRpcQuantity("");
        assertFalse(ok);
        (ok,) = h.decodeRpcQuantity(new bytes(33));
        assertFalse(ok);
    }

    function testFuzz_DecodeRpcQuantity(uint64 value) public {
        bytes memory full = abi.encodePacked(uint256(value));
        uint256 skip;
        while (skip < 31 && full[skip] == 0) ++skip;
        bytes memory raw = new bytes(32 - skip);
        for (uint256 i; i < raw.length; ++i) {
            raw[i] = full[skip + i];
        }
        (bool ok, uint256 decoded) = new DeployLaunchBaseHarness().decodeRpcQuantity(raw);
        assertTrue(ok);
        assertEq(decoded, value);
    }

    /// @dev 포크가 없는 테스트에서 실제 vm.rpc 경로는 "RPC 없음"으로 끝나야 함 (revert하지 않음).
    function test_RpcChainId_UnavailableWithoutFork() public {
        try vm.activeFork() returns (uint256) {
            vm.skip(true);
        } catch {}
        (bool ok, uint256 chainId) = new DeployLaunchBaseHarness().rpcChainId();
        assertFalse(ok);
        assertEq(chainId, 0);
    }

    // ── 서명자 (forge가 시뮬레이션 뒤에야 거부하던 경우를 미리 차단) ──

    function test_RevertWhen_SenderIsNotALoadedSigner() public {
        DeployEnvHarness harness = _envHarness();
        (address loaded, uint256 key) = makeAddrAndKey("loaded-signer");
        vm.rememberKey(key);
        address other = makeAddr("typo-sender");
        harness.requireUsableSigner(loaded);
        harness.requireUsableSigner(other); // 드라이런: 경고만
        harness.setBroadcastContext(true);
        harness.requireUsableSigner(loaded);
        vm.expectRevert(abi.encodeWithSelector(LaunchBase.LaunchSignerMismatch.selector, other));
        harness.requireUsableSigner(other);
    }

    /// @dev 로드된 서명자가 없으면(--unlocked 로컬 리허설) forge의 전송 단계 검증에 맡김. 기본 sender는 항상 거부.
    function test_UsableSigner_NoLoadedWallets() public {
        DeployEnvHarness harness = _envHarness();
        harness.requireUsableSigner(DEFAULT_SENDER); // 드라이런: 경고만
        harness.setBroadcastContext(true);
        harness.requireUsableSigner(makeAddr("unlocked-sender"));
        vm.expectRevert(LaunchBase.LaunchNoSigner.selector);
        harness.requireUsableSigner(DEFAULT_SENDER);
    }

    // ── 중복 배포 방지 (기록 파일이 없어도) ──

    /// @dev 리뷰 PoC: 기록 파일을 치운 뒤 같은 배포자로 다시 실행 → 예전에는 두 번째 FireToken이 배포됨.
    function test_RevertWhen_MainnetRedeployWithoutRecord() public {
        Deploy.DeployConfig memory cfg = _mainnetCfg();
        Deploy.DeployResult memory first = script.deploy(cfg, deployer);
        uint256 nonce = vm.getNonce(deployer);
        vm.expectRevert(abi.encodeWithSelector(Deploy.DeployAlreadyDeployed.selector, first.token));
        script.deploy(cfg, deployer);
        assertEq(vm.getNonce(deployer), nonce);
    }

    function test_Redeploy_TestnetOnlyWarns() public {
        Deploy.DeployResult memory first = script.deploy(_cfg(), deployer);
        Deploy.DeployResult memory second = script.deploy(_cfg(), deployer);
        assertTrue(second.token != first.token);
        assertEq(FireToken(second.token).balanceOf(deployer), 700_000_000e18);
    }

    /// @dev 검사 범위: nonce 직전부터 MAX_PRIOR_NONCE_SCAN개. FireToken이 아닌 컨트랙트(베스팅)는 무시.
    function test_RequireNoPriorDeployment_ScanWindow() public {
        Deploy.DeployResult memory r = script.deploy(_cfg(), deployer); // 베스팅 nonce 0, 토큰 nonce 1
        vm.chainId(8453);
        script.requireNoPriorDeployment(deployer, 1); // nonce 0(베스팅)만 확인
        vm.expectRevert(abi.encodeWithSelector(Deploy.DeployAlreadyDeployed.selector, r.token));
        script.requireNoPriorDeployment(deployer, 4);
        uint256 window = LaunchParams.MAX_PRIOR_NONCE_SCAN;
        vm.expectRevert(abi.encodeWithSelector(Deploy.DeployAlreadyDeployed.selector, r.token));
        script.requireNoPriorDeployment(deployer, 1 + window); // 토큰이 창의 마지막 칸
        script.requireNoPriorDeployment(deployer, 2 + window); // 창 밖
    }

    // ── 기록: pending → confirm() ──

    /// @dev 시뮬레이션 블록보다 33초 늦게 포함된 경우: confirm이 온체인 일정과 status를 기록.
    function test_Confirm_RecordsOnChainScheduleAndStatus() public {
        Deploy.DeployResult memory r = script.deploy(_cfg(), deployer);
        uint256 onChainStart = r.vestingStart;
        r.blockTimestamp -= 33;
        r.vestingStart -= 33;
        r.vestingEnd -= 33;
        string memory path = _tmpPath("confirm");
        vm.writeJson(script.recordJson(r), path);

        Deploy.DeployResult memory c = script.confirmRecord(path);
        string memory json = _readFile(path);
        _removeFile(path);
        assertEq(c.vestingStart, onChainStart);
        assertEq(vm.parseJsonString(json, ".status"), "confirmed");
        assertEq(vm.parseJsonUint(json, ".vesting.start"), onChainStart);
        assertEq(vm.parseJsonUint(json, ".vesting.end"), onChainStart + 540 days);
        assertEq(vm.parseJsonUint(json, ".deployedAt"), LAUNCH_TIME);
        assertEq(vm.parseJsonUint(json, ".blockTimestamp"), LAUNCH_TIME - 33); // 시뮬레이션 값(하한)은 그대로
        assertEq(vm.parseJsonAddress(json, ".contracts.FireToken"), r.token);
    }

    /// @dev 리뷰 PoC: 서명자가 없어 아무것도 전송되지 않았는데 기록만 남은 경우 → confirm 거부.
    function test_RevertWhen_ConfirmRecordOfUnminedDeployment() public {
        Deploy.DeployResult memory r = script.deploy(_cfg(), deployer);
        address ghost = makeAddr("never-sent");
        r.deployer = ghost;
        r.vesting = vm.computeCreateAddress(ghost, 0);
        r.token = vm.computeCreateAddress(ghost, 1);
        _expectConfirmRevert(r, "unmined", "no code at the recorded FireVesting (broadcast not mined?)");
    }

    /// @dev 4건 중 일부만 채굴된 상태(nonce 부족) → --resume으로 마무리하라는 오류.
    function test_RevertWhen_ConfirmPartialBroadcast() public {
        Deploy.DeployResult memory r = script.deploy(_cfg(), deployer);
        vm.setNonceUnsafe(deployer, uint64(r.deployerNonce + 2)); // 베스팅·토큰 2건만 채굴되고 전송 2건은 미채굴
        _expectConfirmRevert(
            r, "partial", "deployer nonce: not all 4 launch transactions were mined (finish with --resume)"
        );
    }

    /// @dev 리뷰 PoC(F2): 기록의 FireToken을 다른 사람이 실제 FireVesting 주소로 만든 복제본으로 바꾸면
    ///      (복제본도 그 베스팅에 2억을 발행하므로 다른 검사는 모두 통과) 배포자의 CREATE 주소가 아니라서 거부.
    function test_RevertWhen_ConfirmRecordNamesCloneToken() public {
        Deploy.DeployResult memory r = script.deploy(_cfg(), deployer);
        vm.prank(makeAddr("clone-maker"));
        FireToken clone = new FireToken(r.vesting);
        assertEq(clone.balanceOf(r.vesting), 200_000_000e18);
        r.token = address(clone);
        _expectConfirmRevert(r, "clone", "contracts.FireToken != CREATE(deployer, deployerNonce + 1)");

        r = script.deploy(_cfg(), makeAddr("deployer-2"));
        r.deployerNonce += 1; // 기록의 nonce만 바꾼 경우도 유도가 맞지 않음
        _expectConfirmRevert(r, "nonce", "contracts.FireVesting != CREATE(deployer, deployerNonce)");
    }

    /// @dev 유도는 맞지만 그 주소의 컨트랙트가 FireToken이 아닌 경우 (배포자가 다른 것을 만든 기록).
    function test_RevertWhen_ConfirmRecordPointsAtNonFireToken() public {
        Deploy.DeployResult memory r = script.deploy(_cfg(), deployer);
        address other = makeAddr("other-deployer");
        vm.startPrank(other);
        FireVesting vesting = new FireVesting(beneficiary, 180 days, 540 days);
        new DeployNotASafe();
        vm.stopPrank();
        r.deployer = other;
        r.deployerNonce = 0;
        r.vesting = address(vesting);
        r.token = vm.computeCreateAddress(other, 1);
        _expectConfirmRevert(r, "not-fire", "no FireToken at the recorded address (broadcast not mined?)");
    }

    function test_RevertWhen_ConfirmRecordDisagreesWithChain() public {
        Deploy.DeployResult memory r = script.deploy(_cfg(), deployer);
        address realBeneficiary = r.beneficiary;
        r.beneficiary = makeAddr("someone-else");
        _expectConfirmRevert(r, "owner", "vesting.owner() != recorded beneficiary");
        r.beneficiary = realBeneficiary;
        r.vestingStart += 1;
        _expectConfirmRevert(r, "start", "vesting.start() earlier than the simulated record");
        r.vestingStart -= 1;
        r.chainId = 84_532;
        _expectConfirmRevert(r, "chain", "record chainId != current chain");
        r.chainId = block.chainid;
        r.token = r.vesting; // 배포자의 CREATE(nonce + 1)이 아닌 주소
        _expectConfirmRevert(r, "token", "contracts.FireToken != CREATE(deployer, deployerNonce + 1)");

        string memory missing = _tmpPath("confirm-missing");
        vm.expectRevert(abi.encodeWithSelector(Deploy.DeployRecordMissing.selector, missing));
        script.confirmRecord(missing);
    }

    function _expectConfirmRevert(Deploy.DeployResult memory r, string memory tag, string memory check) internal {
        string memory path = _tmpPath(string.concat("confirm-", tag));
        vm.writeJson(script.recordJson(r), path);
        vm.expectRevert(abi.encodeWithSelector(Deploy.DeployConfirmFailed.selector, check));
        script.confirmRecord(path);
        _removeFile(path);
    }

    /// @dev confirm은 기록의 다른 키(.pool, 운영자가 넣은 .lpLock)를 지우지 않음.
    function test_Confirm_KeepsPoolAndLockKeys() public {
        Deploy.DeployResult memory r = script.deploy(_cfg(), deployer);
        string memory path = _tmpPath("confirm-keys");
        vm.writeJson(script.recordJson(r), path);
        vm.writeJson('{"status":"pending","fee":10000}', path, ".pool");
        vm.writeJson('{"locker":"0x0000000000000000000000000000000000000abc"}', path, ".lpLock");
        script.confirmRecord(path);
        string memory json = _readFile(path);
        _removeFile(path);
        assertEq(vm.parseJsonUint(json, ".pool.fee"), 10_000);
        assertEq(vm.parseJsonString(json, ".pool.status"), "pending");
        assertEq(vm.parseJsonAddress(json, ".lpLock.locker"), address(0xabc));
        assertEq(vm.parseJsonString(json, ".status"), "confirmed");
    }

    // ── 주소표 ──

    function test_AddressTable() public {
        assertTrue(UniswapV3Addresses.isSupported(8453));
        assertTrue(UniswapV3Addresses.isSupported(84_532));
        assertFalse(UniswapV3Addresses.isSupported(31_337));
        assertFalse(UniswapV3Addresses.isSupported(1));
        DeployAddressTableHarness h = new DeployAddressTableHarness();
        UniswapV3Addresses.Deployment memory base = h.forChain(8453);
        assertEq(base.factory, 0x33128a8fC17869897dcE68Ed026d694621f6FDfD);
        assertEq(base.positionManager, 0x03a520b32C04BF3bEEf7BEb72E919cf822Ed34f1);
        assertEq(base.weth, 0x4200000000000000000000000000000000000006);
        UniswapV3Addresses.Deployment memory sepolia = h.forChain(84_532);
        assertEq(sepolia.factory, 0x4752ba5DBc23f44D87826276BF6Fd6b1C372aD24);
        assertEq(sepolia.positionManager, 0x27F971cb582BF9E50F397e4d29a5C7A34f11faA2);
        assertEq(sepolia.weth, 0x4200000000000000000000000000000000000006);
        vm.expectRevert(abi.encodeWithSelector(UniswapV3Addresses.UniswapV3AddressesUnsupportedChain.selector, 1));
        h.forChain(1);
    }

    /// @dev 하드웨어 지갑용 사전 서명 permit: 서명에는 마감 시각이 꼭 함께 있어야 함. FIRE_TOKEN 오타도 거부.
    function test_Env_CreatePoolPermitAndChecksum() public {
        DeployCreatePoolEnvHarness harness = new DeployCreatePoolEnvHarness();
        string memory path = _tmpPath("createpool-permit");
        address fire = makeAddr("fire");
        vm.writeJson(string.concat('{"contracts":{"FireToken":"', vm.toString(fire), '"}}'), path);
        bytes memory sig = new bytes(65);
        sig[64] = 0x1b;
        harness.setFakeEnv("PERMIT_SIGNATURE", vm.toString(sig));
        vm.expectRevert(abi.encodeWithSelector(LaunchBase.LaunchMissingEnv.selector, "PERMIT_DEADLINE"));
        harness.loadConfig(path);
        harness.setFakeEnv("PERMIT_DEADLINE", "1800000000");
        CreatePool.PoolConfig memory cfg = harness.loadConfig(path);
        assertEq(cfg.permitSignature, sig);
        assertEq(cfg.permitDeadline, 1_800_000_000);
        assertEq(cfg.fireToken, fire);

        bytes memory typo = bytes(vm.toString(fire));
        for (uint256 i = 41; i > 1; --i) {
            if (typo[i] >= "A") {
                typo[i] = bytes1(uint8(typo[i]) ^ 0x20); // 문자 하나의 대소문자만 바꿈
                break;
            }
        }
        harness.setFakeEnv("FIRE_TOKEN", string(typo));
        vm.expectRevert();
        harness.loadConfig(path);
        _removeFile(path);
    }

    // ── 포맷 · Safe 확인 ──

    function test_Format_UtcDates() public {
        DeployLaunchBaseHarness h = new DeployLaunchBaseHarness();
        assertEq(h.formatUtc(0), "1970-01-01 00:00:00 UTC");
        assertEq(h.formatUtc(1_700_000_000), "2023-11-14 22:13:20 UTC");
        assertEq(h.formatUtc(951_782_400), "2000-02-29 00:00:00 UTC");
        assertEq(h.formatUtc(4_102_444_800), "2100-01-01 00:00:00 UTC");
        assertEq(h.formatUtc(LAUNCH_TIME + 180 days), "2027-03-20 14:13:20 UTC");
        assertEq(h.formatUtc(LAUNCH_TIME + 720 days), "2028-09-10 14:13:20 UTC");
        assertEq(h.formatUtc(253_402_300_799), "9999-12-31 23:59:59 UTC");
    }

    function test_Format_Units() public {
        DeployLaunchBaseHarness h = new DeployLaunchBaseHarness();
        assertEq(h.formatUnits(700_000_000e18, 18), "700,000,000");
        assertEq(h.formatUnits(4_285_714_285, 18), "0.000000004285714285");
        assertEq(h.formatUnits(2.985 ether, 18), "2.985");
        assertEq(h.formatUnits(1234, 0), "1,234");
        assertEq(h.formatUnits(999, 0), "999");
        assertEq(h.formatUnits(0, 18), "0");
        assertEq(h.fmtBps(50), "0.50%");
        assertEq(h.fmtBps(100), "1.00%");
    }

    function test_ProbeSafe() public {
        DeployLaunchBaseHarness h = new DeployLaunchBaseHarness();
        (bool isSafe, uint256 threshold, uint256 owners) = h.probeSafe(_safe(2));
        assertTrue(isSafe);
        assertEq(threshold, 2);
        assertEq(owners, 3);
        (isSafe,,) = h.probeSafe(treasury); // EOA
        assertFalse(isSafe);
        (isSafe,,) = h.probeSafe(address(new DeployNotASafe()));
        assertFalse(isSafe);
        (isSafe,,) = h.probeSafe(address(new DeploySilentFallback()));
        assertFalse(isSafe);
    }

    /// @dev getOwners()가 형식이 틀린 값을 돌려줘도 revert하지 않고 Safe가 아님 (이전에는 abi.decode가 revert).
    /// @dev Safe 소유자·모듈 조회는 형식이 이상한 응답에도 revert하지 않고 ok=false를 돌려줌(메인넷 정책은 실패 = 거부).
    function test_SafeOwnersAndModules_MalformedAnswersDoNotRevert() public {
        DeployLaunchBaseHarness h = new DeployLaunchBaseHarness();
        address safe = _safeWith(2, 3);
        (bool ok, address[] memory owners) = h.safeOwners(safe);
        assertTrue(ok);
        assertEq(owners.length, 3);
        assertEq(owners[0], makeAddr("signer-1"));
        address dirty = address(new DeployDirtyOwners());
        (bool isSafe,,) = h.probeSafe(dirty);
        assertTrue(isSafe); // 형식은 맞음
        (ok, owners) = h.safeOwners(dirty); // 주소 범위를 넘는 값
        assertFalse(ok);
        assertEq(owners.length, 0);
        address[3] memory noOwners =
            [makeAddr("eoa"), address(new DeployNotASafe()), address(new DeploySilentFallback())];
        for (uint256 i; i < noOwners.length; ++i) {
            (ok,) = h.safeOwners(noOwners[i]);
            assertFalse(ok);
        }

        bool known;
        bool hasModules;
        (known, hasModules) = h.safeHasModules(safe);
        assertTrue(known);
        assertFalse(hasModules);
        DeployMockSafe(safe).setModule(makeAddr("module"));
        (known, hasModules) = h.safeHasModules(safe);
        assertTrue(known);
        assertTrue(hasModules);
        address[2] memory unknown = [makeAddr("eoa"), address(new DeployNotASafe())];
        for (uint256 i; i < unknown.length; ++i) {
            (known,) = h.safeHasModules(unknown[i]);
            assertFalse(known);
        }
        for (uint256 mode; mode < 4; ++mode) {
            (known, hasModules) = h.safeHasModules(address(new DeployBadModules(mode)));
            assertFalse(known);
            assertFalse(hasModules);
        }
    }

    /// @dev CREATE 출처 확인: creatorNonce − 1부터 maxScan개만 거슬러 확인 (토큰을 배포 지갑에 묶는 CreatePool 검사).
    function test_CreatedBy_ScanWindow() public {
        DeployLaunchBaseHarness h = new DeployLaunchBaseHarness();
        address creator = makeAddr("creator");
        (bool found, uint256 nonce) = h.createdBy(vm.computeCreateAddress(creator, 1), creator, 4, 256);
        assertTrue(found);
        assertEq(nonce, 1);
        (found,) = h.createdBy(vm.computeCreateAddress(creator, 4), creator, 4, 256); // 아직 만들지 않은 nonce
        assertFalse(found);
        (found,) = h.createdBy(vm.computeCreateAddress(creator, 10), creator, 300, 256); // 창 밖 (44 미만)
        assertFalse(found);
        (found, nonce) = h.createdBy(vm.computeCreateAddress(creator, 44), creator, 300, 256);
        assertTrue(found);
        assertEq(nonce, 44);
        (found,) = h.createdBy(vm.computeCreateAddress(makeAddr("other"), 1), creator, 4, 256);
        assertFalse(found);
    }

    /// @dev 서명 목록 파싱(0x + 130자 × 1~16)과 Safe 소유자 서명 검사의 경계.
    function test_ProofSignatureList_Limits() public {
        DeployLaunchBaseHarness h = new DeployLaunchBaseHarness();
        string memory one = vm.toString(_signProof(beneficiaryKey, "BENEFICIARY", beneficiary));
        string memory body = vm.replace(one, "0x", "");
        string memory sixteen = "0x";
        for (uint256 i; i < 16; ++i) {
            sixteen = string.concat(sixteen, body);
        }
        (bool ok, bytes memory sigs) = h.parseProof(sixteen);
        assertTrue(ok);
        assertEq(sigs.length, 16 * 65);
        string[4] memory bad = ["0x", "", string.concat(sixteen, body), string.concat("1x", body)];
        for (uint256 i; i < bad.length; ++i) {
            (ok,) = h.parseProof(bad[i]);
            assertFalse(ok);
        }
    }

    /// @dev Safe 소유자 서명 검사의 결과 코드 (임계값·누락·길이·개수 상한·ecrecover 실패·가변 서명).
    function test_CheckOwners_Results() public {
        DeployLaunchBaseHarness h = new DeployLaunchBaseHarness();
        address safe = _safeWith(2, 3);
        (, address[] memory owners) = h.safeOwners(safe);
        string memory text = _proofText("BENEFICIARY", safe, block.chainid);
        bytes memory first = _signText(_ownerKey(1), text);
        bytes memory good = bytes.concat(first, _signText(_ownerKey(2), text));
        (ControlProof.Result result, uint256 signers,) = h.checkOwners(text, owners, 2, good);
        assertEq(uint8(result), uint8(ControlProof.Result.Valid));
        assertEq(signers, 2);
        (result,,) = h.checkOwners(text, owners, 3, good);
        assertEq(uint8(result), uint8(ControlProof.Result.NotEnoughOwners));
        (result,,) = h.checkOwners(text, owners, 2, "");
        assertEq(uint8(result), uint8(ControlProof.Result.Missing));
        (result,,) = h.checkOwners(text, owners, 2, new bytes(64));
        assertEq(uint8(result), uint8(ControlProof.Result.BadLength));
        (result,,) = h.checkOwners(text, owners, 2, new bytes(17 * 65)); // 16개 초과
        assertEq(uint8(result), uint8(ControlProof.Result.BadLength));
        (result, signers,) = h.checkOwners(text, owners, 2, bytes.concat(first, new bytes(65)));
        assertEq(uint8(result), uint8(ControlProof.Result.BadSignature));
        assertEq(signers, 1);
        (result,,) = h.checkOwners(text, owners, 2, bytes.concat(first, _highS(_signText(_ownerKey(2), text))));
        assertEq(uint8(result), uint8(ControlProof.Result.HighS));
    }

    /// @dev 같은 서명자의 가변(malleable) 서명: s → n − s, v 뒤집기.
    function _highS(bytes memory sig) internal pure returns (bytes memory) {
        (bytes32 r, bytes32 sv) = abi.decode(sig, (bytes32, bytes32));
        uint256 n = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;
        return abi.encodePacked(r, bytes32(n - uint256(sv)), uint8(sig[64]) == 27 ? uint8(28) : uint8(27));
    }

    /// @dev 코드 동일성 도구의 경계: 코드 없음·start() 없음·범위 밖 start, 메타데이터 없는 코드, 짧은 입력.
    function test_LaunchCode_EdgeInputs() public {
        DeployLaunchBaseHarness h = new DeployLaunchBaseHarness();
        Deploy.DeployResult memory r = script.deploy(_cfg(), deployer);
        assertEq(h.vestingStatus(r.vesting), LaunchCode.MATCH);
        assertEq(h.tokenStatus(r.token), LaunchCode.MATCH);
        assertEq(h.tokenStatus(r.vesting), LaunchCode.MISMATCH);
        assertEq(h.vestingStatus(r.token), LaunchCode.MISMATCH); // start() 없음
        assertEq(h.vestingStatus(makeAddr("eoa")), LaunchCode.MISMATCH);
        assertEq(h.tokenStatus(makeAddr("eoa")), LaunchCode.MISMATCH);
        assertEq(h.vestingStatus(address(new DeployFakeStart(5))), LaunchCode.MISMATCH); // start < 180일
        assertEq(h.vestingStatus(address(new DeployFakeStart(1 << 70))), LaunchCode.MISMATCH); // uint64 초과
        assertEq(h.vestingStatus(address(new DeployFakeStart(r.vestingStart))), LaunchCode.MISMATCH);

        assertEq(h.executableLength(hex"00"), 1);
        assertEq(h.executableLength(hex"ffff"), 2); // 메타데이터 길이가 코드보다 김
        assertEq(h.executableLength(hex"6001600260036004"), 8); // CBOR map 헤더가 아님
        assertEq(h.executableLength(abi.encodePacked(hex"6001", hex"a1", hex"0000", hex"0003")), 2);
        assertFalse(h.sameExecutable(hex"00", hex"0000"));
        (uint256 replaced,) = h.replaceWord(hex"00", bytes32(0), bytes32(uint256(1)));
        assertEq(replaced, 0);
        bytes memory code = abi.encodePacked(hex"7f", bytes32(uint256(7)), hex"7f", bytes32(uint256(7)));
        bytes memory patched;
        (replaced, patched) = h.replaceWord(code, bytes32(uint256(7)), bytes32(uint256(9)));
        assertEq(replaced, 2);
        assertEq(patched, abi.encodePacked(hex"7f", bytes32(uint256(9)), hex"7f", bytes32(uint256(9))));
    }

    /// @dev 런칭 계획 하한은 토큰 순서에 맞춰 amountMin을 넣음 (FIRE가 token0 / token1).
    function test_PlanMinLiquidity_BothTokenOrders() public {
        DeployLaunchBaseHarness h = new DeployLaunchBaseHarness();
        uint256 fireMin = PoolMath.minAmount(700_000_000e18, 50);
        uint256 ethMin = PoolMath.minAmount(3 ether, 50);
        assertEq(h.planMinLiquidity(true, 700_000_000e18, 3 ether, 50), PoolMath.minFullRangeLiquidity(fireMin, ethMin));
        assertEq(
            h.planMinLiquidity(false, 700_000_000e18, 3 ether, 50), PoolMath.minFullRangeLiquidity(ethMin, fireMin)
        );
    }

    function test_ProbeSafe_MalformedOwnersDoNotRevert() public {
        DeployLaunchBaseHarness h = new DeployLaunchBaseHarness();
        (bool isSafe, uint256 threshold, uint256 owners) =
            h.probeSafe(address(new DeployMalformedOwners(0x40, 3, 0x40))); // 오프셋이 0x20이 아님
        assertFalse(isSafe);
        assertEq(threshold, 2);
        assertEq(owners, 0);
        (isSafe,,) = h.probeSafe(address(new DeployMalformedOwners(0x20, 1000, 0x40))); // 길이만 크고 본문 없음
        assertFalse(isSafe);
        (isSafe,,) = h.probeSafe(address(new DeployMalformedOwners(0x20, 1, 0x20))); // 32바이트만 반환
        assertFalse(isSafe);
        (isSafe,, owners) = h.probeSafe(address(new DeployMalformedOwners(0x20, 0, 0x40))); // 소유자 0명
        assertFalse(isSafe);
        assertEq(owners, 0);
    }

    /// @dev EIP-7702 위임 지정자는 정확히 0xef0100 ‖ 20바이트(23바이트). 같은 길이의 다른 코드·EOA·일반 컨트랙트는 아님.
    ///      (0xef로 시작하는 다른 코드는 EIP-3541로 체인에 존재할 수 없고 revm도 만들지 않음)
    function test_IsDelegatedEOA_ExactDesignatorOnly() public {
        DeployLaunchBaseHarness h = new DeployLaunchBaseHarness();
        address target = address(new DeployConstantSafe(2, 3));
        address[3] memory accounts = [makeAddr("7702-a"), makeAddr("7702-b"), makeAddr("7702-c")];
        vm.etch(accounts[0], abi.encodePacked(hex"ef0100", target));
        vm.etch(accounts[1], abi.encodePacked(hex"600100", target)); // 23바이트지만 지정자가 아님
        assertEq(accounts[1].code.length, 23);
        assertTrue(h.isDelegatedEOA(accounts[0]));
        assertFalse(h.isDelegatedEOA(accounts[1]));
        assertFalse(h.isDelegatedEOA(accounts[2])); // 코드 없음
        assertFalse(h.isDelegatedEOA(target)); // 일반 컨트랙트
        (bool ok, bool delegated,,) = h.isMultisig(target);
        assertTrue(ok);
        assertFalse(delegated);
        (ok,,,) = h.isMultisig(_safe(1));
        assertFalse(ok); // 1-of-3
    }
}

// ───────────────────────── 소유 증명 (BENEFICIARY / AIRDROP_WALLET) ─────────────────────────

/**
 * @dev 수익자는 수락 절차 없이 FireVesting owner가 되므로(에어드롭은 단순 전송), 주소를 통제한다는 서명 증명을 확인.
 *      cast wallet sign으로 만든 실제 서명(anvil 기본 개발 키, 공개 값)으로 운영자 경로 전체를 검증함.
 */
contract DeployProofTest is DeployFixture {
    /// @dev anvil 기본 계정 #0, #1 (개인 키가 공개된 개발용 주소).
    address internal constant ANVIL_0 = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;
    address internal constant ANVIL_1 = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;
    /// @dev cast wallet sign --private-key <anvil #0> "FIRE launch control proof | role=BENEFICIARY | address=0xf39F…2266 | chainId=8453"
    string internal constant CAST_SIG_BENEFICIARY_8453 =
        "0x031cc798e8452a134101de052604cd4aae7336742fe5ebc1c379b3391aeb9ba51faad43cc8dbc29f147910d845c5f94a4938a0c9d3e09c600390a151b3fd95cd1b";
    /// @dev cast wallet sign --private-key <anvil #1> "FIRE launch control proof | role=AIRDROP_WALLET | address=0x7099…79C8 | chainId=8453"
    string internal constant CAST_SIG_AIRDROP_8453 =
        "0x5ecbe9ae97c80aac552265c5f3c4644a3f6ef626fcda1230dbf9585414f055b60fe07a3ac17c05be46704488554c5af9a4901196d31406d37d48b3ee6e8429cc1c";
    /// @dev 같은 anvil #0의 Base Sepolia(84532) 리허설 서명. 메인넷에서 재사용하면 거부되어야 함.
    string internal constant CAST_SIG_BENEFICIARY_84532 =
        "0x1c80a0be81b804578ef40d56ea1f4360ba0ef2f37e8f14295ba3dc3d626da68c0adf6dc9f48a00b1d7eff98ef8ce507d09ed1dbe10865f71bef1ad45e9ce71af1b";
    string internal constant MALFORMED = "expected 0x followed by 130 hex characters per 65-byte signature (max 16)";

    DeployLaunchBaseHarness internal h;

    function setUp() public override {
        super.setUp();
        h = new DeployLaunchBaseHarness();
    }

    // ── 메시지 형식 ──

    function test_ProofMessage_ExactFormat() public view {
        assertEq(
            h.proofMessage("BENEFICIARY", ANVIL_0, 8453),
            "FIRE launch control proof | role=BENEFICIARY | address=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266 | chainId=8453"
        );
        assertEq(
            h.proofMessage("AIRDROP_WALLET", ANVIL_1, 84_532),
            "FIRE launch control proof | role=AIRDROP_WALLET | address=0x70997970C51812dc3A010C7d01b50e0d17dc79C8 | chainId=84532"
        );
        assertEq(h.proofMessage("BENEFICIARY", beneficiary, 8453), _proofText("BENEFICIARY", beneficiary, 8453));
        assertEq(script.BENEFICIARY_PROOF_ENV(), "BENEFICIARY_PROOF_SIG");
        assertEq(script.AIRDROP_WALLET_PROOF_ENV(), "AIRDROP_WALLET_PROOF_SIG");
    }

    /// @dev cast wallet sign 출력(r ‖ s ‖ v, v = 0x1b/0x1c)을 그대로 검증 (EIP-191 personal_sign 다이제스트 일치).
    function test_Proof_CastSignatureVerifies() public view {
        (bool ok, bytes memory sig) = h.parseProof(CAST_SIG_BENEFICIARY_8453);
        assertTrue(ok);
        assertEq(sig.length, 65);
        (ControlProof.Result result, address recovered) =
            h.checkProof(h.proofMessage("BENEFICIARY", ANVIL_0, 8453), ANVIL_0, sig);
        assertEq(uint8(result), uint8(ControlProof.Result.Valid));
        assertEq(recovered, ANVIL_0);
        // 같은 서명이라도 체인 ID가 다른 메시지에는 통과하지 못함
        (result,) = h.checkProof(h.proofMessage("BENEFICIARY", ANVIL_0, 84_532), ANVIL_0, sig);
        assertEq(uint8(result), uint8(ControlProof.Result.WrongSigner));
    }

    /// @dev 운영자 경로 그대로: 환경 변수(BENEFICIARY_PROOF_SIG 등)에 cast 서명을 넣고 메인넷 run().
    ///      Sepolia 리허설 서명을 메인넷에 재사용하면 거부.
    function test_Proof_MainnetRunWithCastSignaturesFromEnv() public {
        vm.chainId(8453);
        DeployEnvHarness harness = new DeployEnvHarness();
        harness.setFakeEnv("BENEFICIARY", vm.toString(ANVIL_0));
        harness.setFakeEnv("TREASURY_SAFE", vm.toString(_safe(2)));
        harness.setFakeEnv("AIRDROP_WALLET", vm.toString(ANVIL_1));
        harness.setFakeEnv("CONFIRM_MAINNET", "I_UNDERSTAND");
        harness.setFakeEnv("AIRDROP_WALLET_PROOF_SIG", CAST_SIG_AIRDROP_8453);

        vm.expectRevert(
            abi.encodeWithSelector(
                Deploy.DeployProofMissing.selector, "BENEFICIARY_PROOF_SIG", _proofText("BENEFICIARY", ANVIL_0, 8453)
            )
        );
        harness.run();

        harness.setFakeEnv("BENEFICIARY_PROOF_SIG", CAST_SIG_BENEFICIARY_84532);
        vm.expectPartialRevert(Deploy.DeployProofWrongSigner.selector);
        harness.run();

        harness.setFakeEnv("BENEFICIARY_PROOF_SIG", CAST_SIG_BENEFICIARY_8453);
        Deploy.DeployResult memory r = harness.run();
        assertEq(FireVesting(payable(r.vesting)).owner(), ANVIL_0);
        assertEq(FireToken(r.token).balanceOf(ANVIL_1), 50_000_000e18);
    }

    function test_Env_LoadConfigReadsProofs() public {
        DeployEnvHarness harness = _envHarness();
        Deploy.DeployConfig memory cfg = harness.loadConfig();
        assertEq(cfg.beneficiaryProof.length, 0);
        assertEq(cfg.airdropWalletProof.length, 0);

        bytes memory b = _signProof(beneficiaryKey, "BENEFICIARY", beneficiary);
        bytes memory a = _signProof(airdropKey, "AIRDROP_WALLET", airdrop);
        harness.setFakeEnv("BENEFICIARY_PROOF_SIG", vm.toString(b));
        // 16진 대문자도 허용 (접두사는 소문자 0x)
        harness.setFakeEnv("AIRDROP_WALLET_PROOF_SIG", vm.replace(vm.toUppercase(vm.toString(a)), "0X", "0x"));
        cfg = harness.loadConfig();
        assertEq(cfg.beneficiaryProof, b);
        assertEq(cfg.airdropWalletProof, a);
    }

    // ── 서명 검증 실패 ──

    function test_RevertWhen_MainnetProofMissing() public {
        Deploy.DeployConfig memory cfg = _mainnetCfg();
        cfg.beneficiaryProof = "";
        vm.expectRevert(
            abi.encodeWithSelector(
                Deploy.DeployProofMissing.selector,
                "BENEFICIARY_PROOF_SIG",
                _proofText("BENEFICIARY", beneficiary, 8453)
            )
        );
        script.deploy(cfg, deployer);

        cfg = _mainnetCfg();
        cfg.airdropWalletProof = "";
        vm.expectRevert(
            abi.encodeWithSelector(
                Deploy.DeployProofMissing.selector,
                "AIRDROP_WALLET_PROOF_SIG",
                _proofText("AIRDROP_WALLET", airdrop, 8453)
            )
        );
        script.deploy(cfg, deployer);
        assertEq(vm.getNonce(deployer), 0); // 아무것도 전송되지 않음
    }

    function test_RevertWhen_ProofSignedByAnotherKey() public {
        Deploy.DeployConfig memory cfg = _mainnetCfg();
        (address other, uint256 otherKey) = makeAddrAndKey("not-the-beneficiary");
        cfg.beneficiaryProof = _signProof(otherKey, "BENEFICIARY", beneficiary);
        vm.expectRevert(
            abi.encodeWithSelector(Deploy.DeployProofWrongSigner.selector, "BENEFICIARY_PROOF_SIG", beneficiary, other)
        );
        script.deploy(cfg, deployer);
        // 역할을 바꿔 쓴 경우: 수익자 키로 에어드롭 메시지에 서명
        cfg = _mainnetCfg();
        cfg.airdropWalletProof = _signProof(beneficiaryKey, "AIRDROP_WALLET", airdrop);
        vm.expectRevert(
            abi.encodeWithSelector(
                Deploy.DeployProofWrongSigner.selector, "AIRDROP_WALLET_PROOF_SIG", airdrop, beneficiary
            )
        );
        script.deploy(cfg, deployer);
    }

    /// @dev 올바른 키라도 메시지(역할·체인·주소·EIP-55 표기)가 하나라도 다르면 다른 서명자로 복원되어 거부.
    function test_RevertWhen_ProofIsForAnotherMessage() public {
        Deploy.DeployConfig memory cfg = _mainnetCfg();
        string[4] memory wrong = [
            _proofText("AIRDROP_WALLET", beneficiary, 8453),
            _proofText("BENEFICIARY", beneficiary, 84_532),
            _proofText("BENEFICIARY", airdrop, 8453),
            vm.replace(
                _proofText("BENEFICIARY", beneficiary, 8453),
                vm.toString(beneficiary),
                vm.toLowercase(vm.toString(beneficiary))
            )
        ];
        for (uint256 i; i < wrong.length; ++i) {
            cfg.beneficiaryProof = _signText(beneficiaryKey, wrong[i]);
            vm.expectPartialRevert(Deploy.DeployProofWrongSigner.selector);
            script.deploy(cfg, deployer);
        }
    }

    function test_RevertWhen_ProofEnvMalformed() public {
        DeployEnvHarness harness = _envHarness();
        bytes memory sig = _signProof(beneficiaryKey, "BENEFICIARY", beneficiary);
        string memory good = vm.toString(sig);
        bytes memory compact = new bytes(64); // EIP-2098 길이(64바이트)는 지원하지 않음
        for (uint256 i; i < 64; ++i) {
            compact[i] = sig[i];
        }
        string[6] memory bad = [
            "0x1234",
            vm.replace(good, "0x", ""), // 접두사 없음
            vm.toUppercase(good), // "0X" 접두사
            string.concat(good, "00"), // 66바이트
            vm.toString(compact),
            string.concat(good, " ") // 공백
        ];
        for (uint256 i; i < bad.length; ++i) {
            harness.setFakeEnv("BENEFICIARY_PROOF_SIG", bad[i]);
            vm.expectRevert(
                abi.encodeWithSelector(Deploy.DeployProofInvalid.selector, "BENEFICIARY_PROOF_SIG", MALFORMED)
            );
            harness.loadConfig();
        }
        bytes memory nonHex = bytes(good);
        nonHex[10] = "g";
        harness.setFakeEnv("BENEFICIARY_PROOF_SIG", string(nonHex));
        vm.expectRevert(abi.encodeWithSelector(Deploy.DeployProofInvalid.selector, "BENEFICIARY_PROOF_SIG", MALFORMED));
        harness.loadConfig();
        // 형식 검사는 모든 체인에서 (로컬 포함) 수행
        harness.setFakeEnv("BENEFICIARY_PROOF_SIG", "");
        harness.setFakeEnv("AIRDROP_WALLET_PROOF_SIG", "0x");
        vm.expectRevert(
            abi.encodeWithSelector(Deploy.DeployProofInvalid.selector, "AIRDROP_WALLET_PROOF_SIG", MALFORMED)
        );
        harness.loadConfig();
    }

    /// @dev 바이트 수준 오류: 길이(EIP-2098 64바이트 포함), ecrecover 실패, 상위 절반 s(가변 서명), 잘못된 v.
    function test_RevertWhen_ProofBytesInvalid() public {
        Deploy.DeployConfig memory cfg = _mainnetCfg();
        bytes memory good = cfg.beneficiaryProof;
        (bytes32 r, bytes32 sv) = abi.decode(good, (bytes32, bytes32));
        uint8 v = uint8(good[64]);

        cfg.beneficiaryProof = abi.encodePacked(r, sv); // 64바이트 (EIP-2098 압축 형식은 지원하지 않음)
        _expectInvalid(cfg, "not a 65-byte signature");
        cfg.beneficiaryProof = bytes.concat(good, good); // EOA는 서명 1개만 (여러 개는 Safe 소유자 서명용)
        _expectInvalid(cfg, "not a 65-byte signature");
        cfg.beneficiaryProof = abi.encodePacked(bytes32(0), bytes32(0), uint8(27));
        _expectInvalid(cfg, "invalid signature (ecrecover failed)");
        cfg.beneficiaryProof = abi.encodePacked(r, sv, uint8(29));
        _expectInvalid(cfg, "invalid signature (ecrecover failed)");
        uint256 n = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;
        cfg.beneficiaryProof = abi.encodePacked(r, bytes32(n - uint256(sv)), v == 27 ? uint8(28) : uint8(27));
        _expectInvalid(cfg, "malleable signature (s in the upper half); sign again with cast wallet sign");
    }

    function _expectInvalid(Deploy.DeployConfig memory cfg, string memory reason) internal {
        vm.expectRevert(abi.encodeWithSelector(Deploy.DeployProofInvalid.selector, "BENEFICIARY_PROOF_SIG", reason));
        script.deploy(cfg, deployer);
    }

    /// @dev v를 0/1로 내보내는 서명 도구도 허용 (27/28로 정규화). 입력 바이트는 바뀌지 않음.
    function test_Proof_AcceptsZeroOneRecoveryId() public {
        Deploy.DeployConfig memory cfg = _mainnetCfg();
        cfg.beneficiaryProof[64] = bytes1(uint8(cfg.beneficiaryProof[64]) - 27);
        bytes memory before = bytes.concat(cfg.beneficiaryProof);
        (ControlProof.Result result,) =
            h.checkProof(_proofText("BENEFICIARY", beneficiary, 8453), beneficiary, cfg.beneficiaryProof);
        assertEq(uint8(result), uint8(ControlProof.Result.Valid));
        assertEq(cfg.beneficiaryProof, before);
        assertEq(FireVesting(payable(script.deploy(cfg, deployer).vesting)).owner(), beneficiary);
    }

    // ── 주소 종류: Safe / 일반 컨트랙트 / EIP-7702 ──

    /**
     * @dev 리뷰 PoC(F6) 회귀: Safe 수령 주소도 소유 증명이 필요함. 같은 메시지(address = Safe)에 Safe의 현재 소유자들이
     *      각자 서명한 값을 이어 붙여 제출(서로 다른 소유자 ≥ 임계값, 순서 무관). 예전에는 Safe면 서명 없이 통과해
     *      주소 오염용 Safe(다른 사람 소유)도 2억 FIRE 베스팅의 owner가 될 수 있었음.
     */
    function test_Proof_SafeRecipientsNeedOwnerSignatures() public {
        Deploy.DeployConfig memory cfg = _mainnetCfg();
        cfg.beneficiary = _safeWith(1, 1);
        cfg.airdropWallet = _safeWith(2, 3);
        cfg.beneficiaryProof = "";
        cfg.airdropWalletProof = "";
        vm.expectRevert(
            abi.encodeWithSelector(
                Deploy.DeployProofMissing.selector,
                "BENEFICIARY_PROOF_SIG",
                _proofText("BENEFICIARY", cfg.beneficiary, 8453)
            )
        );
        script.deploy(cfg, deployer);

        cfg.beneficiaryProof = _ownerProof("BENEFICIARY", cfg.beneficiary, _indexes(1));
        cfg.airdropWalletProof = _ownerProof("AIRDROP_WALLET", cfg.airdropWallet, _indexes(2)); // 2-of-3에 1명
        vm.expectRevert(
            abi.encodeWithSelector(Deploy.DeployProofNotEnoughOwners.selector, "AIRDROP_WALLET_PROOF_SIG", 1, 2)
        );
        script.deploy(cfg, deployer);

        cfg.airdropWalletProof = _ownerProof("AIRDROP_WALLET", cfg.airdropWallet, _indexes(2, 2)); // 같은 소유자 두 번
        vm.expectRevert(
            abi.encodeWithSelector(
                Deploy.DeployProofInvalid.selector, "AIRDROP_WALLET_PROOF_SIG", "the same Safe owner signed twice"
            )
        );
        script.deploy(cfg, deployer);

        // 소유자가 아닌 키의 서명 (예: 다른 사람의 비슷한 주소 Safe를 붙여 넣은 운영자가 자기 키로 서명)
        cfg.airdropWalletProof = bytes.concat(
            _ownerProof("AIRDROP_WALLET", cfg.airdropWallet, _indexes(1)),
            _signProof(beneficiaryKey, "AIRDROP_WALLET", cfg.airdropWallet)
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                Deploy.DeployProofWrongSigner.selector, "AIRDROP_WALLET_PROOF_SIG", cfg.airdropWallet, beneficiary
            )
        );
        script.deploy(cfg, deployer);

        // 다른 역할의 메시지에 한 서명 (수익자 메시지를 에어드롭 Safe 소유자가 서명) → 다른 서명자로 복원
        cfg.airdropWalletProof = bytes.concat(
            _signProof(_ownerKey(1), "BENEFICIARY", cfg.airdropWallet),
            _signProof(_ownerKey(2), "BENEFICIARY", cfg.airdropWallet)
        );
        vm.expectPartialRevert(Deploy.DeployProofWrongSigner.selector);
        script.deploy(cfg, deployer);

        cfg.airdropWalletProof = _ownerProof("AIRDROP_WALLET", cfg.airdropWallet, _indexes(3, 1)); // 순서 무관
        Deploy.DeployResult memory r = script.deploy(cfg, deployer);
        assertEq(FireVesting(payable(r.vesting)).owner(), cfg.beneficiary);
        assertEq(FireToken(r.token).balanceOf(cfg.airdropWallet), 50_000_000e18);
    }

    /// @dev Base Sepolia: Safe 수령 주소의 서명이 없으면 경고만, 제출하면 메인넷과 같이 검증.
    function test_Proof_SepoliaSafeRecipientWarnsOrVerifies() public {
        vm.chainId(84_532);
        Deploy.DeployConfig memory cfg = _proven(_cfg());
        cfg.beneficiary = _safeWith(2, 3);
        cfg.beneficiaryProof = "";
        script.deploy(cfg, deployer); // 경고만

        cfg.beneficiaryProof = _ownerProof("BENEFICIARY", cfg.beneficiary, _indexes(1));
        vm.expectRevert(
            abi.encodeWithSelector(Deploy.DeployProofNotEnoughOwners.selector, "BENEFICIARY_PROOF_SIG", 1, 2)
        );
        script.deploy(cfg, makeAddr("deployer-2"));
    }

    /**
     * @dev 리뷰 PoC(F6) 회귀: 모듈이 활성화된 Safe는 모듈 키 하나가 서명 없이 자산을 옮길 수 있어 2-of-3 규칙을
     *      무력화함 → 메인넷 트레저리·Safe 수령 주소 모두 거부. 모듈을 읽을 수 없는 Safe(getModulesPaginated 없음)도 같음.
     *      테스트넷은 경고만.
     */
    function test_RevertWhen_MainnetSafeHasModules() public {
        Deploy.DeployConfig memory cfg = _mainnetCfg();
        DeployMockSafe(cfg.treasurySafe).setModule(makeAddr("module"));
        vm.expectRevert(abi.encodeWithSelector(Deploy.DeployTreasurySafeHasModules.selector, cfg.treasurySafe));
        script.deploy(cfg, deployer);

        cfg.treasurySafe = address(new DeployLegacySafe());
        vm.expectRevert(abi.encodeWithSelector(Deploy.DeployTreasurySafeHasModules.selector, cfg.treasurySafe));
        script.deploy(cfg, deployer);

        cfg = _mainnetCfg();
        address safeBeneficiary = _safeWith(1, 1);
        DeployMockSafe(safeBeneficiary).setModule(makeAddr("module"));
        cfg.beneficiary = safeBeneficiary;
        cfg.beneficiaryProof = _ownerProof("BENEFICIARY", safeBeneficiary, _indexes(1));
        vm.expectRevert(
            abi.encodeWithSelector(Deploy.DeployProofSafeHasModules.selector, "BENEFICIARY", safeBeneficiary)
        );
        script.deploy(cfg, deployer);
        assertEq(vm.getNonce(deployer), 0);

        vm.chainId(84_532); // 테스트넷: 경고 후 진행
        cfg.beneficiaryProof = _ownerProof("BENEFICIARY", safeBeneficiary, _indexes(1));
        cfg.airdropWalletProof = _signProof(airdropKey, "AIRDROP_WALLET", airdrop);
        cfg.treasurySafe = address(new DeployLegacySafe());
        assertEq(FireVesting(payable(script.deploy(cfg, deployer).vesting)).owner(), safeBeneficiary);
    }

    /// @dev 코드가 있지만 Safe가 아닌 주소(임계값 0 Safe 포함)는 메인넷에서 거부, 테스트넷은 경고만.
    function test_RevertWhen_MainnetRecipientIsNonSafeContract() public {
        Deploy.DeployConfig memory cfg = _mainnetCfg();
        address[3] memory contracts =
            [address(new DeployNotASafe()), address(new DeploySilentFallback()), _safeWith(0, 3)];
        for (uint256 i; i < contracts.length; ++i) {
            cfg.beneficiary = contracts[i];
            vm.expectRevert(
                abi.encodeWithSelector(Deploy.DeployProofAccountNotSafe.selector, "BENEFICIARY", contracts[i])
            );
            script.deploy(cfg, deployer);
        }
        cfg = _mainnetCfg();
        cfg.airdropWallet = address(new DeployNotASafe());
        vm.expectRevert(
            abi.encodeWithSelector(Deploy.DeployProofAccountNotSafe.selector, "AIRDROP_WALLET", cfg.airdropWallet)
        );
        script.deploy(cfg, deployer);

        vm.chainId(84_532);
        cfg = _proven(_cfg());
        cfg.beneficiary = address(new DeployNotASafe());
        script.deploy(cfg, deployer); // 경고만
    }

    /**
     * @dev EIP-7702 위임 EOA: 위임 대상이 2-of-3 Safe처럼 응답해도 Safe로 보지 않고 원래 EOA 키의 서명을 요구.
     *      vm.signAndAttachDelegation으로 실제 7702 위임(다음 호출에 적용)을 만든 뒤 확인.
     */
    function test_Proof_EIP7702DelegatedEOA_NeedsItsOwnSignature() public {
        vm.setEvmVersion("prague");
        (address eoa, uint256 key) = makeAddrAndKey("beneficiary-7702");
        address safeLike = address(new DeployConstantSafe(2, 3));
        vm.signAndAttachDelegation(safeLike, key);
        assertEq(DeployConstantSafe(eoa).getThreshold(), 2); // 위임이 적용되는 다음 호출
        assertEq(eoa.code, abi.encodePacked(hex"ef0100", safeLike));
        assertTrue(h.isDelegatedEOA(eoa));
        (bool isSafe,,) = h.probeSafe(eoa);
        assertTrue(isSafe, "the delegate answers like a Safe");
        (bool multisig, bool delegated,,) = h.isMultisig(eoa);
        assertFalse(multisig);
        assertTrue(delegated);

        Deploy.DeployConfig memory cfg = _mainnetCfg();
        cfg.beneficiary = eoa;
        cfg.beneficiaryProof = "";
        vm.expectRevert(
            abi.encodeWithSelector(
                Deploy.DeployProofMissing.selector, "BENEFICIARY_PROOF_SIG", _proofText("BENEFICIARY", eoa, 8453)
            )
        );
        script.deploy(cfg, deployer);

        cfg.beneficiaryProof = _signProof(beneficiaryKey, "BENEFICIARY", eoa); // 다른 키
        vm.expectRevert(
            abi.encodeWithSelector(Deploy.DeployProofWrongSigner.selector, "BENEFICIARY_PROOF_SIG", eoa, beneficiary)
        );
        script.deploy(cfg, deployer);

        cfg.beneficiaryProof = _signProof(key, "BENEFICIARY", eoa);
        Deploy.DeployResult memory r = script.deploy(cfg, deployer);
        assertEq(FireVesting(payable(r.vesting)).owner(), eoa);
    }

    // ── 체인 정책 ──

    /// @dev Base Sepolia: 서명이 없으면 경고만, 제출하면 메인넷과 똑같이 검증.
    function test_Proof_SepoliaWarnsWhenMissingButVerifiesWhenProvided() public {
        vm.chainId(84_532);
        Deploy.DeployConfig memory cfg = _cfg();
        assertEq(FireVesting(payable(script.deploy(cfg, deployer).vesting)).owner(), beneficiary);

        cfg = _proven(cfg);
        script.deploy(cfg, makeAddr("deployer-2"));

        cfg.airdropWalletProof = _signProof(beneficiaryKey, "AIRDROP_WALLET", airdrop);
        vm.expectRevert(
            abi.encodeWithSelector(
                Deploy.DeployProofWrongSigner.selector, "AIRDROP_WALLET_PROOF_SIG", airdrop, beneficiary
            )
        );
        script.deploy(cfg, makeAddr("deployer-3"));

        cfg.airdropWalletProof = new bytes(64);
        vm.expectRevert(
            abi.encodeWithSelector(
                Deploy.DeployProofInvalid.selector, "AIRDROP_WALLET_PROOF_SIG", "not a 65-byte signature"
            )
        );
        script.deploy(cfg, makeAddr("deployer-3"));
    }

    /// @dev 로컬 anvil(31337)은 증명을 생략 (잘못된 서명 바이트도 검사하지 않음).
    function test_Proof_LocalChainSkips() public {
        Deploy.DeployConfig memory cfg = _cfg();
        cfg.beneficiaryProof = new bytes(65);
        cfg.airdropWalletProof = hex"1234";
        assertEq(script.deploy(cfg, deployer).chainId, 31_337);
    }

    function test_ProofDescribe_EveryResult() public view {
        assertEq(h.describeProof(ControlProof.Result.Valid), "valid");
        assertEq(h.describeProof(ControlProof.Result.Missing), "not provided");
        assertEq(h.describeProof(ControlProof.Result.BadLength), "not a 65-byte signature");
        assertEq(h.describeProof(ControlProof.Result.BadSignature), "invalid signature (ecrecover failed)");
        assertEq(
            h.describeProof(ControlProof.Result.HighS),
            "malleable signature (s in the upper half); sign again with cast wallet sign"
        );
        assertEq(
            h.describeProof(ControlProof.Result.WrongSigner),
            "signed by a different address (wrong key, or role/address/chainId differ from the message)"
        );
        assertEq(
            h.describeProof(ControlProof.Result.NotEnoughOwners), "fewer Safe owner signatures than the Safe threshold"
        );
        assertEq(h.describeProof(ControlProof.Result.DuplicateSigner), "the same Safe owner signed twice");
    }

    // ── printProofMessages() ──

    function test_PrintProofMessages_ReturnsExactMessages() public {
        DeployEnvHarness harness = _envHarness();
        vm.chainId(8453);
        (string memory b, string memory a) = harness.printProofMessages();
        assertEq(b, _proofText("BENEFICIARY", beneficiary, 8453));
        assertEq(a, _proofText("AIRDROP_WALLET", airdrop, 8453));

        vm.chainId(84_532);
        (b, a) = harness.printProofMessages();
        assertEq(b, _proofText("BENEFICIARY", beneficiary, 84_532));
        assertEq(a, _proofText("AIRDROP_WALLET", airdrop, 84_532));
        vm.chainId(31_337);
        (b,) = harness.printProofMessages();
        assertEq(b, _proofText("BENEFICIARY", beneficiary, 31_337));
    }

    /// @dev 이미 설정된 서명은 상태만 출력하고 revert하지 않음 (유효·형식 오류·다른 서명자). 주소 종류별 출력.
    function test_PrintProofMessages_ReportsStatusWithoutReverting() public {
        vm.setEvmVersion("prague");
        DeployEnvHarness harness = _envHarness();
        vm.chainId(8453);
        harness.setFakeEnv("BENEFICIARY_PROOF_SIG", vm.toString(_signProof(beneficiaryKey, "BENEFICIARY", beneficiary)));
        harness.setFakeEnv("AIRDROP_WALLET_PROOF_SIG", "0x1234");
        harness.printProofMessages();
        harness.setFakeEnv(
            "AIRDROP_WALLET_PROOF_SIG", vm.toString(_signProof(beneficiaryKey, "AIRDROP_WALLET", airdrop))
        );
        harness.printProofMessages();

        address delegated = makeAddr("print-7702");
        vm.etch(delegated, abi.encodePacked(hex"ef0100", address(new DeployConstantSafe(2, 3))));
        harness.setFakeEnv("BENEFICIARY", vm.toString(delegated));
        harness.setFakeEnv("AIRDROP_WALLET", vm.toString(_safe(2)));
        (string memory b,) = harness.printProofMessages();
        assertEq(b, _proofText("BENEFICIARY", delegated, 8453));
        harness.setFakeEnv("AIRDROP_WALLET", vm.toString(address(new DeployNotASafe())));
        harness.printProofMessages();
    }

    function test_PrintProofMessages_InputErrors() public {
        DeployEnvHarness harness = _envHarness();
        vm.chainId(8453);
        harness.setFakeEnv("AIRDROP_WALLET", vm.toLowercase(vm.toString(airdrop)));
        vm.expectRevert(abi.encodeWithSelector(LaunchGuards.LaunchChecksumRequired.selector, "AIRDROP_WALLET"));
        harness.printProofMessages();
        harness.setFakeEnv("BENEFICIARY", "");
        vm.expectRevert(abi.encodeWithSelector(LaunchBase.LaunchMissingEnv.selector, "BENEFICIARY"));
        harness.printProofMessages();
        vm.chainId(1);
        vm.expectRevert(abi.encodeWithSelector(LaunchBase.LaunchUnsupportedChain.selector, 1));
        harness.printProofMessages();
    }
}

// ───────────────────────── PostDeployCheck (로컬) ─────────────────────────

contract DeployPostCheckTest is DeployFixture {
    PostDeployCheck internal checker;
    Deploy.DeployResult internal r;

    function setUp() public override {
        super.setUp();
        treasury = _safe(2);
        r = script.deploy(_cfg(), deployer);
        checker = new PostDeployCheck();
    }

    function _check() internal view returns (PostDeployCheck.Report memory) {
        return checker.check(_inputs(r), true);
    }

    function test_Check_AllPassRightAfterDeploy() public view {
        PostDeployCheck.Report memory rep = _check();
        assertEq(rep.failed, 0);
        assertEq(rep.warned, 0);
        assertGt(rep.passed, 15);
    }

    function test_Check_FromRecordFile() public {
        string memory path = _tmpPath("check-record");
        vm.writeJson(script.recordJson(r), path);
        DeployCheckEnvHarness harness = new DeployCheckEnvHarness();
        PostDeployCheck.CheckInputs memory inputs = harness.loadInputs(path);
        assertEq(inputs.token, r.token);
        assertEq(inputs.vesting, r.vesting);
        assertEq(inputs.deployer, deployer);
        assertEq(inputs.beneficiary, beneficiary);
        assertEq(inputs.treasurySafe, treasury);
        assertEq(inputs.airdropWallet, airdrop);
        assertEq(inputs.recordedVestingStart, r.vestingStart);
        assertFalse(inputs.hasPool);
        PostDeployCheck.Report memory rep = harness.runWith(path);
        assertEq(rep.failed, 0);

        // 환경 변수가 기록보다 우선: 다른 수익자를 지정하면 owner 점검이 FAIL → runWith는 revert
        harness.setFakeEnv("BENEFICIARY", vm.toString(makeAddr("someone-else")));
        assertEq(harness.check(harness.loadInputs(path), false).failed, 1);
        vm.expectRevert(abi.encodeWithSelector(PostDeployCheck.PostDeployCheckFailed.selector, 1));
        harness.runWith(path);
        _removeFile(path);
    }

    function test_LoadInputs_RevertWhen_NothingToCheck() public {
        DeployCheckEnvHarness harness = new DeployCheckEnvHarness();
        vm.expectRevert(
            abi.encodeWithSelector(
                PostDeployCheck.PostDeployCheckMissingInput.selector, "FIRE_TOKEN / contracts.FireToken"
            )
        );
        harness.loadInputs(_tmpPath("does-not-exist"));
    }

    function test_LoadInputs_PoolSectionAndLpEnv() public {
        string memory path = _tmpPath("check-pool-section");
        vm.writeJson(script.recordJson(r), path);
        address npm = makeAddr("npm");
        vm.writeJson(
            string.concat(
                '{"address":"',
                vm.toString(makeAddr("pool")),
                '","positionManager":"',
                vm.toString(npm),
                '","tokenId":42,"liquidity":"123456789012345678901234","fee":10000,"initialSqrtPriceX96":"5186700741341130416096832"}'
            ),
            path,
            ".pool"
        );
        DeployCheckEnvHarness harness = new DeployCheckEnvHarness();
        PostDeployCheck.CheckInputs memory inputs = harness.loadInputs(path);
        assertTrue(inputs.hasPool);
        assertEq(inputs.poolStatus, harness.STATUS_NONE());
        assertEq(inputs.pool, makeAddr("pool"));
        assertEq(inputs.positionManager, npm);
        assertEq(inputs.tokenId, 42); // 온체인에서 다시 확인하므로 읽음
        assertEq(inputs.recordedLiquidity, 0); // confirm되지 않은 유동성은 비교 기준으로 쓰지 않음
        assertEq(inputs.fee, 10_000);
        assertEq(inputs.initialSqrtPriceX96, 5_186_700_741_341_130_416_096_832);
        assertEq(inputs.lpLocker, address(0));

        vm.writeJson('"confirmed"', path, ".pool.status");
        inputs = harness.loadInputs(path);
        assertEq(inputs.poolStatus, harness.STATUS_CONFIRMED());
        assertEq(inputs.recordedLiquidity, 123_456_789_012_345_678_901_234);

        // 운영자가 락업 후 수동으로 추가하는 .lpLock.locker 도 읽음 (환경 변수 LP_LOCKER가 우선)
        vm.writeJson(string.concat('{"locker":"', vm.toString(makeAddr("record-locker")), '"}'), path, ".lpLock");
        assertEq(harness.loadInputs(path).lpLocker, makeAddr("record-locker"));

        harness.setFakeEnv("LP_LOCKER", vm.toString(makeAddr("locker")));
        harness.setFakeEnv("LP_TOKEN_ID", "77");
        inputs = harness.loadInputs(path);
        assertEq(inputs.lpLocker, makeAddr("locker"));
        assertEq(inputs.tokenId, 77);
        _removeFile(path);
    }

    function test_Check_AfterCliffAndRelease() public {
        vm.warp(r.vestingStart + 100 days);
        FireVesting(payable(r.vesting)).release(r.token);
        assertGt(FireToken(r.token).balanceOf(beneficiary), 0);
        assertEq(_check().failed, 0);
    }

    function test_Check_BurnsAreNotFailures() public {
        vm.prank(airdrop);
        FireToken(r.token).burn(1 * M);
        PostDeployCheck.Report memory rep = _check();
        assertEq(rep.failed, 0);
        assertEq(rep.warned, 1); // 에어드롭 지갑 잔액이 런칭 배분과 달라짐
    }

    function test_Check_WarnsWhenLaunchBalancesMove() public {
        vm.prank(treasury);
        assertTrue(FireToken(r.token).transfer(makeAddr("cex"), 1 * M));
        vm.prank(airdrop);
        assertTrue(FireToken(r.token).transfer(makeAddr("merkle-distributor"), 20 * M));
        vm.prank(deployer);
        assertTrue(FireToken(r.token).transfer(makeAddr("elsewhere"), 1));
        PostDeployCheck.Report memory rep = _check();
        assertEq(rep.failed, 0);
        assertEq(rep.warned, 3);
    }

    function test_Check_WarnsWhenExtraTokensSentToVesting() public {
        vm.prank(deployer);
        assertTrue(FireToken(r.token).transfer(r.vesting, 1e18));
        PostDeployCheck.Report memory rep = _check();
        assertEq(rep.failed, 0);
        assertEq(rep.warned, 2); // vesting 초과 입금 + 배포자 잔액 변화
    }

    function test_Check_FailsWhenBeneficiaryRotated() public {
        address next = makeAddr("next-beneficiary");
        FireVesting vesting = FireVesting(payable(r.vesting));
        vm.prank(beneficiary);
        vesting.transferOwnership(next);
        PostDeployCheck.Report memory rep = _check();
        assertEq(rep.failed, 0);
        assertEq(rep.warned, 1); // pending owner

        vm.prank(next);
        vesting.acceptOwnership();
        assertEq(_check().failed, 1); // 기록과 다른 owner
    }

    /// @dev 런칭 포지션을 못 찾았을 때의 안내: 배포 지갑의 NFT가 탐색 한도(100)보다 많으면(런칭 전에 받은 NFT가 앞자리를
    ///      차지) 그 사실과 LP_TOKEN_ID 지정을 안내함. 실제 흐름은 포크 테스트 test_Fork_PreLaunchNftFloodNeedsLpTokenId.
    function test_Check_LpTokenIdHintMentionsScanLimit() public view {
        string memory locked = "if the LP NFT is already locked, set LP_TOKEN_ID=<id>";
        assertEq(checker.lpTokenIdHint(0), locked);
        assertEq(checker.lpTokenIdHint(LaunchParams.MAX_POSITION_SCAN), locked);
        string memory text = checker.lpTokenIdHint(LaunchParams.MAX_POSITION_SCAN + 1);
        assertTrue(vm.contains(text, "checked only the oldest 100 of the deployer's 101 LP NFTs"));
        assertTrue(vm.contains(text, "set LP_TOKEN_ID=<launch NFT id>"));
    }

    /// @dev 리허설 B1 회귀: owner 불일치 문구는 실제 owner와 기대값(기록·BENEFICIARY)을 모두 보여 줌.
    function test_Check_OwnerMismatchTextShowsBothAddresses() public {
        address next = makeAddr("next-beneficiary");
        (bool ok, string memory text) = checker.ownerCheckText(next, beneficiary);
        assertFalse(ok);
        assertTrue(vm.contains(text, vm.toString(next)));
        assertTrue(vm.contains(text, vm.toString(beneficiary)));
        assertTrue(vm.contains(text, "BENEFICIARY=<new owner>"));
        (ok, text) = checker.ownerCheckText(beneficiary, beneficiary);
        assertTrue(ok);
        assertEq(text, string.concat("owner() == beneficiary ", vm.toString(beneficiary)));

        // 정상 교체 후에는 BENEFICIARY=<새 지갑>으로 PASS
        FireVesting vesting = FireVesting(payable(r.vesting));
        vm.prank(beneficiary);
        vesting.transferOwnership(next);
        vm.prank(next);
        vesting.acceptOwnership();
        PostDeployCheck.CheckInputs memory inputs = _inputs(r);
        assertEq(checker.check(inputs, false).failed, 1);
        inputs.beneficiary = next;
        assertEq(checker.check(inputs, false).failed, 0);
    }

    /// @dev 리뷰 PoC(F4) 회귀: 기록에서 읽은 FireToken·FireVesting의 런타임 코드를 이 저장소의 컴파일 결과와 대조하고,
    ///      두 주소가 배포 지갑의 CREATE(deployerNonce, +1)인지 확인함.
    function test_Check_CodeIdentityAndCreateAddressesFromRecord() public {
        string memory path = _tmpPath("check-code-identity");
        vm.writeJson(script.recordJson(r), path);
        DeployCheckEnvHarness harness = new DeployCheckEnvHarness();
        PostDeployCheck.CheckInputs memory inputs = harness.loadInputs(path);
        _removeFile(path);
        assertEq(inputs.tokenCode, LaunchCode.MATCH);
        assertEq(inputs.vestingCode, LaunchCode.MATCH);
        assertTrue(inputs.hasDeployerNonce);
        assertEq(inputs.deployerNonce, r.deployerNonce);
        PostDeployCheck.Report memory rep = harness.check(inputs, true);
        assertEq(rep.failed, 0);
        assertEq(rep.warned, 1); // pending 기록

        inputs.deployerNonce += 1; // 기록의 nonce가 맞지 않으면 FAIL
        assertEq(harness.check(inputs, false).failed, 1);
        inputs.deployerNonce -= 1;
        inputs.vesting = makeAddr("not-the-vesting"); // 코드 없음 + CREATE 유도 불일치
        assertEq(harness.check(inputs, false).failed, 2);
    }

    /**
     * @dev 리뷰 PoC(F4) 회귀: 악의적 배포자가 FireToken 생성자에 "백도어 베스팅"을 넣고 기록을 그대로 공개해도
     *      베스팅 코드 대조가 FAIL (예전에는 인출 전후 모두 PASS). 진짜 FireToken에 숨은 함수를 붙인 변형도 FAIL.
     */
    function test_Check_BackdooredVestingAndMutantTokenFail() public {
        address evil = makeAddr("evil-deployer");
        vm.startPrank(evil);
        DeployBackdooredVesting vesting = new DeployBackdooredVesting(beneficiary, evil);
        FireToken token = new FireToken(address(vesting));
        assertTrue(token.transfer(treasury, 50_000_000e18));
        assertTrue(token.transfer(airdrop, 50_000_000e18));
        vm.stopPrank();
        Deploy.DeployResult memory fake = r;
        (fake.deployer, fake.deployerNonce, fake.vesting, fake.token) = (evil, 0, address(vesting), address(token));
        fake.vestingStart = vesting.start();

        string memory path = _tmpPath("check-backdoor");
        vm.writeJson(script.recordJson(fake), path);
        DeployCheckEnvHarness harness = new DeployCheckEnvHarness();
        PostDeployCheck.CheckInputs memory inputs = harness.loadInputs(path);
        assertEq(inputs.tokenCode, LaunchCode.MATCH); // 토큰은 진짜 FireToken
        assertEq(inputs.vestingCode, LaunchCode.MISMATCH);
        assertEq(harness.check(inputs, false).failed, 1);
        vm.prank(evil);
        vesting.drain(address(token));
        assertEq(harness.check(harness.loadInputs(path), false).failed, 1); // 인출 후에도 (잔액+해제량은 꾸며져 PASS)

        vm.startPrank(evil);
        FireVesting realVesting = new FireVesting(beneficiary, 180 days, 540 days);
        DeployMutantFireToken mutant = new DeployMutantFireToken(address(realVesting));
        vm.stopPrank();
        (fake.deployerNonce, fake.vesting, fake.token) = (1, address(realVesting), address(mutant));
        fake.vestingStart = realVesting.start();
        vm.writeJson(script.recordJson(fake), path);
        inputs = harness.loadInputs(path);
        _removeFile(path);
        assertEq(inputs.vestingCode, LaunchCode.MATCH);
        assertEq(inputs.tokenCode, LaunchCode.MISMATCH);
        assertGe(harness.check(inputs, false).failed, 1);
    }

    /// @dev 리뷰 PoC(F6) 회귀: 트레저리 Safe에 모듈이 있거나 모듈을 읽을 수 없으면 WARN (배포 후 설정 변화 감시).
    function test_Check_TreasurySafeModulesWarn() public {
        PostDeployCheck.Report memory before = _check();
        DeployMockSafe(treasury).setModule(makeAddr("module"));
        PostDeployCheck.Report memory withModule = _check();
        assertEq(withModule.failed, 0);
        assertEq(withModule.warned, before.warned + 1);
        PostDeployCheck.CheckInputs memory inputs = _inputs(r);
        inputs.treasurySafe = address(new DeployLegacySafe()); // 모듈 조회 불가 + 잔액 0
        assertEq(checker.check(inputs, false).warned, before.warned + 2);
    }

    /**
     * @dev 리뷰 PoC(F4) 회귀: 기록의 pool.positionManager가 주소표의 NPM이 아니면 FAIL(점검은 주소표 NPM으로), 풀이
     *      있는데 배포 지갑이 아직 7억 이상을 가지면 FAIL. 예전에는 가짜 NPM의 응답으로 LP 점검이 모두 PASS였음.
     */
    function test_Check_FakePositionManagerAndUnfundedLpFail() public {
        vm.chainId(8453);
        PostDeployCheck.CheckInputs memory inputs = _inputs(r);
        inputs.hasPool = true;
        inputs.positionManager = address(new DeployNotASafe()); // 기록에 적힌 가짜 NPM
        inputs.tokenId = 1;
        inputs.fee = 10_000;
        PostDeployCheck.Report memory rep = checker.check(inputs, true);
        // FAIL: NPM 주소표 불일치, 주소표 NPM 코드 없음(로컬) → 풀 점검 생략, 배포 지갑 7억 보유
        assertEq(rep.failed, 3);
        vm.prank(deployer);
        assertTrue(FireToken(r.token).transfer(makeAddr("pool-stand-in"), 700_000_000e18));
        assertEq(checker.check(inputs, false).failed, 2);
    }

    function test_Check_RecordedStartTolerance() public view {
        PostDeployCheck.CheckInputs memory inputs = _inputs(r);
        inputs.recordedVestingStart = r.vestingStart - 60; // 시뮬레이션 블록보다 60초 늦게 포함된 경우
        assertEq(checker.check(inputs, false).failed, 0);
        inputs.recordedVestingStart = r.vestingStart - 1 days;
        assertEq(checker.check(inputs, false).failed, 0);
        inputs.recordedVestingStart = r.vestingStart - 1 days - 1;
        assertEq(checker.check(inputs, false).failed, 1);
        inputs.recordedVestingStart = r.vestingStart + 1; // 기록보다 이른 온체인 시작은 불가능
        assertEq(checker.check(inputs, false).failed, 1);
        inputs.recordedVestingStart = 0; // 기록 없음
        assertEq(checker.check(inputs, false).failed, 0);
    }

    function test_Check_WrongAddressesFailInsteadOfReverting() public {
        PostDeployCheck.CheckInputs memory inputs = _inputs(r);
        inputs.token = makeAddr("no-code");
        inputs.vesting = r.token; // 코드는 있지만 FireVesting이 아님
        PostDeployCheck.Report memory rep = checker.check(inputs, true);
        assertEq(rep.failed, 2);
    }

    /// @dev pending 기록은 WARN(공개 전 confirm 필요), confirm 후에는 경고 없이 통과.
    function test_Check_PendingRecordWarnsUntilConfirmed() public {
        string memory path = _tmpPath("check-status");
        vm.writeJson(script.recordJson(r), path);
        DeployCheckEnvHarness harness = new DeployCheckEnvHarness();
        PostDeployCheck.CheckInputs memory inputs = harness.loadInputs(path);
        assertEq(inputs.deployStatus, harness.STATUS_PENDING());
        PostDeployCheck.Report memory rep = harness.check(inputs, true);
        assertEq(rep.failed, 0);
        assertEq(rep.warned, 1);

        script.confirmRecord(path);
        inputs = harness.loadInputs(path);
        _removeFile(path);
        assertEq(inputs.deployStatus, harness.STATUS_CONFIRMED());
        rep = harness.check(inputs, true);
        assertEq(rep.failed, 0);
        assertEq(rep.warned, 0);
    }

    /// @dev confirmed 기록은 온체인 start와 정확히 같아야 함(시뮬레이션 지연 허용 없음).
    function test_Check_ConfirmedRecordRequiresExactStart() public view {
        PostDeployCheck.CheckInputs memory inputs = _inputs(r);
        inputs.deployStatus = checker.STATUS_CONFIRMED();
        assertEq(checker.check(inputs, false).failed, 0);
        inputs.recordedVestingStart = r.vestingStart - 60;
        assertEq(checker.check(inputs, false).failed, 1);
        inputs.deployStatus = checker.STATUS_PENDING();
        assertEq(checker.check(inputs, false).failed, 0);
    }

    /// @dev EIP-7702 위임 EOA 트레저리: 메인넷 FAIL(단일 키), 테스트넷 WARN. 2-of-3 미만 Safe는 WARN 1건 추가.
    function test_Check_TreasuryDelegatedEOAOrWeakSafe() public {
        vm.setEvmVersion("prague");
        PostDeployCheck.CheckInputs memory inputs = _inputs(r);
        address delegated = makeAddr("check-treasury-7702");
        vm.etch(delegated, abi.encodePacked(hex"ef0100", address(new DeployConstantSafe(2, 3))));
        inputs.treasurySafe = delegated;
        assertEq(checker.check(inputs, false).failed, 0); // 로컬: 경고
        vm.chainId(8453);
        assertEq(checker.check(inputs, false).failed, 1); // 메인넷: 실패

        inputs.treasurySafe = _safeWith(2, 3); // 잔액 0 → 잔액 WARN 1건
        PostDeployCheck.Report memory strong = checker.check(inputs, false);
        inputs.treasurySafe = _safeWith(2, 2);
        PostDeployCheck.Report memory weak = checker.check(inputs, false);
        assertEq(strong.failed, 0);
        assertEq(weak.failed, 0);
        assertEq(weak.warned, strong.warned + 1);
    }

    function test_Check_TreasuryMustBeSafeOnMainnet() public {
        PostDeployCheck.CheckInputs memory inputs = _inputs(r);
        inputs.treasurySafe = airdrop; // EOA
        inputs.airdropWallet = treasury;
        PostDeployCheck.Report memory rep = checker.check(inputs, false);
        assertEq(rep.failed, 0); // 로컬: 경고
        vm.chainId(8453);
        rep = checker.check(inputs, false);
        assertEq(rep.failed, 1); // 메인넷: 실패
    }
}

// ───────────────────────── 불변식: 정상 운영 활동은 FAIL을 만들지 않음 ─────────────────────────

contract DeployCheckHandler is Test {
    FireToken internal immutable token;
    FireVesting internal immutable vesting;
    address[] internal senders;
    address[] internal recipients;
    uint256 public burned;

    constructor(FireToken token_, FireVesting vesting_, address[] memory senders_) {
        token = token_;
        vesting = vesting_;
        senders = senders_;
        recipients = senders_;
        recipients.push(address(vesting_)); // 베스팅으로의 추가 입금도 "경고"일 뿐 실패가 아님
    }

    function warp(uint256 seconds_) external {
        vm.warp(block.timestamp + bound(seconds_, 1, 120 days));
    }

    function release() external {
        vesting.release(address(token));
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address from = senders[fromSeed % senders.length];
        address to = recipients[toSeed % recipients.length];
        amount = bound(amount, 0, token.balanceOf(from));
        vm.prank(from);
        require(token.transfer(to, amount), "transfer failed");
    }

    function burn(uint256 fromSeed, uint256 amount) external {
        address from = senders[fromSeed % senders.length];
        amount = bound(amount, 0, token.balanceOf(from));
        vm.prank(from);
        token.burn(amount);
        burned += amount;
    }
}

contract DeployCheckInvariantTest is DeployFixture {
    PostDeployCheck internal checker;
    DeployCheckHandler internal handler;
    PostDeployCheck.CheckInputs internal inputs;
    FireToken internal token;
    FireVesting internal vesting;

    function setUp() public override {
        super.setUp();
        treasury = _safe(2);
        Deploy.DeployResult memory r = script.deploy(_cfg(), deployer);
        checker = new PostDeployCheck();
        inputs = _inputs(r);
        token = FireToken(r.token);
        vesting = FireVesting(payable(r.vesting));

        address[] memory senders = new address[](6);
        senders[0] = deployer;
        senders[1] = treasury;
        senders[2] = airdrop;
        senders[3] = beneficiary;
        senders[4] = makeAddr("alice");
        senders[5] = makeAddr("bob");
        handler = new DeployCheckHandler(token, vesting, senders);
        targetContract(address(handler));
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 32
    /// forge-config: ci.invariant.runs = 256
    /// forge-config: ci.invariant.depth = 64
    function invariant_PostDeployCheckNeverFailsOnLegitActivity() public view {
        assertEq(checker.check(inputs, false).failed, 0);
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 32
    /// forge-config: ci.invariant.runs = 256
    /// forge-config: ci.invariant.depth = 64
    function invariant_SupplyAndVestingAccounting() public view {
        assertEq(token.totalSupply() + handler.burned(), LaunchParams.TOTAL_SUPPLY);
        assertGe(token.balanceOf(address(vesting)) + vesting.released(address(token)), LaunchParams.VESTING_AMOUNT);
        assertEq(vesting.owner(), beneficiary);
    }
}
