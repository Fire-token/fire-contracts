// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {console} from "forge-std/console.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {FireToken} from "../src/FireToken.sol";
import {FireVesting} from "../src/FireVesting.sol";
import {LaunchBase} from "./lib/LaunchBase.sol";
import {LaunchCode} from "./lib/LaunchCode.sol";
import {LaunchGuards} from "./lib/LaunchGuards.sol";
import {LaunchParams} from "./lib/LaunchParams.sol";
import {PoolMath} from "./lib/PoolMath.sol";
import {UniswapV3Addresses} from "./lib/UniswapV3Addresses.sol";
import {LaunchPositions} from "./lib/LaunchPositions.sol";
import {INonfungiblePositionManager, IUniswapV3Factory, IUniswapV3Pool} from "./lib/IUniswapV3.sol";

/**
 * @title PostDeployCheck — 배포 후 온체인 상태 점검 (읽기 전용, 브로드캐스트 없음)
 * @notice deployments/<chainId>.json 을 읽고(환경 변수가 있으면 그 값이 우선) 공개용 PASS/WARN/FAIL 보고서를 출력.
 *         환경 변수(선택): FIRE_TOKEN, FIRE_VESTING, DEPLOYER, BENEFICIARY, TREASURY_SAFE, AIRDROP_WALLET,
 *         LP_TOKEN_ID, LP_LOCKER.
 * @dev 등급:
 *      - FAIL: 영구히 성립해야 하는 성질 위반 (공급량·메타데이터·코드 동일성·베스팅 일정/소유자·LP 포지션 축소 등).
 *              1건 이상이면 보고서 출력 후 revert하여 종료 코드가 0이 아니게 함.
 *      - WARN: 런칭 시점 값에서 달라졌지만 정상 운영으로도 생길 수 있는 변화 (트레저리·에어드롭 잔액, LP NFT 미락업,
 *              트레저리 Safe의 모듈 등) 또는 아직 confirm()되지 않은 기록.
 *      - INFO: 참고 값 (현재 가격, 소각량, 실제 베스팅 일정 등).
 *      점검 대상(공개 기록)을 쓴 배포자 자신도 점검 대상이므로 기록의 값을 그대로 믿지 않음:
 *      - FireToken·FireVesting 런타임 코드를 이 저장소에서 컴파일한 코드와 대조 (LaunchCode, loadInputs가 계산)
 *      - 기록에 deployerNonce가 있으면 두 주소가 CREATE(deployer, deployerNonce / + 1)인지 확인
 *      - 기록의 pool.positionManager는 Uniswap V3 주소표(UniswapV3Addresses)와 같아야 하고, 점검은 주소표의 NPM으로 함
 *      - LP NFT id(기록·LP_TOKEN_ID)는 온체인에서 FIRE/WETH 전체 범위 포지션인지, 기록된 계획(투입량·슬리피지)에서
 *        계산한 런칭 크기 이상인지 확인함. 누구나 배포 지갑으로 보낼 수 있는 소액 포지션은 런칭 포지션으로 보지 않음.
 *        기록에 id가 없거나(pending) 틀리면 배포 지갑에서 런칭 크기 포지션을 찾아 그 id로 점검을 이어감.
 *      - 유동성 비교 기준: confirmLock()이 기록한 락업 후 유동성(.lpLock.liquidity)이 있으면 그 값, 없으면 confirm()의
 *        pool.liquidity. 락커가 락업 때 떼어 간 수수료(1% 이하)는 confirmLock() 기록으로 공개됨.
 */
