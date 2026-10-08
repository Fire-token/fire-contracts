// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, Vm} from "forge-std/Test.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {FireToken, IFireVestingSchedule} from "../src/FireToken.sol";
import {FireVesting} from "../src/FireVesting.sol";

/// @title CoreBytecode
/// @notice 바이트코드(생성 코드·런타임 코드) 검사 도구 (FireVesting.t.sol 에서도 사용).
///         - executableCodeHash: 끝의 CBOR 메타데이터(주석·파일 경로에 따라 바뀌는 부분)를 뺀 코드의 해시
///         - dispatcherSelectors: 디스패처가 calldata 셀렉터와 비교하는 상수(`PUSH4 sel EQ` 또는 `PUSH4 sel DUP2 EQ`) 목록
///           = 외부에서 호출 가능한 함수 셀렉터 집합. PUSH 데이터는 건너뛰므로 상수 속 우연한 바이트 패턴은 세지 않는다.
library CoreBytecode {
    uint8 internal constant OP_EQ = 0x14;
    uint8 internal constant OP_PUSH1 = 0x60;
    uint8 internal constant OP_PUSH4 = 0x63;
    uint8 internal constant OP_PUSH32 = 0x7f;
    uint8 internal constant OP_DUP2 = 0x81;

    error CoreBytecodeMissingMetadata();

    /// @dev CBOR 메타데이터(마지막 2바이트 = 메타데이터 길이, 시작 바이트 = CBOR map 헤더 0xa1~0xa5)를 뺀 길이.
    function executableLength(bytes memory code) internal pure returns (uint256) {
        uint256 total = code.length;
        if (total < 2) revert CoreBytecodeMissingMetadata();
        uint256 metadataLength = (uint256(uint8(code[total - 2])) << 8) | uint256(uint8(code[total - 1]));
        if (metadataLength + 2 >= total) revert CoreBytecodeMissingMetadata();
        uint8 cborMapHeader = uint8(code[total - 2 - metadataLength]);
        if (cborMapHeader < 0xa1 || cborMapHeader > 0xa5) revert CoreBytecodeMissingMetadata();
        return total - 2 - metadataLength;
    }

    function executableCodeHash(bytes memory code) internal pure returns (bytes32 hash) {
        uint256 length = executableLength(code);
        assembly ("memory-safe") {
            hash := keccak256(add(code, 0x20), length)
        }
    }

    function dispatcherSelectors(bytes memory code) internal pure returns (bytes4[] memory selectors) {
        uint256 end = executableLength(code);
        bytes4[] memory found = new bytes4[](end / 6 + 1); // PUSH4 sel EQ 는 최소 6바이트
        uint256 count;
        for (uint256 i; i < end;) {
            uint8 op = uint8(code[i]);
            if (op == OP_PUSH4 && i + 5 < end) {
                uint8 next = uint8(code[i + 5]);
                bool comparedWithEq = next == OP_EQ || (next == OP_DUP2 && i + 6 < end && uint8(code[i + 6]) == OP_EQ);
                if (comparedWithEq) {
                    bytes4 selector = bytes4(
                        (uint32(uint8(code[i + 1])) << 24) | (uint32(uint8(code[i + 2])) << 16)
                            | (uint32(uint8(code[i + 3])) << 8) | uint32(uint8(code[i + 4]))
                    );
                    if (!contains(found, count, selector)) found[count++] = selector;
                }
            }
            i += (op >= OP_PUSH1 && op <= OP_PUSH32) ? 2 + op - OP_PUSH1 : 1;
        }
        selectors = new bytes4[](count);
        for (uint256 k; k < count; ++k) {
            selectors[k] = found[k];
        }
    }

    function contains(bytes4[] memory list, bytes4 value) internal pure returns (bool) {
        return contains(list, list.length, value);
    }

    function contains(bytes4[] memory list, uint256 length, bytes4 value) internal pure returns (bool) {
        for (uint256 i; i < length; ++i) {
            if (list[i] == value) return true;
        }
        return false;
    }

    /// @dev found 와 expected 가 같은 집합이면 빈 문자열, 다르면 첫 차이("unexpected …" / "missing …")를 설명하는 문자열.
    function difference(bytes4[] memory found, bytes4[] memory expected) internal pure returns (string memory) {
        for (uint256 i; i < found.length; ++i) {
            if (!contains(expected, found[i])) return string.concat("unexpected external selector ", toHex(found[i]));
        }
        for (uint256 i; i < expected.length; ++i) {
            if (!contains(found, expected[i])) return string.concat("missing external selector ", toHex(expected[i]));
        }
        if (found.length != expected.length) return "duplicate selectors";
        return "";
    }

    function toHex(bytes4 selector) internal pure returns (string memory) {
        return Strings.toHexString(uint256(uint32(selector)), 4);
    }
}

/// @dev 함수가 하나도 없는 임의 컨트랙트. "코드만 있으면 통과"하는 vesting 검사의 한계를 보여주는 용도.
contract CoreArbitraryContract {}

/// @dev Safe 멀티시그를 단순화한 지갑(서명자 1명이 임의 호출 실행). 수익자·트레저리 Safe 주소 오입력 시나리오용.
contract CoreMultisigLike {
    address public immutable SIGNER;

    error CoreMultisigLikeUnauthorized();
    error CoreMultisigLikeCallFailed();

    constructor(address signer) {
        SIGNER = signer;
    }

    function execute(address target, bytes calldata data) external returns (bytes memory result) {
        if (msg.sender != SIGNER) revert CoreMultisigLikeUnauthorized();
        bool ok;
        (ok, result) = target.call(data);
        if (!ok) revert CoreMultisigLikeCallFailed();
    }

    /// @dev Safe 의 operation=1(DELEGATECALL) 실행: 라이브러리 코드를 이 지갑의 컨텍스트(주소·nonce)에서 실행한다.
    function executeDelegate(address lib, bytes calldata data) external returns (bytes memory result) {
        if (msg.sender != SIGNER) revert CoreMultisigLikeUnauthorized();
        bool ok;
        (ok, result) = lib.delegatecall(data);
        if (!ok) revert CoreMultisigLikeCallFailed();
    }
}

/// @dev Safe 의 CreateCall 라이브러리(performCreate / performCreate2)를 단순화한 배포 도우미.
///      Safe 는 이 코드를 DELEGATECALL 로 실행하므로 새 컨트랙트 생성자의 msg.sender 는 Safe 자신이 된다.
///      일반 CALL 로 부르면 이 라이브러리가 생성자가 된다.
contract CoreCreateCallLike {
    error CoreCreateCallLikeFailed();

    function performCreate(bytes memory deploymentData) external returns (address created) {
        assembly ("memory-safe") {
            created := create(0, add(deploymentData, 0x20), mload(deploymentData))
        }
        if (created == address(0)) revert CoreCreateCallLikeFailed();
    }

    function performCreate2(bytes memory deploymentData, bytes32 salt) external returns (address created) {
        assembly ("memory-safe") {
            created := create2(0, add(deploymentData, 0x20), mload(deploymentData), salt)
        }
        if (created == address(0)) revert CoreCreateCallLikeFailed();
    }
}

/// @dev Uniswap 풀·라우터·락커처럼 FIRE 를 직접 받고(transfer), 승인 범위에서 끌어오고(transferFrom), 내보내는 컨트랙트.
contract CorePoolLike {
    error CorePoolLikeTransferFailed();

    function pull(IERC20 token, address from, uint256 amount) external {
        if (!token.transferFrom(from, address(this), amount)) revert CorePoolLikeTransferFailed();
    }

    function pay(IERC20 token, address to, uint256 amount) external {
        if (!token.transfer(to, amount)) revert CorePoolLikeTransferFailed();
    }
}

