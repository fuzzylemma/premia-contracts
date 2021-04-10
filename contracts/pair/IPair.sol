// SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.8.0;

interface IPair {
  /**
   * @notice calculate or get cached variance for current period
   * @return variance64x64 64x64 fixed point representation of EMA of annualized variance
   */
  function getVariance () external view returns (int128 variance64x64);
}