contract PostDeployCheck is LaunchBase {
    struct CheckInputs {
        address token;
        address vesting;
        address deployer;
        address beneficiary;
        address treasurySafe;
        address airdropWallet;
        uint256 recordedVestingStart; // 0이면 기록 없음
        uint8 deployStatus; // STATUS_NONE / STATUS_PENDING / STATUS_CONFIRMED
        bool hasPool;
        uint8 poolStatus;
        address pool;
        address positionManager;
        uint256 tokenId; // 0이면 미확정(pending 기록) → 배포 지갑에서 탐색
        uint256 recordedLiquidity; // 0이면 기록 없음(confirmed 기록에만 있음)
        uint24 fee;
        uint160 initialSqrtPriceX96; // 0이면 기록 없음
        address lpLocker; // 0이면 미지정
        uint256 minLiquidity; // 기록된 계획(pool.lpFireAmount·seedEth·slippageBps)의 런칭 포지션 유동성 하한 (0 = 계획 없음)
        uint256 lockLiquidity; // .lpLock.liquidity: confirmLock()이 기록한 락업 후 유동성 (0 = 없음)
        bool hasDeployerNonce; // 기록에 deployerNonce가 있음 → CREATE 주소 유도 확인
        uint256 deployerNonce;
        uint8 tokenCode; // LaunchCode.UNCHECKED / MATCH / MISMATCH (loadInputs가 계산)
        uint8 vestingCode;
    }

    struct Report {
        uint256 passed;
        uint256 warned;
        uint256 failed;
        bool verbose;
    }

    /// @dev pending 기록의 vesting.start(시뮬레이션 블록 기준)와 온체인 값의 허용 차이(트랜잭션 포함 지연).
    uint256 public constant MAX_INCLUSION_DELAY = LaunchParams.MAX_INCLUSION_DELAY;
    /// @dev 기록 상태: 기록 없음(환경 변수만) / pending(전송 전 값) / confirmed(confirm()이 온체인 값으로 갱신).
    uint8 public constant STATUS_NONE = 0;
    uint8 public constant STATUS_PENDING = 1;
    uint8 public constant STATUS_CONFIRMED = 2;

    error PostDeployCheckFailed(uint256 failures);
    error PostDeployCheckMissingInput(string name);

    // ───────────────────────── 진입점 ─────────────────────────

    function run() external returns (Report memory report) {
        _requireRpcChainMatches(); // --chain / FOUNDRY_CHAIN_ID로 다른 체인의 기록을 읽지 않도록
        report = runWith(deploymentPath(block.chainid));
    }

    /// @notice 보고서를 출력하고 FAIL이 있으면 revert(종료 코드 ≠ 0).
    function runWith(string memory path) public returns (Report memory report) {
        report = check(loadInputs(path), true);
        if (report.failed > 0) revert PostDeployCheckFailed(report.failed);
    }

    /**
     * @notice 배포 기록 + 환경 변수(우선)에서 점검 대상 주소를 읽고, 두 컨트랙트의 코드 동일성을 계산함.
     * @dev 코드 동일성 계산(LaunchCode)은 참조 컨트랙트를 로컬 시뮬레이션에만 배포하므로 view가 아님(전송 없음).
     */
    function loadInputs(string memory path) public returns (CheckInputs memory inputs) {
        (bool exists, string memory json) = _readJsonIfExists(path);
        console.log("record: %s (%s)", path, exists ? "found" : "not found - using env only");

        inputs.token = _pick("FIRE_TOKEN", json, ".contracts.FireToken");
        inputs.vesting = _pick("FIRE_VESTING", json, ".contracts.FireVesting");
        inputs.deployer = _pick("DEPLOYER", json, ".deployer");
        inputs.beneficiary = _pick("BENEFICIARY", json, ".wallets.beneficiary");
        inputs.treasurySafe = _pick("TREASURY_SAFE", json, ".wallets.treasurySafe");
        inputs.airdropWallet = _pick("AIRDROP_WALLET", json, ".wallets.airdropWallet");
        inputs.recordedVestingStart = _jsonUintOr(json, ".vesting.start", 0);
        inputs.deployStatus = _status(exists, json, ".status");

        if (vm.keyExistsJson(json, ".pool")) {
            inputs.hasPool = true;
            inputs.poolStatus = _status(true, json, ".pool.status");
            inputs.pool = _jsonAddressOr(json, ".pool.address", address(0));
            inputs.positionManager = vm.parseJsonAddress(json, ".pool.positionManager");
            inputs.fee = SafeCast.toUint24(vm.parseJsonUint(json, ".pool.fee"));
            // tokenId는 있으면 읽되 온체인에서 다시 확인함. 유동성 비교 기준은 confirm된 기록 값만 사용
            // (시뮬레이션 값과 비교하면 정상 런칭도 "유동성 감소"로 오판할 수 있음).
            inputs.tokenId = _jsonUintOr(json, ".pool.tokenId", 0);
            if (inputs.poolStatus == STATUS_CONFIRMED) {
                inputs.recordedLiquidity = _jsonUintOr(json, ".pool.liquidity", 0);
            }
            inputs.initialSqrtPriceX96 = SafeCast.toUint160(_jsonUintOr(json, ".pool.initialSqrtPriceX96", 0));
            inputs.minLiquidity = _planMinLiquidity(json, inputs.token);
        }
        inputs.lockLiquidity = _jsonUintOr(json, ".lpLock.liquidity", 0);
        inputs.hasDeployerNonce = vm.keyExistsJson(json, ".deployerNonce");
        inputs.deployerNonce = _jsonUintOr(json, ".deployerNonce", 0);
        uint256 envTokenId = _envUintOr("LP_TOKEN_ID", 0);
        if (envTokenId != 0) {
            inputs.hasPool = true;
            if (envTokenId != inputs.tokenId) inputs.recordedLiquidity = 0; // 다른 포지션의 기록 유동성과 비교하지 않음
            inputs.tokenId = envTokenId;
            if (inputs.positionManager == address(0) && UniswapV3Addresses.isSupported(block.chainid)) {
                inputs.positionManager = UniswapV3Addresses.forChain(block.chainid).positionManager;
            }
        }
        inputs.lpLocker = _envAddressOr("LP_LOCKER", _jsonAddressOr(json, ".lpLock.locker", address(0)));

        _requireInput(inputs.token, "FIRE_TOKEN / contracts.FireToken");
        _requireInput(inputs.vesting, "FIRE_VESTING / contracts.FireVesting");
        _requireInput(inputs.deployer, "DEPLOYER / deployer");
        _requireInput(inputs.beneficiary, "BENEFICIARY / wallets.beneficiary");
        _requireInput(inputs.treasurySafe, "TREASURY_SAFE / wallets.treasurySafe");
        _requireInput(inputs.airdropWallet, "AIRDROP_WALLET / wallets.airdropWallet");
        if (inputs.hasPool) _requireInput(inputs.positionManager, "pool.positionManager");
        inputs.tokenCode = LaunchCode.tokenStatus(inputs.token);
        inputs.vestingCode = LaunchCode.vestingStatus(inputs.vesting);
    }

    /// @dev 기록된 풀 계획에서 런칭 포지션 유동성 하한 계산 (필요한 키가 없으면 0 = 크기 검사 생략).
    function _planMinLiquidity(string memory json, address token) private view returns (uint256) {
        string[4] memory keys = [".pool.token0", ".pool.lpFireAmount", ".pool.seedEth", ".pool.slippageBps"];
        for (uint256 i; i < keys.length; ++i) {
            if (!vm.keyExistsJson(json, keys[i])) return 0;
        }
        uint256 slippageBps = vm.parseJsonUint(json, ".pool.slippageBps");
        if (slippageBps > LaunchParams.MAX_SLIPPAGE_BPS) return type(uint128).max; // 계획 자체가 규칙 밖 → 통과 불가
        return LaunchPositions.planMinLiquidity(
            vm.parseJsonAddress(json, ".pool.token0") == token,
            vm.parseJsonUint(json, ".pool.lpFireAmount"),
            vm.parseJsonUint(json, ".pool.seedEth"),
            slippageBps
        );
    }

    function _status(bool exists, string memory json, string memory key) private view returns (uint8) {
        if (!exists || !vm.keyExistsJson(json, key)) return STATUS_NONE;
        return _jsonIsConfirmed(json, key) ? STATUS_CONFIRMED : STATUS_PENDING;
    }

    function _pick(string memory envName, string memory json, string memory key) private view returns (address) {
        address fromJson = _jsonAddressOr(json, key, address(0));
        address fromEnv = _envAddressOr(envName, address(0));
        if (fromEnv == address(0)) return fromJson;
        if (fromJson != address(0) && fromJson != fromEnv) {
            console.log("NOTE: env %s=%s overrides the record value %s", envName, fromEnv, fromJson);
        }
        return fromEnv;
    }

    function _requireInput(address value, string memory name) private pure {
        if (value == address(0)) revert PostDeployCheckMissingInput(name);
    }

    // ───────────────────────── 점검 ─────────────────────────

    /// @notice 모든 점검을 실행하고 집계를 반환(revert하지 않음). verbose=false면 로그 생략(테스트·불변식용).
    function check(CheckInputs memory inputs, bool verbose) public view returns (Report memory r) {
        r.verbose = verbose;
        if (verbose) _logHeader(inputs);
        _checkRecordStatus(r, inputs);
        bool tokenOk = _checkToken(r, inputs);
        _checkVesting(r, inputs, tokenOk);
        if (tokenOk) _checkAllocation(r, inputs);
        if (inputs.hasPool) _checkPool(r, inputs, tokenOk);
        else if (tokenOk) _checkAllowanceWithoutPool(r, inputs);
        if (verbose) {
            console.log("");
            console.log("=== RESULT: %s ===", r.failed == 0 ? "PASS" : "FAIL");
            console.log("passed %s / warnings %s / failed %s", r.passed, r.warned, r.failed);
        }
    }

    /// @dev forge의 --broadcast 실행이 쓴 기록은 전송 전(시뮬레이션) 값이므로 confirm() 전에는 공개하지 말 것.
    function _checkRecordStatus(Report memory r, CheckInputs memory inputs) private pure {
        if (inputs.deployStatus == STATUS_NONE && inputs.poolStatus == STATUS_NONE) return;
        _section(r, "Record status");
        if (inputs.deployStatus == STATUS_CONFIRMED) {
            _pass(r, "deploy record confirmed against the chain");
        } else if (inputs.deployStatus == STATUS_PENDING) {
            _warn(r, "deploy record is pending: run forge script script/Deploy.s.sol:Deploy --sig 'confirm()'");
        }
        if (inputs.poolStatus == STATUS_CONFIRMED) {
            _pass(r, "pool record confirmed against the chain");
        } else if (inputs.poolStatus == STATUS_PENDING) {
            _warn(r, "pool record is pending: run forge script script/CreatePool.s.sol:CreatePool --sig 'confirm()'");
        }
    }

    function _checkToken(Report memory r, CheckInputs memory inputs) private view returns (bool ok) {
        _section(r, "FireToken");
        if (inputs.token.code.length == 0) {
            _fail(r, "no contract code at FireToken address");
            return false;
        }
        FireToken token = FireToken(inputs.token);
        try token.symbol() returns (string memory symbol) {
            ok = _sameString(symbol, "FIRE") && _sameString(token.name(), "Fire") && token.decimals() == 18;
        } catch {}
        _expect(r, ok, "name Fire / symbol FIRE / decimals 18");
        if (!ok) return false;

        _expect(
            r,
            token.TOTAL_SUPPLY() == LaunchParams.TOTAL_SUPPLY && token.VESTING_SUPPLY() == LaunchParams.VESTING_AMOUNT,
            "TOTAL_SUPPLY 1,000,000,000 / VESTING_SUPPLY 200,000,000"
        );
        uint256 supply = token.totalSupply();
        if (supply == LaunchParams.TOTAL_SUPPLY) {
            _pass(r, "totalSupply 1,000,000,000 FIRE (nothing burned yet)");
        } else if (supply < LaunchParams.TOTAL_SUPPLY) {
            _pass(
                r,
                string.concat(
                    "totalSupply ", _fmt(supply), " FIRE (burned ", _fmt(LaunchParams.TOTAL_SUPPLY - supply), ")"
                )
            );
        } else {
            _fail(r, string.concat("totalSupply above 1,000,000,000: ", _fmt(supply)));
        }
        (bool hasOwner,) = inputs.token.staticcall(abi.encodeWithSignature("owner()"));
        _expect(r, !hasOwner, "no owner() on the token (no admin, mint, pause or tax functions)");
        _reportCode(r, inputs.tokenCode, "FireToken");
        _checkCreateAddresses(r, inputs);
    }

    /// @dev 코드 동일성 결과 보고 (UNCHECKED: 기록을 읽지 않고 직접 만든 입력 → 참고 표시만).
    function _reportCode(Report memory r, uint8 status, string memory name) private pure {
        if (status == LaunchCode.UNCHECKED) {
            _info(r, string.concat(name, " runtime code not compared (inputs not loaded with loadInputs)"));
            return;
        }
        _expect(
            r,
            status == LaunchCode.MATCH,
            string.concat(name, " runtime code == ", name, " compiled from this repository (immutables aside)")
        );
    }

    /// @dev 기록의 FireVesting·FireToken이 배포 지갑의 연속된 CREATE 주소(deployerNonce, +1)인지.
    function _checkCreateAddresses(Report memory r, CheckInputs memory inputs) private pure {
        if (!inputs.hasDeployerNonce) return;
        _expect(
            r,
            inputs.vesting == vm.computeCreateAddress(inputs.deployer, inputs.deployerNonce)
                && inputs.token == vm.computeCreateAddress(inputs.deployer, inputs.deployerNonce + 1),
            "FireVesting / FireToken = CREATE(deployer, deployerNonce) / CREATE(deployer, deployerNonce + 1)"
        );
    }

    function _checkVesting(Report memory r, CheckInputs memory inputs, bool tokenOk) private view {
        _section(r, "FireVesting");
        if (inputs.vesting.code.length == 0) {
            _fail(r, "no contract code at FireVesting address");
            return;
        }
        FireVesting vesting = FireVesting(payable(inputs.vesting));
        // 식별: VestingWallet 고유 함수(duration)까지 응답해야 FireVesting으로 보고 나머지 점검을 진행.
        uint256 duration;
        try vesting.duration() returns (uint256 value) {
            duration = value;
        } catch {
            _fail(r, "address does not answer duration(): not a FireVesting");
            return;
        }
        _reportCode(r, inputs.vestingCode, "FireVesting");
        (bool ownerOk, string memory ownerText) = ownerCheckText(vesting.owner(), inputs.beneficiary);
        _expect(r, ownerOk, ownerText);
        address pending = vesting.pendingOwner();
        if (pending == address(0)) _pass(r, "no pending ownership transfer");
        else _warn(r, string.concat("ownership transfer pending to ", vm.toString(pending)));

        uint256 start = vesting.start();
        _expect(r, duration == LaunchParams.LINEAR, "duration() == 540 days (46,656,000 s)");
        _expect(r, vesting.end() == start + duration, "end() == start() + duration()");
        _checkStart(r, start, inputs.recordedVestingStart, inputs.deployStatus == STATUS_CONFIRMED);
        if (start >= LaunchParams.CLIFF) {
            _info(r, string.concat("deployed at        ", _formatUtc(start - LaunchParams.CLIFF)));
        }
        _info(r, string.concat("cliff ends (start) ", _formatUtc(start)));
        _info(r, string.concat("fully vested (end) ", _formatUtc(start + duration)));
        if (tokenOk) _checkVestingBalance(r, vesting, inputs.token, start);
    }

    /**
     * @notice 베스팅 owner 점검 문구. 실패하면 실제 owner와 기대값(기록·BENEFICIARY)을 모두 보여 줌: Ownable2Step로
     *         수령 지갑을 정상 교체한 뒤라면 기록이 아니라 새 지갑을 BENEFICIARY로 주고 다시 실행해야 함.
     */
    function ownerCheckText(address owner, address expected) public pure returns (bool ok, string memory text) {
        ok = owner == expected;
        text = ok
            ? string.concat("owner() == beneficiary ", vm.toString(owner))
            : string.concat(
                "owner() is ",
                vm.toString(owner),
                ", expected beneficiary ",
                vm.toString(expected),
                " (after a legitimate rotation: BENEFICIARY=<new owner>, deployments/README.md)"
            );
    }

    function _checkStart(Report memory r, uint256 start, uint256 recorded, bool confirmed) private view {
        _expect(
            r,
            start >= LaunchParams.CLIFF && start - LaunchParams.CLIFF <= block.timestamp,
            "start() - 180 days is in the past"
        );
        if (recorded == 0) {
            _info(r, "no recorded vesting.start to compare");
        } else if (start == recorded) {
            _pass(r, "start() matches the record exactly");
        } else if (confirmed) {
            _fail(r, string.concat("start() ", vm.toString(start), " != confirmed record ", vm.toString(recorded)));
        } else if (start > recorded && start - recorded <= MAX_INCLUSION_DELAY) {
            _pass(
                r,
                string.concat(
                    "start() is ",
                    vm.toString(start - recorded),
                    "s after the record (tx inclusion delay; on-chain value is final)"
                )
            );
        } else {
            _fail(r, string.concat("start() ", vm.toString(start), " does not match record ", vm.toString(recorded)));
        }
    }

    function _checkVestingBalance(Report memory r, FireVesting vesting, address token, uint256 start) private view {
        uint256 balance = IERC20(token).balanceOf(address(vesting));
        uint256 released = vesting.released(token);
        uint256 accounted = balance + released;
        if (accounted == LaunchParams.VESTING_AMOUNT) {
            _pass(r, string.concat("balance + released == 200,000,000 (released ", _fmt(released), ")"));
        } else if (accounted > LaunchParams.VESTING_AMOUNT) {
            _warn(r, "balance + released > 200,000,000: extra FIRE was sent to the vesting contract (guide 3.1 warns)");
        } else {
            _fail(r, string.concat("balance + released below 200,000,000: ", _fmt(accounted)));
        }
        uint256 releasable = vesting.releasable(token);
        if (block.timestamp < start) _expect(r, releasable == 0, "releasable == 0 before the cliff ends");
        else _info(r, string.concat("releasable now: ", _fmt(releasable), " FIRE"));
    }

    function _checkAllocation(Report memory r, CheckInputs memory inputs) private view {
        _section(r, "Launch allocation (WARN = changed since launch)");
        IERC20 token = IERC20(inputs.token);
        _expectLaunchBalance(r, token.balanceOf(inputs.treasurySafe), LaunchParams.TREASURY_AMOUNT, "treasury Safe");
        _checkTreasuryCode(r, inputs.treasurySafe);
        _expectLaunchBalance(r, token.balanceOf(inputs.airdropWallet), LaunchParams.AIRDROP_AMOUNT, "airdrop wallet");
        uint256 deployerBalance = token.balanceOf(inputs.deployer);
        if (inputs.hasPool) {
            if (deployerBalance >= LaunchParams.LP_AMOUNT) {
                // 풀이 있는데 배포 지갑이 아직(또는 다시) 7억 이상을 가짐: 런칭 LP가 배포 지갑에서 나가지 않았거나 회수됨
                _fail(
                    r,
                    string.concat(
                        "deployer still holds ",
                        _fmt(deployerBalance),
                        " FIRE although a pool is recorded (launch LP not funded from it, or withdrawn)"
                    )
                );
            } else {
                _info(
                    r,
                    string.concat(
                        "deployer FIRE after LP: ", _fmt(deployerBalance), " (rounding dust and collected LP fees)"
                    )
                );
            }
        } else {
            _expectLaunchBalance(r, deployerBalance, LaunchParams.LP_AMOUNT, "deployer (pre-LP)");
        }
    }

    function _expectLaunchBalance(Report memory r, uint256 actual, uint256 expected, string memory who) private pure {
        string memory text = string.concat(who, " holds ", _fmt(actual), " FIRE");
        if (actual == expected) _pass(r, text);
        else _warn(r, string.concat(text, " (launch allocation ", _fmt(expected), ")"));
    }

    /// @dev 메인넷: Safe가 아니거나 EIP-7702 위임 EOA(단일 키)면 FAIL. 2-of-3 미만 Safe는 WARN(배포 후 Safe 설정이
    ///      바뀔 수 있는 현재 상태 점검이므로). Deploy는 배포 시점에 2-of-3 이상을 강제함.
    function _checkTreasuryCode(Report memory r, address treasury) private view {
        if (LaunchGuards.isDelegatedEOA(treasury)) {
            string memory text = "treasury is an EIP-7702 delegated EOA (single key), not a Safe";
            if (_isMainnet()) _fail(r, text);
            else _warn(r, string.concat(text, " (acceptable on testnets only)"));
            return;
        }
        (bool isSafe, uint256 threshold, uint256 owners) = LaunchGuards.probeSafe(treasury);
        if (isSafe) {
            string memory text = string.concat(
                "treasury is a Safe: threshold ", vm.toString(threshold), " of ", vm.toString(owners), " owners"
            );
            if (threshold >= LaunchParams.SAFE_MIN_THRESHOLD && owners >= LaunchParams.SAFE_MIN_OWNERS) {
                _pass(r, text);
            } else {
                _warn(r, string.concat(text, " (guide requires >= 2-of-3)"));
            }
            (bool modulesKnown, bool hasModules) = LaunchGuards.safeHasModules(treasury);
            if (!modulesKnown) {
                _warn(r, "treasury Safe modules could not be read (getModulesPaginated)");
            } else if (hasModules) {
                _warn(r, "treasury Safe has enabled modules: a module can move funds without owner signatures");
            }
        } else if (_isMainnet()) {
            _fail(r, "treasury is not a deployed Safe on Base mainnet");
        } else {
            _warn(r, "treasury is not a deployed Safe (acceptable on testnets only)");
        }
    }

    function _checkPool(Report memory r, CheckInputs memory inputs, bool tokenOk) private view {
        _section(r, "Uniswap V3 pool + LP position");
        address positionManager = _checkPositionManager(r, inputs.positionManager);
        if (!tokenOk || positionManager.code.length == 0) {
            _fail(r, "token or position manager missing; pool checks skipped");
            return;
        }
        INonfungiblePositionManager npm = INonfungiblePositionManager(positionManager);
        IUniswapV3Factory factory = IUniswapV3Factory(npm.factory());
        (address e0, address e1) = PoolMath.sortTokens(inputs.token, npm.WETH9());
        (uint256 tokenId, LaunchPositions.Position memory p) = _resolvePosition(r, inputs, npm, factory, e0, e1);
        if (tokenId == 0) {
            _checkAllowance(r, inputs, positionManager);
            return;
        }
        address pool = factory.getPool(p.token0, p.token1, p.fee);
        if (inputs.pool != address(0)) _expect(r, pool == inputs.pool, "factory.getPool matches the recorded pool");
        if (pool.code.length == 0) {
            _fail(r, "pool has no code");
            return;
        }
        (, address owner) = LaunchPositions.ownerOf(npm, tokenId);
        _checkLaunchSize(r, inputs.minLiquidity, p.liquidity);
        _checkLiquidity(r, inputs, tokenId, p.liquidity, owner != inputs.deployer);
        _expect(
            r,
            p.liquidity > 0 && IUniswapV3Pool(pool).liquidity() >= p.liquidity,
            "pool active liquidity includes the position"
        );
        _checkLpOwner(r, owner, inputs);
        _checkAllowance(r, inputs, positionManager);
        _logPrice(r, pool, p.token0 == inputs.token, inputs.initialSqrtPriceX96);
    }

    /**
     * @dev 기록의 pool.positionManager가 이 체인의 Uniswap V3 NonfungiblePositionManager(주소표)인지 확인하고, 이후 점검에는
     *      항상 주소표의 주소를 씀(가짜 NPM이 "락업된 전체 범위 포지션"을 꾸며 응답하는 것을 막음). 주소표가 없는 체인
     *      (로컬 등)은 기록 값을 그대로 씀.
     */
    function _checkPositionManager(Report memory r, address recorded) private view returns (address) {
        if (!UniswapV3Addresses.isSupported(block.chainid)) return recorded;
        UniswapV3Addresses.Deployment memory uni = UniswapV3Addresses.forChain(block.chainid);
        bool tableOk = uni.positionManager.code.length != 0
            && INonfungiblePositionManager(uni.positionManager).factory() == uni.factory
            && INonfungiblePositionManager(uni.positionManager).WETH9() == uni.weth;
        _expect(
            r,
            recorded == uni.positionManager && tableOk,
            string.concat("pool.positionManager is the Uniswap V3 position manager ", vm.toString(uni.positionManager))
        );
        return uni.positionManager;
    }

    /**
     * @dev 기록(또는 LP_TOKEN_ID)의 id가 FIRE/WETH 전체 범위 포지션인지 온체인에서 확인(없는 id도 revert 없이 FAIL).
     *      id가 없거나(pending 기록) 틀리면 배포 지갑의 NFT에서 런칭 크기(계획 하한 − 락커 수수료 허용 1%) 이상의
     *      포지션 중 유동성이 가장 큰 것을 찾아 그 id로 나머지 점검을 이어감. 소액 포지션(누구나 배포 지갑으로 보낼 수 있음)은
     *      고르지 않음. 찾지 못하면 tokenId = 0 (multicall 미채굴·실패, 이미 락업했는데 LP_TOKEN_ID를 안 준 경우, 또는 런칭 전에
     *      받은 NFT가 탐색 범위(가장 오래된 100개)를 채운 경우 → lpTokenIdHint).
     */
    function _resolvePosition(
        Report memory r,
        CheckInputs memory inputs,
        INonfungiblePositionManager npm,
        IUniswapV3Factory factory,
        address token0,
        address token1
    ) private view returns (uint256 tokenId, LaunchPositions.Position memory p) {
        if (inputs.tokenId != 0) {
            bool exists;
            (exists, p) = LaunchPositions.read(npm, inputs.tokenId);
            if (exists && LaunchPositions.isFullRange(factory, p, token0, token1, inputs.fee)) {
                _pass(
                    r, string.concat("LP NFT #", vm.toString(inputs.tokenId), " is the FIRE/WETH full-range position")
                );
                return (inputs.tokenId, p);
            }
            _fail(
                r,
                string.concat(
                    "LP NFT #",
                    vm.toString(inputs.tokenId),
                    exists ? " is NOT the FIRE/WETH full-range position" : " does not exist"
                )
            );
        }
        LaunchPositions.Search memory found = LaunchPositions.find(
            npm,
            factory,
            inputs.deployer,
            token0,
            token1,
            inputs.fee,
            PoolMath.liquidityFloor(inputs.minLiquidity, LaunchParams.MAX_LOCK_FEE_BPS),
            LaunchParams.MAX_POSITION_SCAN
        );
        tokenId = _reportSearch(r, found, inputs.tokenId == 0);
        if (tokenId != 0) (, p) = LaunchPositions.read(npm, tokenId);
    }

    /// @dev 배포 지갑 탐색 결과 보고. 런칭 크기 포지션이 없으면 0 (pending 기록이면 FAIL).
    function _reportSearch(Report memory r, LaunchPositions.Search memory found, bool pending)
        private
        pure
        returns (uint256)
    {
        uint256 ignored = found.matches - found.eligible;
        if (found.eligible == 0) {
            if (pending) {
                string memory missing;
                if (found.held > LaunchParams.MAX_POSITION_SCAN) {
                    missing = "no launch-sized FIRE/WETH full-range position among the deployer's oldest LP NFTs";
                } else if (ignored == 0) {
                    missing = "no FIRE/WETH full-range LP position recorded or held by the deployer (multicall mined?)";
                } else {
                    missing = string.concat(
                        "the deployer holds only ",
                        vm.toString(ignored),
                        " small FIRE/WETH position(s) below the launch minimum (not the launch LP)"
                    );
                }
                _fail(r, missing);
                _info(r, lpTokenIdHint(found.held));
            }
            return 0;
        }
        string memory text = string.concat("deployer holds FIRE/WETH full-range position #", vm.toString(found.tokenId));
        if (found.eligible > 1) text = string.concat(text, " (largest of ", vm.toString(found.eligible), ")");
        if (ignored > 0) text = string.concat(text, " (", vm.toString(ignored), " smaller position(s) ignored)");
        text = string.concat(text, ": record it with CreatePool --sig 'confirm()'");
        if (pending) _warn(r, text);
        else _info(r, text);
        return found.tokenId;
    }

    /**
     * @notice 배포 지갑에서 런칭 포지션을 찾지 못했을 때의 안내 (held = 배포 지갑의 NFT 수).
     * @dev 탐색은 가장 오래된 NFT부터 MAX_POSITION_SCAN개. 런칭 전에 그보다 많은 NFT가 배포 지갑으로 들어오면 런칭 포지션이
     *      범위 밖에 놓이므로 그 사실과 LP_TOKEN_ID 지정을 안내함.
     */
    function lpTokenIdHint(uint256 held) public pure returns (string memory) {
        if (held <= LaunchParams.MAX_POSITION_SCAN) return "if the LP NFT is already locked, set LP_TOKEN_ID=<id>";
        return string.concat(
            "checked only the oldest ",
            vm.toString(LaunchParams.MAX_POSITION_SCAN),
            " of the deployer's ",
            vm.toString(held),
            " LP NFTs (NFTs received before the launch come first): set LP_TOKEN_ID=<launch NFT id>"
        );
    }

    /// @dev 점검하는 포지션이 기록된 계획의 런칭 크기 이상인지 (락커 수수료 허용 1% 차감). 계획이 없으면 생략.
    function _checkLaunchSize(Report memory r, uint256 minLiquidity, uint128 liquidity) private pure {
        if (minLiquidity == 0) {
            _info(r, "launch-size check skipped (no pool plan recorded)");
            return;
        }
        uint256 floor = PoolMath.liquidityFloor(minLiquidity, LaunchParams.MAX_LOCK_FEE_BPS);
        _expect(
            r,
            liquidity >= floor,
            string.concat(
                "position is launch-sized: liquidity ",
                vm.toString(liquidity),
                " >= ",
                vm.toString(floor),
                " (recorded plan minimum less 1% lock-fee allowance)"
            )
        );
    }

    /**
     * @dev 유동성 비교 기준: confirmLock()의 .lpLock.liquidity(락업 후)가 있으면 그 값, 없으면 confirm()의 pool.liquidity.
     *      다른 id를 점검하게 되면(기록 id가 틀린 경우 등) 기록 값과 비교하지 않음.
     */
    function _checkLiquidity(
        Report memory r,
        CheckInputs memory inputs,
        uint256 tokenId,
        uint128 liquidity,
        bool heldByOther
    ) private pure {
        bool sameId = tokenId == inputs.tokenId;
        uint256 recorded = sameId ? inputs.recordedLiquidity : 0;
        uint256 locked = sameId ? inputs.lockLiquidity : 0;
        if (locked != 0) {
            _checkLockFee(r, recorded, locked);
            _compareLiquidity(r, liquidity, locked, "the lock (lpLock.liquidity)", false);
        } else if (recorded != 0) {
            _compareLiquidity(r, liquidity, recorded, "creation (pool.liquidity)", heldByOther);
        } else {
            _info(r, string.concat("position liquidity ", vm.toString(liquidity), " (nothing recorded)"));
        }
    }

    function _compareLiquidity(Report memory r, uint128 liquidity, uint256 baseline, string memory since, bool lockHint)
        private
        pure
    {
        if (liquidity == baseline) {
            _pass(r, string.concat("position liquidity unchanged since ", since, ": ", vm.toString(liquidity)));
        } else if (liquidity > baseline) {
            _warn(r, string.concat("position liquidity increased since ", since));
        } else {
            uint256 dropBps = Math.mulDiv(baseline - liquidity, PoolMath.BPS, baseline, Math.Rounding.Ceil);
            string memory text = string.concat(
                "position liquidity DECREASED since ", since, " by ", _fmtBps(dropBps), " (liquidity removed)"
            );
            if (lockHint && dropBps <= LaunchParams.MAX_LOCK_FEE_BPS) {
                text = string.concat(
                    text,
                    "; if a locker took it as its LP fee, record the post-lock baseline: CreatePool --sig 'confirmLock()'"
                );
            }
            _fail(r, text);
        }
    }

    /// @dev confirmLock()이 기록한 락업 수수료(기록된 pool.liquidity → lpLock.liquidity)가 상한(1%) 이하인지 공개.
    function _checkLockFee(Report memory r, uint256 recorded, uint256 locked) private pure {
        if (recorded == 0) {
            _info(r, string.concat("post-lock liquidity recorded: ", vm.toString(locked)));
            return;
        }
        if (locked >= recorded) {
            _info(r, "no LP fee was taken at lock (lpLock.liquidity >= pool.liquidity)");
            return;
        }
        uint256 feeBps = Math.mulDiv(recorded - locked, PoolMath.BPS, recorded, Math.Rounding.Ceil);
        _expect(
            r,
            feeBps <= LaunchParams.MAX_LOCK_FEE_BPS,
            string.concat(
                "locker LP fee at lock: ",
                _fmtBps(feeBps),
                " of the position (",
                vm.toString(recorded),
                " -> ",
                vm.toString(locked),
                ", limit 1.00%)"
            )
        );
    }

    function _checkAllowance(Report memory r, CheckInputs memory inputs, address positionManager) private view {
        uint256 leftover = IERC20(inputs.token).allowance(inputs.deployer, positionManager);
        if (leftover == 0) {
            _pass(r, "deployer -> position manager FIRE allowance is 0");
        } else {
            _warn(
                r,
                string.concat(
                    "deployer still approves the position manager for ",
                    _fmt(leftover),
                    " FIRE: cast send <FIRE> 'approve(address,uint256)' <NPM> 0"
                )
            );
        }
    }

    /// @dev 풀 기록이 없어도(예: CreatePool 실패 후) Uniswap이 있는 체인이면 남은 승인을 확인.
    function _checkAllowanceWithoutPool(Report memory r, CheckInputs memory inputs) private view {
        if (!UniswapV3Addresses.isSupported(block.chainid)) return;
        address npm = UniswapV3Addresses.forChain(block.chainid).positionManager;
        if (npm.code.length == 0) return;
        _section(r, "Uniswap V3 (no pool recorded yet)");
        _checkAllowance(r, inputs, npm);
    }

    function _checkLpOwner(Report memory r, address owner, CheckInputs memory inputs) private view {
        string memory who = vm.toString(owner);
        if (inputs.lpLocker != address(0)) {
            string memory text = string.concat("LP NFT held by the locker ", vm.toString(inputs.lpLocker));
            if (owner != inputs.lpLocker) text = string.concat(text, " (actual owner ", who, ")");
            _expect(r, owner == inputs.lpLocker, text);
        } else if (owner == inputs.deployer) {
            _warn(r, "LP NFT still held by the deployer: lock it for 365 days (UNCX / Team Finance)");
        } else if (owner.code.length > 0) {
            _warn(r, string.concat("LP NFT held by contract ", who, ": set LP_LOCKER to confirm it is the locker"));
        } else {
            _warn(r, string.concat("LP NFT held by EOA ", who, " (not a locker)"));
        }
    }

    function _logPrice(Report memory r, address pool, bool fireIsToken0, uint160 initialSqrtPrice) private view {
        (uint160 sqrtPrice, int24 tick,,,,,) = IUniswapV3Pool(pool).slot0();
        uint256 weiPerFire = fireIsToken0 ? PoolMath.price0In1Wad(sqrtPrice) : PoolMath.price1In0Wad(sqrtPrice);
        _info(r, string.concat("current price: 1 FIRE = ", _fmt(weiPerFire), " ETH (tick ", vm.toString(tick), ")"));
        if (initialSqrtPrice != 0) {
            uint256 initialWei =
                fireIsToken0 ? PoolMath.price0In1Wad(initialSqrtPrice) : PoolMath.price1In0Wad(initialSqrtPrice);
            _info(r, string.concat("initial price: 1 FIRE = ", _fmt(initialWei), " ETH"));
        }
    }

    // ───────────────────────── 보고서 출력 ─────────────────────────

    function _logHeader(CheckInputs memory inputs) private view {
        console.log("=== FIRE post-deploy check (%s, chainId %s) ===", _networkName(block.chainid), block.chainid);
        console.log("block %s at %s", block.number, _formatUtc(block.timestamp));
        console.log("FireToken     :", _explorerAddress(inputs.token));
        console.log("FireVesting   :", _explorerAddress(inputs.vesting));
        console.log("deployer      :", _explorerAddress(inputs.deployer));
        console.log("beneficiary   :", _explorerAddress(inputs.beneficiary));
        console.log("treasury Safe :", _explorerAddress(inputs.treasurySafe));
        console.log("airdrop wallet:", _explorerAddress(inputs.airdropWallet));
        if (inputs.hasPool) {
            console.log("pool          :", _explorerAddress(inputs.pool));
            if (inputs.tokenId != 0) console.log("LP NFT id     :", inputs.tokenId);
            else console.log("LP NFT id     : (not recorded yet - pending)");
        }
    }

    function _section(Report memory r, string memory title) private pure {
        if (r.verbose) console.log(string.concat("--- ", title, " ---"));
    }

    function _expect(Report memory r, bool ok, string memory text) private pure {
        if (ok) _pass(r, text);
        else _fail(r, text);
    }

    function _pass(Report memory r, string memory text) private pure {
        ++r.passed;
        if (r.verbose) console.log(string.concat("[PASS] ", text));
    }

    function _warn(Report memory r, string memory text) private pure {
        ++r.warned;
        if (r.verbose) console.log(string.concat("[WARN] ", text));
    }

    function _fail(Report memory r, string memory text) private pure {
        ++r.failed;
        if (r.verbose) console.log(string.concat("[FAIL] ", text));
    }

    function _info(Report memory r, string memory text) private pure {
        if (r.verbose) console.log(string.concat("[INFO] ", text));
    }
}
