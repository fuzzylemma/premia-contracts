// SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.8.0;

import {OptionMath} from "../libraries/OptionMath.sol";

contract OptionMathMock {
  function logreturns (
    int128 today64x64,
    int128 yesterday64x64
  ) external pure returns (int128) {
    return OptionMath.logreturns(today64x64, yesterday64x64);
  }

  function rollingEma (
    int128 oldValue64x64,
    int128 newValue64x64,
    uint256 window
  ) external pure returns (int128) {
    return OptionMath.rollingEma(oldValue64x64, newValue64x64, window);
  }

  function rollingEmaVariance (
    int128 today64x64,
    int128 yesterdayEma64x64,
    int128 yesterdayEmaVariance64x64,
    uint256 window
  ) external pure returns (int128) {
    return OptionMath.rollingEmaVariance(
      today64x64,
      yesterdayEma64x64,
      yesterdayEmaVariance64x64,
      window
    );
  }

  function d1 (
    int128 variance,
    int128 strike,
    int128 price,
    int128 timeToMaturity
  ) external pure returns (int128) {
    return OptionMath.d1(variance, strike, price, timeToMaturity);
  }

  function N (
    int128 x
  ) external pure returns (int128) {
    return OptionMath.N(x);
  }

  function Xt (
    int128 oldPoolState,
    int128 newPoolState
  ) external pure returns (int128) {
    return OptionMath.Xt(oldPoolState, newPoolState);
  }

  function slippageCoefficient (
    int128 oldPoolState,
    int128 newPoolState,
    int128 steepness
  ) external pure returns (int128) {
    return OptionMath.slippageCoefficient(oldPoolState, newPoolState, steepness);
  }

  function bsPrice (
    int128 variance,
    int128 strike,
    int128 price,
    int128 timeToMaturity,
    bool isCall
  ) external pure returns (int128) {
    return OptionMath.bsPrice(variance, strike, price, timeToMaturity, isCall);
  }

  function calculateTradingDelta (
    int128 oldPoolState,
    int128 newPoolState,
    int128 steepness
  ) external pure returns (int128) {
    return OptionMath.calculateTradingDelta(oldPoolState, newPoolState, steepness);
  }

  function calculateCLevel (
    int128 initialCLevel,
    int128 oldPoolState,
    int128 newPoolState,
    int128 steepness
  ) external pure returns (int128) {
    return OptionMath.calculateCLevel(initialCLevel, oldPoolState, newPoolState, steepness);
  }

  function quotePrice (
    int128 variance,
    int128 strike,
    int128 price,
    int128 timeToMaturity,
    int128 cLevel,
    int128 oldPoolState,
    int128 newPoolState,
    int128 steepness,
    bool isCall
  ) external pure returns (int128) {
    return OptionMath.quotePrice(
      variance,
      strike,
      price,
      timeToMaturity,
      cLevel,
      oldPoolState,
      newPoolState,
      steepness,
      isCall
    );
  }
}
