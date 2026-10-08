// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Vm} from "forge-std/Vm.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

/**
 * @title ControlProof
 * @dev 런칭 수령 주소(BENEFICIARY, AIRDROP_WALLET)를 운영자가 실제로 통제하는지 확인하는 서명 증명.
 *      FireVesting의 최초 수익자는 수락 절차 없이 곧바로 owner가 되고 에어드롭 물량은 단순 전송이므로, 주소 오타나
 *      통제하지 않는 주소(예: 다른 체인에만 배포된 Safe 주소)를 넣으면 2억 / 5,000만 FIRE가 영구히 묶임.
 *      그래서 그 주소의 키로 아래 한 줄 메시지에 personal_sign(EIP-191) 서명을 받아 배포 전에 검증함:
 *        FIRE launch control proof | role=<ROLE> | address=<EIP-55 주소> | chainId=<10진 체인 ID>
 *      역할·주소·체인 ID가 메시지에 들어 있으므로 다른 역할·주소·체인(예: Sepolia 리허설)의 서명으로는 통과하지 못함.
 *      서명 생성: cast wallet sign --ledger "<메시지>"  (키스토어: cast wallet sign --account <이름> "<메시지>")
 *      검증: MessageHashUtils.toEthSignedMessageHash(bytes(message)) + ECDSA.tryRecover (revert 없이 결과 코드 반환).
 *      Safe 수령 주소: 같은 메시지(address = Safe 주소)에 Safe의 현재 소유자들이 각자 서명하고, 서명들을 이어 붙여
 *      제출함(순서 무관). 서로 다른 소유자의 서명이 임계값 이상이어야 통과(checkOwners). 다른 사람이 만든 비슷한 주소의
 *      Safe(주소 오염)는 소유자가 달라 운영자 키의 서명으로 통과할 수 없음.
 */
