// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Vm, VmSafe} from "forge-std/Vm.sol";
import {console} from "forge-std/console.sol";
import {ISafeMinimal} from "./ISafeMinimal.sol";

/**
 * @title LaunchGuards
 * @dev 모든 배포 스크립트(Deploy·CreatePool·PostDeployCheck·DeployAirdrop·DeployBatchSender)가 공유하는 안전 검사.
 *        - RPC 체인 ID 대조: --chain / FOUNDRY_CHAIN_ID로 시뮬레이션 체인만 바꿔 메인넷 보호를 우회하는 것을 막음
 *        - 엄격한 EIP-55 주소 파싱: 대소문자 한 글자 오타를 거부하고, 요청 시 체크섬 없는(전부 소문자) 주소도 거부
 *        - 계정 종류 판별: EIP-7702 위임 EOA, Safe 멀티시그(임계값·소유자·모듈)
 *        - 컨트랙트 출처: 주소가 특정 계정의 최근 CREATE 주소인지 (토큰을 배포 지갑에 묶음)
 *      internal 함수만 있으므로 호출한 스크립트 안에 그대로 포함됨(별도 배포·링크 없음). 실행 문맥·환경 변수·RPC 응답
 *      같은 입력은 GuardedScript가 virtual 함수로 받아 넘기며, 테스트는 그 함수들만 재정의함.
 */
