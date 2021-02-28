// SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.8.0;

import '@solidstate/contracts/utils/Math.sol';
import { ExponentLib } from "./libraries/ExponentLib.sol";
import { FixidityLib } from "./libraries/FixidityLib.sol";
import { LogarithmLib } from "./libraries/LogarithmLib.sol";

contract OracleMath {

    function logreturns(uint256 close, uint256 close_1back) internal pure returns (uint256){
        return uint256(LogarithmLib.log_b(10, int256(close/close_1back)));
    }

    function rollingEma(uint256 _old, uint256 _current, uint256 alpha) internal pure returns (uint256){
        return alpha * (_current - _old) + _old;
    }

    function rollingAvg(uint256 _old, uint256 _current, uint256 _window) internal pure returns (uint256 updated) {
        return _old + (_current - _old)/_window;
    }

    function rollingVar(uint256 _old, uint256 _last, uint256 _oldaverage, uint256 _newaverage, uint256 _lastvariance, uint256 _window) internal pure returns (uint256 updated) {
        return _lastvariance + (_last - _old) * (_last - _newaverage + _old - _oldaverage)/(_window - 1);
    }

    function rollingStd(uint256 _old, uint256 _last, uint256 _oldaverage, uint256 _newaverage, uint256 _lastvariance, uint256 _window) internal pure returns (uint256 updated) {
        return sqrt(rollingVar(_old, _last, _oldaverage, _newaverage, _lastvariance, _window));
    }

    function p(uint256 _std, uint256 _strike, uint256 _price, uint256 _days) internal pure returns (uint256) {
        return (uint256(LogarithmLib.ln(int256(_strike/_price))) + (_std**2)/2 * _days)/sqrt(_std**2*_days);
    }

    function bsPrice(uint256 _std, uint256 _strike, uint256 _price, uint256 _timestamp) internal pure returns (uint256) {
        require(timestamp > block.timestamp, 'Option in the past');
        uint256 maturity = (_timestamp - block.timestamp) / (1 days);
        uint256 prob = p(_std, _strike, _price, maturity);
        return _price * prob - _strike * ExponentLib.powerE(int256(maturity)) * prob;
    }

    function slippageFn(uint256 Ct, uint256 St, uint256 St1) internal pure returns (uint256){
        int256 exp = (int256(St1) - int256(St)) / int256(max(St, St1));
        return Ct * FixidityLib.reciprocal(ExponentLib.powerE());
    }

    function pT(uint256 _std, uint256 _strike, uint256 _price, uint256 _timestamp){
        return cT() * bsPrice(_std, _strike, _price, _timestamp);
    }

    function sqrt(uint256 x) internal pure returns (uint256 y) {
        uint256 z = (x + 1) / 2;
        y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
    }
    
    function max(uint256 a, uint256 b) private pure returns (uint256) {
        return a > b ? a : b;
    }
}
