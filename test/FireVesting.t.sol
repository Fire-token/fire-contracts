// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, Vm, stdError} from "forge-std/Test.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {VestingWallet} from "@openzeppelin/contracts/finance/VestingWallet.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Errors} from "@openzeppelin/contracts/utils/Errors.sol";
import {FireToken} from "../src/FireToken.sol";
import {FireVesting} from "../src/FireVesting.sol";
import {CoreBytecode} from "./FireToken.t.sol";

/// @dev ETH를 받을 수 없는 소유자(receive/fallback 없음). 베스팅 소유권 이전만 실행할 수 있다.
contract CoreEtherRejector {
    address public immutable CONTROLLER;

    error CoreEtherRejectorUnauthorized();

    constructor(address controller) {
        CONTROLLER = controller;
    }

    function transferVestingOwnership(FireVesting vesting, address newOwner) external {
        if (msg.sender != CONTROLLER) revert CoreEtherRejectorUnauthorized();
        vesting.transferOwnership(newOwner);
    }
}

/// @dev 호출 능력이 없는 수령 주소(오타 주소, 다른 체인에만 배포된 Safe 주소, 함수 없는 컨트랙트 등)를 흉내 낸다.
contract CoreInertBeneficiary {}

/// @dev [회귀 테스트 전용 변형, 배포 금지] 수익자 전용 "긴급 인출" 함수를 FireVesting 에 덧붙였다 (클리프·선형 일정 무력화).
///      기존 함수만 호출하는 동작 테스트로는 드러나지 않으므로 외부 함수 집합 고정이 필요하다.
contract CoreVestingWithSweep is FireVesting {
    constructor(address beneficiary, uint64 cliffSeconds, uint64 linearSeconds)
        FireVesting(beneficiary, cliffSeconds, linearSeconds)
    {}

    function coreSweep(address token) external onlyOwner {
        SafeERC20.safeTransfer(IERC20(token), owner(), IERC20(token).balanceOf(address(this)));
    }
}

