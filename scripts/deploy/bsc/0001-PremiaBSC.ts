import { ethers } from 'hardhat';
import {
  FeeCalculator__factory,
  PremiaFeeDiscount__factory,
  PremiaMarket__factory,
  PremiaOption__factory,
  PremiaReferral__factory,
} from '../../../contractsTyped';
import { BigNumberish } from 'ethers';
import { deployContracts } from '../../deployContracts';
import { parseEther } from 'ethers/lib/utils';
import { ZERO_ADDRESS } from '../../../test/utils/constants';

async function main() {
  const [deployer] = await ethers.getSigners();

  let busd: string;
  let treasury: string;
  let tokens: { [addr: string]: BigNumberish } = {};
  let uniswapRouters = [
    '0x05fF2B0DB69458A0750badebc4f9e13aDd608C7F', // PancakeSwap router
  ];

  busd = '0xe9e7cea3dedca5984780bafc599bd69add087d56';
  treasury = '0x2332Cc88B8355E07E7334265c52B292fd43547CA';

  let uri = 'https://premia.finance/api/bsc/busd/{id}.json';

  // CAKE
  tokens['0x0e09fabb73bd3ade0a17ecc321fd13a19e81ce82'] = parseEther('2.5');

  // DOT
  tokens['0x7083609fce4d1d8dc0c979aab8c869ea2c873402'] = parseEther('5');

  // ETH
  tokens['0x2170ed0880ac9a755fd29b2688956bd959f933f8'] = parseEther('250');

  // WBNB
  tokens['0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c'] = parseEther('25');

  // UNI
  tokens['0xbf5140a22578168fd562dccf235e5d43a02ce9b1'] = parseEther('2.5');

  // LINK
  tokens['0xf8a0bf9cf54bb92f17374d9e9a321e6a111a51bd'] = parseEther('2.5');

  // BAND
  tokens['0xad6caeb32cd2c308980a548bd0bc5aa4306c6c18'] = parseEther('2.5');

  // VENUS
  tokens['0xcf6bb5389c92bdda8a3747ddb454cb7a64626c63'] = parseEther('10');

  // ADA
  tokens['0x3ee2200efb3400fabb9aacf31297cbdd1d435d47'] = parseEther('0.1');

  // YFI
  tokens['0x88f1a5ae2a3bf98aeaf342d26b30a79438c9142e'] = parseEther('5000');

  // BUNNY
  tokens['0xc9849e6fdb743d08faee3e34dd2d1bc69ea11a51'] = parseEther('10');

  // AUTOv2
  tokens['0xa184088a740c695e156f91f5cc086a06bb78b827'] = parseEther('1000');

  // XRP
  tokens['0x1d2f0da169ceb9fc7b3144628db156f3f6c60dbe'] = parseEther('0.0');

  // EOS
  tokens['0x56b6fb708fc5732dec1afc8d8556423a2edccbd6'] = parseEther('0.5');

  //

  const feeCalculator = await new FeeCalculator__factory(deployer).deploy(
    ZERO_ADDRESS,
  );
  console.log(
    `FeeCalculator deployed at ${feeCalculator.address} (Args : ${ZERO_ADDRESS})`,
  );

  const premiaReferral = await new PremiaReferral__factory(deployer).deploy();
  console.log(`PremiaReferral deployed at ${premiaReferral.address}`);

  //

  const premiaOptionBusd = await new PremiaOption__factory(deployer).deploy(
    uri,
    busd,
    feeCalculator.address,
    ZERO_ADDRESS,
    premiaReferral.address,
    treasury,
  );

  console.log(
    `premiaOption busd deployed at ${premiaOptionBusd.address} (Args : ${uri} / ${busd} / ${ZERO_ADDRESS} / 
    ${ZERO_ADDRESS} / ${premiaReferral.address} / ${treasury})`,
  );

  //

  const tokenAddresses: string[] = [];
  const tokenStrikeIncrements: BigNumberish[] = [];

  Object.keys(tokens).forEach((k) => {
    tokenAddresses.push(k);
    tokenStrikeIncrements.push(tokens[k]);
  });

  await premiaOptionBusd.setTokens(tokenAddresses, tokenStrikeIncrements);

  console.log('Tokens for BUSD options added');

  //

  const premiaMarket = await new PremiaMarket__factory(deployer).deploy(
    ZERO_ADDRESS,
    feeCalculator.address,
    treasury,
    premiaReferral.address,
  );

  console.log(
    `premiaMarket deployed at ${premiaMarket.address} (Args : ${ZERO_ADDRESS} / ${feeCalculator.address} / ${treasury})`,
  );

  await premiaReferral.addWhitelisted([
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

  console.log('Whitelisted busd premiaOption contract on PremiaMarket');

  await premiaOptionBusd.setWhitelistedUniswapRouters(uniswapRouters);
  console.log('Whitelisted uniswap routers on PremiaOption Dai');

  await premiaMarket.addWhitelistedPaymentTokens([busd]);
  console.log('Added busd as market payment token');

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
    await feeCalculator.transferOwnership(treasury);
    console.log(`FeeCalculator ownership transferred to ${treasury}`);

    await premiaMarket.transferOwnership(treasury);
    console.log(`PremiaMarket ownership transferred to ${treasury}`);

    await premiaOptionBusd.transferOwnership(treasury);
    console.log(`PremiaOption BUSD ownership transferred to ${treasury}`);

    await premiaReferral.transferOwnership(treasury);
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
