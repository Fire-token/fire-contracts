// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title ISafeMinimal
 * @dev Safe(구 Gnosis Safe) 멀티시그 식별용 최소 인터페이스. 모든 Safe 버전(1.x)이 제공하는 조회 함수만 선언.
 */
interface ISafeMinimal {
    function getThreshold() external view returns (uint256);
    function getOwners() external view returns (address[] memory);
}