/// @title FireVesting 테스트
/// @notice 가이드 3.1의 스케줄(배포 + 180일 클리프 → 540일 선형, 총 2억 FIRE)과 해제 수량 표,
///         누구나 호출 가능한 release, Ownable2Step 수령 지갑 교체, renounce 차단, 추가 입금(소급) 동작, ETH 베스팅,
///         외부 함수 집합·바이트코드 고정, 최초 수익자 지정의 한계(2단계 보호 범위 밖)를 검증한다.
///         일정은 초 단위이며 "개월"은 30일 환산이다 (달력 월과 다름: test_CalendarMonths_DifferFromThirtyDaySchedule).
contract FireVestingTest is Test {
    uint64 internal constant CLIFF_SECONDS = 15_552_000; // 180일 (30일 × 6. 달력 6개월 = 181~184일보다 짧음)
    uint64 internal constant LINEAR_SECONDS = 46_656_000; // 540일 (30일 × 18)
    uint256 internal constant DEPLOY_TS = 1_794_787_200; // 2026-11-16 00:00:00 UTC (가정한 배포 시각)
    uint256 internal constant START = 1_810_339_200; // 2027-05-15 00:00:00 UTC = 배포 + 180일 (클리프 종료)
    uint256 internal constant END = 1_856_995_200; // 2028-11-05 00:00:00 UTC = 배포 + 720일 (전량 해제)

    uint256 internal constant VESTING_SUPPLY = 200_000_000e18;
    uint256 internal constant DEPLOYER_SUPPLY = 800_000_000e18;

    // 가이드 3.1 "해제 수량 계산" 표의 정확한 온체인 값 (wei, 내림). 표의 "6/12/24개월"은 배포 +180/+360/+720일이다.
    uint256 internal constant VESTED_ONE_SECOND_AFTER_START = 4_286_694_101_508_916_323; // 약 4.29 FIRE
    uint256 internal constant VESTED_AT_START_PLUS_ONE_DAY = 370_370_370_370_370_370_370_370; // 배포 +181일, 약 370,370.37 FIRE
    uint256 internal constant VESTED_AT_DAY_360 = 66_666_666_666_666_666_666_666_666; // 배포 +360일, 2억 / 3 (내림)

    // 달력 월 기준 시각 (2026-11-16 00:00:00 UTC 배포 가정)
    uint256 internal constant SIX_CALENDAR_MONTHS = 1_810_425_600; // 2027-05-16 00:00:00 UTC = START + 1일
    uint256 internal constant TWELVE_CALENDAR_MONTHS = 1_826_323_200; // 2027-11-16 00:00:00 UTC = 배포 +365일
    uint256 internal constant TWENTY_FOUR_CALENDAR_MONTHS = 1_857_945_600; // 2028-11-16 00:00:00 UTC = 배포 +731일

    /// @dev 고정 소스(src/FireVesting.sol + OpenZeppelin v5.7.0)를 프로젝트 빌드 설정(solc 0.8.30, optimizer 200 runs,
    ///      evm cancun)으로 컴파일한 바이트코드 해시 (끝의 CBOR 메타데이터 제외).
    ///      - 생성 코드(type(FireVesting).creationCode): 생성자 로직 포함. 배포 조건과 무관
    ///      - 런타임 코드: DEPLOY_TS 에 (cliff 180일, linear 540일)로 배포. immutable 은 start·duration 뿐이고
    ///        수익자는 storage 에 있으므로 이 조건만 고정하면 된다.
    bytes32 internal constant FIRE_VESTING_CREATION_CODE_HASH =
        0x25a9f23fd9d5312ff50a517ebd51ca0a5ecd9a1d4ca8f8df8d6d84c404c5d36f;
    bytes32 internal constant FIRE_VESTING_RUNTIME_CODE_HASH =
        0x5a3a4a3d98bc56ce340fba6d16408e4e90b10de1535466ce257977e840f301b5;

    FireToken internal token;
    FireVesting internal vesting;

    address internal deployer = makeAddr("deployer");
    address internal beneficiary = makeAddr("beneficiary");
    address internal newWallet = makeAddr("newWallet");
    address internal stranger = makeAddr("stranger");

    function setUp() public {
        vm.warp(DEPLOY_TS);
        vesting = new FireVesting(beneficiary, CLIFF_SECONDS, LINEAR_SECONDS);
        vm.prank(deployer);
        token = new FireToken(address(vesting));
    }

    // ─────────────────────────────────────────────────────────────
    // 배포 파라미터
    // ─────────────────────────────────────────────────────────────

    function test_Deployment_Parameters() public view {
        assertEq(START, DEPLOY_TS + CLIFF_SECONDS);
        assertEq(END, START + LINEAR_SECONDS);

        assertEq(vesting.start(), DEPLOY_TS + CLIFF_SECONDS);
        assertEq(vesting.duration(), LINEAR_SECONDS);
        assertEq(vesting.end(), vesting.start() + vesting.duration());
        assertEq(vesting.end(), END);
        assertEq(vesting.end() - DEPLOY_TS, 720 days); // 180일 클리프 + 540일 선형 = 720일 (30일 × 24, 달력 24개월보다 11일 짧음)
        assertEq(vesting.owner(), beneficiary);
        assertEq(vesting.pendingOwner(), address(0));

        assertEq(token.balanceOf(address(vesting)), VESTING_SUPPLY);
        assertEq(vesting.released(address(token)), 0);
        assertEq(vesting.releasable(address(token)), 0);
        assertEq(vesting.released(), 0);
        assertEq(vesting.releasable(), 0);
    }

    function test_Deployment_EmitsOwnershipTransferredToBeneficiary() public {
        vm.recordLogs();
        FireVesting fresh = new FireVesting(beneficiary, CLIFF_SECONDS, LINEAR_SECONDS);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(logs.length, 1);
        assertEq(logs[0].emitter, address(fresh));
        assertEq(logs[0].topics[0], Ownable.OwnershipTransferred.selector);
        assertEq(logs[0].topics[1], bytes32(0));
        assertEq(logs[0].topics[2], bytes32(uint256(uint160(beneficiary))));
    }

    function testFuzz_Deployment_StartIsDeployTimePlusCliff(uint64 deployTs, uint64 cliff, uint64 linear) public {
        cliff = uint64(bound(cliff, 0, type(uint64).max - deployTs));
        vm.warp(deployTs);
        FireVesting fresh = new FireVesting(beneficiary, cliff, linear);

        assertEq(fresh.start(), uint256(deployTs) + cliff);
        assertEq(fresh.duration(), linear);
        assertEq(fresh.end(), uint256(deployTs) + cliff + linear);
        assertEq(fresh.owner(), beneficiary);
    }

    function test_RevertWhen_BeneficiaryIsZeroAddress() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new FireVesting(address(0), CLIFF_SECONDS, LINEAR_SECONDS);
    }

    function test_RevertWhen_StartOverflowsUint64() public {
        vm.warp(type(uint64).max - 10);
        vm.expectRevert(stdError.arithmeticError);
        new FireVesting(beneficiary, 11, LINEAR_SECONDS);
    }

    function test_RevertWhen_BlockTimestampExceedsUint64() public {
        uint256 farFuture = uint256(type(uint64).max) + 1;
        vm.warp(farFuture);
        vm.expectRevert(abi.encodeWithSelector(SafeCast.SafeCastOverflowedUintDowncast.selector, uint8(64), farFuture));
        new FireVesting(beneficiary, CLIFF_SECONDS, LINEAR_SECONDS);
    }

    // ─────────────────────────────────────────────────────────────
    // 클리프 기간 (배포 ~ +180일: 해제 0)
    // ─────────────────────────────────────────────────────────────

    function testFuzz_Releasable_ZeroBeforeStart(uint256 t) public {
        t = bound(t, DEPLOY_TS, START - 1);
        vm.warp(t);
        assertEq(vesting.releasable(address(token)), 0);
        assertEq(vesting.vestedAmount(address(token), SafeCast.toUint64(t)), 0);

        // 클리프 중 release를 호출해도 아무것도 이동하지 않는다
        vm.prank(stranger);
        vesting.release(address(token));
        assertEq(token.balanceOf(beneficiary), 0);
        assertEq(token.balanceOf(address(vesting)), VESTING_SUPPLY);
        assertEq(vesting.released(address(token)), 0);
    }

    function testFuzz_VestedAmount_ZeroForAnyTimestampBeforeStart(uint64 t) public view {
        t = uint64(bound(t, 0, START - 1));
        assertEq(vesting.vestedAmount(address(token), t), 0);
    }

    function test_CliffBoundary() public {
        vm.warp(START - 1);
        assertEq(vesting.releasable(address(token)), 0);

        vm.warp(START); // 클리프 종료 시점: 경과 0초이므로 아직 0
        assertEq(vesting.releasable(address(token)), 0);

        vm.warp(START + 1); // 0에서 시작해 초 단위로 증가 (클리프 직후 25% 일시 해제 없음)
        assertEq(vesting.releasable(address(token)), VESTED_ONE_SECOND_AFTER_START);
        assertEq(VESTED_ONE_SECOND_AFTER_START, VESTING_SUPPLY / LINEAR_SECONDS);
    }

    // ─────────────────────────────────────────────────────────────
    // 가이드 3.1 해제 수량 표 (표의 "N개월" = 배포 + N × 30일)
    // ─────────────────────────────────────────────────────────────

    function test_GuideTable_ZeroThroughDay180() public {
        vm.warp(DEPLOY_TS + 180 days - 1);
        assertEq(vesting.releasable(address(token)), 0);
        vm.warp(DEPLOY_TS + 180 days);
        assertEq(vesting.releasable(address(token)), 0);
    }

    function test_GuideTable_Day181_OneDayOfLinear() public {
        vm.warp(DEPLOY_TS + 180 days + 1 days);
        assertEq(vesting.releasable(address(token)), VESTED_AT_START_PLUS_ONE_DAY);
        assertEq(VESTED_AT_START_PLUS_ONE_DAY, VESTING_SUPPLY * 86_400 / 46_656_000); // 2억 × 1일 ÷ 540일
        assertApproxEqRel(VESTED_AT_START_PLUS_ONE_DAY, 370_000e18, 0.002e18); // 가이드 표기 "약 370,000 FIRE"
    }

    function test_GuideTable_Day360_OneThird() public {
        vm.warp(DEPLOY_TS + 360 days); // 표의 "12개월" = 배포 +360일 = 선형 구간 180일 경과
        assertEq(vesting.releasable(address(token)), VESTED_AT_DAY_360);
        assertEq(VESTED_AT_DAY_360, VESTING_SUPPLY / 3);
        assertApproxEqRel(VESTED_AT_DAY_360, 66_670_000e18, 0.001e18); // 가이드 표기 "약 66,670,000 FIRE (1/3)"
    }

    function test_GuideTable_FullyVestedFromDay720() public {
        vm.warp(END);
        assertEq(vesting.releasable(address(token)), VESTING_SUPPLY);
        vm.warp(END + 1);
        assertEq(vesting.releasable(address(token)), VESTING_SUPPLY);
        vm.warp(END + 3650 days);
        assertEq(vesting.releasable(address(token)), VESTING_SUPPLY);
        assertEq(vesting.vestedAmount(address(token), type(uint64).max), VESTING_SUPPLY);
    }

    /// @dev 일정은 초 단위(1개월 = 30일 환산)라 달력 월과 어긋난다. 2026-11-16 00:00 UTC 배포를 가정하면:
    ///      - 클리프 종료 2027-05-15 00:00 = 달력 6개월 하루 전 → 2027-05-15 23:59:59 에 이미 약 370,366 FIRE 해제 가능
    ///      - 달력 12개월(2027-11-16): 1/3(66,666,666.67)이 아니라 68,518,518.52 FIRE (선형 185일 경과, +2.8%)
    ///      - 전량 해제 2028-11-05 = 달력 24개월(2028-11-16)보다 11일 이름
    ///      공개 자료에는 "배포 +180일 / +360일 / +720일"과 배포 후 start()·end()로 읽은 UTC 시각을 적는다.
    function test_CalendarMonths_DifferFromThirtyDaySchedule() public {
        assertEq(SIX_CALENDAR_MONTHS - START, 1 days);
        vm.warp(SIX_CALENDAR_MONTHS - 1);
        assertEq(vesting.releasable(address(token)), 370_366_083_676_268_861_454_046);
        assertEq(vesting.releasable(address(token)), VESTING_SUPPLY * (1 days - 1) / LINEAR_SECONDS);

        assertEq(TWELVE_CALENDAR_MONTHS - START, 185 days);
        vm.warp(TWELVE_CALENDAR_MONTHS);
        assertEq(vesting.releasable(address(token)), 68_518_518_518_518_518_518_518_518);
        assertGt(vesting.releasable(address(token)), VESTED_AT_DAY_360);

        assertEq(TWENTY_FOUR_CALENDAR_MONTHS - END, 11 days);
        vm.warp(END);
        assertEq(vesting.releasable(address(token)), VESTING_SUPPLY);
    }

    /// @dev vestedAmount(token, 시각)은 view 함수라 시간을 기다리지 않고도 미래 해제량을 조회할 수 있다
    ///      (테스트넷 리허설에서 `cast call`로 표 값을 확인하는 방법).
    function test_VestedAmount_PreviewWithoutWaiting() public view {
        assertEq(vesting.vestedAmount(address(token), SafeCast.toUint64(START + 1 days)), VESTED_AT_START_PLUS_ONE_DAY);
        assertEq(vesting.vestedAmount(address(token), SafeCast.toUint64(DEPLOY_TS + 360 days)), VESTED_AT_DAY_360);
        assertEq(vesting.vestedAmount(address(token), SafeCast.toUint64(END)), VESTING_SUPPLY);
        assertEq(vesting.releasable(address(token)), 0);
    }

    // ─────────────────────────────────────────────────────────────
    // 선형 수식 / 단조성
    // ─────────────────────────────────────────────────────────────

    function testFuzz_VestedAmount_MatchesLinearFormula(uint64 t) public view {
        t = uint64(bound(t, START, END - 1));
        assertEq(vesting.vestedAmount(address(token), t), VESTING_SUPPLY * (t - START) / LINEAR_SECONDS);
    }

    /// @dev 스케줄 주변 구간(배포 ~ 종료 + 30일)에 집중한 단조성 검사.
    function testFuzz_VestedAmount_MonotonicAndCapped(uint64 t1, uint64 t2) public view {
        t1 = uint64(bound(t1, DEPLOY_TS, END + 30 days));
        t2 = uint64(bound(t2, t1, END + 30 days));
        uint256 v1 = vesting.vestedAmount(address(token), t1);
        uint256 v2 = vesting.vestedAmount(address(token), t2);
        assertLe(v1, v2);
        assertLe(v2, VESTING_SUPPLY);
    }

    /// @dev uint64 전 구간에 대한 단조성 검사.
    function testFuzz_VestedAmount_MonotonicOverFullRange(uint64 t1, uint64 t2) public view {
        if (t1 > t2) (t1, t2) = (t2, t1);
        uint256 v1 = vesting.vestedAmount(address(token), t1);
        uint256 v2 = vesting.vestedAmount(address(token), t2);
        assertLe(v1, v2);
        assertLe(v2, VESTING_SUPPLY);
    }

    /// @dev release는 잔고와 누적 해제량을 맞바꿀 뿐이므로 어떤 시각의 vestedAmount도 바꾸지 않는다.
    function testFuzz_VestedAmount_IndependentOfReleases(uint256 releaseAt, uint64 queryAt) public {
        releaseAt = bound(releaseAt, DEPLOY_TS, END + 30 days);
        uint256 vestedBefore = vesting.vestedAmount(address(token), queryAt);

        vm.warp(releaseAt);
        vesting.release(address(token));

        assertEq(vesting.vestedAmount(address(token), queryAt), vestedBefore);
    }

    // ─────────────────────────────────────────────────────────────
    // release(token): 누구나 호출, 항상 owner()에게 전송
    // ─────────────────────────────────────────────────────────────

    function test_Release_AnyoneCanCallAndOwnerReceives() public {
        vm.warp(START + 30 days);
        uint256 expected = VESTING_SUPPLY * 30 days / LINEAR_SECONDS;

        vm.expectEmit(true, false, false, true, address(vesting));
        emit VestingWallet.ERC20Released(address(token), expected);
        vm.expectEmit(true, true, false, true, address(token));
        emit IERC20.Transfer(address(vesting), beneficiary, expected);
        vm.prank(stranger);
        vesting.release(address(token));

        assertEq(token.balanceOf(beneficiary), expected);
        assertEq(token.balanceOf(stranger), 0);
        assertEq(vesting.released(address(token)), expected);
        assertEq(vesting.releasable(address(token)), 0);
        assertEq(token.balanceOf(address(vesting)), VESTING_SUPPLY - expected);
    }

    function testFuzz_Release_AnyCallerAlwaysPaysOwner(address caller, uint256 t) public {
        vm.assume(caller != beneficiary && caller != address(vesting));
        t = bound(t, DEPLOY_TS, END + 365 days);
        vm.warp(t);
        uint256 expected = vesting.vestedAmount(address(token), SafeCast.toUint64(t));
        uint256 callerBefore = token.balanceOf(caller);

        vm.prank(caller);
        vesting.release(address(token));

        assertEq(token.balanceOf(beneficiary), expected);
        assertEq(token.balanceOf(caller), callerBefore);
        assertEq(vesting.released(address(token)), expected);
    }

    function testFuzz_Release_RepeatedReleasesTrackVestedAmount(uint32[8] memory gaps, uint256 callerSeed) public {
        uint256 t = DEPLOY_TS;
        for (uint256 i; i < gaps.length; ++i) {
            t += bound(gaps[i], 0, 120 days);
            vm.warp(t);
            address caller = address(uint160(uint256(keccak256(abi.encode(callerSeed, i)))));
            vm.prank(caller);
            vesting.release(address(token));

            uint256 vested = vesting.vestedAmount(address(token), SafeCast.toUint64(t));
            assertEq(vesting.released(address(token)), vested);
            assertEq(token.balanceOf(beneficiary), vested);
            assertEq(token.balanceOf(address(vesting)) + vesting.released(address(token)), VESTING_SUPPLY);
            assertEq(vesting.releasable(address(token)), 0);
        }

        vm.warp(END);
        vesting.release(address(token));
        assertEq(token.balanceOf(beneficiary), VESTING_SUPPLY);
        assertEq(token.balanceOf(address(vesting)), 0);
        assertEq(vesting.released(address(token)), VESTING_SUPPLY);
    }

    /// @dev 30일 간격 24회 release: 1~6회차(배포 +30~+180일)는 0, 7~24회차는 매회 약 2억/18 (= 11,111,111.11 FIRE), 합계 2억.
    function test_Release_Every30DaysWalkthrough() public {
        uint256 previous;
        for (uint256 month = 1; month <= 24; ++month) {
            vm.warp(DEPLOY_TS + month * 30 days);
            vm.prank(stranger);
            vesting.release(address(token));

            uint256 total = token.balanceOf(beneficiary);
            if (month <= 6) {
                assertEq(total - previous, 0);
            } else {
                assertApproxEqAbs(total - previous, VESTING_SUPPLY / 18, 1);
            }
            previous = total;
        }
        assertEq(token.balanceOf(beneficiary), VESTING_SUPPLY);
        assertEq(token.balanceOf(address(vesting)), 0);
    }

    function test_Release_BeforeStartTransfersNothing() public {
        vm.warp(START - 1);
        vm.expectEmit(true, false, false, true, address(vesting));
        emit VestingWallet.ERC20Released(address(token), 0);
        vesting.release(address(token));

        assertEq(token.balanceOf(beneficiary), 0);
        assertEq(token.balanceOf(address(vesting)), VESTING_SUPPLY);
    }

    function test_Release_TwiceInSameBlockSecondIsZero() public {
        vm.warp(START + 100 days);
        vesting.release(address(token));
        uint256 afterFirst = token.balanceOf(beneficiary);
        assertGt(afterFirst, 0);

        vm.prank(stranger);
        vesting.release(address(token));
        assertEq(token.balanceOf(beneficiary), afterFirst);
    }

    /// @dev 베스팅 잔고는 승인(allowance)이 없으므로 transferFrom·burnFrom으로 빼낼 수 없다. 감소 경로는 release뿐.
    function testFuzz_VestingBalanceCannotBePulled(address attacker, uint256 amount) public {
        vm.assume(attacker != address(0));
        amount = bound(amount, 1, VESTING_SUPPLY);

        vm.startPrank(attacker);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, attacker, 0, amount));
        token.transferFrom(address(vesting), attacker, amount);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, attacker, 0, amount));
        token.burnFrom(address(vesting), amount);
        vm.stopPrank();

        assertEq(token.balanceOf(address(vesting)), VESTING_SUPPLY);
    }

    // ─────────────────────────────────────────────────────────────
    // 코드 고정: 외부 함수 집합 / 런타임 코드
    // ─────────────────────────────────────────────────────────────

    /// @dev 런타임 코드 디스패처의 외부 함수 셀렉터가 VestingWallet 11개 + Ownable·Ownable2Step 5개 = 16개 서명과 정확히 같다.
    ///      잔고를 옮기는 새 경로(긴급 인출·일정 변경 등)가 하나라도 추가되면 실패한다. 이 16개의 동작은 이 파일의 다른 테스트가 검증.
    function test_ExternalSelectorSetIsExact() public view {
        bytes4[] memory found = CoreBytecode.dispatcherSelectors(address(vesting).code);
        assertEq(CoreBytecode.difference(found, _knownSelectors()), "", "FireVesting external function set changed");
        assertEq(found.length, 16);
    }

    /// @dev 고정 소스의 생성 코드(생성자 포함)와 런타임 코드를 해시로 고정한다 (셀렉터를 바꾸지 않는 일정·권한 로직 변경,
    ///      생성자만 바꾼 변경까지 드러냄). 주석·NatSpec 변경은 메타데이터에만 반영되므로 영향 없음. solc·OpenZeppelin·최적화
    ///      설정을 의도적으로 바꾼 경우에만 검토 후 상수를 갱신한다. forge coverage 는 최적화를 끈 별도 빌드이므로 건너뛴다.
    function test_Bytecode_MatchesPinnedBuild() public {
        vm.skip(vm.isContext(VmSafe.ForgeContext.Coverage), "forge coverage compiles without the optimizer");
        assertEq(
            CoreBytecode.executableCodeHash(type(FireVesting).creationCode),
            FIRE_VESTING_CREATION_CODE_HASH,
            "FireVesting creation code differs from the pinned build (src/, lib/openzeppelin-contracts or compiler settings changed)"
        );
        assertEq(vesting.start(), START);
        assertEq(vesting.duration(), LINEAR_SECONDS);
        assertEq(
            CoreBytecode.executableCodeHash(address(vesting).code),
            FIRE_VESTING_RUNTIME_CODE_HASH,
            "FireVesting runtime code differs from the pinned build (src/, lib/openzeppelin-contracts or compiler settings changed)"
        );
    }

    /// @dev [회귀] 수익자 전용 인출 함수가 붙은 변형은 클리프 중에도 2억 전량을 빼낼 수 있고, 기존 함수만 쓰는 동작 테스트는
    ///      이를 보지 못한다. 셀렉터 집합 고정에서는 예상 밖 셀렉터로 드러난다.
    function test_SelectorPin_FlagsOwnerOnlySweep() public {
        CoreVestingWithSweep mutant = new CoreVestingWithSweep(beneficiary, CLIFF_SECONDS, LINEAR_SECONDS);
        vm.prank(deployer);
        FireToken mutantToken = new FireToken(address(mutant));

        vm.warp(DEPLOY_TS + 1 days); // 클리프 중
        assertEq(mutant.releasable(address(mutantToken)), 0);
        vm.prank(beneficiary);
        mutant.coreSweep(address(mutantToken));
        assertEq(mutantToken.balanceOf(beneficiary), VESTING_SUPPLY);

        bytes4[] memory found = CoreBytecode.dispatcherSelectors(address(mutant).code);
        assertTrue(CoreBytecode.contains(found, CoreVestingWithSweep.coreSweep.selector));
        assertEq(
            CoreBytecode.difference(found, _knownSelectors()),
            string.concat("unexpected external selector ", CoreBytecode.toHex(CoreVestingWithSweep.coreSweep.selector))
        );
    }

    // ─────────────────────────────────────────────────────────────
    // 최초 수익자 지정 (Ownable2Step 보호 범위 밖)
    // ─────────────────────────────────────────────────────────────

    /// @dev [PoC] 생성자의 beneficiary 는 수락 절차 없이 즉시 owner 가 된다 (OwnershipTransferStarted 없이 OwnershipTransferred
    ///      1건). Ownable2Step 은 그 이후의 교체만 보호한다. 호출 능력이 없는 주소(오타, 다른 체인에만 있는 Safe, 함수 없는
    ///      컨트랙트)를 넣으면 아무도 소유권을 옮길 수 없고 2억 전량이 결국 그 주소로 release 된다.
    ///      배포 스크립트의 `owner() == BENEFICIARY` 확인은 같은 값끼리 비교하므로 이 경우를 걸러내지 못한다.
    function test_PoC_InitialBeneficiaryIsOwnerWithoutAcceptance() public {
        address wrongBeneficiary = address(new CoreInertBeneficiary());
        vm.recordLogs();
        FireVesting wrongVesting = new FireVesting(wrongBeneficiary, CLIFF_SECONDS, LINEAR_SECONDS);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);
        assertEq(logs[0].topics[0], Ownable.OwnershipTransferred.selector);
        assertEq(wrongVesting.owner(), wrongBeneficiary);
        assertEq(wrongVesting.pendingOwner(), address(0));

        vm.prank(deployer);
        FireToken wrongToken = new FireToken(address(wrongVesting));

        address[3] memory wouldBeRescuers = [deployer, beneficiary, address(this)];
        for (uint256 i; i < wouldBeRescuers.length; ++i) {
            vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, wouldBeRescuers[i]));
            vm.prank(wouldBeRescuers[i]);
            wrongVesting.transferOwnership(wouldBeRescuers[i]);
        }

        vm.warp(END);
        vm.prank(beneficiary);
        wrongVesting.release(address(wrongToken));
        assertEq(wrongToken.balanceOf(wrongBeneficiary), VESTING_SUPPLY); // 회수 불가능한 주소로 전량 이동
        assertEq(wrongToken.balanceOf(beneficiary), 0);
    }

    /// @dev 소스 수정 없는 완화책: 배포자를 최초 owner 로 베스팅 배포 → transferOwnership(수익자) → 수익자가 Base 에서
    ///      acceptOwnership 으로 통제권을 증명한 뒤에만 토큰 배포. 수락이 오지 않으면(주소 오입력) 토큰 배포 전에 다시 지정한다.
    ///      일정(start)은 베스팅 배포 시각 기준 그대로이며, 수락 전에는 베스팅 잔고가 0 이라 배포자가 owner 인 구간의 위험도 없다.
    function test_Mitigation_BeneficiaryAcceptsBeforeTokenDeploy() public {
        address typo = makeAddr("typo");
        vm.prank(deployer);
        FireVesting provenVesting = new FireVesting(deployer, CLIFF_SECONDS, LINEAR_SECONDS);

        vm.prank(deployer);
        provenVesting.transferOwnership(typo); // 잘못된 주소: 수락이 오지 않는다
        vm.warp(DEPLOY_TS + 5 minutes);
        vm.prank(deployer);
        provenVesting.transferOwnership(beneficiary); // 토큰 배포 전이므로 다시 지정
        vm.warp(DEPLOY_TS + 10 minutes);
        vm.prank(beneficiary);
        provenVesting.acceptOwnership(); // 수령 주소 통제 증명
        assertEq(provenVesting.owner(), beneficiary);
        assertEq(provenVesting.pendingOwner(), address(0));

        vm.prank(deployer);
        FireToken provenToken = new FireToken(address(provenVesting)); // 수락 확인 후에만 토큰 배포
        assertEq(provenToken.balanceOf(address(provenVesting)), VESTING_SUPPLY);
        assertEq(provenVesting.start(), START); // 시작 시각은 베스팅 배포 시각(DEPLOY_TS) 기준
        assertEq(provenVesting.end(), END);

        vm.warp(END);
        provenVesting.release(address(provenToken));
        assertEq(provenToken.balanceOf(beneficiary), VESTING_SUPPLY);
        assertEq(provenToken.balanceOf(typo), 0);
    }

    // ─────────────────────────────────────────────────────────────
    // Ownable2Step: 수령 지갑 교체
    // ─────────────────────────────────────────────────────────────

    function test_TransferOwnership_OnlySetsPendingOwner() public {
        vm.expectEmit(true, true, false, false, address(vesting));
        emit Ownable2Step.OwnershipTransferStarted(beneficiary, newWallet);
        vm.prank(beneficiary);
        vesting.transferOwnership(newWallet);

        assertEq(vesting.owner(), beneficiary);
        assertEq(vesting.pendingOwner(), newWallet);
    }

    function test_TransferOwnership_ReleaseWhilePendingPaysCurrentOwner() public {
        vm.prank(beneficiary);
        vesting.transferOwnership(newWallet);

        vm.warp(START + 1 days);
        vm.prank(stranger);
        vesting.release(address(token));

        assertEq(token.balanceOf(beneficiary), VESTED_AT_START_PLUS_ONE_DAY);
        assertEq(token.balanceOf(newWallet), 0);
    }

    function test_AcceptOwnership_OnlyPendingOwner() public {
        vm.prank(beneficiary);
        vesting.transferOwnership(newWallet);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        vm.prank(stranger);
        vesting.acceptOwnership();

        // 현재 소유자도 대신 수락할 수 없다
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, beneficiary));
        vm.prank(beneficiary);
        vesting.acceptOwnership();

        vm.expectEmit(true, true, false, false, address(vesting));
        emit Ownable.OwnershipTransferred(beneficiary, newWallet);
        vm.prank(newWallet);
        vesting.acceptOwnership();

        assertEq(vesting.owner(), newWallet);
        assertEq(vesting.pendingOwner(), address(0));

        // 수락은 한 번뿐
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, newWallet));
        vm.prank(newWallet);
        vesting.acceptOwnership();
    }

    function testFuzz_RevertWhen_NonPendingOwnerAccepts(address caller) public {
        vm.assume(caller != newWallet);
        vm.prank(beneficiary);
        vesting.transferOwnership(newWallet);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, caller));
        vm.prank(caller);
        vesting.acceptOwnership();

        assertEq(vesting.owner(), beneficiary);
        assertEq(vesting.pendingOwner(), newWallet);
    }

    function test_RevertWhen_AcceptWithoutPendingTransfer() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        vm.prank(stranger);
        vesting.acceptOwnership();
        assertEq(vesting.owner(), beneficiary);
    }

    function test_AcceptOwnership_RedirectsFutureReleasesToNewOwner() public {
        vm.warp(START + 90 days);
        vesting.release(address(token));
        uint256 paidToOldOwner = token.balanceOf(beneficiary);
        assertGt(paidToOldOwner, 0);

        vm.prank(beneficiary);
        vesting.transferOwnership(newWallet);
        vm.prank(newWallet);
        vesting.acceptOwnership();

        vm.warp(END);
        vm.prank(stranger);
        vesting.release(address(token));

        assertEq(token.balanceOf(beneficiary), paidToOldOwner); // 이전 소유자는 더 받지 않음
        assertEq(token.balanceOf(newWallet), VESTING_SUPPLY - paidToOldOwner);
        assertEq(vesting.released(address(token)), VESTING_SUPPLY);

        // 이전 소유자는 더 이상 권한이 없다
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, beneficiary));
        vm.prank(beneficiary);
        vesting.transferOwnership(beneficiary);
    }

    function testFuzz_RevertWhen_NonOwnerTransfersOwnership(address caller, address target) public {
        vm.assume(caller != beneficiary);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, caller));
        vm.prank(caller);
        vesting.transferOwnership(target);

        assertEq(vesting.owner(), beneficiary);
        assertEq(vesting.pendingOwner(), address(0));
    }

    function test_RevertWhen_PendingOwnerTransfersOwnership() public {
        vm.prank(beneficiary);
        vesting.transferOwnership(newWallet);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, newWallet));
        vm.prank(newWallet);
        vesting.transferOwnership(stranger);
        assertEq(vesting.pendingOwner(), newWallet);
    }

    function test_TransferOwnership_OverwritesPendingOwner() public {
        address first = makeAddr("first");
        address second = makeAddr("second");
        vm.startPrank(beneficiary);
        vesting.transferOwnership(first);
        vesting.transferOwnership(second);
        vm.stopPrank();
        assertEq(vesting.pendingOwner(), second);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, first));
        vm.prank(first);
        vesting.acceptOwnership();

        vm.prank(second);
        vesting.acceptOwnership();
        assertEq(vesting.owner(), second);
    }

    function test_TransferOwnership_CancelWithZeroAddress() public {
        vm.prank(beneficiary);
        vesting.transferOwnership(newWallet);

        vm.expectEmit(true, true, false, false, address(vesting));
        emit Ownable2Step.OwnershipTransferStarted(beneficiary, address(0));
        vm.prank(beneficiary);
        vesting.transferOwnership(address(0));

        assertEq(vesting.pendingOwner(), address(0));
        assertEq(vesting.owner(), beneficiary);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, newWallet));
        vm.prank(newWallet);
        vesting.acceptOwnership();
    }

    /// @dev 주소를 잘못 입력해도(예: 수락할 수 없는 토큰 컨트랙트 주소) 소유권과 해제분은 그대로이며 다시 지정할 수 있다.
    function test_TransferOwnership_WrongAddressIsRecoverable() public {
        vm.prank(beneficiary);
        vesting.transferOwnership(address(token));
        assertEq(vesting.owner(), beneficiary);

        vm.warp(START + 1 days);
        vesting.release(address(token));
        assertEq(token.balanceOf(beneficiary), VESTED_AT_START_PLUS_ONE_DAY);

        vm.prank(beneficiary);
        vesting.transferOwnership(newWallet);
        vm.prank(newWallet);
        vesting.acceptOwnership();
        assertEq(vesting.owner(), newWallet);
    }

    // ─────────────────────────────────────────────────────────────
    // renounceOwnership 차단
    // ─────────────────────────────────────────────────────────────

    function test_RevertWhen_OwnerRenounces() public {
        vm.expectRevert(FireVesting.FireVestingRenounceDisabled.selector);
        vm.prank(beneficiary);
        vesting.renounceOwnership();
        assertEq(vesting.owner(), beneficiary);
    }

    function testFuzz_RevertWhen_AnyoneRenounces(address caller) public {
        vm.expectRevert(FireVesting.FireVestingRenounceDisabled.selector);
        vm.prank(caller);
        vesting.renounceOwnership();
        assertEq(vesting.owner(), beneficiary);
    }

    function test_RevertWhen_PendingOrNewOwnerRenounces() public {
        vm.prank(beneficiary);
        vesting.transferOwnership(newWallet);

        vm.expectRevert(FireVesting.FireVestingRenounceDisabled.selector);
        vm.prank(newWallet);
        vesting.renounceOwnership();
        assertEq(vesting.pendingOwner(), newWallet);

        vm.prank(newWallet);
        vesting.acceptOwnership();
        vm.expectRevert(FireVesting.FireVestingRenounceDisabled.selector);
        vm.prank(newWallet);
        vesting.renounceOwnership();
        assertEq(vesting.owner(), newWallet);
    }

    // ─────────────────────────────────────────────────────────────
    // 추가 입금 (가이드 3.1 주의 사항)
    // ─────────────────────────────────────────────────────────────

    /// @dev 베스팅 시작 후 추가 입금된 토큰은 처음부터 잠겨 있던 것처럼 계산되어(소급), 경과 비율만큼 즉시 해제 가능해진다.
    ///      새 입금분에 별도의 클리프가 적용되지 않는다 → 2억 개 외의 토큰을 이 주소로 보내면 안 된다.
    function test_LateDeposit_IsBackdated() public {
        uint256 elapsed = 90 days; // 선형 구간 540일 중 1/6 경과
        vm.warp(START + elapsed);
        vesting.release(address(token));
        uint256 releasedBefore = vesting.released(address(token));
        assertEq(releasedBefore, VESTING_SUPPLY * elapsed / LINEAR_SECONDS);
        assertEq(vesting.releasable(address(token)), 0);

        uint256 lateDeposit = 1_000_000e18;
        vm.prank(deployer);
        assertTrue(token.transfer(address(vesting), lateDeposit));

        // 같은 블록에서 즉시 해제 가능: (2억 + 100만) × 1/6 − 기해제분 ≈ 100만 × 1/6
        uint256 immediatelyReleasable = vesting.releasable(address(token));
        assertEq(immediatelyReleasable, (VESTING_SUPPLY + lateDeposit) * elapsed / LINEAR_SECONDS - releasedBefore);
        assertEq(immediatelyReleasable, 166_666_666_666_666_666_666_667); // 약 166,666.67 FIRE
        assertApproxEqAbs(immediatelyReleasable, lateDeposit * elapsed / LINEAR_SECONDS, 1);

        vm.prank(stranger);
        vesting.release(address(token));
        assertEq(token.balanceOf(beneficiary), releasedBefore + immediatelyReleasable);

        // 총 배분량이 2억 + 추가분으로 늘어나 종료 시 전량 해제
        vm.warp(END);
        vesting.release(address(token));
        assertEq(token.balanceOf(beneficiary), VESTING_SUPPLY + lateDeposit);
        assertEq(token.balanceOf(address(vesting)), 0);
    }

    function testFuzz_LateDeposit_ImmediateShareIsProRata(uint256 elapsed, uint256 deposit) public {
        elapsed = bound(elapsed, 0, LINEAR_SECONDS);
        deposit = bound(deposit, 1, DEPLOYER_SUPPLY);
        vm.warp(START + elapsed);
        vesting.release(address(token));

        vm.prank(deployer);
        assertTrue(token.transfer(address(vesting), deposit));

        uint256 jump = vesting.releasable(address(token));
        uint256 proRata = deposit * elapsed / LINEAR_SECONDS;
        assertGe(jump, proRata);
        assertLe(jump, proRata + 1);
    }

    function test_LateDeposit_AfterEndIsFullyReleasable() public {
        vm.warp(END + 1 days);
        vesting.release(address(token));

        vm.prank(deployer);
        assertTrue(token.transfer(address(vesting), 5_000e18));
        assertEq(vesting.releasable(address(token)), 5_000e18);
    }

    function test_LateDeposit_DuringCliffJoinsSchedule() public {
        uint256 deposit = 3_000_000e18;
        vm.warp(START - 1 days);
        vm.prank(deployer);
        assertTrue(token.transfer(address(vesting), deposit));
        assertEq(vesting.releasable(address(token)), 0);

        vm.warp(START + 1 days);
        assertEq(vesting.releasable(address(token)), (VESTING_SUPPLY + deposit) * 1 days / LINEAR_SECONDS);
    }

    // ─────────────────────────────────────────────────────────────
    // ETH 베스팅 (VestingWallet은 ETH도 같은 스케줄로 해제)
    // ─────────────────────────────────────────────────────────────

    function test_Ether_FollowsSameSchedule() public {
        uint256 amount = 3 ether;
        vm.deal(deployer, amount);
        vm.prank(deployer);
        (bool ok,) = address(vesting).call{value: amount}("");
        assertTrue(ok);
        assertEq(address(vesting).balance, amount);

        vm.warp(START - 1);
        assertEq(vesting.releasable(), 0);

        vm.warp(START + 1 days);
        uint256 expected = amount * 1 days / LINEAR_SECONDS;
        assertEq(vesting.releasable(), expected);

        vm.expectEmit(false, false, false, true, address(vesting));
        emit VestingWallet.EtherReleased(expected);
        vm.prank(stranger);
        vesting.release();
        assertEq(beneficiary.balance, expected);
        assertEq(stranger.balance, 0);

        vm.warp(END);
        vesting.release();
        assertEq(beneficiary.balance, amount); // 잃어버리지 않고 전량 수익자에게
        assertEq(address(vesting).balance, 0);
        assertEq(vesting.released(), amount);
        // ETH와 FIRE 스케줄은 서로 독립
        assertEq(vesting.released(address(token)), 0);
        assertEq(token.balanceOf(address(vesting)), VESTING_SUPPLY);
    }

    /// @dev 소유자가 ETH를 받을 수 없는 컨트랙트면 ETH release가 실패하지만, 수령 지갑을 교체하면 정상 수령 (ETH 동결 아님).
    function test_Ether_OwnerRejectingEtherCanRedirect() public {
        CoreEtherRejector rejector = new CoreEtherRejector(address(this));
        FireVesting rejectingVesting = new FireVesting(address(rejector), CLIFF_SECONDS, LINEAR_SECONDS);
        vm.deal(deployer, 1 ether);
        vm.prank(deployer);
        (bool ok,) = address(rejectingVesting).call{value: 1 ether}("");
        assertTrue(ok);

        vm.warp(END);
        vm.expectRevert(Errors.FailedCall.selector);
        rejectingVesting.release();

        rejector.transferVestingOwnership(rejectingVesting, newWallet);
        vm.prank(newWallet);
        rejectingVesting.acceptOwnership();

        rejectingVesting.release();
        assertEq(newWallet.balance, 1 ether);
        assertEq(address(rejectingVesting).balance, 0);
    }

    // ─────────────────────────────────────────────────────────────
    // 내부 헬퍼
    // ─────────────────────────────────────────────────────────────

    /// @dev FireVesting 의 외부 함수 16개. 컨트랙트 인터페이스가 아니라 서명 문자열에서 독립적으로 계산한다.
    function _knownSelectors() internal pure returns (bytes4[] memory known) {
        string[16] memory signatures = [
            // VestingWallet
            "start()",
            "duration()",
            "end()",
            "released()",
            "released(address)",
            "releasable()",
            "releasable(address)",
            "release()",
            "release(address)",
            "vestedAmount(uint64)",
            "vestedAmount(address,uint64)",
            // Ownable + Ownable2Step (renounceOwnership 은 항상 revert)
            "owner()",
            "renounceOwnership()",
            "transferOwnership(address)",
            "pendingOwner()",
            "acceptOwnership()"
        ];
        known = new bytes4[](signatures.length);
        for (uint256 i; i < signatures.length; ++i) {
            known[i] = bytes4(keccak256(bytes(signatures[i])));
        }
    }
}
