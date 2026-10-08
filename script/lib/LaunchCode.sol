// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Vm} from "forge-std/Vm.sol";
import {FireToken} from "../../src/FireToken.sol";
import {FireVesting} from "../../src/FireVesting.sol";
import {LaunchParams} from "./LaunchParams.sol";

/**
 * @title LaunchCode
 * @dev 배포된 FireToken·FireVesting의 런타임 코드가 이 저장소에서 컴파일한 코드와 같은지 확인 (PostDeployCheck).
 *      공개 기록만 믿으면 악의적인 배포자가 "베스팅처럼 응답하지만 언제든 인출할 수 있는" 컨트랙트로 2억 FIRE를 받고도
 *      점검을 통과할 수 있으므로(FireToken 생성자 검사는 실수 방지용), 코드 자체를 대조함.
 *      - immutable 값은 배포마다 달라 그대로 비교할 수 없으므로 같은 값으로 참조 코드를 만들어 비교:
 *        FireVesting: start·duration뿐 → 시뮬레이션 시각을 (start − 180일)로 옮겨 참조 FireVesting을 배포 (정확히 같은 코드).
 *        FireToken: EIP-712 캐시 값(_cachedThis = 토큰 주소, _cachedDomainSeparator)이 주소에 따라 다름 → 생성 코드를
 *        임시 주소에서 실행해 런타임 코드를 얻은 뒤 그 두 32바이트 값을 실제 토큰 주소의 값으로 바꿔 비교.
 *      - 끝의 CBOR 메타데이터(주석·경로에 따라 바뀌는 해시)는 빼고 비교 (test/FireToken.t.sol의 바이트코드 고정과 같은 기준).
 *      - 참조 컨트랙트 배포·vm.warp·vm.etch는 forge의 로컬 시뮬레이션에서만 일어나며 아무것도 전송하지 않음.
 */
library LaunchCode {
    uint8 internal constant UNCHECKED = 0;
    uint8 internal constant MATCH = 1;
    uint8 internal constant MISMATCH = 2;

    /// @dev forge 치트코드 주소 (forge-std CommonBase의 VM_ADDRESS와 같은 값).
    Vm private constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    /// @dev FireToken 생성 코드를 실행해 볼 임시 주소 (코드·잔액이 없는 주소, 사용 후 코드를 지움).
    address private constant REFERENCE_TOKEN = address(uint160(uint256(keccak256("FIRE launch reference FireToken"))));
    bytes32 private constant EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    /// @notice vesting의 코드가 이 저장소의 FireVesting(start = vesting.start(), duration = 540일)과 같으면 MATCH.
    function vestingStatus(address vesting) internal returns (uint8) {
        if (vesting.code.length == 0) return MISMATCH;
        (bool ok, bytes memory ret) = vesting.staticcall(abi.encodeWithSignature("start()"));
        if (!ok || ret.length != 32) return MISMATCH;
        uint256 start = abi.decode(ret, (uint256));
        if (start < LaunchParams.CLIFF || start > type(uint64).max) return MISMATCH; // start는 uint64 immutable
        uint256 nowTs = VM.getBlockTimestamp(); // vm.warp 전후로 block.timestamp를 캐시하지 않도록 치트코드로 읽음
        VM.warp(start - LaunchParams.CLIFF); // 참조 FireVesting의 start immutable = 대상과 같은 값
        FireVesting expected = new FireVesting(address(1), LaunchParams.CLIFF, LaunchParams.LINEAR);
        VM.warp(nowTs);
        return sameExecutable(vesting.code, address(expected).code) ? MATCH : MISMATCH;
    }

    /// @notice token의 코드가 이 저장소의 FireToken을 그 주소·이 체인에서 배포한 코드와 같으면 MATCH.
    function tokenStatus(address token) internal returns (uint8) {
        if (token.code.length == 0) return MISMATCH;
        // 생성자의 베스팅 검사(start ≥ 현재, duration > 0)를 통과시키는 참조 베스팅. 생성자 인자는 런타임 코드에 남지 않음.
        FireVesting vesting = new FireVesting(address(1), LaunchParams.CLIFF, LaunchParams.LINEAR);
        VM.etch(REFERENCE_TOKEN, abi.encodePacked(type(FireToken).creationCode, abi.encode(address(vesting))));
        (bool ok, bytes memory runtime) = REFERENCE_TOKEN.call("");
        VM.etch(REFERENCE_TOKEN, "");
        if (!ok) return MISMATCH;
        replaceWord(runtime, bytes32(uint256(uint160(REFERENCE_TOKEN))), bytes32(uint256(uint160(token))));
        replaceWord(runtime, domainSeparator(REFERENCE_TOKEN), domainSeparator(token));
        return sameExecutable(token.code, runtime) ? MATCH : MISMATCH;
    }

    /// @notice FireToken(이름 "Fire", 버전 "1")이 이 체인의 verifyingContract 주소에서 쓰는 EIP-712 도메인 구분자.
    function domainSeparator(address verifyingContract) internal view returns (bytes32) {
        return keccak256(
            abi.encode(EIP712_DOMAIN_TYPEHASH, keccak256("Fire"), keccak256("1"), block.chainid, verifyingContract)
        );
    }

    /// @notice CBOR 메타데이터를 뺀 실행 코드가 같은지.
    function sameExecutable(bytes memory a, bytes memory b) internal pure returns (bool) {
        uint256 lengthA = executableLength(a);
        if (lengthA != executableLength(b)) return false;
        return _hashPrefix(a, lengthA) == _hashPrefix(b, lengthA);
    }

    /**
     * @notice 끝의 CBOR 메타데이터(마지막 2바이트 = 길이, 시작 바이트 = CBOR map 헤더 0xa1~0xa5)를 뺀 길이.
     *         형식이 맞지 않으면 전체 길이 (메타데이터 없이 비교).
     */
    function executableLength(bytes memory code) internal pure returns (uint256) {
        uint256 total = code.length;
        if (total < 2) return total;
        uint256 metadataLength = (uint256(uint8(code[total - 2])) << 8) | uint256(uint8(code[total - 1]));
        if (metadataLength + 2 >= total) return total;
        uint8 cborMapHeader = uint8(code[total - 2 - metadataLength]);
        if (cborMapHeader < 0xa1 || cborMapHeader > 0xa5) return total;
        return total - 2 - metadataLength;
    }

    /// @notice code 안의 32바이트 값 from을 모두 to로 바꿈 (immutable은 PUSH32 피연산자로 들어 있음). 바꾼 개수 반환.
    function replaceWord(bytes memory code, bytes32 from, bytes32 to) internal pure returns (uint256 replaced) {
        if (code.length < 32) return 0;
        for (uint256 i; i <= code.length - 32; ++i) {
            bytes32 word;
            assembly ("memory-safe") {
                word := mload(add(add(code, 0x20), i))
            }
            if (word != from) continue;
            assembly ("memory-safe") {
                mstore(add(add(code, 0x20), i), to)
            }
            ++replaced;
            i += 31;
        }
    }

    function _hashPrefix(bytes memory data, uint256 length) private pure returns (bytes32 hash) {
        assembly ("memory-safe") {
            hash := keccak256(add(data, 0x20), length)
        }
    }
}
