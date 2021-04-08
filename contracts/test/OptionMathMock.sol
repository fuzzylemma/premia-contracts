// SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.8.0;

import {OptionMath} from "../libraries/OptionMath.sol";

contract OptionMathMock {
  function rollingEma (
    int128 today64x64,
    int128 yesterday64x64,
    uint256 window
  ) external pure returns (int128) {
    return OptionMath.rollingEma(today64x64, yesterday64x64, window);
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

  function N (
    int128 x
  ) external pure returns (int128) {
    return OptionMath.N(x);
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
