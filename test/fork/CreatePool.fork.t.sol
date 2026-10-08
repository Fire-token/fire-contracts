// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Vm, VmSafe} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {FireToken} from "../../src/FireToken.sol";
import {FireVesting} from "../../src/FireVesting.sol";
import {Deploy} from "../../script/Deploy.s.sol";
import {CreatePool} from "../../script/CreatePool.s.sol";
import {PostDeployCheck} from "../../script/PostDeployCheck.s.sol";
import {LaunchBase} from "../../script/lib/LaunchBase.sol";
import {LaunchCode} from "../../script/lib/LaunchCode.sol";
import {LaunchParams} from "../../script/lib/LaunchParams.sol";
import {LaunchPositions} from "../../script/lib/LaunchPositions.sol";
import {PoolMath} from "../../script/lib/PoolMath.sol";
import {UniswapV3Addresses} from "../../script/lib/UniswapV3Addresses.sol";
import {
    INonfungiblePositionManager,
    ISwapRouter02,
    IUniswapV3Factory,
    IUniswapV3Pool,
    IUniswapV3SwapCallback,
    IWETH9
} from "../../script/lib/IUniswapV3.sol";

// ───────────────────────── 테스트 보조 컨트랙트 (Deploy 접두사) ─────────────────────────

/// @dev Base에 배포된 Safe v1.4.1 SafeProxyFactory (실제 Safe 프록시로 Deploy의 Safe 판별을 검증).
interface IDeployForkSafeProxyFactory {
    function createProxyWithNonce(address singleton, bytes memory initializer, uint256 saltNonce)
        external
        returns (address proxy);
    function proxyCreationCode() external view returns (bytes memory);
}

contract DeployForkSafe {
    function getThreshold() external pure returns (uint256) {
        return 2;
    }

    function getOwners() external pure returns (address[] memory owners) {
        owners = new address[](3);
        owners[0] = address(0x5AFE01);
        owners[1] = address(0x5AFE02);
        owners[2] = address(0x5AFE03);
    }

    function getModulesPaginated(address, uint256) external pure returns (address[] memory, address) {
        return (new address[](0), address(0x1));
    }
}

/// @dev Safe v1.4.1 ModuleManager (모듈 활성화: Safe 자신의 트랜잭션으로만 호출 가능 → vm.prank(safe)로 흉내).
interface IDeployForkSafeModules {
    function enableModule(address module) external;
    function execTransactionFromModule(address to, uint256 value, bytes calldata data, uint8 operation)
        external
        returns (bool success);
}

/// @dev ERC-721 승인 (UNCX 락커에 LP NFT를 맡기기 전 NPM.approve).
interface IDeployForkErc721 {
    function approve(address to, uint256 tokenId) external;
}

/// @dev UNCX Liquidity Locker V3.1 (Base 0x231278eD…BCC1) lock(LockParams). 온체인 바이트코드의 셀렉터 0xa35a96b8로 확인.
interface IDeployForkUncxLocker {
    struct LockParams {
        address nftPositionManager;
        uint256 nftId;
        address dustRecipient;
        address owner;
        address additionalCollector;
        address collectAddress;
        uint256 unlockDate;
        uint16 countryCode;
        string feeName;
        bytes[] r;
    }

    function lock(LockParams calldata params) external payable returns (uint256 lockId);
}

/// @dev 주소 오염용 가짜 FIRE: 이름·심볼·decimals·permit은 진짜와 같고 totalSupply()는 10억이라고 꾸밈(고유 상수 없음).
contract DeployForkPoisonFire is ERC20, ERC20Permit {
    constructor(address victim) ERC20("Fire", "FIRE") ERC20Permit("Fire") {
        _mint(victim, 700_000_000e18);
    }

    function totalSupply() public pure override returns (uint256) {
        return 1_000_000_000e18;
    }
}

/// @dev 락커 대역: LP NFT를 보관하기만 하는 컨트랙트.
contract DeployForkLocker {}

/// @dev pool.swap을 직접 호출하는 최소 콜백 컨트랙트 (라우터를 거치지 않는 저수준 경로 검증).
contract DeployForkSwapper is IUniswapV3SwapCallback {
    using SafeERC20 for IERC20;

    address private _activePool;

    function swapExactInput(IUniswapV3Pool pool, address tokenIn, uint256 amountIn, address recipient)
        external
        returns (uint256 amountOut)
    {
        bool zeroForOne = tokenIn == pool.token0();
        _activePool = address(pool);
        (int256 amount0, int256 amount1) = pool.swap(
            recipient,
            zeroForOne,
            int256(amountIn),
            zeroForOne ? PoolMath.MIN_SQRT_RATIO + 1 : PoolMath.MAX_SQRT_RATIO - 1,
            abi.encode(tokenIn)
        );
        _activePool = address(0);
        amountOut = uint256(-(zeroForOne ? amount1 : amount0));
    }

    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external {
        require(msg.sender == _activePool, "DeployForkSwapper: unexpected caller");
        address tokenIn = abi.decode(data, (address));
        uint256 owed = uint256(amount0Delta > 0 ? amount0Delta : amount1Delta);
        IERC20(tokenIn).safeTransfer(msg.sender, owed);
    }
}

/// @dev 환경 변수를 무시하고 기록 파일만 읽는 PostDeployCheck (사용자 .env가 테스트에 섞이지 않게).
contract DeployForkCheckHarness is PostDeployCheck {
    function _envString(string memory) internal pure override returns (string memory) {
        return "";
    }
}

/**
 * @dev 포크 테스트용 CreatePool: 환경 변수·기록 경로·permit 파일 경로를 주입하고, confirm()이 찾는 이벤트를 넣어 줌.
 *      포크 테스트에서 로컬로 실행한 트랜잭션의 이벤트는 원격 RPC(eth_getLogs)에 없으므로 vm.recordLogs로 잡아 전달함.
 *      실제 eth_getLogs 경로는 realFindMintLog로 Base의 실제 이벤트에 대해 따로 검증함.
 */
contract DeployForkPoolHarness is CreatePool {
    mapping(string => string) private _env;
    string private _recordPath;
    string private _permitFile;
    bool private _mintSet;
    bytes private _mintData;
    bytes32 private _mintTx;
    uint64 private _mintBlock;
    bool private _initSet;
    bytes private _initData;

    function setFakeEnv(string calldata name, string calldata value) external {
        _env[name] = value;
    }

    function setPaths(string calldata recordPath, string calldata permitFile) external {
        _recordPath = recordPath;
        _permitFile = permitFile;
    }

    function setMintLog(bytes calldata data, bytes32 txHash, uint64 blockNumber) external {
        _mintSet = true;
        _mintData = data;
        _mintTx = txHash;
        _mintBlock = blockNumber;
    }

    function setInitializeLog(bytes calldata data) external {
        _initSet = true;
        _initData = data;
    }

    function clearLogs() external {
        _mintSet = false;
        _initSet = false;
    }

    function realFindMintLog(address npm, uint256 tokenId, uint256 fromBlock)
        external
        view
        returns (bool, VmSafe.EthGetLogs memory)
    {
        return super._findMintLog(npm, tokenId, fromBlock);
    }

    function realRpcChainId() external returns (bool, uint256) {
        return _rpcChainId();
    }

    function _envString(string memory name) internal view override returns (string memory) {
        return _env[name];
    }

    function deploymentPath(uint256 chainId) public view override returns (string memory) {
        return bytes(_recordPath).length == 0 ? super.deploymentPath(chainId) : _recordPath;
    }

    function permitPath(uint256 chainId) public view override returns (string memory) {
        return bytes(_permitFile).length == 0 ? super.permitPath(chainId) : _permitFile;
    }

    function _findMintLog(address, uint256, uint256)
        internal
        view
        override
        returns (bool found, VmSafe.EthGetLogs memory log)
    {
        if (!_mintSet) return (false, log);
        log.data = _mintData;
        log.transactionHash = _mintTx;
        log.blockNumber = _mintBlock;
        found = true;
    }

    function _findInitializeLog(address, uint256)
        internal
        view
        override
        returns (bool found, VmSafe.EthGetLogs memory log)
    {
        if (!_initSet) return (false, log);
        log.data = _initData;
        found = true;
    }
}

/**
 * @title CreatePool 포크 테스트 (Base 메인넷)
 * @dev BASE_RPC_URL이 비어 있으면 모든 테스트를 건너뜀(CI 기본). 실행 예:
 *      BASE_RPC_URL=https://mainnet.base.org forge test --match-path test/fork/CreatePool.fork.t.sol
 *      포크 블록은 기본으로 고정(재현성 + foundry RPC 캐시). BASE_FORK_BLOCK으로 바꿀 수 있고 0이면 최신 블록.
 */
