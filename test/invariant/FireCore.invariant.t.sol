// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {FireToken} from "../../src/FireToken.sol";
import {FireVesting} from "../../src/FireVesting.sol";
import {CoreHandler, CoreSafeActor} from "./CoreHandler.sol";

/// @title FireToken + FireVesting 불변식 테스트
/// @notice 배포(2026-11-16 가정) 후 무작위 시간 경과·release·전송·소각·소유권 조작 시퀀스에서 다음이 항상 성립함을 검증:
///         1) totalSupply == 10억 − 누적 소각량
///         2) 베스팅 잔고 + 누적 해제량 == 2억
///         3) 누적 해제량 ≤ vestedAmount(현재 시각), vestedAmount 는 독립 계산한 스케줄과 일치
///         4) 베스팅 컨트랙트의 토큰은 (호출 시점의) owner 외에는 아무도 받지 못함
///         5) 권한 검사(소유권 이전·수락·포기, 무단 인출)가 항상 기대대로 동작하고 owner 는 0 주소가 되지 않음
///         6) 행위자 잔고 합 + 베스팅 잔고 == totalSupply (제3자에게 새는 토큰 없음)
///         7) ETH 도 같은 스케줄로 해제되며 전부 owner 에게 도달
///         행위자: 수익자·배포자·LP·에어드롭(EOA) + 트레저리(Safe 형 컨트랙트). 핸들러 액션은 정상이라면 revert 하지 않으므로
///         fail-on-revert 를 켜 두어, 어떤 액션(예: 제3자의 release)이 막히면 그 자체로 실패하게 한다
///         (foundry.toml 기본값 false 를 이 컨트랙트에만 덮어씀).
/// forge-config: default.invariant.fail-on-revert = true
/// forge-config: ci.invariant.fail-on-revert = true
contract FireCoreInvariantTest is Test {
    uint64 internal constant CLIFF_SECONDS = 15_552_000; // 180일
    uint64 internal constant LINEAR_SECONDS = 46_656_000; // 540일
    uint256 internal constant DEPLOY_TS = 1_794_787_200; // 2026-11-16 00:00:00 UTC
    uint256 internal constant START = 1_810_339_200; // 배포 + 180일
    uint256 internal constant END = 1_856_995_200; // 배포 + 720일
    uint256 internal constant TOTAL_SUPPLY = 1_000_000_000e18;
    uint256 internal constant VESTING_SUPPLY = 200_000_000e18;
    uint256 internal constant ETH_FUNDED = 10 ether;

    FireToken internal token;
    FireVesting internal vesting;
    CoreHandler internal handler;
    address[] internal actors;

    function setUp() public {
        vm.warp(DEPLOY_TS);
        address beneficiary = makeAddr("beneficiary");
        address deployer = makeAddr("deployer");
        address lp = makeAddr("lp");
        address airdrop = makeAddr("airdrop");
        address treasury = address(new CoreSafeActor()); // 트레저리 = Safe 형 컨트랙트 (컨트랙트 수신·spender·수익자 경로)

        vesting = new FireVesting(beneficiary, CLIFF_SECONDS, LINEAR_SECONDS);
        vm.prank(deployer);
        token = new FireToken(address(vesting));

        // 가이드 2.2 분배: 배포자 8억 → LP 7억 / 에어드롭 5,000만 / 트레저리 5,000만
        vm.startPrank(deployer);
        assertTrue(token.transfer(lp, 700_000_000e18));
        assertTrue(token.transfer(airdrop, 50_000_000e18));
        assertTrue(token.transfer(treasury, 50_000_000e18));
        vm.stopPrank();
        assertEq(token.balanceOf(deployer), 0);

        // ETH 도 같은 스케줄로 베스팅되는지 확인하기 위한 입금
        vm.deal(address(this), ETH_FUNDED);
        (bool ok,) = address(vesting).call{value: ETH_FUNDED}("");
        assertTrue(ok);

        actors.push(beneficiary);
        actors.push(deployer);
        actors.push(lp);
        actors.push(airdrop);
        actors.push(treasury);
        handler = new CoreHandler(token, vesting, actors, DEPLOY_TS);

        bytes4[] memory selectors = new bytes4[](12);
        selectors[0] = CoreHandler.advanceTime.selector;
        selectors[1] = CoreHandler.releaseToken.selector;
        selectors[2] = CoreHandler.releaseEther.selector;
        selectors[3] = CoreHandler.transferBetweenActors.selector;
        selectors[4] = CoreHandler.burnOwn.selector;
        selectors[5] = CoreHandler.burnWithAllowance.selector;
        selectors[6] = CoreHandler.startOwnershipTransfer.selector;
        selectors[7] = CoreHandler.acceptOwnershipTransfer.selector;
        selectors[8] = CoreHandler.cancelOwnershipTransfer.selector;
        selectors[9] = CoreHandler.tryRenounce.selector;
        selectors[10] = CoreHandler.tryPullFromVesting.selector;
        selectors[11] = CoreHandler.transferFromBetweenActors.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /// @notice 1) 추가 발행 경로가 없으므로 총공급은 소각으로만 줄어든다.
    function invariant_TotalSupplyEqualsMintedMinusBurned() public view {
        assertEq(token.totalSupply(), TOTAL_SUPPLY - handler.ghostTotalBurned());
    }

    /// @notice 2) 베스팅 물량은 release 외의 경로로 줄지 않는다.
    function invariant_VestingBalancePlusReleasedEqualsAllocation() public view {
        assertEq(token.balanceOf(address(vesting)) + vesting.released(address(token)), VESTING_SUPPLY);
    }

    /// @notice 3) 누적 해제량은 현재 시각의 베스팅량을 넘지 않으며, 베스팅량은 가이드 수식과 정확히 일치한다.
    function invariant_ReleasedNeverExceedsVested() public view {
        uint256 nowTs = handler.currentTimestamp();
        uint64 now64 = SafeCast.toUint64(nowTs);

        uint256 vestedToken = vesting.vestedAmount(address(token), now64);
        assertLe(vesting.released(address(token)), vestedToken);
        assertEq(vestedToken, _expectedVested(VESTING_SUPPLY, nowTs));

        uint256 vestedEther = vesting.vestedAmount(now64);
        assertLe(vesting.released(), vestedEther);
        assertEq(vestedEther, _expectedVested(ETH_FUNDED, nowTs));
    }

    /// @notice 4) 베스팅 컨트랙트에서 나간 FIRE 는 전부 당시 owner 에게만 도착했고, 행위자 잔고는 기대값과 같다.
    function invariant_OnlyOwnerReceivesFromVesting() public view {
        assertEq(handler.ghostNonOwnerVestingOutflows(), 0);
        assertEq(handler.ghostTokenReleasedToOwner(), vesting.released(address(token)));
        for (uint256 i; i < actors.length; ++i) {
            assertEq(token.balanceOf(actors[i]), handler.ghostExpectedBalance(actors[i]));
        }
    }

    /// @notice 5) 권한 검사가 항상 기대대로 동작하고, owner 는 0 주소가 될 수 없으며 항상 행위자 중 하나다.
    function invariant_AccessControlHolds() public view {
        assertEq(handler.ghostUnexpectedOutcomes(), 0);
        address currentOwner = vesting.owner();
        assertTrue(currentOwner != address(0));
        bool isActor;
        for (uint256 i; i < actors.length; ++i) {
            if (actors[i] == currentOwner) isActor = true;
        }
        assertTrue(isActor);
    }

    /// @notice 6) 모든 FIRE 는 행위자 또는 베스팅 컨트랙트에만 있다.
    function invariant_BalancesSumToTotalSupply() public view {
        uint256 sum = token.balanceOf(address(vesting));
        for (uint256 i; i < actors.length; ++i) {
            sum += token.balanceOf(actors[i]);
        }
        assertEq(sum, token.totalSupply());
    }

    /// @notice 7) ETH: 베스팅 잔고 + 해제량 = 입금액, 해제된 ETH 는 모두 owner(행위자)에게 도달.
    function invariant_EtherConservation() public view {
        assertEq(address(vesting).balance + vesting.released(), ETH_FUNDED);
        assertEq(handler.ghostEthReleasedToOwner(), vesting.released());
        uint256 actorsEther;
        for (uint256 i; i < actors.length; ++i) {
            actorsEther += actors[i].balance;
        }
        assertEq(actorsEther, vesting.released());
    }

    /// @notice 각 시퀀스 종료 후: 종료 시각 이후에는 누가 호출하든 남은 FIRE·ETH 전량이 현재 owner 에게 도달한다.
    function afterInvariant() public {
        uint256 finalTs = handler.currentTimestamp() > END ? handler.currentTimestamp() : END;
        vm.warp(finalTs);
        address currentOwner = vesting.owner();
        uint256 ownerTokenBefore = token.balanceOf(currentOwner);
        uint256 remainingToken = token.balanceOf(address(vesting));
        uint256 ownerEtherBefore = currentOwner.balance;
        uint256 remainingEther = address(vesting).balance;

        address finalCaller = makeAddr("finalCaller");
        vm.startPrank(finalCaller);
        vesting.release(address(token));
        vesting.release();
        vm.stopPrank();

        assertEq(token.balanceOf(address(vesting)), 0);
        assertEq(vesting.released(address(token)), VESTING_SUPPLY);
        assertEq(token.balanceOf(currentOwner), ownerTokenBefore + remainingToken);
        assertEq(token.balanceOf(finalCaller), 0);
        assertEq(address(vesting).balance, 0);
        assertEq(vesting.released(), ETH_FUNDED);
        assertEq(currentOwner.balance, ownerEtherBefore + remainingEther);
    }

    /// @dev 컨트랙트와 독립적으로 계산한 스케줄: start 이전 0, end 이후 전량, 그 사이 선형(내림).
    function _expectedVested(uint256 total, uint256 timestamp) internal pure returns (uint256) {
        if (timestamp < START) return 0;
        if (timestamp >= END) return total;
        return total * (timestamp - START) / LINEAR_SECONDS;
    }
}
