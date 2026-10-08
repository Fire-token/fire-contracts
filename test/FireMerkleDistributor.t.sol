// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {Hashes} from "@openzeppelin/contracts/utils/cryptography/Hashes.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {FireToken} from "../src/FireToken.sol";
import {FireVesting} from "../src/FireVesting.sol";
import {FireMerkleDistributor} from "../src/FireMerkleDistributor.sol";

/**
 * @dev airdrop/fixture.mjs가 airdrop/sample.csv로 생성한 픽스처를 읽는 공통 베이스.
 *      test/fixtures/airdrop-sample.json      = generate.mjs의 merkle.json 형식
 *      test/fixtures/airdrop-sample-tree.json = generate.mjs의 tree.json 형식 (StandardMerkleTree dump)
 */
abstract contract AirdropFixture is Test {
    string internal constant AIRDROP_FIXTURE = "test/fixtures/airdrop-sample.json";
    string internal constant AIRDROP_TREE_FIXTURE = "test/fixtures/airdrop-sample-tree.json";
    uint256 internal constant AIRDROP_ALLOCATION = 50_000_000e18;

    uint256 internal fixtureRound;
    bytes32 internal fixtureRoot;
    uint256 internal fixtureTotal;
    uint256 internal fixtureCount;
    address[] internal fixtureAccounts;
    uint256[] internal fixtureAmounts;
    mapping(uint256 index => bytes32[] proof) internal fixtureProofs;

    function _loadAirdropFixture() internal {
        string memory json = vm.readFile(AIRDROP_FIXTURE);
        fixtureRound = vm.parseJsonUint(json, ".round");
        fixtureRoot = vm.parseJsonBytes32(json, ".root");
        fixtureTotal = vm.parseJsonUint(json, ".total");
        fixtureCount = vm.parseJsonUint(json, ".count");

        string[] memory keys = vm.parseJsonKeys(json, ".claims");
        for (uint256 i; i < keys.length; ++i) {
            string memory claimPath = string.concat(".claims.", keys[i]);
            fixtureAccounts.push(vm.parseAddress(keys[i]));
            fixtureAmounts.push(vm.parseJsonUint(json, string.concat(claimPath, ".amount")));
            fixtureProofs[i] = vm.parseJsonBytes32Array(json, string.concat(claimPath, ".proof"));
        }
    }

    /// @dev FIRE 배포(베스팅 → 토큰) 후 배포자 지갑에서 에어드롭 지갑으로 5,000만 FIRE 분리 (가이드 4장 Step 4)
    function _deployFireWithAirdropWallet(address deployer, address airdropWallet) internal returns (FireToken token) {
        vm.startPrank(deployer);
        FireVesting vesting = new FireVesting(makeAddr("beneficiary"), 180 days, 540 days);
        token = new FireToken(address(vesting));
        require(token.transfer(airdropWallet, AIRDROP_ALLOCATION), "transfer failed");
        vm.stopPrank();
    }

    /// @dev OpenZeppelin StandardMerkleTree ["address","uint256"] leaf (컨트랙트와 같은 계산)
    function _leaf(address account, uint256 amount) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(account, amount))));
    }
}

/// @dev 디스패처 파서 자체를 검증하는 변형: 관리자 회수 함수를 하나 더 가진 분배 컨트랙트 (선택자 0x00000000 포함).
contract AirdropMutantDistributor is FireMerkleDistributor {
    constructor(IERC20 token, bytes32 root, uint64 deadline, address sweepRecipient)
        FireMerkleDistributor(token, root, deadline, sweepRecipient)
    {}

    function rescueTokens(address to) external {
        require(TOKEN.transfer(to, TOKEN.balanceOf(address(this))), "transfer failed");
    }

    /// @dev 선택자 0x00000000 (DUP1 ISZERO 비교 경로)
    function wycpnbqcyf() external pure returns (uint256) {
        return 1;
    }
}

