// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import './PremiaLiquidityPool.sol';

contract PremiaUnhedgedPool is PremiaLiquidityPool {
  constructor(address _controller) PremiaLiquidityPool(_controller) {}

  function getLoanableAmount(address _token, uint256 _lockExpiration) public override returns (uint256) {
    return 0;
  }

  function borrow(address _token, uint256 _amountToken, address _collateralToken, uint256 _amountCollateral, uint256 _lockExpiration) external override {
    revert();
  }

  function repay(bytes32 _hash, uint256 _amount) public override {
    revert();
  }

  function liquidate(bytes32 _hash, uint256 _collateralAmount, IUniswapV2Router02 _router) public override {
    revert();
  }
}