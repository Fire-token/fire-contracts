// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {LaunchGuards} from "./LaunchGuards.sol";
import {LaunchParams} from "./LaunchParams.sol";

/**
 * @title GuardedScript
 * @dev 배포 스크립트 공통 기반 (LaunchBase → Deploy·CreatePool·PostDeployCheck, DeployAirdrop, DeployBatchSender).
 *      - 입력 지점: 환경 변수(_envString), 실행 문맥(_isBroadcastRun·_enforceRpcChainCheck), RPC 응답(_rpcChainId)을
 *        virtual 함수 하나씩으로 모음. 테스트는 이 함수만 재정의해 프로세스 전역 환경 변수(병렬 테스트 간 경쟁)를
 *        건드리지 않고 값을 주입하며, 파싱·검증은 실제 실행과 같은 코드로 수행됨.
 *      - 검사 로직(RPC 체인 ID 대조, EIP-55 파싱)은 LaunchGuards 라이브러리에 있음.
 *      환경 변수의 빈 문자열은 "미설정"으로 취급 (.env.example의 `KEY=` 줄을 그대로 둔 경우 대비).
 */
abstract contract GuardedScript is Script {
    // ───────────────────────── 입력 지점 (테스트가 재정의) ─────────────────────────

    /// @dev 모든 환경 변수 읽기가 거치는 단일 지점. 미설정과 빈 값은 모두 "".
    function _envString(string memory name) internal view virtual returns (string memory) {
        return vm.envOr(name, string(""));
    }

    /// @dev 실제 전송(--broadcast) 실행인지. 기록 파일 쓰기·서명자 확인·RPC 필수 여부를 가름.
    function _isBroadcastRun() internal view virtual returns (bool) {
        return LaunchGuards.isBroadcastRun();
    }

    /// @dev 스크립트 실행(드라이런·브로드캐스트)에서만 RPC 대조를 강제. 테스트는 vm.chainId로 체인을 흉내 내므로 제외.
    function _enforceRpcChainCheck() internal view virtual returns (bool) {
        return LaunchGuards.isScriptRun();
    }

    /// @dev 현재 포크 RPC의 eth_chainId. RPC가 없거나 응답이 이상하면 ok=false.
    function _rpcChainId() internal virtual returns (bool ok, uint256 chainId) {
        return LaunchGuards.rpcChainId();
    }

    // ───────────────────────── 공통 검사 ─────────────────────────

    /// @dev 시뮬레이션 체인(block.chainid)과 RPC의 실제 체인이 같은지 확인 (LaunchGuards.requireRpcChainMatches).
    function _requireRpcChainMatches() internal {
        if (!_enforceRpcChainCheck()) return;
        (bool ok, uint256 rpcChain) = _rpcChainId();
        LaunchGuards.requireRpcChainMatches(ok, rpcChain, _isBroadcastRun());
    }

    function _isMainnet() internal view returns (bool) {
        return block.chainid == LaunchParams.BASE_MAINNET;
    }

    /**
     * @dev 선택 주소 환경 변수. 비어 있으면 defaultValue. 엄격한 EIP-55 파싱(대소문자 오타 거부)이며,
     *      Base 메인넷에서는 체크섬이 없는(전부 소문자) 주소도 거부함.
     */
    function _envAddressOr(string memory name, address defaultValue) internal view returns (address) {
        string memory raw = _envString(name);
        return bytes(raw).length == 0 ? defaultValue : LaunchGuards.parseAddress(name, raw, _isMainnet());
    }

    function _envUintOr(string memory name, uint256 defaultValue) internal view returns (uint256) {
        string memory raw = _envString(name);
        return bytes(raw).length == 0 ? defaultValue : vm.parseUint(raw);
    }

    function _sameString(string memory a, string memory b) internal pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }
}