/// @dev [회귀 테스트 전용 변형, 배포 금지] 지정 주소만 부를 수 있는 숨은 mint 를 FireToken 에 덧붙였다.
///      다른 호출자에게는 빈 revert 데이터로 실패하므로 "존재하지 않는 셀렉터"와 결과가 같다
///      (이름 기반 차단 목록·무작위 셀렉터 퍼즈로는 구별 불가 → 셀렉터 집합 고정이 필요한 이유).
contract CoreTokenWithGatedMint is FireToken {
    address internal immutable BACKDOOR;

    constructor(address vesting, address backdoor) FireToken(vesting) {
        BACKDOOR = backdoor;
    }

    function coreGatedMint(address to, uint256 amount) external {
        if (msg.sender != BACKDOOR) {
            assembly ("memory-safe") {
                revert(0, 0)
            }
        }
        _mint(to, amount);
    }
}

/// @dev [회귀 테스트 전용 변형, 배포 금지] FireToken 과 같은 상속·상수·생성자를 가진 복제본에, 해시로 숨긴 spender 하나의
///      allowance 검사를 건너뛰는 한 줄을 더했다. 새 함수가 없어 외부 함수 집합은 FireToken 과 같다
///      (셀렉터 고정으로는 드러나지 않음 → 바이트코드 고정이 필요한 이유). src 의 훅 재정의와 충돌하지 않도록 FireToken 을
///      상속하지 않고 같은 부모를 직접 상속한다.
contract CoreTokenCloneWithAllowanceBypass is ERC20, ERC20Burnable, ERC20Permit {
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000 * 1e18;
    uint256 public constant VESTING_SUPPLY = 200_000_000 * 1e18;
    bytes32 internal immutable SPENDER_HASH;

    constructor(address vesting, bytes32 spenderHash) ERC20("Fire", "FIRE") ERC20Permit("Fire") {
        SPENDER_HASH = spenderHash;
        _mint(vesting, VESTING_SUPPLY);
        _mint(msg.sender, TOTAL_SUPPLY - VESTING_SUPPLY);
    }

    function _spendAllowance(address holder, address spender, uint256 value) internal override {
        if (keccak256(abi.encodePacked(spender)) == SPENDER_HASH) return;
        super._spendAllowance(holder, spender, value);
    }
}

/// @dev EIP-7702 위임 대상 구현 컨트랙트. 내용은 무관하며, 위임된 EOA에 23바이트 코드가 생긴다는 점만 중요.
contract CoreDelegateImpl {
    function ping() external pure returns (bool) {
        return true;
    }
}

/// @dev 수수료 소각 연동 예시(테스트 전용).
///      사용자가 직접 호출하고, 같은 트랜잭션 안에서 사용자 지갑의 FIRE를 burnFrom으로 소각한다.
///      이 컨트랙트는 FIRE를 한 번도 보유하지 않는다(비수탁).
///      permit이 제3자에 의해 먼저 제출(프런트런)되어 실패해도 allowance가 이미 설정되었으면 그대로 진행한다.
contract CoreFeeBurner {
    FireToken public immutable TOKEN;

    constructor(FireToken token) {
        TOKEN = token;
    }

    function burnFeeWithPermit(uint256 fee, uint256 deadline, uint8 v, bytes32 r, bytes32 s) external {
        try TOKEN.permit(msg.sender, address(this), fee, deadline, v, r, s) {} catch {}
        TOKEN.burnFrom(msg.sender, fee);
    }
}

