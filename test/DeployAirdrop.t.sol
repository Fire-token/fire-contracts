// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {FireToken} from "../src/FireToken.sol";
import {FireVesting} from "../src/FireVesting.sol";
import {FireMerkleDistributor} from "../src/FireMerkleDistributor.sol";
import {DeployAirdrop} from "../script/DeployAirdrop.s.sol";
import {LaunchGuards} from "../script/lib/LaunchGuards.sol";
import {AirdropFixture} from "./FireMerkleDistributor.t.sol";

/// @dev 스크립트 내부 함수를 테스트하기 위한 하네스 (환경 변수는 실제 프로세스 환경에서 읽음).
///      배포 기록은 파일 대신 setRecord로 넣은 값만 읽음(기본 "" = 기록 없음): 저장소에 커밋된 deployments/84532.json
///      ·8453.json이 테스트 결과에 섞이지 않게 함.
contract AirdropDeployHarness is DeployAirdrop {
    string internal record;

    function setRecord(string memory json) external {
        record = json;
    }

    function _readDeploymentRecord() internal view override returns (string memory) {
        return record;
    }

    function exposedBroadcaster() external returns (address) {
        return _broadcaster();
    }

    function exposedEnvString(string memory name) external view returns (string memory) {
        return _envString(name);
    }

    function exposedFormatFire(uint256 amount) external pure returns (string memory) {
        return _formatFire(amount);
    }
}

/// @dev 프로세스 전역 환경 변수 대신 주입한 값을 읽는 하네스 (병렬 테스트 간 경쟁 없음).
///      RPC 체인 ID 대조를 검증하기 위해 실행 문맥(--broadcast 여부)과 RPC의 eth_chainId 응답도 주입할 수 있음.
contract AirdropEnvHarness is DeployAirdrop {
    mapping(string name => string value) internal fakeEnv;
    bool internal rpcCheck;
    bool internal rpcOk;
    uint256 internal rpcId;
    bool internal broadcastContext;
    string internal record;

    /// @dev 배포 기록(deployments/<chainId>.json 대신, 기본 "" = 기록 없음).
    function setRecord(string memory json) external {
        record = json;
    }

    function _readDeploymentRecord() internal view override returns (string memory) {
        return record;
    }

    function setFakeEnv(string memory name, string memory value) external {
        fakeEnv[name] = value;
    }

    /// @dev RPC 대조를 강제하고 eth_chainId 응답(ok=false면 RPC 없음)을 흉내 냄.
    function setRpcChainId(bool ok, uint256 chainId) external {
        rpcCheck = true;
        rpcOk = ok;
        rpcId = chainId;
    }

    function setBroadcastContext(bool on) external {
        broadcastContext = on;
    }

    function _envString(string memory name) internal view override returns (string memory) {
        return fakeEnv[name];
    }

    function _enforceRpcChainCheck() internal view override returns (bool) {
        return rpcCheck;
    }

    function _rpcChainId() internal view override returns (bool, uint256) {
        return (rpcOk, rpcId);
    }

    function _isBroadcastRun() internal view override returns (bool) {
        return broadcastContext;
    }
}

/// @dev FIRE가 아닌 토큰 (심볼·소수점 검증용)
contract AirdropMockToken is ERC20 {
    uint8 private immutable _DECIMALS;

    constructor(string memory symbol_, uint8 decimals_) ERC20("Mock", symbol_) {
        _DECIMALS = decimals_;
        _mint(msg.sender, 1e30);
    }

    function decimals() public view override returns (uint8) {
        return _DECIMALS;
    }
}

/// @dev FireToken의 고유 상수(TOTAL_SUPPLY·VESTING_SUPPLY)만 흉내 내는 믹스인 (스크립트의 토큰 확인 통과용).
abstract contract AirdropFireConstants {
    // forge-lint: disable-next-line(mixed-case-function)
    function TOTAL_SUPPLY() external pure returns (uint256) {
        return 1_000_000_000e18;
    }

    // forge-lint: disable-next-line(mixed-case-function)
    function VESTING_SUPPLY() external pure returns (uint256) {
        return 200_000_000e18;
    }
}

/// @dev 받는 쪽에서 1%를 떼는 토큰 (심볼 FIRE) → 예치 사후 확인(FundingMismatch) 검증용
contract AirdropFeeOnTransferToken is ERC20, AirdropFireConstants {
    constructor() ERC20("Fee", "FIRE") {
        _mint(msg.sender, 1e30);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from == address(0) || to == address(0)) return super._update(from, to, value);
        uint256 fee = value / 100;
        super._update(from, to, value - fee);
        super._update(from, address(0), fee);
    }
}

/// @dev 보내는 쪽에서 1 wei를 더 떼는 토큰 (심볼 FIRE) → 브로드캐스터 잔액 사후 확인 검증용
contract AirdropSenderFeeToken is ERC20, AirdropFireConstants {
    constructor() ERC20("SenderFee", "FIRE") {
        _mint(msg.sender, 1e30);
    }

    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        if (from != address(0) && to != address(0)) super._update(from, address(0), 1);
    }
}

/**
 * @dev script/DeployAirdrop.s.sol의 배포 로직을 로컬(31337 등)에서 샘플 픽스처로 실행.
 *      FIRE_TOKEN·AIRDROP_WALLET·CONFIRM_MAINNET 같은 공용 환경 변수는 건드리지 않고 deploy(params, broadcaster)를
 *      직접 호출하거나 AirdropEnvHarness로 값을 주입함. 헤더만 다른 merkle.json 변형은 실행 중에
 *      deployments/test-airdrop-*.json으로 만들고 테스트 끝에서 지움 (fs_permissions상 쓰기 가능한 유일한 경로).
 */
