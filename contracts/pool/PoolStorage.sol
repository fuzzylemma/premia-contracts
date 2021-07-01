// SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.8.0;

import {AggregatorInterface} from '@chainlink/contracts/src/v0.8/interfaces/AggregatorInterface.sol';
import {AggregatorV3Interface} from '@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol';
import {ERC1155EnumerableStorage} from '@solidstate/contracts/token/ERC1155/ERC1155EnumerableStorage.sol';

import {ABDKMath64x64} from 'abdk-libraries-solidity/ABDKMath64x64.sol';
import {ABDKMath64x64Token} from '../libraries/ABDKMath64x64Token.sol';
import {OptionMath} from '../libraries/OptionMath.sol';
import {Pool} from './Pool.sol';

library PoolStorage {
  // ToDo : Handle both  put and call for reserved liq
  enum TokenType {
    UNDERLYING_FREE_LIQ,
    BASE_FREE_LIQ,

    LONG_CALL,
    SHORT_CALL,

    LONG_PUT,
    SHORT_PUT,

    UNDERLYING_RESERVED_LIQ,
    BASE_RESERVED_LIQ
  }

  struct PoolSettings {
    address underlying;
    address base;
    address underlyingOracle;
    address baseOracle;
  }

  struct QuoteArgs {
    uint64 maturity; // timestamp of option maturity
    int128 strike64x64; // 64x64 fixed point representation of strike price
    int128 spot64x64; // 64x64 fixed point representation of spot price
    int128 emaVarianceAnnualized64x64; // 64x64 fixed point representation of annualized variance
    uint256 amount; // size of option contract
    bool isCall; // true for call, false for put
  }

  struct PurchaseArgs {
    uint64 maturity; // timestamp of option maturity
    int128 strike64x64; // 64x64 fixed point representation of strike price
    uint256 amount; // size of option contract
    uint256 maxCost; // maximum acceptable cost after accounting for slippage
    bool isCall; // true for call, false for put
  }

  struct BatchData {
    uint256 eta;
    uint256 totalPendingDeposits;
  }

  bytes32 internal constant STORAGE_SLOT = keccak256(
    'premia.contracts.storage.Pool'
  );

  struct Layout {
    // ERC20 token addresses
    address base;
    address underlying;

    // AggregatorV3Interface oracle addresses
    address baseOracle;
    address underlyingOracle;

    // token metadata
    uint8 underlyingDecimals;
    uint8 baseDecimals;

    int128 cLevelUnderlying64x64;
    int128 cLevelBase64x64;

    uint256 updatedAt;
    int128 emaLogReturns64x64;
    int128 emaVarianceAnnualized64x64;

    // User -> isCall -> depositedAt
    mapping (address => mapping(bool => uint256)) depositedAt;

    mapping (address => uint256) divestmentTimestamps;

    // doubly linked list of free liquidity intervals
    // isCall -> User -> User
    mapping (bool => mapping(address => address)) liquidityQueueAscending;
    mapping (bool => mapping(address => address)) liquidityQueueDescending;

    // TODO: enforced interval size for maturity (maturity % interval == 0)
    // updatable by owner

    // minimum resolution price bucket => price
    mapping (uint256 => int128) bucketPrices64x64;
    // sequence id (minimum resolution price bucket / 256) => price update sequence
    mapping (uint256 => uint256) priceUpdateSequences;

    // isCall -> batch data
    mapping(bool => BatchData) nextDeposits;
    // user -> batch timestamp -> isCall -> pending amount
    mapping(address => mapping(uint256 => mapping(bool => uint256))) pendingDeposits;
  }

  function layout () internal pure returns (Layout storage l) {
    bytes32 slot = STORAGE_SLOT;
    assembly { l.slot := slot }
  }

  /**
   * @notice calculate ERC1155 token id for given option parameters
   * @param tokenType TokenType enum
   * @param maturity timestamp of option maturity
   * @param strike64x64 64x64 fixed point representation of strike price
   * @return tokenId token id
   */
  function formatTokenId (
    TokenType tokenType,
    uint64 maturity,
    int128 strike64x64
  ) internal pure returns (uint256 tokenId) {
    // TODO: fix probably Hardhat issue related to usage of assembly
    // assembly {
    //   tokenId := add(shl(248, tokenType), add(shl(128, maturity), strike64x64))
    // }

    tokenId = (uint256(tokenType) << 248) + (uint256(maturity) << 128) + uint256(int256(strike64x64));
  }

  /**
   * @notice derive option maturity and strike price from ERC1155 token id
   * @param tokenId token id
   * @return tokenType TokenType enum
   * @return maturity timestamp of option maturity
   * @return strike64x64 option strike price
   */
  function parseTokenId (
    uint256 tokenId
  ) internal pure returns (TokenType tokenType, uint64 maturity, int128 strike64x64) {
    assembly {
      tokenType := shr(248, tokenId)
      maturity := shr(128, tokenId)
      strike64x64 := tokenId
    }
  }

  function getTokenDecimals (
    Layout storage l,
    bool isCall
  ) internal view returns (uint8 decimals) {
    decimals = isCall ? l.underlyingDecimals : l.baseDecimals;
  }

  function totalFreeLiquiditySupply64x64 (
    Layout storage l,
    bool isCall
  ) internal view returns (int128) {
    uint256 tokenId = formatTokenId(isCall ? TokenType.UNDERLYING_FREE_LIQ : TokenType.BASE_FREE_LIQ, 0, 0);

    return ABDKMath64x64Token.fromDecimals(
      ERC1155EnumerableStorage.layout().totalSupply[tokenId] - l.nextDeposits[isCall].totalPendingDeposits,
      getTokenDecimals(l, isCall)
    );
  }

  function getReinvestmentStatus (
    Layout storage l,
    address account
  ) internal view returns (bool) {
    uint256 timestamp = l.divestmentTimestamps[account];
    return timestamp == 0 || timestamp > block.timestamp;
  }

  function addUnderwriter (
    Layout storage l,
    address account,
    bool isCallPool
  ) internal {
    require(account != address(0));
    mapping (address => address) storage desc = l.liquidityQueueDescending[isCallPool];

    address last = desc[address(0)];

    l.liquidityQueueAscending[isCallPool][last] = account;
    desc[account] = last;
    desc[address(0)] = account;
  }

  function removeUnderwriter (
    Layout storage l,
    address account,
    bool isCallPool
  ) internal {
    require(account != address(0));
    mapping (address => address) storage asc = l.liquidityQueueAscending[isCallPool];
    mapping (address => address) storage desc = l.liquidityQueueDescending[isCallPool];

    address prev = desc[account];
    address next = asc[account];
    asc[prev] = next;
    desc[next] = prev;
    delete asc[account];
    delete desc[account];
  }

  function getCLevel (
    Layout storage l,
    bool isCall
  ) internal view returns (int128 cLevel64x64) {
    cLevel64x64 = isCall ? l.cLevelUnderlying64x64 : l.cLevelBase64x64;
  }

  function setCLevel (
    Layout storage l,
    int128 oldLiquidity64x64,
    int128 newLiquidity64x64,
    bool isCallPool
  ) internal returns (int128 cLevel64x64) {
    cLevel64x64 = calculateCLevel(l, oldLiquidity64x64, newLiquidity64x64, isCallPool);

    // 0.8
    if (cLevel64x64 < 0xcccccccccccccccd) cLevel64x64 = 0xcccccccccccccccd;

    if (isCallPool) {
      l.cLevelUnderlying64x64 = cLevel64x64;
    } else {
      l.cLevelBase64x64 = cLevel64x64;
    }
  }

  function calculateCLevel (
    Layout storage l,
    int128 oldLiquidity64x64,
    int128 newLiquidity64x64,
    bool isCallPool
  ) internal view returns(int128) {
    return OptionMath.calculateCLevel(
      isCallPool ? l.cLevelUnderlying64x64 : l.cLevelBase64x64,
      oldLiquidity64x64,
      newLiquidity64x64,
      0x10000000000000000 // 64x64 fixed point representation of 1
    );
  }

  function setOracles(
    Layout storage l,
    address baseOracle,
    address underlyingOracle
  ) internal {
    require(
      AggregatorV3Interface(baseOracle).decimals() == AggregatorV3Interface(underlyingOracle).decimals(),
      'Pool: oracle decimals must match'
    );

    l.baseOracle = baseOracle;
    l.underlyingOracle = underlyingOracle;
  }

  function fetchPriceUpdate (
    Layout storage l
  ) internal view returns (int128 price64x64) {
    int256 priceUnderlying = AggregatorInterface(l.underlyingOracle).latestAnswer();
    int256 priceBase = AggregatorInterface(l.baseOracle).latestAnswer();

    return ABDKMath64x64.divi(
      priceUnderlying,
      priceBase
    );
  }

  function setPriceUpdate (
    Layout storage l,
    int128 price64x64
  ) internal {
    // TODO: check for off-by-one errors
    uint bucket = block.timestamp / (1 hours);
    l.bucketPrices64x64[bucket] = price64x64;
    l.priceUpdateSequences[bucket >> 8] += 1 << 256 - (bucket & 255);
  }

  function getPriceUpdate (
    Layout storage l,
    uint timestamp
  ) internal view returns (int128) {
    return l.bucketPrices64x64[timestamp / (1 hours)];
  }

  function getPriceUpdateAfter (
    Layout storage l,
    uint timestamp
  ) internal view returns (int128) {
    // TODO: check for off-by-one errors
    uint bucket = timestamp / (1 hours);
    uint sequenceId = bucket >> 8;
    // shift to skip buckets from earlier in sequence
    // TODO: underflow
    uint offset = (bucket & 255) - 1;
    uint sequence = l.priceUpdateSequences[sequenceId] << offset >> offset;

    uint currentPriceUpdateSequenceId = block.timestamp / (256 hours);

    while (sequence == 0 && sequenceId <= currentPriceUpdateSequenceId) {
      sequence = l.priceUpdateSequences[++sequenceId];
    }

    if (sequence == 0) {
      // TODO: no price update found; continuing function will return 0 anyway
      return 0;
    }

    uint256 msb; // most significant bit

    for (uint256 i = 128; i > 0; i >>= 1) {
      if (sequence >> i > 0) {
        msb += i;
        sequence >>= i;
      }
    }

    return l.bucketPrices64x64[(sequenceId + 1 << 8) - msb];
  }

  function fromBaseToUnderlyingDecimals (
    Layout storage l,
    uint256 value
  ) internal view returns (uint256) {
    int128 valueFixed64x64 = ABDKMath64x64Token.fromDecimals(value, l.baseDecimals);
    return ABDKMath64x64Token.toDecimals(valueFixed64x64, l.underlyingDecimals);
  }

  function fromUnderlyingToBaseDecimals (
    Layout storage l,
    uint256 value
  ) internal view returns (uint256) {
    int128 valueFixed64x64 = ABDKMath64x64Token.fromDecimals(value, l.underlyingDecimals);
    return ABDKMath64x64Token.toDecimals(valueFixed64x64, l.baseDecimals);
  }
}