contract CreatePoolForkTest is Test {
    uint256 internal constant DEFAULT_FORK_BLOCK = 52_317_000;

    address internal constant WETH = UniswapV3Addresses.WETH;
    address internal constant FACTORY = UniswapV3Addresses.BASE_FACTORY;
    address internal constant NPM = UniswapV3Addresses.BASE_POSITION_MANAGER;
    address internal constant ROUTER = UniswapV3Addresses.BASE_SWAP_ROUTER02;
    /// @dev Base 네이티브 USDC (FIRE가 아닌 ERC20 거부 확인용).
    address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

    uint256 internal constant SEED_ETH = 3 ether;
    uint256 internal constant LP_FIRE = 700_000_000e18;

    // Python 독립 계산값 (isqrt, Decimal 100자리 로그): 3 ETH + 7억 FIRE
    uint160 internal constant SQRT_WETH_TOKEN0 = 1_210_230_172_979_597_097_089_260_854_307_451;
    int24 internal constant TICK_WETH_TOKEN0 = 192_689;
    uint160 internal constant SQRT_FIRE_TOKEN0 = 5_186_700_741_341_130_416_096_832;
    int24 internal constant TICK_FIRE_TOKEN0 = -192_690;

    bool internal forked;
    Deploy internal deployScript;
    CreatePool internal poolScript;
    PostDeployCheck internal checker;
    DeployForkPoolHarness internal harness;
    DeployForkCheckHarness internal checkHarness;
    INonfungiblePositionManager internal npm = INonfungiblePositionManager(NPM);

    /// @dev 수익자·에어드롭 지갑은 소유 증명 서명을 위해 테스트 전용 키를 가짐 (makeAddr와 같은 주소).
    address internal beneficiary;
    uint256 internal beneficiaryKey;
    address internal airdrop;
    uint256 internal airdropKey;
    address internal treasury;

    function setUp() public {
        (beneficiary, beneficiaryKey) = makeAddrAndKey("fork-beneficiary");
        (airdrop, airdropKey) = makeAddrAndKey("fork-airdrop");
        string memory rpc = vm.envOr("BASE_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return;
        string memory blockEnv = vm.envOr("BASE_FORK_BLOCK", string(""));
        uint256 forkBlock = bytes(blockEnv).length == 0 ? DEFAULT_FORK_BLOCK : vm.parseUint(blockEnv);
        if (forkBlock == 0) vm.createSelectFork(rpc);
        else vm.createSelectFork(rpc, forkBlock);
        forked = true;
        deployScript = new Deploy();
        poolScript = new CreatePool();
        checker = new PostDeployCheck();
        harness = new DeployForkPoolHarness();
        checkHarness = new DeployForkCheckHarness();
        treasury = address(new DeployForkSafe());
    }

    modifier onlyFork() {
        if (!forked) vm.skip(true);
        _;
    }

    // ───────────────────────── 헬퍼 ─────────────────────────

    /// @dev 테스트가 만든 ./deployments/test-deploy-*.json 임시 파일만 읽고 지움 (fs_permissions 범위).
    function _readFile(string memory path) internal view returns (string memory) {
        // forge-lint: disable-next-line(unsafe-cheatcode)
        return vm.readFile(path);
    }

    function _removeFile(string memory path) internal {
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.removeFile(path);
    }

    function _tmpPath(string memory tag) internal pure returns (string memory) {
        return string.concat("deployments/test-deploy-fork-", tag, ".json");
    }

    /// @dev 원하는 토큰 순서가 나오는 새(nonce 0) 배포자를 고름 (토큰 주소 = CREATE(배포자, nonce + 1)).
    function _deployerFrom(bool fireIsToken0, uint256 start) internal returns (address deployer) {
        for (uint256 i = start;; ++i) {
            deployer = makeAddr(string.concat("fork-deployer-", vm.toString(i)));
            if (deployer.code.length != 0 || vm.getNonce(deployer) != 0) continue;
            address token = vm.computeCreateAddress(deployer, 1);
            if ((token < WETH) == fireIsToken0) return deployer;
        }
    }

    function _deployerFor(bool fireIsToken0) internal returns (address) {
        return _deployerFrom(fireIsToken0, 0);
    }

    /// @dev 개인 키를 아는 배포자 (permit 서명 경로용). 키는 테스트 전용으로 makeAddrAndKey가 만든 값.
    function _keyedDeployerFor(bool fireIsToken0) internal returns (address deployer, uint256 key) {
        for (uint256 i;; ++i) {
            (deployer, key) = makeAddrAndKey(string.concat("fork-keyed-deployer-", vm.toString(i)));
            if (deployer.code.length != 0 || vm.getNonce(deployer) != 0) continue;
            address token = vm.computeCreateAddress(deployer, 1);
            if ((token < WETH) == fireIsToken0) return (deployer, key);
        }
    }

    function _launchWith(address deployer) internal returns (Deploy.DeployResult memory d) {
        vm.deal(deployer, 10 ether);
        d = deployScript.deploy(_launchCfg(), deployer);
        assertEq(d.chainId, 8453);
    }

    /// @dev 메인넷 포크(8453) 런칭 설정: 2-of-3 Safe 트레저리 + 수익자·에어드롭 지갑의 소유 증명(personal_sign).
    function _launchCfg() internal view returns (Deploy.DeployConfig memory cfg) {
        cfg.beneficiary = beneficiary;
        cfg.treasurySafe = treasury;
        cfg.airdropWallet = airdrop;
        cfg.mainnetConfirmed = true;
        cfg.beneficiaryProof = _controlProof(beneficiaryKey, "BENEFICIARY", beneficiary);
        cfg.airdropWalletProof = _controlProof(airdropKey, "AIRDROP_WALLET", airdrop);
    }

    /// @dev cast wallet sign과 같은 형식(r ‖ s ‖ v)의 소유 증명 서명. 메시지는 스크립트와 독립적으로 구성.
    function _controlProof(uint256 key, string memory role, address account) internal view returns (bytes memory) {
        string memory text = string.concat(
            "FIRE launch control proof | role=",
            role,
            " | address=",
            vm.toString(account),
            " | chainId=",
            vm.toString(block.chainid)
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, MessageHashUtils.toEthSignedMessageHash(bytes(text)));
        return abi.encodePacked(r, s, v);
    }

    function _launch(bool fireIsToken0) internal returns (Deploy.DeployResult memory d) {
        d = _launchWith(_deployerFor(fireIsToken0));
        assertEq(d.token < WETH, fireIsToken0);
    }

    function _cfg(address token, uint24 fee) internal pure returns (CreatePool.PoolConfig memory) {
        return CreatePool.PoolConfig({
            fireToken: token,
            seedEth: SEED_ETH,
            lpFireAmount: LP_FIRE,
            feeTier: fee,
            slippageBps: 50,
            mainnetConfirmed: true,
            permitSignature: "",
            permitDeadline: 0
        });
    }

    function _absDiff(int24 a, int24 b) internal pure returns (uint256) {
        return a > b ? uint256(int256(a) - b) : uint256(int256(b) - a);
    }

    function _targetSqrt(address token) internal pure returns (uint160) {
        return token < WETH ? SQRT_FIRE_TOKEN0 : SQRT_WETH_TOKEN0;
    }

    /// @dev 제3자가 1% 등급 풀을 먼저 만들고 주어진 가격으로 초기화.
    function _frontRunInitialize(address token, uint160 sqrtPriceX96) internal returns (address pool) {
        vm.startPrank(makeAddr("front-runner"));
        pool = IUniswapV3Factory(FACTORY).createPool(token, WETH, 10_000);
        IUniswapV3Pool(pool).initialize(sqrtPriceX96);
        vm.stopPrank();
    }

    /**
     * @dev forge script의 실행 모델 재현: 먼저 시뮬레이션해 트랜잭션을 만들고(이 상태 변화는 버림), 나중에 그
     *      트랜잭션을 그대로 전송함(_replay). 그 사이에 다른 사람의 트랜잭션이 끼어들 수 있음.
     */
    function _simulate(CreatePool.PoolConfig memory cfg, address deployer)
        internal
        returns (CreatePool.PoolPlan memory plan, CreatePool.PoolResult memory sim, string memory pending)
    {
        uint256 snapshot = vm.snapshotState();
        (plan, sim) = harness.createPool(cfg, deployer);
        pending = harness.pendingPoolJson(plan, sim);
        assertTrue(vm.revertToState(snapshot));
    }

    /// @dev 시뮬레이션이 만든 트랜잭션을 그대로 전송 (계획을 다시 세우지 않음). multicall이 실패하면 forge는 멈추므로
    ///      approve(0)도 보내지 않음.
    function _replay(CreatePool.PoolPlan memory plan) internal returns (bool ok) {
        bytes[] memory calls = harness.multicallData(plan);
        vm.startPrank(plan.broadcaster);
        if (!plan.usePermit) assertTrue(IERC20(plan.fireToken).approve(NPM, plan.lpFireAmount));
        (ok,) = NPM.call{value: plan.seedEth}(abi.encodeCall(INonfungiblePositionManager.multicall, (calls)));
        if (ok) assertTrue(IERC20(plan.fireToken).approve(NPM, 0));
        vm.stopPrank();
    }

    /// @dev vm.recordLogs로 잡은 mint/Initialize 이벤트를 하네스의 confirm()에 전달.
    function _injectLogs(Vm.Log[] memory entries, address pool) internal {
        for (uint256 i; i < entries.length; ++i) {
            Vm.Log memory e = entries[i];
            if (e.topics.length == 0) continue;
            if (e.emitter == NPM && e.topics[0] == harness.INCREASE_LIQUIDITY_TOPIC()) {
                harness.setMintLog(e.data, keccak256("fork-mint-tx"), uint64(block.number));
            } else if (e.emitter == pool && e.topics[0] == harness.INITIALIZE_TOPIC()) {
                harness.setInitializeLog(e.data);
            }
        }
    }

    /// @dev Deploy 기록(pending) + CreatePool 기록(pending)을 임시 파일에 씀.
    function _writePendingRecord(Deploy.DeployResult memory d, string memory pending, string memory path) internal {
        vm.writeJson(deployScript.recordJson(d), path);
        harness.writePoolRecord(pending, d.token, path);
    }

    struct Created {
        Deploy.DeployResult d;
        CreatePool.PoolPlan plan;
        CreatePool.PoolResult res;
    }

    /// @dev 배포 → 풀 생성 → 과제 요구 사항 전부 검증.
    function _createAndAssert(bool fireIsToken0, uint24 fee) internal returns (Created memory c) {
        c.d = _launch(fireIsToken0);
        FireToken token = FireToken(c.d.token);
        uint256 ethBefore = c.d.deployer.balance;
        (c.plan, c.res) = poolScript.createPool(_cfg(c.d.token, fee), c.d.deployer);

        // 풀 주소·키
        assertEq(IUniswapV3Factory(FACTORY).getPool(c.d.token, WETH, fee), c.res.pool);
        IUniswapV3Pool pool = IUniswapV3Pool(c.res.pool);
        assertEq(pool.fee(), fee);
        assertEq(c.plan.fireIsToken0, fireIsToken0);

        // 가격: 목표 sqrtPriceX96과 정확히 일치, 틱은 독립 계산값과 1틱 이내
        (uint160 sqrtPrice, int24 tick,,,,,) = pool.slot0();
        assertEq(sqrtPrice, fireIsToken0 ? SQRT_FIRE_TOKEN0 : SQRT_WETH_TOKEN0);
        assertLe(_absDiff(tick, fireIsToken0 ? TICK_FIRE_TOKEN0 : TICK_WETH_TOKEN0), 1);

        // 포지션: 전체 범위, 유동성 > 0, 소유자 = 배포자, 풀의 유일한 활성 유동성
        (bool exists, LaunchPositions.Position memory p) = LaunchPositions.read(npm, c.res.tokenId);
        assertTrue(exists);
        int24 spacing = fee == 10_000 ? int24(200) : int24(60);
        assertEq(p.tickLower, (PoolMath.MIN_TICK / spacing) * spacing);
        assertEq(p.tickUpper, -p.tickLower);
        assertGt(p.liquidity, 0);
        assertEq(p.liquidity, c.res.liquidity);
        assertEq(pool.liquidity(), p.liquidity);
        assertEq(npm.ownerOf(c.res.tokenId), c.d.deployer);

        // 투입 수량의 99.9% 이상 사용
        assertGe(c.res.fireUsed * 1000, LP_FIRE * 999);
        assertGe(c.res.ethUsed * 1000, SEED_ETH * 999);
        assertEq(token.balanceOf(c.res.pool), c.res.fireUsed);
        assertEq(IERC20(WETH).balanceOf(c.res.pool), c.res.ethUsed);
        assertEq(token.balanceOf(c.d.deployer), LP_FIRE - c.res.fireUsed);

        // 남은 ETH는 같은 트랜잭션에서 환불, NPM에 ETH 잔액 없음, 승인 잔량 0
        assertEq(c.res.ethRefunded, SEED_ETH - c.res.ethUsed);
        assertEq(c.d.deployer.balance, ethBefore - c.res.ethUsed);
        assertEq(NPM.balance, 0);
        assertEq(token.allowance(c.d.deployer, NPM), 0);

        // EIP-7825 가스 상한
        assertLt(c.res.multicallGas, LaunchParams.TX_GAS_CAP);
        emit log_named_uint("multicall gas (pool create + init + mint + refund)", c.res.multicallGas);
    }

    function _checkInputs(Created memory c) internal view returns (PostDeployCheck.CheckInputs memory inputs) {
        inputs.token = c.d.token;
        inputs.vesting = c.d.vesting;
        inputs.deployer = c.d.deployer;
        inputs.beneficiary = beneficiary;
        inputs.treasurySafe = treasury;
        inputs.airdropWallet = airdrop;
        inputs.recordedVestingStart = c.d.vestingStart;
        inputs.hasPool = true;
        inputs.pool = c.res.pool;
        inputs.positionManager = NPM;
        inputs.tokenId = c.res.tokenId;
        inputs.recordedLiquidity = c.res.liquidity;
        inputs.fee = c.plan.fee;
        inputs.initialSqrtPriceX96 = c.res.sqrtPriceX96;
    }

    // ───────────────────────── 주소표·인터페이스 검증 ─────────────────────────

    function test_Fork_AddressTableAndInterfacesMatchChain() public onlyFork {
        assertEq(block.chainid, 8453);
        assertEq(npm.factory(), FACTORY);
        assertEq(npm.WETH9(), WETH);
        assertEq(IUniswapV3Factory(FACTORY).feeAmountTickSpacing(10_000), 200);
        assertEq(IUniswapV3Factory(FACTORY).feeAmountTickSpacing(3000), 60);
        assertEq(ISwapRouter02(ROUTER).factory(), FACTORY);
        assertEq(ISwapRouter02(ROUTER).WETH9(), WETH);
        assertEq(ISwapRouter02(ROUTER).positionManager(), NPM);
    }

    /// @dev 실제 vm.rpc 경로: 포크 RPC의 eth_chainId가 8453으로 해석됨 (--chain 위장 탐지의 기준값).
    function test_Fork_RpcChainIdMatchesFork() public onlyFork {
        (bool ok, uint256 chainId) = harness.realRpcChainId();
        assertTrue(ok);
        assertEq(chainId, 8453);
    }

    // ───────────────────────── 정상 경로 ─────────────────────────

    function test_Fork_CreatePool_Fee1Percent_WethIsToken0() public onlyFork {
        _createAndAssert(false, 10_000);
    }

    function test_Fork_CreatePool_Fee1Percent_FireIsToken0() public onlyFork {
        _createAndAssert(true, 10_000);
    }

    function test_Fork_CreatePool_Fee0_3Percent() public onlyFork {
        Created memory c = _createAndAssert(false, 3000);
        assertEq(c.plan.tickLower, -887_220);
        assertEq(c.plan.tickUpper, 887_220);
    }

    /// @dev 일반 사용자 매수(ETH→FIRE, SwapRouter02)와 저수준 매도(FIRE→WETH, pool.swap) 후
    ///      양쪽 수수료가 쌓이고 포지션 소유자만 수취할 수 있는지 확인.
    function test_Fork_SwapsSucceedAndFeesAreCollectableByOwner() public onlyFork {
        Created memory c = _createAndAssert(false, 10_000);
        address buyer = makeAddr("buyer");
        vm.deal(buyer, 1 ether);
        uint256 ethIn = 0.1 ether;
        uint256 fireOut = _buyWithRouter(c, buyer, ethIn);
        uint256 fireIn = fireOut / 2;
        _sellThroughPool(c, buyer, fireIn);
        _assertFeesCollectableOnlyByOwner(c, ethIn, fireIn);
    }

    /// @dev ETH → FIRE (SwapRouter02, msg.value로 지불).
    function _buyWithRouter(Created memory c, address buyer, uint256 ethIn) internal returns (uint256 fireOut) {
        vm.prank(buyer);
        fireOut = ISwapRouter02(ROUTER).exactInputSingle{value: ethIn}(
            ISwapRouter02.ExactInputSingleParams({
                tokenIn: WETH,
                tokenOut: c.d.token,
                fee: c.plan.fee,
                recipient: buyer,
                amountIn: ethIn,
                amountOutMinimum: 1,
                sqrtPriceLimitX96: 0
            })
        );
        assertEq(FireToken(c.d.token).balanceOf(buyer), fireOut);
        // 1% 수수료 + 가격 영향(풀 ETH의 약 3.3%) 반영: 이상적 수량의 95% ~ 99% 사이
        uint256 ideal = ethIn * LP_FIRE / SEED_ETH;
        assertGt(fireOut, ideal * 95 / 100);
        assertLt(fireOut, ideal * 99 / 100);
    }

    /// @dev FIRE → WETH (pool.swap + 최소 콜백 컨트랙트).
    function _sellThroughPool(Created memory c, address seller, uint256 fireIn) internal {
        DeployForkSwapper swapper = new DeployForkSwapper();
        vm.prank(seller);
        assertTrue(FireToken(c.d.token).transfer(address(swapper), fireIn));
        uint256 wethOut = swapper.swapExactInput(IUniswapV3Pool(c.res.pool), c.d.token, fireIn, seller);
        assertGt(wethOut, 0);
        assertEq(IERC20(WETH).balanceOf(seller), wethOut);
    }

    /// @dev 입력 토큰의 1%가 LP 몫 (프로토콜 수수료가 켜져 있으면 그만큼 제외). 소유자 외 수취 불가.
    function _assertFeesCollectableOnlyByOwner(Created memory c, uint256 ethIn, uint256 fireIn) internal {
        (uint256 expectedWethFee, uint256 expectedFireFee) = _expectedFees(c, ethIn, fireIn);
        INonfungiblePositionManager.CollectParams memory params = INonfungiblePositionManager.CollectParams({
            tokenId: c.res.tokenId,
            recipient: makeAddr("stranger"),
            amount0Max: type(uint128).max,
            amount1Max: type(uint128).max
        });
        vm.prank(params.recipient);
        vm.expectRevert(bytes("Not approved"));
        npm.collect(params);

        params.recipient = c.d.deployer;
        (uint256 wethFee, uint256 fireFee) = _collectAsOwner(c, params);
        assertApproxEqAbs(wethFee, expectedWethFee, 10);
        assertApproxEqAbs(fireFee, expectedFireFee, 10);
        emit log_named_uint("collected WETH fee (wei)", wethFee);
        emit log_named_uint("collected FIRE fee (wei)", fireFee);
    }

    function _expectedFees(Created memory c, uint256 ethIn, uint256 fireIn)
        internal
        view
        returns (uint256 wethFee, uint256 fireFee)
    {
        (,,,,, uint8 feeProtocol,) = IUniswapV3Pool(c.res.pool).slot0();
        (uint8 wethProtocol, uint8 fireProtocol) =
            c.plan.fireIsToken0 ? (feeProtocol >> 4, feeProtocol % 16) : (feeProtocol % 16, feeProtocol >> 4);
        wethFee = _lpShare(ethIn / 100, wethProtocol);
        fireFee = _lpShare(fireIn - fireIn * 99 / 100, fireProtocol);
    }

    /// @dev 소유자가 수취한 양이 실제 잔액 증가와 같은지까지 확인.
    function _collectAsOwner(Created memory c, INonfungiblePositionManager.CollectParams memory params)
        internal
        returns (uint256 wethFee, uint256 fireFee)
    {
        uint256 wethBefore = IERC20(WETH).balanceOf(c.d.deployer);
        uint256 fireBefore = FireToken(c.d.token).balanceOf(c.d.deployer);
        vm.prank(c.d.deployer);
        (uint256 c0, uint256 c1) = npm.collect(params);
        (fireFee, wethFee) = c.plan.fireIsToken0 ? (c0, c1) : (c1, c0);
        assertEq(IERC20(WETH).balanceOf(c.d.deployer) - wethBefore, wethFee);
        assertEq(FireToken(c.d.token).balanceOf(c.d.deployer) - fireBefore, fireFee);
    }

    function _lpShare(uint256 fee, uint8 protocolDenominator) internal pure returns (uint256) {
        return protocolDenominator == 0 ? fee : fee - fee / protocolDenominator;
    }

    // ───────────────────────── 승인: permit (multicall 안) vs approve 대체 경로 ─────────────────────────

    /// @dev 키스토어(--account)처럼 스크립트가 서명할 수 있으면 permit을 multicall 첫 호출로 넣음:
    ///      트랜잭션은 multicall + approve(0) 2건뿐이고, 사전 approve 트랜잭션(풀 생성 신호)이 없음.
    function test_Fork_Permit_ApprovalInsideMulticall() public onlyFork {
        (address deployer, uint256 key) = _keyedDeployerFor(false);
        vm.rememberKey(key);
        Deploy.DeployResult memory d = _launchWith(deployer);
        uint256 nonceBefore = vm.getNonce(deployer);
        (CreatePool.PoolPlan memory plan, CreatePool.PoolResult memory res) =
            poolScript.createPool(_cfg(d.token, 10_000), deployer);
        assertTrue(plan.usePermit);
        assertEq(poolScript.multicallData(plan).length, 4);
        assertEq(vm.getNonce(deployer), nonceBefore + 2);
        assertEq(FireToken(d.token).nonces(deployer), 1);
        assertEq(FireToken(d.token).allowance(deployer, NPM), 0);
        assertEq(npm.ownerOf(res.tokenId), deployer);
        assertGe(res.fireUsed * 1000, LP_FIRE * 999);
    }

    /**
     * @dev 리뷰 PoC: 시뮬레이션 뒤 전송 전에 누군가 풀을 4배 가격으로 초기화 → multicall이 amountMin에서 revert.
     *      permit 경로: 승인도 함께 되돌려져 남는 것이 없음.
     *      approve 대체 경로(--ledger 등): 7억 승인이 남음 → PostDeployCheck가 중단 없이 FAIL/WARN으로 보고하고,
     *      confirm()도 없는 포지션을 기록하지 않음.
     */
    function test_Fork_FailedMulticall_PermitLeavesNoApproval_ApprovePathIsReported() public onlyFork {
        (address keyed, uint256 key) = _keyedDeployerFor(false);
        vm.rememberKey(key);
        Deploy.DeployResult memory d = _launchWith(keyed);
        (CreatePool.PoolPlan memory plan,,) = _simulate(_cfg(d.token, 10_000), keyed);
        assertTrue(plan.usePermit);
        _frontRunInitialize(d.token, plan.sqrtPriceX96 * 2);
        assertFalse(_replay(plan));
        assertEq(FireToken(d.token).allowance(keyed, NPM), 0);
        assertEq(npm.balanceOf(keyed), 0);

        Deploy.DeployResult memory d2 = _launch(false);
        (CreatePool.PoolPlan memory plan2,, string memory pending2) = _simulate(_cfg(d2.token, 10_000), d2.deployer);
        assertFalse(plan2.usePermit);
        _frontRunInitialize(d2.token, plan2.sqrtPriceX96 * 2);
        assertFalse(_replay(plan2));
        assertEq(FireToken(d2.token).allowance(d2.deployer, NPM), LP_FIRE);

        string memory path = _tmpPath("failed-multicall");
        _writePendingRecord(d2, pending2, path);
        PostDeployCheck.Report memory rep = checkHarness.check(checkHarness.loadInputs(path), true);
        assertEq(rep.failed, 2); // LP 포지션 없음 + 풀이 기록됐는데 배포 지갑이 7억을 그대로 가짐
        assertEq(rep.warned, 3); // deploy·pool 기록 pending + 남은 승인
        vm.expectRevert(abi.encodeWithSelector(CreatePool.CreatePoolPositionNotFound.selector, d2.deployer, 0));
        harness.confirmRecord(path);
        _removeFile(path);
    }

    /// @dev 하드웨어 지갑 경로: permitTypedData()의 JSON을 `cast wallet sign --data`로 서명해 PERMIT_SIGNATURE로 전달.
    ///      (키를 forge에 로드하지 않아 스크립트 안에서는 서명할 수 없는 --ledger 상황을 재현)
    function test_Fork_PermitSignatureFromEnv() public onlyFork {
        (address deployer, uint256 key) = _keyedDeployerFor(true);
        Deploy.DeployResult memory d = _launchWith(deployer);
        string memory path = _tmpPath("permit-env");
        string memory permitFile = _tmpPath("permit-typed-data");
        vm.writeJson(deployScript.recordJson(d), path);
        harness.setPaths(path, permitFile);
        harness.setFakeEnv("CONFIRM_MAINNET", "I_UNDERSTAND");
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        harness.setFakeEnv("PERMIT_DEADLINE", vm.toString(deadline));
        bytes32 digest = _assertTypedDataMatchesDigest(d.token, deployer, deadline);

        // 다른 키의 서명 → 거부
        (address wrong, uint256 wrongKey) = makeAddrAndKey("wrong-permit-signer");
        _setPermitSignature(wrongKey, digest);
        CreatePool.PoolConfig memory cfg = harness.loadConfig(path);
        vm.expectRevert(abi.encodeWithSelector(CreatePool.CreatePoolBadPermitSignature.selector, wrong));
        harness.createPool(cfg, deployer);

        // 올바른 서명이라도 마감까지 5분 미만이면 거부 (포함 전에 만료될 수 있으므로 다시 서명)
        _setPermitSignature(key, digest);
        cfg = harness.loadConfig(path);
        uint256 nowTs = vm.getBlockTimestamp();
        vm.warp(deadline - harness.PERMIT_MIN_REMAINING() + 1);
        vm.expectRevert(abi.encodeWithSelector(CreatePool.CreatePoolPermitExpired.selector, deadline));
        harness.createPool(cfg, deployer);
        vm.warp(nowTs);

        (CreatePool.PoolPlan memory plan, CreatePool.PoolResult memory res) = harness.createPool(cfg, deployer);
        assertTrue(plan.usePermit);
        assertEq(plan.permitDeadline, deadline);
        assertEq(FireToken(d.token).allowance(deployer, NPM), 0);
        assertEq(npm.ownerOf(res.tokenId), deployer);

        // permitTypedData(): --sender 없이(forge 기본 sender) 실행하면 엉뚱한 owner로 서명하지 않도록 중단
        vm.expectRevert(CreatePool.CreatePoolPermitOwnerUnknown.selector);
        harness.permitTypedData();
        // 같은 형식의 JSON을 파일로 씀 (owner 다음 nonce = 1)
        string memory written = harness.permitTypedDataFor(deployer);
        assertEq(_readFile(permitFile), written);
        assertEq(vm.parseJsonAddress(written, ".message.owner"), deployer);
        assertEq(vm.parseJsonUint(written, ".message.nonce"), 1);
        assertEq(vm.parseJsonUint(written, ".message.deadline"), deadline);
        _removeFile(permitFile);
        _removeFile(path);
    }

    function _setPermitSignature(uint256 key, bytes32 digest) internal {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        harness.setFakeEnv("PERMIT_SIGNATURE", vm.toString(abi.encodePacked(r, s, v)));
    }

    /// @dev 서명 입력 JSON의 각 필드와, 그 필드로 독립 계산한 EIP-712 다이제스트가 스크립트 값과 같은지 확인.
    function _assertTypedDataMatchesDigest(address token, address owner, uint256 deadline)
        internal
        view
        returns (bytes32 digest)
    {
        string memory typed = harness.permitTypedDataJson(token, owner, NPM, LP_FIRE, deadline);
        assertEq(vm.parseJsonString(typed, ".primaryType"), "Permit");
        assertEq(vm.parseJsonString(typed, ".domain.name"), "Fire");
        assertEq(vm.parseJsonString(typed, ".domain.version"), "1");
        assertEq(vm.parseJsonUint(typed, ".domain.chainId"), 8453);
        assertEq(vm.parseJsonAddress(typed, ".domain.verifyingContract"), token);
        assertEq(vm.parseJsonAddress(typed, ".message.owner"), owner);
        assertEq(vm.parseJsonAddress(typed, ".message.spender"), NPM);
        assertEq(vm.parseJsonUint(typed, ".message.value"), LP_FIRE);
        assertEq(vm.parseJsonUint(typed, ".message.nonce"), 0);
        assertEq(vm.parseJsonUint(typed, ".message.deadline"), deadline);
        bytes32 domain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("Fire"),
                keccak256("1"),
                uint256(8453),
                token
            )
        );
        bytes32 structHash = keccak256(abi.encode(harness.PERMIT_TYPEHASH(), owner, NPM, LP_FIRE, 0, deadline));
        digest = keccak256(abi.encodePacked("\x19\x01", domain, structHash));
        assertEq(harness.permitDigest(token, owner, NPM, LP_FIRE, 0, deadline), digest);
    }

    // ───────────────────────── 시뮬레이션 ≠ 체인: confirm()이 실제 값을 기록 ─────────────────────────

    /**
     * @dev 리뷰 PoC: 시뮬레이션과 포함 사이에 다른 사람이 LP NFT를 발행하면 실제 id가 1 밀림.
     *      예전에는 시뮬레이션 id를 기록·출력해 남의 NFT를 가리켰음. 이제 pending 기록에는 id가 없고,
     *      confirm()이 배포 지갑에서 실제 포지션을 찾아 기록함. 틀린 id를 넣어도 PostDeployCheck는 중단 없이
     *      FAIL 1건으로 알리고 실제 포지션으로 나머지를 점검함.
     */
    function test_Fork_Confirm_FindsRealTokenIdAfterInterleavedMint() public onlyFork {
        Deploy.DeployResult memory d = _launch(false);
        Deploy.DeployResult memory other = _launchWith(_deployerFrom(true, 500));
        (CreatePool.PoolPlan memory plan, CreatePool.PoolResult memory sim, string memory pending) =
            _simulate(_cfg(d.token, 10_000), d.deployer);

        poolScript.createPool(_cfg(other.token, 10_000), other.deployer); // 제3자의 mint가 먼저 포함됨
        assertEq(npm.ownerOf(sim.tokenId), other.deployer);
        vm.recordLogs();
        assertTrue(_replay(plan));
        _injectLogs(vm.getRecordedLogs(), sim.pool);

        string memory path = _tmpPath("interleaved");
        _writePendingRecord(d, pending, path);
        string memory json = _readFile(path);
        assertEq(vm.parseJsonString(json, ".pool.status"), "pending");
        assertFalse(vm.keyExistsJson(json, ".pool.tokenId")); // 시뮬레이션 id는 기록하지 않음

        CreatePool.Confirmed memory c = harness.confirmRecord(path);
        assertEq(c.tokenId, sim.tokenId + 1);
        assertEq(npm.ownerOf(c.tokenId), d.deployer);
        assertEq(c.liquidity, sim.liquidity);
        assertEq(c.fireDeposited, sim.fireUsed);
        assertEq(c.ethDeposited, sim.ethUsed);
        json = _readFile(path);
        assertEq(vm.parseJsonString(json, ".pool.status"), "confirmed");
        assertEq(vm.parseJsonUint(json, ".pool.tokenId"), sim.tokenId + 1);

        deployScript.confirmRecord(path);
        PostDeployCheck.CheckInputs memory inputs = checkHarness.loadInputs(path);
        _removeFile(path);
        PostDeployCheck.Report memory rep = checkHarness.check(inputs, true);
        assertEq(rep.failed, 0);
        assertEq(rep.warned, 1); // LP NFT 미락업

        inputs.tokenId = sim.tokenId; // 예전처럼 시뮬레이션 id가 기록된 경우
        rep = checkHarness.check(inputs, true);
        assertEq(rep.failed, 1);
    }

    /**
     * @dev 리뷰 PoC: 시뮬레이션 때는 풀이 없었는데 전송 전에 제3자가 +0.4% 가격으로 초기화 → 슬리피지(0.5%) 안이라
     *      체인에서는 성공하지만 실제 가격·유동성은 시뮬레이션과 다름. confirm()이 실제 값을 기록하므로
     *      PostDeployCheck가 "유동성 감소"로 오인하지 않음.
     */
    function test_Fork_FrontRunInitializeWithinSlippage_ConfirmRecordsReality() public onlyFork {
        Deploy.DeployResult memory d = _launch(true);
        (CreatePool.PoolPlan memory plan, CreatePool.PoolResult memory sim, string memory pending) =
            _simulate(_cfg(d.token, 10_000), d.deployer);
        assertEq(plan.existingPool, address(0));

        vm.recordLogs();
        uint160 skewed = uint160(uint256(plan.sqrtPriceX96) * 1002 / 1000); // 가격 +0.4%
        address pool = _frontRunInitialize(d.token, skewed);
        assertEq(pool, sim.pool);
        assertTrue(_replay(plan));
        _injectLogs(vm.getRecordedLogs(), pool);

        string memory path = _tmpPath("front-run");
        _writePendingRecord(d, pending, path);
        CreatePool.Confirmed memory c = harness.confirmRecord(path);
        assertEq(c.initialSqrtPriceX96, skewed);
        assertLt(c.liquidity, sim.liquidity);
        (, LaunchPositions.Position memory position) = LaunchPositions.read(npm, c.tokenId);
        uint128 positionLiquidity = position.liquidity;
        assertEq(c.liquidity, positionLiquidity);
        string memory json = _readFile(path);
        assertEq(vm.parseJsonUint(json, ".pool.initialSqrtPriceX96"), skewed);
        assertEq(vm.parseJsonUint(json, ".pool.liquidity"), positionLiquidity);

        PostDeployCheck.Report memory rep = checkHarness.check(checkHarness.loadInputs(path), true);
        _removeFile(path);
        assertEq(rep.failed, 0);
    }

    /// @dev pending 기록 → confirm → PostDeployCheck 전 과정과 기록 내용.
    function test_Fork_RecordConfirmAndPostDeployCheck() public onlyFork {
        vm.recordLogs();
        Created memory c = _createAndAssert(false, 10_000);
        _injectLogs(vm.getRecordedLogs(), c.res.pool);
        string memory path = _tmpPath("record");
        _writePendingRecord(c.d, harness.pendingPoolJson(c.plan, c.res), path);

        string memory json = _readFile(path);
        assertEq(vm.parseJsonString(json, ".pool.status"), "pending");
        assertEq(vm.parseJsonAddress(json, ".contracts.FireToken"), c.d.token);
        assertEq(vm.parseJsonAddress(json, ".pool.address"), c.res.pool);
        assertEq(vm.parseJsonAddress(json, ".pool.positionManager"), NPM);
        assertEq(vm.parseJsonUint(json, ".pool.fee"), 10_000);
        assertEq(vm.parseJsonInt(json, ".pool.tickLower"), -887_200);
        assertEq(vm.parseJsonInt(json, ".pool.tickUpper"), 887_200);
        assertEq(vm.parseJsonUint(json, ".pool.targetSqrtPriceX96"), SQRT_WETH_TOKEN0);
        assertEq(vm.parseJsonString(json, ".pool.seedEth"), "3000000000000000000");
        assertEq(vm.parseJsonAddress(json, ".pool.positionOwner"), c.d.deployer);
        assertEq(vm.parseJsonString(json, ".pool.approval"), "approve");
        assertFalse(vm.keyExistsJson(json, ".pool.tokenId"));
        assertFalse(vm.keyExistsJson(json, ".pool.liquidity"));
        assertFalse(vm.keyExistsJson(json, ".pool.fireDeposited"));

        deployScript.confirmRecord(path);
        harness.confirmRecord(path);
        json = _readFile(path);
        assertEq(vm.parseJsonString(json, ".status"), "confirmed");
        assertEq(vm.parseJsonString(json, ".pool.status"), "confirmed");
        assertEq(vm.parseJsonUint(json, ".pool.tokenId"), c.res.tokenId);
        assertEq(vm.parseJsonString(json, ".pool.liquidity"), vm.toString(c.res.liquidity));
        assertEq(vm.parseJsonString(json, ".pool.fireDeposited"), vm.toString(c.res.fireUsed));
        assertEq(vm.parseJsonString(json, ".pool.ethDeposited"), vm.toString(c.res.ethUsed));
        assertEq(vm.parseJsonString(json, ".pool.ethRefunded"), vm.toString(c.res.ethRefunded));
        assertEq(vm.parseJsonUint(json, ".pool.initialSqrtPriceX96"), SQRT_WETH_TOKEN0);
        assertEq(vm.parseJsonInt(json, ".pool.initialTick"), c.res.tick);
        assertEq(vm.parseJsonBytes32(json, ".pool.mintTx"), keccak256("fork-mint-tx"));
        assertEq(vm.parseJsonAddress(json, ".pool.ownerAtConfirm"), c.d.deployer);

        PostDeployCheck.CheckInputs memory inputs = checkHarness.loadInputs(path);
        _removeFile(path);
        assertEq(inputs.poolStatus, checkHarness.STATUS_CONFIRMED());
        assertEq(inputs.tokenId, c.res.tokenId);
        // 리뷰 PoC(F4) 회귀: 실제 배포본의 런타임 코드가 이 저장소의 컴파일 결과와 같음(EIP-712 캐시 immutable 포함 재현)
        assertEq(inputs.tokenCode, LaunchCode.MATCH);
        assertEq(inputs.vestingCode, LaunchCode.MATCH);
        assertTrue(inputs.hasDeployerNonce);
        assertGt(inputs.minLiquidity, 0);
        assertGe(c.res.liquidity, inputs.minLiquidity);
        PostDeployCheck.Report memory rep = checkHarness.check(inputs, true);
        assertEq(rep.failed, 0);
        assertEq(rep.warned, 1); // LP NFT 미락업

        // 락업(락커 컨트랙트로 NFT 이전) 후 LP_LOCKER 지정 → 경고 없음
        address locker = address(new DeployForkLocker());
        vm.prank(c.d.deployer);
        npm.transferFrom(c.d.deployer, locker, c.res.tokenId);
        inputs.lpLocker = locker;
        rep = checkHarness.check(inputs, true);
        assertEq(rep.failed, 0);
        assertEq(rep.warned, 0);

        // 락커가 아닌 곳이 들고 있으면 FAIL
        inputs.lpLocker = makeAddr("other-locker");
        assertEq(checkHarness.check(inputs, false).failed, 1);
    }

    /// @dev 이미 락업해 배포 지갑에 NFT가 없으면 LP_TOKEN_ID로 지정해 confirm. 여러 개면 지정 요구.
    function test_Fork_Confirm_LockedNftNeedsLpTokenId() public onlyFork {
        Created memory c = _createAndAssert(true, 10_000);
        string memory path = _tmpPath("confirm-locked");
        _writePendingRecord(c.d, harness.pendingPoolJson(c.plan, c.res), path);
        address locker = address(new DeployForkLocker());
        vm.prank(c.d.deployer);
        npm.transferFrom(c.d.deployer, locker, c.res.tokenId);

        vm.expectRevert(abi.encodeWithSelector(CreatePool.CreatePoolPositionNotFound.selector, c.d.deployer, 0));
        harness.confirmRecord(path);
        harness.setFakeEnv("LP_TOKEN_ID", vm.toString(c.res.tokenId));
        CreatePool.Confirmed memory conf = harness.confirmRecord(path);
        assertEq(conf.tokenId, c.res.tokenId);
        assertEq(conf.owner, locker);
        assertFalse(conf.mintFound); // 이벤트를 주입하지 않음 → 예치량 미기록
        string memory json = _readFile(path);
        assertFalse(vm.keyExistsJson(json, ".pool.fireDeposited"));
        assertEq(vm.parseJsonAddress(json, ".pool.ownerAtConfirm"), locker);

        harness.setFakeEnv("LP_TOKEN_ID", vm.toString(c.res.tokenId + 1)); // 없는 id
        vm.expectRevert(abi.encodeWithSelector(CreatePool.CreatePoolNotLaunchPosition.selector, c.res.tokenId + 1));
        harness.confirmRecord(path);
        _removeFile(path);
    }

    /**
     * @dev 배포 지갑의 두 번째(소액) FIRE/WETH 전체 범위 포지션은 런칭 크기(기록 계획의 하한) 미만이라 confirm이 무시하고
     *      실제 런칭 포지션을 고름(예전에는 "모양"만 보고 2개라며 중단). 그 소액 포지션을 LP_TOKEN_ID로 지정해도 거부.
     *      런칭 크기 포지션이 둘이면 여전히 LP_TOKEN_ID를 요구함(아래 _mintSecondFullRange는 크기를 바꿔 재사용).
     */
    function test_Fork_Confirm_IgnoresSmallSecondPosition() public onlyFork {
        vm.recordLogs();
        Created memory c = _createAndAssert(false, 10_000);
        _injectLogs(vm.getRecordedLogs(), c.res.pool);
        string memory path = _tmpPath("confirm-second");
        _writePendingRecord(c.d, harness.pendingPoolJson(c.plan, c.res), path);
        harness.confirmRecord(path);

        uint256 second = _mintSecondFullRange(c);
        CreatePool.Confirmed memory conf = harness.confirmRecord(path);
        assertEq(conf.tokenId, c.res.tokenId);
        assertGt(conf.minLiquidity, 0);
        assertGe(conf.liquidity, conf.minLiquidity);

        harness.clearLogs();
        harness.setFakeEnv("LP_TOKEN_ID", vm.toString(second));
        (, LaunchPositions.Position memory small) = LaunchPositions.read(npm, second);
        vm.expectRevert(
            abi.encodeWithSelector(
                CreatePool.CreatePoolPositionBelowPlan.selector, second, small.liquidity, conf.minLiquidity
            )
        );
        harness.confirmRecord(path);
        string memory json = _readFile(path);
        assertEq(vm.parseJsonUint(json, ".pool.tokenId"), c.res.tokenId);
        assertEq(vm.parseJsonUint(json, ".pool.minLiquidity"), conf.minLiquidity);

        // 기록의 계획이 작았다면(테스트넷 리허설 규모) 두 포지션 모두 런칭 크기 → 고르지 않고 LP_TOKEN_ID 요구
        harness.setFakeEnv("LP_TOKEN_ID", "");
        vm.writeJson('"1000000000000000000000"', path, ".pool.lpFireAmount");
        vm.writeJson('"1000000000000"', path, ".pool.seedEth"); // 소액 포지션도 하한(약 3.1e16)을 넘는 규모
        vm.expectRevert(abi.encodeWithSelector(CreatePool.CreatePoolAmbiguousPosition.selector, c.d.deployer, 2));
        harness.confirmRecord(path);
        vm.writeJson(string.concat('"', vm.toString(LP_FIRE), '"'), path, ".pool.lpFireAmount");
        vm.writeJson(string.concat('"', vm.toString(SEED_ETH), '"'), path, ".pool.seedEth");

        // 런칭 포지션을 같은 크기로 새 NFT에 옮긴 경우(예: 락커가 포지션을 새로 발행): LP_TOKEN_ID로 다시 확정하면
        // 새 id의 mint 이벤트를 못 찾았을 때 이전 id의 예치량·트랜잭션이 남지 않도록 null로 비움
        uint256 migrated = _migrateLaunchPosition(c);
        harness.setFakeEnv("LP_TOKEN_ID", vm.toString(migrated));
        conf = harness.confirmRecord(path);
        assertEq(conf.tokenId, migrated);
        assertFalse(conf.mintFound);
        json = _readFile(path);
        _removeFile(path);
        assertEq(vm.parseJsonUint(json, ".pool.tokenId"), migrated);
        assertTrue(vm.keyExistsJson(json, ".pool.mintTx")); // 키는 남지만 값은 null
        assertEq(vm.parseJsonUint(json, ".pool.initialSqrtPriceX96"), SQRT_WETH_TOKEN0); // 풀 단위 값은 유지
    }

    /// @dev 배포자가 런칭 포지션의 유동성을 전부 빼서 같은 수량으로 새 전체 범위 포지션을 발행 (새 NFT id).
    function _migrateLaunchPosition(Created memory c) internal returns (uint256 tokenId) {
        vm.startPrank(c.d.deployer);
        npm.decreaseLiquidity(
            INonfungiblePositionManager.DecreaseLiquidityParams({
                tokenId: c.res.tokenId,
                liquidity: c.res.liquidity,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp
            })
        );
        (uint256 amount0, uint256 amount1) = npm.collect(
            INonfungiblePositionManager.CollectParams({
                tokenId: c.res.tokenId,
                recipient: c.d.deployer,
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            })
        );
        IWETH9(WETH).approve(NPM, type(uint256).max);
        assertTrue(FireToken(c.d.token).approve(NPM, type(uint256).max));
        (tokenId,,,) = npm.mint(
            INonfungiblePositionManager.MintParams({
                token0: c.plan.token0,
                token1: c.plan.token1,
                fee: c.plan.fee,
                tickLower: c.plan.tickLower,
                tickUpper: c.plan.tickUpper,
                amount0Desired: amount0,
                amount1Desired: amount1,
                amount0Min: 0,
                amount1Min: 0,
                recipient: c.d.deployer,
                deadline: block.timestamp
            })
        );
        vm.stopPrank();
    }

    /// @dev 배포자가 같은 풀에 두 번째 전체 범위 포지션을 만듦 (에어드롭 지갑에서 받은 FIRE + WETH 소량).
    function _mintSecondFullRange(Created memory c) internal returns (uint256 tokenId) {
        vm.prank(airdrop);
        assertTrue(FireToken(c.d.token).transfer(c.d.deployer, 1000e18));
        vm.startPrank(c.d.deployer);
        IWETH9(WETH).deposit{value: 0.01 ether}();
        IWETH9(WETH).approve(NPM, type(uint256).max);
        assertTrue(FireToken(c.d.token).approve(NPM, type(uint256).max));
        (tokenId,,,) = npm.mint(
            INonfungiblePositionManager.MintParams({
                token0: c.plan.token0,
                token1: c.plan.token1,
                fee: c.plan.fee,
                tickLower: c.plan.tickLower,
                tickUpper: c.plan.tickUpper,
                amount0Desired: c.plan.fireIsToken0 ? 1000e18 : 0.01 ether,
                amount1Desired: c.plan.fireIsToken0 ? 0.01 ether : 1000e18,
                amount0Min: 0,
                amount1Min: 0,
                recipient: c.d.deployer,
                deadline: block.timestamp
            })
        );
        vm.stopPrank();
    }

    /// @dev confirm()의 실제 이벤트 조회 경로(vm.eth_getLogs, 500블록 구간)를 Base의 실제 mint 이벤트로 확인.
    ///      LP NFT #6192194: 블록 52,316,994, tx 0x290e22ee…9a04 (cast logs로 확인한 값).
    function test_Fork_FindMintLog_RealChainEvent() public onlyFork {
        if (block.number < 52_316_994) vm.skip(true);
        (bool found, VmSafe.EthGetLogs memory log) = harness.realFindMintLog(NPM, 6_192_194, 52_316_000);
        assertTrue(found);
        assertEq(log.blockNumber, 52_316_994);
        assertEq(log.transactionHash, 0x290e22ee4b1088a8795ab617e261912abee663868b9be4223652258449d79a04);
        (uint128 liquidity, uint256 amount0, uint256 amount1) = abi.decode(log.data, (uint128, uint256, uint256));
        assertEq(liquidity, 0x18defaae34adb379a);
        assertEq(amount0, 0x1d9235793136c067cdd);
        assertEq(amount1, 0x1c55036);
        if (block.number == DEFAULT_FORK_BLOCK) {
            (found,) = harness.realFindMintLog(NPM, 6_192_194, 52_316_995); // 이벤트 이후 구간: 없음(revert 없음)
            assertFalse(found);
        }
    }

    // ───────────────────────── 기존 풀 처리 ─────────────────────────

    /// @dev 스나이퍼가 먼저 풀을 만들고 엉뚱한 가격으로 초기화 → 중단. 대안(다른 수수료 등급)은 정상 동작.
    function test_Fork_RevertWhen_PoolPreCreatedAtWrongPrice() public onlyFork {
        Deploy.DeployResult memory d = _launch(false);
        address pool = _frontRunInitialize(d.token, _targetSqrt(d.token) * 2); // 가격 4배
        vm.expectRevert(
            abi.encodeWithSelector(CreatePool.CreatePoolExistingPoolPriceMismatch.selector, pool, type(uint256).max)
        );
        poolScript.createPool(_cfg(d.token, 10_000), d.deployer);

        // 옵션 (a): FEE_TIER=3000 으로는 정상 생성
        (, CreatePool.PoolResult memory res) = poolScript.createPool(_cfg(d.token, 3000), d.deployer);
        assertGt(res.liquidity, 0);
    }

    /// @dev 1% 경계를 스크립트 수준에서 확인: 편차 101 bps → 중단, 정확히 100 bps → SLIPPAGE_BPS 50이면 중단,
    ///      100이면 기존 가격으로 진행(한쪽이 최대 1% 덜 쓰임).
    function test_Fork_ExistingPoolDeviationBoundary() public onlyFork {
        Deploy.DeployResult memory d = _launchWith(_deployerFrom(true, 200));
        uint160 s101 = _sqrtWithDeviation(_targetSqrt(d.token), 101);
        address pool = _frontRunInitialize(d.token, s101);
        vm.expectRevert(abi.encodeWithSelector(CreatePool.CreatePoolExistingPoolPriceMismatch.selector, pool, 101));
        poolScript.createPool(_cfg(d.token, 10_000), d.deployer);

        Deploy.DeployResult memory e = _launchWith(_deployerFrom(false, 300));
        uint160 s100 = _sqrtWithDeviation(_targetSqrt(e.token), 100);
        address pool2 = _frontRunInitialize(e.token, s100);
        vm.expectRevert(
            abi.encodeWithSelector(
                CreatePool.CreatePoolExistingPoolPriceBeyondSlippage.selector, pool2, 100, uint256(50)
            )
        );
        poolScript.createPool(_cfg(e.token, 10_000), e.deployer);
        CreatePool.PoolConfig memory cfg = _cfg(e.token, 10_000);
        cfg.slippageBps = 100;
        (, CreatePool.PoolResult memory res) = poolScript.createPool(cfg, e.deployer);
        assertEq(res.sqrtPriceX96, s100);
        assertGe(res.fireUsed * 10_000, LP_FIRE * 9900);
        assertGe(res.ethUsed * 10_000, SEED_ETH * 9900);
    }

    /// @dev priceDeviationBps(s, target) == bps 인 가장 큰 s (> target)를 이분 탐색 (편차는 s에 대해 단조 증가).
    function _sqrtWithDeviation(uint160 target, uint256 bps) internal pure returns (uint160) {
        uint256 lo = target;
        uint256 hi = uint256(target) * 102 / 100;
        while (lo < hi) {
            uint256 mid = (lo + hi + 1) / 2;
            if (PoolMath.priceDeviationBps(uint160(mid), target) <= bps) lo = mid;
            else hi = mid - 1;
        }
        assertEq(PoolMath.priceDeviationBps(uint160(lo), target), bps);
        return uint160(lo);
    }

    function test_Fork_RevertWhen_ExistingPoolPriceBeyondSlippageButWithinOnePercent() public onlyFork {
        Deploy.DeployResult memory d = _launch(true);
        uint160 target = _targetSqrt(d.token);
        uint160 skewed = target * 1004 / 1000; // 가격 약 +0.8%
        address pool = _frontRunInitialize(d.token, skewed);
        uint256 deviation = PoolMath.priceDeviationBps(skewed, target);
        assertGt(deviation, 50);
        assertLe(deviation, 100);

        vm.expectRevert(
            abi.encodeWithSelector(
                CreatePool.CreatePoolExistingPoolPriceBeyondSlippage.selector, pool, deviation, uint256(50)
            )
        );
        poolScript.createPool(_cfg(d.token, 10_000), d.deployer);

        // SLIPPAGE_BPS=100 이면 기존 가격 그대로 진행 (가격은 바뀌지 않고, 한쪽이 덜 쓰임)
        CreatePool.PoolConfig memory cfg = _cfg(d.token, 10_000);
        cfg.slippageBps = 100;
        (CreatePool.PoolPlan memory plan, CreatePool.PoolResult memory res) = poolScript.createPool(cfg, d.deployer);
        assertEq(plan.existingSqrtPriceX96, skewed);
        assertEq(res.sqrtPriceX96, skewed);
        assertGe(res.fireUsed * 10_000, LP_FIRE * 9900);
        assertGe(res.ethUsed * 10_000, SEED_ETH * 9900);
        assertEq(FireToken(d.token).allowance(d.deployer, NPM), 0);
    }

    function test_Fork_ProceedsWhen_ExistingPoolWithinTolerance() public onlyFork {
        Deploy.DeployResult memory d = _launch(false);
        uint160 skewed = _targetSqrt(d.token) * 10_005 / 10_000; // 가격 약 +0.1%
        address pool = _frontRunInitialize(d.token, skewed);
        (, CreatePool.PoolResult memory res) = poolScript.createPool(_cfg(d.token, 10_000), d.deployer);
        assertEq(res.pool, pool);
        assertEq(res.sqrtPriceX96, skewed);
        assertGe(res.fireUsed * 1000, LP_FIRE * 998);
        assertGe(res.ethUsed * 1000, SEED_ETH * 998);
    }

    /// @dev 풀만 만들어지고 초기화되지 않은 경우: 이 multicall이 목표 가격으로 초기화.
    function test_Fork_ProceedsWhen_ExistingPoolUninitialized() public onlyFork {
        Deploy.DeployResult memory d = _launch(true);
        vm.prank(makeAddr("griefer"));
        address pool = IUniswapV3Factory(FACTORY).createPool(d.token, WETH, 10_000);
        (CreatePool.PoolPlan memory plan, CreatePool.PoolResult memory res) =
            poolScript.createPool(_cfg(d.token, 10_000), d.deployer);
        assertEq(plan.existingPool, pool);
        assertEq(plan.existingSqrtPriceX96, 0);
        assertEq(res.pool, pool);
        assertEq(res.sqrtPriceX96, SQRT_FIRE_TOKEN0);
    }

    /// @dev 누군가 정상 가격으로 이미 유동성을 넣은 풀: 중단 (가격 통제권이 없는 풀에 런칭 물량을 넣지 않음).
    function test_Fork_RevertWhen_PoolAlreadyHasLiquidity() public onlyFork {
        Deploy.DeployResult memory d = _launch(false);
        address griefer = makeAddr("griefer");
        vm.prank(airdrop);
        assertTrue(FireToken(d.token).transfer(griefer, 1000e18));
        vm.deal(griefer, 1 ether);

        vm.startPrank(griefer);
        address pool = IUniswapV3Factory(FACTORY).createPool(d.token, WETH, 10_000);
        IUniswapV3Pool(pool).initialize(_targetSqrt(d.token));
        IWETH9(WETH).deposit{value: 0.01 ether}();
        IWETH9(WETH).approve(NPM, type(uint256).max);
        assertTrue(FireToken(d.token).approve(NPM, type(uint256).max));
        (address t0, address t1) = PoolMath.sortTokens(d.token, WETH);
        (int24 lower, int24 upper) = PoolMath.fullRangeTicks(200);
        (, uint128 griefLiquidity,,) = npm.mint(
            INonfungiblePositionManager.MintParams({
                token0: t0,
                token1: t1,
                fee: 10_000,
                tickLower: lower,
                tickUpper: upper,
                amount0Desired: t0 == d.token ? 1000e18 : 0.01 ether,
                amount1Desired: t0 == d.token ? 0.01 ether : 1000e18,
                amount0Min: 0,
                amount1Min: 0,
                recipient: griefer,
                deadline: block.timestamp
            })
        );
        vm.stopPrank();

        vm.expectRevert(abi.encodeWithSelector(CreatePool.CreatePoolPoolHasLiquidity.selector, pool, griefLiquidity));
        poolScript.createPool(_cfg(d.token, 10_000), d.deployer);
    }

    /**
     * @dev 리뷰 PoC: FireToken 주소는 CREATE(배포자, nonce + 1)로 미리 계산되므로, 배포자 주소가 알려지면 토큰이
     *      생기기 전에 1%·0.3% 두 등급 모두 엉뚱한 가격 + WETH 단독 활성 유동성으로 선점할 수 있음(WETH가 token0일 때).
     *      그러면 CreatePool은 두 등급 모두 PoolHasLiquidity로 막힘. Deploy가 토큰 배포 전에 이를 감지해 아무것도
     *      보내지 않고 중단하고, 공개된 적 없는 새 배포 지갑으로는 정상 진행.
     */
    function test_Fork_RevertWhen_PoolsPreemptedBeforeTokenExists() public onlyFork {
        address deployer = _deployerFor(false);
        address predicted = vm.computeCreateAddress(deployer, vm.getNonce(deployer) + 1);
        assertEq(predicted.code.length, 0);
        address[2] memory pools = _preemptBothTiers(predicted);

        uint256 nonce = vm.getNonce(deployer);
        vm.deal(deployer, 10 ether);
        vm.expectRevert(
            abi.encodeWithSelector(Deploy.DeployPoolPreempted.selector, predicted, uint24(10_000), pools[0])
        );
        deployScript.deploy(_launchCfg(), deployer);
        assertEq(vm.getNonce(deployer), nonce);
        assertEq(predicted.code.length, 0);

        // 새 배포 지갑: 선점된 주소와 무관하게 정상 런칭
        Deploy.DeployResult memory d = _launchWith(_deployerFrom(false, 100));
        (, CreatePool.PoolResult memory res) = poolScript.createPool(_cfg(d.token, 10_000), d.deployer);
        assertGt(res.liquidity, 0);
    }

    // ───────────────────────── 실제 Safe(v1.4.1) — 트레저리 규칙·소유 증명 ─────────────────────────

    /// @dev Safe v1.4.1 공식 배포 주소 (Base 메인넷·Sepolia 동일, safe-deployments).
    address internal constant SAFE_PROXY_FACTORY = 0x4e1DCf7AD4e460CfD30791CCC4F9c8a4f820ec67;
    address internal constant SAFE_L2_SINGLETON = 0x29fcB43b46531BcA003ddC8FCB67FFE91900C762;
    address internal constant SAFE_FALLBACK_HANDLER = 0xfd0732Dc9E303f09fCEf3a7388Ad10A83459Ec99;

    function _safeInitializer(uint256 threshold, uint256 ownerCount) internal returns (bytes memory) {
        address[] memory owners = new address[](ownerCount);
        for (uint256 i; i < ownerCount; ++i) {
            owners[i] = makeAddr(string.concat("fork-safe-owner-", vm.toString(i)));
        }
        return abi.encodeWithSignature(
            "setup(address[],uint256,address,bytes,address,address,uint256,address)",
            owners,
            threshold,
            address(0),
            "",
            SAFE_FALLBACK_HANDLER,
            address(0),
            0,
            address(0)
        );
    }

    function _createSafe(bytes memory initializer, uint256 saltNonce) internal returns (address) {
        return
            IDeployForkSafeProxyFactory(SAFE_PROXY_FACTORY)
                .createProxyWithNonce(SAFE_L2_SINGLETON, initializer, saltNonce);
    }

    /// @dev SafeProxyFactory.createProxyWithNonce가 만들 CREATE2 주소 (다른 체인에서 쓰던 Safe 주소와 같은 방식).
    function _predictSafe(bytes memory initializer, uint256 saltNonce) internal view returns (address) {
        bytes memory creationCode = IDeployForkSafeProxyFactory(SAFE_PROXY_FACTORY).proxyCreationCode();
        bytes32 salt = keccak256(abi.encodePacked(keccak256(initializer), saltNonce));
        bytes32 initCodeHash = keccak256(abi.encodePacked(creationCode, uint256(uint160(SAFE_L2_SINGLETON))));
        return vm.computeCreate2Address(salt, initCodeHash, SAFE_PROXY_FACTORY);
    }

    /**
     * @dev 실제 Safe 프록시로 검증:
     *      1) 메인넷 TREASURY_SAFE는 2-of-3 이상: 실제 1-of-1 Safe는 거부(임계값·소유자 수를 실제 Safe에서 읽음).
     *      2) 다른 체인에만 있는(Base에는 아직 없는) Safe 주소를 BENEFICIARY로 넣으면 코드가 없으므로 EOA 서명을
     *         요구 → 아무도 만들 수 없으므로 배포가 막힘(2억 FIRE 영구 동결 방지).
     *      3) 같은 Safe를 Base에 실제로 배포하면 서명 없이 통과하고 베스팅 owner가 그 Safe가 됨.
     */
    function test_Fork_RealSafe_TreasuryRuleAndCounterfactualBeneficiary() public onlyFork {
        address deployer = _deployerFor(false);
        vm.deal(deployer, 10 ether);
        Deploy.DeployConfig memory cfg = _launchCfg();

        address weak = _createSafe(_safeInitializer(1, 1), 1);
        cfg.treasurySafe = weak;
        vm.expectRevert(abi.encodeWithSelector(Deploy.DeployTreasurySafeTooWeak.selector, weak, 1, 1));
        deployScript.deploy(cfg, deployer);

        cfg.treasurySafe = _createSafe(_safeInitializer(2, 3), 2);
        bytes memory beneficiarySafeInit = _safeInitializer(2, 3);
        address counterfactual = _predictSafe(beneficiarySafeInit, 7);
        assertEq(counterfactual.code.length, 0);
        cfg.beneficiary = counterfactual;
        cfg.beneficiaryProof = "";
        vm.expectRevert(
            abi.encodeWithSelector(
                Deploy.DeployProofMissing.selector,
                "BENEFICIARY_PROOF_SIG",
                string.concat(
                    "FIRE launch control proof | role=BENEFICIARY | address=",
                    vm.toString(counterfactual),
                    " | chainId=8453"
                )
            )
        );
        deployScript.deploy(cfg, deployer);
        assertEq(vm.getNonce(deployer), 0);

        assertEq(_createSafe(beneficiarySafeInit, 7), counterfactual);
        // 실제 Safe가 생긴 뒤에는 그 Safe 소유자 2명이 같은 메시지에 각자 서명해야 함 (임계값 2)
        cfg.beneficiaryProof = _safeOwnerProof("BENEFICIARY", counterfactual, 2);
        Deploy.DeployResult memory d = deployScript.deploy(cfg, deployer);
        assertEq(FireVesting(payable(d.vesting)).owner(), counterfactual);
        assertEq(FireToken(d.token).balanceOf(cfg.treasurySafe), 50_000_000e18);
    }

    /// @dev _safeInitializer가 만든 Safe의 소유자(fork-safe-owner-0..) 중 앞의 count명이 소유 증명 메시지에 서명해 이어 붙임.
    function _safeOwnerProof(string memory role, address safe, uint256 count) internal returns (bytes memory proof) {
        for (uint256 i; i < count; ++i) {
            (, uint256 key) = makeAddrAndKey(string.concat("fork-safe-owner-", vm.toString(i)));
            proof = bytes.concat(proof, _controlProof(key, role, safe));
        }
    }

    /// @dev 토큰이 없는 주소로 두 등급 풀을 만들고 가격 1(틱 0)에서 [0, spacing] 범위에 WETH만 예치.
    function _preemptBothTiers(address predicted) internal returns (address[2] memory pools) {
        address griefer = makeAddr("preempt-griefer");
        vm.deal(griefer, 1 ether);
        vm.startPrank(griefer);
        IWETH9(WETH).deposit{value: 0.01 ether}();
        IWETH9(WETH).approve(NPM, type(uint256).max);
        uint24[2] memory fees = [uint24(10_000), uint24(3000)];
        for (uint256 i; i < 2; ++i) {
            pools[i] = npm.createAndInitializePoolIfNecessary(WETH, predicted, fees[i], uint160(1 << 96));
            npm.mint(
                INonfungiblePositionManager.MintParams({
                    token0: WETH,
                    token1: predicted,
                    fee: fees[i],
                    tickLower: 0,
                    tickUpper: IUniswapV3Factory(FACTORY).feeAmountTickSpacing(fees[i]),
                    amount0Desired: 1e12,
                    amount1Desired: 0,
                    amount0Min: 0,
                    amount1Min: 0,
                    recipient: griefer,
                    deadline: block.timestamp
                })
            );
            assertGt(IUniswapV3Pool(pools[i]).liquidity(), 0);
        }
        vm.stopPrank();
    }

    // ───────────────────────── 가드 ─────────────────────────

    function test_Fork_Guards() public onlyFork {
        Deploy.DeployResult memory d = _launch(false);
        CreatePool.PoolConfig memory cfg = _cfg(d.token, 10_000);

        cfg.mainnetConfirmed = false;
        vm.expectRevert(LaunchBase.LaunchMainnetNotConfirmed.selector);
        poolScript.createPool(cfg, d.deployer);

        cfg = _cfg(d.token, 500);
        vm.expectRevert(abi.encodeWithSelector(CreatePool.CreatePoolUnsupportedFeeTier.selector, uint24(500)));
        poolScript.createPool(cfg, d.deployer);

        cfg = _cfg(d.token, 10_000);
        cfg.slippageBps = 0;
        vm.expectRevert(abi.encodeWithSelector(CreatePool.CreatePoolInvalidSlippage.selector, 0));
        poolScript.createPool(cfg, d.deployer);
        cfg.slippageBps = 101;
        vm.expectRevert(abi.encodeWithSelector(CreatePool.CreatePoolInvalidSlippage.selector, 101));
        poolScript.createPool(cfg, d.deployer);

        cfg = _cfg(d.token, 10_000);
        cfg.seedEth = 3; // "3 ETH"를 wei로 착각한 경우
        vm.expectRevert(abi.encodeWithSelector(CreatePool.CreatePoolSeedEthTooLow.selector, 3, 1 ether));
        poolScript.createPool(cfg, d.deployer);

        cfg = _cfg(d.token, 10_000);
        cfg.lpFireAmount = 600_000_000e18; // 메인넷은 공개 토크노믹스(7억)와 정확히 일치해야 함
        vm.expectRevert(abi.encodeWithSelector(CreatePool.CreatePoolInvalidFireAmount.selector, 600_000_000e18));
        poolScript.createPool(cfg, d.deployer);

        cfg = _cfg(d.token, 10_000);
        cfg.seedEth = 20 ether;
        vm.expectRevert(abi.encodeWithSelector(CreatePool.CreatePoolInsufficientEth.selector, 10 ether, 20 ether));
        poolScript.createPool(cfg, d.deployer);

        cfg = _cfg(WETH, 10_000);
        vm.expectRevert(abi.encodeWithSelector(CreatePool.CreatePoolNotFireToken.selector, WETH));
        poolScript.createPool(cfg, d.deployer);

        cfg = _cfg(USDC, 10_000); // 코드가 있는 다른 ERC20
        vm.expectRevert(abi.encodeWithSelector(CreatePool.CreatePoolNotFireToken.selector, USDC));
        poolScript.createPool(cfg, d.deployer);

        cfg = _cfg(makeAddr("no-code"), 10_000);
        vm.expectRevert(abi.encodeWithSelector(CreatePool.CreatePoolMissingCode.selector, cfg.fireToken));
        poolScript.createPool(cfg, d.deployer);

        // 배포자가 7억을 다 갖고 있지 않으면 중단
        vm.prank(d.deployer);
        assertTrue(FireToken(d.token).transfer(airdrop, 1));
        vm.expectRevert(abi.encodeWithSelector(CreatePool.CreatePoolInsufficientFire.selector, LP_FIRE - 1, LP_FIRE));
        poolScript.createPool(_cfg(d.token, 10_000), d.deployer);
    }

    /// @dev 주소표와 실제 NPM이 다르면 전송 전에 중단.
    function test_Fork_RevertWhen_PositionManagerMismatch() public onlyFork {
        Deploy.DeployResult memory d = _launch(false);
        vm.mockCall(
            NPM, abi.encodeWithSelector(INonfungiblePositionManager.factory.selector), abi.encode(address(0xdead))
        );
        vm.expectRevert(
            abi.encodeWithSelector(CreatePool.CreatePoolPositionManagerMismatch.selector, address(0xdead), WETH)
        );
        poolScript.createPool(_cfg(d.token, 10_000), d.deployer);
    }

    /// @dev 팩토리의 tickSpacing이 예상(1% → 200)과 다르면 전송 전에 중단.
    function test_Fork_RevertWhen_TickSpacingMismatch() public onlyFork {
        Deploy.DeployResult memory d = _launch(false);
        vm.mockCall(
            FACTORY, abi.encodeCall(IUniswapV3Factory.feeAmountTickSpacing, (uint24(10_000))), abi.encode(int24(100))
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                CreatePool.CreatePoolTickSpacingMismatch.selector, uint24(10_000), int24(200), int24(100)
            )
        );
        poolScript.createPool(_cfg(d.token, 10_000), d.deployer);
    }

    /// @dev 시뮬레이션 사후 조건이 변조·이상값을 잡아내는지 (가스 상한 포함).
    function test_Fork_PostConditionsSeeTampering() public onlyFork {
        Created memory c = _createAndAssert(false, 10_000);
        poolScript.checkPostConditions(c.plan, c.res);

        uint256 gasUsed = c.res.multicallGas;
        c.res.multicallGas = 13_000_000;
        vm.expectRevert(
            abi.encodeWithSelector(
                CreatePool.CreatePoolGasAboveCap.selector, (13_000_000 + 100_000) * 130 / 100, LaunchParams.TX_GAS_CAP
            )
        );
        poolScript.checkPostConditions(c.plan, c.res);
        c.res.multicallGas = gasUsed;

        c.res.liquidity += 1;
        _expectPostFailure(c, "position liquidity");
        c.res.liquidity -= 1;
        c.res.sqrtPriceX96 += 1;
        _expectPostFailure(c, "pool price moved during creation");
        c.res.sqrtPriceX96 -= 1;
        c.res.amount1 = 0;
        _expectPostFailure(c, "amounts below minimum");
        c.res.amount1 = c.plan.fireIsToken0 ? c.res.ethUsed : c.res.fireUsed;

        vm.prank(c.d.deployer);
        assertTrue(FireToken(c.d.token).approve(NPM, 1));
        _expectPostFailure(c, "leftover allowance");
    }

    function _expectPostFailure(Created memory c, string memory check) internal {
        vm.expectRevert(abi.encodeWithSelector(CreatePool.CreatePoolPostConditionFailed.selector, check));
        poolScript.checkPostConditions(c.plan, c.res);
    }

    /// @dev CreatePool.run()을 가짜 환경으로 실행: 드라이런은 기록 파일을 건드리지 않고 pending JSON만 출력.
    function test_Fork_CreatePoolRun_DryRunDoesNotWriteRecord() public onlyFork {
        Deploy.DeployResult memory d = _launchWith(DEFAULT_SENDER);
        string memory path = _tmpPath("run-dry");
        vm.writeJson(deployScript.recordJson(d), path);
        harness.setPaths(path, _tmpPath("run-dry-permit"));
        harness.setFakeEnv("CONFIRM_MAINNET", "I_UNDERSTAND");
        (CreatePool.PoolPlan memory plan, CreatePool.PoolResult memory res) = harness.run();
        string memory json = _readFile(path);
        _removeFile(path);
        assertEq(plan.broadcaster, DEFAULT_SENDER);
        assertEq(plan.fireToken, d.token);
        assertFalse(plan.usePermit);
        assertGt(res.liquidity, 0);
        assertFalse(vm.keyExistsJson(json, ".pool"));
    }

    // ───────────────────────── PostDeployCheck ─────────────────────────

    /// @dev 유동성 일부 회수(러그 신호)는 FAIL.
    function test_Fork_PostDeployCheck_FailsWhenLiquidityRemoved() public onlyFork {
        Created memory c = _createAndAssert(true, 10_000);
        PostDeployCheck.CheckInputs memory inputs = _checkInputs(c);
        assertEq(checker.check(inputs, false).failed, 0);

        vm.prank(c.d.deployer);
        npm.decreaseLiquidity(
            INonfungiblePositionManager.DecreaseLiquidityParams({
                tokenId: c.res.tokenId,
                liquidity: c.res.liquidity / 2,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp
            })
        );
        assertEq(checker.check(inputs, true).failed, 1);
    }

    /// @dev 잘못된·없는 LP NFT id, 남의 포지션, 유동성 증가, 락커가 아닌 보유자: 모두 revert 없이 보고.
    function test_Fork_PostDeployCheck_PositionBranches() public onlyFork {
        Created memory c = _createAndAssert(false, 10_000);
        PostDeployCheck.CheckInputs memory inputs = _checkInputs(c);
        PostDeployCheck.Report memory rep = checker.check(inputs, true);
        assertEq(rep.failed, 0);
        assertEq(rep.warned, 1); // 배포 지갑 보유(미락업)

        inputs.tokenId = c.res.tokenId + 1_000_000; // 없는 id: 예전에는 "Invalid token ID"로 보고서 없이 중단
        rep = checker.check(inputs, true);
        assertEq(rep.failed, 1);

        Deploy.DeployResult memory other = _launchWith(_deployerFrom(true, 700));
        (, CreatePool.PoolResult memory foreign) = poolScript.createPool(_cfg(other.token, 10_000), other.deployer);
        inputs.tokenId = foreign.tokenId; // 다른 토큰 쌍의 포지션
        rep = checker.check(inputs, true);
        assertEq(rep.failed, 1);

        inputs.tokenId = 0; // pending 기록: 배포 지갑에서 찾아 WARN
        rep = checker.check(inputs, true);
        assertEq(rep.failed, 0);
        assertEq(rep.warned, 2);

        inputs.tokenId = c.res.tokenId;
        inputs.recordedLiquidity = c.res.liquidity - 1; // 기록보다 유동성이 큼 → WARN
        rep = checker.check(inputs, false);
        assertEq(rep.failed, 0);
        assertEq(rep.warned, 2);
        inputs.recordedLiquidity = c.res.liquidity;

        address holder = address(new DeployForkLocker());
        vm.prank(c.d.deployer);
        npm.transferFrom(c.d.deployer, holder, c.res.tokenId); // LP_LOCKER 미지정 컨트랙트
        rep = checker.check(inputs, false);
        assertEq(rep.failed, 0);
        assertEq(rep.warned, 1);
        vm.prank(holder);
        npm.transferFrom(holder, makeAddr("some-eoa"), c.res.tokenId); // EOA
        rep = checker.check(inputs, false);
        assertEq(rep.failed, 0);
        assertEq(rep.warned, 1);
    }
    // ───────────────────────── LP 락업 (실제 UNCX V3.1) · confirmLock ─────────────────────────

    /// @dev UNCX Liquidity Locker V3.1 (Base). 포크 블록 52,317,000에서 getFee("DEFAULT") = lpFee 50 / collectFee 200 /
    ///      flatFee 0.1 ETH (cast call로 확인한 값).
    address internal constant UNCX_V3_LOCKER = 0x231278eDd38B00B07fBd52120CEf685B9BaEBCC1;

    function _lockAtUncx(address owner, uint256 tokenId) internal {
        vm.startPrank(owner);
        IDeployForkErc721(NPM).approve(UNCX_V3_LOCKER, tokenId);
        IDeployForkUncxLocker(UNCX_V3_LOCKER).lock{value: 0.1 ether}(
            IDeployForkUncxLocker.LockParams({
                nftPositionManager: NPM,
                nftId: tokenId,
                dustRecipient: owner,
                owner: owner,
                additionalCollector: address(0),
                collectAddress: owner,
                unlockDate: block.timestamp + 366 days,
                countryCode: 0,
                feeName: "DEFAULT",
                r: new bytes[](0)
            })
        );
        vm.stopPrank();
    }

    /// @dev pending → confirm까지 마친 기록 (mint/Initialize 이벤트 주입).
    function _confirmedRecord(bool fireIsToken0, string memory tag)
        internal
        returns (Created memory c, string memory path)
    {
        vm.recordLogs();
        c = _createAndAssert(fireIsToken0, 10_000);
        _injectLogs(vm.getRecordedLogs(), c.res.pool);
        path = _tmpPath(tag);
        _writePendingRecord(c.d, harness.pendingPoolJson(c.plan, c.res), path);
        deployScript.confirmRecord(path);
        harness.confirmRecord(path);
    }

    /**
     * @dev 리허설 B1 회귀 (실제 UNCX V3.1 락커): 락업 때 DEFAULT 수수료로 LP 유동성의 정확히 0.5%가 빠짐. 예전에는
     *      PostDeployCheck가 이를 "유동성 감소"로 FAIL 처리해 문서의 "락업 → PostDeployCheck RESULT: PASS" 단계에 도달할
     *      수 없었음. confirmLock()이 락업 후 유동성(.lpLock.liquidity)과 수수료(0.50%)를 기록하면 FAIL 0·WARN 0이 되고,
     *      운영자가 넣은 lpLock 키(lockTx 등)는 유지되며, 이후의 감소는 다시 FAIL.
     */
    function test_Fork_UncxLock_ConfirmLockRecordsPostLockBaseline() public onlyFork {
        (Created memory c, string memory path) = _confirmedRecord(false, "uncx-lock");
        vm.expectRevert(abi.encodeWithSelector(CreatePool.CreatePoolLpNotLocked.selector, c.res.tokenId, c.d.deployer));
        harness.confirmLockRecord(path); // 락업 전

        _lockAtUncx(c.d.deployer, c.res.tokenId);
        (, LaunchPositions.Position memory p) = LaunchPositions.read(npm, c.res.tokenId);
        assertEq(npm.ownerOf(c.res.tokenId), UNCX_V3_LOCKER); // 전체 범위라 같은 NFT id 그대로 보관
        assertEq(p.liquidity, c.res.liquidity - c.res.liquidity * 50 / 10_000);

        PostDeployCheck.CheckInputs memory inputs = checkHarness.loadInputs(path);
        inputs.lpLocker = UNCX_V3_LOCKER;
        assertEq(checkHarness.check(inputs, true).failed, 1); // 기준 미갱신: 0.50% 감소 FAIL (confirmLock 안내 포함)

        address wrongLocker = makeAddr("not-the-locker");
        harness.setFakeEnv("LP_LOCKER", vm.toString(wrongLocker));
        vm.expectRevert(
            abi.encodeWithSelector(CreatePool.CreatePoolLockerMismatch.selector, wrongLocker, UNCX_V3_LOCKER)
        );
        harness.confirmLockRecord(path);

        vm.writeJson('"0x1111111111111111111111111111111111111111111111111111111111111111"', path, ".lpLock.lockTx");
        harness.setFakeEnv("LP_LOCKER", vm.toString(UNCX_V3_LOCKER));
        CreatePool.LockConfirmed memory l = harness.confirmLockRecord(path);
        assertEq(l.tokenId, c.res.tokenId);
        assertEq(l.locker, UNCX_V3_LOCKER);
        assertEq(l.liquidityBefore, c.res.liquidity);
        assertEq(l.liquidityAfter, p.liquidity);
        assertEq(l.lockFeeBps, 50);
        string memory json = _readFile(path);
        assertEq(vm.parseJsonAddress(json, ".lpLock.locker"), UNCX_V3_LOCKER);
        assertEq(vm.parseJsonUint(json, ".lpLock.liquidity"), p.liquidity);
        assertEq(vm.parseJsonUint(json, ".lpLock.lockFeeBps"), 50);
        assertEq(vm.parseJsonUint(json, ".pool.liquidity"), c.res.liquidity); // 생성 시점 값은 그대로 공개
        assertEq(
            vm.parseJsonBytes32(json, ".lpLock.lockTx"),
            0x1111111111111111111111111111111111111111111111111111111111111111
        );

        harness.setFakeEnv("LP_LOCKER", "");
        inputs = checkHarness.loadInputs(path); // LP_LOCKER 없이 기록의 lpLock.locker 사용
        assertEq(inputs.lpLocker, UNCX_V3_LOCKER);
        assertEq(inputs.lockLiquidity, p.liquidity);
        PostDeployCheck.Report memory rep = checkHarness.check(inputs, true);
        assertEq(rep.failed, 0);
        assertEq(rep.warned, 0);

        // 락업 후의 감소는 다시 FAIL (락커 계약이 유동성을 줄였다고 가정)
        vm.prank(UNCX_V3_LOCKER);
        npm.decreaseLiquidity(
            INonfungiblePositionManager.DecreaseLiquidityParams({
                tokenId: c.res.tokenId, liquidity: 1, amount0Min: 0, amount1Min: 0, deadline: block.timestamp
            })
        );
        assertEq(checkHarness.check(inputs, false).failed, 1);
        // confirmLock을 다시 실행해도 락업 후 기준을 낮춰 그 감소를 덮을 수 없음 (같으면 다시 실행해도 됨)
        vm.expectRevert(
            abi.encodeWithSelector(CreatePool.CreatePoolLockBaselineDecreased.selector, p.liquidity, p.liquidity - 1)
        );
        harness.confirmLockRecord(path);
        _removeFile(path);
    }

    /// @dev confirmLock은 락커 수수료 상한(1%)을 넘는 감소를 락업 수수료로 기록하지 않음. 보유자가 EOA여도 거부.
    function test_Fork_ConfirmLock_RejectsLargeDecreaseOrNonContractHolder() public onlyFork {
        (Created memory c, string memory path) = _confirmedRecord(true, "lock-too-much");
        address locker = address(new DeployForkLocker());
        vm.prank(c.d.deployer);
        npm.transferFrom(c.d.deployer, locker, c.res.tokenId);
        vm.prank(locker);
        npm.decreaseLiquidity(
            INonfungiblePositionManager.DecreaseLiquidityParams({
                tokenId: c.res.tokenId,
                liquidity: c.res.liquidity / 50, // 2%
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp
            })
        );
        vm.expectRevert(abi.encodeWithSelector(CreatePool.CreatePoolLockFeeTooHigh.selector, 200, 100));
        harness.confirmLockRecord(path);

        address eoa = makeAddr("eoa-holder");
        vm.prank(locker);
        npm.transferFrom(locker, eoa, c.res.tokenId);
        vm.expectRevert(abi.encodeWithSelector(CreatePool.CreatePoolLpNotLocked.selector, c.res.tokenId, eoa));
        harness.confirmLockRecord(path);
        _removeFile(path);

        string memory unconfirmed = _tmpPath("lock-unconfirmed");
        _writePendingRecord(c.d, harness.pendingPoolJson(c.plan, c.res), unconfirmed);
        vm.expectRevert(abi.encodeWithSelector(CreatePool.CreatePoolRecordMissing.selector, unconfirmed));
        harness.confirmLockRecord(unconfirmed); // confirm() 전
        _removeFile(unconfirmed);
    }

    // ───────────────────────── 리뷰 F3: 배포 지갑으로 보낸 소액 포지션 ─────────────────────────

    /// @dev 누구나: 풀에서 FIRE 몇 wei를 사서 배포 지갑을 recipient로 전체 범위 소액 포지션을 발행(NPM.mint는 수령자 제한 없음).
    function _mintDustTo(Created memory c, address recipient) internal returns (uint256 tokenId) {
        address attacker = makeAddr("dust-attacker");
        vm.deal(attacker, 1 ether);
        DeployForkSwapper swapper = new DeployForkSwapper();
        vm.startPrank(attacker);
        IWETH9(WETH).deposit{value: 0.01 ether}();
        assertTrue(IWETH9(WETH).transfer(address(swapper), 1e9));
        vm.stopPrank();
        uint256 fireOut = swapper.swapExactInput(IUniswapV3Pool(c.res.pool), WETH, 1e9, attacker);
        vm.startPrank(attacker);
        IWETH9(WETH).approve(NPM, type(uint256).max);
        assertTrue(FireToken(c.d.token).approve(NPM, type(uint256).max));
        (tokenId,,,) = npm.mint(
            INonfungiblePositionManager.MintParams({
                token0: c.plan.token0,
                token1: c.plan.token1,
                fee: c.plan.fee,
                tickLower: c.plan.tickLower,
                tickUpper: c.plan.tickUpper,
                amount0Desired: c.plan.fireIsToken0 ? fireOut : 1e9,
                amount1Desired: c.plan.fireIsToken0 ? 1e9 : fireOut,
                amount0Min: 0,
                amount1Min: 0,
                recipient: recipient,
                deadline: block.timestamp
            })
        );
        vm.stopPrank();
    }

    /**
     * @dev 리뷰 PoC(F3) 회귀: 제3자가 배포 지갑으로 보낸 소액 FIRE/WETH 전체 범위 포지션은 런칭 포지션으로 쓰이지 않음.
     *      예전에는 PostDeployCheck(pending)가 "가장 최근 id"인 소액 포지션을 골라 점검했고, LP_TOKEN_ID로 그 id를 주면
     *      confirm()이 기록했으며, 그 소액 NFT를 락업하면 실제 7억 LP를 회수해도 PASS였음.
     */
    function test_Fork_DustPositionsCannotStandInForTheLaunchLp() public onlyFork {
        vm.recordLogs();
        Created memory c = _createAndAssert(false, 10_000);
        _injectLogs(vm.getRecordedLogs(), c.res.pool);
        string memory path = _tmpPath("dust");
        _writePendingRecord(c.d, harness.pendingPoolJson(c.plan, c.res), path);
        uint256 dustId = _mintDustTo(c, c.d.deployer);
        assertGt(dustId, c.res.tokenId);
        assertEq(npm.ownerOf(dustId), c.d.deployer);

        // pending 기록의 PostDeployCheck: 런칭 크기 포지션(실제 LP)을 골라 점검 (소액 포지션 무시)
        PostDeployCheck.CheckInputs memory inputs = checkHarness.loadInputs(path);
        assertEq(checkHarness.check(inputs, true).failed, 0);

        CreatePool.Confirmed memory conf = harness.confirmRecord(path);
        assertEq(conf.tokenId, c.res.tokenId);
        (, LaunchPositions.Position memory dust) = LaunchPositions.read(npm, dustId);
        assertLt(uint256(dust.liquidity) * 1e6, conf.minLiquidity);

        harness.setFakeEnv("LP_TOKEN_ID", vm.toString(dustId));
        vm.expectRevert(
            abi.encodeWithSelector(
                CreatePool.CreatePoolPositionBelowPlan.selector, dustId, dust.liquidity, conf.minLiquidity
            )
        );
        harness.confirmRecord(path);
        harness.setFakeEnv("LP_TOKEN_ID", "");

        // 기록(또는 LP_TOKEN_ID)이 소액 포지션을 가리키고 그것을 락커에 넣어도 PostDeployCheck는 FAIL
        deployScript.confirmRecord(path);
        inputs = checkHarness.loadInputs(path);
        address locker = address(new DeployForkLocker());
        vm.prank(c.d.deployer);
        npm.transferFrom(c.d.deployer, locker, dustId);
        inputs.tokenId = dustId;
        inputs.lpLocker = locker;
        assertGe(checkHarness.check(inputs, true).failed, 1); // 런칭 크기 미달

        // 실제 런칭 LP를 회수하면 (기록된 id로) FAIL
        inputs.tokenId = c.res.tokenId;
        vm.prank(c.d.deployer);
        npm.decreaseLiquidity(
            INonfungiblePositionManager.DecreaseLiquidityParams({
                tokenId: c.res.tokenId,
                liquidity: c.res.liquidity,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp
            })
        );
        assertGe(checkHarness.check(inputs, true).failed, 2); // 유동성 감소 + 런칭 크기 미달 (+ 락커 아님)
        _removeFile(path);
    }

    /// @dev 리뷰 PoC(F3) 회귀: 소액 NFT를 탐색 한도(100개) 이상 보내도 런칭 포지션(배포 지갑의 첫 NFT)은 밀려나지 않음.
    function test_Fork_ManyDustPositionsDoNotHideTheLaunchLp() public onlyFork {
        vm.recordLogs();
        Created memory c = _createAndAssert(true, 10_000);
        _injectLogs(vm.getRecordedLogs(), c.res.pool);
        string memory path = _tmpPath("dust-many");
        _writePendingRecord(c.d, harness.pendingPoolJson(c.plan, c.res), path);
        for (uint256 i; i < LaunchParams.MAX_POSITION_SCAN + 5; ++i) {
            _mintDustTo(c, c.d.deployer);
        }
        assertEq(npm.balanceOf(c.d.deployer), LaunchParams.MAX_POSITION_SCAN + 6);
        CreatePool.Confirmed memory conf = harness.confirmRecord(path);
        _removeFile(path);
        assertEq(conf.tokenId, c.res.tokenId);
    }

    /**
     * @dev 런칭 전에(배포 지갑 주소는 자금을 받을 때부터 공개) 제3자가 다른 풀의 NFT를 탐색 한도만큼 배포 지갑으로 보내 두면
     *      런칭 포지션이 탐색 범위(가장 오래된 100개) 밖에 놓임. confirm()은 다른 포지션을 고르지 않고 보유 NFT 수와 함께
     *      중단하며, LP_TOKEN_ID로 지정하면 같은 런칭 크기 검사를 거쳐 확정됨. PostDeployCheck(pending)도 FAIL 후 안내.
     */
    function test_Fork_PreLaunchNftFloodNeedsLpTokenId() public onlyFork {
        address deployer = _deployerFrom(false, 1000);
        _mintForeignNftsTo(deployer, LaunchParams.MAX_POSITION_SCAN);
        assertEq(npm.balanceOf(deployer), LaunchParams.MAX_POSITION_SCAN);

        vm.recordLogs();
        Deploy.DeployResult memory d = _launchWith(deployer);
        (CreatePool.PoolPlan memory plan, CreatePool.PoolResult memory res) =
            poolScript.createPool(_cfg(d.token, 10_000), deployer);
        _injectLogs(vm.getRecordedLogs(), res.pool);
        uint256 held = LaunchParams.MAX_POSITION_SCAN + 1;
        assertEq(npm.balanceOf(deployer), held);
        assertEq(npm.tokenOfOwnerByIndex(deployer, held - 1), res.tokenId); // 탐색 범위 밖

        string memory path = _tmpPath("nft-flood");
        _writePendingRecord(d, harness.pendingPoolJson(plan, res), path);
        PostDeployCheck.Report memory rep = checkHarness.check(checkHarness.loadInputs(path), true);
        assertGe(rep.failed, 1); // 런칭 포지션을 찾지 못함 (다른 포지션으로 대신하지 않음)
        vm.expectRevert(abi.encodeWithSelector(CreatePool.CreatePoolPositionNotFound.selector, deployer, held));
        harness.confirmRecord(path);

        harness.setFakeEnv("LP_TOKEN_ID", vm.toString(res.tokenId));
        CreatePool.Confirmed memory conf = harness.confirmRecord(path);
        harness.setFakeEnv("LP_TOKEN_ID", "");
        assertEq(conf.tokenId, res.tokenId);
        assertEq(conf.liquidity, res.liquidity);
        assertTrue(conf.mintFound);

        // 확정된 기록은 그 id를 직접 점검하므로 탐색 한도와 무관하게 통과
        deployScript.confirmRecord(path);
        rep = checkHarness.check(checkHarness.loadInputs(path), true);
        _removeFile(path);
        assertEq(rep.failed, 0);
    }

    /// @dev 제3자가 만든 별도 풀(FIRE와 무관한 토큰 2개)의 소액 전체 범위 포지션 NFT를 recipient에게 count개 발행.
    function _mintForeignNftsTo(address recipient, uint256 count) internal {
        address attacker = makeAddr("nft-flooder");
        vm.startPrank(attacker);
        address tokenA = address(new DeployForkPoisonFire(attacker));
        address tokenB = address(new DeployForkPoisonFire(attacker));
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        address pool = IUniswapV3Factory(FACTORY).createPool(token0, token1, 10_000);
        IUniswapV3Pool(pool).initialize(uint160(PoolMath.Q96));
        assertTrue(IERC20(token0).approve(NPM, type(uint256).max));
        assertTrue(IERC20(token1).approve(NPM, type(uint256).max));
        (int24 tickLower, int24 tickUpper) = PoolMath.fullRangeTicks(200);
        for (uint256 i; i < count; ++i) {
            npm.mint(
                INonfungiblePositionManager.MintParams({
                    token0: token0,
                    token1: token1,
                    fee: 10_000,
                    tickLower: tickLower,
                    tickUpper: tickUpper,
                    amount0Desired: 1e9,
                    amount1Desired: 1e9,
                    amount0Min: 0,
                    amount1Min: 0,
                    recipient: recipient,
                    deadline: block.timestamp
                })
            );
        }
        vm.stopPrank();
    }

    /// @dev confirm()이 찾은 mint 이벤트의 예치량·유동성이 기록 계획의 하한보다 작으면 런칭 multicall의 mint가 아님 → 중단.
    function test_Fork_Confirm_RejectsMintEventBelowPlan() public onlyFork {
        Created memory c = _createAndAssert(false, 10_000);
        string memory path = _tmpPath("mint-below-plan");
        _writePendingRecord(c.d, harness.pendingPoolJson(c.plan, c.res), path);
        harness.setMintLog(abi.encode(c.res.liquidity, uint256(1), uint256(1)), keccak256("fake-mint"), 1);
        uint256 minLiquidity = harness.launchMinLiquidity(harness.recordedPool(_readFile(path)));
        vm.expectRevert(
            abi.encodeWithSelector(
                CreatePool.CreatePoolPositionBelowPlan.selector, c.res.tokenId, c.res.liquidity, minLiquidity
            )
        );
        harness.confirmRecord(path);
        _removeFile(path);
    }

    // ───────────────────────── 리뷰 F2: 배포 지갑이 만들지 않은 "FIRE" ─────────────────────────

    /**
     * @dev 리뷰 PoC(F2) 회귀: 기록 없이 FIRE_TOKEN만으로는 메인넷에서 실행되지 않고, 배포 지갑이 만들지 않은 토큰(다른 사람이
     *      만든 바이트코드 복제 FIRE를 배포 지갑에 7억 보낸 경우)이나 FireToken 고유 상수가 없는 가짜 "Fire"에는 시딩하지 않음.
     *      예전에는 가짜 토큰 풀에 3 ETH가 들어가 공격자가 WETH를 거의 전부 가져갈 수 있었음.
     */
    function test_Fork_RevertWhen_FireTokenNotFromTheDeployer() public onlyFork {
        Deploy.DeployResult memory d = _launch(false);
        string memory path = _tmpPath("no-record");
        harness.setPaths(path, "");
        harness.setFakeEnv("FIRE_TOKEN", vm.toString(d.token));
        harness.setFakeEnv("CONFIRM_MAINNET", "I_UNDERSTAND");
        vm.expectRevert(abi.encodeWithSelector(CreatePool.CreatePoolLaunchRecordRequired.selector, path));
        harness.loadConfig(path);

        address attacker = makeAddr("clone-attacker");
        vm.startPrank(attacker);
        FireToken clone = new FireToken(address(new FireVesting(attacker, 180 days, 540 days)));
        assertTrue(clone.transfer(d.deployer, LP_FIRE));
        vm.stopPrank();
        vm.expectRevert(
            abi.encodeWithSelector(CreatePool.CreatePoolTokenNotFromBroadcaster.selector, address(clone), d.deployer)
        );
        poolScript.createPool(_cfg(address(clone), 10_000), d.deployer);

        DeployForkPoisonFire poison = new DeployForkPoisonFire(d.deployer);
        vm.expectRevert(abi.encodeWithSelector(CreatePool.CreatePoolNotFireToken.selector, address(poison)));
        poolScript.createPool(_cfg(address(poison), 10_000), d.deployer);
        assertEq(d.deployer.balance, 10 ether); // 아무것도 전송되지 않음
    }

    // ───────────────────────── 리뷰 F6: Safe 모듈 · Safe 수령 주소의 소유 증명 ─────────────────────────

    /**
     * @dev 리뷰 PoC(F6) 회귀 (실제 Safe v1.4.1): 모듈이 활성화된 2-of-3 Safe는 모듈 키 하나로 서명 없이 5,000만 FIRE를 옮길
     *      수 있으므로 메인넷 트레저리로 거부. 다른 사람이 소유한 Safe를 BENEFICIARY로 붙여 넣으면 서명이 없거나(Missing)
     *      운영자 키의 서명(WrongSigner)으로는 통과하지 못하고, 그 Safe 소유자들의 서명이 있어야만 통과.
     */
    function test_Fork_RealSafe_ModulesAndOwnerProofs() public onlyFork {
        address deployer = _deployerFrom(false, 900);
        vm.deal(deployer, 10 ether);
        Deploy.DeployConfig memory cfg = _launchCfg();
        address moduleSafe = _createSafe(_safeInitializer(2, 3), 21);
        address moduleKey = makeAddr("single-module-key");
        vm.prank(moduleSafe);
        IDeployForkSafeModules(moduleSafe).enableModule(moduleKey);
        cfg.treasurySafe = moduleSafe;
        vm.expectRevert(abi.encodeWithSelector(Deploy.DeployTreasurySafeHasModules.selector, moduleSafe));
        deployScript.deploy(cfg, deployer);

        cfg = _launchCfg();
        address otherSafe = _createSafe(_safeInitializer(2, 3), 22);
        cfg.beneficiary = otherSafe;
        cfg.beneficiaryProof = "";
        vm.expectPartialRevert(Deploy.DeployProofMissing.selector);
        deployScript.deploy(cfg, deployer);
        cfg.beneficiaryProof = _controlProof(beneficiaryKey, "BENEFICIARY", otherSafe); // 운영자 키 (소유자 아님)
        vm.expectRevert(
            abi.encodeWithSelector(
                Deploy.DeployProofWrongSigner.selector, "BENEFICIARY_PROOF_SIG", otherSafe, beneficiary
            )
        );
        deployScript.deploy(cfg, deployer);
        assertEq(vm.getNonce(deployer), 0);

        cfg.beneficiaryProof = _safeOwnerProof("BENEFICIARY", otherSafe, 2);
        Deploy.DeployResult memory d = deployScript.deploy(cfg, deployer);
        assertEq(FireVesting(payable(d.vesting)).owner(), otherSafe);
    }
}

