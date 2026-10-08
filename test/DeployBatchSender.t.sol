// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {FireToken} from "../src/FireToken.sol";
import {FireVesting} from "../src/FireVesting.sol";
import {FireBatchSender} from "../src/FireBatchSender.sol";
import {DeployBatchSender} from "../script/DeployBatchSender.s.sol";
import {CreatePool} from "../script/CreatePool.s.sol";
import {LaunchGuards} from "../script/lib/LaunchGuards.sol";

/// @dev 환경 변수·배포 기록을 메모리 값으로 대체한 배포 스크립트 하네스.
///      vm.setEnv는 병렬로 실행되는 다른 테스트와 프로세스 환경(FIRE_TOKEN, CONFIRM_MAINNET 등)을 공유해 경쟁 상태가
///      생기므로 사용하지 않음. 재정의하는 것은 원시 문자열 공급원(_envString)과 기록 파일 읽기뿐이며,
///      빈 값 = 미설정, 기본값 적용, vm.parse* 파싱은 실제 실행과 같은 스크립트 코드가 수행함.
contract BatchDeployHarness is DeployBatchSender {
    mapping(bytes32 => string) private _values;
    string private _record;
    string private _recordFile;
    bool private _rpcCheck;
    bool private _rpcOk;
    uint256 private _rpcId;
    bool private _broadcastContext;

    /// @dev RPC 대조를 강제하고 eth_chainId 응답(ok=false면 RPC 없음)을 흉내 냄.
    function setRpcChainId(bool ok, uint256 chainId) external {
        _rpcCheck = true;
        _rpcOk = ok;
        _rpcId = chainId;
    }

    function setBroadcastContext(bool on) external {
        _broadcastContext = on;
    }

    function _enforceRpcChainCheck() internal view override returns (bool) {
        return _rpcCheck;
    }

    function _rpcChainId() internal view override returns (bool, uint256) {
        return (_rpcOk, _rpcId);
    }

    function _isBroadcastRun() internal view override returns (bool) {
        return _broadcastContext;
    }

    function setVar(string memory name, string memory value) external {
        _values[keccak256(bytes(name))] = value;
    }

    function clearVar(string memory name) external {
        delete _values[keccak256(bytes(name))];
    }

    function setRecord(string memory json) external {
        _record = json;
    }

    /// @dev 지정하면 메모리 기록 대신 실제 파일 읽기 경로(vm.exists + vm.readFile)를 그 파일로 실행.
    function useRecordFile(string memory path) external {
        _recordFile = path;
    }

    function _envString(string memory name) internal view override returns (string memory) {
        return _values[keccak256(bytes(name))];
    }

    function _deploymentRecordPath() internal view override returns (string memory) {
        return bytes(_recordFile).length != 0 ? _recordFile : super._deploymentRecordPath();
    }

    function _readDeploymentRecord() internal view override returns (string memory) {
        return bytes(_recordFile).length != 0 ? super._readDeploymentRecord() : _record;
    }
}

/// @dev 재정의 없이 실제 환경 변수 읽기 함수를 노출. 다른 테스트와 겹치지 않는 고유 변수명으로만 사용.
contract BatchDeployEnvProbe is DeployBatchSender {
    function envString(string memory name) external view returns (string memory) {
        return _envString(name);
    }

    function envUintOr(string memory name, uint256 defaultValue) external view returns (uint256) {
        return _envUintOr(name, defaultValue);
    }

    function envAddressOr(string memory name, address defaultValue) external view returns (address) {
        return _envAddressOr(name, defaultValue);
    }

    function recordPath() external view returns (string memory) {
        return _deploymentRecordPath();
    }
}

/// @dev Safe 대역: getThreshold()/getOwners()/getModulesPaginated() 응답 (서명자 수·임계값 지정, 모듈은 setModule로).
contract BatchDeploySafeStub {
    uint256 private immutable _THRESHOLD;
    uint256 private immutable _OWNER_COUNT;
    address public module;

    constructor(uint256 threshold, uint256 ownerCount) {
        _THRESHOLD = threshold;
        _OWNER_COUNT = ownerCount;
    }

    function setModule(address module_) external {
        module = module_;
    }

    /// @dev Safe ModuleManager와 같은 반환 형식. 모듈이 없으면 빈 배열 + SENTINEL(0x1).
    function getModulesPaginated(address, uint256) external view returns (address[] memory page, address next) {
        next = address(0x1);
        if (module == address(0)) return (new address[](0), next);
        page = new address[](1);
        page[0] = module;
    }

    function getThreshold() external view returns (uint256) {
        return _THRESHOLD;
    }

    function getOwners() external view returns (address[] memory owners) {
        owners = new address[](_OWNER_COUNT);
        for (uint256 i = 0; i < _OWNER_COUNT; ++i) {
            owners[i] = address(uint160(0x5AFE0000 + i + 1));
        }
    }
}

/// @dev FIRE가 아닌 토큰 (FIRE_TOKEN 오입력 방지 검증용, name "Other Token").
contract BatchDeployOtherToken is ERC20 {
    uint8 private immutable _DECIMALS;

    constructor(string memory symbol_, uint8 decimals_) ERC20("Other Token", symbol_) {
        _DECIMALS = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _DECIMALS;
    }
}

/// @dev name·symbol·decimals는 FIRE와 같지만 FireToken의 고정 상수가 없는 사칭 토큰.
contract BatchDeployMetadataOnlyToken is ERC20 {
    constructor() ERC20("Fire", "FIRE") {
        _mint(msg.sender, 1_000_000_000e18);
    }
}