library ControlProof {
    /// @dev 검증 결과. Valid 외에는 describe()가 운영자용 설명을 돌려줌.
    enum Result {
        Valid,
        Missing,
        BadLength,
        BadSignature,
        HighS,
        WrongSigner,
        NotEnoughOwners,
        DuplicateSigner
    }

    string internal constant ROLE_BENEFICIARY = "BENEFICIARY";
    string internal constant ROLE_AIRDROP_WALLET = "AIRDROP_WALLET";
    string internal constant MESSAGE_PREFIX = "FIRE launch control proof";
    uint256 internal constant SIGNATURE_LENGTH = 65;
    /// @dev 한 환경 변수에 이어 붙일 수 있는 서명 수 상한 (Safe 소유자 서명).
    uint256 internal constant MAX_SIGNATURES = 16;

    /// @dev forge 치트코드 주소 (EIP-55 표기·10진 문자열 변환에만 사용, 모두 pure).
    Vm private constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    /// @notice 서명할 정확한 메시지 (한 줄, 주소는 EIP-55 체크섬 표기, 체인 ID는 10진수).
    function message(string memory role, address account, uint256 chainId) internal pure returns (string memory) {
        return string.concat(
            MESSAGE_PREFIX, " | role=", role, " | address=", VM.toString(account), " | chainId=", VM.toString(chainId)
        );
    }

    /// @notice personal_sign(EIP-191) 다이제스트: keccak256("\x19Ethereum Signed Message:\n" ‖ 길이 ‖ 메시지).
    function digest(string memory text) internal pure returns (bytes32) {
        return MessageHashUtils.toEthSignedMessageHash(bytes(text));
    }

    /**
     * @notice 환경 변수 값 → 65바이트 서명 k개(1 ≤ k ≤ MAX_SIGNATURES)를 이어 붙인 바이트.
     *         "0x" + 16진수 130·k자(대소문자 무관)만 허용하고, 아니면 ok=false. EOA는 k = 1, Safe는 소유자 수만큼.
     * @dev vm.parseBytes는 길이·접두사를 따지지 않으므로 형식을 먼저 엄격히 확인해 분명한 오류를 내게 함.
     */
    function parseSignatures(string memory raw) internal pure returns (bool ok, bytes memory signatures) {
        bytes memory b = bytes(raw);
        if (b.length < 2 || b[0] != "0" || b[1] != "x") return (false, "");
        uint256 hexLength = b.length - 2;
        if (hexLength == 0 || hexLength % (2 * SIGNATURE_LENGTH) != 0) return (false, "");
        if (hexLength / (2 * SIGNATURE_LENGTH) > MAX_SIGNATURES) return (false, "");
        signatures = new bytes(hexLength / 2);
        for (uint256 i; i < signatures.length; ++i) {
            (bool okHigh, uint8 high) = _hexDigit(b[2 + 2 * i]);
            (bool okLow, uint8 low) = _hexDigit(b[3 + 2 * i]);
            if (!okHigh || !okLow) return (false, "");
            signatures[i] = bytes1(high * 16 + low);
        }
        ok = true;
    }

    /**
     * @notice text에 대한 signature가 account의 서명인지 확인 (revert 없음). EOA·EIP-7702 위임 EOA용(서명 1개).
     * @dev v가 0/1인 서명(일부 서명 도구)은 27/28로 바꿔 검증함. OpenZeppelin tryRecover는 s가 상위 절반인
     *      가변(malleable) 서명을 거부(HighS)하고, ecrecover 실패는 BadSignature로 돌려줌.
     *      입력 signature는 바꾸지 않음(복사본에서 v를 정규화).
     */
    function check(string memory text, address account, bytes memory signature)
        internal
        pure
        returns (Result result, address recovered)
    {
        if (signature.length == 0) return (Result.Missing, address(0));
        if (signature.length != SIGNATURE_LENGTH) return (Result.BadLength, address(0));
        (result, recovered) = _recover(digest(text), signature, 0);
        if (result != Result.Valid) return (result, address(0));
        if (recovered != account) result = Result.WrongSigner;
    }

    /**
     * @notice Safe 수령 주소의 소유 증명: signatures = Safe 소유자들이 text에 각자 personal_sign한 65바이트 서명을 이어
     *         붙인 값(순서 무관). 모든 서명이 서로 다른 현재 소유자의 것이고 그 수가 threshold 이상이면 Valid.
     * @return result     Valid / Missing / BadLength / BadSignature / HighS / WrongSigner(소유자가 아닌 서명자) /
     *                    DuplicateSigner(같은 소유자 두 번) / NotEnoughOwners(임계값 미달)
     * @return signers    확인된 서로 다른 소유자 수
     * @return offender   WrongSigner·DuplicateSigner일 때 해당 서명자 주소
     */
    function checkOwners(string memory text, address[] memory owners, uint256 threshold, bytes memory signatures)
        internal
        pure
        returns (Result result, uint256 signers, address offender)
    {
        if (signatures.length == 0) return (Result.Missing, 0, address(0));
        uint256 count = signatures.length / SIGNATURE_LENGTH;
        if (signatures.length % SIGNATURE_LENGTH != 0 || count > MAX_SIGNATURES) {
            return (Result.BadLength, 0, address(0));
        }
        bytes32 hash = digest(text);
        address[] memory seen = new address[](count);
        for (uint256 k; k < count; ++k) {
            address recovered;
            (result, recovered) = _recover(hash, signatures, k * SIGNATURE_LENGTH);
            if (result != Result.Valid) return (result, signers, address(0));
            if (!_contains(owners, owners.length, recovered)) return (Result.WrongSigner, signers, recovered);
            if (_contains(seen, signers, recovered)) return (Result.DuplicateSigner, signers, recovered);
            seen[signers++] = recovered;
        }
        result = signers >= threshold ? Result.Valid : Result.NotEnoughOwners;
    }

    /// @notice 검증 결과에 대한 운영자용 설명 (오류 메시지·로그에 사용).
    function describe(Result result) internal pure returns (string memory) {
        if (result == Result.Valid) return "valid";
        if (result == Result.Missing) return "not provided";
        if (result == Result.BadLength) return "not a 65-byte signature";
        if (result == Result.BadSignature) return "invalid signature (ecrecover failed)";
        if (result == Result.HighS) {
            return "malleable signature (s in the upper half); sign again with cast wallet sign";
        }
        if (result == Result.NotEnoughOwners) return "fewer Safe owner signatures than the Safe threshold";
        if (result == Result.DuplicateSigner) return "the same Safe owner signed twice";
        return "signed by a different address (wrong key, or role/address/chainId differ from the message)";
    }

    /// @dev signatures[offset..offset+65)의 서명자 복원 (v 0/1 → 27/28 정규화는 복사본에서).
    function _recover(bytes32 hash, bytes memory signatures, uint256 offset)
        private
        pure
        returns (Result result, address recovered)
    {
        bytes memory sig = new bytes(SIGNATURE_LENGTH);
        for (uint256 i; i < SIGNATURE_LENGTH; ++i) {
            sig[i] = signatures[offset + i];
        }
        uint8 v = uint8(sig[SIGNATURE_LENGTH - 1]);
        if (v < 2) sig[SIGNATURE_LENGTH - 1] = bytes1(v + 27);
        ECDSA.RecoverError err;
        (recovered, err,) = ECDSA.tryRecover(hash, sig);
        if (err == ECDSA.RecoverError.InvalidSignatureS) return (Result.HighS, address(0));
        if (err != ECDSA.RecoverError.NoError) return (Result.BadSignature, address(0));
        result = Result.Valid;
    }

    function _contains(address[] memory list, uint256 length, address value) private pure returns (bool) {
        for (uint256 i; i < length; ++i) {
            if (list[i] == value) return true;
        }
        return false;
    }

    function _hexDigit(bytes1 c) private pure returns (bool ok, uint8 value) {
        uint8 x = uint8(c);
        if (x >= 0x30 && x <= 0x39) return (true, x - 0x30); // 0-9
        if (x >= 0x61 && x <= 0x66) return (true, x - 0x57); // a-f
        if (x >= 0x41 && x <= 0x46) return (true, x - 0x37); // A-F
        return (false, 0);
    }
}