contract FireMerkleDistributorTest is AirdropFixture {
    uint256 internal constant CLAIM_PERIOD = 90 days;

    FireToken internal token;
    FireMerkleDistributor internal distributor;
    address internal deployer = makeAddr("deployer");
    address internal airdropWallet = makeAddr("airdropWallet");
    address internal relayer = makeAddr("relayer");
    uint64 internal deadline;

    function setUp() public {
        _loadAirdropFixture();
        token = _deployFireWithAirdropWallet(deployer, airdropWallet);
        deadline = SafeCast.toUint64(block.timestamp + CLAIM_PERIOD);
        distributor = _deployFunded(fixtureTotal);
    }

    function _deployFunded(uint256 funding) internal returns (FireMerkleDistributor d) {
        vm.startPrank(airdropWallet);
        d = new FireMerkleDistributor(token, fixtureRoot, deadline, airdropWallet);
        require(token.transfer(address(d), funding), "transfer failed");
        vm.stopPrank();
    }

    function _claim(uint256 i) internal {
        distributor.claim(fixtureAccounts[i], fixtureAmounts[i], fixtureProofs[i]);
    }

    function _proofCopy(uint256 i) internal view returns (bytes32[] memory copy) {
        bytes32[] storage proof = fixtureProofs[i];
        copy = new bytes32[](proof.length);
        for (uint256 j; j < proof.length; ++j) {
            copy[j] = proof[j];
        }
    }

    function _expectInvalidProof(address account, uint256 amount) internal {
        vm.expectRevert(
            abi.encodeWithSelector(FireMerkleDistributor.FireMerkleDistributorInvalidProof.selector, account, amount)
        );
    }

    // ───────────────────────── 픽스처: JS(OpenZeppelin merkle-tree) ↔ Solidity 호환성 ─────────────────────────

    function test_Fixture_MetadataIsConsistent() public view {
        assertEq(fixtureRound, 1);
        assertEq(fixtureCount, 9);
        assertEq(fixtureAccounts.length, fixtureCount);
        assertEq(fixtureTotal, 1000e18);

        uint256 sum;
        for (uint256 i; i < fixtureCount; ++i) {
            assertGt(fixtureAmounts[i], 0);
            assertNotEq(fixtureAccounts[i], address(0));
            if (i > 0) assertLt(uint160(fixtureAccounts[i - 1]), uint160(fixtureAccounts[i])); // 주소 오름차순·중복 없음
            sum += fixtureAmounts[i];
        }
        assertEq(sum, fixtureTotal);
    }

    function test_Fixture_CoversUnbalancedTree() public view {
        // 9개 leaf → 증명 길이가 3과 4로 섞임 (불균형 트리 경로까지 호환성 검증)
        uint256 minLength = type(uint256).max;
        uint256 maxLength;
        for (uint256 i; i < fixtureCount; ++i) {
            uint256 length = fixtureProofs[i].length;
            if (length < minLength) minLength = length;
            if (length > maxLength) maxLength = length;
        }
        assertEq(minLength, 3);
        assertEq(maxLength, 4);
    }

    function test_Fixture_EveryClaimSucceeds() public {
        for (uint256 i; i < fixtureCount; ++i) {
            address account = fixtureAccounts[i];
            assertFalse(distributor.isClaimed(account));

            vm.expectEmit(address(distributor));
            emit FireMerkleDistributor.Claimed(account, fixtureAmounts[i]);
            _claim(i);

            assertTrue(distributor.isClaimed(account));
            assertEq(token.balanceOf(account), fixtureAmounts[i]);
        }
        assertEq(token.balanceOf(address(distributor)), 0);
    }

    function test_Fixture_TreeDumpMatchesSolidityHashing() public view {
        string memory json = vm.readFile(AIRDROP_TREE_FIXTURE);
        assertEq(vm.parseJsonString(json, ".format"), "standard-v1");
        string[] memory leafEncoding = vm.parseJsonStringArray(json, ".leafEncoding");
        assertEq(leafEncoding.length, 2);
        assertEq(leafEncoding[0], "address");
        assertEq(leafEncoding[1], "uint256");

        bytes32[] memory nodes = vm.parseJsonBytes32Array(json, ".tree");
        uint256 leafCount = vm.parseJsonArrayLength(json, ".values");
        assertEq(leafCount, fixtureCount);
        assertEq(nodes.length, 2 * leafCount - 1);
        assertEq(nodes[0], fixtureRoot);

        // 모든 내부 노드 = 정렬된 자식 쌍의 keccak256 (OpenZeppelin MerkleProof와 같은 규칙)
        uint256 firstLeafIndex = nodes.length - leafCount;
        for (uint256 i; i < firstLeafIndex; ++i) {
            assertEq(nodes[i], Hashes.commutativeKeccak256(nodes[2 * i + 1], nodes[2 * i + 2]));
        }
        // 모든 leaf = Solidity로 계산한 이중 해시, merkle.json과 같은 (주소, 수량)
        for (uint256 j; j < leafCount; ++j) {
            string memory valuePath = string.concat(".values[", vm.toString(j), "]");
            address account = vm.parseJsonAddress(json, string.concat(valuePath, ".value[0]"));
            uint256 amount = vm.parseJsonUint(json, string.concat(valuePath, ".value[1]"));
            uint256 treeIndex = vm.parseJsonUint(json, string.concat(valuePath, ".treeIndex"));
            assertGe(treeIndex, firstLeafIndex);
            assertLt(treeIndex, nodes.length);
            assertEq(nodes[treeIndex], _leaf(account, amount));
            assertEq(account, fixtureAccounts[j]);
            assertEq(amount, fixtureAmounts[j]);
        }
    }

    // ───────────────────────── claim: 실패 경로 ─────────────────────────

    function test_RevertWhen_ProofTampered() public {
        bytes32[] memory proof = _proofCopy(0);
        proof[0] = proof[0] ^ bytes32(uint256(1));
        _expectInvalidProof(fixtureAccounts[0], fixtureAmounts[0]);
        distributor.claim(fixtureAccounts[0], fixtureAmounts[0], proof);
    }

    function test_RevertWhen_ProofEmpty() public {
        _expectInvalidProof(fixtureAccounts[0], fixtureAmounts[0]);
        distributor.claim(fixtureAccounts[0], fixtureAmounts[0], new bytes32[](0));
    }

    function test_RevertWhen_ProofTruncated() public {
        bytes32[] memory full = _proofCopy(0);
        bytes32[] memory proof = new bytes32[](full.length - 1);
        for (uint256 j; j < proof.length; ++j) {
            proof[j] = full[j];
        }
        _expectInvalidProof(fixtureAccounts[0], fixtureAmounts[0]);
        distributor.claim(fixtureAccounts[0], fixtureAmounts[0], proof);
    }

    function test_RevertWhen_ProofExtended() public {
        bytes32[] memory full = _proofCopy(0);
        bytes32[] memory proof = new bytes32[](full.length + 1);
        for (uint256 j; j < full.length; ++j) {
            proof[j] = full[j];
        }
        proof[full.length] = fixtureRoot;
        _expectInvalidProof(fixtureAccounts[0], fixtureAmounts[0]);
        distributor.claim(fixtureAccounts[0], fixtureAmounts[0], proof);
    }

    function test_RevertWhen_InternalNodeUsedAsProofTarget() public {
        // 증명 첫 원소(형제 leaf)를 leaf 자리에 놓는 것도 이중 해시 때문에 불가능
        bytes32[] memory proof = _proofCopy(1);
        _expectInvalidProof(fixtureAccounts[0], fixtureAmounts[0]);
        distributor.claim(fixtureAccounts[0], fixtureAmounts[0], proof);
    }

    function test_RevertWhen_AmountHigherThanListed() public {
        _expectInvalidProof(fixtureAccounts[2], fixtureAmounts[2] + 1);
        distributor.claim(fixtureAccounts[2], fixtureAmounts[2] + 1, fixtureProofs[2]);
    }

    function test_RevertWhen_AmountLowerThanListed() public {
        _expectInvalidProof(fixtureAccounts[2], fixtureAmounts[2] - 1);
        distributor.claim(fixtureAccounts[2], fixtureAmounts[2] - 1, fixtureProofs[2]);
    }

    function test_RevertWhen_WrongAccount() public {
        address attacker = makeAddr("attacker");
        _expectInvalidProof(attacker, fixtureAmounts[3]);
        vm.prank(attacker);
        distributor.claim(attacker, fixtureAmounts[3], fixtureProofs[3]);
    }

    function test_RevertWhen_OtherRecipientsProof() public {
        // 4번 수령자의 정상 (주소, 수량)에 5번 수령자의 증명을 붙이면 실패
        _expectInvalidProof(fixtureAccounts[4], fixtureAmounts[4]);
        distributor.claim(fixtureAccounts[4], fixtureAmounts[4], fixtureProofs[5]);
    }

    function test_RevertWhen_AlreadyClaimed() public {
        _claim(6);
        vm.expectRevert(
            abi.encodeWithSelector(
                FireMerkleDistributor.FireMerkleDistributorAlreadyClaimed.selector, fixtureAccounts[6]
            )
        );
        _claim(6);
        assertEq(token.balanceOf(fixtureAccounts[6]), fixtureAmounts[6]);
    }

    function test_RevertWhen_ClaimedByRelayerThenByAccount() public {
        vm.prank(relayer);
        _claim(7);
        vm.expectRevert(
            abi.encodeWithSelector(
                FireMerkleDistributor.FireMerkleDistributorAlreadyClaimed.selector, fixtureAccounts[7]
            )
        );
        vm.prank(fixtureAccounts[7]);
        _claim(7);
    }

    function test_ClaimOnBehalf_TokensGoToAccount() public {
        address account = fixtureAccounts[8];
        vm.expectEmit(address(distributor));
        emit FireMerkleDistributor.Claimed(account, fixtureAmounts[8]);
        vm.prank(relayer);
        _claim(8);

        assertEq(token.balanceOf(account), fixtureAmounts[8]);
        assertEq(token.balanceOf(relayer), 0);
        assertTrue(distributor.isClaimed(account));
    }

    /// @dev README §8: 목록에 잘못 들어간 주소(여기서는 개인 키 없는 테스트 주소)의 몫도 마감 전에 누구나 그 주소로
    ///      보내 버릴 수 있으므로, 그런 몫이 sweep으로 회수된다고 기대할 수 없음 (사양상 claim은 누구나 제출 가능)
    function test_ClaimOnBehalf_ErroneousEntryIsNotRecoverableBySweep() public {
        address unusable = fixtureAccounts[0];
        vm.prank(makeAddr("anyone"));
        _claim(0);
        assertEq(token.balanceOf(unusable), fixtureAmounts[0]);

        uint256 walletBefore = token.balanceOf(airdropWallet);
        vm.warp(uint256(deadline) + 1);
        distributor.sweep();
        assertEq(token.balanceOf(airdropWallet) - walletBefore, fixtureTotal - fixtureAmounts[0]);
    }

    function test_RevertWhen_UnderfundedClaim_StateRollsBack() public {
        FireMerkleDistributor underfunded = _deployFunded(fixtureAmounts[0] - 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientBalance.selector,
                address(underfunded),
                fixtureAmounts[0] - 1,
                fixtureAmounts[0]
            )
        );
        underfunded.claim(fixtureAccounts[0], fixtureAmounts[0], fixtureProofs[0]);
        assertFalse(underfunded.isClaimed(fixtureAccounts[0])); // 청구 기록도 함께 되돌려짐

        vm.prank(airdropWallet);
        require(token.transfer(address(underfunded), 1), "transfer failed");
        underfunded.claim(fixtureAccounts[0], fixtureAmounts[0], fixtureProofs[0]);
        assertEq(token.balanceOf(fixtureAccounts[0]), fixtureAmounts[0]);
    }

    // ───────────────────────── 기한 경계 ─────────────────────────

    function test_Claim_AtDeadline_Succeeds() public {
        vm.warp(deadline); // 기한 시각 포함
        _claim(0);
        assertEq(token.balanceOf(fixtureAccounts[0]), fixtureAmounts[0]);
    }

    function test_RevertWhen_ClaimOneSecondAfterDeadline() public {
        vm.warp(uint256(deadline) + 1);
        vm.expectRevert(
            abi.encodeWithSelector(FireMerkleDistributor.FireMerkleDistributorClaimWindowClosed.selector, deadline)
        );
        _claim(0);
    }

    function test_RevertWhen_SweepBeforeDeadline() public {
        vm.expectRevert(
            abi.encodeWithSelector(FireMerkleDistributor.FireMerkleDistributorClaimWindowOpen.selector, deadline)
        );
        distributor.sweep();
    }

    function test_RevertWhen_SweepAtDeadline() public {
        vm.warp(deadline);
        vm.expectRevert(
            abi.encodeWithSelector(FireMerkleDistributor.FireMerkleDistributorClaimWindowOpen.selector, deadline)
        );
        distributor.sweep();
    }

    // ───────────────────────── sweep ─────────────────────────

    function test_Sweep_AfterDeadline_ReturnsUnclaimedToAirdropWallet() public {
        _claim(0);
        _claim(3);
        uint256 unclaimed = fixtureTotal - fixtureAmounts[0] - fixtureAmounts[3];
        uint256 walletBefore = token.balanceOf(airdropWallet);

        vm.warp(uint256(deadline) + 1);
        vm.expectEmit(address(distributor));
        emit FireMerkleDistributor.Swept(unclaimed);
        vm.prank(makeAddr("anyone")); // 누구나 호출 가능, 수령처는 고정
        distributor.sweep();

        assertEq(token.balanceOf(address(distributor)), 0);
        assertEq(token.balanceOf(airdropWallet), walletBefore + unclaimed);
    }

    function test_RevertWhen_SweepTwice() public {
        vm.warp(uint256(deadline) + 1);
        distributor.sweep();
        vm.expectRevert(FireMerkleDistributor.FireMerkleDistributorNothingToSweep.selector);
        distributor.sweep();
    }

    function test_Sweep_AgainAfterLateDeposit() public {
        vm.warp(uint256(deadline) + 1);
        distributor.sweep();
        uint256 walletBefore = token.balanceOf(airdropWallet);

        vm.prank(deployer);
        require(token.transfer(address(distributor), 5e18), "transfer failed"); // 기한 후 잘못 입금된 FIRE
        vm.expectEmit(address(distributor));
        emit FireMerkleDistributor.Swept(5e18);
        distributor.sweep();
        assertEq(token.balanceOf(airdropWallet), walletBefore + 5e18);
    }

    function test_RevertWhen_SweepAfterEverythingClaimed() public {
        for (uint256 i; i < fixtureCount; ++i) {
            _claim(i);
        }
        vm.warp(uint256(deadline) + 1);
        vm.expectRevert(FireMerkleDistributor.FireMerkleDistributorNothingToSweep.selector);
        distributor.sweep();
    }

    function test_RevertWhen_ClaimAfterSweep() public {
        vm.warp(uint256(deadline) + 1);
        distributor.sweep();
        vm.expectRevert(
            abi.encodeWithSelector(FireMerkleDistributor.FireMerkleDistributorClaimWindowClosed.selector, deadline)
        );
        _claim(1);
    }

    // ───────────────────────── 생성자·권한 ─────────────────────────

    function test_Constructor_SetsImmutables() public view {
        assertEq(address(distributor.TOKEN()), address(token));
        assertEq(distributor.MERKLE_ROOT(), fixtureRoot);
        assertEq(distributor.CLAIM_DEADLINE(), deadline);
        assertEq(distributor.SWEEP_RECIPIENT(), airdropWallet);
    }

    function test_RevertWhen_ConstructorTokenIsZero() public {
        vm.expectRevert(
            abi.encodeWithSelector(FireMerkleDistributor.FireMerkleDistributorInvalidToken.selector, address(0))
        );
        new FireMerkleDistributor(IERC20(address(0)), fixtureRoot, deadline, airdropWallet);
    }

    function test_RevertWhen_ConstructorTokenIsNotContract() public {
        address eoa = makeAddr("eoa");
        vm.expectRevert(abi.encodeWithSelector(FireMerkleDistributor.FireMerkleDistributorInvalidToken.selector, eoa));
        new FireMerkleDistributor(IERC20(eoa), fixtureRoot, deadline, airdropWallet);
    }

    function test_RevertWhen_ConstructorRootIsZero() public {
        vm.expectRevert(FireMerkleDistributor.FireMerkleDistributorZeroMerkleRoot.selector);
        new FireMerkleDistributor(token, bytes32(0), deadline, airdropWallet);
    }

    function test_RevertWhen_ConstructorDeadlineIsNow() public {
        uint64 nowTs = SafeCast.toUint64(block.timestamp);
        vm.expectRevert(
            abi.encodeWithSelector(FireMerkleDistributor.FireMerkleDistributorInvalidClaimDeadline.selector, nowTs)
        );
        new FireMerkleDistributor(token, fixtureRoot, nowTs, airdropWallet);
    }

    function test_RevertWhen_ConstructorDeadlineInPast() public {
        vm.warp(1_800_000_000);
        uint64 past = 1_799_999_999;
        vm.expectRevert(
            abi.encodeWithSelector(FireMerkleDistributor.FireMerkleDistributorInvalidClaimDeadline.selector, past)
        );
        new FireMerkleDistributor(token, fixtureRoot, past, airdropWallet);
    }

    function test_Constructor_AcceptsDeadlineAtMaxClaimPeriod() public {
        uint64 latest = SafeCast.toUint64(block.timestamp + distributor.MAX_CLAIM_PERIOD());
        FireMerkleDistributor d = new FireMerkleDistributor(token, fixtureRoot, latest, airdropWallet);
        assertEq(d.CLAIM_DEADLINE(), latest);
        assertEq(distributor.MAX_CLAIM_PERIOD(), 365 days);
    }

    function test_RevertWhen_ConstructorDeadlineBeyondMaxClaimPeriod() public {
        uint64 tooLate = SafeCast.toUint64(block.timestamp + 365 days + 1);
        vm.expectRevert(
            abi.encodeWithSelector(FireMerkleDistributor.FireMerkleDistributorInvalidClaimDeadline.selector, tooLate)
        );
        new FireMerkleDistributor(token, fixtureRoot, tooLate, airdropWallet);
    }

    /// @dev 회귀: JS Date.now()처럼 밀리초 단위로 넣은 마감 시각(약 5만 7천 년 뒤)은 거부되어 미청구분이 잠기지 않음
    function test_RevertWhen_ConstructorDeadlineInMilliseconds() public {
        vm.warp(1_767_225_600); // 2026-01-01T00:00:00Z
        uint64 milliseconds = SafeCast.toUint64((block.timestamp + 90 days) * 1000);
        vm.expectRevert(
            abi.encodeWithSelector(
                FireMerkleDistributor.FireMerkleDistributorInvalidClaimDeadline.selector, milliseconds
            )
        );
        new FireMerkleDistributor(token, fixtureRoot, milliseconds, airdropWallet);
    }

    function test_RevertWhen_ConstructorSweepRecipientIsZero() public {
        vm.expectRevert(FireMerkleDistributor.FireMerkleDistributorZeroSweepRecipient.selector);
        new FireMerkleDistributor(token, fixtureRoot, deadline, address(0));
    }

    function test_HasNoAdminSurface() public {
        // 스모크 테스트: 흔한 관리자 함수·fallback·receive가 없음 (정확한 목록은 test_AbiSurfaceIsExactlyTheExpectedSelectors)
        bytes[5] memory calls = [
            abi.encodeWithSignature("owner()"),
            abi.encodeWithSignature("transferOwnership(address)", airdropWallet),
            abi.encodeWithSignature("setMerkleRoot(bytes32)", bytes32(uint256(1))),
            abi.encodeWithSignature("withdraw(address,uint256)", airdropWallet, 1),
            abi.encodeWithSignature("pause()")
        ];
        for (uint256 i; i < calls.length; ++i) {
            (bool ok,) = address(distributor).call(calls[i]);
            assertFalse(ok);
        }
        vm.deal(address(this), 1 ether);
        (bool sent,) = address(distributor).call{value: 1 ether}("");
        assertFalse(sent);
    }

    /**
     * @dev 회귀: 공개 함수 목록이 정확히 아래 8개인지 배포된 바이트코드의 디스패처로 확인함. 이름과 무관하게 함수가
     *      하나라도 추가되면(예: rescueTokens, updateMerkleRoot) 실패하므로, 함수를 추가하려면 이 목록을 함께 고쳐
     *      검토받아야 함. 무작위 호출 퍼즈와 test_HasNoAdminSurface가 fallback·receive 부재를 보완함.
     */
    function test_AbiSurfaceIsExactlyTheExpectedSelectors() public view {
        bytes4[] memory expected = _expectedSelectors();
        bytes4[] memory found = _dispatcherSelectors(address(distributor).code);
        assertEq(found.length, expected.length, "unexpected number of external functions");
        for (uint256 i; i < found.length; ++i) {
            assertTrue(_contains(expected, found[i]), "unexpected external function selector");
            assertTrue(_contains(found, expected[i]), "expected selector missing from dispatcher");
        }
    }

    /// @dev 파서가 실제로 함수 추가를 잡아내는지 (레거시·via-IR 모두): 회수 함수와 선택자 0x00000000 함수를 찾아냄.
    function test_DispatcherParserFindsAddedFunctions() public {
        AirdropMutantDistributor mutant = new AirdropMutantDistributor(token, fixtureRoot, deadline, airdropWallet);
        bytes4[] memory found = _dispatcherSelectors(address(mutant).code);
        assertEq(found.length, 10);
        assertTrue(_contains(found, AirdropMutantDistributor.rescueTokens.selector));
        assertTrue(_contains(found, bytes4(0)));
        assertEq(AirdropMutantDistributor.wycpnbqcyf.selector, bytes4(0));
        bytes4[] memory expected = _expectedSelectors();
        for (uint256 i; i < expected.length; ++i) {
            assertTrue(_contains(found, expected[i]));
        }
    }

    /// @dev 목록에 없는 선택자 호출은 모두 실패하고 잔액·청구 상태를 바꾸지 않음 (fallback·receive 없음)
    function testFuzz_UnknownSelectorsRevertWithoutEffects(bytes4 selector, bytes calldata args) public {
        vm.assume(!_contains(_expectedSelectors(), selector));
        (bool ok,) = address(distributor).call(bytes.concat(selector, args));
        assertFalse(ok);
        assertEq(token.balanceOf(address(distributor)), fixtureTotal);
        for (uint256 i; i < fixtureCount; ++i) {
            assertFalse(distributor.isClaimed(fixtureAccounts[i]));
        }
    }

    function _expectedSelectors() internal view returns (bytes4[] memory selectors) {
        selectors = new bytes4[](8);
        selectors[0] = distributor.claim.selector;
        selectors[1] = distributor.sweep.selector;
        selectors[2] = distributor.isClaimed.selector;
        selectors[3] = distributor.TOKEN.selector;
        selectors[4] = distributor.MERKLE_ROOT.selector;
        selectors[5] = distributor.CLAIM_DEADLINE.selector;
        selectors[6] = distributor.SWEEP_RECIPIENT.selector;
        selectors[7] = distributor.MAX_CLAIM_PERIOD.selector;
    }

    /**
     * @dev solc 디스패처의 선택자 비교를 모두 찾음 (레거시 파이프라인과 via-IR 모두):
     *      - 레거시: `DUP1 PUSHn <선택자> EQ PUSHm <함수 진입점> JUMPI` (선택자 0은 `DUP1 ISZERO PUSHm t JUMPI`,
     *        via-IR 최적화는 `DUP2 ISZERO …`)
     *      - via-IR: 위와 같은 EQ 비교 + 마지막 함수만 `PUSHn <선택자> SUB PUSHm <fallback> JUMPI`(일치하지 않으면 분기),
     *        최적화 시 `PUSHn <선택자> DUP2 EQ …` 형태도 씀 (forge coverage --ir-minimum이 via-IR로 빌드함)
     *      - 선택자 앞자리가 0이면 solc가 짧은 PUSH를 씀 (예: 0x00ae3bf8 → PUSH3, 0x00000000 → PUSH0 또는 ISZERO)
     *      - 검사 구간: 선택자를 읽는 첫 CALLDATALOAD 직후 ~ 가장 앞선 함수 진입점(EQ 분기 목적지) 직전.
     *        함수 본문의 상수 비교(예: PUSH1 0x01 EQ)는 이 구간 밖이라 오탐하지 않음
     *      - PUSH 데이터(immutable 값 포함)는 명령어 단위로 건너뜀
     */
    function _dispatcherSelectors(bytes memory code) internal pure returns (bytes4[] memory selectors) {
        uint256 i = _afterSelectorLoad(code);
        uint256 end = code.length;
        bytes4[] memory found = new bytes4[](64);
        uint256 count;
        while (i < end) {
            (bool matched, bytes4 selector, uint256 target, bool entry) = _matchSelectorComparison(code, i);
            if (matched) {
                found[count++] = selector;
                if (entry && target < end) end = target;
            }
            i += _instructionLength(uint8(code[i]));
        }
        selectors = new bytes4[](count);
        for (uint256 j; j < count; ++j) {
            selectors[j] = found[j];
        }
    }

    /**
     * @dev code[i..]가 선택자 비교면 (true, 선택자, 분기 목적지, 목적지가 함수 진입점인지):
     *      `DUP1|DUP2 ISZERO PUSHm t JUMPI`(선택자 0, 진입점), `PUSHn x EQ PUSHm t JUMPI`, `PUSHn x DUP2 EQ PUSHm t JUMPI`
     *      (n = 0..4, 진입점), `PUSHn x SUB PUSHm t JUMPI`(via-IR 마지막 비교, 목적지는 fallback).
     */
    function _matchSelectorComparison(bytes memory code, uint256 i)
        internal
        pure
        returns (bool matched, bytes4 selector, uint256 target, bool entry)
    {
        if (i + 1 >= code.length) return (false, 0, 0, false);
        uint8 op = uint8(code[i]);
        uint256 j;
        if ((op == 0x80 || op == 0x81) && uint8(code[i + 1]) == 0x15) {
            (j, entry) = (i + 2, true); // DUP1/DUP2 ISZERO: 선택자 0x00000000 (via-IR 최적화는 DUP2)
        } else if (op >= 0x5f && op <= 0x63) {
            uint256 n = op - 0x5f; // PUSH0 ~ PUSH4
            uint256 k = i + 1 + n;
            if (k + 1 >= code.length) return (false, 0, 0, false);
            uint256 value;
            for (uint256 b; b < n; ++b) {
                value = (value << 8) | uint8(code[i + 1 + b]);
            }
            selector = bytes4(uint32(value));
            uint8 next = uint8(code[k]);
            if (next == 0x14) {
                (j, entry) = (k + 1, true); // EQ
            } else if (next == 0x81 && uint8(code[k + 1]) == 0x14) {
                (j, entry) = (k + 2, true); // DUP2 EQ
            } else if (next == 0x03) {
                j = k + 1; // SUB: 일치하지 않으면 분기 (via-IR)
            } else {
                return (false, 0, 0, false);
            }
        } else {
            return (false, 0, 0, false);
        }
        if (j + 1 >= code.length) return (false, 0, 0, false);
        uint8 tagPush = uint8(code[j]);
        if (tagPush != 0x60 && tagPush != 0x61) return (false, 0, 0, false); // PUSH1 / PUSH2
        uint256 m = tagPush - 0x5f;
        if (j + 1 + m >= code.length || uint8(code[j + 1 + m]) != 0x57) return (false, 0, 0, false); // JUMPI
        for (uint256 b; b < m; ++b) {
            target = (target << 8) | uint8(code[j + 1 + b]);
        }
        matched = true;
    }

    /// @dev 선택자를 읽는 첫 CALLDATALOAD 바로 다음 위치 (명령어 경계 기준). 레거시는 바로 뒤에 `PUSH1 0xe0 SHR`가 오고,
    ///      via-IR은 같은 연산을 서브루틴으로 호출함.
    function _afterSelectorLoad(bytes memory code) internal pure returns (uint256) {
        for (uint256 i; i < code.length; i += _instructionLength(uint8(code[i]))) {
            if (uint8(code[i]) == 0x35) return i + 1;
        }
        revert("selector load (CALLDATALOAD) not found");
    }

    function _instructionLength(uint8 op) internal pure returns (uint256) {
        return (op >= 0x60 && op <= 0x7f) ? uint256(op) - 0x5e : 1; // PUSHn은 1 + n바이트
    }

    function _contains(bytes4[] memory list, bytes4 value) internal pure returns (bool) {
        for (uint256 i; i < list.length; ++i) {
            if (list[i] == value) return true;
        }
        return false;
    }

    function test_Claim_GasWithinBudget() public {
        uint256 deepest;
        for (uint256 i; i < fixtureCount; ++i) {
            if (fixtureProofs[i].length > fixtureProofs[deepest].length) deepest = i;
        }
        uint256 gasBefore = gasleft();
        _claim(deepest);
        uint256 used = gasBefore - gasleft();
        assertLt(used, 120_000); // 증명 길이 4 기준. 16,777,216 tx 가스 상한과는 무관한 수준
    }

    // ───────────────────────── 퍼즈 ─────────────────────────

    function testFuzz_RevertWhen_ForgedLeafWithFixtureProof(address account, uint256 amount, uint256 seed) public {
        uint256 i = _bound(seed, 0, fixtureCount - 1);
        vm.assume(account != fixtureAccounts[i] || amount != fixtureAmounts[i]);
        _expectInvalidProof(account, amount);
        distributor.claim(account, amount, fixtureProofs[i]);
    }

    function testFuzz_RevertWhen_RandomProof(uint256 seed, bytes32[] calldata proof) public {
        uint256 i = _bound(seed, 0, fixtureCount - 1);
        vm.assume(keccak256(abi.encode(proof)) != keccak256(abi.encode(fixtureProofs[i])));
        _expectInvalidProof(fixtureAccounts[i], fixtureAmounts[i]);
        distributor.claim(fixtureAccounts[i], fixtureAmounts[i], proof);
    }

    function testFuzz_ClaimOnBehalf_AlwaysPaysListedAccount(address caller, uint256 seed) public {
        uint256 i = _bound(seed, 0, fixtureCount - 1);
        address account = fixtureAccounts[i];
        vm.assume(caller != account && caller != address(distributor));
        uint256 callerBefore = token.balanceOf(caller);

        vm.prank(caller);
        _claim(i);

        assertEq(token.balanceOf(account), fixtureAmounts[i]);
        assertEq(token.balanceOf(caller), callerBefore);
        assertEq(token.balanceOf(address(distributor)), fixtureTotal - fixtureAmounts[i]);
    }

    function testFuzz_ClaimAndSweepWindowsAreComplementary(uint256 timestamp, uint256 seed) public {
        timestamp = _bound(timestamp, block.timestamp, uint256(deadline) + 3 * 365 days);
        uint256 i = _bound(seed, 0, fixtureCount - 1);
        vm.warp(timestamp);

        if (timestamp <= deadline) {
            _claim(i);
            assertEq(token.balanceOf(fixtureAccounts[i]), fixtureAmounts[i]);
            vm.expectRevert(
                abi.encodeWithSelector(FireMerkleDistributor.FireMerkleDistributorClaimWindowOpen.selector, deadline)
            );
            distributor.sweep();
        } else {
            vm.expectRevert(
                abi.encodeWithSelector(FireMerkleDistributor.FireMerkleDistributorClaimWindowClosed.selector, deadline)
            );
            _claim(i);
            distributor.sweep();
            assertEq(token.balanceOf(address(distributor)), 0);
        }
    }

    /// @dev 성질: 임의의 수령자 부분집합이 청구한 뒤 totalClaimed + 잔액 == 예치량, sweep 후 미청구분 전액 회수
    function testFuzz_ClaimSubset_TotalClaimedPlusBalanceEqualsFunded(uint256 mask) public {
        uint256 totalClaimed;
        for (uint256 i; i < fixtureCount; ++i) {
            if ((mask >> i) & 1 == 1) {
                _claim(i);
                totalClaimed += fixtureAmounts[i];
            }
        }
        assertEq(totalClaimed + token.balanceOf(address(distributor)), fixtureTotal);

        uint256 walletBefore = token.balanceOf(airdropWallet);
        vm.warp(uint256(deadline) + 1);
        if (totalClaimed == fixtureTotal) {
            vm.expectRevert(FireMerkleDistributor.FireMerkleDistributorNothingToSweep.selector);
            distributor.sweep();
        } else {
            distributor.sweep();
        }
        assertEq(token.balanceOf(airdropWallet), walletBefore + fixtureTotal - totalClaimed);
        assertEq(token.balanceOf(address(distributor)), 0);
    }

    function testFuzz_Constructor_DeadlineMustBeWithinClaimWindow(uint64 claimDeadline) public {
        if (claimDeadline <= block.timestamp || claimDeadline > block.timestamp + 365 days) {
            vm.expectRevert(
                abi.encodeWithSelector(
                    FireMerkleDistributor.FireMerkleDistributorInvalidClaimDeadline.selector, claimDeadline
                )
            );
            new FireMerkleDistributor(token, fixtureRoot, claimDeadline, airdropWallet);
        } else {
            FireMerkleDistributor d = new FireMerkleDistributor(token, fixtureRoot, claimDeadline, airdropWallet);
            assertEq(d.CLAIM_DEADLINE(), claimDeadline);
        }
    }

    /// @dev 허용 구간 (now, now + 365일]의 양쪽 경계 부근을 집중적으로 퍼즈
    function testFuzz_Constructor_DeadlineWindowBoundaries(uint256 startTime, uint256 offset) public {
        startTime = _bound(startTime, 1, 4_000_000_000);
        vm.warp(startTime);
        uint64 claimDeadline = SafeCast.toUint64(_bound(offset, 0, 366 days) + startTime - 1);
        bool valid = claimDeadline > startTime && claimDeadline <= startTime + 365 days;
        if (!valid) {
            vm.expectRevert(
                abi.encodeWithSelector(
                    FireMerkleDistributor.FireMerkleDistributorInvalidClaimDeadline.selector, claimDeadline
                )
            );
        }
        FireMerkleDistributor d = new FireMerkleDistributor(token, fixtureRoot, claimDeadline, airdropWallet);
        if (valid) assertEq(d.CLAIM_DEADLINE(), claimDeadline);
    }
}