/// @dev FireToken의 메타데이터·고정 상수를 흉내 내는 사칭 토큰. 모든 값을 지정할 수 있고,
///      vesting이 type(uint256).max면 VESTING_SUPPLY()가 revert(함수가 없는 것과 같은 경우).
contract BatchDeployLookalikeToken is ERC20 {
    struct Spec {
        string name;
        string symbol;
        uint8 decimals;
        uint256 maxSupply;
        uint256 vesting;
        uint256 minted;
    }

    uint8 private immutable _DECIMALS;
    uint256 private immutable _MAX_SUPPLY;
    uint256 private immutable _VESTING;

    error BatchDeployLookalikeTokenNoVestingSupply();

    constructor(Spec memory spec) ERC20(spec.name, spec.symbol) {
        _DECIMALS = spec.decimals;
        _MAX_SUPPLY = spec.maxSupply;
        _VESTING = spec.vesting;
        _mint(msg.sender, spec.minted);
    }

    function decimals() public view override returns (uint8) {
        return _DECIMALS;
    }

    // forge-lint: disable-next-line(mixed-case-function)
    function TOTAL_SUPPLY() external view returns (uint256) {
        return _MAX_SUPPLY;
    }

    // forge-lint: disable-next-line(mixed-case-function)
    function VESTING_SUPPLY() external view returns (uint256) {
        if (_VESTING == type(uint256).max) revert BatchDeployLookalikeTokenNoVestingSupply();
        return _VESTING;
    }
}

/// @dev name은 "Fire"지만 symbol() 또는 decimals()가 revert하는 토큰 (try/catch 실패 분기 검증용).
contract BatchDeployBrokenMetadataToken is ERC20 {
    bool private immutable _BREAK_SYMBOL;

    error BatchDeployBrokenMetadataTokenBroken();

    constructor(bool breakSymbol) ERC20("Fire", "FIRE") {
        _BREAK_SYMBOL = breakSymbol;
    }

    function symbol() public view override returns (string memory) {
        if (_BREAK_SYMBOL) revert BatchDeployBrokenMetadataTokenBroken();
        return super.symbol();
    }

    function decimals() public view override returns (uint8) {
        if (!_BREAK_SYMBOL) revert BatchDeployBrokenMetadataTokenBroken();
        return 18;
    }
}

