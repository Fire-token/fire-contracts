// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, Vm, console, stdError} from "forge-std/Test.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {FireToken} from "../src/FireToken.sol";
import {FireVesting} from "../src/FireVesting.sol";
import {FireBatchSender} from "../src/FireBatchSender.sol";

// ─────────────────────────────────────────────────────────────────────────────
// 테스트 전용 헬퍼 컨트랙트 (다른 테스트 파일과 이름 충돌을 피하려고 Batch 접두사 사용)
// ─────────────────────────────────────────────────────────────────────────────

/// @dev 표준 OpenZeppelin ERC-20 (자유 발행).
contract BatchMockToken is ERC20 {
    constructor() ERC20("Batch Mock", "BMOCK") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev USDT형 토큰: approve/transferFrom이 값을 반환하지 않고 실패 시 revert.
contract BatchNoReturnToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    error BatchNoReturnTokenInsufficient();

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external {
        allowance[msg.sender][spender] = amount;
    }

    function transferFrom(address from, address to, uint256 amount) external {
        if (allowance[from][msg.sender] < amount || balanceOf[from] < amount) revert BatchNoReturnTokenInsufficient();
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}

/// @dev 실패 시 revert 대신 false를 반환하는 토큰.
contract BatchFalseReturnToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        if (allowance[from][msg.sender] < amount || balanceOf[from] < amount) return false;
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @dev 전송액의 1%를 소각하는 전송 수수료(fee-on-transfer) 토큰.
contract BatchFeeOnTransferToken is ERC20 {
    constructor() ERC20("Batch Fee On Transfer", "BFOT") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from == address(0) || to == address(0)) {
            super._update(from, to, value);
            return;
        }
        uint256 fee = value / 100;
        super._update(from, address(0), fee);
        super._update(from, to, value - fee);
    }
}

/// @dev transferFrom이 아무것도 옮기지 않고 true만 반환하는 가짜 토큰 (BatchSent가 호출자 입력임을 문서화).
contract BatchNoOpToken {
    function transferFrom(address, address, uint256) external pure returns (bool) {
        return true;
    }
}

/// @dev ETH 수령을 항상 거부하는 컨트랙트.
contract BatchRevertingReceiver {
    error BatchRevertingReceiverRejected();

    receive() external payable {
        revert BatchRevertingReceiverRejected();
    }
}

/// @dev Safe 싱글턴 대역: ETH 수령 시 이벤트만 기록 (Safe v1.3.0+ receive()와 같은 동작).
contract BatchSafeLikeSingleton {
    event SafeReceived(address indexed sender, uint256 value);

    receive() external payable {
        emit SafeReceived(msg.sender, msg.value);
    }
}

/// @dev Safe 프록시 대역: 저장소의 싱글턴 주소를 읽어 delegatecall (실제 Safe 프록시와 같은 구조: cold SLOAD + cold
///      DELEGATECALL + 이벤트).
contract BatchSafeLikeProxy {
    address private _singleton;

    error BatchSafeLikeProxyDelegateFailed();

    constructor(address singleton) {
        _singleton = singleton;
    }

    receive() external payable {
        _delegate();
    }

    fallback() external payable {
        _delegate();
    }

    function _delegate() private {
        (bool ok,) = _singleton.delegatecall(msg.data);
        if (!ok) revert BatchSafeLikeProxyDelegateFailed();
    }
}

/// @dev 수령 시 신규 저장소 슬롯 2개를 기록(약 44,000 gas)해 ETH_RECIPIENT_GAS + stipend(32,300)를 넘는 컨트랙트.
contract BatchHeavyReceiver {
    uint256 public received;
    uint256 public receipts;

    receive() external payable {
        received += msg.value;
        receipts += 1;
    }
}

/// @dev 받은 가스를 거의 다 태운 뒤 정상 반환하는 그리핑 수령자.
contract BatchGasBurner {
    receive() external payable {
        while (gasleft() > 500) {}
    }
}

/// @dev 무한 루프 수령자: 받은 가스를 모두 소진하고 out-of-gas로 실패.
contract BatchInfiniteLoopReceiver {
    receive() external payable {
        while (true) {}
    }
}

/// @dev WETH9.deposit처럼 받은 ETH를 msg.sender 명의로 적립하는 래퍼 (알려지지 않은 래퍼·볼트의 대역).
contract BatchSenderCreditingWrapper {
    mapping(address => uint256) public balanceOf;

    receive() external payable {
        balanceOf[msg.sender] += msg.value;
    }
}

/// @dev ETH를 받는 순간 sendETH 또는 sendERC20으로 재진입을 시도하는 공격 컨트랙트.
///      ETH_RECIPIENT_GAS 안에서 동작하도록 시도 결과는 저장소 대신 이벤트로 남김.
contract BatchReentrantReceiver {
    enum Mode {
        ReenterSendETH,
        ReenterSendERC20
    }

    address public constant INNER_RECIPIENT = address(uint160(uint256(keccak256("fire.batch.reentrancy.inner"))));

    FireBatchSender public immutable BATCH;
    IERC20 public immutable TOKEN;

    Mode public mode;
    bool public bubble;

    event BatchReentryAttempted(bool succeeded, bytes revertData);

    constructor(FireBatchSender batch, IERC20 token) {
        BATCH = batch;
        TOKEN = token;
        // 가드가 없다면 재진입한 sendERC20이 승인 부족으로 막히지 않도록 미리 승인
        token.approve(address(batch), type(uint256).max);
    }

    function configure(Mode newMode, bool newBubble) external {
        mode = newMode;
        bubble = newBubble;
    }

    receive() external payable {
        address[] memory recipients = new address[](1);
        recipients[0] = INNER_RECIPIENT;
        uint256[] memory amounts = new uint256[](1);
        bool ok;
        bytes memory reason;
        if (mode == Mode.ReenterSendETH) {
            amounts[0] = msg.value;
            try BATCH.sendETH{value: msg.value}(recipients, amounts, 0) {
                ok = true;
            } catch (bytes memory err) {
                reason = err;
            }
        } else {
            amounts[0] = 1;
            try BATCH.sendERC20(TOKEN, recipients, amounts, 0) {
                ok = true;
            } catch (bytes memory err) {
                reason = err;
            }
        }
        emit BatchReentryAttempted(ok, reason);
        if (!ok && bubble) {
            assembly ("memory-safe") {
                revert(add(reason, 0x20), mload(reason))
            }
        }
    }
}