/**
 * @dev 불변식 테스트용 핸들러. 결과를 미리 예측하고(성공 또는 정확한 오류) 그대로 일어나는지 확인하므로,
 *      예측과 다른 revert가 나면 fail-on-revert 설정에 의해 불변식 테스트가 실패함.
 */
contract AirdropClaimHandler is Test {
    FireMerkleDistributor internal distributor;
    IERC20 internal token;
    address internal donor;
    uint64 internal deadline;
    address[] internal accounts;
    uint256[] internal amounts;
    mapping(uint256 index => bytes32[] proof) internal proofs;

    uint256 public ghostClaimed;
    uint256 public ghostSwept;
    uint256 public ghostDonated;
    uint256 public ghostClaimCount;
    uint256 public ghostSweepCount;

    constructor(FireMerkleDistributor distributor_, address donor_) {
        distributor = distributor_;
        token = distributor_.TOKEN();
        donor = donor_;
        deadline = distributor_.CLAIM_DEADLINE();
    }

    function addRecipient(address account, uint256 amount, bytes32[] calldata proof) external {
        proofs[accounts.length] = proof;
        accounts.push(account);
        amounts.push(amount);
    }

    function claim(uint256 seed, address caller) external {
        uint256 i = _bound(seed, 0, accounts.length - 1);
        address account = accounts[i];
        bool success;
        if (block.timestamp > deadline) {
            vm.expectRevert(
                abi.encodeWithSelector(FireMerkleDistributor.FireMerkleDistributorClaimWindowClosed.selector, deadline)
            );
        } else if (distributor.isClaimed(account)) {
            vm.expectRevert(
                abi.encodeWithSelector(FireMerkleDistributor.FireMerkleDistributorAlreadyClaimed.selector, account)
            );
        } else {
            success = true;
        }
        vm.prank(caller);
        distributor.claim(account, amounts[i], proofs[i]);
        if (success) {
            ghostClaimed += amounts[i];
            ++ghostClaimCount;
        }
    }

    function claimForged(address account, uint256 amount, uint256 seed) external {
        uint256 i = _bound(seed, 0, accounts.length - 1);
        if (account == accounts[i] && amount == amounts[i]) amount += 1;
        if (block.timestamp > deadline) {
            vm.expectRevert(
                abi.encodeWithSelector(FireMerkleDistributor.FireMerkleDistributorClaimWindowClosed.selector, deadline)
            );
        } else if (distributor.isClaimed(account)) {
            vm.expectRevert(
                abi.encodeWithSelector(FireMerkleDistributor.FireMerkleDistributorAlreadyClaimed.selector, account)
            );
        } else {
            vm.expectRevert(
                abi.encodeWithSelector(
                    FireMerkleDistributor.FireMerkleDistributorInvalidProof.selector, account, amount
                )
            );
        }
        distributor.claim(account, amount, proofs[i]);
    }

    function sweep(address caller) external {
        uint256 balance = token.balanceOf(address(distributor));
        bool success;
        if (block.timestamp <= deadline) {
            vm.expectRevert(
                abi.encodeWithSelector(FireMerkleDistributor.FireMerkleDistributorClaimWindowOpen.selector, deadline)
            );
        } else if (balance == 0) {
            vm.expectRevert(FireMerkleDistributor.FireMerkleDistributorNothingToSweep.selector);
        } else {
            success = true;
        }
        vm.prank(caller);
        distributor.sweep();
        if (success) {
            ghostSwept += balance;
            ++ghostSweepCount;
        }
    }

    function donate(uint256 amount) external {
        amount = _bound(amount, 1, 1_000e18);
        vm.prank(donor);
        require(token.transfer(address(distributor), amount), "transfer failed");
        ghostDonated += amount;
    }

    function warp(uint256 secondsForward) external {
        vm.warp(block.timestamp + _bound(secondsForward, 0, 20 days));
    }
}

