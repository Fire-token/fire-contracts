// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/**
 * @title PoolMath
 * @dev Uniswap V3 풀 생성용 순수 수학 함수. Uniswap 코드를 복사하지 않고 OpenZeppelin Math(mulDiv, sqrt)로 구현.
 *      경계 상수(MIN/MAX_TICK, MIN/MAX_SQRT_RATIO)는 Uniswap V3 TickMath가 공개한 값과 동일함.
 */
library PoolMath {
    error PoolMathIdenticalTokens();
    error PoolMathZeroAddress();
    error PoolMathZeroAmount();
    error PoolMathPriceOutOfRange(uint256 amount0, uint256 amount1);
    error PoolMathInvalidTickSpacing(int24 tickSpacing);
    error PoolMathInvalidBps(uint256 bps);
    error PoolMathZeroPrice();

    int24 internal constant MIN_TICK = -887_272;
    int24 internal constant MAX_TICK = 887_272;
    /// @dev getSqrtRatioAtTick(MIN_TICK). 풀 초기화 가격은 이 값 이상이어야 함.
    uint160 internal constant MIN_SQRT_RATIO = 4_295_128_739;
    /// @dev getSqrtRatioAtTick(MAX_TICK). 풀 초기화 가격은 이 값 미만이어야 함.
    uint160 internal constant MAX_SQRT_RATIO = 1_461_446_703_485_210_103_287_273_052_203_988_822_378_723_970_342;
    /// @dev UniswapV3Factory가 허용하는 tickSpacing 상한(0 < tickSpacing < 16384).
    int24 internal constant MAX_TICK_SPACING = 16_383;

    uint256 internal constant Q96 = 1 << 96;
    uint256 internal constant Q192 = 1 << 192;
    uint256 internal constant BPS = 10_000;
    uint256 internal constant WAD = 1e18;
    /// @dev priceDeviationBps가 "2배 이상 차이"일 때 반환하는 포화값.
    uint256 internal constant DEVIATION_SATURATED = type(uint256).max;

    /// @notice Uniswap 규칙대로 주소가 작은 토큰이 token0.
    function sortTokens(address tokenA, address tokenB) internal pure returns (address token0, address token1) {
        if (tokenA == tokenB) revert PoolMathIdenticalTokens();
        (token0, token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        if (token0 == address(0)) revert PoolMathZeroAddress();
    }

    /**
     * @notice 예치 수량 비율로 초기 가격을 정함: sqrtPriceX96 = floor(sqrt(amount1 * 2^192 / amount0)).
     * @dev 오버플로 안전성:
     *      - amount1 * 2^192는 최대 2^448이지만 Math.mulDiv가 512비트 중간값으로 계산하므로 곱셈 단계는 넘치지 않음.
     *      - 몫 floor(amount1 * 2^192 / amount0)가 2^256 이상이 되는 경우는 amount1 >= amount0 * 2^64일 때뿐이며,
     *        이는 (amount1 >> 64) >= amount0 과 정확히 동치이므로 mulDiv 호출 전에 명시적으로 거부함.
     *      - 몫 < 2^256 이므로 sqrt 결과 < 2^128 < MAX_SQRT_RATIO(약 2^160.0) → 상한은 자동 충족, uint160 변환 안전.
     *      - 하한: 결과가 MIN_SQRT_RATIO(약 2^32) 미만, 즉 가격이 약 2^-128 미만이면 Uniswap이 초기화를 거부하므로 거부함.
     *      - 내림 오차: mulDiv와 sqrt 각각 내림 → 실제 가격 대비 상대 오차 < 2 / sqrtPriceX96 (MIN 근처에서도 < 1e-9).
     */
    function encodeSqrtPriceX96(uint256 amount0, uint256 amount1) internal pure returns (uint160 sqrtPriceX96) {
        if (amount0 == 0 || amount1 == 0) revert PoolMathZeroAmount();
        if ((amount1 >> 64) >= amount0) revert PoolMathPriceOutOfRange(amount0, amount1);
        uint256 root = Math.sqrt(Math.mulDiv(amount1, Q192, amount0));
        if (root < MIN_SQRT_RATIO) revert PoolMathPriceOutOfRange(amount0, amount1);
        sqrtPriceX96 = SafeCast.toUint160(root);
    }

    /**
     * @notice 전체 범위(Full Range) 포지션의 틱 경계.
     * @dev tickLower = (MIN_TICK / tickSpacing) * tickSpacing. Solidity의 정수 나눗셈은 0 방향 절삭이므로
     *      음수 MIN_TICK에 대해 "올림" 효과가 나서 결과는 MIN_TICK 이상인 가장 작은 tickSpacing의 배수가 됨.
     *      tickUpper = -tickLower 는 MAX_TICK 이하인 가장 큰 배수 (MIN_TICK = -MAX_TICK 이므로 대칭).
     *      예) tickSpacing 200 → ±887200, 60 → ±887220.
     */
    function fullRangeTicks(int24 tickSpacing) internal pure returns (int24 tickLower, int24 tickUpper) {
        if (tickSpacing <= 0 || tickSpacing > MAX_TICK_SPACING) revert PoolMathInvalidTickSpacing(tickSpacing);
        tickLower = (MIN_TICK / tickSpacing) * tickSpacing;
        tickUpper = -tickLower;
    }

    /// @notice 슬리피지 하한: floor(amount * (10000 - bps) / 10000).
    function minAmount(uint256 amount, uint256 slippageBps) internal pure returns (uint256) {
        if (slippageBps > BPS) revert PoolMathInvalidBps(slippageBps);
        return Math.mulDiv(amount, BPS - slippageBps, BPS);
    }

    /**
     * @notice amount0 ≥ amount0Min, amount1 ≥ amount1Min으로 발행된 전체 범위 포지션의 유동성 L 하한 (가격과 무관).
     * @dev 전체 범위에서 풀 가격 √P(= sqrtPriceX96 / 2^96)일 때 Uniswap V3 SqrtPriceMath가 예치량을 올림으로 계산하므로
     *        amount0 ≤ L / √P + 2,  amount1 ≤ L · √P + 1
     *      이고, 두 식을 곱하면 (amount0 − 2)(amount1 − 1) < L². 따라서 mint의 amountMin 검사를 통과한 포지션은
     *      어떤 가격에서 발행됐든 L ≥ ⌊√((amount0Min − 2)(amount1Min − 1))⌋. 런칭 multicall이 만든 포지션만 이 값을
     *      넘을 수 있고(제3자는 런칭 전에 FIRE를 가질 수 없음), 누구나 배포 지갑으로 보낼 수 있는 소액 포지션은 걸러짐.
     */
    function minFullRangeLiquidity(uint256 amount0Min, uint256 amount1Min) internal pure returns (uint256) {
        if (amount0Min <= 2 || amount1Min <= 1) return 0;
        (bool ok, uint256 product) = Math.tryMul(amount0Min - 2, amount1Min - 1);
        // 곱이 2^256을 넘는 계획은 유동성(uint128)으로 만들 수 없음 → 어떤 포지션도 통과하지 못하는 값
        if (!ok) return type(uint128).max;
        return Math.sqrt(product);
    }

    /// @notice 하한 L에서 bps만큼 뺀 값: floor(L * (10000 - bps) / 10000). 락커 수수료(LaunchParams.MAX_LOCK_FEE_BPS) 허용용.
    function liquidityFloor(uint256 minLiquidity, uint256 allowanceBps) internal pure returns (uint256) {
        if (allowanceBps > BPS) revert PoolMathInvalidBps(allowanceBps);
        return Math.mulDiv(minLiquidity, BPS - allowanceBps, BPS);
    }

    /**
     * @notice 두 sqrt 가격 사이의 "가격" 편차 |P/Ptarget - 1|을 bps로(올림) 반환.
     * @dev r = s/t를 18자리 고정소수점으로 구한 뒤 제곱. s < 2^160, t >= 1 이므로 mulDiv(s, 1e18, t) < 2^220.
     *      r >= 2 (가격 4배 이상 차이)이면 정밀 계산 없이 포화값을 반환해 r^2 계산의 범위를 묶어 둠.
     */
    function priceDeviationBps(uint160 sqrtPriceX96, uint160 targetSqrtPriceX96) internal pure returns (uint256) {
        if (targetSqrtPriceX96 == 0) revert PoolMathZeroPrice();
        uint256 ratio = Math.mulDiv(sqrtPriceX96, WAD, targetSqrtPriceX96);
        if (ratio >= 2 * WAD) return DEVIATION_SATURATED;
        uint256 priceRatio = Math.mulDiv(ratio, ratio, WAD);
        uint256 diff = priceRatio > WAD ? priceRatio - WAD : WAD - priceRatio;
        return Math.mulDiv(diff, BPS, WAD, Math.Rounding.Ceil);
    }

    /// @notice token0 1개(최소 단위 10^18개)당 token1 수량을 18자리 고정소수점으로: sqrtP^2 / 2^192 * 1e18.
    function price0In1Wad(uint160 sqrtPriceX96) internal pure returns (uint256) {
        return Math.mulDiv(Math.mulDiv(sqrtPriceX96, sqrtPriceX96, Q96), WAD, Q96);
    }

    /// @notice token1 1개당 token0 수량(18자리): 2^192 / sqrtP^2 * 1e18. sqrtP >= MIN_SQRT_RATIO 가정.
    function price1In0Wad(uint160 sqrtPriceX96) internal pure returns (uint256) {
        if (sqrtPriceX96 == 0) revert PoolMathZeroPrice();
        return Math.mulDiv(Math.mulDiv(WAD, Q96, sqrtPriceX96), Q96, sqrtPriceX96);
    }
}