/// @dev 2-of-3 Safe처럼 응답하지만 getModulesPaginated가 없는 컨트랙트 (모듈 상태를 확인할 수 없음).
contract BatchDeployLegacySafeStub {
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

/// @dev getThreshold()만 있고 getOwners()가 없는 컨트랙트 (Safe 판별 실패 분기 검증용).
contract BatchDeployThresholdOnlyStub {
    function getThreshold() external pure returns (uint256) {
        return 2;
    }
}

contract DeployBatchSenderTest is Test {
    uint256 internal constant BASE_MAINNET = 8453;
    uint256 internal constant BASE_SEPOLIA = 84532;
    uint256 internal constant LOCAL_CHAIN = 31337;

    BatchDeployHarness internal deployScript;
    FireToken internal fire;
    FireVesting internal vesting;
    address internal safe;
    /// @dev 이 테스트 컨트랙트가 vesting을 만든 CREATE nonce (기록의 deployerNonce, fire = CREATE(this, nonce + 1)).
    uint256 internal launchNonce;

    function setUp() public {
        vesting = new FireVesting(makeAddr("beneficiary"), 15_552_000, 46_656_000);
        fire = new FireToken(address(vesting));
        while (vm.computeCreateAddress(address(this), launchNonce) != address(vesting)) ++launchNonce;
        safe = address(new BatchDeploySafeStub(2, 3));
        deployScript = new BatchDeployHarness();
        deployScript.setVar("FIRE_TOKEN", vm.toString(address(fire)));
        deployScript.setVar("BATCH_SENDER_OWNER", vm.toString(safe));
    }

    function _assertDeployed(FireBatchSender sender, address owner, uint256 limit, uint256 fee) internal view {
        assertTrue(address(sender).code.length > 0);
        assertEq(sender.fireToken(), address(fire));
        assertEq(sender.owner(), owner);
        assertEq(sender.pendingOwner(), address(0));
        assertEq(sender.freeRecipientLimit(), limit);
        assertEq(sender.burnFee(), fee);
    }

    /// @dev deployments/<chainId>.json 형식의 Deploy 기록 (0 주소인 항목은 생략). deployer = 이 테스트 컨트랙트,
    ///      deployerNonce = vesting의 CREATE nonce → fire = CREATE(deployer, deployerNonce + 1).
    function _record(address token, address treasury) internal view returns (string memory json) {
        string memory contracts = token == address(0) ? "{}" : string.concat('{"FireToken":"', vm.toString(token), '"}');
        string memory wallets =
            treasury == address(0) ? "{}" : string.concat('{"treasurySafe":"', vm.toString(treasury), '"}');
        json = string.concat(
            '{"chainId":8453,"deployer":"',
            vm.toString(address(this)),
            '","deployerNonce":',
            vm.toString(launchNonce),
            ',"contracts":',
            contracts,
            ',"wallets":',
            wallets,
            "}"
        );
    }

    function _useMainnet() internal {
        vm.chainId(BASE_MAINNET);
        deployScript.setVar("CONFIRM_MAINNET", "I_UNDERSTAND");
        deployScript.setRecord(_record(address(fire), safe));
    }

    function _expectMismatch(string memory name, address given, address recorded) internal {
        vm.expectRevert(
            abi.encodeWithSelector(DeployBatchSender.DeployBatchSenderRecordMismatch.selector, name, given, recorded)
        );
    }

    function _expectInvalidToken(address token) internal {
        vm.expectRevert(abi.encodeWithSelector(DeployBatchSender.DeployBatchSenderInvalidFireToken.selector, token));
    }

    // ───────── 정상 배포 ─────────

    function test_Run_LocalChainUsesDefaults() public {
        assertEq(block.chainid, LOCAL_CHAIN);
        FireBatchSender sender = deployScript.run();
        _assertDeployed(sender, safe, 25, 10_000e18);
    }

    function test_Run_CustomParameters() public {
        deployScript.setVar("BATCH_FREE_RECIPIENTS", "50");
        deployScript.setVar("BATCH_BURN_FEE_FIRE", "2500");
        FireBatchSender sender = deployScript.run();
        _assertDeployed(sender, safe, 50, 2_500e18);
    }

    function test_Run_ZeroFeeAndZeroFreeLimit() public {
        deployScript.setVar("BATCH_FREE_RECIPIENTS", "0");
        deployScript.setVar("BATCH_BURN_FEE_FIRE", "0");
        FireBatchSender sender = deployScript.run();
        _assertDeployed(sender, safe, 0, 0);
    }

    function test_Run_AcceptsContractUpperBounds() public {
        deployScript.setVar("BATCH_FREE_RECIPIENTS", "300");
        deployScript.setVar("BATCH_BURN_FEE_FIRE", "1000000");
        FireBatchSender sender = deployScript.run();
        _assertDeployed(sender, safe, 300, 1_000_000e18);
    }

    function test_Run_BaseSepoliaAllowsEOAOwnerForRehearsal() public {
        address eoaOwner = makeAddr("rehearsal-owner");
        vm.chainId(BASE_SEPOLIA);
        deployScript.setVar("BATCH_SENDER_OWNER", vm.toString(eoaOwner));
        FireBatchSender sender = deployScript.run();
        _assertDeployed(sender, eoaOwner, 25, 10_000e18);
    }

    function test_Run_TestnetAllowsOwnerOtherThanRecordedTreasury() public {
        address eoaOwner = makeAddr("rehearsal-owner");
        vm.chainId(BASE_SEPOLIA);
        deployScript.setRecord(_record(address(fire), safe));
        deployScript.setVar("BATCH_SENDER_OWNER", vm.toString(eoaOwner));
        FireBatchSender sender = deployScript.run(); // 경고만 출력
        _assertDeployed(sender, eoaOwner, 25, 10_000e18);
    }

    function test_Run_MainnetWithConfirmationRecordAndSafeOwner() public {
        _useMainnet();
        FireBatchSender sender = deployScript.run();
        _assertDeployed(sender, safe, 25, 10_000e18);
    }

    function test_Run_MainnetReadsTokenAndOwnerFromRecordWhenEnvIsEmpty() public {
        _useMainnet();
        deployScript.setVar("FIRE_TOKEN", ""); // .env.example의 `FIRE_TOKEN=` 줄을 그대로 둔 경우
        deployScript.clearVar("BATCH_SENDER_OWNER");
        FireBatchSender sender = deployScript.run();
        _assertDeployed(sender, safe, 25, 10_000e18);
    }

    function test_Run_DeployerAndCallerGetNoRights() public {
        FireBatchSender sender = deployScript.run();
        address[3] memory others = [DEFAULT_SENDER, address(this), address(deployScript)];
        for (uint256 i = 0; i < others.length; ++i) {
            vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, others[i]));
            vm.prank(others[i]);
            sender.setBurnFee(0);
        }
    }

    function test_Run_DeployedSenderWorksEndToEnd() public {
        FireBatchSender sender = deployScript.run();
        address user = makeAddr("user");
        assertTrue(fire.transfer(user, 1_000_000e18));
        vm.deal(user, 100 ether);

        uint256 n = 26; // 기본 무료 한도 25명 초과 → 유료
        address[] memory r = new address[](n);
        uint256[] memory a = new uint256[](n);
        for (uint256 i = 0; i < n; ++i) {
            r[i] = makeAddr(string.concat("deploy-e2e-", vm.toString(i)));
            a[i] = 1 ether;
        }
        uint256 fee = sender.quoteBurnFee(n);
        assertEq(fee, 10_000e18);
        vm.prank(user);
        assertTrue(fire.approve(address(sender), fee));
        uint256 supplyBefore = fire.totalSupply();

        vm.prank(user);
        sender.sendETH{value: 26 ether}(r, a, fee);

        assertEq(fire.totalSupply(), supplyBefore - fee);
        assertEq(fire.balanceOf(safe), 0, "treasury Safe never receives the fee");
        assertEq(r[n - 1].balance, 1 ether);
    }

    function test_LoadConfig_ConvertsWholeFireToWei() public {
        deployScript.setVar("BATCH_BURN_FEE_FIRE", "1234");
        deployScript.setVar("BATCH_FREE_RECIPIENTS", "40");
        DeployBatchSender.Config memory cfg = deployScript.loadConfig();
        assertEq(cfg.fireToken, address(fire));
        assertEq(cfg.owner, safe);
        assertEq(cfg.freeRecipientLimit, 40);
        assertEq(cfg.burnFee, 1_234e18);
    }

    function test_LoadConfig_EmptyValuesMeanUnset() public {
        // 실제 forge(vm.envOr)와 같이 빈 값은 미설정 → 기본값
        deployScript.setVar("BATCH_FREE_RECIPIENTS", "");
        deployScript.setVar("BATCH_BURN_FEE_FIRE", "");
        DeployBatchSender.Config memory cfg = deployScript.loadConfig();
        assertEq(cfg.freeRecipientLimit, 25);
        assertEq(cfg.burnFee, 10_000e18);

        // 빈 주소는 기록값으로 대체, 기록도 없으면 누락 오류
        deployScript.setVar("FIRE_TOKEN", "");
        vm.expectRevert(
            abi.encodeWithSelector(DeployBatchSender.DeployBatchSenderMissingAddress.selector, "FIRE_TOKEN")
        );
        deployScript.loadConfig();
        deployScript.setRecord(_record(address(fire), address(0)));
        assertEq(deployScript.loadConfig().fireToken, address(fire));

        // 빈 확인 문구는 미확인
        vm.chainId(BASE_MAINNET);
        deployScript.setVar("CONFIRM_MAINNET", "");
        vm.expectRevert(DeployBatchSender.DeployBatchSenderMainnetNotConfirmed.selector);
        deployScript.run();
    }

    function test_Deploy_AcceptsExplicitConfigWithFractionalFee() public {
        DeployBatchSender.Config memory cfg =
            DeployBatchSender.Config({fireToken: address(fire), owner: safe, freeRecipientLimit: 10, burnFee: 0.5e18});
        FireBatchSender sender = deployScript.deploy(cfg);
        _assertDeployed(sender, safe, 10, 0.5e18);
    }

    // ───────── 체인 가드 ─────────

    function testFuzz_Run_RevertsOnUnsupportedChain(uint64 chainId) public {
        vm.assume(chainId != 0 && chainId != BASE_MAINNET && chainId != BASE_SEPOLIA && chainId != LOCAL_CHAIN);
        vm.chainId(chainId);
        vm.expectRevert(abi.encodeWithSelector(DeployBatchSender.DeployBatchSenderUnsupportedChain.selector, chainId));
        deployScript.run();
    }

    function test_Run_ChecksChainBeforeReadingOtherVariables() public {
        deployScript.clearVar("FIRE_TOKEN");
        vm.chainId(1);
        vm.expectRevert(abi.encodeWithSelector(DeployBatchSender.DeployBatchSenderUnsupportedChain.selector, 1));
        deployScript.run();
    }

    function test_Deploy_ExplicitConfigStillChecksChainAndMainnetPolicy() public {
        DeployBatchSender.Config memory cfg = DeployBatchSender.Config({
            fireToken: address(fire), owner: safe, freeRecipientLimit: 25, burnFee: 10_000e18
        });
        vm.chainId(10);
        vm.expectRevert(abi.encodeWithSelector(DeployBatchSender.DeployBatchSenderUnsupportedChain.selector, 10));
        deployScript.deploy(cfg);

        vm.chainId(BASE_MAINNET);
        vm.expectRevert(DeployBatchSender.DeployBatchSenderMainnetNotConfirmed.selector);
        deployScript.deploy(cfg);

        // 명시적 설정이라도 메인넷 기록 고정·Safe 정책을 우회할 수 없음
        deployScript.setVar("CONFIRM_MAINNET", "I_UNDERSTAND");
        vm.expectRevert(
            abi.encodeWithSelector(
                DeployBatchSender.DeployBatchSenderFireTokenNotRecorded.selector, "deployments/8453.json"
            )
        );
        deployScript.deploy(cfg);
    }

    function test_Run_MainnetRequiresConfirmation() public {
        vm.chainId(BASE_MAINNET);
        vm.expectRevert(DeployBatchSender.DeployBatchSenderMainnetNotConfirmed.selector);
        deployScript.run();
    }

    function test_Run_MainnetRejectsWrongConfirmation() public {
        vm.chainId(BASE_MAINNET);
        string[4] memory wrong = ["", "i_understand", "YES", "I_UNDERSTAND "];
        for (uint256 i = 0; i < wrong.length; ++i) {
            deployScript.setVar("CONFIRM_MAINNET", wrong[i]);
            vm.expectRevert(DeployBatchSender.DeployBatchSenderMainnetNotConfirmed.selector);
            deployScript.run();
        }
    }

    // ───────── 메인넷 FIRE 토큰 고정 ─────────

    function test_Run_MainnetRequiresLaunchRecord() public {
        _useMainnet();
        deployScript.setRecord("");
        vm.expectRevert(
            abi.encodeWithSelector(
                DeployBatchSender.DeployBatchSenderFireTokenNotRecorded.selector, "deployments/8453.json"
            )
        );
        deployScript.run();
    }

    function test_Run_MainnetRejectsBytecodeCloneOfFireToken() public {
        // 바이트코드가 같은 복제 토큰은 이름·상수·공급량 검사를 모두 통과하므로 런칭 기록과의 비교로만 걸러짐
        FireToken clone = new FireToken(address(new FireVesting(makeAddr("clone-beneficiary"), 1, 1)));
        _useMainnet();
        deployScript.setVar("FIRE_TOKEN", vm.toString(address(clone)));
        _expectMismatch("FIRE_TOKEN", address(clone), address(fire));
        deployScript.run();
    }

    function test_Run_TokenRecordMismatchIsFatalOnEveryChain() public {
        FireToken other = new FireToken(address(new FireVesting(makeAddr("other-beneficiary"), 1, 1)));
        deployScript.setRecord(_record(address(fire), address(0)));
        deployScript.setVar("FIRE_TOKEN", vm.toString(address(other)));
        _expectMismatch("FIRE_TOKEN", address(other), address(fire));
        deployScript.run();

        vm.chainId(BASE_SEPOLIA);
        _expectMismatch("FIRE_TOKEN", address(other), address(fire));
        deployScript.run();
    }

    /**
     * @dev 리뷰 PoC(F2) 회귀: 메인넷 고정 기준은 Deploy가 쓴 런칭 기록이어야 함(deployer·deployerNonce가 있고 토큰 =
     *      CREATE(deployer, deployerNonce + 1)). CreatePool이 FIRE_TOKEN 값만으로 만든 최소 기록이나 손으로 고친 기록은
     *      거부하며, CreatePool도 메인넷에서는 그런 최소 기록을 만들지 않음. 예전에는 복제 토큰을 쓰는 Batch Sender가 배포됐음.
     */
    function test_Run_MainnetRejectsRecordThatIsNotALaunchRecord() public {
        FireToken clone = new FireToken(address(new FireVesting(makeAddr("clone-beneficiary"), 1, 1)));
        string memory path = "deployments/test-batch-minimal-record.json";
        CreatePool poolScript = new CreatePool();
        vm.chainId(BASE_MAINNET);
        vm.expectRevert(abi.encodeWithSelector(CreatePool.CreatePoolLaunchRecordRequired.selector, path));
        poolScript.writePoolRecord('{"status":"pending"}', address(clone), path);
        assertFalse(vm.exists(path));

        _useMainnet();
        deployScript.clearVar("FIRE_TOKEN");
        deployScript.setRecord(
            string.concat('{"chainId":8453,"contracts":{"FireToken":"', vm.toString(address(clone)), '"},"pool":{}}')
        );
        vm.expectRevert(
            abi.encodeWithSelector(DeployBatchSender.DeployBatchSenderRecordNotLaunch.selector, "deployments/8453.json")
        );
        deployScript.run();

        // deployer·nonce를 적었어도 토큰이 그 배포자의 CREATE(nonce + 1)이 아니면 거부
        deployScript.setRecord(
            string.concat(
                '{"chainId":8453,"deployer":"',
                vm.toString(address(this)),
                '","deployerNonce":',
                vm.toString(launchNonce),
                ',"contracts":{"FireToken":"',
                vm.toString(address(clone)),
                '"}}'
            )
        );
        vm.expectRevert(
            abi.encodeWithSelector(DeployBatchSender.DeployBatchSenderRecordNotLaunch.selector, "deployments/8453.json")
        );
        deployScript.run();
    }

    // ───────── 메인넷 소유자(트레저리 Safe) ─────────

    function test_Run_MainnetOwnerMustMatchRecordedTreasury() public {
        address otherSafe = address(new BatchDeploySafeStub(2, 3));
        _useMainnet();
        deployScript.setVar("BATCH_SENDER_OWNER", vm.toString(otherSafe));
        _expectMismatch("BATCH_SENDER_OWNER", otherSafe, safe);
        deployScript.run();
    }

    function test_Run_MainnetRejectsEOAOwner() public {
        address eoaOwner = makeAddr("eoa-owner");
        _useMainnet();
        deployScript.setRecord(_record(address(fire), address(0))); // 트레저리 미기록 → Safe 검사로 판별
        deployScript.setVar("BATCH_SENDER_OWNER", vm.toString(eoaOwner));
        vm.expectRevert(
            abi.encodeWithSelector(DeployBatchSender.DeployBatchSenderOwnerNotSafe.selector, eoaOwner, 0, 0)
        );
        deployScript.run();
    }

    function test_Run_MainnetRejectsContractOwnerThatIsNotASafe() public {
        // 호출할 수 없는 컨트랙트가 소유자가 되면 수수료 설정이 영구 동결됨 (renounce·rescue 없음)
        address[3] memory wrong = [address(fire), address(vesting), address(new BatchDeployOtherToken("WETH", 18))];
        _useMainnet();
        deployScript.setRecord(_record(address(fire), address(0)));
        for (uint256 i = 0; i < wrong.length; ++i) {
            deployScript.setVar("BATCH_SENDER_OWNER", vm.toString(wrong[i]));
            vm.expectRevert(
                abi.encodeWithSelector(DeployBatchSender.DeployBatchSenderOwnerNotSafe.selector, wrong[i], 0, 0)
            );
            deployScript.run();
        }
    }

    function test_Run_MainnetRejectsSafeBelowTwoOfThree() public {
        uint256[2][3] memory configs = [[uint256(1), 3], [uint256(2), 2], [uint256(1), 1]];
        _useMainnet();
        deployScript.setRecord(_record(address(fire), address(0)));
        for (uint256 i = 0; i < configs.length; ++i) {
            address weak = address(new BatchDeploySafeStub(configs[i][0], configs[i][1]));
            deployScript.setVar("BATCH_SENDER_OWNER", vm.toString(weak));
            vm.expectRevert(
                abi.encodeWithSelector(
                    DeployBatchSender.DeployBatchSenderOwnerNotSafe.selector, weak, configs[i][0], configs[i][1]
                )
            );
            deployScript.run();
        }
        // 2-of-3 이상은 허용 (3-of-5)
        address strong = address(new BatchDeploySafeStub(3, 5));
        deployScript.setVar("BATCH_SENDER_OWNER", vm.toString(strong));
        _assertDeployed(deployScript.run(), strong, 25, 10_000e18);
    }

    function test_Run_MainnetRejectsContractAnsweringOnlyGetThreshold() public {
        address thresholdOnly = address(new BatchDeployThresholdOnlyStub());
        _useMainnet();
        deployScript.setRecord(_record(address(fire), address(0)));
        deployScript.setVar("BATCH_SENDER_OWNER", vm.toString(thresholdOnly));
        vm.expectRevert(
            abi.encodeWithSelector(DeployBatchSender.DeployBatchSenderOwnerNotSafe.selector, thresholdOnly, 2, 0)
        );
        deployScript.run();
    }

    /// @dev 리뷰 PoC(F6) 회귀: 모듈이 활성화된(또는 모듈을 읽을 수 없는) Safe는 모듈이 서명 없이 Safe로서
    ///      setBurnFee 등을 호출할 수 있으므로 메인넷 소유자로 거부. 테스트넷은 경고만.
    function test_Run_MainnetRejectsSafeOwnerWithModules() public {
        _useMainnet();
        BatchDeploySafeStub(safe).setModule(makeAddr("module"));
        vm.expectRevert(abi.encodeWithSelector(DeployBatchSender.DeployBatchSenderOwnerHasModules.selector, safe));
        deployScript.run();

        address legacy = address(new BatchDeployLegacySafeStub());
        deployScript.setRecord(_record(address(fire), address(0)));
        deployScript.setVar("BATCH_SENDER_OWNER", vm.toString(legacy));
        vm.expectRevert(abi.encodeWithSelector(DeployBatchSender.DeployBatchSenderOwnerHasModules.selector, legacy));
        deployScript.run();

        vm.chainId(BASE_SEPOLIA); // 리허설: 경고만
        _assertDeployed(deployScript.run(), legacy, 25, 10_000e18);
        deployScript.setVar("BATCH_SENDER_OWNER", vm.toString(safe));
        _assertDeployed(deployScript.run(), safe, 25, 10_000e18);
    }

    function test_Run_MainnetRejectsEIP7702DelegatedOwner() public {
        vm.setEvmVersion("prague");
        // 위임 대상이 2-of-3 Safe처럼 응답해도 EOA의 원래 개인 키 하나로 언제든 서명 가능 → 거부
        address delegatedEoa = makeAddr("hot-wallet-with-7702");
        vm.etch(delegatedEoa, abi.encodePacked(hex"ef0100", safe));
        assertEq(delegatedEoa.code.length, 23);
        (, bytes memory threshold) = delegatedEoa.staticcall(abi.encodeWithSignature("getThreshold()"));
        assertEq(abi.decode(threshold, (uint256)), 2, "the delegate answers like a Safe");

        _useMainnet();
        deployScript.setRecord(_record(address(fire), address(0)));
        deployScript.setVar("BATCH_SENDER_OWNER", vm.toString(delegatedEoa));
        vm.expectRevert(
            abi.encodeWithSelector(DeployBatchSender.DeployBatchSenderOwnerIsDelegatedEOA.selector, delegatedEoa)
        );
        deployScript.run();
    }

    // ───────── 입력 검증 ─────────

    function test_Run_RevertsWhenFireTokenMissing() public {
        deployScript.clearVar("FIRE_TOKEN");
        vm.expectRevert(
            abi.encodeWithSelector(DeployBatchSender.DeployBatchSenderMissingAddress.selector, "FIRE_TOKEN")
        );
        deployScript.run();
    }

    function test_Run_RevertsWhenOwnerMissing() public {
        deployScript.clearVar("BATCH_SENDER_OWNER");
        vm.expectRevert(
            abi.encodeWithSelector(DeployBatchSender.DeployBatchSenderMissingAddress.selector, "BATCH_SENDER_OWNER")
        );
        deployScript.run();
    }

    function test_Run_RevertsWhenFireTokenHasNoCode() public {
        address eoa = makeAddr("not-a-token");
        deployScript.setVar("FIRE_TOKEN", vm.toString(eoa));
        _expectInvalidToken(eoa);
        deployScript.run();
    }

    function test_Run_RevertsWhenTokenIsNotFire() public {
        address weth = address(new BatchDeployOtherToken("WETH", 18));
        deployScript.setVar("FIRE_TOKEN", vm.toString(weth));
        _expectInvalidToken(weth);
        deployScript.run();
    }

    function test_Run_RevertsWhenFireSymbolHasWrongDecimals() public {
        address fake = address(new BatchDeployOtherToken("FIRE", 6));
        deployScript.setVar("FIRE_TOKEN", vm.toString(fake));
        _expectInvalidToken(fake);
        deployScript.run();
    }

    function _lookalike(
        string memory symbol_,
        uint8 decimals_,
        uint256 maxSupply,
        uint256 vestingSupply,
        uint256 minted
    ) internal returns (address) {
        return address(
            new BatchDeployLookalikeToken(
                BatchDeployLookalikeToken.Spec({
                    name: "Fire",
                    symbol: symbol_,
                    decimals: decimals_,
                    maxSupply: maxSupply,
                    vesting: vestingSupply,
                    minted: minted
                })
            )
        );
    }

    function test_Run_RejectsLookalikeFireTokens() public {
        uint256 max = 1_000_000_000e18;
        uint256 vest = 200_000_000e18;
        address[11] memory fakes = [
            // symbol FIRE·decimals 18이지만 name이 다름 (리뷰 재현: 이전에는 메인넷에서도 통과)
            address(new BatchDeployOtherToken("FIRE", 18)),
            // name은 Fire지만 symbol·decimals가 다르거나 조회 자체가 revert
            _lookalike("FIRE2", 18, max, vest, 1e18),
            _lookalike("FIRE", 6, max, vest, 1e18),
            address(new BatchDeployBrokenMetadataToken(true)),
            address(new BatchDeployBrokenMetadataToken(false)),
            // name·symbol·decimals는 같지만 FireToken 상수가 없거나 값이 다름
            address(new BatchDeployMetadataOnlyToken()),
            _lookalike("FIRE", 18, 2 * max, vest, 1e18),
            _lookalike("FIRE", 18, max, vest / 2, 1e18),
            _lookalike("FIRE", 18, max, type(uint256).max, 1e18),
            // 발행량이 상한 초과 또는 0
            _lookalike("FIRE", 18, max, vest, max + 1),
            _lookalike("FIRE", 18, max, vest, 0)
        ];
        for (uint256 i = 0; i < fakes.length; ++i) {
            deployScript.setVar("FIRE_TOKEN", vm.toString(fakes[i]));
            _expectInvalidToken(fakes[i]);
            deployScript.run();
        }
        // 대조군: 같은 상수를 가진 사칭 토큰은 식별 검사를 통과 → 메인넷은 런칭 기록으로 고정해야 하는 이유
        address lookalike = _lookalike("FIRE", 18, max, vest, 1e18);
        deployScript.setVar("FIRE_TOKEN", vm.toString(lookalike));
        assertEq(deployScript.run().fireToken(), lookalike, "passes identity checks off mainnet without a record");
        _useMainnet();
        deployScript.setVar("FIRE_TOKEN", vm.toString(lookalike));
        _expectMismatch("FIRE_TOKEN", lookalike, address(fire));
        deployScript.run();
    }

    function test_Run_RevertsWhenFireTokenIsAnotherContract() public {
        // 베스팅 컨트랙트 주소를 잘못 넣은 경우: name()이 없어 호출 자체가 실패
        deployScript.setVar("FIRE_TOKEN", vm.toString(address(vesting)));
        _expectInvalidToken(address(vesting));
        deployScript.run();
    }

    function test_Run_ZeroOwnerIsTreatedAsMissing() public {
        deployScript.setVar("BATCH_SENDER_OWNER", vm.toString(address(0)));
        vm.expectRevert(
            abi.encodeWithSelector(DeployBatchSender.DeployBatchSenderMissingAddress.selector, "BATCH_SENDER_OWNER")
        );
        deployScript.run();

        DeployBatchSender.Config memory cfg = DeployBatchSender.Config({
            fireToken: address(fire), owner: address(0), freeRecipientLimit: 25, burnFee: 10_000e18
        });
        vm.expectRevert(abi.encodeWithSelector(DeployBatchSender.DeployBatchSenderInvalidOwner.selector, address(0)));
        deployScript.deploy(cfg);
    }

    function test_Run_RevertsWhenFeeAboveContractCap() public {
        deployScript.setVar("BATCH_BURN_FEE_FIRE", "1000001");
        vm.expectRevert(
            abi.encodeWithSelector(FireBatchSender.FireBatchSenderBurnFeeTooHigh.selector, 1_000_001e18, 1_000_000e18)
        );
        deployScript.run();
    }

    function test_Run_RevertsWhenFeeConversionWouldOverflow() public {
        uint256 huge = type(uint256).max / 1e18 + 1;
        deployScript.setVar("BATCH_BURN_FEE_FIRE", vm.toString(huge));
        vm.expectRevert(abi.encodeWithSelector(DeployBatchSender.DeployBatchSenderBurnFeeOverflow.selector, huge));
        deployScript.run();

        deployScript.setVar("BATCH_BURN_FEE_FIRE", vm.toString(type(uint256).max));
        vm.expectRevert(
            abi.encodeWithSelector(DeployBatchSender.DeployBatchSenderBurnFeeOverflow.selector, type(uint256).max)
        );
        deployScript.run();
    }

    function test_Run_RevertsWhenFreeRecipientsAboveMax() public {
        deployScript.setVar("BATCH_FREE_RECIPIENTS", "301");
        vm.expectRevert(
            abi.encodeWithSelector(FireBatchSender.FireBatchSenderFreeRecipientLimitTooHigh.selector, 301, 300)
        );
        deployScript.run();
    }

    function test_Run_RevertsOnMalformedNumber() public {
        string[4] memory malformed = ["twenty-five", "1,000", "2.5", " 25"];
        for (uint256 i = 0; i < malformed.length; ++i) {
            deployScript.setVar("BATCH_FREE_RECIPIENTS", malformed[i]);
            vm.expectRevert();
            deployScript.run();
        }
    }

    // ───────── RPC 체인 ID 대조 (LaunchGuards 공유) ─────────

    /// @dev --rpc-url base --chain base-sepolia: 메인넷 소유자 Safe 규칙·확인 문구를 건너뛰는 위장 → 중단.
    function test_RevertWhen_ChainFlagSpoofsTestnetOnMainnetRpc() public {
        address eoaOwner = makeAddr("rehearsal-owner");
        deployScript.setVar("BATCH_SENDER_OWNER", vm.toString(eoaOwner)); // 메인넷이면 거부될 소유자
        vm.chainId(BASE_SEPOLIA);
        deployScript.setRpcChainId(true, BASE_MAINNET);
        bytes memory mismatch =
            abi.encodeWithSelector(LaunchGuards.LaunchChainIdMismatch.selector, BASE_SEPOLIA, BASE_MAINNET);
        vm.expectRevert(mismatch);
        deployScript.run();
        DeployBatchSender.Config memory cfg = DeployBatchSender.Config({
            fireToken: address(fire), owner: eoaOwner, freeRecipientLimit: 25, burnFee: 10_000e18
        });
        vm.expectRevert(mismatch);
        deployScript.deploy(cfg);
    }

    function test_ChainCheck_MatchingRpcProceeds() public {
        vm.chainId(BASE_SEPOLIA);
        deployScript.setRpcChainId(true, BASE_SEPOLIA);
        _assertDeployed(deployScript.run(), safe, 25, 10_000e18);
    }

    /// @dev RPC가 없는 로컬 드라이런은 진행, --broadcast인데 RPC를 조회할 수 없으면 중단.
    function test_ChainCheck_NoRpc_DryRunProceedsBroadcastReverts() public {
        deployScript.setRpcChainId(false, 0);
        deployScript.setBroadcastContext(true);
        vm.expectRevert(LaunchGuards.LaunchRpcUnavailable.selector);
        deployScript.run();
        deployScript.setBroadcastContext(false);
        _assertDeployed(deployScript.run(), safe, 25, 10_000e18);
    }

    // ───────── EIP-55 주소 파싱 (LaunchGuards 공유) ─────────

    /// @dev 체크섬 대소문자 한 글자 오타는 모든 체인에서 거부 (vm.parseAddress는 다른 주소로 받아들임).
    function test_RevertWhen_EnvAddressHasChecksumTypo() public {
        string[2] memory names = ["FIRE_TOKEN", "BATCH_SENDER_OWNER"];
        address[2] memory values = [address(fire), safe];
        for (uint256 i; i < names.length; ++i) {
            string memory typo = _checksumTypo(values[i]);
            assertEq(vm.parseAddress(typo), values[i]); // forge 자체는 그대로 통과시킴
            deployScript.setVar(names[i], typo);
            vm.expectRevert(abi.encodeWithSelector(LaunchGuards.LaunchBadChecksum.selector, names[i]));
            deployScript.loadConfig();
            vm.chainId(BASE_SEPOLIA);
            vm.expectRevert(abi.encodeWithSelector(LaunchGuards.LaunchBadChecksum.selector, names[i]));
            deployScript.run();
            vm.chainId(LOCAL_CHAIN);
            deployScript.setVar(names[i], vm.toString(values[i]));
        }
    }

    /// @dev 전부 소문자인 주소(체크섬 정보 없음): 테스트넷·로컬은 허용, Base 메인넷은 거부.
    function test_Env_LowercaseAddressesOnlyOffMainnet() public {
        deployScript.setVar("FIRE_TOKEN", vm.toLowercase(vm.toString(address(fire))));
        deployScript.setVar("BATCH_SENDER_OWNER", vm.toLowercase(vm.toString(safe)));
        vm.chainId(BASE_SEPOLIA);
        _assertDeployed(deployScript.run(), safe, 25, 10_000e18);

        _useMainnet();
        vm.expectRevert(abi.encodeWithSelector(LaunchGuards.LaunchChecksumRequired.selector, "FIRE_TOKEN"));
        deployScript.run();
        deployScript.setVar("FIRE_TOKEN", vm.toString(address(fire)));
        vm.expectRevert(abi.encodeWithSelector(LaunchGuards.LaunchChecksumRequired.selector, "BATCH_SENDER_OWNER"));
        deployScript.run();
        deployScript.setVar("BATCH_SENDER_OWNER", vm.toString(safe));
        _assertDeployed(deployScript.run(), safe, 25, 10_000e18);
    }

    function test_RevertWhen_EnvAddressMalformed() public {
        string[4] memory malformed = [
            "not-an-address",
            string.concat(" ", vm.toString(safe)),
            vm.replace(vm.toString(safe), "0x", ""),
            string.concat(vm.toString(safe), "0")
        ];
        for (uint256 i; i < malformed.length; ++i) {
            deployScript.setVar("BATCH_SENDER_OWNER", malformed[i]);
            vm.expectRevert(abi.encodeWithSelector(LaunchGuards.LaunchInvalidAddress.selector, "BATCH_SENDER_OWNER"));
            deployScript.loadConfig();
        }
    }

    /// @dev EIP-55 표기에서 첫 소문자 16진 문자를 대문자로 바꾼 오타 (대문자가 남으므로 체크섬 불일치).
    function _checksumTypo(address account) internal pure returns (string memory) {
        bytes memory b = bytes(vm.toString(account));
        for (uint256 i = 2; i < b.length; ++i) {
            if (b[i] >= "a" && b[i] <= "f") {
                b[i] = bytes1(uint8(b[i]) - 32);
                return string(b);
            }
        }
        revert("no lowercase letter to flip");
    }

    // ───────── 실제 입력 경로 (하네스 재정의 없음) ─────────

    // 실제 환경 변수 경로를 검증하려면 vm.setEnv가 필요함. 이 테스트만 쓰는 고유 변수명이라 다른 테스트와 겹치지 않음.
    // forge-lint: disable-next-item(unsafe-cheatcode)
    /// @dev 실제 _envString(vm.envOr) 경로. 이 테스트만 쓰는 고유 변수명이라 병렬 테스트와 경쟁하지 않음.
    function test_EnvReaders_RealProcessEnvironment() public {
        BatchDeployEnvProbe probe = new BatchDeployEnvProbe();
        string memory unsetName = "FIRE_BATCH_DEPLOY_TEST_UNSET_3b9e";
        string memory name = "FIRE_BATCH_DEPLOY_TEST_VALUE_3b9e";

        assertEq(probe.envString(unsetName), "");
        assertEq(probe.envUintOr(unsetName, 25), 25);
        assertEq(probe.envAddressOr(unsetName, address(0xBEEF)), address(0xBEEF));

        vm.setEnv(name, "");
        assertEq(probe.envUintOr(name, 10_000), 10_000, "empty value means unset");
        assertEq(probe.envAddressOr(name, address(fire)), address(fire));

        vm.setEnv(name, "2500");
        assertEq(probe.envUintOr(name, 10_000), 2500);
        vm.setEnv(name, vm.toString(address(fire)));
        assertEq(probe.envAddressOr(name, address(0)), address(fire));

        vm.setEnv(name, "1,000");
        vm.expectRevert();
        probe.envUintOr(name, 10_000);

        assertEq(probe.recordPath(), "deployments/31337.json");
        vm.chainId(BASE_MAINNET);
        assertEq(probe.recordPath(), "deployments/8453.json");
    }

    // 실제 파일 읽기 경로를 검증하려면 임시 기록 파일이 필요함 (fs_permissions: ./deployments 읽기·쓰기, 테스트 전용 파일명).
    // forge-lint: disable-next-item(unsafe-cheatcode)
    /// @dev 실제 기록 파일 읽기 경로(vm.exists + vm.readFile + JSON 파싱). 임시 파일은 테스트가 직접 지움.
    function test_LoadConfig_ReadsDeploymentRecordFile() public {
        string memory path = "deployments/test-batchsender-record.json";
        vm.writeFile(path, _record(address(fire), safe));
        deployScript.useRecordFile(path);
        deployScript.clearVar("FIRE_TOKEN");
        deployScript.clearVar("BATCH_SENDER_OWNER");

        DeployBatchSender.Config memory cfg = deployScript.loadConfig();
        vm.removeFile(path);

        assertEq(cfg.fireToken, address(fire));
        assertEq(cfg.owner, safe);
    }

    function test_LoadConfig_MissingRecordFileMeansNoRecord() public {
        deployScript.useRecordFile("deployments/test-batchsender-missing.json");
        assertEq(deployScript.loadConfig().fireToken, address(fire), "env value still works");
        deployScript.clearVar("FIRE_TOKEN");
        vm.expectRevert(
            abi.encodeWithSelector(DeployBatchSender.DeployBatchSenderMissingAddress.selector, "FIRE_TOKEN")
        );
        deployScript.loadConfig();
    }
}