contract FireMerkleDistributorInvariantTest is AirdropFixture {
    FireToken internal token;
    FireMerkleDistributor internal distributor;
    AirdropClaimHandler internal handler;
    address internal airdropWallet = makeAddr("airdropWallet");
    address internal donor = makeAddr("donor");
    uint256 internal walletAfterFunding;
    uint64 internal deadline;

    function setUp() public {
        _loadAirdropFixture();
        address deployer = makeAddr("deployer");
        token = _deployFireWithAirdropWallet(deployer, airdropWallet);
        vm.prank(deployer);
        require(token.transfer(donor, 1_000_000e18), "transfer failed");

        deadline = SafeCast.toUint64(block.timestamp + 90 days);
        vm.startPrank(airdropWallet);
        distributor = new FireMerkleDistributor(token, fixtureRoot, deadline, airdropWallet);
        require(token.transfer(address(distributor), fixtureTotal), "transfer failed");
        vm.stopPrank();
        walletAfterFunding = token.balanceOf(airdropWallet);

        handler = new AirdropClaimHandler(distributor, donor);
        for (uint256 i; i < fixtureCount; ++i) {
            handler.addRecipient(fixtureAccounts[i], fixtureAmounts[i], fixtureProofs[i]);
        }

        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = AirdropClaimHandler.claim.selector;
        selectors[1] = AirdropClaimHandler.claimForged.selector;
        selectors[2] = AirdropClaimHandler.sweep.selector;
        selectors[3] = AirdropClaimHandler.donate.selector;
        selectors[4] = AirdropClaimHandler.warp.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /// @dev 청구 + 회수 + 잔액 == 예치 + 추가 입금 (토큰이 새거나 생기지 않음)
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_TotalClaimedPlusSweptPlusBalanceEqualsFunded() public view {
        assertEq(
            handler.ghostClaimed() + handler.ghostSwept() + token.balanceOf(address(distributor)),
            fixtureTotal + handler.ghostDonated()
        );
    }

    /// @dev 청구한 주소는 정확히 목록상 수량만, 청구하지 않은 주소는 0을 보유
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_RecipientsHoldExactlyTheirClaims() public view {
        uint256 claimedSum;
        for (uint256 i; i < fixtureCount; ++i) {
            bool claimed = distributor.isClaimed(fixtureAccounts[i]);
            assertEq(token.balanceOf(fixtureAccounts[i]), claimed ? fixtureAmounts[i] : 0);
            if (claimed) claimedSum += fixtureAmounts[i];
        }
        assertEq(claimedSum, handler.ghostClaimed());
    }

    /// @dev 클레임 기간 중에는 미청구 수령자 전원에게 지급할 잔액이 항상 남아 있음 (sweep 불가)
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_SolventWhileClaimWindowOpen() public view {
        if (block.timestamp > deadline) return;
        uint256 unclaimed;
        for (uint256 i; i < fixtureCount; ++i) {
            if (!distributor.isClaimed(fixtureAccounts[i])) unclaimed += fixtureAmounts[i];
        }
        assertGe(token.balanceOf(address(distributor)), unclaimed);
        assertEq(handler.ghostSwept(), 0);
    }

    /// @dev 회수 주소(에어드롭 지갑)는 sweep으로만 토큰을 받음
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_SweepRecipientReceivesOnlySweeps() public view {
        assertEq(token.balanceOf(airdropWallet), walletAfterFunding + handler.ghostSwept());
    }

    /// @dev 매 실행 종료 후: 기한 이후 sweep 한 번으로 남은 전부가 에어드롭 지갑으로 돌아옴
    function afterInvariant() public {
        if (block.timestamp <= deadline) vm.warp(uint256(deadline) + 1);
        uint256 remaining = token.balanceOf(address(distributor));
        if (remaining > 0) distributor.sweep();
        assertEq(token.balanceOf(address(distributor)), 0);
        assertEq(token.balanceOf(airdropWallet), walletAfterFunding + handler.ghostSwept() + remaining);
        assertEq(handler.ghostClaimed() + handler.ghostSwept() + remaining, fixtureTotal + handler.ghostDonated());
    }
}
