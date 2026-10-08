// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {console} from "forge-std/console.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {IERC5267} from "@openzeppelin/contracts/interfaces/IERC5267.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {LaunchBase} from "./lib/LaunchBase.sol";
import {LaunchGuards} from "./lib/LaunchGuards.sol";
import {LaunchParams} from "./lib/LaunchParams.sol";
import {LaunchPositions} from "./lib/LaunchPositions.sol";
import {PoolMath} from "./lib/PoolMath.sol";
import {UniswapV3Addresses} from "./lib/UniswapV3Addresses.sol";
import {INonfungiblePositionManager, IUniswapV3Factory, IUniswapV3Pool} from "./lib/IUniswapV3.sol";

/**
 * @title CreatePool — FIRE/WETH Uniswap V3 풀 생성 + 전체 범위 포지션 (가이드 2.3절, 5장)
 * @notice 환경 변수: FIRE_TOKEN (없으면 deployments/<chainId>.json), SEED_ETH (wei, 기본 3 ether),
 *         LP_FIRE_AMOUNT (기본 7억 FIRE), FEE_TIER (10000 기본 / 3000), SLIPPAGE_BPS (기본 50), CONFIRM_MAINNET,
 *         PERMIT_SIGNATURE + PERMIT_DEADLINE (선택: 하드웨어 지갑으로 미리 서명한 permit, permitTypedData() 참고),
 *         LP_TOKEN_ID (confirm()용, 선택), LP_LOCKER (confirmLock()용, 선택).
 *         토큰 확인: FireToken 고유 상수(TOTAL_SUPPLY 10억·VESTING_SUPPLY 2억)와 함께, 토큰이 브로드캐스터(배포 지갑)가
 *         직접 만든 CREATE 주소인지 확인함(주소 오염용 가짜 "FIRE"에 시딩 ETH를 넣는 사고 방지). Base 메인넷은 Deploy가 쓴
 *         배포 기록(deployments/8453.json)이 반드시 있어야 하며, 기록의 토큰 = CREATE(deployer, deployerNonce + 1)이어야 함.
 * @dev 트랜잭션:
 *        1) NPM.multicall{value: SEED_ETH}([selfPermitIfNecessary, createAndInitializePoolIfNecessary, mint, refundETH])
 *           → 승인(EIP-2612 permit)·풀 생성·가격 초기화·유동성 공급·ETH 환불이 한 트랜잭션에서 원자적으로 일어남.
 *             초기화와 유동성 공급 사이에 누구도 거래할 수 없고, 사전 approve 트랜잭션이 "곧 풀 생성" 신호로
 *             노출되지도 않으며, multicall이 실패하면 승인도 함께 되돌려짐.
 *        2) FIRE.approve(NPM, 0) — 반올림으로 남은 승인 잔량을 항상 0으로 정리
 *      permit 서명을 만들 수 없으면(예: --ledger는 스크립트 안의 해시 서명을 지원하지 않음) 1) 앞에
 *      FIRE.approve(NPM, LP_FIRE_AMOUNT) 트랜잭션을 따로 보냄(경고 출력).
 *      포지션 NFT는 브로드캐스터(배포자)가 받으며, 이후 UNCX / Team Finance에서 365일 락업(수동).
 *      기록: forge는 시뮬레이션 후 전송하므로, --broadcast 실행은 계획 값만 담은 .pool을 status "pending"으로 씀.
 *      LP NFT id(Base 전체가 공유하는 카운터), 실제 유동성·예치량은 채굴 후 confirm()이 온체인에서 찾아 기록함.
 */