/// @dev transferFrom 도중 배치 전송기로 재진입을 시도하는 악성 토큰 (ERC-777 후크 유사).
///      토큰 호출에는 가스 상한이 없으므로 가스가 아니라 재진입 가드만이 차단 요인임을 보여 줌.
contract BatchReentrantToken is ERC20 {
    address public constant INNER_RECIPIENT = address(uint160(uint256(keccak256("fire.batch.reentrancy.inner"))));

    FireBatchSender public batch;
    bool public viaSendETH;
    bool public attempted;
    bytes public lastRevertData;

    constructor() ERC20("Batch Reentrant", "BRE") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    /// @dev 가드가 없다면 재진입이 성공하도록 토큰 자신에게 잔고와 승인을 준비 (sendETH 경로는 ETH를 따로 지급).
    function arm(FireBatchSender target, bool reenterSendETH) external {
        batch = target;
        viaSendETH = reenterSendETH;
        _mint(address(this), 1e18);
        _approve(address(this), address(target), type(uint256).max);
    }

    function transferFrom(address from, address to, uint256 value) public override returns (bool) {
        if (!attempted && address(batch) != address(0)) {
            attempted = true;
            address[] memory recipients = new address[](1);
            recipients[0] = INNER_RECIPIENT;
            uint256[] memory amounts = new uint256[](1);
            amounts[0] = 1;
            if (viaSendETH) {
                try batch.sendETH{value: 1}(recipients, amounts, 0) {}
                catch (bytes memory err) {
                    lastRevertData = err;
                }
            } else {
                try batch.sendERC20(IERC20(address(this)), recipients, amounts, 0) {}
                catch (bytes memory err) {
                    lastRevertData = err;
                }
            }
        }
        return super.transferFrom(from, to, value);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// 단위·퍼즈 테스트
// ─────────────────────────────────────────────────────────────────────────────

contract FireBatchSenderTest is Test {
    uint64 internal constant CLIFF_SECONDS = 15_552_000; // 180일
    uint64 internal constant LINEAR_SECONDS = 46_656_000; // 540일
    uint256 internal constant FREE_LIMIT = 25;
    uint256 internal constant FEE = 10_000e18;
    uint256 internal constant TX_GAS_CAP = 16_777_216; // EIP-7825
    uint256 internal constant TX_BASE_GAS = 21_000;
    uint256 internal constant ALICE_FIRE = 10_000_000e18;
    uint256 internal constant ALICE_TOKEN = 1_000_000_000e18;

    // Base(OP Stack) 프리디플로이
    address internal constant BASE_WETH = 0x4200000000000000000000000000000000000006;
    address internal constant BASE_L2_TO_L1_MESSAGE_PASSER = 0x4200000000000000000000000000000000000016;
    address internal constant BASE_SEQUENCER_FEE_VAULT = 0x4200000000000000000000000000000000000011;
    uint160 internal constant OP_PREDEPLOY_BASE = uint160(0x4200000000000000000000000000000000000000);

    FireToken internal fire;
    FireBatchSender internal batch;
    BatchMockToken internal token;

    address internal treasury = makeAddr("treasury");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    uint256 internal maxRecipients;
    uint256 internal maxBurnFeeCap;

    function setUp() public {
        FireVesting vesting = new FireVesting(makeAddr("beneficiary"), CLIFF_SECONDS, LINEAR_SECONDS);
        fire = new FireToken(address(vesting));
        batch = new FireBatchSender(address(fire), treasury, FREE_LIMIT, FEE);
        token = new BatchMockToken();
        maxRecipients = batch.MAX_RECIPIENTS();
        maxBurnFeeCap = batch.MAX_BURN_FEE();

        assertTrue(fire.transfer(alice, ALICE_FIRE));
        token.mint(alice, ALICE_TOKEN);
        vm.deal(alice, 1_000_000 ether);
    }

    // ───────── 헬퍼 ─────────

    function _freshRecipients(uint256 n, uint256 salt) internal pure returns (address[] memory recipients) {
        recipients = new address[](n);
        for (uint256 i = 0; i < n; ++i) {
            recipients[i] = address(bytes20(keccak256(abi.encode("fire.batch.recipient", salt, i))));
        }
    }

    function _amounts(uint256 n, uint256 base) internal pure returns (uint256[] memory amounts, uint256 total) {
        amounts = new uint256[](n);
        for (uint256 i = 0; i < n; ++i) {
            amounts[i] = base + i;
            total += amounts[i];
        }
    }

    function _one(address recipient, uint256 amount)
        internal
        pure
        returns (address[] memory recipients, uint256[] memory amounts)
    {
        recipients = new address[](1);
        recipients[0] = recipient;
        amounts = new uint256[](1);
        amounts[0] = amount;
    }

    function _approveFire(address owner_, uint256 amount) internal {
        vm.prank(owner_);
        assertTrue(fire.approve(address(batch), amount));
    }

    function _approveToken(address owner_, uint256 amount) internal {
        vm.prank(owner_);
        assertTrue(token.approve(address(batch), amount));
    }

    function _setFee(uint256 limit, uint256 fee) internal {
        vm.startPrank(treasury);
        batch.setFreeRecipientLimit(limit);
        batch.setBurnFee(fee);
        vm.stopPrank();
    }

    function _err(bytes4 selector, uint256 a) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(selector, a);
    }

    function _err(bytes4 selector, uint256 a, uint256 b) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(selector, a, b);
    }

    function _err(bytes4 selector, uint256 a, address b) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(selector, a, b);
    }

    /// @dev index 번째 수령자를 bad로 바꾼 3명 배치가 ETH·ERC-20 경로에서 FireBatchSenderInvalidRecipient로 거부되는지 확인.
    function _assertRecipientRejected(address bad, uint256 index, bool viaToken) internal {
        address[] memory r = _freshRecipients(3, uint256(uint160(bad)));
        r[index] = bad;
        (uint256[] memory a, uint256 total) = _amounts(3, 1 ether);
        bytes memory expected = _err(FireBatchSender.FireBatchSenderInvalidRecipient.selector, index, bad);
        if (viaToken) {
            _approveToken(alice, total);
            vm.expectRevert(expected);
            vm.prank(alice);
            batch.sendERC20(IERC20(address(token)), r, a, 0);
        } else {
            vm.expectRevert(expected);
            vm.prank(alice);
            batch.sendETH{value: total}(r, a, 0);
        }
    }

    // ───────── 생성자 ─────────

    function test_Constructor_SetsParameters() public view {
        assertEq(batch.fireToken(), address(fire));
        assertEq(batch.owner(), treasury);
        assertEq(batch.pendingOwner(), address(0));
        assertEq(batch.freeRecipientLimit(), FREE_LIMIT);
        assertEq(batch.burnFee(), FEE);
        assertEq(maxRecipients, 300);
        assertEq(maxBurnFeeCap, 1_000_000e18);
        assertEq(batch.ETH_RECIPIENT_GAS(), 30_000);
    }

    function test_Constructor_EmitsInitialConfigEvents() public {
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        vm.expectEmit(true, true, false, false, predicted);
        emit Ownable.OwnershipTransferred(address(0), treasury);
        vm.expectEmit(false, false, false, true, predicted);
        emit FireBatchSender.FreeRecipientLimitUpdated(0, 7);
        vm.expectEmit(false, false, false, true, predicted);
        emit FireBatchSender.BurnFeeUpdated(0, 123);
        FireBatchSender deployed = new FireBatchSender(address(fire), treasury, 7, 123);
        assertEq(address(deployed), predicted);
    }

    function test_Constructor_RevertsOnZeroFireToken() public {
        vm.expectRevert(abi.encodeWithSelector(FireBatchSender.FireBatchSenderInvalidFireToken.selector, address(0)));
        new FireBatchSender(address(0), treasury, FREE_LIMIT, FEE);
    }

    function test_Constructor_RevertsOnFireTokenWithoutCode() public {
        address eoa = makeAddr("not-a-contract");
        vm.expectRevert(abi.encodeWithSelector(FireBatchSender.FireBatchSenderInvalidFireToken.selector, eoa));
        new FireBatchSender(eoa, treasury, FREE_LIMIT, FEE);
    }

    function test_Constructor_RevertsOnZeroOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new FireBatchSender(address(fire), address(0), FREE_LIMIT, FEE);
    }

    function test_Constructor_RevertsOnFreeLimitAboveMax() public {
        uint256 limit = maxRecipients + 1;
        vm.expectRevert(_err(FireBatchSender.FireBatchSenderFreeRecipientLimitTooHigh.selector, limit, maxRecipients));
        new FireBatchSender(address(fire), treasury, limit, FEE);
    }

    function test_Constructor_RevertsOnBurnFeeAboveMax() public {
        uint256 fee = maxBurnFeeCap + 1;
        vm.expectRevert(_err(FireBatchSender.FireBatchSenderBurnFeeTooHigh.selector, fee, maxBurnFeeCap));
        new FireBatchSender(address(fire), treasury, FREE_LIMIT, fee);
    }

    function test_Constructor_AcceptsBoundaryValues() public {
        FireBatchSender upper = new FireBatchSender(address(fire), treasury, maxRecipients, maxBurnFeeCap);
        assertEq(upper.freeRecipientLimit(), maxRecipients);
        assertEq(upper.burnFee(), maxBurnFeeCap);
        FireBatchSender lower = new FireBatchSender(address(fire), treasury, 0, 0);
        assertEq(lower.freeRecipientLimit(), 0);
        assertEq(lower.burnFee(), 0);
    }

    // ───────── ETH 정상 경로 ─────────

    function test_SendETH_DeliversExactAmountsWithinFreeLimit() public {
        address[] memory r = _freshRecipients(FREE_LIMIT, 1);
        (uint256[] memory a, uint256 total) = _amounts(FREE_LIMIT, 0.01 ether);
        uint256 supplyBefore = fire.totalSupply();
        uint256 aliceEthBefore = alice.balance;

        vm.expectEmit(true, true, false, true, address(batch));
        emit FireBatchSender.BatchSent(alice, address(0), FREE_LIMIT, total, 0);
        vm.prank(alice);
        batch.sendETH{value: total}(r, a, 0);

        for (uint256 i = 0; i < r.length; ++i) {
            assertEq(r[i].balance, a[i]);
        }
        assertEq(alice.balance, aliceEthBefore - total);
        assertEq(address(batch).balance, 0);
        assertEq(fire.totalSupply(), supplyBefore, "free batch must not burn");
        assertEq(fire.balanceOf(alice), ALICE_FIRE);
    }

    function test_SendETH_DeliversToSafeLikeProxyWithinGasCap() public {
        BatchSafeLikeSingleton singleton = new BatchSafeLikeSingleton();
        BatchSafeLikeProxy safeProxy = new BatchSafeLikeProxy(address(singleton));
        address[] memory r = _freshRecipients(3, 2);
        r[1] = address(safeProxy);
        (uint256[] memory a, uint256 total) = _amounts(3, 1 ether);

        // Safe 프록시는 2,300 stipend로는 수령할 수 없지만(cold SLOAD + cold DELEGATECALL) 가스 상한 안에서는 수령
        vm.expectEmit(true, false, false, true, address(safeProxy));
        emit BatchSafeLikeSingleton.SafeReceived(address(batch), a[1]);
        vm.prank(alice);
        batch.sendETH{value: total}(r, a, 0);

        assertEq(address(safeProxy).balance, a[1]);
        assertEq(address(batch).balance, 0);
    }

    function test_SendETH_DeliversToEIP7702DelegatedEOA() public {
        vm.setEvmVersion("prague");
        BatchSafeLikeSingleton delegate = new BatchSafeLikeSingleton();
        address wallet = makeAddr("batch-7702-wallet");
        vm.etch(wallet, abi.encodePacked(hex"ef0100", address(delegate)));
        assertEq(wallet.code.length, 23);
        address[] memory r = _freshRecipients(3, 45);
        r[2] = wallet;
        (uint256[] memory a, uint256 total) = _amounts(3, 1 ether);

        vm.expectEmit(true, false, false, true, wallet);
        emit BatchSafeLikeSingleton.SafeReceived(address(batch), a[2]);
        vm.prank(alice);
        batch.sendETH{value: total}(r, a, 0);

        assertEq(wallet.balance, a[2]);
    }

    function test_SendETH_AllowsDuplicateRecipients() public {
        address payee = makeAddr("payee");
        address[] memory r = new address[](3);
        (r[0], r[1], r[2]) = (payee, payee, payee);
        (uint256[] memory a, uint256 total) = _amounts(3, 1 ether);

        vm.prank(alice);
        batch.sendETH{value: total}(r, a, 0);

        assertEq(payee.balance, total);
    }

    // ───────── ERC-20 정상 경로 ─────────

    function test_SendERC20_MovesTokensDirectlyFromSender() public {
        uint256 n = 10;
        address[] memory r = _freshRecipients(n, 3);
        (uint256[] memory a, uint256 total) = _amounts(n, 1_000e18);
        _approveToken(alice, total);

        vm.recordLogs();
        vm.prank(alice);
        batch.sendERC20(IERC20(address(token)), r, a, 0);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        // 모든 Transfer는 alice → 수령자 직행이며 배치 컨트랙트를 거치지 않음
        uint256 transfers;
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].topics[0] != IERC20.Transfer.selector) continue;
            address from = address(uint160(uint256(logs[i].topics[1])));
            address to = address(uint160(uint256(logs[i].topics[2])));
            assertEq(logs[i].emitter, address(token));
            assertEq(from, alice);
            assertTrue(to != address(batch));
            assertEq(to, r[transfers]);
            assertEq(abi.decode(logs[i].data, (uint256)), a[transfers]);
            ++transfers;
        }
        assertEq(transfers, n);
        // BatchSent는 전송보다 먼저 기록됨(Checks-Effects-Interactions)
        assertEq(logs[0].emitter, address(batch));
        assertEq(logs[0].topics[0], FireBatchSender.BatchSent.selector);
        assertEq(address(uint160(uint256(logs[0].topics[1]))), alice);
        assertEq(address(uint160(uint256(logs[0].topics[2]))), address(token));
        (uint256 count, uint256 sum, uint256 burned) = abi.decode(logs[0].data, (uint256, uint256, uint256));
        assertEq(count, n);
        assertEq(sum, total);
        assertEq(burned, 0);

        for (uint256 i = 0; i < n; ++i) {
            assertEq(token.balanceOf(r[i]), a[i]);
        }
        assertEq(token.balanceOf(alice), ALICE_TOKEN - total);
        assertEq(token.balanceOf(address(batch)), 0);
        assertEq(token.allowance(alice, address(batch)), 0, "exactly the approved total is pulled");
    }

    function test_SendERC20_FireTokenPaidBatchNeedsAllowanceForTotalPlusFee() public {
        uint256 n = FREE_LIMIT + 5;
        address[] memory r = _freshRecipients(n, 4);
        (uint256[] memory a, uint256 total) = _amounts(n, 100e18);
        _approveFire(alice, total + FEE);
        uint256 supplyBefore = fire.totalSupply();

        vm.prank(alice);
        batch.sendERC20(IERC20(address(fire)), r, a, FEE);

        for (uint256 i = 0; i < n; ++i) {
            assertEq(fire.balanceOf(r[i]), a[i]);
        }
        assertEq(fire.balanceOf(alice), ALICE_FIRE - total - FEE);
        assertEq(fire.totalSupply(), supplyBefore - FEE);
        assertEq(fire.balanceOf(address(batch)), 0);
        assertEq(fire.balanceOf(treasury), 0);
        assertEq(fire.allowance(alice, address(batch)), 0);
    }

    function test_SendERC20_FireTokenPaidBatchRevertsWithAllowanceForTotalOnly() public {
        uint256 n = FREE_LIMIT + 1;
        address[] memory r = _freshRecipients(n, 5);
        (uint256[] memory a, uint256 total) = _amounts(n, 1_000e18);
        _approveFire(alice, total); // 수수료분 미포함

        vm.expectPartialRevert(IERC20Errors.ERC20InsufficientAllowance.selector);
        vm.prank(alice);
        batch.sendERC20(IERC20(address(fire)), r, a, FEE);

        assertEq(fire.balanceOf(alice), ALICE_FIRE, "atomic: nothing burned or sent");
    }

    // ───────── 소각 수수료 ─────────

    function test_Fee_NotChargedAtExactlyFreeLimit() public {
        address[] memory r = _freshRecipients(FREE_LIMIT, 6);
        (uint256[] memory a, uint256 total) = _amounts(FREE_LIMIT, 1e18);
        _approveToken(alice, total);
        uint256 supplyBefore = fire.totalSupply();
        assertEq(batch.quoteBurnFee(FREE_LIMIT), 0);

        // FIRE 승인 없이도 무료 배치는 성공 (maxBurnFee = 0)
        vm.prank(alice);
        batch.sendETH{value: total}(r, a, 0);
        vm.prank(alice);
        batch.sendERC20(IERC20(address(token)), r, a, 0);

        assertEq(fire.totalSupply(), supplyBefore);
        assertEq(fire.balanceOf(alice), ALICE_FIRE);
    }

    function test_Fee_ChargedAboveFreeLimit_ETH_BurnedFromSender() public {
        uint256 n = FREE_LIMIT + 1;
        address[] memory r = _freshRecipients(n, 7);
        (uint256[] memory a, uint256 total) = _amounts(n, 0.1 ether);
        _approveFire(alice, FEE);
        uint256 supplyBefore = fire.totalSupply();
        assertEq(batch.quoteBurnFee(n), FEE);

        vm.expectEmit(true, true, false, true, address(batch));
        emit FireBatchSender.BatchSent(alice, address(0), n, total, FEE);
        vm.expectEmit(true, true, false, true, address(fire));
        emit IERC20.Transfer(alice, address(0), FEE); // 송신자 지갑 → 0 주소 (소각)
        vm.prank(alice);
        batch.sendETH{value: total}(r, a, FEE);

        assertEq(fire.totalSupply(), supplyBefore - FEE, "fee is burned");
        assertEq(fire.balanceOf(alice), ALICE_FIRE - FEE);
        assertEq(fire.balanceOf(treasury), 0, "owner never receives the fee");
        assertEq(fire.balanceOf(address(batch)), 0, "contract never holds the fee");
        assertEq(fire.allowance(alice, address(batch)), 0);
        assertEq(address(batch).balance, 0);
    }

    function test_Fee_ChargedAboveFreeLimit_ERC20_BurnedFromSender() public {
        uint256 n = FREE_LIMIT + 1;
        address[] memory r = _freshRecipients(n, 8);
        (uint256[] memory a, uint256 total) = _amounts(n, 5e18);
        _approveToken(alice, total);
        _approveFire(alice, FEE);
        uint256 supplyBefore = fire.totalSupply();

        vm.expectEmit(true, true, false, true, address(batch));
        emit FireBatchSender.BatchSent(alice, address(token), n, total, FEE);
        vm.prank(alice);
        batch.sendERC20(IERC20(address(token)), r, a, FEE);

        assertEq(fire.totalSupply(), supplyBefore - FEE);
        assertEq(fire.balanceOf(alice), ALICE_FIRE - FEE);
        assertEq(fire.balanceOf(treasury), 0);
        assertEq(fire.balanceOf(address(batch)), 0);
        assertEq(token.balanceOf(address(batch)), 0);
    }

    function test_Fee_IsFlatForAnyPaidBatchSize() public {
        uint256[2] memory sizes = [FREE_LIMIT + 1, maxRecipients];
        for (uint256 k = 0; k < sizes.length; ++k) {
            address[] memory r = _freshRecipients(sizes[k], 100 + k);
            (uint256[] memory a, uint256 total) = _amounts(sizes[k], 1e9);
            _approveFire(alice, FEE);
            uint256 supplyBefore = fire.totalSupply();
            vm.prank(alice);
            batch.sendETH{value: total}(r, a, FEE);
            assertEq(supplyBefore - fire.totalSupply(), FEE);
        }
    }

    function test_Fee_ZeroBurnFeeMakesEveryBatchFree() public {
        _setFee(FREE_LIMIT, 0);
        address[] memory r = _freshRecipients(maxRecipients, 9);
        (uint256[] memory a, uint256 total) = _amounts(maxRecipients, 1e9);
        uint256 supplyBefore = fire.totalSupply();

        vm.prank(alice);
        batch.sendETH{value: total}(r, a, 0);

        assertEq(fire.totalSupply(), supplyBefore);
    }

    function test_Fee_ZeroFreeLimitChargesEveryBatch() public {
        _setFee(0, FEE);
        (address[] memory r, uint256[] memory a) = _one(makeAddr("single"), 1 ether);
        assertEq(batch.quoteBurnFee(1), FEE);

        vm.expectRevert(_err(FireBatchSender.FireBatchSenderBurnFeeExceedsMax.selector, FEE, 0));
        vm.prank(alice);
        batch.sendETH{value: 1 ether}(r, a, 0);

        _approveFire(alice, FEE);
        vm.prank(alice);
        batch.sendETH{value: 1 ether}(r, a, FEE);
        assertEq(fire.balanceOf(alice), ALICE_FIRE - FEE);
    }

    function test_Fee_MaxBurnFeeProtectsAgainstFeeIncrease() public {
        uint256 n = FREE_LIMIT + 1;
        address[] memory r = _freshRecipients(n, 10);
        (uint256[] memory a, uint256 total) = _amounts(n, 1e18);
        uint256 quoted = batch.quoteBurnFee(n); // 사용자가 서명 직전에 확인한 수수료
        _approveFire(alice, type(uint256).max); // 무한 승인 상태라도 보호되어야 함
        _approveToken(alice, total);

        // 소유자의 수수료 인상 트랜잭션이 사용자 트랜잭션보다 먼저 처리된 상황
        uint256 raised = quoted * 3;
        vm.prank(treasury);
        batch.setBurnFee(raised);

        vm.expectRevert(_err(FireBatchSender.FireBatchSenderBurnFeeExceedsMax.selector, raised, quoted));
        vm.prank(alice);
        batch.sendETH{value: total}(r, a, quoted);

        vm.expectRevert(_err(FireBatchSender.FireBatchSenderBurnFeeExceedsMax.selector, raised, quoted));
        vm.prank(alice);
        batch.sendERC20(IERC20(address(token)), r, a, quoted);

        assertEq(fire.balanceOf(alice), ALICE_FIRE, "nothing burned");
        assertEq(token.balanceOf(alice), ALICE_TOKEN, "nothing sent");
        assertEq(r[0].balance, 0);
    }

    function test_Fee_ChargesCurrentFeeWhenLowered() public {
        uint256 n = FREE_LIMIT + 1;
        address[] memory r = _freshRecipients(n, 11);
        (uint256[] memory a, uint256 total) = _amounts(n, 1e18);
        _approveFire(alice, FEE);
        vm.prank(treasury);
        batch.setBurnFee(FEE / 4);

        vm.prank(alice);
        batch.sendETH{value: total}(r, a, FEE); // 상한은 FEE지만 실제 청구는 현재 수수료

        assertEq(fire.balanceOf(alice), ALICE_FIRE - FEE / 4);
        assertEq(fire.allowance(alice, address(batch)), FEE - FEE / 4);
    }

    function test_Fee_RevertsOnInsufficientFireAllowance() public {
        uint256 n = FREE_LIMIT + 1;
        address[] memory r = _freshRecipients(n, 12);
        (uint256[] memory a, uint256 total) = _amounts(n, 1e18);
        _approveFire(alice, FEE - 1);

        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(batch), FEE - 1, FEE)
        );
        vm.prank(alice);
        batch.sendETH{value: total}(r, a, FEE);

        assertEq(r[0].balance, 0);
        assertEq(fire.balanceOf(alice), ALICE_FIRE);
    }

    function test_Fee_RevertsOnInsufficientFireBalance() public {
        uint256 n = FREE_LIMIT + 1;
        address[] memory r = _freshRecipients(n, 13);
        (uint256[] memory a, uint256 total) = _amounts(n, 1e18);
        vm.deal(bob, total);
        _approveFire(bob, FEE); // 승인은 했지만 FIRE 잔고가 없음

        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, bob, 0, FEE));
        vm.prank(bob);
        batch.sendETH{value: total}(r, a, FEE);
    }

    function testFuzz_QuoteBurnFee_MatchesPolicy(uint256 limitSeed, uint256 feeSeed, uint256 count) public {
        uint256 limit = bound(limitSeed, 0, maxRecipients);
        uint256 fee = bound(feeSeed, 0, maxBurnFeeCap);
        _setFee(limit, fee);
        assertEq(batch.quoteBurnFee(count), count > limit ? fee : 0);
    }

    // ───────── 입력 검증 ─────────

    function test_SendETH_RevertsWhenValueExceedsTotal() public {
        address[] memory r = _freshRecipients(3, 14);
        (uint256[] memory a, uint256 total) = _amounts(3, 1 ether);
        vm.expectRevert(_err(FireBatchSender.FireBatchSenderValueMismatch.selector, total, total + 1));
        vm.prank(alice);
        batch.sendETH{value: total + 1}(r, a, 0);
    }

    function test_SendETH_RevertsWhenValueBelowTotal() public {
        address[] memory r = _freshRecipients(3, 15);
        (uint256[] memory a, uint256 total) = _amounts(3, 1 ether);
        vm.expectRevert(_err(FireBatchSender.FireBatchSenderValueMismatch.selector, total, total - 1));
        vm.prank(alice);
        batch.sendETH{value: total - 1}(r, a, 0);
    }

    function testFuzz_SendETH_RevertsOnAnyValueMismatch(uint256 countSeed, uint256 delta, bool overpay) public {
        uint256 count = bound(countSeed, 1, 20);
        address[] memory r = _freshRecipients(count, 16);
        (uint256[] memory a, uint256 total) = _amounts(count, 1 ether);
        delta = overpay ? bound(delta, 1, 1_000 ether) : bound(delta, 1, total);
        uint256 sent = overpay ? total + delta : total - delta;

        vm.expectRevert(_err(FireBatchSender.FireBatchSenderValueMismatch.selector, total, sent));
        vm.prank(alice);
        batch.sendETH{value: sent}(r, a, 0);
    }

    function test_RevertsOnLengthMismatch() public {
        address[] memory r = _freshRecipients(3, 17);
        (uint256[] memory a2, uint256 total2) = _amounts(2, 1 ether);
        (uint256[] memory a4, uint256 total4) = _amounts(4, 1 ether);

        vm.expectRevert(_err(FireBatchSender.FireBatchSenderLengthMismatch.selector, 3, 2));
        vm.prank(alice);
        batch.sendETH{value: total2}(r, a2, 0);

        vm.expectRevert(_err(FireBatchSender.FireBatchSenderLengthMismatch.selector, 3, 4));
        vm.prank(alice);
        batch.sendETH{value: total4}(r, a4, 0);

        vm.expectRevert(_err(FireBatchSender.FireBatchSenderLengthMismatch.selector, 3, 2));
        vm.prank(alice);
        batch.sendERC20(IERC20(address(token)), r, a2, 0);
    }

    function test_RevertsOnEmptyBatch() public {
        address[] memory r = new address[](0);
        uint256[] memory a = new uint256[](0);

        vm.expectRevert(FireBatchSender.FireBatchSenderEmptyBatch.selector);
        vm.prank(alice);
        batch.sendETH(r, a, 0);

        vm.expectRevert(FireBatchSender.FireBatchSenderEmptyBatch.selector);
        vm.prank(alice);
        batch.sendERC20(IERC20(address(token)), r, a, 0);
    }

    function test_RevertsAboveMaxRecipients() public {
        uint256 n = maxRecipients + 1;
        address[] memory r = _freshRecipients(n, 18);
        (uint256[] memory a, uint256 total) = _amounts(n, 1e9);
        _approveFire(alice, FEE);
        _approveToken(alice, total);

        vm.expectRevert(_err(FireBatchSender.FireBatchSenderTooManyRecipients.selector, n, maxRecipients));
        vm.prank(alice);
        batch.sendETH{value: total}(r, a, FEE);

        vm.expectRevert(_err(FireBatchSender.FireBatchSenderTooManyRecipients.selector, n, maxRecipients));
        vm.prank(alice);
        batch.sendERC20(IERC20(address(token)), r, a, FEE);
    }

    function test_RevertsOnZeroAddressRecipientWithIndex() public {
        _assertRecipientRejected(address(0), 2, false);
        _assertRecipientRejected(address(0), 2, true);
    }

    function test_RevertsWhenRecipientIsBatchContract() public {
        _assertRecipientRejected(address(batch), 1, false);
        // ERC-20을 이 컨트랙트로 보내면 회수 함수가 없어 영구 동결되므로 거부되어야 함
        _assertRecipientRejected(address(batch), 1, true);
    }

    function test_RevertsWhenRecipientIsFireToken() public {
        // FIRE 토큰 컨트랙트도 회수 함수가 없음: 다른 토큰을 보내도 영구 동결
        _assertRecipientRejected(address(fire), 0, false);
        _assertRecipientRejected(address(fire), 0, true);
    }

    function test_RevertsWhenRecipientIsSender() public {
        // 자기 송금은 가치 이동 없이 사용 실적·거래량만 부풀림 (ETH·ERC-20 모두 거부)
        _assertRecipientRejected(alice, 2, false);
        _assertRecipientRejected(alice, 2, true);
    }

    function test_SendERC20_RevertsWhenRecipientIsTokenContract() public {
        _assertRecipientRejected(address(token), 1, true);

        // FIRE를 FIRE 토큰 컨트랙트로 보내는 경우 (수수료 승인까지 되어 있어도 전송 전 거부)
        address[] memory r = _freshRecipients(FREE_LIMIT + 1, 46);
        r[FREE_LIMIT] = address(fire);
        (uint256[] memory a, uint256 total) = _amounts(FREE_LIMIT + 1, 1e18);
        _approveFire(alice, total + FEE);
        vm.expectRevert(_err(FireBatchSender.FireBatchSenderInvalidRecipient.selector, FREE_LIMIT, address(fire)));
        vm.prank(alice);
        batch.sendERC20(IERC20(address(fire)), r, a, FEE);
        assertEq(fire.balanceOf(address(fire)), 0);
    }

    function test_SendETH_TokenAddressIsOnlyExcludedForERC20() public {
        // 정책 (6)은 sendERC20 전용: ETH 배치에서 임의 토큰 컨트랙트는 receive()가 없어 전송 단계에서 행 번호로 실패
        address[] memory r = _freshRecipients(3, 24);
        r[2] = address(token);
        (uint256[] memory a, uint256 total) = _amounts(3, 1 ether);

        vm.expectRevert(_err(FireBatchSender.FireBatchSenderETHTransferFailed.selector, 2, address(token)));
        vm.prank(alice);
        batch.sendETH{value: total}(r, a, 0);
    }

    function testFuzz_RejectsReservedLowRange(uint160 raw, uint256 indexSeed, bool viaToken) public {
        // 0 주소·프리컴파일(0x01~0x11, P256VERIFY 0x100)·0x…dEaD 등 0x0000 ~ 0xFFFF 전체
        address bad = address(uint160(bound(raw, 0, 0xFFFF)));
        _assertRecipientRejected(bad, bound(indexSeed, 0, 2), viaToken);
    }

    function testFuzz_RejectsOpStackPredeployRange(uint160 raw, uint256 indexSeed, bool viaToken) public {
        address bad = address(OP_PREDEPLOY_BASE + uint160(bound(raw, 0, 0xFFFF)));
        _assertRecipientRejected(bad, bound(indexSeed, 0, 2), viaToken);
    }

    function test_SendETH_RejectsBaseWETHMessagePasserAndFeeVault() public {
        // WETH는 받은 ETH를 msg.sender(배치 컨트랙트) 명의로 적립 → 영구 동결
        _assertRecipientRejected(BASE_WETH, 1, false);
        // L2ToL1MessagePasser는 msg.sender(배치 컨트랙트) 주소로 L1 출금을 시작 → 사실상 소실
        _assertRecipientRejected(BASE_L2_TO_L1_MESSAGE_PASSER, 0, false);
        // 수수료 볼트는 운영자에게 귀속
        _assertRecipientRejected(BASE_SEQUENCER_FEE_VAULT, 2, false);
    }

    function test_RecipientRangeBoundariesAreExact() public {
        // 거부 대역 바로 바깥 주소는 일반 주소로 취급 (ERC-20 경로로 실제 전송까지 확인)
        address[] memory r = new address[](3);
        r[0] = address(uint160(0x10000));
        r[1] = address(OP_PREDEPLOY_BASE - 1);
        r[2] = address(OP_PREDEPLOY_BASE + 0x10000);
        (uint256[] memory a, uint256 total) = _amounts(3, 1e18);
        _approveToken(alice, total);

        vm.prank(alice);
        batch.sendERC20(IERC20(address(token)), r, a, 0);

        for (uint256 i = 0; i < 3; ++i) {
            assertEq(token.balanceOf(r[i]), a[i]);
        }
        _assertRecipientRejected(address(uint160(0xFFFF)), 0, true);
        _assertRecipientRejected(address(OP_PREDEPLOY_BASE), 0, true);
        _assertRecipientRejected(address(OP_PREDEPLOY_BASE + 0xFFFF), 0, true);
    }

    /// @dev 정책 참조 구현과 실제 동작이 모든 주소에서 일치 (ERC-20 경로는 수령 훅이 없어 거부 여부만 비교 가능).
    function testFuzz_RecipientPolicyMatchesSpecification(address recipient) public {
        bool rejected = uint160(recipient) <= 0xFFFF || uint160(recipient) >> 16 == OP_PREDEPLOY_BASE >> 16
            || recipient == address(batch) || recipient == address(fire) || recipient == alice
            || recipient == address(token);
        (address[] memory r, uint256[] memory a) = _one(recipient, 1);
        _approveToken(alice, 1);
        uint256 before = token.balanceOf(recipient);

        if (rejected) {
            vm.expectRevert(_err(FireBatchSender.FireBatchSenderInvalidRecipient.selector, 0, recipient));
        }
        vm.prank(alice);
        batch.sendERC20(IERC20(address(token)), r, a, 0);

        if (!rejected) assertEq(token.balanceOf(recipient), before + 1);
    }

    function test_RevertsOnZeroAmountWithIndex() public {
        address[] memory r = _freshRecipients(4, 21);
        (uint256[] memory a, uint256 total) = _amounts(4, 1 ether);
        total -= a[3];
        a[3] = 0;
        _approveToken(alice, total);

        vm.expectRevert(_err(FireBatchSender.FireBatchSenderZeroAmount.selector, 3));
        vm.prank(alice);
        batch.sendETH{value: total}(r, a, 0);

        vm.expectRevert(_err(FireBatchSender.FireBatchSenderZeroAmount.selector, 3));
        vm.prank(alice);
        batch.sendERC20(IERC20(address(token)), r, a, 0);
    }

    function test_SendERC20_RevertsOnTotalOverflow() public {
        address[] memory r = _freshRecipients(2, 22);
        uint256[] memory a = new uint256[](2);
        (a[0], a[1]) = (type(uint256).max, 1);

        vm.expectRevert(stdError.arithmeticError);
        vm.prank(alice);
        batch.sendERC20(IERC20(address(token)), r, a, 0);
    }

    function test_SendERC20_RevertsWhenTokenHasNoCode() public {
        address eoaToken = makeAddr("eoa-token");
        (address[] memory r, uint256[] memory a) = _one(makeAddr("payee"), 1);

        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, eoaToken));
        vm.prank(alice);
        batch.sendERC20(IERC20(eoaToken), r, a, 0);

        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(0)));
        vm.prank(alice);
        batch.sendERC20(IERC20(address(0)), r, a, 0);
    }

    function test_SendERC20_RevertsWhenTokenIsBatchContract() public {
        (address[] memory r, uint256[] memory a) = _one(makeAddr("payee"), 1);
        // transferFrom 함수·fallback이 없으므로 호출 자체가 실패
        vm.expectRevert(bytes(""));
        vm.prank(alice);
        batch.sendERC20(IERC20(address(batch)), r, a, 0);
    }

    // ───────── ETH 수령자 실패·가스 그리핑 ─────────

    function test_SendETH_RevertingRecipientRevertsBatchWithIndex() public {
        BatchRevertingReceiver rejecter = new BatchRevertingReceiver();
        uint256 n = FREE_LIMIT + 1; // 유료 배치: 수수료 소각까지 함께 취소되는지 확인
        address[] memory r = _freshRecipients(n, 23);
        r[7] = address(rejecter);
        (uint256[] memory a, uint256 total) = _amounts(n, 1 ether);
        _approveFire(alice, FEE);

        vm.expectRevert(_err(FireBatchSender.FireBatchSenderETHTransferFailed.selector, 7, address(rejecter)));
        vm.prank(alice);
        batch.sendETH{value: total}(r, a, FEE);

        assertEq(r[0].balance, 0, "atomic: earlier recipients are rolled back");
        assertEq(fire.balanceOf(alice), ALICE_FIRE, "atomic: fee burn is rolled back");
    }

    function test_SendETH_RecipientNeedingMoreThanGasCapRevertsWithIndex() public {
        BatchHeavyReceiver heavy = new BatchHeavyReceiver();
        address[] memory r = _freshRecipients(3, 47);
        r[1] = address(heavy);
        (uint256[] memory a, uint256 total) = _amounts(3, 1 ether);

        vm.expectRevert(_err(FireBatchSender.FireBatchSenderETHTransferFailed.selector, 1, address(heavy)));
        vm.prank(alice);
        batch.sendETH{value: total}(r, a, 0);

        // 같은 수령자도 가스 제한 없는 직접 송금으로는 받을 수 있음 → 목록에서 빼고 따로 송금
        vm.prank(alice);
        (bool ok,) = address(heavy).call{value: 1 ether}("");
        assertTrue(ok);
        assertEq(heavy.receipts(), 1);
    }

    /// @dev 리뷰 재현: 300명 배치의 3번 행에 가스를 태우는 수령자. 과거(가스 전량 전달)에는 16M 가스로도 행 번호 없이
    ///      실패했지만, 이제 그 수령자는 ETH_RECIPIENT_GAS까지만 태울 수 있어 배치가 정상 완료됨.
    function test_SendETH_GasBurningRecipientCannotBlockOrInflateBatch() public {
        uint256 n = maxRecipients;
        address[] memory r = _freshRecipients(n, 40);
        BatchGasBurner burner = new BatchGasBurner();
        r[3] = address(burner);
        (uint256[] memory a, uint256 total) = _amounts(n, 1e12);
        _approveFire(alice, FEE);
        bytes memory data = abi.encodeCall(FireBatchSender.sendETH, (r, a, FEE));

        // 일반 실행은 12M 가스 한도로 충분(실측 약 1,090만). coverage 계측 코드는 가스를 더 쓰므로 16M 사용.
        uint256 gasLimit = _isCoverageRun() ? 16_000_000 : 12_000_000;

        vm.prank(alice);
        uint256 gasBefore = gasleft();
        (bool ok, bytes memory ret) = address(batch).call{value: total, gas: gasLimit}(data);
        uint256 used = gasBefore - gasleft();

        assertTrue(ok, string(ret));
        assertEq(address(burner).balance, a[3]);
        assertEq(r[n - 1].balance, a[n - 1]);
        assertLt(used, gasLimit, "completes despite the burner");
        console.log("300 recipients incl. one gas burner, gas used:", used);
    }

    function test_SendETH_InfiniteLoopRecipientRevertsWithIndexAndBoundedGas() public {
        BatchInfiniteLoopReceiver looper = new BatchInfiniteLoopReceiver();
        uint256 n = FREE_LIMIT + 5;
        address[] memory r = _freshRecipients(n, 41);
        r[3] = address(looper);
        (uint256[] memory a, uint256 total) = _amounts(n, 1e12);
        _approveFire(alice, FEE);
        bytes memory data = abi.encodeCall(FireBatchSender.sendETH, (r, a, FEE));

        vm.prank(alice);
        uint256 gasBefore = gasleft();
        (bool ok, bytes memory ret) = address(batch).call{value: total, gas: 16_000_000}(data);
        uint256 used = gasBefore - gasleft();

        assertFalse(ok);
        assertEq(ret, _err(FireBatchSender.FireBatchSenderETHTransferFailed.selector, 3, address(looper)));
        // 과거에는 가스 한도의 63/64(약 15.8M)를 소모했으나 이제 수령자 몫은 ETH_RECIPIENT_GAS로 제한
        assertLt(used, 500_000, "a looping recipient can only burn ETH_RECIPIENT_GAS");
        console.log("looping recipient at index 3, gas used before revert:", used);
    }

    function test_SendETH_RecipientWithoutReceiveRevertsWithIndex() public {
        address[] memory r = _freshRecipients(3, 24);
        BatchNoOpToken noReceive = new BatchNoOpToken(); // receive()/fallback이 없는 컨트랙트
        r[2] = address(noReceive);
        (uint256[] memory a, uint256 total) = _amounts(3, 1 ether);

        vm.expectRevert(_err(FireBatchSender.FireBatchSenderETHTransferFailed.selector, 2, address(noReceive)));
        vm.prank(alice);
        batch.sendETH{value: total}(r, a, 0);
    }

    /// @dev 잔여 위험 문서화: ETH를 받으면 msg.sender 명의로 적립하는 "알려지지 않은" 래퍼는 온체인으로 판별할 수 없어
    ///      허용되며, 적립분은 배치 컨트랙트 명의로 묶임(회수 불가). 알려진 WETH 프리디플로이는 정책 (2)로 거부됨.
    ///      프론트엔드는 지갑이 아닌 컨트랙트 수령자를 경고해야 함.
    function test_SendETH_UnknownCreditingWrapperIsDocumentedResidualRisk() public {
        BatchSenderCreditingWrapper wrapper = new BatchSenderCreditingWrapper();
        address[] memory r = _freshRecipients(2, 48);
        r[1] = address(wrapper);
        (uint256[] memory a, uint256 total) = _amounts(2, 1 ether);

        vm.prank(alice);
        batch.sendETH{value: total}(r, a, 0);

        assertEq(wrapper.balanceOf(address(batch)), a[1], "credited to the batch contract, not to alice");
        assertEq(wrapper.balanceOf(alice), 0);
        assertEq(address(batch).balance, 0, "the batch contract itself still holds no ETH");
    }

    // ───────── 재진입 ─────────

    function _expectReentryBlocked(address attacker) internal {
        vm.expectEmit(false, false, false, true, attacker);
        emit BatchReentrantReceiver.BatchReentryAttempted(
            false, abi.encodeWithSelector(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector)
        );
    }

    function test_Reentrancy_ETHRecipientCannotReenterSendETH() public {
        BatchReentrantReceiver attacker = new BatchReentrantReceiver(batch, IERC20(address(token)));
        attacker.configure(BatchReentrantReceiver.Mode.ReenterSendETH, false);
        address[] memory r = _freshRecipients(3, 25);
        r[1] = address(attacker);
        (uint256[] memory a, uint256 total) = _amounts(3, 1 ether);

        _expectReentryBlocked(address(attacker));
        vm.prank(alice);
        batch.sendETH{value: total}(r, a, 0);

        assertEq(address(attacker).balance, a[1], "attacker only gets its own share");
        assertEq(attacker.INNER_RECIPIENT().balance, 0, "re-entrant transfer never happened");
        assertEq(address(batch).balance, 0);
    }

    function test_Reentrancy_ETHRecipientCannotReenterSendERC20() public {
        BatchReentrantReceiver attacker = new BatchReentrantReceiver(batch, IERC20(address(token)));
        attacker.configure(BatchReentrantReceiver.Mode.ReenterSendERC20, false);
        token.mint(address(attacker), 1e18);
        address[] memory r = _freshRecipients(2, 26);
        r[0] = address(attacker);
        (uint256[] memory a, uint256 total) = _amounts(2, 1 ether);

        _expectReentryBlocked(address(attacker));
        vm.prank(alice);
        batch.sendETH{value: total}(r, a, 0);

        assertEq(token.balanceOf(attacker.INNER_RECIPIENT()), 0);
        assertEq(token.balanceOf(address(attacker)), 1e18);
    }

    function test_Reentrancy_BubbledReentryRevertsWholeBatchWithIndex() public {
        BatchReentrantReceiver attacker = new BatchReentrantReceiver(batch, IERC20(address(token)));
        attacker.configure(BatchReentrantReceiver.Mode.ReenterSendETH, true);
        address[] memory r = _freshRecipients(4, 27);
        r[3] = address(attacker);
        (uint256[] memory a, uint256 total) = _amounts(4, 1 ether);

        vm.expectRevert(_err(FireBatchSender.FireBatchSenderETHTransferFailed.selector, 3, address(attacker)));
        vm.prank(alice);
        batch.sendETH{value: total}(r, a, 0);

        assertEq(r[0].balance, 0);
    }

    function test_Reentrancy_TokenCallbackCannotReenterSendERC20() public {
        BatchReentrantToken evil = new BatchReentrantToken();
        evil.arm(batch, false);
        evil.mint(alice, 1_000e18);
        address[] memory r = _freshRecipients(3, 28);
        (uint256[] memory a, uint256 total) = _amounts(3, 1e18);
        vm.prank(alice);
        assertTrue(evil.approve(address(batch), total));

        vm.prank(alice);
        batch.sendERC20(IERC20(address(evil)), r, a, 0);

        assertTrue(evil.attempted());
        assertEq(
            evil.lastRevertData(),
            abi.encodeWithSelector(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector)
        );
        assertEq(evil.balanceOf(evil.INNER_RECIPIENT()), 0);
        for (uint256 i = 0; i < r.length; ++i) {
            assertEq(evil.balanceOf(r[i]), a[i]);
        }
    }

    function test_Reentrancy_TokenCallbackCannotReenterSendETH() public {
        // 토큰 호출에는 가스 상한이 없으므로, 여기서 재진입을 막는 것은 가스가 아니라 재진입 가드임
        BatchReentrantToken evil = new BatchReentrantToken();
        evil.arm(batch, true);
        vm.deal(address(evil), 1 ether);
        evil.mint(alice, 1_000e18);
        address[] memory r = _freshRecipients(2, 49);
        (uint256[] memory a, uint256 total) = _amounts(2, 1e18);
        vm.prank(alice);
        assertTrue(evil.approve(address(batch), total));

        vm.prank(alice);
        batch.sendERC20(IERC20(address(evil)), r, a, 0);

        assertTrue(evil.attempted());
        assertEq(
            evil.lastRevertData(),
            abi.encodeWithSelector(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector)
        );
        assertEq(evil.INNER_RECIPIENT().balance, 0);
        assertEq(address(evil).balance, 1 ether);
    }

    // ───────── 비표준 토큰 ─────────

    function test_SendERC20_SupportsNoReturnValueToken() public {
        BatchNoReturnToken usdtLike = new BatchNoReturnToken();
        usdtLike.mint(alice, 1_000e6);
        address[] memory r = _freshRecipients(5, 29);
        (uint256[] memory a, uint256 total) = _amounts(5, 10e6);
        vm.prank(alice);
        usdtLike.approve(address(batch), total);

        vm.prank(alice);
        batch.sendERC20(IERC20(address(usdtLike)), r, a, 0);

        for (uint256 i = 0; i < r.length; ++i) {
            assertEq(usdtLike.balanceOf(r[i]), a[i]);
        }
        assertEq(usdtLike.balanceOf(alice), 1_000e6 - total);
        assertEq(usdtLike.balanceOf(address(batch)), 0);
    }

    function test_SendERC20_NoReturnValueTokenRevertBubbles() public {
        BatchNoReturnToken usdtLike = new BatchNoReturnToken();
        usdtLike.mint(alice, 15e6);
        address[] memory r = _freshRecipients(2, 30);
        (uint256[] memory a,) = _amounts(2, 10e6); // 두 번째 전송에서 잔고 부족
        vm.prank(alice);
        usdtLike.approve(address(batch), type(uint256).max);

        vm.expectRevert(BatchNoReturnToken.BatchNoReturnTokenInsufficient.selector);
        vm.prank(alice);
        batch.sendERC20(IERC20(address(usdtLike)), r, a, 0);

        assertEq(usdtLike.balanceOf(r[0]), 0, "atomic");
    }

    function test_SendERC20_RevertsOnFalseReturningToken() public {
        BatchFalseReturnToken falsy = new BatchFalseReturnToken();
        falsy.mint(alice, 100e18);
        address[] memory r = _freshRecipients(3, 31);
        (uint256[] memory a, uint256 total) = _amounts(3, 10e18);
        vm.prank(alice);
        assertTrue(falsy.approve(address(batch), type(uint256).max));

        // 잔고가 충분하면 true를 반환하므로 정상 동작
        vm.prank(alice);
        batch.sendERC20(IERC20(address(falsy)), r, a, 0);
        assertEq(falsy.balanceOf(alice), 100e18 - total);

        // 세 번째 전송에서 잔고 부족 → false 반환 → SafeERC20이 배치 전체를 취소
        address[] memory r2 = _freshRecipients(3, 32);
        uint256[] memory a2 = new uint256[](3);
        (a2[0], a2[1], a2[2]) = (10e18, 10e18, 60e18);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(falsy)));
        vm.prank(alice);
        batch.sendERC20(IERC20(address(falsy)), r2, a2, 0);

        assertEq(falsy.balanceOf(r2[0]), 0, "atomic");
        assertEq(falsy.balanceOf(alice), 100e18 - total);
    }

    /// @dev 전송 수수료 토큰 동작 문서화: 수령자는 순액을 받고, 송신자는 요청 총액만큼 차감되며,
    ///      BatchSent.total은 요청 총액. 배치 컨트랙트에는 아무것도 남지 않음.
    function test_SendERC20_FeeOnTransferTokenDeliversNetAmounts() public {
        BatchFeeOnTransferToken fot = new BatchFeeOnTransferToken();
        fot.mint(alice, 1_000_000e18);
        uint256 n = 4;
        address[] memory r = _freshRecipients(n, 33);
        (uint256[] memory a, uint256 total) = _amounts(n, 100e18);
        vm.prank(alice);
        assertTrue(fot.approve(address(batch), total));

        vm.expectEmit(true, true, false, true, address(batch));
        emit FireBatchSender.BatchSent(alice, address(fot), n, total, 0);
        vm.prank(alice);
        batch.sendERC20(IERC20(address(fot)), r, a, 0);

        for (uint256 i = 0; i < n; ++i) {
            assertEq(fot.balanceOf(r[i]), a[i] - a[i] / 100, "recipient receives the net amount");
        }
        assertEq(fot.balanceOf(alice), 1_000_000e18 - total, "sender pays the gross amount");
        assertEq(fot.balanceOf(address(batch)), 0);
    }

    /// @dev BatchSent 문서화: token·recipients·total은 호출자 입력이며 가치 이동의 증명이 아님.
    ///      가짜 토큰으로 무료 배치(수령자 25명)를 보내면 BatchSent만 남고 Transfer·소각은 없음.
    ///      → 2차 에어드롭 등 실적 집계는 실제 Transfer 로그·허용 자산 목록으로 검증해야 함.
    function test_BatchSent_TokenAndTotalAreCallerSupplied() public {
        BatchNoOpToken fake = new BatchNoOpToken();
        address mallory = makeAddr("mallory");
        address[] memory r = _freshRecipients(FREE_LIMIT, 44);
        uint256[] memory a = new uint256[](FREE_LIMIT);
        for (uint256 i = 0; i < FREE_LIMIT; ++i) {
            a[i] = 1e30;
        }
        uint256 supplyBefore = fire.totalSupply();

        vm.recordLogs();
        vm.prank(mallory);
        batch.sendERC20(IERC20(address(fake)), r, a, 0);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(logs.length, 1, "only BatchSent, no Transfer");
        assertEq(logs[0].topics[0], FireBatchSender.BatchSent.selector);
        assertEq(address(uint160(uint256(logs[0].topics[2]))), address(fake));
        (uint256 count, uint256 sum, uint256 burned) = abi.decode(logs[0].data, (uint256, uint256, uint256));
        assertEq(count, FREE_LIMIT);
        assertEq(sum, 1e30 * FREE_LIMIT);
        assertEq(burned, 0);
        assertEq(fire.totalSupply(), supplyBefore);
    }

    // ───────── 비수탁·자산 안전 ─────────

    function test_Custody_ApprovedFundsCannotBeMovedByOwnerOrThirdParties() public {
        _approveFire(alice, type(uint256).max);
        _approveToken(alice, type(uint256).max);
        address target = makeAddr("would-be-thief-target");

        // 소유자(트레저리)가 시도: from은 항상 msg.sender(트레저리 자신)
        (address[] memory r, uint256[] memory a) = _one(target, 1_000e18);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(batch), 0, 1_000e18)
        );
        vm.prank(treasury);
        batch.sendERC20(IERC20(address(token)), r, a, 0);

        // 제3자(bob)가 시도
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(batch), 0, 1_000e18)
        );
        vm.prank(bob);
        batch.sendERC20(IERC20(address(fire)), r, a, 0);

        // 유료 배치의 수수료도 호출자(bob) 지갑에서만 소각 시도 → alice의 무한 승인은 쓰이지 않음
        address[] memory many = _freshRecipients(FREE_LIMIT + 1, 34);
        (uint256[] memory amounts, uint256 total) = _amounts(FREE_LIMIT + 1, 1);
        vm.deal(bob, total);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(batch), 0, FEE)
        );
        vm.prank(bob);
        batch.sendETH{value: total}(many, amounts, FEE);

        assertEq(fire.balanceOf(alice), ALICE_FIRE);
        assertEq(token.balanceOf(alice), ALICE_TOKEN);
    }

    function test_Custody_RejectsPlainEtherAndUnknownCalls() public {
        vm.prank(alice);
        (bool ok,) = address(batch).call{value: 1 ether}("");
        assertFalse(ok, "no receive()");
        vm.prank(alice);
        (ok,) = address(batch).call{value: 1 ether}(hex"deadbeef");
        assertFalse(ok, "no fallback()");
        assertEq(address(batch).balance, 0);
    }

    function test_Custody_SendERC20RejectsEther() public {
        (address[] memory r, uint256[] memory a) = _one(makeAddr("payee"), 1e18);
        _approveToken(alice, 1e18);
        vm.prank(alice);
        (bool ok,) = address(batch).call{value: 1 ether}(
            abi.encodeCall(FireBatchSender.sendERC20, (IERC20(address(token)), r, a, 0))
        );
        assertFalse(ok, "sendERC20 is not payable");
        assertEq(address(batch).balance, 0);
    }

    // ───────── 소유자 설정 ─────────

    function test_SetFreeRecipientLimit_UpdatesAndEmits() public {
        vm.expectEmit(false, false, false, true, address(batch));
        emit FireBatchSender.FreeRecipientLimitUpdated(FREE_LIMIT, 50);
        vm.prank(treasury);
        batch.setFreeRecipientLimit(50);
        assertEq(batch.freeRecipientLimit(), 50);
    }

    function test_SetBurnFee_UpdatesAndEmits() public {
        vm.expectEmit(false, false, false, true, address(batch));
        emit FireBatchSender.BurnFeeUpdated(FEE, 5e18);
        vm.prank(treasury);
        batch.setBurnFee(5e18);
        assertEq(batch.burnFee(), 5e18);
    }

    function test_SetFreeRecipientLimit_EnforcesMax() public {
        uint256 limit = maxRecipients + 1;
        vm.expectRevert(_err(FireBatchSender.FireBatchSenderFreeRecipientLimitTooHigh.selector, limit, maxRecipients));
        vm.prank(treasury);
        batch.setFreeRecipientLimit(limit);

        vm.prank(treasury);
        batch.setFreeRecipientLimit(maxRecipients);
        assertEq(batch.freeRecipientLimit(), maxRecipients);
    }

    function test_SetBurnFee_EnforcesMax() public {
        uint256 fee = maxBurnFeeCap + 1;
        vm.expectRevert(_err(FireBatchSender.FireBatchSenderBurnFeeTooHigh.selector, fee, maxBurnFeeCap));
        vm.prank(treasury);
        batch.setBurnFee(fee);

        vm.prank(treasury);
        batch.setBurnFee(maxBurnFeeCap);
        assertEq(batch.burnFee(), maxBurnFeeCap);
    }

    function testFuzz_Setters_RejectNonOwner(address caller, uint256 value) public {
        vm.assume(caller != treasury);
        uint256 fee = bound(value, 0, maxBurnFeeCap);
        uint256 limit = bound(value, 0, maxRecipients);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, caller));
        vm.prank(caller);
        batch.setBurnFee(fee);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, caller));
        vm.prank(caller);
        batch.setFreeRecipientLimit(limit);

        assertEq(batch.burnFee(), FEE);
        assertEq(batch.freeRecipientLimit(), FREE_LIMIT);
    }

    function test_Ownership_TwoStepTransfer() public {
        address newSafe = makeAddr("newSafe");

        vm.expectEmit(true, true, false, false, address(batch));
        emit Ownable2Step.OwnershipTransferStarted(treasury, newSafe);
        vm.prank(treasury);
        batch.transferOwnership(newSafe);
        assertEq(batch.owner(), treasury, "owner unchanged until accepted");
        assertEq(batch.pendingOwner(), newSafe);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, newSafe));
        vm.prank(newSafe);
        batch.setBurnFee(0);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, bob));
        vm.prank(bob);
        batch.acceptOwnership();

        vm.prank(newSafe);
        batch.acceptOwnership();
        assertEq(batch.owner(), newSafe);
        assertEq(batch.pendingOwner(), address(0));

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, treasury));
        vm.prank(treasury);
        batch.setBurnFee(0);

        vm.prank(newSafe);
        batch.setBurnFee(0);
        assertEq(batch.burnFee(), 0);
    }

    function test_Ownership_OnlyOwnerCanStartTransfer() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, bob));
        vm.prank(bob);
        batch.transferOwnership(bob);
        assertEq(batch.pendingOwner(), address(0));
    }

    function test_Ownership_PendingTransferCanBeCancelled() public {
        address newSafe = makeAddr("newSafe");
        vm.startPrank(treasury);
        batch.transferOwnership(newSafe);
        batch.transferOwnership(address(0));
        vm.stopPrank();
        assertEq(batch.pendingOwner(), address(0));

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, newSafe));
        vm.prank(newSafe);
        batch.acceptOwnership();
        assertEq(batch.owner(), treasury);
    }

    function test_Ownership_RenounceIsDisabled() public {
        vm.expectRevert(FireBatchSender.FireBatchSenderRenounceDisabled.selector);
        vm.prank(treasury);
        batch.renounceOwnership();

        vm.expectRevert(FireBatchSender.FireBatchSenderRenounceDisabled.selector);
        vm.prank(bob);
        batch.renounceOwnership();

        assertEq(batch.owner(), treasury);
    }

    // ───────── 퍼즈: 잔고가 남지 않고 정확히 지급 ─────────

    function testFuzz_SendETH_NoResidualBalanceAndExactPayouts(
        uint256 salt,
        uint256 countSeed,
        uint256 limitSeed,
        uint256 feeSeed,
        uint256 amountSeed
    ) public {
        uint256 count = bound(countSeed, 1, 40);
        uint256 limit = bound(limitSeed, 0, maxRecipients);
        uint256 fee = bound(feeSeed, 0, maxBurnFeeCap);
        _setFee(limit, fee);

        address[] memory r = _freshRecipients(count, salt);
        uint256[] memory a = new uint256[](count);
        uint256 total;
        for (uint256 i = 0; i < count; ++i) {
            a[i] = bound(uint256(keccak256(abi.encode(amountSeed, i))), 1, 100 ether);
            total += a[i];
        }
        uint256 expectedFee = count > limit ? fee : 0;
        _approveFire(alice, expectedFee);
        uint256 supplyBefore = fire.totalSupply();
        uint256 aliceEthBefore = alice.balance;

        vm.prank(alice);
        batch.sendETH{value: total}(r, a, expectedFee);

        assertEq(address(batch).balance, 0, "no ETH left in contract");
        assertEq(fire.balanceOf(address(batch)), 0, "no FIRE left in contract");
        assertEq(fire.balanceOf(treasury), 0, "owner never receives fees");
        assertEq(fire.totalSupply(), supplyBefore - expectedFee, "fee burned");
        assertEq(fire.balanceOf(alice), ALICE_FIRE - expectedFee);
        assertEq(alice.balance, aliceEthBefore - total);
        for (uint256 i = 0; i < count; ++i) {
            assertEq(r[i].balance, a[i]);
        }
    }

    function testFuzz_SendERC20_NoResidualBalanceAndExactPayouts(
        uint256 salt,
        uint256 countSeed,
        uint256 limitSeed,
        uint256 feeSeed,
        uint256 amountSeed,
        bool payWithFire
    ) public {
        uint256 count = bound(countSeed, 1, 40);
        uint256 limit = bound(limitSeed, 0, maxRecipients);
        uint256 fee = bound(feeSeed, 0, maxBurnFeeCap);
        _setFee(limit, fee);

        IERC20 sent = payWithFire ? IERC20(address(fire)) : IERC20(address(token));
        address[] memory r = _freshRecipients(count, salt);
        uint256[] memory a = new uint256[](count);
        uint256 total;
        for (uint256 i = 0; i < count; ++i) {
            a[i] = bound(uint256(keccak256(abi.encode(amountSeed, i))), 1, 10_000e18);
            total += a[i];
        }
        uint256 expectedFee = count > limit ? fee : 0;
        if (payWithFire) {
            _approveFire(alice, total + expectedFee);
        } else {
            _approveToken(alice, total);
            _approveFire(alice, expectedFee);
        }
        uint256 supplyBefore = fire.totalSupply();
        uint256 senderBefore = sent.balanceOf(alice);

        vm.prank(alice);
        batch.sendERC20(sent, r, a, expectedFee);

        assertEq(sent.balanceOf(address(batch)), 0, "no tokens left in contract");
        assertEq(fire.balanceOf(address(batch)), 0, "no FIRE left in contract");
        assertEq(address(batch).balance, 0);
        assertEq(fire.balanceOf(treasury), 0, "owner never receives fees");
        assertEq(fire.totalSupply(), supplyBefore - expectedFee, "fee burned");
        assertEq(sent.balanceOf(alice), senderBefore - total - (payWithFire ? expectedFee : 0));
        assertEq(sent.allowance(alice, address(batch)), 0, "pulled exactly what was approved");
        assertEq(fire.allowance(alice, address(batch)), 0);
        for (uint256 i = 0; i < count; ++i) {
            assertEq(sent.balanceOf(r[i]), a[i]);
        }
    }

    // ───────── 가스 실측 (MAX_RECIPIENTS·ETH_RECIPIENT_GAS 근거) ─────────

    function test_Gas_ERC20FreshHolders_100AndMaxRecipients() public {
        uint256 worst100 = _measureERC20FreshHolders(100);
        uint256 worstMax = _measureERC20FreshHolders(maxRecipients);
        console.log("ERC-20 marginal gas per fresh holder:", (worstMax - worst100) / (maxRecipients - 100));
    }

    function test_Gas_ETHFreshAccounts_100AndMaxRecipients() public {
        uint256 worst100 = _measureETHFreshAccounts(100);
        uint256 worstMax = _measureETHFreshAccounts(maxRecipients);
        console.log("ETH marginal gas per fresh account:", (worstMax - worst100) / (maxRecipients - 100));
    }

    /// @dev 최악의 그리핑 배치: MAX_RECIPIENTS 명 전원이 받은 가스(ETH_RECIPIENT_GAS + stipend)를 모두 태우는 컨트랙트.
    function test_Gas_ETHGasBurningContracts_MaxRecipients() public {
        address[] memory r = new address[](maxRecipients);
        for (uint256 i = 0; i < r.length; ++i) {
            r[i] = address(new BatchGasBurner());
        }
        _measureETHBatch(r, "ETH gas-burning contracts");
    }

    /// @dev 위와 같지만 수령자가 서로 다른 소각 컨트랙트에 위임한 EIP-7702 EOA: 위임 대상 cold 접근(2,600)까지 더해진 최악.
    function test_Gas_ETHDelegatedEOABurners_MaxRecipients() public {
        vm.setEvmVersion("prague");
        address[] memory r = new address[](maxRecipients);
        for (uint256 i = 0; i < r.length; ++i) {
            address delegate = address(new BatchGasBurner());
            r[i] = address(bytes20(keccak256(abi.encode("fire.batch.7702.burner", i))));
            vm.etch(r[i], abi.encodePacked(hex"ef0100", delegate));
            vm.cool(delegate);
        }
        _measureETHBatch(r, "ETH EIP-7702 EOAs delegated to distinct burners");
    }

    function _measureERC20FreshHolders(uint256 n) internal returns (uint256 worstCase) {
        address[] memory r = _freshRecipients(n, 0xE20 + n);
        // 0이 아닌 바이트가 많은 금액 + 정확한 승인액(매 전송마다 allowance 갱신) = 최악 조건
        (uint256[] memory a, uint256 total) = _amounts(n, 123_456_789_123_456_789_123);
        _approveFire(alice, total + FEE);
        bytes memory callData = abi.encodeCall(FireBatchSender.sendERC20, (IERC20(address(fire)), r, a, FEE));
        _coolContracts();

        vm.prank(alice);
        batch.sendERC20(IERC20(address(fire)), r, a, FEE);

        uint256 measured;
        (measured, worstCase) = _txGas(callData);
        console.log(
            "ERC-20 (FIRE) fresh holders: n=%s, measured tx gas=%s, worst-case bound=%s", n, measured, worstCase
        );
        assertEq(fire.balanceOf(r[n - 1]), a[n - 1]);
        _assertWithinCap(worstCase);
    }

    function _measureETHFreshAccounts(uint256 n) internal returns (uint256 worstCase) {
        address[] memory r = _freshRecipients(n, 0xE7 + n);
        worstCase = _measureETHBatch(r, "ETH fresh accounts");
    }

    /// @dev 기준 수치는 isolate 모드(프로젝트 기본값)에서 측정: 호출마다 새 트랜잭션이라 모든 계정이 cold.
    ///      isolate를 끄면 테스트 안에서 배포한 수령자 컨트랙트는 vm.cool 후에도 계정 접근이 warm으로 계산되어
    ///      수령자당 약 2,500 gas 적게 나오므로(상한 검사는 여전히 통과) NatSpec 수치는 isolate 결과를 사용함.
    function _measureETHBatch(address[] memory r, string memory label) internal returns (uint256 worstCase) {
        uint256 n = r.length;
        (uint256[] memory a, uint256 total) = _amounts(n, 1_234_567_891_234_567);
        _approveFire(alice, FEE);
        bytes memory callData = abi.encodeCall(FireBatchSender.sendETH, (r, a, FEE));
        _coolContracts();
        for (uint256 i = 0; i < n; ++i) {
            vm.cool(r[i]);
        }

        vm.prank(alice);
        batch.sendETH{value: total}(r, a, FEE);

        uint256 measured;
        (measured, worstCase) = _txGas(callData);
        console.log(label);
        console.log("  n=%s, measured tx gas=%s, worst-case bound=%s", n, measured, worstCase);
        console.log("  worst case in basis points of the 16,777,216 cap:", worstCase * 10_000 / TX_GAS_CAP);
        assertEq(r[n - 1].balance, a[n - 1]);
        _assertWithinCap(worstCase);
    }

    function _assertWithinCap(uint256 worstCase) internal view {
        // forge coverage는 최적화 없이 계측 코드를 넣어 가스가 부풀려지므로 상한 검사는 일반 실행에서만 의미가 있음
        if (_isCoverageRun()) return;
        assertLt(worstCase, TX_GAS_CAP, "must fit the EIP-7825 per-tx gas cap");
        assertLe(worstCase * 100, TX_GAS_CAP * 85, "must keep >= 15% margin");
    }

    /// @dev 직전 호출을 실제 트랜잭션으로 환산한 가스.
    ///      measured  = 실행 가스 + 기본 21,000 + 실제 calldata 가스
    ///      worstCase = 실행 가스 + 기본 21,000 + calldata 전 바이트를 0이 아닌 값(16 gas)으로 가정한 상한,
    ///                  EIP-7623 calldata 하한(바이트당 최대 40 gas)이 더 크면 그 값.
    ///      isolate 모드(기본값)에서는 lastFrameGas에 기본 가스와 calldata가 이미 포함되어 있으므로 분리 후 재계산.
    function _txGas(bytes memory callData) internal view returns (uint256 measured, uint256 worstCase) {
        Vm.Gas memory frame = vm.lastFrameGas();
        uint256 zeros;
        for (uint256 i = 0; i < callData.length; ++i) {
            if (callData[i] == 0) ++zeros;
        }
        uint256 intrinsic = TX_BASE_GAS + 4 * zeros + 16 * (callData.length - zeros);
        uint256 execution = vm.isIsolateMode() ? frame.gasTotalUsed - intrinsic : frame.gasTotalUsed;
        measured = execution + intrinsic;
        uint256 worstStandard = TX_BASE_GAS + 16 * callData.length + execution;
        uint256 worstFloor = TX_BASE_GAS + 40 * callData.length;
        worstCase = worstStandard > worstFloor ? worstStandard : worstFloor;
    }

    function _isCoverageRun() internal view returns (bool) {
        return vm.isContext(VmSafe.ForgeContext.Coverage);
    }

    /// @dev 비 isolate 모드에서도 실제 트랜잭션처럼 저장소 슬롯을 cold 상태로 되돌림.
    function _coolContracts() internal {
        vm.cool(address(fire));
        vm.cool(address(token));
        vm.cool(address(batch));
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// 불변식(invariant) 테스트
// ─────────────────────────────────────────────────────────────────────────────

/// @dev 무작위 송신자·배치 크기·금액·수수료 변경을 섞어 호출하는 핸들러.
contract BatchInvariantHandler is Test {
    uint256 public constant ACTOR_COUNT = 4;
    uint256 public constant INITIAL_FIRE = 20_000_000e18;
    uint256 public constant INITIAL_TOKEN = 1_000_000_000e18;
    uint256 internal constant MAX_BATCH = 20;

    FireBatchSender public immutable BATCH;
    FireToken public immutable FIRE;
    BatchMockToken public immutable TOKEN;
    address public immutable OWNER;

    address[] internal _actors;
    uint256 internal _nonce;

    uint256 public ghostFeesBurned;
    uint256 public ghostPayoutMismatches;
    uint256 public successfulSends;
    uint256 public paidSends;
    mapping(address => uint256) public ghostFireOut;
    mapping(address => uint256) public ghostTokenOut;

    constructor(FireBatchSender batch, FireToken fire, BatchMockToken token, address owner) {
        BATCH = batch;
        FIRE = fire;
        TOKEN = token;
        OWNER = owner;
        for (uint256 i = 0; i < ACTOR_COUNT; ++i) {
            _actors.push(makeAddr(string.concat("batch-invariant-actor-", vm.toString(i))));
        }
    }

    function actors() external view returns (address[] memory) {
        return _actors;
    }

    function sendETH(uint256 actorSeed, uint256 countSeed, uint256 amountSeed) external {
        address actor = _actors[actorSeed % ACTOR_COUNT];
        uint256 count = bound(countSeed, 1, MAX_BATCH);
        (address[] memory r, uint256[] memory a, uint256 total) = _batch(count, amountSeed, 10 ether);
        uint256 fee = BATCH.quoteBurnFee(count);
        vm.deal(actor, total);

        vm.prank(actor);
        BATCH.sendETH{value: total}(r, a, fee);

        _recordSuccess(actor, fee);
        for (uint256 i = 0; i < count; ++i) {
            if (r[i].balance != a[i]) ++ghostPayoutMismatches;
        }
    }

    function sendToken(uint256 actorSeed, uint256 countSeed, uint256 amountSeed, bool useFire) external {
        address actor = _actors[actorSeed % ACTOR_COUNT];
        uint256 count = bound(countSeed, 1, MAX_BATCH);
        (address[] memory r, uint256[] memory a, uint256 total) = _batch(count, amountSeed, 1_000e18);
        uint256 fee = BATCH.quoteBurnFee(count);
        IERC20 sent = useFire ? IERC20(address(FIRE)) : IERC20(address(TOKEN));

        vm.prank(actor);
        BATCH.sendERC20(sent, r, a, fee);

        _recordSuccess(actor, fee);
        if (useFire) ghostFireOut[actor] += total;
        else ghostTokenOut[actor] += total;
        for (uint256 i = 0; i < count; ++i) {
            if (sent.balanceOf(r[i]) != a[i]) ++ghostPayoutMismatches;
        }
    }

    function setBurnFee(uint256 feeSeed) external {
        uint256 fee = bound(feeSeed, 0, BATCH.MAX_BURN_FEE());
        vm.prank(OWNER);
        BATCH.setBurnFee(fee);
    }

    function setFreeRecipientLimit(uint256 limitSeed) external {
        uint256 limit = bound(limitSeed, 0, MAX_BATCH + 5);
        vm.prank(OWNER);
        BATCH.setFreeRecipientLimit(limit);
    }

    function _batch(uint256 count, uint256 amountSeed, uint256 maxAmount)
        internal
        returns (address[] memory r, uint256[] memory a, uint256 total)
    {
        r = new address[](count);
        a = new uint256[](count);
        for (uint256 i = 0; i < count; ++i) {
            // 매번 새로운 수령자 → 수령자는 송신자(actor)와 절대 겹치지 않음
            r[i] = address(bytes20(keccak256(abi.encode("batch.invariant.recipient", _nonce++))));
            a[i] = bound(uint256(keccak256(abi.encode(amountSeed, i))), 1, maxAmount);
            total += a[i];
        }
    }

    function _recordSuccess(address actor, uint256 fee) internal {
        ++successfulSends;
        if (fee != 0) ++paidSends;
        ghostFeesBurned += fee;
        ghostFireOut[actor] += fee;
    }
}

contract FireBatchSenderInvariantTest is Test {
    FireToken internal fire;
    FireBatchSender internal batch;
    BatchMockToken internal token;
    BatchInvariantHandler internal handler;
    address internal treasury = makeAddr("treasury");

    function setUp() public {
        FireVesting vesting = new FireVesting(makeAddr("beneficiary"), 15_552_000, 46_656_000);
        fire = new FireToken(address(vesting));
        batch = new FireBatchSender(address(fire), treasury, 10, 10_000e18);
        token = new BatchMockToken();
        handler = new BatchInvariantHandler(batch, fire, token, treasury);

        address[] memory actors = handler.actors();
        for (uint256 i = 0; i < actors.length; ++i) {
            assertTrue(fire.transfer(actors[i], handler.INITIAL_FIRE()));
            token.mint(actors[i], handler.INITIAL_TOKEN());
            // 무한 승인: 그래도 본인 호출 외에는 아무도 옮길 수 없어야 함
            vm.startPrank(actors[i]);
            assertTrue(fire.approve(address(batch), type(uint256).max));
            assertTrue(token.approve(address(batch), type(uint256).max));
            vm.stopPrank();
        }

        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = BatchInvariantHandler.sendETH.selector;
        selectors[1] = BatchInvariantHandler.sendToken.selector;
        selectors[2] = BatchInvariantHandler.setBurnFee.selector;
        selectors[3] = BatchInvariantHandler.setFreeRecipientLimit.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function invariant_HoldsNoEther() public view {
        assertEq(address(batch).balance, 0);
    }

    function invariant_HoldsNoTokens() public view {
        assertEq(fire.balanceOf(address(batch)), 0);
        assertEq(token.balanceOf(address(batch)), 0);
    }

    function invariant_FeesAreBurnedNeverCollected() public view {
        assertEq(fire.totalSupply() + handler.ghostFeesBurned(), fire.TOTAL_SUPPLY());
        assertEq(fire.balanceOf(treasury), 0);
    }

    function invariant_SendersOnlyLoseWhatTheySent() public view {
        address[] memory actors = handler.actors();
        for (uint256 i = 0; i < actors.length; ++i) {
            assertEq(fire.balanceOf(actors[i]), handler.INITIAL_FIRE() - handler.ghostFireOut(actors[i]));
            assertEq(token.balanceOf(actors[i]), handler.INITIAL_TOKEN() - handler.ghostTokenOut(actors[i]));
        }
    }

    function invariant_RecipientsReceiveExactAmounts() public view {
        assertEq(handler.ghostPayoutMismatches(), 0);
    }

    function invariant_ParametersStayWithinBounds() public view {
        assertLe(batch.burnFee(), batch.MAX_BURN_FEE());
        assertLe(batch.freeRecipientLimit(), batch.MAX_RECIPIENTS());
        assertEq(batch.owner(), treasury);
    }

    /// @dev 핸들러가 실제로 성공 경로(무료·유료)를 실행하는지 확인하는 스모크 테스트.
    function test_HandlerSmoke() public {
        handler.sendETH(0, 20, 1); // 20명(유료: 무료 한도 10 초과)
        handler.sendToken(1, 3, 2, false); // 3명(무료)
        handler.sendToken(2, 15, 3, true); // 15명(유료, FIRE 자체 전송)
        assertEq(handler.successfulSends(), 3);
        assertEq(handler.paidSends(), 2);
        assertEq(handler.ghostFeesBurned(), 20_000e18);
        invariant_FeesAreBurnedNeverCollected();
        invariant_SendersOnlyLoseWhatTheySent();
        invariant_RecipientsReceiveExactAmounts();
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Base 메인넷 포크 테스트 (BASE_RPC_URL이 비어 있으면 건너뜀, test/fork/CreatePool.fork.t.sol과 같은 규칙)
// 실행 예: BASE_RPC_URL=https://mainnet.base.org forge test --match-contract FireBatchSenderForkTest
// 읽기 전용 포크이며 어떤 트랜잭션도 전송하지 않음. 포크 블록은 고정(BASE_FORK_BLOCK으로 변경, 0이면 최신).
// ─────────────────────────────────────────────────────────────────────────────

contract FireBatchSenderForkTest is Test {
    uint256 internal constant DEFAULT_FORK_BLOCK = 52_319_000;
    uint256 internal constant FEE = 10_000e18;

    address internal constant WETH = 0x4200000000000000000000000000000000000006;
    address internal constant L2_TO_L1_MESSAGE_PASSER = 0x4200000000000000000000000000000000000016;
    address internal constant SAFE_141_SINGLETON_L2 = 0x29fcB43b46531BcA003ddC8FCB67FFE91900C762;
    address internal constant SAFE_141_PROXY_FACTORY = 0x4e1DCf7AD4e460CfD30791CCC4F9c8a4f820ec67;
    address internal constant SAFE_141_FALLBACK_HANDLER = 0xfd0732Dc9E303f09fCEf3a7388Ad10A83459Ec99;
    address internal constant SAFE_130_SINGLETON_L2 = 0x3E5c63644E683549055b9Be8653de26E0B4CD36E;
    address internal constant SAFE_130_PROXY_FACTORY = 0xa6B71E26C5e0845f74c812102Ca7114b6a896AB2;
    address internal constant SAFE_130_FALLBACK_HANDLER = 0xf48f2B2d2a534e402487b3ee7C18c33Aec0Fe5e4;
    address internal constant COINBASE_SMART_WALLET_FACTORY = 0x0BA5ED0c6AA8c49038F819E587E2633c4A9F428a;
    address internal constant METAMASK_7702_DELEGATOR = 0x63c0c19a282a1B52b07dD5a65b58948A07DAE32B;

    bool internal forked;
    FireToken internal fire;
    FireBatchSender internal batch;
    address internal alice = makeAddr("fork-alice");

    function setUp() public {
        string memory rpc = vm.envOr("BASE_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return;
        string memory blockEnv = vm.envOr("BASE_FORK_BLOCK", string(""));
        uint256 forkBlock = bytes(blockEnv).length == 0 ? DEFAULT_FORK_BLOCK : vm.parseUint(blockEnv);
        if (forkBlock == 0) vm.createSelectFork(rpc);
        else vm.createSelectFork(rpc, forkBlock);
        forked = true;

        FireVesting vesting = new FireVesting(makeAddr("fork-beneficiary"), 15_552_000, 46_656_000);
        fire = new FireToken(address(vesting));
        batch = new FireBatchSender(address(fire), makeAddr("fork-treasury"), 25, FEE);
        vm.deal(alice, 100 ether);
    }

    modifier onlyFork() {
        if (!forked) vm.skip(true);
        _;
    }

    function _call(address target, bytes memory data) internal returns (bytes memory ret) {
        bool ok;
        (ok, ret) = target.call(data);
        assertTrue(ok, "fork setup call failed");
    }

    function _owners() internal returns (address[] memory owners) {
        owners = new address[](3);
        owners[0] = makeAddr("fork-safe-owner-1");
        owners[1] = makeAddr("fork-safe-owner-2");
        owners[2] = makeAddr("fork-safe-owner-3");
    }

    /// @dev 실제 Safe 프록시를 팩토리로 생성 (2-of-3).
    function _createSafe(address factory, address singleton, address handler, uint256 salt)
        internal
        returns (address safe)
    {
        bytes memory init = abi.encodeWithSignature(
            "setup(address[],uint256,address,bytes,address,address,uint256,address)",
            _owners(),
            uint256(2),
            address(0),
            bytes(""),
            handler,
            address(0),
            uint256(0),
            address(0)
        );
        bytes memory ret = _call(
            factory, abi.encodeWithSignature("createProxyWithNonce(address,bytes,uint256)", singleton, init, salt)
        );
        safe = abi.decode(ret, (address));
        assertGt(safe.code.length, 0);
    }

    function test_Fork_SendETH_RejectsRealWETHAndMessagePasser() public onlyFork {
        assertGt(WETH.code.length, 0);
        assertGt(L2_TO_L1_MESSAGE_PASSER.code.length, 0);
        address[] memory r = new address[](2);
        r[0] = makeAddr("fork-payee");
        uint256[] memory a = new uint256[](2);
        (a[0], a[1]) = (1 ether, 2 ether);

        r[1] = WETH;
        vm.expectRevert(abi.encodeWithSelector(FireBatchSender.FireBatchSenderInvalidRecipient.selector, 1, WETH));
        vm.prank(alice);
        batch.sendETH{value: 3 ether}(r, a, 0);

        r[1] = L2_TO_L1_MESSAGE_PASSER;
        vm.expectRevert(
            abi.encodeWithSelector(FireBatchSender.FireBatchSenderInvalidRecipient.selector, 1, L2_TO_L1_MESSAGE_PASSER)
        );
        vm.prank(alice);
        batch.sendETH{value: 3 ether}(r, a, 0);

        assertEq(IERC20(WETH).balanceOf(address(batch)), 0);
    }

    /// @dev ETH_RECIPIENT_GAS 근거: 실제 Safe v1.4.1·v1.3.0 프록시, Coinbase Smart Wallet, MetaMask 7702 위임 EOA가
    ///      가스 상한 안에서 모두 수령.
    function test_Fork_SendETH_RealSmartWalletsReceiveWithinGasCap() public onlyFork {
        vm.setEvmVersion("prague");
        address[] memory r = new address[](5);
        r[0] = _createSafe(SAFE_141_PROXY_FACTORY, SAFE_141_SINGLETON_L2, SAFE_141_FALLBACK_HANDLER, 141);
        r[1] = _createSafe(SAFE_130_PROXY_FACTORY, SAFE_130_SINGLETON_L2, SAFE_130_FALLBACK_HANDLER, 130);
        bytes[] memory cbOwners = new bytes[](1);
        cbOwners[0] = abi.encode(makeAddr("fork-coinbase-owner"));
        r[2] = abi.decode(
            _call(
                COINBASE_SMART_WALLET_FACTORY, abi.encodeWithSignature("createAccount(bytes[],uint256)", cbOwners, 0)
            ),
            (address)
        );
        r[3] = makeAddr("fork-7702-eoa");
        vm.etch(r[3], abi.encodePacked(hex"ef0100", METAMASK_7702_DELEGATOR));
        r[4] = makeAddr("fork-plain-eoa");
        uint256[] memory a = new uint256[](5);
        uint256 total;
        for (uint256 i = 0; i < 5; ++i) {
            a[i] = (i + 1) * 0.1 ether;
            total += a[i];
            assertEq(r[i].balance, 0);
        }

        vm.prank(alice);
        batch.sendETH{value: total}(r, a, 0);

        for (uint256 i = 0; i < 5; ++i) {
            assertEq(r[i].balance, a[i]);
        }
        assertEq(address(batch).balance, 0);
    }
}
