// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoolMath} from "./PoolMath.sol";
import {INonfungiblePositionManager, IUniswapV3Factory} from "./IUniswapV3.sol";

/**
 * @title LaunchPositions
 * @dev Uniswap V3 LP 포지션 NFT 조회. forge 스크립트의 시뮬레이션이 돌려준 tokenId는 전송 전 값이라
 *      (NPM의 id 카운터는 Base 전체가 공유) 실제 id와 다를 수 있으므로, 기록·점검은 이 라이브러리로
 *      온체인에서 확인한 id만 사용함. 모든 조회는 revert하지 않음(없는 id → exists=false).
 */
library LaunchPositions {
    struct Position {
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
    }

    /**
     * @dev NPM.positions()의 반환값 12개를 같은 순서로 담은 구조체. 멤버가 모두 정적 타입이라 ABI 인코딩이 12개 값의
     *      튜플과 동일하고 abi.decode의 값 범위 검사도 같음. 튜플로 직접 디코딩하면 디코더가 12개 값을 스택에 올려
     *      최적화 없는 빌드(forge coverage)에서 "stack too deep"이 나므로 구조체(메모리)로 디코딩함.
     */
    struct RawPosition {
        uint96 nonce;
        address operator;
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        uint256 feeGrowthInside0LastX128;
        uint256 feeGrowthInside1LastX128;
        uint128 tokensOwed0;
        uint128 tokensOwed1;
    }

    /// @notice find()의 결과.
    struct Search {
        uint256 tokenId; // 하한(minLiquidity) 이상인 포지션 중 유동성이 가장 큰 것 (없으면 0)
        uint128 liquidity; // 그 포지션의 유동성
        uint256 matches; // 유동성이 있는 (token0, token1[, fee]) 전체 범위 포지션 수 (하한 미만 포함)
        uint256 eligible; // 그중 유동성이 minLiquidity 이상인 수
        uint256 held; // owner가 가진 NFT 수 (balanceOf). maxScan보다 크면 가장 오래된 maxScan개만 확인한 것
    }

    /// @dev positions() 반환 데이터 크기 (정적 타입 12워드).
    uint256 private constant POSITIONS_RETURN_SIZE = 12 * 32;

    /// @dev NPM.positions(tokenId). 존재하지 않거나 소각된 id면 NPM이 revert("Invalid token ID") → exists=false.
    function read(INonfungiblePositionManager npm, uint256 tokenId)
        internal
        view
        returns (bool exists, Position memory p)
    {
        (bool ok, bytes memory ret) =
            address(npm).staticcall(abi.encodeCall(INonfungiblePositionManager.positions, (tokenId)));
        if (!ok || ret.length != POSITIONS_RETURN_SIZE) return (false, p);
        RawPosition memory raw = abi.decode(ret, (RawPosition));
        p = Position({
            token0: raw.token0,
            token1: raw.token1,
            fee: raw.fee,
            tickLower: raw.tickLower,
            tickUpper: raw.tickUpper,
            liquidity: raw.liquidity
        });
        exists = true;
    }

    /// @dev NPM.ownerOf(tokenId). 존재하지 않는 id면 exists=false.
    function ownerOf(INonfungiblePositionManager npm, uint256 tokenId)
        internal
        view
        returns (bool exists, address owner)
    {
        (bool ok, bytes memory ret) =
            address(npm).staticcall(abi.encodeCall(INonfungiblePositionManager.ownerOf, (tokenId)));
        if (!ok || ret.length != 32) return (false, address(0));
        return (true, abi.decode(ret, (address)));
    }

    /**
     * @notice (token0, token1) 쌍의 전체 범위 포지션인지. fee가 0이 아니면 수수료 등급도 일치해야 함.
     * @dev 전체 범위 틱은 팩토리에 등록된 해당 등급의 tickSpacing으로 계산.
     */
    function isFullRange(IUniswapV3Factory factory, Position memory p, address token0, address token1, uint24 fee)
        internal
        view
        returns (bool)
    {
        if (p.token0 != token0 || p.token1 != token1) return false;
        if (fee != 0 && p.fee != fee) return false;
        int24 spacing = factory.feeAmountTickSpacing(p.fee);
        if (spacing <= 0 || spacing > PoolMath.MAX_TICK_SPACING) return false;
        (int24 lower, int24 upper) = PoolMath.fullRangeTicks(spacing);
        return p.tickLower == lower && p.tickUpper == upper;
    }

    /**
     * @notice 런칭 계획(record의 .pool)에서 런칭 포지션 유동성의 하한을 계산.
     * @dev 런칭 multicall의 mint는 amount0Min·amount1Min(목표 × (1 − slippageBps))을 강제하므로 그 포지션의 유동성은
     *      PoolMath.minFullRangeLiquidity(amount0Min, amount1Min) 이상. FIRE를 런칭 전에 가질 수 없는 제3자가
     *      배포 지갑으로 보내는 소액 포지션(유동성이 수억 분의 1)과 런칭 포지션을 구별하는 기준.
     */
    function planMinLiquidity(bool fireIsToken0, uint256 lpFireAmount, uint256 seedEth, uint256 slippageBps)
        internal
        pure
        returns (uint256)
    {
        (uint256 amount0, uint256 amount1) = fireIsToken0 ? (lpFireAmount, seedEth) : (seedEth, lpFireAmount);
        return PoolMath.minFullRangeLiquidity(
            PoolMath.minAmount(amount0, slippageBps), PoolMath.minAmount(amount1, slippageBps)
        );
    }

    /**
     * @notice owner가 보유한 NFT 중 유동성이 있는 (token0, token1[, fee]) 전체 범위 포지션을 찾음.
     * @dev ERC721Enumerable 인덱스 0(가장 오래된 것)부터 최대 maxScan개를 확인. Uniswap V3 NPM(OpenZeppelin 3.4 ERC721)은
     *      새로 받은 NFT를 목록 끝에 붙이고 보낸 NFT 자리에만 마지막 것을 옮겨 오므로, 런칭 뒤에 제3자가 배포 지갑으로 NFT를
     *      아무리 많이 보내도 런칭 포지션은 그 앞자리에 남음. 런칭 전에(배포 지갑 주소는 자금을 받을 때부터 공개) maxScan개
     *      이상을 먼저 보내 두면 런칭 포지션이 탐색 범위 밖에 놓이므로, 호출자는 이때(held > maxScan) LP_TOKEN_ID 지정을
     *      안내함(지정한 id도 같은 런칭 크기 검사를 거침). 락커처럼 NFT가 많은 주소는 대상이 아님.
     *      런칭 포지션은 "가장 최근 id"가 아니라 유동성으로 고름: 하한(minLiquidity) 이상 중 가장 큰 것.
     *      minLiquidity가 0이면 유동성이 있는 모든 포지션이 대상.
     */
    function find(
        INonfungiblePositionManager npm,
        IUniswapV3Factory factory,
        address owner,
        address token0,
        address token1,
        uint24 fee,
        uint256 minLiquidity,
        uint256 maxScan
    ) internal view returns (Search memory s) {
        uint256 balance = npm.balanceOf(owner);
        s.held = balance;
        uint256 end = balance < maxScan ? balance : maxScan;
        for (uint256 i; i < end; ++i) {
            uint256 id = npm.tokenOfOwnerByIndex(owner, i);
            (bool exists, Position memory p) = read(npm, id);
            if (!exists || p.liquidity == 0 || !isFullRange(factory, p, token0, token1, fee)) continue;
            ++s.matches;
            if (p.liquidity < minLiquidity) continue;
            ++s.eligible;
            if (p.liquidity > s.liquidity) (s.tokenId, s.liquidity) = (id, p.liquidity);
        }
    }
}
