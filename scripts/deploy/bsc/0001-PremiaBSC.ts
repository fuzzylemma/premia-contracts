import { ethers } from 'hardhat';
import {
  PremiaMarket__factory,
  PremiaOption__factory,
} from '../../../contractsTyped';
import { BigNumberish } from 'ethers';
import { deployContracts } from '../../deployContracts';
import { parseEther } from 'ethers/lib/utils';
import { ZERO_ADDRESS } from '../../../test/utils/constants';

async function main() {
  const isTestnet = true;
  const [deployer] = await ethers.getSigners();

  let busd: string;
  // let weth: string;
  // let wbtc: string;
  let premia: string | undefined;
  let treasury: string;
  let tokens: { [addr: string]: BigNumberish } = {};
  let uniswapRouters = [
    '0x05fF2B0DB69458A0750badebc4f9e13aDd608C7F', // PancakeSwap router
  ];

  premia = '';
  busd = '0xe9e7cea3dedca5984780bafc599bd69add087d56';
  // treasury = '';
  treasury = deployer.address;

  let uri = 'https://premia.finance/api/bsc/dai/{id}.json';

  //

  const contracts = await deployContracts(
    deployer,
    treasury,
    isTestnet,
    true,
    premia,
  );

  //

  const premiaOptionBusd = await new PremiaOption__factory(deployer).deploy(
    uri,
    busd,
    ZERO_ADDRESS,
    contracts.feeCalculator.address,
    contracts.premiaReferral.address,
    treasury,
  );

  console.log(
    `premiaOption dai deployed at ${premiaOptionBusd.address} (Args : ${uri} / ${busd} / ${ZERO_ADDRESS} / 
    ${contracts.feeCalculator.address} / ${contracts.premiaReferral.address} / ${treasury})`,
  );

  //

  const tokenAddresses: string[] = [];
  const tokenStrikeIncrements: BigNumberish[] = [];

  Object.keys(tokens).forEach((k) => {
    tokenAddresses.push(k);
    tokenStrikeIncrements.push(tokens[k]);
  });

  await premiaOptionBusd.setTokens(tokenAddresses, tokenStrikeIncrements);

  console.log('Tokens for DAI options added');

  //

  await contracts.premiaFeeDiscount.setStakeLevels([
    { amount: parseEther('5000'), discount: 2500 }, // -25%
    { amount: parseEther('50000'), discount: 5000 }, // -50%
    { amount: parseEther('250000'), discount: 7500 }, // -75%
    { amount: parseEther('500000'), discount: 9500 }, // -95%
  ]);
  console.log('Added PremiaFeeDiscount stake levels');

  const oneMonth = 30 * 24 * 3600;
  await contracts.premiaFeeDiscount.setStakePeriod(oneMonth, 10000);
  await contracts.premiaFeeDiscount.setStakePeriod(3 * oneMonth, 12500);
  await contracts.premiaFeeDiscount.setStakePeriod(6 * oneMonth, 15000);
  await contracts.premiaFeeDiscount.setStakePeriod(12 * oneMonth, 20000);
  console.log('Added premiaFeeDiscount stake periods');

  //

  const premiaMarket = await new PremiaMarket__factory(deployer).deploy(
    ZERO_ADDRESS,
    contracts.feeCalculator.address,
    treasury,
    contracts.premiaReferral.address,
  );

  console.log(
    `premiaMarket deployed at ${premiaMarket.address} (Args : ${ZERO_ADDRESS} / ${contracts.feeCalculator.address} / ${treasury})`,
  );

  await contracts.premiaReferral.addWhitelisted([
    premiaOptionBusd.address,
    premiaMarket.address,
    // premiaOptionEth.address,
    // premiaOptionWbtc.address,
  ]);
  console.log('Whitelisted PremiaOption on PremiaReferral');

  await premiaMarket.addWhitelistedOptionContracts([
    // premiaOptionEth.address,
    premiaOptionBusd.address,
    // premiaOptionWbtc.address,
  ]);

  console.log('Whitelisted dai premiaOption contract on PremiaMarket');

  await premiaOptionBusd.setWhitelistedUniswapRouters(uniswapRouters);
  console.log('Whitelisted uniswap routers on PremiaOption Dai');

  await contracts.premiaMaker.addWhitelistedRouter(uniswapRouters);
  console.log('Whitelisted uniswap routers on PremiaMaker');

  await premiaMarket.addWhitelistedPaymentTokens([busd]);
  console.log('Added dai as market payment token');

  // Badger routing : Badger -> Wbtc -> Weth
  // await contracts.premiaMaker.setCustomPath(
  //   '0x3472A5A71965499acd81997a54BBA8D852C6E53d',
  //   [
  //     '0x3472A5A71965499acd81997a54BBA8D852C6E53d',
  //     '0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599',
  //     '0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2',
  //   ],
  // );
  // console.log('Added badger custom routing');

  if (treasury !== deployer.address) {
    await contracts.feeCalculator.transferOwnership(treasury);
    console.log(`FeeCalculator ownership transferred to ${treasury}`);

    await contracts.premiaFeeDiscount.transferOwnership(treasury);
    console.log(`PremiaFeeDiscount ownership transferred to ${treasury}`);

    await contracts.premiaMaker.transferOwnership(treasury);
    console.log(`PremiaMaker ownership transferred to ${treasury}`);

    await premiaMarket.transferOwnership(treasury);
    console.log(`PremiaMarket ownership transferred to ${treasury}`);

    await premiaOptionBusd.transferOwnership(treasury);
    console.log(`PremiaOption DAI ownership transferred to ${treasury}`);

    await contracts.premiaReferral.transferOwnership(treasury);
    console.log(`PremiaReferral ownership transferred to ${treasury}`);
  }
}

// We recommend this pattern to be able to use async/await everywhere
// and properly handle errors.
main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