contract CreatePool is LaunchBase {
    /// @dev 시딩 ETH 외에 남겨 둘 가스 여유분(경고 기준). Base에서 이 스크립트 전체 가스비는 보통 0.0001 ETH 미만.
    uint256 public constant GAS_RESERVE = 0.002 ether;
    /// @dev EIP-2612 Permit 타입 해시 (OpenZeppelin ERC20Permit과 동일).
    bytes32 public constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
    bytes32 public constant EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    /// @dev NonfungiblePositionManager: IncreaseLiquidity(uint256 indexed tokenId, uint128, uint256, uint256)
    bytes32 public constant INCREASE_LIQUIDITY_TOPIC = keccak256("IncreaseLiquidity(uint256,uint128,uint256,uint256)");
    /// @dev UniswapV3Pool: Initialize(uint160 sqrtPriceX96, int24 tick)
    bytes32 public constant INITIALIZE_TOPIC = keccak256("Initialize(uint160,int24)");
    /// @dev permitTypedData()가 PERMIT_DEADLINE 미지정 시 쓰는 서명 유효 시간.
    uint256 public constant PERMIT_SIGNING_WINDOW = 1 hours;
    /// @dev 미리 받은 permit 서명(PERMIT_SIGNATURE)의 마감까지 최소 남은 시간. 이보다 짧으면 포함 전에 만료될 수 있음.
    uint256 public constant PERMIT_MIN_REMAINING = 5 minutes;

    struct PoolConfig {
        address fireToken;
        uint256 seedEth;
        uint256 lpFireAmount;
        uint24 feeTier;
        uint256 slippageBps;
        bool mainnetConfirmed;
        bytes permitSignature; // PERMIT_SIGNATURE (선택)
        uint256 permitDeadline; // PERMIT_DEADLINE (PERMIT_SIGNATURE와 함께, 또는 permitTypedData()용)
    }

    struct PoolPlan {
        address broadcaster;
        address factory;
        address positionManager;
        address weth;
        address fireToken;
        address token0;
        address token1;
        bool fireIsToken0;
        uint24 fee;
        int24 tickSpacing;
        int24 tickLower;
        int24 tickUpper;
        uint160 sqrtPriceX96;
        uint256 seedEth;
        uint256 lpFireAmount;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        uint256 slippageBps;
        address existingPool;
        uint160 existingSqrtPriceX96;
        uint256 deadline;
        bool usePermit;
        uint256 permitNonce;
        uint256 permitDeadline;
        uint8 permitV;
        bytes32 permitR;
        bytes32 permitS;
    }

    /// @notice 시뮬레이션 결과 (전송 전 값: tokenId 등은 실제 체인에서 달라질 수 있어 기록하지 않음).
    struct PoolResult {
        address pool;
        uint256 tokenId;
        uint128 liquidity;
        uint256 amount0;
        uint256 amount1;
        uint256 fireUsed;
        uint256 ethUsed;
        uint256 ethRefunded;
        uint160 sqrtPriceX96;
        int24 tick;
        uint256 multicallGas;
        uint256 blockNumber;
        uint256 blockTimestamp;
    }

    /// @notice 기록(.pool)에서 읽은 계획 값 — confirm()의 입력.
    struct RecordedPool {
        address pool;
        address factory;
        address positionManager;
        address fireToken;
        address token0;
        address token1;
        uint24 fee;
        uint256 seedEth;
        uint256 lpFireAmount;
        uint256 slippageBps;
        address positionOwner;
        uint256 fromBlock;
    }

    /// @notice confirm()이 온체인에서 확인한 실제 LP 포지션.
    struct Confirmed {
        address pool;
        uint256 tokenId;
        uint128 liquidity;
        address owner;
        bool mintFound;
        bytes32 mintTx;
        uint256 mintBlock;
        uint128 mintLiquidity;
        uint256 fireDeposited;
        uint256 ethDeposited;
        uint256 ethRefunded;
        bool initFound;
        uint160 initialSqrtPriceX96;
        int24 initialTick;
        uint256 minLiquidity; // 기록의 계획(투입량·슬리피지)에서 계산한 런칭 포지션 유동성 하한
    }

    /// @notice confirmLock()이 온체인에서 확인한 락업 상태 (deployments/<chainId>.json의 .lpLock).
    struct LockConfirmed {
        uint256 tokenId;
        address locker;
        uint256 liquidityBefore; // 기록된 pool.liquidity (confirm() 시점)
        uint256 liquidityAfter; // 락업 후 현재 유동성 = 이후 PostDeployCheck의 비교 기준
        uint256 lockFeeBps; // 락커가 락업 때 떼어 간 LP 비율 (올림, bp)
    }

    error CreatePoolMissingFireToken();
    error CreatePoolTokenSourceMismatch(address envToken, address recordToken);
    error CreatePoolMissingCode(address target);
    error CreatePoolPositionManagerMismatch(address factory, address weth);
    error CreatePoolNotFireToken(address token);
    error CreatePoolUnsupportedFeeTier(uint24 fee);
    error CreatePoolTickSpacingMismatch(uint24 fee, int24 expected, int24 actual);
    error CreatePoolInvalidSlippage(uint256 slippageBps);
    error CreatePoolSeedEthTooLow(uint256 seedEth, uint256 minimum);
    error CreatePoolInvalidFireAmount(uint256 lpFireAmount);
    error CreatePoolInsufficientFire(uint256 balance, uint256 required);
    error CreatePoolInsufficientEth(uint256 balance, uint256 required);
    error CreatePoolPoolHasLiquidity(address pool, uint128 liquidity);
    error CreatePoolExistingPoolPriceMismatch(address pool, uint256 deviationBps);
    error CreatePoolExistingPoolPriceBeyondSlippage(address pool, uint256 deviationBps, uint256 slippageBps);
    error CreatePoolGasAboveCap(uint256 gasUsed, uint256 cap);
    error CreatePoolPostConditionFailed(string check);
    error CreatePoolPermitExpired(uint256 deadline);
    error CreatePoolBadPermitSignature(address recovered);
    error CreatePoolPermitOwnerUnknown();
    error CreatePoolRecordMissing(string path);
    error CreatePoolRecordMismatch(string check);
    error CreatePoolPositionNotFound(address owner, uint256 nftsHeld);
    error CreatePoolAmbiguousPosition(address owner, uint256 matches);
    error CreatePoolNotLaunchPosition(uint256 tokenId);
    error CreatePoolPositionBelowPlan(uint256 tokenId, uint256 liquidity, uint256 minLiquidity);
    error CreatePoolLaunchRecordRequired(string path);
    error CreatePoolTokenNotFromBroadcaster(address token, address broadcaster);
    error CreatePoolBroadcasterHasCode(address broadcaster);
    error CreatePoolLpNotLocked(uint256 tokenId, address owner);
    error CreatePoolLockerMismatch(address expected, address actual);
    error CreatePoolLockFeeTooHigh(uint256 lockFeeBps, uint256 maxBps);
    error CreatePoolLockBaselineDecreased(uint256 recordedLiquidity, uint256 currentLiquidity);

    // ───────────────────────── 진입점 ─────────────────────────

    function run() external returns (PoolPlan memory plan, PoolResult memory result) {
        _requireSupportedChain(false);
        string memory path = deploymentPath(block.chainid);
        PoolConfig memory cfg = loadConfig(path);
        (plan, result) = createPool(cfg, address(0));
        string memory pending = pendingPoolJson(plan, result);
        if (_isBroadcastRun()) {
            writePoolRecord(pending, plan.fireToken, path);
            console.log("Pool record written to %s (key .pool, status: pending)", path);
        } else {
            console.log("Dry run: pool record NOT written (would be added to %s as .pool):", path);
            console.log(pending);
        }
        _logNextSteps(plan);
    }

    /**
     * @notice 트랜잭션이 채굴된 뒤 실행(서명·전송 없음): 실제 LP NFT id·유동성·예치량을 온체인에서 찾아 .pool을
     *         "confirmed"로 갱신. forge script script/CreatePool.s.sol:CreatePool --sig "confirm()" --rpc-url <별칭>
     *         이미 락업해 배포 지갑에 NFT가 없거나, 런칭 전에 배포 지갑으로 NFT가 100개 이상 들어와 런칭 포지션이 탐색
     *         범위(가장 오래된 100개) 밖에 있으면 LP_TOKEN_ID=<id>로 지정 (같은 런칭 크기 검사를 거침).
     */
    function confirm() external returns (Confirmed memory c) {
        _requireSupportedChain(false);
        c = confirmRecord(deploymentPath(block.chainid));
    }

    /**
     * @notice LP NFT를 락커로 옮긴 뒤 실행(서명·전송 없음): 락업 후 유동성을 PostDeployCheck의 새 비교 기준으로 기록.
     *         forge script script/CreatePool.s.sol:CreatePool --sig "confirmLock()" --rpc-url <별칭>   (선택: LP_LOCKER=<락커>)
     * @dev UNCX V3 락커는 락업 때 LP 유동성의 일부(Base 실측 DEFAULT 0.5%, LVP 0.8%, LLP 0.3%)를 수수료로 떼어 감
     *      (decreaseLiquidity). 기준을 갱신하지 않으면 PostDeployCheck가 이를 "유동성 감소"로 FAIL 처리하므로, 락업 직후
     *      이 단계를 실행해 .lpLock.locker / liquidity / lockFeeBps / confirmedAtBlock을 기록함(운영자가 넣은 lockTx·
     *      unlockDate·url 등 다른 키는 유지). 감소가 LaunchParams.MAX_LOCK_FEE_BPS(1%)를 넘으면 락커 수수료로 보지 않고 중단.
     */
    function confirmLock() external returns (LockConfirmed memory l) {
        _requireSupportedChain(false);
        l = confirmLockRecord(deploymentPath(block.chainid));
    }

    /**
     * @notice 하드웨어 지갑용 permit 서명 입력(EIP-712 JSON)을 deployments/permit-<chainId>.json에 씀(전송 없음).
     *         1) forge script script/CreatePool.s.sol:CreatePool --sig "permitTypedData()" --rpc-url <별칭> --sender $DEPLOYER
     *         2) cast wallet sign --ledger --data --from-file deployments/permit-<chainId>.json   → 65바이트 서명
     *         3) PERMIT_DEADLINE=<출력값> PERMIT_SIGNATURE=<서명>을 붙여 CreatePool --broadcast 실행
     * @dev 이 파일·서명에는 비밀 정보가 없음(승인 대상 NPM, 수량 LP_FIRE_AMOUNT). 커밋하지 말고 사용 후 지움.
     */
    function permitTypedData() external returns (string memory json) {
        _requireSupportedChain(false);
        address owner = _resolveBroadcaster(address(0));
        if (owner == DEFAULT_SENDER) {
            console.log("ABORT: pass --sender $DEPLOYER (the hardware wallet address that will sign the permit).");
            revert CreatePoolPermitOwnerUnknown();
        }
        json = permitTypedDataFor(owner);
    }

    /// @notice permitTypedData()의 본체: owner(배포 지갑)의 permit 서명 입력을 permitPath()에 씀.
    function permitTypedDataFor(address owner) public returns (string memory json) {
        PoolConfig memory cfg = loadConfig(deploymentPath(block.chainid));
        address npm = UniswapV3Addresses.forChain(block.chainid).positionManager;
        uint256 deadline = cfg.permitDeadline != 0 ? cfg.permitDeadline : block.timestamp + PERMIT_SIGNING_WINDOW;
        json = permitTypedDataJson(cfg.fireToken, owner, npm, cfg.lpFireAmount, deadline);
        string memory out = permitPath(block.chainid);
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.writeFile(out, json);
        console.log("Permit typed data written:", out);
        console.log("  owner %s, spender (position manager) %s", owner, npm);
        console.log("  value %s FIRE, deadline %s", _fmt(cfg.lpFireAmount), _formatUtc(deadline));
        console.log(string.concat("1) export PERMIT_DEADLINE=", vm.toString(deadline)));
        console.log(string.concat("2) cast wallet sign --ledger --data --from-file ", out));
        console.log("3) export PERMIT_SIGNATURE=<0x... from step 2>, then run CreatePool with --broadcast.");
    }

    /**
     * @notice 환경 변수 + 배포 기록에서 설정을 읽음. FIRE_TOKEN과 기록이 서로 다르면 중단(오래된 .env 방지).
     * @dev 기록에 deployer·deployerNonce가 있으면 contracts.FireToken = CREATE(deployer, deployerNonce + 1)이어야 함
     *      (모든 체인). Base 메인넷은 그런 Deploy 기록이 반드시 있어야 함(기록 없이 FIRE_TOKEN만으로 실행 불가).
     */
    function loadConfig(string memory path) public view returns (PoolConfig memory cfg) {
        (bool exists, string memory json) = _readJsonIfExists(path);
        address recordToken = _jsonAddressOr(json, ".contracts.FireToken", address(0));
        _checkLaunchRecord(path, exists, json, recordToken);
        address envToken = _envAddressOr("FIRE_TOKEN", address(0));
        if (envToken != address(0) && recordToken != address(0) && envToken != recordToken) {
            revert CreatePoolTokenSourceMismatch(envToken, recordToken);
        }
        cfg.fireToken = envToken != address(0) ? envToken : recordToken;
        if (cfg.fireToken == address(0)) revert CreatePoolMissingFireToken();
        cfg.seedEth = _envUintOr("SEED_ETH", LaunchParams.DEFAULT_SEED_ETH);
        cfg.lpFireAmount = _envUintOr("LP_FIRE_AMOUNT", LaunchParams.LP_AMOUNT);
        cfg.feeTier = SafeCast.toUint24(_envUintOr("FEE_TIER", LaunchParams.FEE_TIER_1_PERCENT));
        cfg.slippageBps = _envUintOr("SLIPPAGE_BPS", LaunchParams.DEFAULT_SLIPPAGE_BPS);
        cfg.mainnetConfirmed = _envMainnetConfirmed();
        cfg.permitDeadline = _envUintOr("PERMIT_DEADLINE", 0);
        string memory sig = _envString("PERMIT_SIGNATURE");
        if (bytes(sig).length != 0) {
            cfg.permitSignature = vm.parseBytes(sig);
            if (cfg.permitDeadline == 0) revert LaunchMissingEnv("PERMIT_DEADLINE");
        }
    }

    /// @dev loadConfig의 기록 검사: 메인넷은 Deploy 기록 필수, 기록에 배포자 정보가 있으면 토큰 주소의 CREATE 유도 확인.
    function _checkLaunchRecord(string memory path, bool exists, string memory json, address recordToken) private view {
        bool hasDeployer = vm.keyExistsJson(json, ".deployer") && vm.keyExistsJson(json, ".deployerNonce");
        if (_isMainnet() && (!exists || recordToken == address(0) || !hasDeployer)) {
            console.log("ABORT: Base mainnet needs the Deploy record %s (contracts.FireToken, deployer,", path);
            console.log("  deployerNonce). Copy it from the PC that ran Deploy; never use FIRE_TOKEN alone.");
            revert CreatePoolLaunchRecordRequired(path);
        }
        if (!hasDeployer || recordToken == address(0)) return;
        address deployer = vm.parseJsonAddress(json, ".deployer");
        uint256 deployerNonce = vm.parseJsonUint(json, ".deployerNonce");
        if (recordToken != vm.computeCreateAddress(deployer, deployerNonce + 1)) {
            revert CreatePoolRecordMismatch("contracts.FireToken != CREATE(deployer, deployerNonce + 1)");
        }
    }

    /// @notice 풀 생성 본체. 테스트는 sender를 넘기고, run()은 address(0)으로 CLI 서명자를 사용.
    function createPool(PoolConfig memory cfg, address sender)
        public
        returns (PoolPlan memory plan, PoolResult memory result)
    {
        _requireSupportedChain(false);
        _requireMainnetConfirmation(cfg.mainnetConfirmed);
        plan = planPool(cfg, _resolveBroadcaster(sender));
        _logPlan(plan);
        result = _execute(plan);
        checkPostConditions(plan, result);
        _logResult(plan, result);
    }

    // ───────────────────────── 사전 점검 ─────────────────────────

    /// @notice 전송 전 모든 검증과 계산. 실패 시 아무 트랜잭션도 만들어지지 않음.
    function planPool(PoolConfig memory cfg, address broadcaster) public view returns (PoolPlan memory plan) {
        UniswapV3Addresses.Deployment memory uni = UniswapV3Addresses.forChain(block.chainid);
        _checkUniswap(uni);
        _checkFireToken(cfg.fireToken, uni.weth);
        _checkBroadcaster(broadcaster, cfg.fireToken);
        _checkAmounts(cfg, broadcaster);

        plan.broadcaster = broadcaster;
        plan.factory = uni.factory;
        plan.positionManager = uni.positionManager;
        plan.weth = uni.weth;
        plan.fireToken = cfg.fireToken;
        plan.fee = cfg.feeTier;
        plan.seedEth = cfg.seedEth;
        plan.lpFireAmount = cfg.lpFireAmount;
        plan.slippageBps = cfg.slippageBps;
        plan.tickSpacing = _checkTickSpacing(uni.factory, cfg.feeTier);
        (plan.tickLower, plan.tickUpper) = PoolMath.fullRangeTicks(plan.tickSpacing);

        (plan.token0, plan.token1) = PoolMath.sortTokens(cfg.fireToken, uni.weth);
        plan.fireIsToken0 = plan.token0 == cfg.fireToken;
        (plan.amount0Desired, plan.amount1Desired) =
            plan.fireIsToken0 ? (cfg.lpFireAmount, cfg.seedEth) : (cfg.seedEth, cfg.lpFireAmount);
        plan.sqrtPriceX96 = PoolMath.encodeSqrtPriceX96(plan.amount0Desired, plan.amount1Desired);
        plan.amount0Min = PoolMath.minAmount(plan.amount0Desired, cfg.slippageBps);
        plan.amount1Min = PoolMath.minAmount(plan.amount1Desired, cfg.slippageBps);
        plan.deadline = block.timestamp + LaunchParams.MINT_DEADLINE;

        plan.existingPool = IUniswapV3Factory(uni.factory).getPool(plan.token0, plan.token1, plan.fee);
        if (plan.existingPool != address(0)) _checkExistingPool(plan);
        _planApproval(plan, cfg);
    }

    function _checkUniswap(UniswapV3Addresses.Deployment memory uni) private view {
        _requireCode(uni.factory);
        _requireCode(uni.positionManager);
        _requireCode(uni.weth);
        INonfungiblePositionManager npm = INonfungiblePositionManager(uni.positionManager);
        address factory = npm.factory();
        address weth = npm.WETH9();
        if (factory != uni.factory || weth != uni.weth) revert CreatePoolPositionManagerMismatch(factory, weth);
    }

    function _checkFireToken(address token, address weth) private view {
        _requireCode(token);
        if (token == weth) revert CreatePoolNotFireToken(token);
        try IERC20Metadata(token).symbol() returns (string memory symbol) {
            if (!_sameString(symbol, "FIRE")) revert CreatePoolNotFireToken(token);
        } catch {
            revert CreatePoolNotFireToken(token);
        }
        if (IERC20Metadata(token).decimals() != 18) revert CreatePoolNotFireToken(token);
        if (IERC20(token).totalSupply() > LaunchParams.TOTAL_SUPPLY) revert CreatePoolNotFireToken(token);
        // FireToken 고유 상수 (이름·심볼만 흉내 낸 토큰 거부)
        (bool okTotal, uint256 total) = _staticUint(token, abi.encodeWithSignature("TOTAL_SUPPLY()"));
        (bool okVesting, uint256 vested) = _staticUint(token, abi.encodeWithSignature("VESTING_SUPPLY()"));
        if (!okTotal || total != LaunchParams.TOTAL_SUPPLY || !okVesting || vested != LaunchParams.VESTING_AMOUNT) {
            revert CreatePoolNotFireToken(token);
        }
    }

    /**
     * @dev 브로드캐스터(LP NFT·환불 ETH 수령자) 확인. 메인넷 중단 / 테스트넷 경고:
     *      - 코드가 있음(EIP-7702 위임 EOA): 위임 코드가 LP NFT·잔액을 옮길 수 있음 (Deploy의 배포 지갑 규칙과 같음)
     *      - 토큰이 브로드캐스터의 CREATE 주소가 아님: 다른 사람이 만든 같은 이름·바이트코드의 토큰(주소 오염)으로
     *        시딩 ETH가 들어가는 것을 막음. 런칭 토큰은 배포 지갑이 직접 만든 컨트랙트임(Deploy 두 번째 트랜잭션).
     */
    function _checkBroadcaster(address broadcaster, address token) private view {
        bool mainnet = _isMainnet();
        if (broadcaster.code.length != 0) {
            if (mainnet) {
                console.log("ABORT: the broadcaster %s has code (EIP-7702 delegation?).", broadcaster);
                revert CreatePoolBroadcasterHasCode(broadcaster);
            }
            console.log("WARNING: the broadcaster has code (EIP-7702 delegation?); rejected on Base mainnet.");
        }
        (bool created,) =
            LaunchGuards.createdBy(token, broadcaster, vm.getNonce(broadcaster), LaunchParams.MAX_PRIOR_NONCE_SCAN);
        if (created) return;
        if (mainnet) {
            console.log("ABORT: FIRE_TOKEN %s was not created by the broadcaster %s.", token, broadcaster);
            console.log("  Run CreatePool from the deployer wallet that broadcast Deploy (check FIRE_TOKEN / record).");
            revert CreatePoolTokenNotFromBroadcaster(token, broadcaster);
        }
        console.log("WARNING: FIRE_TOKEN was not created by the broadcaster (rejected on Base mainnet).");
    }

    function _checkAmounts(PoolConfig memory cfg, address broadcaster) private view {
        if (cfg.slippageBps == 0 || cfg.slippageBps > LaunchParams.MAX_SLIPPAGE_BPS) {
            revert CreatePoolInvalidSlippage(cfg.slippageBps);
        }
        uint256 minSeed = _isMainnet() ? LaunchParams.MAINNET_MIN_SEED_ETH : LaunchParams.MIN_SEED_ETH;
        if (cfg.seedEth < minSeed) revert CreatePoolSeedEthTooLow(cfg.seedEth, minSeed);
        // 메인넷은 공개 토크노믹스(7억)와 정확히 일치해야 함. 테스트넷은 리허설용으로 1 FIRE 이상 허용.
        bool badAmount = _isMainnet() ? cfg.lpFireAmount != LaunchParams.LP_AMOUNT : cfg.lpFireAmount < 1e18;
        if (badAmount) revert CreatePoolInvalidFireAmount(cfg.lpFireAmount);

        uint256 fireBalance = IERC20(cfg.fireToken).balanceOf(broadcaster);
        if (fireBalance < cfg.lpFireAmount) revert CreatePoolInsufficientFire(fireBalance, cfg.lpFireAmount);
        if (broadcaster.balance < cfg.seedEth) revert CreatePoolInsufficientEth(broadcaster.balance, cfg.seedEth);
    }

    function _checkTickSpacing(address factory, uint24 fee) private view returns (int24 spacing) {
        int24 expected;
        if (fee == LaunchParams.FEE_TIER_1_PERCENT) expected = LaunchParams.TICK_SPACING_1_PERCENT;
        else if (fee == LaunchParams.FEE_TIER_0_3_PERCENT) expected = LaunchParams.TICK_SPACING_0_3_PERCENT;
        else revert CreatePoolUnsupportedFeeTier(fee);
        spacing = IUniswapV3Factory(factory).feeAmountTickSpacing(fee);
        if (spacing != expected) revert CreatePoolTickSpacingMismatch(fee, expected, spacing);
    }

    /**
     * @dev 같은 (FIRE, WETH, fee) 풀이 이미 있을 때 (시뮬레이션 시점 기준):
     *      - 초기화 전(sqrtPrice 0): 이 multicall이 목표 가격으로 초기화하므로 그대로 진행.
     *      - 활성 유동성 > 0: 타인이 이미 시딩한 풀 → 중단.
     *      - 유동성 0 + 가격 편차 > 1%: 중단 (다른 FEE_TIER 사용 또는 가격 복구 후 재실행).
     *      - 유동성 0 + 편차 > SLIPPAGE_BPS: mint가 amountMin 검사에서 실패하므로 미리 중단.
     *        (전체 범위에서 가격 편차 d일 때 덜 쓰이는 쪽의 부족분은 d/(1+d) 또는 d 이하 → 편차 ≤ 슬리피지면 통과)
     *      - 그 외: 기존 가격에 유동성 공급 (경고 출력).
     *      시뮬레이션 이후 전송 전에 누군가 풀을 만들거나 가격을 바꾸면 이 검사는 다시 실행되지 않음. 그때의
     *      온체인 방어선은 mint의 amountMin(목표 대비 SLIPPAGE_BPS)이며, 벗어나면 multicall 전체가 revert됨.
     */
    function _checkExistingPool(PoolPlan memory plan) private view {
        IUniswapV3Pool pool = IUniswapV3Pool(plan.existingPool);
        (uint160 current,,,,,,) = pool.slot0();
        plan.existingSqrtPriceX96 = current;
        if (current == 0) {
            console.log("NOTE: pool %s exists but is uninitialized; this tx initializes it.", plan.existingPool);
            return;
        }
        uint128 active = pool.liquidity();
        if (active > 0) {
            console.log("ABORT: FIRE/WETH pool %s (fee %s) already has active liquidity.", plan.existingPool, plan.fee);
            console.log("  Someone else seeded it; do NOT add the launch liquidity at a price you did not set.");
            console.log("  Option: re-run with the other fee tier (FEE_TIER=3000 or 10000) and announce the pool.");
            revert CreatePoolPoolHasLiquidity(plan.existingPool, active);
        }
        uint256 deviation = PoolMath.priceDeviationBps(current, plan.sqrtPriceX96);
        if (deviation > LaunchParams.MAX_PRICE_DEVIATION_BPS) {
            _logPriceOptions(plan, current, deviation);
            revert CreatePoolExistingPoolPriceMismatch(plan.existingPool, deviation);
        }
        if (deviation > plan.slippageBps) {
            console.log(
                "ABORT: existing pool price is %s bps from target > SLIPPAGE_BPS %s.", deviation, plan.slippageBps
            );
            console.log("  The mint would fail its amountMin check. Options: SLIPPAGE_BPS=%s (max 100),", deviation);
            console.log("  or the other FEE_TIER.");
            revert CreatePoolExistingPoolPriceBeyondSlippage(plan.existingPool, deviation, plan.slippageBps);
        }
        console.log("WARNING: pool already initialized (no liquidity) %s bps from target;", deviation);
        console.log("  liquidity will be added at the EXISTING price.");
    }

    function _logPriceOptions(PoolPlan memory plan, uint160 current, uint256 deviation) private pure {
        console.log("ABORT: FIRE/WETH pool %s (fee %s) was initialized by someone else", plan.existingPool, plan.fee);
        console.log("  at a price %s away from the target (limit 100 bps = 1%%).", _deviationText(deviation));
        console.log("  current sqrtPriceX96:", current);
        console.log("  target  sqrtPriceX96:", plan.sqrtPriceX96);
        console.log("Options:");
        console.log("  (a) re-run with the other fee tier: FEE_TIER=3000 (or 10000) - simplest;");
        console.log("  (b) repair the price first with a zero-liquidity swap to the target sqrtPriceX96");
        console.log("      (manual, see deployments/README.md), then re-run this script.");
    }

    function _deviationText(uint256 deviation) private pure returns (string memory) {
        if (deviation == PoolMath.DEVIATION_SATURATED) return "4x or more (>= 30000 bps)";
        return string.concat(vm.toString(deviation), " bps");
    }

    function _requireCode(address target) private view {
        if (target.code.length == 0) revert CreatePoolMissingCode(target);
    }

    // ───────────────────────── 승인 (permit) ─────────────────────────

    /**
     * @dev 승인 방식 결정:
     *      1) PERMIT_SIGNATURE가 있으면(하드웨어 지갑으로 미리 서명) 서명자가 브로드캐스터인지 검증해 사용.
     *      2) 없으면 forge에 로드된 서명자(--account 키스토어, --private-key)로 vm.sign 시도.
     *      3) 둘 다 안 되면(예: --ledger는 임의 해시 서명 미지원, --unlocked) 별도 approve 트랜잭션으로 대체.
     *      permit은 multicall의 첫 호출(selfPermitIfNecessary)이라 승인과 유동성 공급이 같은 트랜잭션에서 일어남.
     */
    function _planApproval(PoolPlan memory plan, PoolConfig memory cfg) private view {
        plan.permitNonce = IERC20Permit(plan.fireToken).nonces(plan.broadcaster);
        plan.permitDeadline = cfg.permitDeadline != 0 ? cfg.permitDeadline : plan.deadline;
        bytes32 digest = permitDigest(
            plan.fireToken,
            plan.broadcaster,
            plan.positionManager,
            plan.lpFireAmount,
            plan.permitNonce,
            plan.permitDeadline
        );
        if (cfg.permitSignature.length != 0) {
            // 하드웨어 지갑 서명·전송 대기 시간을 고려해 최소 PERMIT_MIN_REMAINING이 남아 있어야 함(아니면 다시 서명).
            if (plan.permitDeadline < block.timestamp + PERMIT_MIN_REMAINING) {
                revert CreatePoolPermitExpired(plan.permitDeadline);
            }
            (address signer, ECDSA.RecoverError err,) = ECDSA.tryRecover(digest, cfg.permitSignature);
            if (err != ECDSA.RecoverError.NoError || signer != plan.broadcaster) {
                revert CreatePoolBadPermitSignature(signer);
            }
            (plan.permitV, plan.permitR, plan.permitS) = _splitSignature(cfg.permitSignature);
            plan.usePermit = true;
            return;
        }
        try vm.sign(plan.broadcaster, digest) returns (uint8 v, bytes32 r, bytes32 s) {
            (address signer, ECDSA.RecoverError err,) = ECDSA.tryRecover(digest, v, r, s);
            if (err == ECDSA.RecoverError.NoError && signer == plan.broadcaster) {
                (plan.permitV, plan.permitR, plan.permitS) = (v, r, s);
                plan.usePermit = true;
            }
        } catch {
            plan.usePermit = false;
        }
    }

    /// @notice FireToken.permit(owner, spender, value, nonce, deadline)의 EIP-712 다이제스트(토큰의 DOMAIN_SEPARATOR 사용).
    function permitDigest(address token, address owner, address spender, uint256 value, uint256 nonce, uint256 deadline)
        public
        view
        returns (bytes32)
    {
        bytes32 structHash = keccak256(abi.encode(PERMIT_TYPEHASH, owner, spender, value, nonce, deadline));
        return MessageHashUtils.toTypedDataHash(IERC20Permit(token).DOMAIN_SEPARATOR(), structHash);
    }

    /**
     * @notice `cast wallet sign --data` 형식(eth_signTypedData_v4)의 permit 서명 입력 JSON.
     * @dev 도메인 값은 토큰의 eip712Domain()(EIP-5267)에서 읽고, 그 값으로 계산한 도메인 구분자가 토큰의
     *      DOMAIN_SEPARATOR()와 같은지 확인함(다르면 서명이 permit에서 거부되므로 미리 중단).
     */
    function permitTypedDataJson(address token, address owner, address spender, uint256 value, uint256 deadline)
        public
        view
        returns (string memory)
    {
        return string.concat(
            '{"types":{"EIP712Domain":[{"name":"name","type":"string"},{"name":"version","type":"string"},',
            '{"name":"chainId","type":"uint256"},{"name":"verifyingContract","type":"address"}],',
            '"Permit":[{"name":"owner","type":"address"},{"name":"spender","type":"address"},',
            '{"name":"value","type":"uint256"},{"name":"nonce","type":"uint256"},{"name":"deadline","type":"uint256"}]},',
            '"primaryType":"Permit",',
            _permitDomainJson(token),
            _permitMessageJson(owner, spender, value, IERC20Permit(token).nonces(owner), deadline)
        );
    }

    function _permitDomainJson(address token) private view returns (string memory) {
        (, string memory name, string memory version, uint256 chainId, address verifyingContract,,) =
            IERC5267(token).eip712Domain();
        bytes32 domain = keccak256(
            abi.encode(
                EIP712_DOMAIN_TYPEHASH, keccak256(bytes(name)), keccak256(bytes(version)), chainId, verifyingContract
            )
        );
        if (domain != IERC20Permit(token).DOMAIN_SEPARATOR()) {
            revert CreatePoolPostConditionFailed("EIP-712 domain mismatch");
        }
        return string.concat(
            '"domain":{"name":"',
            name,
            '","version":"',
            version,
            '","chainId":',
            vm.toString(chainId),
            ',"verifyingContract":"',
            vm.toString(verifyingContract),
            '"},'
        );
    }

    function _permitMessageJson(address owner, address spender, uint256 value, uint256 nonce, uint256 deadline)
        private
        pure
        returns (string memory)
    {
        return string.concat(
            '"message":{"owner":"',
            vm.toString(owner),
            '","spender":"',
            vm.toString(spender),
            '","value":"',
            vm.toString(value),
            '","nonce":"',
            vm.toString(nonce),
            '","deadline":"',
            vm.toString(deadline),
            '"}}'
        );
    }

    /// @notice permitTypedData()가 쓰는 서명 입력 파일 경로 (테스트는 임시 경로로 재정의).
    function permitPath(uint256 chainId) public view virtual returns (string memory) {
        return string.concat("deployments/permit-", vm.toString(chainId), ".json");
    }

    function _splitSignature(bytes memory sig) private pure returns (uint8 v, bytes32 r, bytes32 s) {
        assembly ("memory-safe") {
            r := mload(add(sig, 0x20))
            s := mload(add(sig, 0x40))
            v := byte(0, mload(add(sig, 0x60)))
        }
    }

    // ───────────────────────── 실행 ─────────────────────────

    function _execute(PoolPlan memory plan) private returns (PoolResult memory result) {
        INonfungiblePositionManager npm = INonfungiblePositionManager(plan.positionManager);
        uint256 npmEthBefore = plan.positionManager.balance;
        bytes[] memory calls = multicallData(plan);

        vm.startBroadcast(plan.broadcaster);
        if (!plan.usePermit) _approve(plan.fireToken, plan.positionManager, plan.lpFireAmount);
        uint256 gasStart = gasleft();
        bytes[] memory results = npm.multicall{value: plan.seedEth}(calls);
        result.multicallGas = gasStart - gasleft();
        _approve(plan.fireToken, plan.positionManager, 0);
        vm.stopBroadcast();

        uint256 offset = plan.usePermit ? 1 : 0;
        result.pool = abi.decode(results[offset], (address));
        (result.tokenId, result.liquidity, result.amount0, result.amount1) =
            abi.decode(results[offset + 1], (uint256, uint128, uint256, uint256));
        (result.fireUsed, result.ethUsed) =
            plan.fireIsToken0 ? (result.amount0, result.amount1) : (result.amount1, result.amount0);
        // refundETH는 NPM의 ETH 잔액 전부를 돌려주므로: 보낸 ETH + (기존 잔액) − WETH로 감싼 양
        result.ethRefunded = plan.seedEth + npmEthBefore - result.ethUsed;
        (result.sqrtPriceX96, result.tick,,,,,) = IUniswapV3Pool(result.pool).slot0();
        result.blockNumber = block.number;
        result.blockTimestamp = block.timestamp;
    }

    /// @notice [selfPermitIfNecessary (permit일 때), createAndInitializePoolIfNecessary, mint, refundETH] 호출 데이터.
    function multicallData(PoolPlan memory plan) public pure returns (bytes[] memory calls) {
        calls = new bytes[](plan.usePermit ? 4 : 3);
        uint256 i;
        if (plan.usePermit) {
            calls[i++] = abi.encodeCall(
                INonfungiblePositionManager.selfPermitIfNecessary,
                (plan.fireToken, plan.lpFireAmount, plan.permitDeadline, plan.permitV, plan.permitR, plan.permitS)
            );
        }
        calls[i++] = abi.encodeCall(
            INonfungiblePositionManager.createAndInitializePoolIfNecessary,
            (plan.token0, plan.token1, plan.fee, plan.sqrtPriceX96)
        );
        calls[i++] = abi.encodeCall(
            INonfungiblePositionManager.mint,
            (INonfungiblePositionManager.MintParams({
                    token0: plan.token0,
                    token1: plan.token1,
                    fee: plan.fee,
                    tickLower: plan.tickLower,
                    tickUpper: plan.tickUpper,
                    amount0Desired: plan.amount0Desired,
                    amount1Desired: plan.amount1Desired,
                    amount0Min: plan.amount0Min,
                    amount1Min: plan.amount1Min,
                    recipient: plan.broadcaster,
                    deadline: plan.deadline
                }))
        );
        calls[i] = abi.encodeCall(INonfungiblePositionManager.refundETH, ());
    }

    function _approve(address token, address spender, uint256 amount) private {
        if (!IERC20(token).approve(spender, amount)) revert CreatePoolPostConditionFailed("approve returned false");
    }

    // ───────────────────────── 사후 조건 (시뮬레이션) ─────────────────────────

    function checkPostConditions(PoolPlan memory plan, PoolResult memory result) public view {
        INonfungiblePositionManager npm = INonfungiblePositionManager(plan.positionManager);
        IUniswapV3Pool pool = IUniswapV3Pool(result.pool);

        _post(result.pool != address(0), "pool address is zero");
        _post(
            IUniswapV3Factory(plan.factory).getPool(plan.token0, plan.token1, plan.fee) == result.pool,
            "factory.getPool != multicall pool"
        );
        _post(pool.token0() == plan.token0 && pool.token1() == plan.token1 && pool.fee() == plan.fee, "pool key");
        _post(npm.ownerOf(result.tokenId) == plan.broadcaster, "position NFT owner != broadcaster");
        _checkPosition(npm, plan, result);
        _post(result.amount0 >= plan.amount0Min && result.amount1 >= plan.amount1Min, "amounts below minimum");
        _post(result.fireUsed <= plan.lpFireAmount && result.ethUsed <= plan.seedEth, "used more than provided");
        _post(IERC20(plan.fireToken).allowance(plan.broadcaster, plan.positionManager) == 0, "leftover allowance");
        _post(plan.positionManager.balance == 0, "ETH left in position manager (refundETH)");
        uint160 expectedPrice = plan.existingSqrtPriceX96 == 0 ? plan.sqrtPriceX96 : plan.existingSqrtPriceX96;
        _post(result.sqrtPriceX96 == expectedPrice, "pool price moved during creation");
        // EIP-7825: forge가 추정치 × 130%를 가스 한도로 쓰므로 그 값까지 상한 아래인지 확인.
        uint256 gasLimit = (result.multicallGas + 100_000) * LaunchParams.GAS_ESTIMATE_MULTIPLIER_PERCENT / 100;
        if (gasLimit > LaunchParams.TX_GAS_CAP) revert CreatePoolGasAboveCap(gasLimit, LaunchParams.TX_GAS_CAP);
    }

    /// @dev positions()는 LaunchPositions.read로 읽음 (12개 반환값을 구조체로 디코딩: 최적화 없는 coverage 빌드 대응).
    function _checkPosition(INonfungiblePositionManager npm, PoolPlan memory plan, PoolResult memory result)
        private
        view
    {
        (bool exists, LaunchPositions.Position memory p) = LaunchPositions.read(npm, result.tokenId);
        _post(exists, "position NFT has no position data");
        _post(p.token0 == plan.token0 && p.token1 == plan.token1 && p.fee == plan.fee, "position token pair / fee");
        _post(p.tickLower == plan.tickLower && p.tickUpper == plan.tickUpper, "position is not full range");
        _post(p.liquidity == result.liquidity && p.liquidity > 0, "position liquidity");
    }

    function _post(bool ok, string memory check) private pure {
        if (!ok) revert CreatePoolPostConditionFailed(check);
    }

    // ───────────────────────── 기록 ─────────────────────────

    /**
     * @notice --broadcast 실행이 deployments/<chainId>.json에 쓰는 .pool (status "pending").
     * @dev 전송 전에 확정되는 값만 기록: 풀 주소(CREATE2로 결정), 토큰 순서, 수수료·틱, 목표 가격, 투입량, 수령자.
     *      시뮬레이션의 tokenId·유동성·예치량은 기록하지 않음(confirm()이 온체인 값으로 채움).
     */
    function pendingPoolJson(PoolPlan memory plan, PoolResult memory result) public returns (string memory json) {
        string memory k = "fire.pool";
        _resetJson(k);
        vm.serializeString(k, "status", LaunchParams.RECORD_PENDING);
        vm.serializeAddress(k, "address", result.pool);
        vm.serializeAddress(k, "factory", plan.factory);
        vm.serializeAddress(k, "positionManager", plan.positionManager);
        vm.serializeAddress(k, "weth", plan.weth);
        vm.serializeAddress(k, "token0", plan.token0);
        vm.serializeAddress(k, "token1", plan.token1);
        vm.serializeUint(k, "fee", plan.fee);
        vm.serializeInt(k, "tickSpacing", plan.tickSpacing);
        vm.serializeInt(k, "tickLower", plan.tickLower);
        vm.serializeInt(k, "tickUpper", plan.tickUpper);
        _serializeAmount(k, "targetSqrtPriceX96", plan.sqrtPriceX96);
        _serializeAmount(k, "seedEth", plan.seedEth);
        _serializeAmount(k, "lpFireAmount", plan.lpFireAmount);
        vm.serializeUint(k, "slippageBps", plan.slippageBps);
        vm.serializeAddress(k, "positionOwner", plan.broadcaster);
        vm.serializeString(k, "approval", plan.usePermit ? "permit" : "approve");
        json = vm.serializeUint(k, "simulatedBlockNumber", result.blockNumber);
    }

    /**
     * @notice 기존 기록이 있으면 .pool 키만 교체하고, 없으면 최소 기록을 새로 만듦(테스트넷만).
     * @dev 메인넷은 Deploy 기록이 있어야만 실행되므로(loadConfig) 최소 기록을 만들지 않음: FIRE_TOKEN 값만 담긴 기록이
     *      DeployBatchSender·DeployAirdrop의 메인넷 고정 기준이 되는 것을 막음.
     */
    function writePoolRecord(string memory poolJsonValue, address fireToken, string memory path) public {
        if (vm.exists(path)) {
            vm.writeJson(poolJsonValue, path, ".pool");
            return;
        }
        if (_isMainnet()) revert CreatePoolLaunchRecordRequired(path);
        _resetJson("fire.poolrecord.contracts");
        string memory contracts = vm.serializeAddress("fire.poolrecord.contracts", "FireToken", fireToken);
        _resetJson("fire.poolrecord");
        vm.serializeUint("fire.poolrecord", "chainId", block.chainid);
        vm.serializeString("fire.poolrecord", "network", _networkName(block.chainid));
        vm.serializeString("fire.poolrecord", "contracts", contracts);
        vm.writeJson(vm.serializeString("fire.poolrecord", "pool", poolJsonValue), path);
    }

    // ───────────────────────── 확인(confirm) ─────────────────────────

    /**
     * @notice 기록의 .pool(pending 또는 confirmed)을 온체인 상태로 확정.
     * @dev 1) 풀 주소가 factory.getPool과 같은지 확인.
     *      2) LP NFT id: LP_TOKEN_ID가 있으면 그 id, 없으면 positionOwner(배포자)가 보유한 NFT에서 FIRE/WETH 전체 범위
     *         포지션 중 런칭 크기(아래 하한 이상)인 것을 찾음(정확히 1개여야 함). 누구나 NPM.mint의 수령자를 배포 지갑으로
     *         지정해 소액 포지션을 보낼 수 있으므로 "모양"만으로는 고르지 않음.
     *      3) 런칭 크기: 기록의 계획(lpFireAmount·seedEth·slippageBps)으로 mint의 amountMin을 다시 계산하면 런칭 포지션의
     *         유동성 하한 L_min이 나옴(PoolMath.minFullRangeLiquidity). 현재 유동성은 L_min × (1 − 락커 수수료 상한 1%)
     *         이상, mint 이벤트를 찾았으면 발행 당시 유동성 ≥ L_min이고 예치량 ≥ amountMin이어야 함. 아니면 중단.
     *      4) 실제 유동성·현재 보유자, mint 트랜잭션의 예치량(IncreaseLiquidity 이벤트)과 풀 초기 가격(Initialize
     *         이벤트)을 eth_getLogs로 찾아(시뮬레이션 블록부터 500블록 구간씩) 기록하고 status를 confirmed로 바꿈.
     */
    function confirmRecord(string memory path) public returns (Confirmed memory c) {
        (bool exists, string memory json) = _readJsonIfExists(path);
        if (!exists || !vm.keyExistsJson(json, ".pool")) revert CreatePoolRecordMissing(path);
        RecordedPool memory rp = recordedPool(json);
        _checkRecordedPool(rp);
        INonfungiblePositionManager npm = INonfungiblePositionManager(rp.positionManager);
        IUniswapV3Factory factory = IUniswapV3Factory(rp.factory);

        c.pool = factory.getPool(rp.token0, rp.token1, rp.fee);
        if (c.pool == address(0) || c.pool != rp.pool) {
            revert CreatePoolRecordMismatch("factory.getPool != recorded pool (was the multicall mined?)");
        }
        c.minLiquidity = launchMinLiquidity(rp);
        uint256 floor = PoolMath.liquidityFloor(c.minLiquidity, LaunchParams.MAX_LOCK_FEE_BPS);
        c.tokenId = _envUintOr("LP_TOKEN_ID", 0);
        if (c.tokenId == 0) c.tokenId = _findLaunchPosition(npm, factory, rp, floor);
        (bool found, LaunchPositions.Position memory p) = LaunchPositions.read(npm, c.tokenId);
        if (!found || p.liquidity == 0 || !LaunchPositions.isFullRange(factory, p, rp.token0, rp.token1, rp.fee)) {
            revert CreatePoolNotLaunchPosition(c.tokenId);
        }
        if (p.liquidity < floor) revert CreatePoolPositionBelowPlan(c.tokenId, p.liquidity, c.minLiquidity);
        c.liquidity = p.liquidity;
        (, c.owner) = LaunchPositions.ownerOf(npm, c.tokenId);
        _readMintLog(c, rp);
        _readInitializeLog(c, rp);
        // 이전 confirm과 다른 id로 다시 확정하는데 mint 이벤트를 못 찾으면, 이전 id의 예치량이 남지 않도록 비움.
        uint256 previousId = _jsonUintOr(json, ".pool.tokenId", 0);
        _writeConfirmed(c, path, previousId != 0 && previousId != c.tokenId);
        _logConfirmed(c, rp);
    }

    /// @notice 기록의 계획에서 계산한 런칭 포지션 유동성 하한 (LaunchPositions.planMinLiquidity).
    function launchMinLiquidity(RecordedPool memory rp) public pure returns (uint256) {
        return LaunchPositions.planMinLiquidity(rp.token0 == rp.fireToken, rp.lpFireAmount, rp.seedEth, rp.slippageBps);
    }

    /// @dev 배포 지갑의 NFT에서 런칭 크기(floor 이상)인 FIRE/WETH 전체 범위 포지션을 정확히 1개 찾음.
    function _findLaunchPosition(
        INonfungiblePositionManager npm,
        IUniswapV3Factory factory,
        RecordedPool memory rp,
        uint256 floor
    ) private view returns (uint256) {
        LaunchPositions.Search memory found = LaunchPositions.find(
            npm, factory, rp.positionOwner, rp.token0, rp.token1, rp.fee, floor, LaunchParams.MAX_POSITION_SCAN
        );
        if (found.matches > found.eligible) {
            console.log(
                "NOTE: ignored %s small FIRE/WETH position(s) sent to the deployer (below the launch minimum).",
                found.matches - found.eligible
            );
        }
        if (found.eligible == 0) {
            if (found.held > LaunchParams.MAX_POSITION_SCAN) {
                console.log(
                    "NOTE: checked only the oldest %s of the deployer's %s LP NFTs (NFTs received before the launch come first).",
                    LaunchParams.MAX_POSITION_SCAN,
                    found.held
                );
            }
            console.log("NEXT: if the multicall was mined or the NFT is already locked, rerun with LP_TOKEN_ID=<id>");
            console.log(
                "      (the id is in the multicall's IncreaseLiquidity event on BaseScan; same launch-size checks)."
            );
            revert CreatePoolPositionNotFound(rp.positionOwner, found.held);
        }
        if (found.eligible > 1) revert CreatePoolAmbiguousPosition(rp.positionOwner, found.eligible);
        return found.tokenId;
    }

    /// @notice 기록 JSON의 .pool → RecordedPool.
    function recordedPool(string memory json) public view returns (RecordedPool memory rp) {
        rp.pool = vm.parseJsonAddress(json, ".pool.address");
        rp.factory = vm.parseJsonAddress(json, ".pool.factory");
        rp.positionManager = vm.parseJsonAddress(json, ".pool.positionManager");
        rp.fireToken = _jsonAddressOr(json, ".contracts.FireToken", address(0));
        rp.token0 = vm.parseJsonAddress(json, ".pool.token0");
        rp.token1 = vm.parseJsonAddress(json, ".pool.token1");
        rp.fee = SafeCast.toUint24(vm.parseJsonUint(json, ".pool.fee"));
        rp.seedEth = vm.parseJsonUint(json, ".pool.seedEth");
        rp.lpFireAmount = vm.parseJsonUint(json, ".pool.lpFireAmount");
        rp.slippageBps = vm.parseJsonUint(json, ".pool.slippageBps");
        rp.positionOwner = vm.parseJsonAddress(json, ".pool.positionOwner");
        rp.fromBlock = _jsonUintOr(json, ".pool.simulatedBlockNumber", 0);
    }

    function _checkRecordedPool(RecordedPool memory rp) private view {
        UniswapV3Addresses.Deployment memory uni = UniswapV3Addresses.forChain(block.chainid);
        if (rp.factory != uni.factory || rp.positionManager != uni.positionManager) {
            revert CreatePoolRecordMismatch("recorded Uniswap addresses != address table for this chain");
        }
        if (rp.fireToken == address(0) || (rp.token0 != rp.fireToken && rp.token1 != rp.fireToken)) {
            revert CreatePoolRecordMismatch("recorded pool does not contain contracts.FireToken");
        }
        _requireCode(rp.positionManager);
        _requireCode(rp.factory);
    }

    /// @dev mint의 IncreaseLiquidity 이벤트 → 실제 예치량·트랜잭션. 못 찾으면(RPC 구간 제한 등) 비워 둠.
    ///      검색은 시뮬레이션 블록(실제 포함 블록의 하한)부터 앞으로 진행하므로 confirm을 늦게 실행해도 바로 찾음.
    ///      찾았으면 발행 당시 유동성 ≥ L_min, 예치량 ≥ 계획의 amountMin이어야 함(런칭 multicall의 mint가 아니면 중단).
    function _readMintLog(Confirmed memory c, RecordedPool memory rp) private view {
        if (rp.fromBlock == 0) return; // 하한이 없는 기록: 전체 체인을 뒤지지 않음
        (bool found, VmSafe.EthGetLogs memory log) = _findMintLog(rp.positionManager, c.tokenId, rp.fromBlock);
        if (!found) return;
        (uint128 liquidity, uint256 amount0, uint256 amount1) = abi.decode(log.data, (uint128, uint256, uint256));
        bool fireIsToken0 = rp.token0 == rp.fireToken;
        (c.fireDeposited, c.ethDeposited) = fireIsToken0 ? (amount0, amount1) : (amount1, amount0);
        bool belowPlan = liquidity < c.minLiquidity
            || c.fireDeposited < PoolMath.minAmount(rp.lpFireAmount, rp.slippageBps)
            || c.ethDeposited < PoolMath.minAmount(rp.seedEth, rp.slippageBps);
        if (belowPlan) revert CreatePoolPositionBelowPlan(c.tokenId, liquidity, c.minLiquidity);
        c.mintLiquidity = liquidity;
        c.ethRefunded = rp.seedEth > c.ethDeposited ? rp.seedEth - c.ethDeposited : 0;
        c.mintTx = log.transactionHash;
        c.mintBlock = log.blockNumber;
        c.mintFound = true;
    }

    /// @dev 풀의 Initialize 이벤트 → 실제 초기 가격. 시뮬레이션 전에 이미 초기화된 풀이면 구간 밖이라 못 찾음.
    function _readInitializeLog(Confirmed memory c, RecordedPool memory rp) private view {
        if (rp.fromBlock == 0) return;
        (bool found, VmSafe.EthGetLogs memory log) = _findInitializeLog(c.pool, rp.fromBlock);
        if (!found) return;
        (c.initialSqrtPriceX96, c.initialTick) = abi.decode(log.data, (uint160, int24));
        c.initFound = true;
    }

    /// @dev 테스트가 재정의할 수 있는 이벤트 조회 지점 (포크 테스트의 로컬 이벤트는 원격 RPC에 없으므로).
    function _findMintLog(address npm, uint256 tokenId, uint256 fromBlock)
        internal
        view
        virtual
        returns (bool found, VmSafe.EthGetLogs memory log)
    {
        bytes32[] memory topics = new bytes32[](2);
        topics[0] = INCREASE_LIQUIDITY_TOPIC;
        topics[1] = bytes32(tokenId);
        return _firstLog(npm, topics, fromBlock);
    }

    function _findInitializeLog(address pool, uint256 fromBlock)
        internal
        view
        virtual
        returns (bool found, VmSafe.EthGetLogs memory log)
    {
        bytes32[] memory topics = new bytes32[](1);
        topics[0] = INITIALIZE_TOPIC;
        return _firstLog(pool, topics, fromBlock);
    }

    /// @dev fromBlock부터 현재 블록까지 LOG_WINDOW_BLOCKS(500) 구간씩 최대 MAX_LOG_WINDOWS번 조회해 첫 이벤트를 반환.
    function _firstLog(address emitter, bytes32[] memory topics, uint256 fromBlock)
        internal
        view
        returns (bool found, VmSafe.EthGetLogs memory log)
    {
        uint256 toBlock = block.number;
        for (uint256 w; w < LaunchParams.MAX_LOG_WINDOWS && fromBlock <= toBlock; ++w) {
            uint256 end = Math.min(fromBlock + LaunchParams.LOG_WINDOW_BLOCKS - 1, toBlock);
            try vm.eth_getLogs(fromBlock, end, emitter, topics) returns (VmSafe.EthGetLogs[] memory logs) {
                if (logs.length != 0) return (true, logs[0]);
            } catch {
                return (false, log);
            }
            fromBlock = end + 1;
        }
    }

    function _writeConfirmed(Confirmed memory c, string memory path, bool tokenIdChanged) private {
        vm.writeJson(vm.toString(c.tokenId), path, ".pool.tokenId");
        vm.writeJson(_quoted(vm.toString(c.liquidity)), path, ".pool.liquidity");
        vm.writeJson(_quoted(vm.toString(c.owner)), path, ".pool.ownerAtConfirm");
        vm.writeJson(_quoted(vm.toString(c.minLiquidity)), path, ".pool.minLiquidity");
        if (c.mintFound) {
            vm.writeJson(_quoted(vm.toString(c.mintTx)), path, ".pool.mintTx");
            vm.writeJson(vm.toString(c.mintBlock), path, ".pool.mintBlock");
            vm.writeJson(_quoted(vm.toString(c.mintLiquidity)), path, ".pool.mintLiquidity");
            vm.writeJson(_quoted(vm.toString(c.fireDeposited)), path, ".pool.fireDeposited");
            vm.writeJson(_quoted(vm.toString(c.ethDeposited)), path, ".pool.ethDeposited");
            vm.writeJson(_quoted(vm.toString(c.ethRefunded)), path, ".pool.ethRefunded");
        } else if (tokenIdChanged) {
            vm.writeJson("null", path, ".pool.mintTx");
            vm.writeJson("null", path, ".pool.mintBlock");
            vm.writeJson("null", path, ".pool.mintLiquidity");
            vm.writeJson("null", path, ".pool.fireDeposited");
            vm.writeJson("null", path, ".pool.ethDeposited");
            vm.writeJson("null", path, ".pool.ethRefunded");
        }
        if (c.initFound) {
            vm.writeJson(_quoted(vm.toString(uint256(c.initialSqrtPriceX96))), path, ".pool.initialSqrtPriceX96");
            vm.writeJson(vm.toString(c.initialTick), path, ".pool.initialTick");
        }
        vm.writeJson(vm.toString(block.number), path, ".pool.confirmedAtBlock");
        vm.writeJson(_quoted(LaunchParams.RECORD_CONFIRMED), path, ".pool.status");
    }

    function _quoted(string memory value) private pure returns (string memory) {
        return string.concat('"', value, '"');
    }

    // ───────────────────────── 락업 확인(confirmLock) ─────────────────────────

    /**
     * @notice confirmLock()의 본체: 기록의 확정된 LP NFT(pool.tokenId)가 락커 컨트랙트로 옮겨졌는지 확인하고, 락업 후
     *         유동성을 .lpLock에 기록함. 기록 파일 외에는 아무것도 바꾸지 않음.
     * @dev 조건: pool.status = confirmed, NFT가 FIRE/WETH 전체 범위 포지션이고 보유자가 배포 지갑이 아닌 컨트랙트,
     *      LP_LOCKER를 주면 그 주소와 같아야 함, 기록된 pool.liquidity 대비 감소가 MAX_LOCK_FEE_BPS(1%) 이하.
     *      이미 기록된 락업 후 유동성(.lpLock.liquidity)보다 줄었으면 다시 실행해도 기준을 낮추지 않고 중단함
     *      (락업 이후의 감소를 기준 갱신으로 덮지 못하게 함).
     */
    function confirmLockRecord(string memory path) public returns (LockConfirmed memory l) {
        (bool exists, string memory json) = _readJsonIfExists(path);
        if (!exists || !_jsonIsConfirmed(json, ".pool.status")) {
            console.log("ABORT: run CreatePool --sig 'confirm()' before locking (pool.status must be confirmed).");
            revert CreatePoolRecordMissing(path);
        }
        RecordedPool memory rp = recordedPool(json);
        _checkRecordedPool(rp);
        INonfungiblePositionManager npm = INonfungiblePositionManager(rp.positionManager);
        l.tokenId = vm.parseJsonUint(json, ".pool.tokenId");
        l.liquidityBefore = vm.parseJsonUint(json, ".pool.liquidity");
        (bool found, LaunchPositions.Position memory p) = LaunchPositions.read(npm, l.tokenId);
        if (!found || !LaunchPositions.isFullRange(IUniswapV3Factory(rp.factory), p, rp.token0, rp.token1, rp.fee)) {
            revert CreatePoolNotLaunchPosition(l.tokenId);
        }
        (, l.locker) = LaunchPositions.ownerOf(npm, l.tokenId);
        if (l.locker == rp.positionOwner || l.locker.code.length == 0) {
            revert CreatePoolLpNotLocked(l.tokenId, l.locker);
        }
        address expected = _envAddressOr("LP_LOCKER", address(0));
        if (expected != address(0) && expected != l.locker) revert CreatePoolLockerMismatch(expected, l.locker);
        l.liquidityAfter = p.liquidity;
        uint256 previous = _jsonUintOr(json, ".lpLock.liquidity", 0);
        if (previous != 0 && l.liquidityAfter < previous) {
            console.log("ABORT: liquidity %s is below the recorded post-lock baseline %s.", l.liquidityAfter, previous);
            revert CreatePoolLockBaselineDecreased(previous, l.liquidityAfter);
        }
        if (l.liquidityAfter < l.liquidityBefore) {
            l.lockFeeBps =
                Math.mulDiv(l.liquidityBefore - l.liquidityAfter, PoolMath.BPS, l.liquidityBefore, Math.Rounding.Ceil);
        }
        if (l.lockFeeBps > LaunchParams.MAX_LOCK_FEE_BPS) {
            console.log("ABORT: liquidity fell %s bps since confirm(): more than a locker LP fee.", l.lockFeeBps);
            revert CreatePoolLockFeeTooHigh(l.lockFeeBps, LaunchParams.MAX_LOCK_FEE_BPS);
        }
        vm.writeJson(_quoted(vm.toString(l.locker)), path, ".lpLock.locker");
        vm.writeJson(_quoted(vm.toString(l.liquidityAfter)), path, ".lpLock.liquidity");
        vm.writeJson(vm.toString(l.lockFeeBps), path, ".lpLock.lockFeeBps");
        vm.writeJson(vm.toString(block.number), path, ".lpLock.confirmedAtBlock");
        _logLockConfirmed(l, path);
    }

    // ───────────────────────── 로그 ─────────────────────────

    function _logPlan(PoolPlan memory plan) private view {
        console.log("=== FIRE/WETH Uniswap V3 pool (%s, chainId %s) ===", _networkName(block.chainid), block.chainid);
        console.log("broadcaster (LP NFT recipient):", plan.broadcaster);
        console.log("FIRE:", plan.fireToken);
        console.log("WETH:", plan.weth);
        console.log(
            "token0 = %s, token1 = %s", plan.fireIsToken0 ? "FIRE" : "WETH", plan.fireIsToken0 ? "WETH" : "FIRE"
        );
        console.log(
            string.concat(
                "fee tier ",
                vm.toString(plan.fee),
                " (",
                _fmtBps(plan.fee / 100),
                "), tick spacing ",
                vm.toString(plan.tickSpacing),
                ", full range [",
                vm.toString(plan.tickLower),
                ", ",
                vm.toString(plan.tickUpper),
                "]"
            )
        );
        console.log("seed: %s ETH + %s FIRE", _fmt(plan.seedEth), _fmt(plan.lpFireAmount));
        uint256 weiPerFire = PoolMath.price0In1Wad(plan.sqrtPriceX96);
        if (!plan.fireIsToken0) weiPerFire = PoolMath.price1In0Wad(plan.sqrtPriceX96);
        console.log("initial price: 1 FIRE = %s ETH", _fmt(weiPerFire));
        console.log("initial FDV  : ~%s ETH (1,000,000,000 FIRE)", _fmt(weiPerFire * 1e9));
        console.log("sqrtPriceX96 :", plan.sqrtPriceX96);
        console.log(
            "min amounts (slippage %s): token0 %s / token1 %s",
            _fmtBps(plan.slippageBps),
            _fmt(plan.amount0Min),
            _fmt(plan.amount1Min)
        );
        console.log("existing pool:", plan.existingPool);
        if (plan.usePermit) {
            console.log("approval: EIP-2612 permit inside the multicall (no separate approve tx)");
        } else {
            console.log("WARNING: no in-script signer for a permit (e.g. --ledger); sending a separate approve tx.");
            console.log("  That approve is public before the pool exists and stays set if the multicall fails.");
            console.log("  To avoid it, sign a permit first: see permitTypedData() / PERMIT_SIGNATURE.");
        }
        // 승인(1) → multicall(2) 사이에 가스가 모자라면 승인만 남으므로 여유분을 미리 경고.
        if (plan.broadcaster.balance < plan.seedEth + GAS_RESERVE) {
            console.log("WARNING: less than %s ETH left for gas after the seed ETH.", _fmt(GAS_RESERVE));
        }
    }

    function _logResult(PoolPlan memory plan, PoolResult memory result) private view {
        console.log("--- SIMULATED result (final values are assigned when the multicall is mined) ---");
        console.log("pool        :", _explorerAddress(result.pool));
        console.log("LP NFT id   : %s (simulated; other mints on Base can shift it)", result.tokenId);
        console.log("liquidity   :", result.liquidity);
        console.log("FIRE used   : %s of %s", _fmt(result.fireUsed), _fmt(plan.lpFireAmount));
        console.log("ETH used    : %s of %s", _fmt(result.ethUsed), _fmt(plan.seedEth));
        console.log("ETH refunded: %s", _fmt(result.ethRefunded));
        console.log("multicall gas (simulation): %s (EIP-7825 cap %s)", result.multicallGas, LaunchParams.TX_GAS_CAP);
        console.log("post-conditions (simulation): OK (allowance reset to 0, NFT owned by broadcaster)");
    }

    function _logConfirmed(Confirmed memory c, RecordedPool memory rp) private view {
        console.log("--- confirmed on-chain ---");
        console.log("pool        :", _explorerAddress(c.pool));
        console.log("LP NFT id   :", c.tokenId);
        console.log("liquidity   :", c.liquidity);
        console.log("owner now   :", c.owner);
        if (c.mintFound) {
            console.log("mint tx     :", vm.toString(c.mintTx));
            console.log("FIRE deposited: %s", _fmt(c.fireDeposited));
            console.log("ETH deposited : %s (refunded %s)", _fmt(c.ethDeposited), _fmt(c.ethRefunded));
        } else {
            console.log("NOTE: mint event not found via eth_getLogs (RPC range limit?); amounts not recorded.");
            console.log("      They are in broadcast/CreatePool.s.sol/<chainId>/run-latest.json.");
        }
        if (!c.initFound) console.log("NOTE: pool Initialize event not found after the simulated block.");
        console.log("launch minimum: %s (from the recorded plan; smaller positions are ignored)", c.minLiquidity);
        if (c.owner == rp.positionOwner) {
            console.log(
                "NEXT: lock LP NFT #%s for %s days at UNCX or Team Finance (Uniswap V3 Locker),",
                c.tokenId,
                LaunchParams.LP_LOCK_DAYS
            );
            console.log("      then record the post-lock liquidity: CreatePool --sig 'confirmLock()'.");
        }
    }

    function _logLockConfirmed(LockConfirmed memory l, string memory path) private view {
        console.log("--- LP lock confirmed on-chain ---");
        console.log("LP NFT id      :", l.tokenId);
        console.log("held by locker :", _explorerAddress(l.locker));
        console.log("liquidity      : %s at confirm() -> %s now", l.liquidityBefore, l.liquidityAfter);
        console.log("locker LP fee  : %s (taken from the position when it was locked)", _fmtBps(l.lockFeeBps));
        console.log("Record updated (.lpLock.locker/liquidity/lockFeeBps/confirmedAtBlock):", path);
        console.log("Add lockTx, unlockDate and url to .lpLock by hand, then run PostDeployCheck.");
    }

    function _logNextSteps(PoolPlan memory plan) private view {
        string memory rpc = _rpcAlias(block.chainid);
        console.log("");
        console.log("=== NEXT STEPS (guide 5-2) ===");
        console.log("The LP NFT id above is SIMULATED. The real id is assigned when the multicall is mined.");
        console.log("1) Once mined, record the real position (no signing, no transactions):");
        console.log(
            string.concat("   forge script script/CreatePool.s.sol:CreatePool --sig 'confirm()' --rpc-url ", rpc)
        );
        console.log(
            "2) Lock the LP NFT id printed by step 1 for %s days at UNCX or Team Finance (Uniswap V3 Locker):",
            LaunchParams.LP_LOCK_DAYS
        );
        console.log("   - position manager:", plan.positionManager);
        console.log("   - set the fee collector to the developer wallet; open the locker via its official domain.");
        console.log("   - UNCX takes part of the LP at lock time (Base DEFAULT 0.5%); the rest stays locked.");
        console.log("3) Record the post-lock liquidity (no signing, no transactions):");
        console.log(
            string.concat(
                "   LP_LOCKER=<locker> forge script script/CreatePool.s.sol:CreatePool --sig 'confirmLock()' --rpc-url ",
                rpc
            )
        );
        console.log("4) Publish the lock tx hash and lock page URL; add them to .lpLock (deployments/README.md).");
        console.log("5) forge script script/PostDeployCheck.s.sol:PostDeployCheck --rpc-url", rpc);
        if (plan.usePermit) {
            console.log("If the multicall fails on-chain, nothing stays approved (the permit reverts with it).");
        } else {
            console.log("If the multicall fails on-chain, clear the approval:");
            console.log("   cast send <FIRE> 'approve(address,uint256)' <NPM> 0 (with your --ledger / --account)");
        }
    }
}