/**
 * @title Base Sepolia 주소표 포크 테스트
 * @dev BASE_SEPOLIA_RPC_URL이 비어 있으면 건너뜀. 예: BASE_SEPOLIA_RPC_URL=https://sepolia.base.org forge test
 *      포크 블록은 기본으로 고정(BASE_SEPOLIA_FORK_BLOCK으로 변경, 0이면 최신 블록).
 */
contract DeploySepoliaForkTest is Test {
    uint256 internal constant DEFAULT_SEPOLIA_FORK_BLOCK = 47_829_000;

    bool internal forked;

    function setUp() public {
        string memory rpc = vm.envOr("BASE_SEPOLIA_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return;
        uint256 forkBlock = vm.envOr("BASE_SEPOLIA_FORK_BLOCK", DEFAULT_SEPOLIA_FORK_BLOCK);
        if (forkBlock == 0) vm.createSelectFork(rpc);
        else vm.createSelectFork(rpc, forkBlock);
        forked = true;
    }

    function test_ForkSepolia_AddressTableMatchesChain() public {
        if (!forked) vm.skip(true);
        assertEq(block.chainid, 84_532);
        UniswapV3Addresses.Deployment memory uni = UniswapV3Addresses.forChain(84_532);
        assertGt(uni.factory.code.length, 0);
        assertGt(uni.positionManager.code.length, 0);
        assertGt(uni.weth.code.length, 0);
        INonfungiblePositionManager npm = INonfungiblePositionManager(uni.positionManager);
        assertEq(npm.factory(), uni.factory);
        assertEq(npm.WETH9(), uni.weth);
        assertEq(IUniswapV3Factory(uni.factory).feeAmountTickSpacing(10_000), 200);
        assertEq(IUniswapV3Factory(uni.factory).feeAmountTickSpacing(3000), 60);
    }
}
