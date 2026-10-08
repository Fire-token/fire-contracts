// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {CommonBase} from "forge-std/Base.sol";
import {StdUtils} from "forge-std/StdUtils.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {FireToken} from "../../src/FireToken.sol";
import {FireVesting} from "../../src/FireVesting.sol";

/// @title CoreSafeActor
/// @notice Safe 멀티시그처럼 FIRE 와 ETH 를 받을 수 있는 컨트랙트 행위자 (가이드 2.2 트레저리 Safe 역할).
///         핸들러가 vm.prank 로 이 주소의 호출(전송·승인·소각·소유권 수락)을 대신 실행한다.
///         컨트랙트 수신자·컨트랙트 spender·컨트랙트 수익자 경로를 불변식 캠페인에 포함하기 위한 용도.
contract CoreSafeActor {
    receive() external payable {}
}

/// @title CoreHandler
/// @notice FireToken/FireVesting 불변식 테스트용 핸들러.
///         시간 경과, 임의 호출자의 release(토큰·ETH), 행위자(EOA·컨트랙트) 간 전송·위임 전송(transferFrom)·소각(burn/burnFrom),
///         소유권 이전·수락·취소·포기 시도, 승인 없이 베스팅 잔고를 빼내려는 시도를 무작위로 수행하고
///         기대값을 고스트 변수에 기록한다. 베스팅 컨트랙트로의 추가 입금은 하지 않는다(배분량 2억 고정).
///         모든 액션은 정상 동작이라면 revert 하지 않도록 작성되어 있고, 불변식 테스트는 fail-on-revert 로 이를 강제한다.
contract CoreHandler is CommonBase, StdUtils {
    FireToken public immutable TOKEN;
    FireVesting public immutable VESTING;

    address[] internal _actors;

    /// @notice 핸들러가 관리하는 현재 시각. 호출 사이에 block.timestamp가 유지되는지와 무관하게 매 호출 시작 시 다시 맞춘다.
    uint256 public currentTimestamp;

    /// @notice 누적 소각량 (burn + burnFrom)
    uint256 public ghostTotalBurned;
    /// @notice 베스팅 컨트랙트 → (호출 시점의) owner 로 관측된 FIRE Transfer 합계
    uint256 public ghostTokenReleasedToOwner;
    /// @notice owner 가 실제로 수령한 ETH 합계
    uint256 public ghostEthReleasedToOwner;
    /// @notice 베스팅 컨트랙트에서 owner 이외의 주소로 나간 FIRE Transfer 횟수 (항상 0이어야 함)
    uint256 public ghostNonOwnerVestingOutflows;
    /// @notice 권한 없는 호출의 성공, 정상 호출의 실패, 잔고 변화 불일치 등 예상 밖 결과 횟수 (항상 0이어야 함)
    uint256 public ghostUnexpectedOutcomes;
    /// @notice 행위자별 기대 FIRE 잔고
    mapping(address account => uint256) public ghostExpectedBalance;

    /// @notice 커버리지 확인용 통계
    uint256 public callsNonZeroRelease;
    uint256 public callsOwnershipTransferStarted;
    uint256 public callsOwnershipAccepted;
    /// @notice 컨트랙트 행위자가 보내거나 받은 0 초과 전송 횟수
    uint256 public callsContractPartyTransfer;

    constructor(FireToken token, FireVesting vesting, address[] memory initialActors, uint256 startTimestamp) {
        TOKEN = token;
        VESTING = vesting;
        currentTimestamp = startTimestamp;
        for (uint256 i; i < initialActors.length; ++i) {
            _actors.push(initialActors[i]);
            ghostExpectedBalance[initialActors[i]] = token.balanceOf(initialActors[i]);
        }
    }

    /// @dev 시각을 맞추고, 호출 중 발생한 로그에서 베스팅 컨트랙트의 FIRE 유출을 모두 검사한다.
    modifier observe() {
        vm.warp(currentTimestamp);
        address ownerAtCall = VESTING.owner();
        vm.recordLogs();
        _;
        _scanVestingOutflows(ownerAtCall);
    }

    // ─────────────────────────────────────────────────────────────
    // 시간
    // ─────────────────────────────────────────────────────────────

    /// @notice 1초~1일 / 1일~30일 / 30일~400일 중 하나의 폭으로 시간을 전진.
    ///         클리프 중·선형 구간·종료 이후가 모두 충분히 나오도록 고른 분포. 기본 프로필(256 runs × 64 calls, 액션 12종)에서
    ///         시퀀스 종료 시각을 3회 측정한 결과(2026-10-08, 시드마다 다름): 클리프 중 34~38%, 선형 구간 43~45%, 종료 이후 19~21%.
    ///         같은 측정에서 0 초과 release 가 있는 시퀀스 약 55%, 소유권 수락 약 68%, 컨트랙트 행위자가 낀 전송 약 88%.
    function advanceTime(uint256 seed) external {
        uint256 bucket = seed % 3;
        uint256 delta;
        if (bucket == 0) {
            delta = _bound(seed / 3, 1, 1 days);
        } else if (bucket == 1) {
            delta = _bound(seed / 3, 1 days, 30 days);
        } else {
            delta = _bound(seed / 3, 30 days, 400 days);
        }
        currentTimestamp += delta;
        vm.warp(currentTimestamp);
    }

    // ─────────────────────────────────────────────────────────────
    // release (누구나 호출 가능, 항상 owner 에게)
    // ─────────────────────────────────────────────────────────────

    function releaseToken(uint256 callerSeed) external observe {
        address caller = _anyCaller(callerSeed);
        address currentOwner = VESTING.owner();
        uint256 expected = VESTING.releasable(address(TOKEN));
        uint256 ownerBefore = TOKEN.balanceOf(currentOwner);
        uint256 callerBefore = TOKEN.balanceOf(caller);

        vm.prank(caller);
        VESTING.release(address(TOKEN));

        if (TOKEN.balanceOf(currentOwner) != ownerBefore + expected) ghostUnexpectedOutcomes++;
        if (caller != currentOwner && TOKEN.balanceOf(caller) != callerBefore) ghostUnexpectedOutcomes++;
        if (VESTING.releasable(address(TOKEN)) != 0) ghostUnexpectedOutcomes++;
        ghostExpectedBalance[currentOwner] += expected;
        if (expected > 0) callsNonZeroRelease++;
    }

    function releaseEther(uint256 callerSeed) external observe {
        address caller = _anyCaller(callerSeed);
        address currentOwner = VESTING.owner();
        uint256 expected = VESTING.releasable();
        uint256 ownerBefore = currentOwner.balance;
        uint256 callerBefore = caller.balance;

        vm.prank(caller);
        VESTING.release();

        if (currentOwner.balance != ownerBefore + expected) ghostUnexpectedOutcomes++;
        if (caller != currentOwner && caller.balance != callerBefore) ghostUnexpectedOutcomes++;
        ghostEthReleasedToOwner += expected;
    }

    // ─────────────────────────────────────────────────────────────
    // 행위자 간 전송 / 소각
    // ─────────────────────────────────────────────────────────────

    function transferBetweenActors(uint256 fromSeed, uint256 toSeed, uint256 amount) external observe {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        amount = _bound(amount, 0, TOKEN.balanceOf(from));

        vm.prank(from);
        if (!TOKEN.transfer(to, amount)) ghostUnexpectedOutcomes++;

        ghostExpectedBalance[from] -= amount;
        ghostExpectedBalance[to] += amount;
        _countContractParty(from, to, amount);
    }

    /// @notice 라우터·포지션 매니저 경로: 보유자가 승인한 만큼 spender(EOA 또는 컨트랙트)가 transferFrom 으로 옮긴다.
    function transferFromBetweenActors(uint256 holderSeed, uint256 spenderSeed, uint256 toSeed, uint256 amount)
        external
        observe
    {
        address holder = _actor(holderSeed);
        address spender = _actor(spenderSeed);
        address to = _actor(toSeed);
        amount = _bound(amount, 0, TOKEN.balanceOf(holder));

        vm.prank(holder);
        if (!TOKEN.approve(spender, amount)) ghostUnexpectedOutcomes++;
        vm.prank(spender);
        if (!TOKEN.transferFrom(holder, to, amount)) ghostUnexpectedOutcomes++;

        if (TOKEN.allowance(holder, spender) != 0) ghostUnexpectedOutcomes++;
        ghostExpectedBalance[holder] -= amount;
        ghostExpectedBalance[to] += amount;
        _countContractParty(holder, to, amount);
    }

    function burnOwn(uint256 fromSeed, uint256 amount) external observe {
        address from = _actor(fromSeed);
        amount = _bound(amount, 0, TOKEN.balanceOf(from));

        vm.prank(from);
        TOKEN.burn(amount);

        ghostExpectedBalance[from] -= amount;
        ghostTotalBurned += amount;
    }

    /// @notice 수수료 소각 경로: 보유자가 승인한 만큼 다른 행위자(서비스 역할)가 보유자 지갑에서 직접 소각
    function burnWithAllowance(uint256 holderSeed, uint256 spenderSeed, uint256 amount) external observe {
        address holder = _actor(holderSeed);
        address spender = _actor(spenderSeed);
        amount = _bound(amount, 0, TOKEN.balanceOf(holder));
        uint256 spenderBefore = TOKEN.balanceOf(spender);

        vm.prank(holder);
        if (!TOKEN.approve(spender, amount)) ghostUnexpectedOutcomes++;
        vm.prank(spender);
        TOKEN.burnFrom(holder, amount);

        if (TOKEN.allowance(holder, spender) != 0) ghostUnexpectedOutcomes++;
        if (spender != holder && TOKEN.balanceOf(spender) != spenderBefore) ghostUnexpectedOutcomes++;
        ghostExpectedBalance[holder] -= amount;
        ghostTotalBurned += amount;
    }

    // ─────────────────────────────────────────────────────────────
    // 소유권 (Ownable2Step)
    // ─────────────────────────────────────────────────────────────

    /// @notice 절반은 현재 owner, 절반은 임의 주소가 transferOwnership 시도. owner 만 성공해야 하며 owner() 는 즉시 바뀌지 않는다.
    function startOwnershipTransfer(uint256 callerSeed, uint256 targetSeed) external observe {
        address currentOwner = VESTING.owner();
        address pendingBefore = VESTING.pendingOwner();
        address caller = callerSeed % 2 == 0 ? currentOwner : _anyCaller(callerSeed / 2);
        address target = _actor(targetSeed);

        vm.prank(caller);
        try VESTING.transferOwnership(target) {
            if (caller != currentOwner || VESTING.pendingOwner() != target) ghostUnexpectedOutcomes++;
            callsOwnershipTransferStarted++;
        } catch (bytes memory reason) {
            if (caller == currentOwner || !_isUnauthorized(reason, caller)) ghostUnexpectedOutcomes++;
            if (VESTING.pendingOwner() != pendingBefore) ghostUnexpectedOutcomes++;
        }
        if (VESTING.owner() != currentOwner) ghostUnexpectedOutcomes++;
    }

    /// @notice 절반은 pendingOwner, 절반은 임의 주소가 acceptOwnership 시도. pendingOwner 만 성공해야 한다.
    function acceptOwnershipTransfer(uint256 callerSeed) external observe {
        address currentOwner = VESTING.owner();
        address pending = VESTING.pendingOwner();
        address caller = (callerSeed % 2 == 0 && pending != address(0)) ? pending : _anyCaller(callerSeed / 2);

        vm.prank(caller);
        try VESTING.acceptOwnership() {
            if (pending == address(0) || caller != pending) ghostUnexpectedOutcomes++;
            if (VESTING.owner() != caller || VESTING.pendingOwner() != address(0)) ghostUnexpectedOutcomes++;
            callsOwnershipAccepted++;
        } catch (bytes memory reason) {
            if (caller == pending || !_isUnauthorized(reason, caller)) ghostUnexpectedOutcomes++;
            if (VESTING.owner() != currentOwner || VESTING.pendingOwner() != pending) ghostUnexpectedOutcomes++;
        }
    }

    /// @notice owner 가 transferOwnership(address(0)) 으로 진행 중인 이전을 취소
    function cancelOwnershipTransfer() external observe {
        address currentOwner = VESTING.owner();
        vm.prank(currentOwner);
        VESTING.transferOwnership(address(0));
        if (VESTING.pendingOwner() != address(0) || VESTING.owner() != currentOwner) ghostUnexpectedOutcomes++;
    }

    /// @notice owner 를 포함한 누구의 renounceOwnership 도 FireVestingRenounceDisabled 로 실패해야 한다.
    function tryRenounce(uint256 callerSeed) external observe {
        address currentOwner = VESTING.owner();
        address caller = callerSeed % 2 == 0 ? currentOwner : _anyCaller(callerSeed / 2);

        vm.prank(caller);
        try VESTING.renounceOwnership() {
            ghostUnexpectedOutcomes++;
        } catch (bytes memory reason) {
            if (
                keccak256(reason) != keccak256(abi.encodeWithSelector(FireVesting.FireVestingRenounceDisabled.selector))
            ) {
                ghostUnexpectedOutcomes++;
            }
        }
        if (VESTING.owner() != currentOwner) ghostUnexpectedOutcomes++;
    }

    // ─────────────────────────────────────────────────────────────
    // 공격 시도
    // ─────────────────────────────────────────────────────────────

    /// @notice 승인 없이 베스팅 잔고를 transferFrom / burnFrom 으로 빼내려는 시도. 항상 실패해야 한다.
    function tryPullFromVesting(uint256 callerSeed, uint256 amount) external observe {
        address caller = _anyCaller(callerSeed);
        amount = _bound(amount, 1, TOKEN.balanceOf(address(VESTING)) + 1);

        vm.prank(caller);
        try TOKEN.transferFrom(address(VESTING), caller, amount) returns (bool) {
            ghostUnexpectedOutcomes++;
        } catch {}

        vm.prank(caller);
        try TOKEN.burnFrom(address(VESTING), amount) {
            ghostUnexpectedOutcomes++;
        } catch {}
    }

    // ─────────────────────────────────────────────────────────────
    // 조회 / 내부 헬퍼
    // ─────────────────────────────────────────────────────────────

    function _actor(uint256 seed) internal view returns (address) {
        return _actors[seed % _actors.length];
    }

    /// @dev 절반은 등록된 행위자, 절반은 FIRE를 보유하지 않은 임의의 제3자 주소.
    function _anyCaller(uint256 seed) internal view returns (address caller) {
        if (seed % 2 == 0) return _actor(seed / 2);
        caller = address(uint160(uint256(keccak256(abi.encode("core.caller", seed)))));
        if (caller == address(0) || caller == address(VESTING) || caller == address(TOKEN)) caller = _actors[0];
    }

    function _countContractParty(address from, address to, uint256 amount) internal {
        if (amount > 0 && from != to && (from.code.length > 0 || to.code.length > 0)) callsContractPartyTransfer++;
    }

    function _isUnauthorized(bytes memory reason, address caller) internal pure returns (bool) {
        return
            keccak256(reason) == keccak256(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, caller));
    }

    function _scanVestingOutflows(address ownerAtCall) internal {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            Vm.Log memory entry = logs[i];
            if (entry.emitter != address(TOKEN) || entry.topics.length != 3) continue;
            if (entry.topics[0] != IERC20.Transfer.selector) continue;
            if (address(uint160(uint256(entry.topics[1]))) != address(VESTING)) continue;

            address to = address(uint160(uint256(entry.topics[2])));
            uint256 amount = abi.decode(entry.data, (uint256));
            if (to == ownerAtCall) {
                ghostTokenReleasedToOwner += amount;
            } else {
                ghostNonOwnerVestingOutflows++;
            }
        }
    }
}
