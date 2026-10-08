// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {PoolMath} from "../script/lib/PoolMath.sol";

/// @dev 라이브러리 internal 함수의 revert를 vm.expectRevert로 확인하기 위한 외부 호출 래퍼.
contract DeployPoolMathHarness {
    function encodeSqrtPriceX96(uint256 amount0, uint256 amount1) external pure returns (uint160) {
        return PoolMath.encodeSqrtPriceX96(amount0, amount1);
    }

    function fullRangeTicks(int24 tickSpacing) external pure returns (int24, int24) {
        return PoolMath.fullRangeTicks(tickSpacing);
    }

    function sortTokens(address tokenA, address tokenB) external pure returns (address, address) {
        return PoolMath.sortTokens(tokenA, tokenB);
    }

    function minAmount(uint256 amount, uint256 slippageBps) external pure returns (uint256) {
        return PoolMath.minAmount(amount, slippageBps);
    }

    function priceDeviationBps(uint160 sqrtPriceX96, uint160 target) external pure returns (uint256) {
        return PoolMath.priceDeviationBps(sqrtPriceX96, target);
    }

    function price0In1Wad(uint160 sqrtPriceX96) external pure returns (uint256) {
        return PoolMath.price0In1Wad(sqrtPriceX96);
    }

    function price1In0Wad(uint160 sqrtPriceX96) external pure returns (uint256) {
        return PoolMath.price1In0Wad(sqrtPriceX96);
    }

    function minFullRangeLiquidity(uint256 amount0Min, uint256 amount1Min) external pure returns (uint256) {
        return PoolMath.minFullRangeLiquidity(amount0Min, amount1Min);
    }

    function liquidityFloor(uint256 minLiquidity, uint256 allowanceBps) external pure returns (uint256) {
        return PoolMath.liquidityFloor(minLiquidity, allowanceBps);
    }
}

/**
 * @dev 기대값은 두 가지 독립 경로로 확인:
 *      (1) Python 임의 정밀도 정수(math.isqrt)로 미리 계산한 고정 벡터,
 *      (2) 512비트 곱셈으로 바닥 제곱근의 정의 s^2·a0 ≤ a1·2^192 < (s+1)^2·a0 를 직접 검사(퍼즈).
 *      어느 쪽도 PoolMath가 쓰는 Math.mulDiv / Math.sqrt에 의존하지 않음.
 */