library LaunchGuards {
    error LaunchChainIdMismatch(uint256 simulatedChainId, uint256 rpcChainId);
    error LaunchRpcUnavailable();
    error LaunchInvalidAddress(string name);
    error LaunchBadChecksum(string name);
    error LaunchChecksumRequired(string name);

    /// @dev forge 치트코드 주소 (forge-std CommonBase의 VM_ADDRESS와 같은 값).
    Vm private constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    /// @dev EIP-7702 위임 지정자 = 0xef0100 ‖ 위임 대상 주소(20바이트). EIP-3541로 일반 컨트랙트 코드는 0xef로 시작할 수 없음.
    uint256 private constant DELEGATION_CODE_LENGTH = 23;
    /// @dev Safe ModuleManager의 모듈 목록 시작 표지 (SENTINEL_MODULES).
    address private constant SAFE_SENTINEL_MODULES = address(0x1);

    // ───────────────────────── 실행 문맥 ─────────────────────────

    /// @dev forge script 실행(드라이런·브로드캐스트·재개)인지. forge test는 false.
    function isScriptRun() internal view returns (bool) {
        return VM.isContext(VmSafe.ForgeContext.ScriptGroup);
    }

    /**
     * @dev 실제 전송(--broadcast) 실행인지. forge script --resume은 스크립트를 다시 실행하지 않으므로 ScriptResume 문맥은
     *      스크립트 코드에서 관찰되지 않지만, 향후 forge가 재실행하더라도 안전하도록 함께 둠.
     */
    function isBroadcastRun() internal view returns (bool) {
        return VM.isContext(VmSafe.ForgeContext.ScriptBroadcast) || VM.isContext(VmSafe.ForgeContext.ScriptResume);
    }

    // ───────────────────────── RPC 체인 ID ─────────────────────────

    /// @dev 현재 포크 RPC의 eth_chainId. RPC가 없거나 응답 형식이 이상하면 ok=false (revert하지 않음).
    function rpcChainId() internal returns (bool ok, uint256 chainId) {
        try VM.rpc("eth_chainId", "[]") returns (bytes memory raw) {
            return decodeRpcQuantity(raw);
        } catch {
            return (false, 0);
        }
    }

    /// @dev vm.rpc는 16진 quantity("0x2105", "0x14a34")를 빅엔디언 바이트(0x2105, 0x014a34)로 돌려줌.
    function decodeRpcQuantity(bytes memory raw) internal pure returns (bool ok, uint256 value) {
        if (raw.length == 0 || raw.length > 32) return (false, 0);
        value = uint256(bytes32(raw)) >> (8 * (32 - raw.length));
        ok = true;
    }

    /**
     * @dev forge script의 `--chain <id>`(별칭 --chain-id)나 FOUNDRY_CHAIN_ID는 시뮬레이션의 block.chainid만 바꾸고,
     *      서명·전송은 RPC의 실제 체인으로 함. 그대로 두면 Base 메인넷에 전송하면서 스크립트는 Sepolia로 착각해
     *      CONFIRM_MAINNET·Safe 확인·소유 증명·체크섬 강제를 모두 건너뜀. 그래서 RPC의 eth_chainId와 다르면 중단함.
     *      RPC가 없는 로컬 드라이런은 전송이 없으므로 통과시키지만, --broadcast에서 RPC를 조회할 수 없으면 중단함.
     */
    function requireRpcChainMatches(bool rpcOk, uint256 rpcChain, bool broadcasting) internal view {
        if (!rpcOk) {
            if (broadcasting) revert LaunchRpcUnavailable();
            console.log("NOTE: no RPC endpoint (local simulation only); chain id cross-check skipped.");
            return;
        }
        if (rpcChain != block.chainid) {
            console.log("ABORT: the script sees chainId %s but the RPC is chainId %s.", block.chainid, rpcChain);
            console.log("  Never pass --chain / --chain-id or FOUNDRY_CHAIN_ID to these scripts; use --rpc-url only.");
            revert LaunchChainIdMismatch(block.chainid, rpcChain);
        }
    }

    // ───────────────────────── 주소 파싱 ─────────────────────────

    /**
     * @dev "0x" + 16진수 40자만 허용. vm.parseAddress는 EIP-55 체크섬을 검사하지 않아 대소문자가 섞인 주소의
     *      한 글자 오타도 "다른 유효한 주소"로 받아들이므로(예: BENEFICIARY 오타 → 2억 FIRE 영구 동결):
     *      - EIP-55 표기(vm.toString)와 정확히 같으면 통과 (드물게 EIP-55 표기 자체가 전부 소문자인 주소도 포함).
     *      - 대문자가 하나라도 있는데 EIP-55 표기와 다르면 거부 (체크섬 불일치 = 오타).
     *      - 전부 소문자이고 EIP-55 표기와 다르면 체크섬 정보가 없는 입력: requireChecksum이면 거부.
     *      오류 메시지에 "올바른 체크섬"을 보여 주지 않음: 오타 주소의 체크섬을 복사해 쓰는 실수를 막기 위해
     *      원본에서 다시 복사하도록 안내함.
     * @param name 오류에 표시할 환경 변수 이름.
     */
    function parseAddress(string memory name, string memory raw, bool requireChecksum)
        internal
        pure
        returns (address parsed)
    {
        bytes memory b = bytes(raw);
        if (b.length != 42 || b[0] != "0" || b[1] != "x") revert LaunchInvalidAddress(name);
        bool hasUpper;
        bool hasLower;
        for (uint256 i = 2; i < 42; ++i) {
            bytes1 c = b[i];
            if (c >= "0" && c <= "9") continue;
            if (c >= "a" && c <= "f") hasLower = true;
            else if (c >= "A" && c <= "F") hasUpper = true;
            else revert LaunchInvalidAddress(name);
        }
        parsed = VM.parseAddress(raw);
        if (keccak256(b) == keccak256(bytes(VM.toString(parsed)))) return parsed;
        if (hasUpper) revert LaunchBadChecksum(name);
        if (requireChecksum && hasLower) revert LaunchChecksumRequired(name);
    }

    // ───────────────────────── 계정 종류 ─────────────────────────

    /**
     * @dev EIP-7702 위임 지정자(0xef0100 ‖ 위임 대상 주소, 23바이트)를 코드로 가진 EOA인지.
     *      위임 대상이 Safe처럼 응답해도 원래 개인 키 하나로 언제든 직접 서명할 수 있으므로 멀티시그로 보지 않음.
     */
    function isDelegatedEOA(address account) internal view returns (bool) {
        if (account.code.length != DELEGATION_CODE_LENGTH) return false;
        bytes memory code = account.code;
        return code[0] == 0xef && code[1] == 0x01 && code[2] == 0x00;
    }

    /**
     * @dev getThreshold()/getOwners()를 저수준 staticcall로 조회 (모든 Safe 1.x가 제공). 코드가 없거나, Safe가 아니거나,
     *      fallback이 빈 값·형식이 다른 값을 돌려주는 컨트랙트여도 revert하지 않고 isSafe=false를 반환.
     *      isSafe = 0 < threshold ≤ 소유자 수 (getThreshold() ≥ 1이고 getOwners()가 비어 있지 않음).
     *      EIP-7702 위임 EOA는 위임 대상의 응답이 나오므로, 멀티시그 판정에는 isDelegatedEOA를 먼저 확인할 것.
     */
    function probeSafe(address account) internal view returns (bool isSafe, uint256 threshold, uint256 ownerCount) {
        if (account.code.length == 0) return (false, 0, 0);
        (bool ok, bytes memory ret) = account.staticcall(abi.encodeCall(ISafeMinimal.getThreshold, ()));
        if (!ok || ret.length != 32) return (false, 0, 0);
        threshold = abi.decode(ret, (uint256));
        (ok, ret) = account.staticcall(abi.encodeCall(ISafeMinimal.getOwners, ()));
        if (!ok) return (false, threshold, 0);
        bool wellFormed;
        (wellFormed, ownerCount) = _addressArrayLength(ret);
        if (!wellFormed) return (false, threshold, 0);
        isSafe = threshold != 0 && threshold <= ownerCount;
    }

    /**
     * @dev 멀티시그 기준(Safe, 임계값 ≥ minThreshold, 소유자 ≥ minOwners)을 만족하는지. EIP-7702 위임 EOA는 항상 false.
     *      반환값의 threshold·ownerCount는 오류 메시지용 (위임 EOA면 0).
     */
    function isMultisig(address account, uint256 minThreshold, uint256 minOwners)
        internal
        view
        returns (bool ok, bool delegated, uint256 threshold, uint256 ownerCount)
    {
        delegated = isDelegatedEOA(account);
        if (delegated) return (false, true, 0, 0);
        bool isSafe;
        (isSafe, threshold, ownerCount) = probeSafe(account);
        ok = isSafe && threshold >= minThreshold && ownerCount >= minOwners;
    }

    /**
     * @dev Safe의 getOwners()를 revert 없이 읽음. 형식이 abi.encode(address[])가 아니거나 주소 범위를 벗어난 값이 있으면
     *      ok=false. (Safe 판별은 probeSafe, 이 함수는 소유자 목록이 필요한 소유 증명 검증용)
     */
    function safeOwners(address account) internal view returns (bool ok, address[] memory owners) {
        if (account.code.length == 0) return (false, owners);
        (bool success, bytes memory ret) = account.staticcall(abi.encodeCall(ISafeMinimal.getOwners, ()));
        if (!success) return (false, owners);
        (bool wellFormed,) = _addressArrayLength(ret);
        if (!wellFormed) return (false, owners);
        uint256[] memory words = abi.decode(ret, (uint256[])); // uint256은 값 검사가 없어 형식만 맞으면 revert하지 않음
        owners = new address[](words.length);
        for (uint256 i; i < words.length; ++i) {
            if (words[i] > type(uint160).max) return (false, new address[](0));
            owners[i] = address(uint160(words[i]));
        }
        ok = true;
    }

    /**
     * @dev Safe에 활성화된 모듈이 있는지: getModulesPaginated(SENTINEL, 1)을 revert 없이 조회 (Safe 1.1.1 이상).
     *      모듈은 소유자 서명 없이 execTransactionFromModule로 Safe 자산을 옮길 수 있어 임계값(2-of-3) 규칙을 무력화함.
     *      ok=false: 조회 실패·형식 이상(모듈 상태를 확인할 수 없음). 반환 형식 = abi.encode(address[] page, address next).
     */
    function safeHasModules(address account) internal view returns (bool ok, bool hasModules) {
        if (account.code.length == 0) return (false, false);
        (bool success, bytes memory ret) = account.staticcall(
            abi.encodeWithSignature("getModulesPaginated(address,uint256)", SAFE_SENTINEL_MODULES, uint256(1))
        );
        if (!success || ret.length < 96) return (false, false);
        (uint256 offset,, uint256 n) = abi.decode(ret, (uint256, uint256, uint256));
        if (offset != 64 || n > (ret.length - 96) / 32) return (false, false);
        return (true, n != 0);
    }

    /**
     * @dev account가 creator의 CREATE 주소(nonce가 creatorNonce − 1부터 최대 maxScan개 이전까지)인지. 런칭 토큰은 배포
     *      지갑이 직접 만든 컨트랙트이므로, 다른 사람이 만든 같은 이름·바이트코드의 토큰(주소 오염)을 걸러 냄.
     *      반환 nonce는 일치한 CREATE nonce (found=false면 0).
     */
    function createdBy(address account, address creator, uint256 creatorNonce, uint256 maxScan)
        internal
        pure
        returns (bool found, uint256 nonce)
    {
        uint256 stop = creatorNonce > maxScan ? creatorNonce - maxScan : 0;
        for (uint256 n = creatorNonce; n > stop;) {
            --n;
            if (VM.computeCreateAddress(creator, n) == account) return (true, n);
        }
    }

    /// @dev abi.encode(address[])의 길이를 revert 없이 읽음: 오프셋 0x20, 길이 n, 본문 n워드가 모두 들어 있어야 함.
    function _addressArrayLength(bytes memory ret) private pure returns (bool ok, uint256 length) {
        if (ret.length < 64) return (false, 0);
        (uint256 offset, uint256 n) = abi.decode(ret, (uint256, uint256));
        if (offset != 32 || n > (ret.length - 64) / 32) return (false, 0);
        return (true, n);
    }
}