contract DeployAirdropTest is AirdropFixture {
    AirdropDeployHarness internal script;
    FireToken internal token;
    address internal deployer = makeAddr("deployer");
    address internal airdropWallet = makeAddr("airdropWallet");
    bytes32 internal constant OTHER_ROOT = keccak256("fire-airdrop-test-other-root");

    function setUp() public {
        _loadAirdropFixture();
        token = _deployFireWithAirdropWallet(deployer, airdropWallet);
        script = new AirdropDeployHarness();
    }

    function _params() internal view returns (DeployAirdrop.Params memory params) {
        params.token = address(token);
        params.merkleJsonPath = AIRDROP_FIXTURE;
        params.claimDays = 90;
    }

    /// @dev Deploy가 쓰는 런칭 기록 형식 (deployer가 nonce 0·1로 FireVesting·FireToken을 만듦, _deployFireWithAirdropWallet).
    function _launchRecordWith(address recordedToken) internal view returns (string memory) {
        return string.concat(
            '{"chainId":8453,"deployer":"',
            vm.toString(deployer),
            '","deployerNonce":0,"contracts":{"FireToken":"',
            vm.toString(recordedToken),
            '"},"wallets":{"airdropWallet":"',
            vm.toString(airdropWallet),
            '"}}'
        );
    }

    function _launchRecord() internal view returns (string memory) {
        return _launchRecordWith(address(token));
    }

    /// @dev 메인넷 가드(확인 문구·AIRDROP_WALLET·AIRDROP_EXPECTED_ROOT·런칭 기록)를 모두 채운 Params
    function _mainnetParams(string memory merkleJsonPath, bytes32 expectedRoot)
        internal
        returns (DeployAirdrop.Params memory params)
    {
        script.setRecord(_launchRecord());
        params = _params();
        params.merkleJsonPath = merkleJsonPath;
        params.confirmMainnet = "I_UNDERSTAND";
        params.airdropWallet = airdropWallet;
        params.expectedRoot = expectedRoot;
    }

    // ── 실행 중 만드는 merkle.json (generate.mjs와 같은 레이아웃) ──

    function _headerFields(uint256 round, bytes32 root, uint256 total, string memory totalFire, uint256 count)
        internal
        pure
        returns (string memory)
    {
        return string.concat(
            '  "round": ',
            vm.toString(round),
            ",\n",
            '  "root": "',
            vm.toString(root),
            '",\n',
            '  "total": "',
            vm.toString(total),
            '",\n',
            '  "totalFire": "',
            totalFire,
            '",\n',
            '  "count": ',
            vm.toString(count),
            ",\n"
        );
    }

    /// @dev deployments/test-airdrop-<tag>-<난수>.json. 난수 접미사로 같은 체크아웃에서 forge test를 동시에 돌려도 충돌하지 않음
    function _tempPath(string memory tag) internal view returns (string memory) {
        return string.concat("deployments/test-airdrop-", tag, "-", vm.toString(vm.randomUint() % 1e12), ".json");
    }

    function _writeMerkleJson(string memory tag, string memory headerFields) internal returns (string memory path) {
        path = _tempPath(tag);
        vm.writeFile(
            path,
            string.concat(
                "{\n",
                headerFields,
                '  "claims": {\n    "',
                vm.toString(fixtureAccounts[0]),
                '": {\n      "amount": "1",\n      "proof": []\n    }\n  }\n}\n'
            )
        );
    }

    function _expectInvalidMerkleJson(string memory tag, string memory headerFields, string memory reason) internal {
        DeployAirdrop.Params memory params = _params();
        params.merkleJsonPath = _writeMerkleJson(tag, headerFields);
        vm.expectRevert(
            abi.encodeWithSelector(DeployAirdrop.DeployAirdropInvalidMerkleJson.selector, params.merkleJsonPath, reason)
        );
        script.deploy(params, airdropWallet);
        vm.removeFile(params.merkleJsonPath);
    }

    // ───────────────────────── 정상 배포 ─────────────────────────

    function test_Deploy_FundsExactlyMerkleTotalFromAirdropWallet() public {
        FireMerkleDistributor distributor = script.deploy(_params(), airdropWallet);

        assertEq(address(distributor), vm.computeCreateAddress(airdropWallet, 0)); // 에어드롭 지갑이 직접 배포
        assertEq(token.balanceOf(address(distributor)), fixtureTotal);
        assertEq(token.balanceOf(airdropWallet), AIRDROP_ALLOCATION - fixtureTotal);
        assertEq(token.balanceOf(deployer), 750_000_000e18); // 토큰 배포자 지갑은 관여하지 않음
        assertEq(address(distributor.TOKEN()), address(token));
        assertEq(distributor.MERKLE_ROOT(), fixtureRoot);
        assertEq(distributor.CLAIM_DEADLINE(), block.timestamp + 90 days);
        assertEq(distributor.SWEEP_RECIPIENT(), airdropWallet); // 기본값 = 브로드캐스터
    }

    function test_Deploy_CustomSweepRecipientAndClaimDays() public {
        DeployAirdrop.Params memory params = _params();
        params.claimDays = 30;
        params.sweepRecipient = makeAddr("airdropSafe");

        FireMerkleDistributor distributor = script.deploy(params, airdropWallet);
        assertEq(distributor.CLAIM_DEADLINE(), block.timestamp + 30 days);
        assertEq(distributor.SWEEP_RECIPIENT(), params.sweepRecipient);
    }

    function test_Deploy_OnBaseSepoliaChainId() public {
        vm.chainId(84532);
        FireMerkleDistributor distributor = script.deploy(_params(), airdropWallet);
        assertEq(token.balanceOf(address(distributor)), fixtureTotal);
    }

    function test_Deploy_WithMatchingAirdropWalletAndExpectedRoot() public {
        DeployAirdrop.Params memory params = _params();
        params.airdropWallet = airdropWallet;
        params.expectedRoot = fixtureRoot;
        FireMerkleDistributor distributor = script.deploy(params, airdropWallet);
        assertEq(distributor.MERKLE_ROOT(), fixtureRoot);
    }

    function test_Deploy_EndToEnd_ClaimThenSweepRollsOverToAirdropWallet() public {
        FireMerkleDistributor distributor = script.deploy(_params(), airdropWallet);

        uint256 claimed;
        for (uint256 i; i < fixtureCount; i += 2) {
            distributor.claim(fixtureAccounts[i], fixtureAmounts[i], fixtureProofs[i]);
            assertEq(token.balanceOf(fixtureAccounts[i]), fixtureAmounts[i]);
            claimed += fixtureAmounts[i];
        }

        vm.warp(uint256(distributor.CLAIM_DEADLINE()) + 1);
        distributor.sweep();
        assertEq(token.balanceOf(address(distributor)), 0);
        // 미청구분이 에어드롭 지갑으로 돌아와 다음 회차로 이월 가능
        assertEq(token.balanceOf(airdropWallet), AIRDROP_ALLOCATION - claimed);
    }

    function testFuzz_Deploy_DeadlineIsClaimDaysAfterNow(uint256 claimDays, uint256 startTime) public {
        claimDays = _bound(claimDays, 1, 365);
        startTime = _bound(startTime, block.timestamp, 4_000_000_000);
        vm.warp(startTime);

        DeployAirdrop.Params memory params = _params();
        params.claimDays = claimDays;
        FireMerkleDistributor distributor = script.deploy(params, airdropWallet);
        assertEq(distributor.CLAIM_DEADLINE(), startTime + claimDays * 1 days);
    }

    function test_MaxClaimDaysMatchesContractCap() public {
        FireMerkleDistributor distributor = script.deploy(_params(), airdropWallet);
        assertEq(script.MAX_CLAIM_DAYS() * 1 days, distributor.MAX_CLAIM_PERIOD());
    }

    // ───────────────────────── 배포 주소 선입금(더스트) ─────────────────────────

    /// @dev 회귀: 예측 가능한 다음 CREATE 주소들에 1 wei씩 보내 두어도 배포가 막히지 않음
    function test_Deploy_DustAtPredictedAddressesDoesNotBlock() public {
        address griefer = makeAddr("griefer");
        vm.prank(deployer);
        require(token.transfer(griefer, 100), "transfer failed");
        uint64 nonce = vm.getNonce(airdropWallet);
        vm.startPrank(griefer);
        for (uint64 k; k < 10; ++k) {
            require(token.transfer(vm.computeCreateAddress(airdropWallet, nonce + k), 1), "dust");
        }
        vm.stopPrank();

        FireMerkleDistributor distributor = script.deploy(_params(), airdropWallet);
        assertEq(token.balanceOf(address(distributor)), fixtureTotal + 1);
        assertEq(token.balanceOf(airdropWallet), AIRDROP_ALLOCATION - fixtureTotal); // 정확히 total만 예치

        for (uint256 i; i < fixtureCount; ++i) {
            distributor.claim(fixtureAccounts[i], fixtureAmounts[i], fixtureProofs[i]);
        }
        vm.warp(uint256(distributor.CLAIM_DEADLINE()) + 1);
        distributor.sweep(); // 선입금된 1 wei는 마감 후 에어드롭 지갑으로 회수
        assertEq(token.balanceOf(airdropWallet), AIRDROP_ALLOCATION - fixtureTotal + 1);
    }

    function testFuzz_Deploy_PreexistingBalanceIsAccounted(uint256 dust) public {
        dust = _bound(dust, 1, 1_000_000e18);
        vm.prank(deployer);
        require(token.transfer(vm.computeCreateAddress(airdropWallet, vm.getNonce(airdropWallet)), dust), "dust");

        FireMerkleDistributor distributor = script.deploy(_params(), airdropWallet);
        assertEq(token.balanceOf(address(distributor)), dust + fixtureTotal);
        assertEq(token.balanceOf(airdropWallet), AIRDROP_ALLOCATION - fixtureTotal);
    }

    // ───────────────────────── 같은 root 중복 배포 차단 ─────────────────────────

    /// @dev 회귀: 같은 명령을 다시 실행해도 두 번째 분배 컨트랙트가 만들어지지 않음 (이중 지급 방지)
    function test_RevertWhen_SameRootAlreadyDeployedByBroadcaster() public {
        FireMerkleDistributor first = script.deploy(_params(), airdropWallet);
        uint256 walletBalance = token.balanceOf(airdropWallet);

        vm.expectRevert(abi.encodeWithSelector(DeployAirdrop.DeployAirdropRootAlreadyDeployed.selector, address(first)));
        script.deploy(_params(), airdropWallet);
        assertEq(token.balanceOf(airdropWallet), walletBalance);
    }

    /// @dev 회귀: 이전 회차 파일을 다시 쓰면 마감·sweep 이후에도 거부함 (이미 청구한 주소가 다시 청구할 수 있으므로)
    function test_RevertWhen_PreviousRoundFileReusedAfterDeadlineAndSweep() public {
        FireMerkleDistributor first = script.deploy(_params(), airdropWallet);
        first.claim(fixtureAccounts[0], fixtureAmounts[0], fixtureProofs[0]);
        vm.warp(uint256(first.CLAIM_DEADLINE()) + 30 days);
        first.sweep();

        DeployAirdrop.Params memory params = _params();
        params.claimDays = 60;
        vm.expectRevert(abi.encodeWithSelector(DeployAirdrop.DeployAirdropRootAlreadyDeployed.selector, address(first)));
        script.deploy(params, airdropWallet);
    }

    /// @dev 다른 root·다른 토큰의 이전 배포, 분배 컨트랙트가 아닌 컨트랙트는 막지 않음
    function test_Deploy_IgnoresOtherRootsOtherTokensAndOtherContracts() public {
        FireToken otherToken = _deployFireWithAirdropWallet(makeAddr("otherDeployer"), makeAddr("otherAirdrop"));
        uint64 deadline = uint64(block.timestamp + 30 days);
        vm.startPrank(airdropWallet);
        new AirdropMockToken("MOCK", 18); // 분배 컨트랙트가 아닌 컨트랙트
        new FireMerkleDistributor(token, OTHER_ROOT, deadline, airdropWallet); // 다른 root, 클레임 기간 중
        new FireMerkleDistributor(otherToken, fixtureRoot, deadline, airdropWallet); // 같은 root, 다른 토큰
        vm.stopPrank();

        FireMerkleDistributor distributor = script.deploy(_params(), airdropWallet);
        assertEq(distributor.MERKLE_ROOT(), fixtureRoot);
        assertEq(token.balanceOf(address(distributor)), fixtureTotal);
    }

    /// @dev 검사 범위는 최근 MAX_NONCES_SCANNED개 nonce (에어드롭 전용 지갑의 nonce는 매우 작음). 범위 밖은 검사하지 않음
    function test_Deploy_ScanWindowCoversRecentNoncesOnly() public {
        FireMerkleDistributor first = script.deploy(_params(), airdropWallet);
        vm.setNonce(airdropWallet, uint64(vm.getNonce(airdropWallet) + script.MAX_NONCES_SCANNED()));

        FireMerkleDistributor second = script.deploy(_params(), airdropWallet);
        assertTrue(address(second) != address(first));
    }

    // ───────────────────────── 체인·메인넷 가드 ─────────────────────────

    function test_RevertWhen_UnsupportedChain() public {
        vm.chainId(1);
        vm.expectRevert(abi.encodeWithSelector(DeployAirdrop.DeployAirdropUnsupportedChain.selector, 1));
        script.deploy(_params(), airdropWallet);
    }

    function test_RevertWhen_MainnetNotConfirmed() public {
        vm.chainId(8453);
        vm.expectRevert(DeployAirdrop.DeployAirdropMainnetNotConfirmed.selector);
        script.deploy(_params(), airdropWallet);
    }

    function test_RevertWhen_MainnetConfirmationMisspelled() public {
        vm.chainId(8453);
        DeployAirdrop.Params memory params = _params();
        params.confirmMainnet = "i_understand";
        vm.expectRevert(DeployAirdrop.DeployAirdropMainnetNotConfirmed.selector);
        script.deploy(params, airdropWallet);
    }

    /// @dev 회귀: 샘플 목록은 경로 표기·복사본과 무관하게 메인넷에서 거부 (내용 기준)
    function test_RevertWhen_MainnetSampleList_AnyPathSpelling() public {
        vm.chainId(8453);
        string memory copy = _tempPath("sample-copy");
        vm.writeFile(copy, vm.readFile(AIRDROP_FIXTURE));
        string[4] memory paths =
            [AIRDROP_FIXTURE, "test/./fixtures/airdrop-sample.json", "test//fixtures/airdrop-sample.json", copy];
        for (uint256 i; i < paths.length; ++i) {
            DeployAirdrop.Params memory params = _mainnetParams(paths[i], fixtureRoot);
            vm.expectRevert(
                abi.encodeWithSelector(DeployAirdrop.DeployAirdropSampleListOnMainnet.selector, fixtureRoot)
            );
            script.deploy(params, airdropWallet);
        }
        vm.removeFile(copy);
        assertEq(script.SAMPLE_MERKLE_ROOT(), fixtureRoot); // 상수가 커밋된 픽스처와 같음
    }

    function test_RevertWhen_MainnetWithoutExpectedRoot() public {
        vm.chainId(8453);
        string memory path = _writeMerkleJson("mainnet-no-expected", _headerFields(1, OTHER_ROOT, 1000e18, "1000", 9));
        DeployAirdrop.Params memory params = _mainnetParams(path, bytes32(0));
        vm.expectRevert(abi.encodeWithSelector(DeployAirdrop.DeployAirdropMissingEnv.selector, "AIRDROP_EXPECTED_ROOT"));
        script.deploy(params, airdropWallet);
        vm.removeFile(path);
    }

    function test_RevertWhen_ExpectedRootDiffers() public {
        DeployAirdrop.Params memory params = _params();
        params.expectedRoot = OTHER_ROOT;
        vm.expectRevert(
            abi.encodeWithSelector(DeployAirdrop.DeployAirdropUnexpectedRoot.selector, fixtureRoot, OTHER_ROOT)
        );
        script.deploy(params, airdropWallet);
    }

    function test_RevertWhen_MainnetWithoutAirdropWallet() public {
        vm.chainId(8453);
        string memory path = _writeMerkleJson("mainnet-no-wallet", _headerFields(1, OTHER_ROOT, 1000e18, "1000", 9));
        DeployAirdrop.Params memory params = _mainnetParams(path, OTHER_ROOT);
        params.airdropWallet = address(0);
        vm.expectRevert(abi.encodeWithSelector(DeployAirdrop.DeployAirdropMissingEnv.selector, "AIRDROP_WALLET"));
        script.deploy(params, airdropWallet);
        vm.removeFile(path);
    }

    /// @dev 회귀: 배포자 지갑(7억 5천만 FIRE 보유)으로 잘못 서명하면 메인넷에서 거부
    function test_RevertWhen_MainnetBroadcasterIsTokenDeployer() public {
        vm.chainId(8453);
        string memory path = _writeMerkleJson("mainnet-deployer", _headerFields(1, OTHER_ROOT, 1000e18, "1000", 9));
        DeployAirdrop.Params memory params = _mainnetParams(path, OTHER_ROOT);
        vm.expectRevert(
            abi.encodeWithSelector(
                DeployAirdrop.DeployAirdropBroadcasterNotAirdropWallet.selector, deployer, airdropWallet
            )
        );
        script.deploy(params, deployer);
        vm.removeFile(path);
    }

    function test_RevertWhen_BroadcasterIsNotAirdropWalletOnTestnet() public {
        vm.chainId(84532);
        DeployAirdrop.Params memory params = _params();
        params.airdropWallet = airdropWallet;
        vm.expectRevert(
            abi.encodeWithSelector(
                DeployAirdrop.DeployAirdropBroadcasterNotAirdropWallet.selector, deployer, airdropWallet
            )
        );
        script.deploy(params, deployer);
    }

    function test_Deploy_Mainnet_SucceedsWhenEveryGuardIsSatisfied() public {
        vm.chainId(8453);
        string memory path = _writeMerkleJson("mainnet-ok", _headerFields(1, OTHER_ROOT, 1000e18, "1000", 9));
        FireMerkleDistributor distributor = script.deploy(_mainnetParams(path, OTHER_ROOT), airdropWallet);
        vm.removeFile(path);

        assertEq(distributor.MERKLE_ROOT(), OTHER_ROOT);
        assertEq(token.balanceOf(address(distributor)), 1000e18);
        assertEq(distributor.SWEEP_RECIPIENT(), airdropWallet);
    }

    /**
     * @dev 리뷰 PoC(F2) 회귀: 메인넷은 Deploy 런칭 기록이 필수이고 FIRE_TOKEN·AIRDROP_WALLET이 기록과 같아야 함.
     *      예전에는 다른 사람이 만든 바이트코드 복제 FIRE를 에어드롭 지갑에 뿌려 두면(주소 오염) 메인넷 가드를 모두 통과해
     *      공지한 회차가 가짜 토큰으로 집행될 수 있었음.
     */
    function test_RevertWhen_MainnetTokenOrWalletNotFromLaunchRecord() public {
        vm.chainId(8453);
        string memory path = _writeMerkleJson("mainnet-record", _headerFields(1, OTHER_ROOT, 1000e18, "1000", 9));
        DeployAirdrop.Params memory params = _mainnetParams(path, OTHER_ROOT);
        bytes memory recordRequired =
            abi.encodeWithSelector(DeployAirdrop.DeployAirdropLaunchRecordRequired.selector, "deployments/8453.json");
        script.setRecord("");
        vm.expectRevert(recordRequired);
        script.deploy(params, airdropWallet);
        // CreatePool 최소 기록처럼 배포자 정보가 없는 기록
        script.setRecord(string.concat('{"contracts":{"FireToken":"', vm.toString(address(token)), '"}}'));
        vm.expectRevert(recordRequired);
        script.deploy(params, airdropWallet);

        vm.startPrank(makeAddr("attacker"));
        FireToken clone = new FireToken(address(new FireVesting(makeAddr("attacker"), 180 days, 540 days)));
        assertTrue(clone.transfer(airdropWallet, 20_000_000e18));
        vm.stopPrank();
        script.setRecord(_launchRecord());
        params.token = address(clone);
        vm.expectRevert(
            abi.encodeWithSelector(
                DeployAirdrop.DeployAirdropRecordMismatch.selector, "FIRE_TOKEN", address(clone), address(token)
            )
        );
        script.deploy(params, airdropWallet);

        params.token = address(token);
        params.airdropWallet = makeAddr("other-wallet");
        vm.expectRevert(
            abi.encodeWithSelector(
                DeployAirdrop.DeployAirdropRecordMismatch.selector,
                "AIRDROP_WALLET",
                params.airdropWallet,
                airdropWallet
            )
        );
        script.deploy(params, params.airdropWallet);

        // 기록의 토큰이 기록된 배포자의 CREATE(nonce + 1)이 아님 (손으로 고친 기록)
        script.setRecord(_launchRecordWith(address(clone)));
        params.token = address(clone);
        params.airdropWallet = airdropWallet;
        vm.expectRevert(
            abi.encodeWithSelector(
                DeployAirdrop.DeployAirdropRecordMismatch.selector,
                "contracts.FireToken",
                address(clone),
                address(token)
            )
        );
        script.deploy(params, airdropWallet);
        vm.removeFile(path);
        assertEq(clone.balanceOf(airdropWallet), 20_000_000e18); // 아무것도 예치되지 않음
    }

    /// @dev 테스트넷도 기록이 있으면 같은 토큰이어야 함 (오래된 .env 방지). 기록이 없으면 FIRE_TOKEN만으로 진행.
    function test_RevertWhen_TokenDiffersFromRecordOnTestnet() public {
        vm.chainId(84532);
        FireToken other = _deployFireWithAirdropWallet(makeAddr("other-deployer"), airdropWallet);
        script.setRecord(_launchRecord());
        DeployAirdrop.Params memory params = _params();
        params.token = address(other);
        vm.expectRevert(
            abi.encodeWithSelector(
                DeployAirdrop.DeployAirdropRecordMismatch.selector, "FIRE_TOKEN", address(other), address(token)
            )
        );
        script.deploy(params, airdropWallet);
        script.setRecord("");
        assertEq(address(script.deploy(params, airdropWallet).TOKEN()), address(other));
    }

    /// @dev 이름·심볼·decimals만 FIRE인 토큰(FireToken 고유 상수 없음)은 모든 체인에서 거부.
    function test_RevertWhen_TokenLacksFireConstants() public {
        vm.prank(airdropWallet);
        AirdropMockToken lookalike = new AirdropMockToken("FIRE", 18);
        DeployAirdrop.Params memory params = _params();
        params.token = address(lookalike);
        vm.expectRevert(abi.encodeWithSelector(DeployAirdrop.DeployAirdropInvalidToken.selector, address(lookalike)));
        script.deploy(params, airdropWallet);
    }

    // ───────────────────────── 입력 검증 ─────────────────────────

    function test_RevertWhen_ClaimDaysZero() public {
        DeployAirdrop.Params memory params = _params();
        params.claimDays = 0;
        vm.expectRevert(abi.encodeWithSelector(DeployAirdrop.DeployAirdropInvalidClaimDays.selector, 0));
        script.deploy(params, airdropWallet);
    }

    function test_RevertWhen_ClaimDaysAboveMax() public {
        DeployAirdrop.Params memory params = _params();
        params.claimDays = 366;
        vm.expectRevert(abi.encodeWithSelector(DeployAirdrop.DeployAirdropInvalidClaimDays.selector, 366));
        script.deploy(params, airdropWallet);
    }

    function test_RevertWhen_BroadcasterBalanceBelowTotal() public {
        address poorWallet = makeAddr("poorWallet");
        vm.prank(airdropWallet);
        require(token.transfer(poorWallet, fixtureTotal - 1), "transfer failed");

        vm.expectRevert(
            abi.encodeWithSelector(
                DeployAirdrop.DeployAirdropInsufficientBalance.selector, poorWallet, fixtureTotal - 1, fixtureTotal
            )
        );
        script.deploy(_params(), poorWallet);
    }

    function test_RevertWhen_TokenHasNoCode() public {
        DeployAirdrop.Params memory params = _params();
        params.token = makeAddr("notAToken");
        vm.expectRevert(abi.encodeWithSelector(DeployAirdrop.DeployAirdropInvalidToken.selector, params.token));
        script.deploy(params, airdropWallet);
    }

    function test_RevertWhen_TokenSymbolIsNotFire() public {
        DeployAirdrop.Params memory params = _params();
        params.token = address(new AirdropMockToken("FAKE", 18));
        vm.expectRevert(abi.encodeWithSelector(DeployAirdrop.DeployAirdropInvalidToken.selector, params.token));
        script.deploy(params, airdropWallet);
    }

    function test_RevertWhen_TokenDecimalsAreNot18() public {
        DeployAirdrop.Params memory params = _params();
        params.token = address(new AirdropMockToken("FIRE", 6));
        vm.expectRevert(abi.encodeWithSelector(DeployAirdrop.DeployAirdropInvalidToken.selector, params.token));
        script.deploy(params, airdropWallet);
    }

    function test_RevertWhen_SweepRecipientIsToken() public {
        DeployAirdrop.Params memory params = _params();
        params.sweepRecipient = address(token);
        vm.expectRevert(
            abi.encodeWithSelector(DeployAirdrop.DeployAirdropInvalidSweepRecipient.selector, address(token))
        );
        script.deploy(params, airdropWallet);
    }

    // ── 예치 사후 확인 ──

    function test_RevertWhen_TokenTakesFeeOnTransfer() public {
        vm.prank(airdropWallet);
        AirdropFeeOnTransferToken feeToken = new AirdropFeeOnTransferToken();
        DeployAirdrop.Params memory params = _params();
        params.token = address(feeToken);
        uint256 received = fixtureTotal - fixtureTotal / 100;
        vm.expectRevert(
            abi.encodeWithSelector(DeployAirdrop.DeployAirdropFundingMismatch.selector, received, fixtureTotal)
        );
        script.deploy(params, airdropWallet);
    }

    function test_RevertWhen_TokenChargesTheSenderExtra() public {
        vm.prank(airdropWallet);
        AirdropSenderFeeToken feeToken = new AirdropSenderFeeToken();
        DeployAirdrop.Params memory params = _params();
        params.token = address(feeToken);
        uint256 expected = 1e30 - fixtureTotal;
        vm.expectRevert(
            abi.encodeWithSelector(
                DeployAirdrop.DeployAirdropBroadcasterBalanceMismatch.selector, expected - 1, expected
            )
        );
        script.deploy(params, airdropWallet);
    }

    // ───────────────────────── merkle.json 헤더 검증 ─────────────────────────

    function test_ReadMerkleJson_MatchesFixture() public {
        DeployAirdrop.MerkleInfo memory info = script.readMerkleJson(AIRDROP_FIXTURE);
        assertEq(info.round, fixtureRound);
        assertEq(info.root, fixtureRoot);
        assertEq(info.total, fixtureTotal);
        assertEq(info.totalFire, "1000");
        assertEq(info.count, fixtureCount);
    }

    function test_ReadMerkleJson_RereadsFromTheStartEveryTime() public {
        bytes32 first = script.readMerkleJson(AIRDROP_FIXTURE).root;
        assertEq(script.readMerkleJson(AIRDROP_FIXTURE).root, first);
        assertEq(script.readMerkleJson(AIRDROP_FIXTURE).root, fixtureRoot);
    }

    function test_ReadMerkleJson_AcceptsCrlfLineEndings() public {
        string memory path = _tempPath("crlf");
        vm.writeFile(
            path,
            string.concat(
                "{\r\n",
                '  "round": 2,\r\n',
                '  "root": "',
                vm.toString(OTHER_ROOT),
                '",\r\n',
                '  "total": "75500000000000000000",\r\n',
                '  "totalFire": "75.5",\r\n',
                '  "count": 3,\r\n',
                '  "claims": {\r\n  }\r\n}\r\n'
            )
        );
        DeployAirdrop.MerkleInfo memory info = script.readMerkleJson(path);
        vm.removeFile(path);
        assertEq(info.round, 2);
        assertEq(info.root, OTHER_ROOT);
        assertEq(info.total, 75.5e18);
        assertEq(info.count, 3);
    }

    /**
     * @dev 회귀: 파일 전체를 읽던 이전 구현은 약 8 MB(수령자 약 7,000명)부터 가스가 부족했음.
     *      헤더만 스트리밍으로 읽으므로 12 MB 파일도 9명짜리 픽스처와 같은 가스로 읽음.
     */
    function test_ReadMerkleJson_LargeFileUsesTheSameGasAsTheFixture() public {
        string memory path = _tempPath("large");
        vm.writeFile(
            path,
            string.concat(
                "{\n",
                _headerFields(1, fixtureRoot, fixtureTotal, "1000", fixtureCount),
                '  "claims": {\n    "',
                vm.toString(fixtureAccounts[0]),
                '": {\n      "amount": "1",\n      "proof": [\n'
            )
        );
        // 증명 원소 한 줄(78바이트)을 2배씩 늘려 약 1.28 MB 덩어리를 만들고 10번 덧붙임 → 약 12.8 MB
        bytes memory chunk = bytes(string.concat('        "', vm.toString(OTHER_ROOT), '",\n'));
        for (uint256 i; i < 14; ++i) {
            chunk = bytes.concat(chunk, chunk);
        }
        for (uint256 i; i < 10; ++i) {
            vm.writeLine(path, string(chunk));
        }
        vm.writeLine(path, string.concat('        "', vm.toString(OTHER_ROOT), '"\n      ]\n    }\n  }\n}'));
        assertGt(vm.fsMetadata(path).length, 12_000_000);

        uint256 gasBefore = gasleft();
        script.readMerkleJson(AIRDROP_FIXTURE);
        uint256 fixtureGas = gasBefore - gasleft();
        gasBefore = gasleft();
        DeployAirdrop.MerkleInfo memory info = script.readMerkleJson(path);
        uint256 largeGas = gasBefore - gasleft();
        vm.removeFile(path);

        assertEq(info.root, fixtureRoot);
        assertEq(info.total, fixtureTotal);
        assertEq(info.count, fixtureCount);
        assertLt(largeGas, 1_000_000);
        assertApproxEqAbs(largeGas, fixtureGas, 10_000);
    }

    function test_RevertWhen_MerkleJsonMissing() public {
        DeployAirdrop.Params memory params = _params();
        params.merkleJsonPath = "test/fixtures/airdrop-missing.json";
        vm.expectRevert(
            abi.encodeWithSelector(DeployAirdrop.DeployAirdropMerkleJsonNotFound.selector, params.merkleJsonPath)
        );
        script.deploy(params, airdropWallet);
    }

    function test_RevertWhen_TreeDumpPassedInsteadOfMerkleJson() public {
        DeployAirdrop.Params memory params = _params();
        params.merkleJsonPath = AIRDROP_TREE_FIXTURE;
        vm.expectRevert(
            abi.encodeWithSelector(
                DeployAirdrop.DeployAirdropInvalidMerkleJson.selector, AIRDROP_TREE_FIXTURE, "layout"
            )
        );
        script.deploy(params, airdropWallet);
    }

    function test_RevertWhen_MerkleJsonReformatted() public {
        // 한 줄로 압축(재포맷)한 파일: generate.mjs 출력이 아니므로 거부
        DeployAirdrop.Params memory params = _params();
        params.merkleJsonPath = _tempPath("minified");
        vm.writeFile(
            params.merkleJsonPath,
            string.concat(
                '{"round":1,"root":"', vm.toString(fixtureRoot), '","total":"1","totalFire":"0.000000000000000001"}'
            )
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                DeployAirdrop.DeployAirdropInvalidMerkleJson.selector, params.merkleJsonPath, "layout"
            )
        );
        script.deploy(params, airdropWallet);
        vm.removeFile(params.merkleJsonPath);
    }

    function test_RevertWhen_MerkleJsonHeaderMissesClaimsLine() public {
        DeployAirdrop.Params memory params = _params();
        params.merkleJsonPath = _tempPath("no-claims");
        vm.writeFile(
            params.merkleJsonPath,
            string.concat("{\n", _headerFields(1, fixtureRoot, fixtureTotal, "1000", 9), '  "claims": {}\n}\n')
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                DeployAirdrop.DeployAirdropInvalidMerkleJson.selector, params.merkleJsonPath, "layout"
            )
        );
        script.deploy(params, airdropWallet);
        vm.removeFile(params.merkleJsonPath);
    }

    function test_RevertWhen_MerkleJsonHeaderKeysChanged() public {
        string memory renamed = string.concat(
            '  "rounds": 1,\n  "root": "',
            vm.toString(fixtureRoot),
            '",\n  "total": "1000000000000000000000",\n  "totalFire": "1000",\n  "count": 9,\n'
        );
        _expectInvalidMerkleJson("renamed-key", renamed, "header");
        string memory duplicated = string.concat(
            '  "round": 1,\n  "root": "',
            vm.toString(fixtureRoot),
            '",\n  "round": 2,\n  "totalFire": "1000",\n  "count": 9,\n'
        );
        _expectInvalidMerkleJson("duplicate-key", duplicated, "header");
    }

    function test_RevertWhen_MerkleJsonHeaderIsNotJson() public {
        string memory broken = string.concat(
            '  "round": one,\n  "root": "',
            vm.toString(fixtureRoot),
            '",\n  "total": "1000000000000000000000",\n  "totalFire": "1000",\n  "count": 9,\n'
        );
        _expectInvalidMerkleJson("not-json", broken, "header");
    }

    function test_RevertWhen_MerkleJsonRoundIsZero() public {
        _expectInvalidMerkleJson("round-zero", _headerFields(0, fixtureRoot, fixtureTotal, "1000", 9), "round");
    }

    function test_RevertWhen_MerkleJsonRootIsZero() public {
        _expectInvalidMerkleJson("root-zero", _headerFields(1, bytes32(0), fixtureTotal, "1000", 9), "root");
    }

    function test_RevertWhen_MerkleJsonTotalIsZero() public {
        _expectInvalidMerkleJson("total-zero", _headerFields(1, fixtureRoot, 0, "0", 9), "total");
    }

    function test_RevertWhen_MerkleJsonTotalAboveSupply() public {
        _expectInvalidMerkleJson(
            "total-supply",
            _headerFields(1, fixtureRoot, 1_000_000_000e18 + 1, "1000000000.000000000000000001", 9),
            "total"
        );
    }

    /// @dev 회귀: total(wei)만 고친 헤더(예: 970 FIRE, totalFire는 1000)를 거부
    function test_RevertWhen_MerkleJsonTotalDisagreesWithTotalFire() public {
        _expectInvalidMerkleJson("total-fire", _headerFields(1, fixtureRoot, 970e18, "1000", 9), "totalFire");
    }

    function test_RevertWhen_MerkleJsonCountIsZero() public {
        _expectInvalidMerkleJson("count-zero", _headerFields(1, fixtureRoot, fixtureTotal, "1000", 0), "count");
    }

    // ───────────────────────── 환경 변수·run() ─────────────────────────

    function test_Run_ReadsEnvironmentAndDeploysFromScriptSender() public {
        AirdropEnvHarness envScript = new AirdropEnvHarness();
        envScript.setFakeEnv("FIRE_TOKEN", vm.toString(address(token)));
        envScript.setFakeEnv("AIRDROP_MERKLE_JSON", AIRDROP_FIXTURE);
        envScript.setFakeEnv("AIRDROP_CLAIM_DAYS", "30");
        envScript.setFakeEnv("AIRDROP_WALLET", vm.toString(DEFAULT_SENDER));
        vm.prank(airdropWallet);
        require(token.transfer(DEFAULT_SENDER, fixtureTotal), "transfer failed");

        uint64 nonce = vm.getNonce(DEFAULT_SENDER);

        FireMerkleDistributor distributor = envScript.run();
        assertEq(address(distributor), vm.computeCreateAddress(DEFAULT_SENDER, nonce));
        assertEq(distributor.CLAIM_DEADLINE(), block.timestamp + 30 days);
        assertEq(distributor.SWEEP_RECIPIENT(), DEFAULT_SENDER);
        assertEq(token.balanceOf(address(distributor)), fixtureTotal);
    }

    function test_ParamsFromEnv_ParsesEveryVariable() public {
        AirdropEnvHarness envScript = new AirdropEnvHarness();
        address safe = makeAddr("airdropSafe");
        envScript.setFakeEnv("FIRE_TOKEN", vm.toString(address(token)));
        envScript.setFakeEnv("AIRDROP_MERKLE_JSON", AIRDROP_FIXTURE);
        envScript.setFakeEnv("AIRDROP_CLAIM_DAYS", "45");
        envScript.setFakeEnv("AIRDROP_SWEEP_RECIPIENT", vm.toString(safe));
        envScript.setFakeEnv("AIRDROP_WALLET", vm.toString(airdropWallet));
        envScript.setFakeEnv("AIRDROP_EXPECTED_ROOT", vm.toString(fixtureRoot));
        envScript.setFakeEnv("CONFIRM_MAINNET", "I_UNDERSTAND");

        DeployAirdrop.Params memory params = envScript.paramsFromEnv();
        assertEq(params.token, address(token));
        assertEq(params.merkleJsonPath, AIRDROP_FIXTURE);
        assertEq(params.claimDays, 45);
        assertEq(params.sweepRecipient, safe);
        assertEq(params.airdropWallet, airdropWallet);
        assertEq(params.expectedRoot, fixtureRoot);
        assertEq(params.confirmMainnet, "I_UNDERSTAND");
    }

    function test_ParamsFromEnv_DefaultsForOptionalVariables() public {
        AirdropEnvHarness envScript = new AirdropEnvHarness();
        envScript.setFakeEnv("FIRE_TOKEN", vm.toString(address(token)));
        envScript.setFakeEnv("AIRDROP_MERKLE_JSON", AIRDROP_FIXTURE);
        envScript.setFakeEnv("AIRDROP_WALLET", ""); // .env.example의 `AIRDROP_WALLET=`처럼 빈 값 = 미설정

        DeployAirdrop.Params memory params = envScript.paramsFromEnv();
        assertEq(params.claimDays, 90);
        assertEq(params.sweepRecipient, address(0));
        assertEq(params.airdropWallet, address(0));
        assertEq(params.expectedRoot, bytes32(0));
        assertEq(params.confirmMainnet, "");
    }

    /// @dev FIRE_TOKEN이 비어 있으면 기록의 contracts.FireToken, 둘 다 있는데 다르면 모든 체인에서 중단.
    function test_ParamsFromEnv_TokenFromLaunchRecord() public {
        AirdropEnvHarness envScript = _envScript();
        envScript.setFakeEnv("FIRE_TOKEN", "");
        envScript.setRecord(_launchRecord());
        assertEq(envScript.paramsFromEnv().token, address(token));
        address other = makeAddr("other-token");
        envScript.setFakeEnv("FIRE_TOKEN", vm.toString(other));
        vm.expectRevert(
            abi.encodeWithSelector(
                DeployAirdrop.DeployAirdropRecordMismatch.selector, "FIRE_TOKEN", other, address(token)
            )
        );
        envScript.paramsFromEnv();
    }

    function test_RevertWhen_RequiredEnvironmentVariableMissing() public {
        AirdropEnvHarness envScript = new AirdropEnvHarness();
        vm.expectRevert(abi.encodeWithSelector(DeployAirdrop.DeployAirdropMissingEnv.selector, "FIRE_TOKEN"));
        envScript.paramsFromEnv();

        envScript.setFakeEnv("FIRE_TOKEN", vm.toString(address(token)));
        vm.expectRevert(abi.encodeWithSelector(DeployAirdrop.DeployAirdropMissingEnv.selector, "AIRDROP_MERKLE_JSON"));
        envScript.paramsFromEnv();
    }

    function test_EnvString_ReadsTheProcessEnvironment() public {
        // 이 테스트 전용 이름이라 다른 테스트와 경합하지 않음
        vm.setEnv("FIRE_AIRDROP_TEST_ONLY_ENV_PROBE", "probe-value");
        assertEq(script.exposedEnvString("FIRE_AIRDROP_TEST_ONLY_ENV_PROBE"), "probe-value");
        assertEq(script.exposedEnvString("FIRE_AIRDROP_TEST_ONLY_ENV_UNSET"), "");
    }

    // ───────────────────────── RPC 체인 ID 대조 (LaunchGuards 공유) ─────────────────────────

    /// @dev --rpc-url base --chain base-sepolia: 스크립트는 84532로 보고 메인넷 가드를 건너뛰지만 전송은 8453 → 중단.
    function test_RevertWhen_ChainFlagSpoofsTestnetOnMainnetRpc() public {
        AirdropEnvHarness envScript = _envScript();
        vm.chainId(84532);
        envScript.setRpcChainId(true, 8453);
        bytes memory mismatch = abi.encodeWithSelector(LaunchGuards.LaunchChainIdMismatch.selector, 84532, 8453);
        vm.expectRevert(mismatch);
        envScript.run();
        vm.expectRevert(mismatch);
        envScript.deploy(_params(), airdropWallet);
        assertEq(vm.getNonce(airdropWallet), 0);
    }

    function test_ChainCheck_MatchingRpcProceeds() public {
        AirdropEnvHarness envScript = _envScript();
        vm.chainId(84532);
        envScript.setRpcChainId(true, 84532);
        FireMerkleDistributor distributor = envScript.deploy(_params(), airdropWallet);
        assertEq(token.balanceOf(address(distributor)), fixtureTotal);
    }

    /// @dev RPC가 없는 로컬 드라이런은 전송이 없으므로 진행, --broadcast인데 RPC를 조회할 수 없으면 중단.
    function test_ChainCheck_NoRpc_DryRunProceedsBroadcastReverts() public {
        AirdropEnvHarness envScript = _envScript();
        envScript.setRpcChainId(false, 0);
        envScript.setBroadcastContext(true);
        vm.expectRevert(LaunchGuards.LaunchRpcUnavailable.selector);
        envScript.deploy(_params(), airdropWallet);
        envScript.setBroadcastContext(false);
        envScript.deploy(_params(), airdropWallet);
    }

    // ───────────────────────── EIP-55 주소 파싱 (LaunchGuards 공유) ─────────────────────────

    /// @dev 체크섬 대소문자 한 글자 오타는 모든 체인에서 거부 (vm.parseAddress는 다른 주소로 받아들임).
    function test_RevertWhen_EnvAddressHasChecksumTypo() public {
        string[3] memory names = ["FIRE_TOKEN", "AIRDROP_WALLET", "AIRDROP_SWEEP_RECIPIENT"];
        address[3] memory values = [address(token), airdropWallet, makeAddr("airdropSafe")];
        for (uint256 i; i < names.length; ++i) {
            AirdropEnvHarness envScript = _envScript();
            string memory typo = _checksumTypo(values[i]);
            assertEq(vm.parseAddress(typo), values[i]); // forge 자체는 그대로 통과시킴
            envScript.setFakeEnv(names[i], typo);
            vm.expectRevert(abi.encodeWithSelector(LaunchGuards.LaunchBadChecksum.selector, names[i]));
            envScript.paramsFromEnv();
            vm.chainId(84532);
            vm.expectRevert(abi.encodeWithSelector(LaunchGuards.LaunchBadChecksum.selector, names[i]));
            envScript.paramsFromEnv();
            vm.chainId(31337);
        }
    }

    /// @dev 전부 소문자인 주소(체크섬 정보 없음): 테스트넷·로컬은 허용, Base 메인넷은 거부.
    function test_Env_LowercaseAddressesOnlyOffMainnet() public {
        AirdropEnvHarness envScript = _envScript();
        envScript.setFakeEnv("FIRE_TOKEN", vm.toLowercase(vm.toString(address(token))));
        envScript.setFakeEnv("AIRDROP_WALLET", vm.toLowercase(vm.toString(airdropWallet)));
        vm.chainId(84532);
        DeployAirdrop.Params memory params = envScript.paramsFromEnv();
        assertEq(params.token, address(token));
        assertEq(params.airdropWallet, airdropWallet);

        vm.chainId(8453);
        vm.expectRevert(abi.encodeWithSelector(LaunchGuards.LaunchChecksumRequired.selector, "FIRE_TOKEN"));
        envScript.paramsFromEnv();
        envScript.setFakeEnv("FIRE_TOKEN", vm.toString(address(token)));
        vm.expectRevert(abi.encodeWithSelector(LaunchGuards.LaunchChecksumRequired.selector, "AIRDROP_WALLET"));
        envScript.paramsFromEnv();
        envScript.setFakeEnv("AIRDROP_WALLET", vm.toString(airdropWallet));
        assertEq(envScript.paramsFromEnv().airdropWallet, airdropWallet);
    }

    function test_RevertWhen_EnvAddressMalformed() public {
        AirdropEnvHarness envScript = _envScript();
        string[4] memory malformed = [
            "not-an-address",
            string.concat(" ", vm.toString(address(token))),
            vm.replace(vm.toString(address(token)), "0x", ""),
            string.concat(vm.toString(address(token)), "0")
        ];
        for (uint256 i; i < malformed.length; ++i) {
            envScript.setFakeEnv("FIRE_TOKEN", malformed[i]);
            vm.expectRevert(abi.encodeWithSelector(LaunchGuards.LaunchInvalidAddress.selector, "FIRE_TOKEN"));
            envScript.paramsFromEnv();
        }
    }

    /// @dev 필수 환경 변수만 채운 하네스 (EIP-55 표기).
    function _envScript() internal returns (AirdropEnvHarness envScript) {
        envScript = new AirdropEnvHarness();
        envScript.setFakeEnv("FIRE_TOKEN", vm.toString(address(token)));
        envScript.setFakeEnv("AIRDROP_MERKLE_JSON", AIRDROP_FIXTURE);
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

    // ───────────────────────── 보조 함수 ─────────────────────────

    function test_Broadcaster_IsScriptSender() public {
        // forge script에서는 --sender/서명 지갑, forge test에서는 기본 발신자
        assertEq(script.exposedBroadcaster(), DEFAULT_SENDER);
    }

    function test_FormatFire() public view {
        assertEq(script.exposedFormatFire(1000e18), "1000");
        assertEq(script.exposedFormatFire(75.5e18), "75.5");
        assertEq(script.exposedFormatFire(49_999999999999999999), "49.999999999999999999");
        assertEq(script.exposedFormatFire(1), "0.000000000000000001");
        assertEq(script.exposedFormatFire(0), "0");
    }
}
