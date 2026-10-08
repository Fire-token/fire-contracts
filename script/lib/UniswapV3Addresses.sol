// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title UniswapV3Addresses
 * @dev Base / Base Sepolia의 Uniswap V3 주소표. CreatePool은 실행 시점에 NPM.factory()·NPM.WETH9()가
 *      이 표와 일치하는지 다시 확인하므로, 주소표 오기입이 있으면 트랜잭션 전송 전에 중단됨.
 */
library UniswapV3Addresses {
    error UniswapV3AddressesUnsupportedChain(uint256 chainId);

    struct Deployment {
        address factory;
        address positionManager;
        address weth;
    }

    /// @dev OP Stack 프리디플로이 WETH (Base, Base Sepolia 동일 주소).
    address internal constant WETH = 0x4200000000000000000000000000000000000006;

    address internal constant BASE_FACTORY = 0x33128a8fC17869897dcE68Ed026d694621f6FDfD;
    address internal constant BASE_POSITION_MANAGER = 0x03a520b32C04BF3bEEf7BEb72E919cf822Ed34f1;
    /// @dev 스크립트는 사용하지 않음. 포크 테스트의 사용자 매수 경로 검증용.
    address internal constant BASE_SWAP_ROUTER02 = 0x2626664c2603336E57B271c5C0b26F421741e481;

    address internal constant BASE_SEPOLIA_FACTORY = 0x4752ba5DBc23f44D87826276BF6Fd6b1C372aD24;
    address internal constant BASE_SEPOLIA_POSITION_MANAGER = 0x27F971cb582BF9E50F397e4d29a5C7A34f11faA2;

    function isSupported(uint256 chainId) internal pure returns (bool) {
        return chainId == 8453 || chainId == 84532;
    }

    function forChain(uint256 chainId) internal pure returns (Deployment memory d) {
        if (chainId == 8453) {
            d = Deployment({factory: BASE_FACTORY, positionManager: BASE_POSITION_MANAGER, weth: WETH});
        } else if (chainId == 84532) {
            d = Deployment({factory: BASE_SEPOLIA_FACTORY, positionManager: BASE_SEPOLIA_POSITION_MANAGER, weth: WETH});
        } else {
            revert UniswapV3AddressesUnsupportedChain(chainId);
        }
    }
}