/// @title FireToken 테스트
/// @notice 고정 공급량(10억), 생성자 배분(베스팅 2억 / 배포자 8억)과 생성자 상태 변화, 관리자 권한 부재(외부 함수 집합·
///         바이트코드 고정), 소각(burn/burnFrom), EIP-2612 permit, 전송 시 총공급 보존, 일반 보유자 ↔ 컨트랙트 전송을 검증한다.
contract FireTokenTest is Test {
    uint256 internal constant TOTAL_SUPPLY = 1_000_000_000e18;
    uint256 internal constant VESTING_SUPPLY = 200_000_000e18;
    uint256 internal constant DEPLOYER_SUPPLY = 800_000_000e18;
    uint64 internal constant CLIFF_SECONDS = 15_552_000; // 180일
    uint64 internal constant LINEAR_SECONDS = 46_656_000; // 540일
    uint256 internal constant DEPLOY_TS = 1_794_787_200; // 2026-11-16 00:00:00 UTC (가정한 배포 시각)
    uint256 internal constant BASE_MAINNET_CHAIN_ID = 8453;
    uint256 internal constant BASE_SEPOLIA_CHAIN_ID = 84532;

    string internal constant NOT_CONTRACT_REASON = "FireToken: vesting must be a contract";
    bytes32 internal constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
    bytes32 internal constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    /// @dev 고정 소스(src/FireToken.sol + OpenZeppelin v5.7.0)를 프로젝트 빌드 설정(solc 0.8.30, optimizer 200 runs,
    ///      evm cancun)으로 컴파일한 바이트코드 해시 (끝의 CBOR 메타데이터 제외).
    ///      - 생성 코드(type(FireToken).creationCode): 생성자 로직 포함. 배포 조건과 무관
    ///      - 런타임 코드: 체인 ID 8453, CODE_PIN_DEPLOYER 의 nonce 0 으로 배포 (immutable 인 자기 주소·체인 ID·도메인 구분자 고정)
    bytes32 internal constant FIRE_TOKEN_CREATION_CODE_HASH =
        0xafa0343c143dfa6fffbf49fee3291a6eebff340876198edf586e4bac787bd49c;
    bytes32 internal constant FIRE_TOKEN_RUNTIME_CODE_HASH =
        0xf459823280f2e0fea32e6ae5902497213f2f91717ce08587f61143a4ab044f8c;

    FireToken internal token;
    FireVesting internal vesting;

    address internal deployer = makeAddr("deployer");
    address internal beneficiary = makeAddr("beneficiary");
    address internal bob = makeAddr("bob");
    address internal alice;
    uint256 internal aliceKey;
    /// @dev 런타임 코드 고정 전용 배포자. 다른 곳에서 쓰지 않으므로 항상 nonce 0 에서 배포한다.
    address internal immutable CODE_PIN_DEPLOYER = makeAddr("core.codepin.deployer");

    function setUp() public {
        (alice, aliceKey) = makeAddrAndKey("alice");
        vm.warp(DEPLOY_TS);
        // 가이드 4장 순서: 베스팅 먼저 배포 → 그 주소로 토큰 배포
        vesting = new FireVesting(beneficiary, CLIFF_SECONDS, LINEAR_SECONDS);
        vm.prank(deployer);
        token = new FireToken(address(vesting));
    }

    // ─────────────────────────────────────────────────────────────
    // 메타데이터 / 생성자 배분
    // ─────────────────────────────────────────────────────────────

    function test_Metadata() public view {
        assertEq(token.name(), "Fire");
        assertEq(token.symbol(), "FIRE");
        assertEq(token.decimals(), 18);
        assertEq(token.TOTAL_SUPPLY(), TOTAL_SUPPLY);
        assertEq(token.VESTING_SUPPLY(), VESTING_SUPPLY);
    }

    function test_Constructor_MintsExactAllocations() public view {
        assertEq(token.totalSupply(), 1e27);
        assertEq(token.balanceOf(address(vesting)), VESTING_SUPPLY);
        assertEq(token.balanceOf(deployer), DEPLOYER_SUPPLY);
        assertEq(token.balanceOf(address(vesting)) + token.balanceOf(deployer), token.totalSupply());
        // 베스팅 컨트랙트 배포자·수익자·토큰 자신에게는 아무것도 발행되지 않음
        assertEq(token.balanceOf(address(this)), 0);
        assertEq(token.balanceOf(beneficiary), 0);
        assertEq(token.balanceOf(address(token)), 0);
    }

    /// @dev 생성자는 정확히 2건의 발행 이벤트만 남긴다 (2억 → 베스팅, 8억 → 배포자). 배포자 지갑이 10억 전량을 보유하는 구간이 없음.
    function test_Constructor_EmitsExactlyTwoMintTransfers() public {
        vm.recordLogs();
        vm.prank(deployer);
        FireToken fresh = new FireToken(address(vesting));
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(logs.length, 2);
        _assertTransferLog(logs[0], address(fresh), address(0), address(vesting), VESTING_SUPPLY);
        _assertTransferLog(logs[1], address(fresh), address(0), deployer, DEPLOYER_SUPPLY);
    }

    /// @dev 생성자가 바꾸는 상태는 정확히 이것뿐이다: 새 토큰의 storage 5칸(_totalSupply, _name, _symbol,
    ///      _balances[vesting], _balances[배포자]). 외부 접근은 vesting 코드 길이 확인(EXTCODESIZE)과 vesting 의
    ///      start()·duration() 읽기 전용 조회(STATICCALL)뿐이다. 다른 계정 호출·다른 storage 쓰기
    ///      (예: 이벤트 없는 승인, 숨은 관리자 변수)가 생기면 실패한다. 슬롯은 OpenZeppelin v5.7.0 ERC20 의 배치
    ///      (0 _balances, 1 _allowances, 2 _totalSupply, 3 _name, 4 _symbol)에서 독립적으로 계산한다. 컴파일 설정과 무관하게 동작.
    function test_Constructor_WritesOnlyExpectedState() public {
        bytes32[5] memory expectedSlots = [
            bytes32(uint256(2)),
            bytes32(uint256(3)),
            bytes32(uint256(4)),
            keccak256(abi.encode(address(vesting), uint256(0))),
            keccak256(abi.encode(deployer, uint256(0)))
        ];
        vm.startStateDiffRecording();
        vm.prank(deployer);
        FireToken fresh = new FireToken(address(vesting));
        Vm.AccountAccess[] memory accesses = vm.stopAndReturnStateDiff();

        uint256 writes;
        uint256 staticProbes;
        for (uint256 i; i < accesses.length; ++i) {
            Vm.AccountAccess memory access = accesses[i];
            if (access.account == VM_ADDRESS) continue; // vm.prank 호출 자체
            if (access.kind == VmSafe.AccountAccessKind.Extcodesize) {
                assertEq(access.account, address(vesting));
            } else if (access.kind == VmSafe.AccountAccessKind.StaticCall) {
                // 일정 확인용 읽기 전용 조회만 허용: vesting.start(), vesting.duration()
                assertEq(access.account, address(vesting), "constructor static-called another account");
                bytes4 selector = bytes4(access.data);
                assertTrue(
                    selector == IFireVestingSchedule.start.selector
                        || selector == IFireVestingSchedule.duration.selector,
                    "constructor static-called an unexpected function"
                );
                assertEq(access.data.length, 4, "schedule probe carries no arguments");
                staticProbes++;
            } else {
                assertTrue(
                    access.kind == VmSafe.AccountAccessKind.Create || access.kind == VmSafe.AccountAccessKind.Resume,
                    "constructor made an external call"
                );
                assertEq(access.account, address(fresh));
            }
            for (uint256 j; j < access.storageAccesses.length; ++j) {
                Vm.StorageAccess memory slotAccess = access.storageAccesses[j];
                if (!slotAccess.isWrite) continue;
                assertEq(slotAccess.account, address(fresh), "constructor wrote another account's storage");
                bool expected;
                for (uint256 k; k < expectedSlots.length; ++k) {
                    if (slotAccess.slot == expectedSlots[k]) expected = true;
                }
                assertTrue(expected, string.concat("unexpected storage write: ", vm.toString(slotAccess.slot)));
                writes++;
            }
        }
        assertEq(writes, 6); // _totalSupply 는 발행마다 한 번씩 두 번
        assertEq(staticProbes, 2); // start(), duration() 각 1회

        assertEq(uint256(vm.load(address(fresh), expectedSlots[0])), TOTAL_SUPPLY);
        assertEq(vm.load(address(fresh), expectedSlots[1]), bytes32(abi.encodePacked("Fire", bytes27(0), uint8(8))));
        assertEq(vm.load(address(fresh), expectedSlots[2]), bytes32(abi.encodePacked("FIRE", bytes27(0), uint8(8))));
        assertEq(uint256(vm.load(address(fresh), expectedSlots[3])), VESTING_SUPPLY);
        assertEq(uint256(vm.load(address(fresh), expectedSlots[4])), DEPLOYER_SUPPLY);
    }

    function testFuzz_Constructor_MintsDeployerShareToMsgSender(address someDeployer) public {
        vm.assume(someDeployer != address(0) && someDeployer != address(vesting));
        vm.prank(someDeployer);
        FireToken fresh = new FireToken(address(vesting));

        assertEq(fresh.balanceOf(someDeployer), DEPLOYER_SUPPLY);
        assertEq(fresh.balanceOf(address(vesting)), VESTING_SUPPLY);
        assertEq(fresh.totalSupply(), TOTAL_SUPPLY);
    }

    // ─────────────────────────────────────────────────────────────
    // 생성자 입력 검증 (vesting 주소)
    // ─────────────────────────────────────────────────────────────

    function test_RevertWhen_VestingIsZeroAddress() public {
        vm.expectRevert(bytes(NOT_CONTRACT_REASON));
        vm.prank(deployer);
        new FireToken(address(0));
    }

    /// @dev 가장 흔한 실수: vesting 자리에 수익자 지갑이나 배포자 지갑(EOA) 주소를 입력.
    function test_RevertWhen_VestingIsEoa() public {
        vm.expectRevert(bytes(NOT_CONTRACT_REASON));
        vm.prank(deployer);
        new FireToken(beneficiary);

        vm.expectRevert(bytes(NOT_CONTRACT_REASON));
        vm.prank(deployer);
        new FireToken(deployer);

        // 프리컴파일(ecrecover)도 코드 길이가 0이므로 거부
        vm.expectRevert(bytes(NOT_CONTRACT_REASON));
        vm.prank(deployer);
        new FireToken(address(1));
    }

    function testFuzz_RevertWhen_VestingHasNoCode(address eoa) public {
        vm.assume(eoa.code.length == 0);
        vm.expectRevert(bytes(NOT_CONTRACT_REASON));
        vm.prank(deployer);
        new FireToken(eoa);
    }

    /// @dev [회귀] EIP-7702로 위임된 EOA는 `0xef0100 || 구현주소`(23바이트) 코드를 가지므로 코드 길이 검사만으로는 통과했다.
    ///      Base 메인넷에서도 흔하다 (예: 0x44Aa5BBdCA392092a4B83EbDD8cC0b242834284F 의 코드
    ///      = 0xef010069007702764179f14f51cdce752f4f775d74e139, 2026-10-08 cast code로 확인).
    ///      이제 생성자가 start()·duration()을 조회하므로, 일정 조회에 응답하지 않는 스마트 계정은 배포 자체가 실패한다.
    function test_RevertWhen_VestingIsEip7702DelegatedEoa() public {
        vm.setEvmVersion("prague");
        (address smartEoa, uint256 smartEoaKey) = makeAddrAndKey("smartEoa");
        CoreDelegateImpl impl = new CoreDelegateImpl();
        vm.signAndAttachDelegation(address(impl), smartEoaKey);
        assertEq(smartEoa.code, abi.encodePacked(hex"ef0100", address(impl)));
        assertEq(smartEoa.code.length, 23);

        vm.expectRevert();
        vm.prank(deployer);
        new FireToken(smartEoa);
    }

    /// @dev [회귀] 코드가 있는 임의의 주소(수익자/트레저리 Safe, 토큰을 옮길 수 없는 컨트랙트)를 넣으면 이전에는 2억 개가
    ///      잠기지 않은 채 발행되거나 영구 동결됐다. 이제 일정 조회에 응답하지 않으므로 배포가 실패한다.
    function test_RevertWhen_VestingIsArbitraryContract() public {
        CoreMultisigLike beneficiarySafe = new CoreMultisigLike(beneficiary);
        vm.expectRevert();
        vm.prank(deployer);
        new FireToken(address(beneficiarySafe));

        CoreArbitraryContract sink = new CoreArbitraryContract();
        vm.expectRevert();
        vm.prank(deployer);
        new FireToken(address(sink));
    }

    /// @dev 해제가 이미 시작된 베스팅(클리프 0으로 배포 후 시간이 흐름)이나 해제 기간 0인 베스팅에는 발행하지 않는다.
    function test_RevertWhen_VestingScheduleAlreadyStartedOrZeroDuration() public {
        vm.prank(deployer);
        FireVesting noCliff = new FireVesting(beneficiary, 0, LINEAR_SECONDS);
        vm.warp(block.timestamp + 1);
        vm.expectRevert(bytes("FireToken: vesting schedule must not have started"));
        vm.prank(deployer);
        new FireToken(address(noCliff));

        vm.prank(deployer);
        FireVesting zeroDuration = new FireVesting(beneficiary, CLIFF_SECONDS, 0);
        vm.expectRevert(bytes("FireToken: vesting schedule must not have started"));
        vm.prank(deployer);
        new FireToken(address(zeroDuration));
    }

    /// @dev 경계: 같은 블록에서 클리프 0으로 배포한 베스팅은 start() == 현재 시각이므로 허용된다 (해제량 0).
    function test_VestingStartingNow_IsAccepted() public {
        vm.prank(deployer);
        FireVesting startsNow = new FireVesting(beneficiary, 0, LINEAR_SECONDS);
        assertEq(startsNow.start(), block.timestamp);
        vm.prank(deployer);
        FireToken fresh = new FireToken(address(startsNow));
        assertEq(fresh.balanceOf(address(startsNow)), VESTING_SUPPLY);
        assertEq(startsNow.releasable(address(fresh)), 0);
    }

    /// @dev [PoC] 8억 개는 생성자의 msg.sender에게 발행된다. CREATE2 팩토리를 거쳐 배포하면(예: forge script 안의
    ///      `new FireToken{salt: s}(vesting)`은 0x4e59b448…956C 팩토리를 경유) 8억 개가 팩토리 주소에 발행되어 영구 동결된다.
    ///      이 팩토리는 Base 메인넷·Base Sepolia에 동일 바이트코드로 존재한다 (2026-10-08 cast code로 확인).
    function test_PoC_Create2FactoryDeploymentStrandsDeployerShare() public {
        assertGt(CREATE2_FACTORY.code.length, 0);
        bytes32 salt = keccak256("FIRE");
        bytes memory initCode = abi.encodePacked(type(FireToken).creationCode, abi.encode(address(vesting)));

        vm.prank(deployer);
        (bool ok, bytes memory ret) = CREATE2_FACTORY.call(abi.encodePacked(salt, initCode));
        assertTrue(ok);
        FireToken viaFactory = FireToken(address(bytes20(ret)));
        assertEq(address(viaFactory), vm.computeCreate2Address(salt, keccak256(initCode), CREATE2_FACTORY));

        assertEq(viaFactory.balanceOf(CREATE2_FACTORY), DEPLOYER_SUPPLY); // 회수 불가
        assertEq(viaFactory.balanceOf(deployer), 0);
        assertEq(viaFactory.balanceOf(address(vesting)), VESTING_SUPPLY);
    }

    /// @dev 손실 여부는 "생성자를 실행한 msg.sender 가 토큰을 옮길 수 있는가"로 갈린다.
    ///      Safe 가 CreateCall 을 DELEGATECALL(operation=1)로 실행하면 생성자의 msg.sender 는 Safe 자신이므로 8억 개를
    ///      Safe 가 받고 서명으로 옮길 수 있다 (손실 아님, 다만 배포자 지갑 수령이라는 계획과 다름). CREATE2 경로도 같다.
    ///      같은 라이브러리를 일반 CALL 로 부르면 라이브러리가 생성자가 되어 8억 개가 동결된다 (CREATE2 팩토리와 같은 경우).
    function test_SafeCreateCall_DelegatecallMintsToSafeButCallStrands() public {
        address signer = makeAddr("safeSigner");
        CoreMultisigLike safe = new CoreMultisigLike(signer);
        CoreCreateCallLike createCall = new CoreCreateCallLike();
        bytes memory initCode = abi.encodePacked(type(FireToken).creationCode, abi.encode(address(vesting)));

        vm.prank(signer);
        bytes memory ret =
            safe.executeDelegate(address(createCall), abi.encodeCall(CoreCreateCallLike.performCreate, (initCode)));
        FireToken viaDelegatecall = FireToken(abi.decode(ret, (address)));
        assertEq(viaDelegatecall.balanceOf(address(safe)), DEPLOYER_SUPPLY);
        assertEq(viaDelegatecall.balanceOf(address(createCall)), 0);
        vm.prank(signer);
        safe.execute(address(viaDelegatecall), abi.encodeCall(IERC20.transfer, (deployer, DEPLOYER_SUPPLY)));
        assertEq(viaDelegatecall.balanceOf(deployer), DEPLOYER_SUPPLY); // Safe 서명으로 회수 가능

        vm.prank(signer);
        ret = safe.executeDelegate(
            address(createCall), abi.encodeCall(CoreCreateCallLike.performCreate2, (initCode, keccak256("FIRE")))
        );
        FireToken viaDelegatecall2 = FireToken(abi.decode(ret, (address)));
        assertEq(viaDelegatecall2.balanceOf(address(safe)), DEPLOYER_SUPPLY);
        assertEq(viaDelegatecall2.balanceOf(address(createCall)), 0);

        vm.prank(signer);
        ret = safe.execute(address(createCall), abi.encodeCall(CoreCreateCallLike.performCreate, (initCode)));
        FireToken viaCall = FireToken(abi.decode(ret, (address)));
        assertEq(viaCall.balanceOf(address(createCall)), DEPLOYER_SUPPLY); // 옮길 함수가 없어 동결
        assertEq(viaCall.balanceOf(address(safe)), 0);
    }

    // ─────────────────────────────────────────────────────────────
    // 관리자 권한 부재
    // ─────────────────────────────────────────────────────────────

    /// @dev 흔한 관리자 함수 이름(차단 목록)을 호출하면 배포자·베스팅 컨트랙트·수익자 등 "권한이 있을 법한" 호출자 모두
    ///      빈 revert 데이터로 실패한다. 읽기 쉬운 문서용 검사이며, 이름이 다르거나 특정 주소만 부를 수 있는 함수는 잡지 못한다.
    ///      "이 17개 외에 함수가 없다"는 증명은 test_ExternalSelectorSetIsExact 와 test_Bytecode_MatchesPinnedBuild 가 담당.
    function test_NoPrivilegedFunctions() public {
        bytes[] memory calls = new bytes[](12);
        calls[0] = abi.encodeWithSignature("mint(address,uint256)", deployer, 1e18);
        calls[1] = abi.encodeWithSignature("owner()");
        calls[2] = abi.encodeWithSignature("pause()");
        calls[3] = abi.encodeWithSignature("transferOwnership(address)", bob);
        calls[4] = abi.encodeWithSignature("renounceOwnership()");
        calls[5] = abi.encodeWithSignature("unpause()");
        calls[6] = abi.encodeWithSignature("mint(uint256)", 1e18);
        calls[7] = abi.encodeWithSignature("burn(address,uint256)", deployer, 1e18);
        calls[8] = abi.encodeWithSignature("blacklist(address)", bob);
        calls[9] = abi.encodeWithSignature("acceptOwnership()");
        calls[10] = abi.encodeWithSignature("pendingOwner()");
        calls[11] = abi.encodeWithSignature("upgradeToAndCall(address,bytes)", bob, "");

        address[3] memory callers = [deployer, address(vesting), beneficiary];
        for (uint256 c; c < callers.length; ++c) {
            for (uint256 i; i < calls.length; ++i) {
                vm.prank(callers[c]);
                (bool ok, bytes memory ret) = address(token).call(calls[i]);
                assertFalse(ok);
                assertEq(ret.length, 0);
            }
        }

        assertEq(token.totalSupply(), TOTAL_SUPPLY);
        assertEq(token.balanceOf(deployer), DEPLOYER_SUPPLY);
        assertEq(token.balanceOf(address(vesting)), VESTING_SUPPLY);
    }

    function test_NoOwnerGetter() public view {
        (bool ok,) = address(token).staticcall(abi.encodeWithSignature("owner()"));
        assertFalse(ok);
    }

    /// @dev fallback/receive 부재 확인: 알려진 17개 이외의 셀렉터로 호출하면 누가 호출하든 빈 revert 데이터로 실패하고
    ///      총공급이 바뀌지 않는다. 무작위 셀렉터는 숨은 함수를 거의 맞히지 못하고, 숨은 함수도 권한 없는 호출에는 빈 revert 를
    ///      낼 수 있으므로(test_SelectorPin_FlagsGatedHiddenMint) 함수 집합 자체는 test_ExternalSelectorSetIsExact 가 고정한다.
    function testFuzz_UnknownSelectorsRevert(address caller, bytes4 selector, bytes calldata args) public {
        vm.assume(!_isKnownSelector(selector));
        vm.prank(caller);
        (bool ok, bytes memory ret) = address(token).call(abi.encodePacked(selector, args));
        assertFalse(ok);
        assertEq(ret.length, 0);
        assertEq(token.totalSupply(), TOTAL_SUPPLY);
    }

    /// @dev 런타임 코드 디스패처에서 추출한 외부 함수 셀렉터 집합이 아래 17개 서명과 정확히 같다
    ///      (ERC20 9 + Burnable 2 + Permit 3 + EIP-5267 1 + 상수 2). 이름·호출 권한과 무관하게 함수가 하나라도 추가·삭제되면 실패.
    ///      기대값은 컨트랙트가 아니라 함수 서명 문자열에서 독립적으로 계산한다.
    function test_ExternalSelectorSetIsExact() public view {
        bytes4[] memory found = CoreBytecode.dispatcherSelectors(address(token).code);
        assertEq(CoreBytecode.difference(found, _knownSelectors()), "", "FireToken external function set changed");
        assertEq(found.length, 17);
    }

    /// @dev 고정 소스의 생성 코드(생성자 포함)와 런타임 코드를 해시로 고정한다. 외부 함수 집합을 바꾸지 않는 내부 로직 변경
    ///      (예: 특정 spender 의 allowance 검사 생략, 특정 조건의 전송 차단)과 생성자만 바꾼 변경(예: 이벤트 없는 승인)까지 드러낸다.
    ///      주석·NatSpec 변경은 메타데이터에만 반영되므로 영향 없음. solc·OpenZeppelin·최적화 설정을 의도적으로 바꾼 경우에만
    ///      검토 후 상수를 갱신한다. forge coverage 는 최적화를 끈 별도 빌드이므로 건너뛴다(셀렉터 집합 고정은 coverage 에서도 실행).
    function test_Bytecode_MatchesPinnedBuild() public {
        vm.skip(vm.isContext(VmSafe.ForgeContext.Coverage), "forge coverage compiles without the optimizer");
        assertEq(
            CoreBytecode.executableCodeHash(type(FireToken).creationCode),
            FIRE_TOKEN_CREATION_CODE_HASH,
            "FireToken creation code differs from the pinned build (src/, lib/openzeppelin-contracts or compiler settings changed)"
        );
        FireToken pinned = _deployAtCodePinAddress();
        assertEq(
            CoreBytecode.executableCodeHash(address(pinned).code),
            FIRE_TOKEN_RUNTIME_CODE_HASH,
            "FireToken runtime code differs from the pinned build (src/, lib/openzeppelin-contracts or compiler settings changed)"
        );
    }

    /// @dev [회귀] 지정 주소만 부를 수 있는 숨은 mint: 배포자 호출은 "없는 셀렉터"와 똑같이 빈 revert 데이터로 실패하므로
    ///      차단 목록·무작위 셀렉터 검사로는 드러나지 않지만, 셀렉터 집합 고정에서는 예상 밖 셀렉터로 드러난다.
    function test_SelectorPin_FlagsGatedHiddenMint() public {
        address backdoor = makeAddr("backdoor");
        vm.prank(deployer);
        CoreTokenWithGatedMint mutant = new CoreTokenWithGatedMint(address(vesting), backdoor);
        bytes memory mintCall = abi.encodeCall(CoreTokenWithGatedMint.coreGatedMint, (backdoor, TOTAL_SUPPLY));

        vm.prank(deployer);
        (bool ok, bytes memory ret) = address(mutant).call(mintCall);
        assertFalse(ok);
        assertEq(ret.length, 0);

        vm.prank(backdoor);
        (ok,) = address(mutant).call(mintCall);
        assertTrue(ok);
        assertEq(mutant.totalSupply(), 2 * TOTAL_SUPPLY);

        bytes4[] memory found = CoreBytecode.dispatcherSelectors(address(mutant).code);
        assertTrue(CoreBytecode.contains(found, CoreTokenWithGatedMint.coreGatedMint.selector));
        assertEq(
            CoreBytecode.difference(found, _knownSelectors()),
            string.concat(
                "unexpected external selector ", CoreBytecode.toHex(CoreTokenWithGatedMint.coreGatedMint.selector)
            )
        );
    }

    /// @dev [회귀] 새 함수 없이 내부 로직만 바꾼 백도어(해시로 숨긴 spender 의 allowance 검사 생략)는 셀렉터 집합이 같아
    ///      셀렉터 고정을 통과하지만, 같은 배포 조건의 바이트코드 해시가 달라져 바이트코드 고정에서 드러난다.
    ///      영향: 그 spender 가 승인 없이 베스팅 컨트랙트의 2억을 즉시 빼낼 수 있다.
    function test_CodePin_FlagsLogicOnlyBackdoor() public {
        address attacker = makeAddr("attacker");
        bytes32 attackerHash = keccak256(abi.encodePacked(attacker));
        vm.chainId(BASE_MAINNET_CHAIN_ID);
        vm.prank(CODE_PIN_DEPLOYER);
        CoreTokenCloneWithAllowanceBypass mutant = new CoreTokenCloneWithAllowanceBypass(address(vesting), attackerHash);
        assertEq(address(mutant), vm.computeCreateAddress(CODE_PIN_DEPLOYER, 0)); // 고정 테스트와 같은 주소·체인

        assertEq(CoreBytecode.difference(CoreBytecode.dispatcherSelectors(address(mutant).code), _knownSelectors()), "");
        assertNotEq(CoreBytecode.executableCodeHash(address(mutant).code), FIRE_TOKEN_RUNTIME_CODE_HASH);
        assertNotEq(
            CoreBytecode.executableCodeHash(type(CoreTokenCloneWithAllowanceBypass).creationCode),
            FIRE_TOKEN_CREATION_CODE_HASH
        );

        vm.prank(attacker);
        assertTrue(mutant.transferFrom(address(vesting), attacker, VESTING_SUPPLY));
        assertEq(mutant.balanceOf(attacker), VESTING_SUPPLY);
        assertEq(mutant.balanceOf(address(vesting)), 0);
    }

    function test_RejectsEtherAndEmptyCalldata() public {
        vm.deal(deployer, 1 ether);
        vm.startPrank(deployer);
        (bool ok,) = address(token).call{value: 1 ether}("");
        assertFalse(ok);
        (ok,) = address(token).call("");
        assertFalse(ok);
        vm.stopPrank();
        assertEq(address(token).balance, 0);
    }

    // ─────────────────────────────────────────────────────────────
    // 소각 (burn / burnFrom)
    // ─────────────────────────────────────────────────────────────

    function test_Burn_ReducesSupplyAndBalance() public {
        uint256 amount = 1_000e18;
        vm.expectEmit(true, true, false, true, address(token));
        emit IERC20.Transfer(deployer, address(0), amount);
        vm.prank(deployer);
        token.burn(amount);

        assertEq(token.totalSupply(), TOTAL_SUPPLY - amount);
        assertEq(token.balanceOf(deployer), DEPLOYER_SUPPLY - amount);
        // TOTAL_SUPPLY 상수는 최초 발행량이며 소각 후 실제 총공급(totalSupply)과 달라진다
        assertEq(token.TOTAL_SUPPLY(), TOTAL_SUPPLY);
    }

    function test_RevertWhen_BurnExceedsBalance() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 0, 1));
        vm.prank(alice);
        token.burn(1);
    }

    /// @dev 수수료 소각 경로: 사용자가 승인한 범위 안에서 서비스(spender)가 사용자 지갑의 토큰을 직접 소각. spender는 토큰을 받지 않는다.
    function test_BurnFrom_SpendsAllowanceAndBurnsFromHolder() public {
        vm.prank(deployer);
        assertTrue(token.approve(bob, 100e18));

        vm.expectEmit(true, true, false, true, address(token));
        emit IERC20.Transfer(deployer, address(0), 60e18);
        vm.prank(bob);
        token.burnFrom(deployer, 60e18);

        assertEq(token.allowance(deployer, bob), 40e18);
        assertEq(token.totalSupply(), TOTAL_SUPPLY - 60e18);
        assertEq(token.balanceOf(deployer), DEPLOYER_SUPPLY - 60e18);
        assertEq(token.balanceOf(bob), 0);
    }

    function test_RevertWhen_BurnFromWithoutAllowance() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, bob, 0, 1));
        vm.prank(bob);
        token.burnFrom(deployer, 1);
        assertEq(token.totalSupply(), TOTAL_SUPPLY);
    }

    function test_RevertWhen_BurnFromExceedsAllowance() public {
        vm.prank(deployer);
        assertTrue(token.approve(bob, 50e18));

        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, bob, 50e18, 50e18 + 1));
        vm.prank(bob);
        token.burnFrom(deployer, 50e18 + 1);

        assertEq(token.allowance(deployer, bob), 50e18);
        assertEq(token.totalSupply(), TOTAL_SUPPLY);
    }

    function test_RevertWhen_BurnFromExceedsBalance() public {
        vm.prank(alice);
        assertTrue(token.approve(bob, type(uint256).max));

        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 0, 1));
        vm.prank(bob);
        token.burnFrom(alice, 1);
    }

    function test_BurnFrom_InfiniteAllowanceIsNotDecreased() public {
        vm.prank(deployer);
        assertTrue(token.approve(bob, type(uint256).max));
        vm.prank(bob);
        token.burnFrom(deployer, 1_000e18);

        assertEq(token.allowance(deployer, bob), type(uint256).max);
        assertEq(token.totalSupply(), TOTAL_SUPPLY - 1_000e18);
    }

    function testFuzz_Burn(uint256 amount) public {
        amount = bound(amount, 0, DEPLOYER_SUPPLY);
        vm.prank(deployer);
        token.burn(amount);

        assertEq(token.totalSupply(), TOTAL_SUPPLY - amount);
        assertEq(token.balanceOf(deployer), DEPLOYER_SUPPLY - amount);
    }

    function testFuzz_BurnFrom_RespectsAllowance(uint256 allowance, uint256 amount) public {
        allowance = bound(allowance, 0, DEPLOYER_SUPPLY);
        amount = bound(amount, 0, DEPLOYER_SUPPLY);
        vm.prank(deployer);
        assertTrue(token.approve(bob, allowance));

        if (amount > allowance) {
            vm.expectRevert(
                abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, bob, allowance, amount)
            );
            vm.prank(bob);
            token.burnFrom(deployer, amount);
            assertEq(token.totalSupply(), TOTAL_SUPPLY);
            assertEq(token.allowance(deployer, bob), allowance);
        } else {
            vm.prank(bob);
            token.burnFrom(deployer, amount);
            assertEq(token.totalSupply(), TOTAL_SUPPLY - amount);
            assertEq(token.balanceOf(deployer), DEPLOYER_SUPPLY - amount);
            assertEq(token.allowance(deployer, bob), allowance - amount);
            assertEq(token.balanceOf(bob), 0);
        }
    }

    // ─────────────────────────────────────────────────────────────
    // EIP-2612 permit / EIP-712 도메인
    // ─────────────────────────────────────────────────────────────

    function test_DomainSeparator_MatchesEip712Domain() public view {
        assertEq(token.DOMAIN_SEPARATOR(), _domainSeparator(address(token), block.chainid));

        (
            bytes1 fields,
            string memory domainName,
            string memory domainVersion,
            uint256 chainId,
            address verifyingContract,
            bytes32 salt,
            uint256[] memory extensions
        ) = token.eip712Domain();
        assertEq(uint8(fields), 0x0f);
        assertEq(domainName, "Fire");
        assertEq(domainVersion, "1");
        assertEq(chainId, block.chainid);
        assertEq(verifyingContract, address(token));
        assertEq(salt, bytes32(0));
        assertEq(extensions.length, 0);
    }

    function test_DomainSeparator_OnBaseChainIds() public {
        uint256[2] memory chainIds = [BASE_MAINNET_CHAIN_ID, BASE_SEPOLIA_CHAIN_ID];
        for (uint256 i; i < chainIds.length; ++i) {
            vm.chainId(chainIds[i]);
            FireVesting v = new FireVesting(beneficiary, CLIFF_SECONDS, LINEAR_SECONDS);
            vm.prank(deployer);
            FireToken t = new FireToken(address(v));
            assertEq(t.DOMAIN_SEPARATOR(), _domainSeparator(address(t), chainIds[i]));
        }
    }

    /// @dev 체인 ID가 바뀌면(하드포크로 체인이 갈라지는 경우) 도메인이 재계산되어 원래 체인용 서명을 재사용할 수 없다.
    function test_DomainSeparator_RebuiltWhenChainIdChanges() public {
        vm.chainId(BASE_MAINNET_CHAIN_ID);
        FireVesting v = new FireVesting(beneficiary, CLIFF_SECONDS, LINEAR_SECONDS);
        vm.prank(deployer);
        FireToken t = new FireToken(address(v));

        uint256 deadline = block.timestamp + 1 hours;
        bytes32 digest = _permitDigest(address(t), BASE_MAINNET_CHAIN_ID, alice, bob, 1e18, 0, deadline);
        (uint8 v8, bytes32 r, bytes32 s) = vm.sign(aliceKey, digest);

        uint256 forkChainId = 999_999;
        vm.chainId(forkChainId);
        assertEq(t.DOMAIN_SEPARATOR(), _domainSeparator(address(t), forkChainId));
        address recovered = ecrecover(_permitDigest(address(t), forkChainId, alice, bob, 1e18, 0, deadline), v8, r, s);
        vm.expectRevert(abi.encodeWithSelector(ERC20Permit.ERC2612InvalidSigner.selector, recovered, alice));
        t.permit(alice, bob, 1e18, deadline, v8, r, s);

        vm.chainId(BASE_MAINNET_CHAIN_ID);
        t.permit(alice, bob, 1e18, deadline, v8, r, s);
        assertEq(t.allowance(alice, bob), 1e18);
    }

    function test_Permit_SetsAllowanceAndBumpsNonce() public {
        uint256 value = 500e18;
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(aliceKey, alice, bob, value, 0, deadline);
        assertEq(token.nonces(alice), 0);

        vm.expectEmit(true, true, false, true, address(token));
        emit IERC20.Approval(alice, bob, value);
        vm.prank(bob); // 서명만 있으면 누구나(릴레이어) 제출 가능
        token.permit(alice, bob, value, deadline, v, r, s);

        assertEq(token.allowance(alice, bob), value);
        assertEq(token.nonces(alice), 1);
    }

    function test_Permit_DeadlineEqualToNowIsValid() public {
        uint256 deadline = block.timestamp;
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(aliceKey, alice, bob, 1e18, 0, deadline);
        token.permit(alice, bob, 1e18, deadline, v, r, s);
        assertEq(token.allowance(alice, bob), 1e18);
    }

    function test_RevertWhen_PermitExpired() public {
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(aliceKey, alice, bob, 1e18, 0, deadline);

        vm.warp(deadline + 1);
        vm.expectRevert(abi.encodeWithSelector(ERC20Permit.ERC2612ExpiredSignature.selector, deadline));
        token.permit(alice, bob, 1e18, deadline, v, r, s);

        assertEq(token.nonces(alice), 0);
        assertEq(token.allowance(alice, bob), 0);
    }

    function test_RevertWhen_PermitDeadlineAlreadyPast() public {
        uint256 deadline = block.timestamp - 1;
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(aliceKey, alice, bob, 1e18, 0, deadline);
        vm.expectRevert(abi.encodeWithSelector(ERC20Permit.ERC2612ExpiredSignature.selector, deadline));
        token.permit(alice, bob, 1e18, deadline, v, r, s);
    }

    function test_RevertWhen_PermitReplayed() public {
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(aliceKey, alice, bob, 1e18, 0, deadline);
        token.permit(alice, bob, 1e18, deadline, v, r, s);

        // 두 번째 제출 시 nonce=1로 해시가 달라져 엉뚱한 서명자가 복원됨
        address recovered =
            ecrecover(_permitDigest(address(token), block.chainid, alice, bob, 1e18, 1, deadline), v, r, s);
        assertTrue(recovered != alice);
        vm.expectRevert(abi.encodeWithSelector(ERC20Permit.ERC2612InvalidSigner.selector, recovered, alice));
        token.permit(alice, bob, 1e18, deadline, v, r, s);

        assertEq(token.nonces(alice), 1);
    }

    function test_RevertWhen_PermitSignedByWrongKey() public {
        (address mallory, uint256 malloryKey) = makeAddrAndKey("mallory");
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(malloryKey, alice, mallory, 1e18, 0, deadline);

        vm.expectRevert(abi.encodeWithSelector(ERC20Permit.ERC2612InvalidSigner.selector, mallory, alice));
        token.permit(alice, mallory, 1e18, deadline, v, r, s);
        assertEq(token.allowance(alice, mallory), 0);
    }

    /// @dev 서명된 필드(value / spender / deadline)를 하나라도 바꾸면 다른 서명자가 복원되어 실패.
    function test_RevertWhen_PermitFieldsTampered() public {
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(aliceKey, alice, bob, 1e18, 0, deadline);

        _expectInvalidSigner(_permitDigest(address(token), block.chainid, alice, bob, 2e18, 0, deadline), v, r, s);
        token.permit(alice, bob, 2e18, deadline, v, r, s);

        _expectInvalidSigner(_permitDigest(address(token), block.chainid, alice, deployer, 1e18, 0, deadline), v, r, s);
        token.permit(alice, deployer, 1e18, deadline, v, r, s);

        _expectInvalidSigner(_permitDigest(address(token), block.chainid, alice, bob, 1e18, 0, deadline + 1), v, r, s);
        token.permit(alice, bob, 1e18, deadline + 1, v, r, s);

        assertEq(token.nonces(alice), 0);
    }

    /// @dev s 값이 상위 절반인 가변(malleable) 서명은 ECDSA 라이브러리에서 거부.
    function test_RevertWhen_PermitSignatureIsMalleable() public {
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(aliceKey, alice, bob, 1e18, 0, deadline);
        bytes32 highS = bytes32(SECP256K1_ORDER - uint256(s));
        uint8 flippedV = v == 27 ? 28 : 27;

        vm.expectRevert(abi.encodeWithSelector(ECDSA.ECDSAInvalidSignatureS.selector, highS));
        token.permit(alice, bob, 1e18, deadline, flippedV, r, highS);
    }

    function test_RevertWhen_PermitSignatureIsGarbage() public {
        vm.expectRevert(ECDSA.ECDSAInvalidSignature.selector);
        token.permit(alice, bob, 1e18, block.timestamp, 0, bytes32(0), bytes32(0));
    }

    function testFuzz_Permit(uint256 ownerKey, address spender, uint256 value, uint256 deadline) public {
        ownerKey = bound(ownerKey, 1, SECP256K1_ORDER - 1);
        address holder = vm.addr(ownerKey);
        vm.assume(spender != address(0));
        deadline = bound(deadline, block.timestamp, type(uint256).max);
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(ownerKey, holder, spender, value, 0, deadline);

        token.permit(holder, spender, value, deadline, v, r, s);

        assertEq(token.allowance(holder, spender), value);
        assertEq(token.nonces(holder), 1);
    }

    /// @dev 가이드 1.3 "사용자 지갑에서 직접 소각" 원칙: permit 서명 + burnFrom이 한 트랜잭션에서 끝나며
    ///      서비스 컨트랙트로의 Transfer가 단 한 번도 발생하지 않는다.
    function test_PermitAndBurnFrom_SingleTxWithoutCustody() public {
        CoreFeeBurner burner = new CoreFeeBurner(token);
        vm.prank(deployer);
        assertTrue(token.transfer(alice, 1_000e18));

        uint256 fee = 10e18;
        uint256 deadline = block.timestamp + 10 minutes;
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(aliceKey, alice, address(burner), fee, 0, deadline);

        vm.recordLogs();
        vm.prank(alice);
        burner.burnFeeWithPermit(fee, deadline, v, r, s);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(logs.length, 2); // Approval(permit) + Transfer(alice → 0x0)
        assertEq(logs[0].topics[0], IERC20.Approval.selector);
        _assertTransferLog(logs[1], address(token), alice, address(0), fee);

        assertEq(token.balanceOf(alice), 990e18);
        assertEq(token.totalSupply(), TOTAL_SUPPLY - fee);
        assertEq(token.balanceOf(address(burner)), 0);
        assertEq(token.allowance(alice, address(burner)), 0);
        assertEq(token.nonces(alice), 1);
    }

    /// @dev permit 서명이 제3자에 의해 먼저 제출되어도(nonce 소진) try/catch 연동은 소각을 완료한다.
    ///      (permit을 그대로 호출하는 단순 연동이라면 test_RevertWhen_PermitReplayed와 같은 이유로 사용자 트랜잭션이 실패)
    function test_PermitFrontRun_DoesNotBlockTryCatchIntegration() public {
        CoreFeeBurner burner = new CoreFeeBurner(token);
        vm.prank(deployer);
        assertTrue(token.transfer(alice, 1_000e18));

        uint256 fee = 10e18;
        uint256 deadline = block.timestamp + 10 minutes;
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(aliceKey, alice, address(burner), fee, 0, deadline);

        vm.prank(bob);
        token.permit(alice, address(burner), fee, deadline, v, r, s);

        vm.prank(alice);
        burner.burnFeeWithPermit(fee, deadline, v, r, s);

        assertEq(token.totalSupply(), TOTAL_SUPPLY - fee);
        assertEq(token.balanceOf(alice), 990e18);
        assertEq(token.balanceOf(address(burner)), 0);
    }

    // ─────────────────────────────────────────────────────────────
    // 전송 시 총공급 보존
    // ─────────────────────────────────────────────────────────────

    function testFuzz_Transfer_PreservesTotalSupply(address to, uint256 amount) public {
        vm.assume(to != address(0));
        amount = bound(amount, 0, DEPLOYER_SUPPLY);
        uint256 toBefore = token.balanceOf(to);

        vm.prank(deployer);
        assertTrue(token.transfer(to, amount));

        assertEq(token.totalSupply(), TOTAL_SUPPLY);
        if (to == deployer) {
            assertEq(token.balanceOf(deployer), DEPLOYER_SUPPLY);
        } else {
            assertEq(token.balanceOf(deployer), DEPLOYER_SUPPLY - amount);
            assertEq(token.balanceOf(to), toBefore + amount);
        }
    }

    function testFuzz_TransferFrom_PreservesTotalSupply(address to, uint256 allowance, uint256 amount) public {
        vm.assume(to != address(0));
        allowance = bound(allowance, 0, DEPLOYER_SUPPLY);
        amount = bound(amount, 0, allowance);
        vm.prank(deployer);
        assertTrue(token.approve(bob, allowance));

        vm.prank(bob);
        assertTrue(token.transferFrom(deployer, to, amount));

        assertEq(token.totalSupply(), TOTAL_SUPPLY);
        assertEq(token.allowance(deployer, bob), allowance - amount);
    }

    /// @dev 여러 주소를 거치는 연쇄 전송 후에도 총공급과 잔고 합계가 보존된다.
    function testFuzz_TransferChain_PreservesSupplyAndSum(address a, address b, address c, uint256[4] memory amounts)
        public
    {
        address[5] memory parties = [deployer, a, b, c, address(vesting)];
        for (uint256 i; i < parties.length; ++i) {
            vm.assume(parties[i] != address(0));
            for (uint256 j = i + 1; j < parties.length; ++j) {
                vm.assume(parties[i] != parties[j]);
            }
        }

        _boundedTransfer(deployer, a, amounts[0]);
        _boundedTransfer(a, b, amounts[1]);
        _boundedTransfer(b, c, amounts[2]);
        _boundedTransfer(c, deployer, amounts[3]);

        uint256 sum;
        for (uint256 i; i < parties.length; ++i) {
            sum += token.balanceOf(parties[i]);
        }
        assertEq(sum, TOTAL_SUPPLY);
        assertEq(token.totalSupply(), TOTAL_SUPPLY);
        assertEq(token.balanceOf(address(vesting)), VESTING_SUPPLY);
    }

    /// @dev 소액 보유자 ↔ 컨트랙트 경로: 컨트랙트로 직접 전송(풀 매도·Safe·락커 예치), 컨트랙트가 승인 범위에서 끌어오기
    ///      (라우터·포지션 매니저의 transferFrom), 컨트랙트가 보유자에게 전송(매수 체결). GoPlus "Honeypot 아님"의 근거가 되는
    ///      경로이며, 배포자(대량 보유자)나 EOA 끼리의 전송만으로는 드러나지 않는 매도 차단 로직을 잡는다.
    function test_SmallHolder_TransfersWithContracts() public {
        CorePoolLike pool = new CorePoolLike();
        vm.prank(deployer);
        assertTrue(token.transfer(alice, 1_000e18));

        vm.prank(alice);
        assertTrue(token.transfer(address(pool), 400e18));
        vm.prank(alice);
        assertTrue(token.approve(address(pool), 600e18));
        pool.pull(token, alice, 600e18);
        assertEq(token.balanceOf(alice), 0);

        pool.pay(token, alice, 250e18);
        vm.prank(alice);
        assertTrue(token.transfer(bob, 50e18)); // 매수 후 다시 이동 가능

        assertEq(token.balanceOf(alice), 200e18);
        assertEq(token.balanceOf(bob), 50e18);
        assertEq(token.balanceOf(address(pool)), 750e18);
        assertEq(token.allowance(alice, address(pool)), 0);
        assertEq(token.totalSupply(), TOTAL_SUPPLY);
    }

    function testFuzz_OrdinaryHolder_TransfersWithContracts(
        uint256 holderSeed,
        uint256 balance,
        uint256 sent,
        uint256 pulled,
        uint256 paidBack
    ) public {
        address holder = address(uint160(uint256(keccak256(abi.encode("core.holder", holderSeed)))));
        vm.assume(holder != address(0) && holder.code.length == 0 && holder != deployer);
        balance = bound(balance, 1, DEPLOYER_SUPPLY);
        sent = bound(sent, 0, balance);
        pulled = bound(pulled, 0, balance - sent);
        paidBack = bound(paidBack, 0, sent + pulled);
        CorePoolLike pool = new CorePoolLike();
        vm.prank(deployer);
        assertTrue(token.transfer(holder, balance));

        vm.prank(holder);
        assertTrue(token.transfer(address(pool), sent));
        vm.prank(holder);
        assertTrue(token.approve(address(pool), pulled));
        pool.pull(token, holder, pulled);
        pool.pay(token, holder, paidBack);

        assertEq(token.balanceOf(holder), balance - sent - pulled + paidBack);
        assertEq(token.balanceOf(address(pool)), sent + pulled - paidBack);
        assertEq(token.allowance(holder, address(pool)), 0);
        assertEq(token.totalSupply(), TOTAL_SUPPLY);
    }

    function test_RevertWhen_TransferToZeroAddress() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(deployer);
        token.transfer(address(0), 1);
    }

    function test_RevertWhen_TransferExceedsBalance() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientBalance.selector, deployer, DEPLOYER_SUPPLY, DEPLOYER_SUPPLY + 1
            )
        );
        vm.prank(deployer);
        token.transfer(bob, DEPLOYER_SUPPLY + 1);
    }

    // ─────────────────────────────────────────────────────────────
    // 내부 헬퍼
    // ─────────────────────────────────────────────────────────────

    function _domainSeparator(address verifyingContract, uint256 chainId) internal pure returns (bytes32) {
        return keccak256(abi.encode(DOMAIN_TYPEHASH, keccak256("Fire"), keccak256("1"), chainId, verifyingContract));
    }

    function _permitDigest(
        address tokenAddress,
        uint256 chainId,
        address holder,
        address spender,
        uint256 value,
        uint256 nonce,
        uint256 deadline
    ) internal pure returns (bytes32) {
        bytes32 structHash = keccak256(abi.encode(PERMIT_TYPEHASH, holder, spender, value, nonce, deadline));
        return keccak256(abi.encodePacked("\x19\x01", _domainSeparator(tokenAddress, chainId), structHash));
    }

    function _signPermit(uint256 key, address holder, address spender, uint256 value, uint256 nonce, uint256 deadline)
        internal
        view
        returns (uint8 v, bytes32 r, bytes32 s)
    {
        (v, r, s) = vm.sign(key, _permitDigest(address(token), block.chainid, holder, spender, value, nonce, deadline));
    }

    /// @dev 변조된 다이제스트에서 복원될 서명자를 미리 계산해 정확한 revert 데이터를 기대값으로 설정.
    function _expectInvalidSigner(bytes32 tamperedDigest, uint8 v, bytes32 r, bytes32 s) internal {
        address recovered = ecrecover(tamperedDigest, v, r, s);
        assertTrue(recovered != address(0) && recovered != alice);
        vm.expectRevert(abi.encodeWithSelector(ERC20Permit.ERC2612InvalidSigner.selector, recovered, alice));
    }

    function _boundedTransfer(address from, address to, uint256 amount) internal {
        amount = bound(amount, 0, token.balanceOf(from));
        vm.prank(from);
        assertTrue(token.transfer(to, amount));
    }

    function _assertTransferLog(Vm.Log memory entry, address emitter, address from, address to, uint256 amount)
        internal
        pure
    {
        assertEq(entry.emitter, emitter);
        assertEq(entry.topics.length, 3);
        assertEq(entry.topics[0], IERC20.Transfer.selector);
        assertEq(entry.topics[1], bytes32(uint256(uint160(from))));
        assertEq(entry.topics[2], bytes32(uint256(uint160(to))));
        assertEq(abi.decode(entry.data, (uint256)), amount);
    }

    /// @dev FireToken 의 공개 함수 17개. 컨트랙트 인터페이스가 아니라 서명 문자열에서 독립적으로 계산한다.
    function _knownSelectors() internal pure returns (bytes4[] memory known) {
        string[17] memory signatures = [
            "name()",
            "symbol()",
            "decimals()",
            "totalSupply()",
            "balanceOf(address)",
            "transfer(address,uint256)",
            "allowance(address,address)",
            "approve(address,uint256)",
            "transferFrom(address,address,uint256)",
            "burn(uint256)",
            "burnFrom(address,uint256)",
            "permit(address,address,uint256,uint256,uint8,bytes32,bytes32)",
            "nonces(address)",
            "DOMAIN_SEPARATOR()",
            "eip712Domain()",
            "TOTAL_SUPPLY()",
            "VESTING_SUPPLY()"
        ];
        known = new bytes4[](signatures.length);
        for (uint256 i; i < signatures.length; ++i) {
            known[i] = bytes4(keccak256(bytes(signatures[i])));
        }
    }

    function _isKnownSelector(bytes4 selector) internal pure returns (bool) {
        return CoreBytecode.contains(_knownSelectors(), selector);
    }

    /// @dev 런타임 코드 고정용 결정적 배포: 체인 ID 8453, 전용 배포자의 nonce 0 → 주소·immutable 이 항상 같다.
    function _deployAtCodePinAddress() internal returns (FireToken pinned) {
        vm.chainId(BASE_MAINNET_CHAIN_ID);
        assertEq(vm.getNonce(CODE_PIN_DEPLOYER), 0);
        vm.prank(CODE_PIN_DEPLOYER);
        pinned = new FireToken(address(vesting));
        assertEq(address(pinned), vm.computeCreateAddress(CODE_PIN_DEPLOYER, 0));
    }
}
