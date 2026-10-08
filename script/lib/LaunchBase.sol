// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {console} from "forge-std/console.sol";
import {GuardedScript} from "./GuardedScript.sol";
import {LaunchGuards} from "./LaunchGuards.sol";
import {LaunchParams} from "./LaunchParams.sol";

/**
 * @title LaunchBase
 * @dev 런칭 스크립트 공통 기반: 체인·메인넷 가드, 브로드캐스터 확인, 환경 변수 파싱, 배포 기록 경로, 출력 포맷.
 *      입력 지점(환경 변수·실행 문맥·RPC)과 RPC 체인 ID 대조·EIP-55 파싱은 GuardedScript / LaunchGuards와 공유함
 *      (DeployAirdrop·DeployBatchSender도 같은 코드를 사용).
 *      개인 키를 다루지 않음. 서명은 forge CLI(--ledger / --account)가 담당.
 */
abstract contract LaunchBase is GuardedScript {
    error LaunchUnsupportedChain(uint256 chainId);
    error LaunchMainnetNotConfirmed();
    error LaunchMissingEnv(string name);
    error LaunchNoSigner();
    error LaunchSignerMismatch(address broadcaster);

    bytes private constant DIGITS = "0123456789";

    // ───────────────────────── 체인 가드 ─────────────────────────

    /**
     * @dev Base 메인넷·Base Sepolia만 허용. allowLocal이면 로컬 anvil(31337)도 허용.
     *      block.chainid는 forge의 시뮬레이션 값이라 --chain / FOUNDRY_CHAIN_ID로 바뀔 수 있으므로,
     *      스크립트 실행 중에는 RPC의 실제 eth_chainId와 같은지도 확인함(_requireRpcChainMatches).
     */
    function _requireSupportedChain(bool allowLocal) internal {
        uint256 id = block.chainid;
        bool supported = id == LaunchParams.BASE_MAINNET || id == LaunchParams.BASE_SEPOLIA
            || (allowLocal && id == LaunchParams.LOCAL_ANVIL);
        if (!supported) revert LaunchUnsupportedChain(id);
        _requireRpcChainMatches();
    }

    /// @dev 메인넷에서는 CONFIRM_MAINNET=I_UNDERSTAND 없이는 어떤 트랜잭션도 만들지 않음.
    function _requireMainnetConfirmation(bool confirmed) internal view {
        if (_isMainnet() && !confirmed) {
            console.log("ABORT: Base mainnet requires CONFIRM_MAINNET=%s", LaunchParams.CONFIRM_MAINNET_PHRASE);
            revert LaunchMainnetNotConfirmed();
        }
    }

    function _envMainnetConfirmed() internal view returns (bool) {
        return _sameString(_envString("CONFIRM_MAINNET"), LaunchParams.CONFIRM_MAINNET_PHRASE);
    }

    // ───────────────────────── 환경 변수 ─────────────────────────
    // _envString / _envAddressOr / _envUintOr는 GuardedScript (빈 문자열 = 미설정, 메인넷 주소는 체크섬 필수).

    /// @param requireChecksum true면 EIP-55 체크섬이 들어간 주소만 허용(전부 소문자인 입력 거부).
    function _envAddressRequired(string memory name, bool requireChecksum) internal view returns (address) {
        string memory raw = _envString(name);
        if (bytes(raw).length == 0) revert LaunchMissingEnv(name);
        return LaunchGuards.parseAddress(name, raw, requireChecksum);
    }

    // ───────────────────────── 브로드캐스터 ─────────────────────────

    /**
     * @dev sender가 0이 아니면 그대로 사용(테스트). 0이면 CLI(--sender / --ledger / --account)가 정한
     *      기본 브로드캐스터를 조회: startBroadcast 직후 readCallers로 주소만 읽고 즉시 중지하므로
     *      이 과정에서 기록되는 트랜잭션은 없음.
     */
    function _resolveBroadcaster(address sender) internal returns (address broadcaster) {
        if (sender != address(0)) return sender;
        vm.startBroadcast();
        (, broadcaster,) = vm.readCallers();
        vm.stopBroadcast();
        _requireUsableSigner(broadcaster);
    }

    /**
     * @dev forge는 시뮬레이션을 끝낸 뒤에야 서명자 문제("default sender", "No associated wallet")로 중단하는데,
     *      그때는 이미 기록 파일과 "deployed" 로그가 남은 뒤임. 그래서 --broadcast에서는 시뮬레이션 전에 확인함:
     *      - 서명자 없이 Foundry 기본 sender로 실행 → 중단
     *      - 서명자(--account/--ledger/--private-key)가 로드됐는데 --sender가 그중 어느 것과도 다름 → 중단
     *      로드된 서명자가 없으면(--unlocked 로컬 리허설 등) forge가 전송 단계에서 검증함.
     */
    function _requireUsableSigner(address broadcaster) internal view {
        bool broadcasting = _isBroadcastRun();
        if (broadcaster == DEFAULT_SENDER) {
            if (broadcasting) {
                console.log("ABORT: --broadcast needs a signer: add --ledger or --account <name> and --sender.");
                revert LaunchNoSigner();
            }
            console.log("WARNING: no --sender/--ledger/--account given; simulating with Foundry's default sender.");
            return;
        }
        address[] memory wallets = vm.getWallets();
        if (wallets.length == 0) return;
        for (uint256 i; i < wallets.length; ++i) {
            if (wallets[i] == broadcaster) return;
        }
        if (broadcasting) {
            console.log("ABORT: --sender %s is not one of the loaded signers (--ledger / --account).", broadcaster);
            revert LaunchSignerMismatch(broadcaster);
        }
        console.log("WARNING: --sender %s does not match the loaded signer(s); --broadcast would fail.", broadcaster);
    }

    // ───────────────────────── 배포 기록 ─────────────────────────

    /// @notice 공개 배포 기록 파일 경로: deployments/<chainId>.json (테스트는 임시 경로로 재정의).
    function deploymentPath(uint256 chainId) public view virtual returns (string memory) {
        return string.concat("deployments/", vm.toString(chainId), ".json");
    }

    // 기록 파일은 실제 전송(_isBroadcastRun, GuardedScript)일 때만 씀. 드라이런·테스트에서는 콘솔 출력만 함.
    // forge script --resume은 스크립트를 다시 실행하지 않으므로 첫 실행이 남긴 pending 기록이 그대로 유지됨.

    /// @dev forge의 JSON 직렬화 객체는 키 이름으로 전역 누적되므로, 객체를 만들기 전에 비워 둠.
    function _resetJson(string memory objectKey) internal {
        vm.serializeJson(objectKey, "{}");
    }

    /// @dev 토큰·ETH 수량은 항상 10진 문자열로 기록. forge는 2^64 미만 정수를 JSON 숫자로 쓰는데,
    ///      2^53을 넘는 숫자는 JavaScript JSON.parse에서 정밀도가 깨지므로 공개 기록에 부적합함.
    function _serializeAmount(string memory objectKey, string memory valueKey, uint256 value)
        internal
        returns (string memory)
    {
        return vm.serializeString(objectKey, valueKey, vm.toString(value));
    }

    /// @dev 읽기 대상은 foundry.toml fs_permissions가 허용한 ./deployments 아래의 공개 기록 파일뿐임.
    function _readJsonIfExists(string memory path) internal view returns (bool exists, string memory json) {
        exists = vm.exists(path);
        // forge-lint: disable-next-line(unsafe-cheatcode)
        json = exists ? vm.readFile(path) : "{}";
    }

    function _jsonAddressOr(string memory json, string memory key, address defaultValue)
        internal
        view
        returns (address)
    {
        return vm.keyExistsJson(json, key) ? vm.parseJsonAddress(json, key) : defaultValue;
    }

    function _jsonUintOr(string memory json, string memory key, uint256 defaultValue) internal view returns (uint256) {
        return vm.keyExistsJson(json, key) ? vm.parseJsonUint(json, key) : defaultValue;
    }

    /// @dev 기록의 status 값이 "confirmed"인지 (키가 없거나 "pending"이면 false).
    function _jsonIsConfirmed(string memory json, string memory key) internal view returns (bool) {
        return vm.keyExistsJson(json, key) && _sameString(vm.parseJsonString(json, key), LaunchParams.RECORD_CONFIRMED);
    }

    // ───────────────────────── 네트워크 표시 ─────────────────────────

    function _networkName(uint256 chainId) internal pure returns (string memory) {
        if (chainId == LaunchParams.BASE_MAINNET) return "base";
        if (chainId == LaunchParams.BASE_SEPOLIA) return "base-sepolia";
        if (chainId == LaunchParams.LOCAL_ANVIL) return "anvil";
        return "unknown";
    }

    /// @dev foundry.toml [rpc_endpoints] 별칭.
    function _rpcAlias(uint256 chainId) internal pure returns (string memory) {
        if (chainId == LaunchParams.BASE_MAINNET) return "base";
        if (chainId == LaunchParams.BASE_SEPOLIA) return "base_sepolia";
        return "http://127.0.0.1:8545";
    }

    function _explorerAddress(address account) internal view returns (string memory) {
        string memory addr = vm.toString(account);
        if (block.chainid == LaunchParams.BASE_MAINNET) return string.concat("https://basescan.org/address/", addr);
        if (block.chainid == LaunchParams.BASE_SEPOLIA) {
            return string.concat("https://sepolia.basescan.org/address/", addr);
        }
        return addr;
    }

    // ───────────────────────── 온체인 조회 ─────────────────────────
    // Safe·EIP-7702 판별은 LaunchGuards.probeSafe / isDelegatedEOA / isMultisig.

    /// @dev 반환값이 정확히 32바이트인 view 함수만 읽음(코드 없음·revert·형식 불일치는 ok=false, revert 없음).
    function _staticUint(address target, bytes memory callData) internal view returns (bool ok, uint256 value) {
        if (target.code.length == 0) return (false, 0);
        bytes memory ret;
        (ok, ret) = target.staticcall(callData);
        if (!ok || ret.length != 32) return (false, 0);
        value = abi.decode(ret, (uint256));
    }

    // ───────────────────────── 출력 포맷 ─────────────────────────

    /// @dev 18자리 토큰 수량을 "700,000,000" / "0.000000004285714285" 형태로.
    function _fmt(uint256 value) internal pure returns (string memory) {
        return _formatUnits(value, 18);
    }

    function _formatUnits(uint256 value, uint8 decimals) internal pure returns (string memory) {
        uint256 unit = 10 ** decimals;
        string memory whole = _groupThousands(vm.toString(value / unit));
        uint256 frac = value % unit;
        if (frac == 0) return whole;
        bytes memory digits = new bytes(decimals);
        for (uint256 i = decimals; i > 0; --i) {
            digits[i - 1] = DIGITS[frac % 10];
            frac /= 10;
        }
        uint256 len = decimals;
        while (digits[len - 1] == "0") --len; // frac != 0 이므로 0이 아닌 자리가 반드시 있음
        bytes memory trimmed = new bytes(len);
        for (uint256 i; i < len; ++i) {
            trimmed[i] = digits[i];
        }
        return string.concat(whole, ".", string(trimmed));
    }

    function _groupThousands(string memory digits) internal pure returns (string memory) {
        bytes memory d = bytes(digits);
        uint256 n = d.length;
        if (n <= 3) return digits;
        bytes memory out = new bytes(n + (n - 1) / 3);
        uint256 j = out.length;
        for (uint256 i = n; i > 0; --i) {
            uint256 fromRight = n - i;
            if (fromRight != 0 && fromRight % 3 == 0) out[--j] = ",";
            out[--j] = d[i - 1];
        }
        return string(out);
    }

    /// @dev 유닉스 시각 → "YYYY-MM-DD hh:mm:ss UTC" (Howard Hinnant의 civil_from_days 알고리즘).
    function _formatUtc(uint256 timestamp) internal pure returns (string memory) {
        uint256 z = timestamp / 1 days + 719_468;
        uint256 era = z / 146_097;
        uint256 doe = z % 146_097;
        uint256 yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
        uint256 doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
        uint256 mp = (5 * doy + 2) / 153;
        uint256 day = doy - (153 * mp + 2) / 5 + 1;
        uint256 month = mp < 10 ? mp + 3 : mp - 9;
        uint256 year = yoe + era * 400 + (month <= 2 ? 1 : 0);
        uint256 secs = timestamp % 1 days;
        return string.concat(
            vm.toString(year),
            "-",
            _pad2(month),
            "-",
            _pad2(day),
            " ",
            _pad2(secs / 1 hours),
            ":",
            _pad2((secs % 1 hours) / 1 minutes),
            ":",
            _pad2(secs % 1 minutes),
            " UTC"
        );
    }

    function _pad2(uint256 value) internal pure returns (string memory) {
        return value < 10 ? string.concat("0", vm.toString(value)) : vm.toString(value);
    }

    /// @dev bps → "0.50%" 형태.
    function _fmtBps(uint256 bps) internal pure returns (string memory) {
        return string.concat(vm.toString(bps / 100), ".", _pad2(bps % 100), "%");
    }
}