contract PoolMathTest is Test {
    DeployPoolMathHarness internal h;

    uint256 internal constant E18 = 1e18;
    uint256 internal constant LP_FIRE = 700_000_000e18;
    uint256 internal constant SEED_ETH = 3 ether;
    uint256 internal constant Q192 = 1 << 192;

    // Python: isqrt(a1 * 2**192 // a0)
    uint160 internal constant SQRT_WETH0_3ETH_700M = 1_210_230_172_979_597_097_089_260_854_307_451;
    uint160 internal constant SQRT_FIRE0_700M_3ETH = 5_186_700_741_341_130_416_096_832;
    uint160 internal constant SQRT_WETH0_1ETH_700M = 2_096_180_148_453_533_211_898_198_031_677_635;
    uint160 internal constant SQRT_FIRE0_700M_5ETH = 6_696_001_864_325_287_039_494_348;
    uint160 internal constant SQRT_NEAR_UPPER = 340_282_366_920_938_463_454_151_235_394_913_435_647; // (1, 2^64-1)
    uint160 internal constant SQRT_2POW127_TO_1 = 6_074_000_999; // (2^127, 1)
    uint160 internal constant SQRT_BIG_MIXED = 7_922_816_251_426_433_759_354_395_033_600_000; // (1e30, 1e40)

    function setUp() public {
        h = new DeployPoolMathHarness();
    }

    // ───────────────────────── 512비트 기준 구현 ─────────────────────────

    function _mul512(uint256 a, uint256 b) internal pure returns (uint256 hi, uint256 lo) {
        assembly ("memory-safe") {
            let mm := mulmod(a, b, not(0))
            lo := mul(a, b)
            hi := sub(sub(mm, lo), lt(mm, lo))
        }
    }

    function _lt512(uint256 aHi, uint256 aLo, uint256 bHi, uint256 bLo) internal pure returns (bool) {
        return aHi < bHi || (aHi == bHi && aLo < bLo);
    }

    function _add512(uint256 aHi, uint256 aLo, uint256 bHi, uint256 bLo)
        internal
        pure
        returns (uint256 hi, uint256 lo)
    {
        unchecked {
            lo = aLo + bLo;
            hi = aHi + bHi + (lo < aLo ? 1 : 0);
        }
    }

    /// @dev a1·2^192 을 512비트 (hi, lo)로.
    function _shifted(uint256 a1) internal pure returns (uint256 hi, uint256 lo) {
        hi = a1 >> 64;
        lo = a1 << 192;
    }

    /// @dev s가 floor(sqrt(a1·2^192 / a0))인지 정의로 검사: s^2·a0 ≤ a1·2^192 < (s+1)^2·a0.
    function _assertFloorSqrt(uint256 s, uint256 a0, uint256 a1) internal pure {
        assertLt(s, 1 << 128, "s >= 2^128");
        (uint256 rHi, uint256 rLo) = _shifted(a1);
        (uint256 lHi, uint256 lLo) = _mul512(s * s, a0);
        assertFalse(_lt512(rHi, rLo, lHi, lLo), "s^2*a0 > a1*2^192");
        (uint256 eHi, uint256 eLo) = _mul512(2 * s + 1, a0);
        (uint256 uHi, uint256 uLo) = _add512(lHi, lLo, eHi, eLo);
        assertTrue(_lt512(rHi, rLo, uHi, uLo), "(s+1)^2*a0 <= a1*2^192");
    }

    /// @dev 독립 판정: 가격이 Uniswap 범위를 벗어나는가.
    ///      상한: a1·2^192 ≥ a0·2^256 (몫이 2^256 이상), 하한: a1·2^192 < MIN_SQRT_RATIO^2·a0.
    function _outOfRange(uint256 a0, uint256 a1) internal pure returns (bool) {
        (uint256 rHi, uint256 rLo) = _shifted(a1);
        if (!_lt512(rHi, rLo, a0, 0)) return true;
        uint256 minSq = uint256(PoolMath.MIN_SQRT_RATIO) * PoolMath.MIN_SQRT_RATIO;
        (uint256 mHi, uint256 mLo) = _mul512(minSq, a0);
        return _lt512(rHi, rLo, mHi, mLo);
    }

    // ───────────────────────── encodeSqrtPriceX96 ─────────────────────────

    function test_EncodeSqrtPrice_KnownVectors() public view {
        assertEq(h.encodeSqrtPriceX96(1, 1), 1 << 96);
        assertEq(h.encodeSqrtPriceX96(type(uint256).max, type(uint256).max), 1 << 96);
        assertEq(h.encodeSqrtPriceX96(1 ether, 700_000_000e18), SQRT_WETH0_1ETH_700M);
        assertEq(h.encodeSqrtPriceX96(700_000_000e18, 5 ether), SQRT_FIRE0_700M_5ETH);
        assertEq(h.encodeSqrtPriceX96(1, type(uint64).max), SQRT_NEAR_UPPER);
        assertEq(h.encodeSqrtPriceX96(1 << 127, 1), SQRT_2POW127_TO_1);
        assertEq(h.encodeSqrtPriceX96(1e30, 1e40), SQRT_BIG_MIXED);
    }

    /// @dev 런칭 파라미터(3 ETH + 7억 FIRE)를 두 토큰 순서 모두로 확인.
    function test_EncodeSqrtPrice_LaunchParams_BothOrderings() public view {
        // WETH(0x4200…) < FIRE 인 경우: token0 = WETH, token1 = FIRE
        uint160 wethFirst = h.encodeSqrtPriceX96(SEED_ETH, LP_FIRE);
        assertEq(wethFirst, SQRT_WETH0_3ETH_700M);
        _assertFloorSqrt(wethFirst, SEED_ETH, LP_FIRE);
        // FIRE < WETH 인 경우: token0 = FIRE, token1 = WETH
        uint160 fireFirst = h.encodeSqrtPriceX96(LP_FIRE, SEED_ETH);
        assertEq(fireFirst, SQRT_FIRE0_700M_3ETH);
        _assertFloorSqrt(fireFirst, LP_FIRE, SEED_ETH);

        // 두 순서 모두 1 FIRE = 3/700,000,000 ETH ≈ 0.000000004285714285 ETH
        assertEq(h.price0In1Wad(fireFirst), 4_285_714_285);
        assertEq(h.price1In0Wad(wethFirst), 4_285_714_285);
        assertEq(h.price0In1Wad(wethFirst), 233_333_333_333_333_333_333_333_333); // FIRE per WETH
    }

    function test_RevertWhen_EncodeZeroAmount() public {
        vm.expectRevert(PoolMath.PoolMathZeroAmount.selector);
        h.encodeSqrtPriceX96(0, 1);
        vm.expectRevert(PoolMath.PoolMathZeroAmount.selector);
        h.encodeSqrtPriceX96(1, 0);
    }

    function test_RevertWhen_PriceAboveRange() public {
        // a1/a0 = 2^64 → 몫 = 2^256 (표현 불가) → 명시적으로 거부
        vm.expectRevert(abi.encodeWithSelector(PoolMath.PoolMathPriceOutOfRange.selector, 1, uint256(1) << 64));
        h.encodeSqrtPriceX96(1, uint256(1) << 64);
        vm.expectRevert(abi.encodeWithSelector(PoolMath.PoolMathPriceOutOfRange.selector, 1, type(uint256).max));
        h.encodeSqrtPriceX96(1, type(uint256).max);
    }

    function test_RevertWhen_PriceBelowRange() public {
        // sqrt(2^-128)·2^96 = 2^32 < MIN_SQRT_RATIO
        vm.expectRevert(abi.encodeWithSelector(PoolMath.PoolMathPriceOutOfRange.selector, uint256(1) << 128, 1));
        h.encodeSqrtPriceX96(uint256(1) << 128, 1);
        vm.expectRevert(abi.encodeWithSelector(PoolMath.PoolMathPriceOutOfRange.selector, type(uint256).max, 1));
        h.encodeSqrtPriceX96(type(uint256).max, 1);
    }

    /// @dev 전 구간 퍼즈: 범위 안이면 정의를 만족하고 Uniswap 경계 안, 범위 밖이면 정확히 그 에러로 revert.
    function testFuzz_EncodeSqrtPrice_MatchesDefinition(uint256 amount0, uint256 amount1) public {
        amount0 = bound(amount0, 1, type(uint256).max);
        amount1 = bound(amount1, 1, type(uint256).max);
        _checkEncode(amount0, amount1);
    }

    /// @dev 자릿수(2^0 ~ 2^255)를 고르게 퍼뜨려 극단 비율을 집중적으로 탐색.
    function testFuzz_EncodeSqrtPrice_LogScale(uint256 x, uint256 y, uint8 shiftX, uint8 shiftY) public {
        uint256 amount0 = (x >> shiftX) | 1;
        uint256 amount1 = (y >> shiftY) | 1;
        _checkEncode(amount0, amount1);
    }

    function _checkEncode(uint256 amount0, uint256 amount1) internal {
        if (_outOfRange(amount0, amount1)) {
            vm.expectRevert(abi.encodeWithSelector(PoolMath.PoolMathPriceOutOfRange.selector, amount0, amount1));
            h.encodeSqrtPriceX96(amount0, amount1);
            return;
        }
        uint160 s = h.encodeSqrtPriceX96(amount0, amount1);
        _assertFloorSqrt(s, amount0, amount1);
        assertGe(s, PoolMath.MIN_SQRT_RATIO);
        assertLt(s, PoolMath.MAX_SQRT_RATIO);
    }

    /// @dev 토큰 순서를 바꾸면 가격은 역수: s0·s1 ≤ 2^192 이고 그 차이는 내림 오차(≈ s0 + s1) 이내.
    function testFuzz_EncodeSqrtPrice_OrderingIsReciprocal(uint256 fire, uint256 eth) public view {
        // 두 순서 모두 유효하려면 비율이 (2^-64, 2^64) 안이어야 함 → 1e-18 ~ 1e18 배로 제한 (1e18 < 2^64).
        fire = bound(fire, 1, 1e36);
        eth = bound(eth, fire / 1e18 + 1, fire * 1e18);
        uint256 s0 = h.encodeSqrtPriceX96(fire, eth); // FIRE = token0
        uint256 s1 = h.encodeSqrtPriceX96(eth, fire); // FIRE = token1
        (uint256 hi, uint256 product) = _mul512(s0, s1);
        assertEq(hi, 0);
        assertLe(product, Q192);
        assertLe(Q192 - product, s0 + s1 + 4);
    }

    function testFuzz_EncodeSqrtPrice_MonotonicInAmount1(uint256 amount0, uint256 a, uint256 b) public view {
        amount0 = bound(amount0, 1, 1e36);
        a = bound(a, amount0 / 1e18 + 1, amount0 * 1e18);
        b = bound(b, a, amount0 * 1e18);
        assertLe(h.encodeSqrtPriceX96(amount0, a), h.encodeSqrtPriceX96(amount0, b));
    }

    // ───────────────────────── fullRangeTicks ─────────────────────────

    function test_FullRangeTicks_KnownSpacings() public view {
        _assertTicks(1, -887_272, 887_272);
        _assertTicks(10, -887_270, 887_270);
        _assertTicks(60, -887_220, 887_220); // fee 3000
        _assertTicks(200, -887_200, 887_200); // fee 10000
    }

    function _assertTicks(int24 spacing, int24 lower, int24 upper) internal view {
        (int24 l, int24 u) = h.fullRangeTicks(spacing);
        assertEq(l, lower);
        assertEq(u, upper);
    }

    /// @dev 독립 계산: 양수 정수 산술로 MAX_TICK 이하 최대 배수를 구해 부호만 뒤집어 비교.
    function testFuzz_FullRangeTicks(int24 spacing) public view {
        spacing = int24(bound(spacing, 1, PoolMath.MAX_TICK_SPACING));
        (int24 lower, int24 upper) = h.fullRangeTicks(spacing);
        uint256 s = uint256(uint24(spacing));
        uint256 expectedUpper = (887_272 / s) * s;
        assertEq(uint256(uint24(upper)), expectedUpper);
        assertEq(lower, -upper);
        assertEq(lower % spacing, 0);
        assertGe(lower, PoolMath.MIN_TICK);
        assertLe(upper, PoolMath.MAX_TICK);
        assertLt(int256(lower) - spacing, PoolMath.MIN_TICK);
        assertGt(int256(upper) + spacing, PoolMath.MAX_TICK);
    }

    function test_RevertWhen_InvalidTickSpacing() public {
        int24[4] memory bad = [int24(0), int24(-1), int24(16_384), type(int24).max];
        for (uint256 i; i < bad.length; ++i) {
            vm.expectRevert(abi.encodeWithSelector(PoolMath.PoolMathInvalidTickSpacing.selector, bad[i]));
            h.fullRangeTicks(bad[i]);
        }
    }

    // ───────────────────────── sortTokens ─────────────────────────

    function test_SortTokens_BothOrders() public view {
        address weth = 0x4200000000000000000000000000000000000006;
        address low = address(0x1000);
        address high = address(0xf000000000000000000000000000000000000000);
        (address t0, address t1) = h.sortTokens(high, weth);
        assertEq(t0, weth);
        assertEq(t1, high);
        (t0, t1) = h.sortTokens(weth, high);
        assertEq(t0, weth);
        assertEq(t1, high);
        (t0, t1) = h.sortTokens(low, weth);
        assertEq(t0, low);
        assertEq(t1, weth);
    }

    function test_RevertWhen_SortIdenticalOrZero() public {
        vm.expectRevert(PoolMath.PoolMathIdenticalTokens.selector);
        h.sortTokens(address(1), address(1));
        vm.expectRevert(PoolMath.PoolMathZeroAddress.selector);
        h.sortTokens(address(0), address(1));
    }

    function testFuzz_SortTokens(address a, address b) public view {
        vm.assume(a != b && a != address(0) && b != address(0));
        (address t0, address t1) = h.sortTokens(a, b);
        assertLt(uint160(t0), uint160(t1));
        assertTrue((t0 == a && t1 == b) || (t0 == b && t1 == a));
    }

    // ───────────────────────── minAmount ─────────────────────────

    function test_MinAmount() public {
        assertEq(h.minAmount(LP_FIRE, 50), 696_500_000e18);
        assertEq(h.minAmount(SEED_ETH, 50), 2.985 ether);
        assertEq(h.minAmount(1000, 10_000), 0);
        assertEq(h.minAmount(type(uint256).max, 0), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(PoolMath.PoolMathInvalidBps.selector, 10_001));
        h.minAmount(1, 10_001);
    }

    function testFuzz_MinAmount(uint256 amount, uint256 bps) public view {
        amount = bound(amount, 0, type(uint256).max / 10_000);
        bps = bound(bps, 0, 10_000);
        uint256 m = h.minAmount(amount, bps);
        assertEq(m, amount * (10_000 - bps) / 10_000);
        assertLe(m, amount);
    }

    // ───────────────────────── priceDeviationBps ─────────────────────────

    function test_PriceDeviation_KnownValues() public {
        uint160 t = SQRT_FIRE0_700M_3ETH;
        assertEq(h.priceDeviationBps(t, t), 0);
        // Python 기준값 (|s^2 - t^2| · 10000 / t^2 올림)
        assertEq(h.priceDeviationBps(5_212_634_245_047_836_068_177_316, t), 101); // sqrt +0.5% → 가격 +1.0025%
        assertEq(h.priceDeviationBps(5_160_767_237_634_424_764_016_347, t), 100); // sqrt -0.5%
        assertEq(h.priceDeviationBps(5_212_115_574_973_701_955_135_706, t), 99);
        assertEq(h.priceDeviationBps(t * 2 - 1, t), 30_000); // 가격 거의 4배
        assertEq(h.priceDeviationBps(t * 2, t), type(uint256).max); // 포화
        assertEq(h.priceDeviationBps(type(uint160).max, PoolMath.MIN_SQRT_RATIO), type(uint256).max);
        vm.expectRevert(PoolMath.PoolMathZeroPrice.selector);
        h.priceDeviationBps(t, 0);
    }

    /// @dev 기준 구현: 제곱이 2^256 안에 들어가는 구간(s, t < 2^128)에서 |s^2 - t^2|·10000 / t^2 를 직접 계산.
    function testFuzz_PriceDeviation_MatchesReference(uint256 s, uint256 t) public view {
        t = bound(t, PoolMath.MIN_SQRT_RATIO, (1 << 128) - 1);
        s = bound(s, t / 2 + 1, Math.min(2 * t - 1, (1 << 128) - 1));
        uint256 dev = h.priceDeviationBps(uint160(s), uint160(t));
        uint256 diff = s > t ? s * s - t * t : t * t - s * s;
        uint256 expected = Math.mulDiv(diff, 10_000, t * t, Math.Rounding.Ceil);
        assertApproxEqAbs(dev, expected, 1);
    }

    function testFuzz_PriceDeviation_SaturatesAtDouble(uint160 t, uint160 s) public view {
        t = uint160(bound(t, 1, type(uint160).max / 2));
        s = uint160(bound(s, uint256(t) * 2, type(uint160).max));
        assertEq(h.priceDeviationBps(s, t), type(uint256).max);
    }

    // ───────────────────────── 가격 표시 ─────────────────────────

    // ── 런칭 포지션 유동성 하한 (리뷰 F3: 소액 포지션과 런칭 포지션 구별) ──

    /// @dev Uniswap V3 SqrtPriceMath와 같은 올림 계산으로 유동성 L의 예치량을 독립 구현 (sqrtA < sqrtP < sqrtB).
    function _amountsForLiquidity(uint160 sqrtP, uint128 liquidity) internal pure returns (uint256 a0, uint256 a1) {
        uint256 sqrtA = PoolMath.MIN_SQRT_RATIO;
        uint256 sqrtB = PoolMath.MAX_SQRT_RATIO;
        uint256 inner = Math.mulDiv(uint256(liquidity) << 96, sqrtB - sqrtP, sqrtB, Math.Rounding.Ceil);
        a0 = Math.ceilDiv(inner, sqrtP);
        a1 = Math.mulDiv(liquidity, sqrtP - sqrtA, 1 << 96, Math.Rounding.Ceil);
    }

    /// @dev 하한의 근거 (PoolMath NatSpec): 어떤 가격·유동성으로 발행된 전체 범위 포지션이든, 그 예치량을 amountMin으로 넣어
    ///      계산한 하한은 실제 유동성을 넘지 않음. 따라서 amountMin 검사를 통과한 런칭 포지션은 항상 하한 이상.
    function testFuzz_MinFullRangeLiquidity_NeverExceedsActualLiquidity(uint160 sqrtP, uint128 liquidity) public view {
        sqrtP = uint160(_bound(sqrtP, uint256(PoolMath.MIN_SQRT_RATIO) + 1, uint256(PoolMath.MAX_SQRT_RATIO) - 1));
        liquidity = uint128(_bound(liquidity, 1, type(uint128).max));
        (uint256 a0, uint256 a1) = _amountsForLiquidity(sqrtP, liquidity);
        assertLe(h.minFullRangeLiquidity(a0, a1), liquidity);
    }

    function test_MinFullRangeLiquidity_LaunchPlanAndEdges() public view {
        // 런칭 계획 (7억 FIRE + 3 ETH, 슬리피지 0.5%): 포크 실측 런칭 유동성 45,825,756,949,558,400,065,880 이하
        uint256 fireMin = 700_000_000e18 * 9950 / 10_000;
        uint256 ethMin = 3 ether * 9950 / 10_000;
        uint256 lMin = h.minFullRangeLiquidity(ethMin, fireMin);
        assertLe(lMin, 45_825_756_949_558_400_065_880);
        assertGt(lMin, uint256(45_825_756_949_558_400_065_880) * 994 / 1000);
        // 예치량이 거의 없으면 하한 0, 곱이 2^256을 넘는 계획은 어떤 포지션도 통과하지 못하는 값
        assertEq(h.minFullRangeLiquidity(2, 1e30), 0);
        assertEq(h.minFullRangeLiquidity(1e30, 1), 0);
        assertEq(h.minFullRangeLiquidity(type(uint256).max, type(uint256).max), type(uint128).max);
    }

    function test_LiquidityFloor() public {
        assertEq(h.liquidityFloor(10_000, 100), 9900);
        assertEq(h.liquidityFloor(10_001, 100), 9900); // 내림
        assertEq(h.liquidityFloor(10_000, 0), 10_000);
        assertEq(h.liquidityFloor(10_000, 10_000), 0);
        vm.expectRevert(abi.encodeWithSelector(PoolMath.PoolMathInvalidBps.selector, 10_001));
        h.liquidityFloor(1, 10_001);
    }

    function test_PriceDisplay_UnitPrice() public view {
        assertEq(h.price0In1Wad(uint160(1 << 96)), 1e18);
        assertEq(h.price1In0Wad(uint160(1 << 96)), 1e18);
    }

    function testFuzz_PriceDisplay_NoOverflowAcrossRange(uint160 s) public view {
        s = uint160(bound(s, PoolMath.MIN_SQRT_RATIO, PoolMath.MAX_SQRT_RATIO - 1));
        h.price0In1Wad(s);
        h.price1In0Wad(s);
    }
}
