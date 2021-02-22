import { ethers } from 'hardhat';
import {
  FeeCalculator__factory,
  PremiaMarket__factory,
  PremiaOption__factory,
} from '../../../../contractsTyped';
import { BigNumberish } from 'ethers';
import { ZERO_ADDRESS } from '../../../../test/utils/constants';

async function main() {
  const [deployer] = await ethers.getSigners();

  let busd: string;
  let treasury: string;
  let tokens: { [addr: string]: BigNumberish } = {};
  let uniswapRouters = [
    '0x05fF2B0DB69458A0750badebc4f9e13aDd608C7F', // PancakeSwap router
  ];

  busd = '0xe9e7cea3dedca5984780bafc599bd69add087d56';
  treasury = deployer.address;

  let uri = 'https://premia.finance/api/bsc/dai/{id}.json';

  //

  const feeCalculator = await new FeeCalculator__factory(deployer).deploy(
    ZERO_ADDRESS,
  );
  console.log(
    `FeeCalculator deployed at ${feeCalculator.address} (Args : ${ZERO_ADDRESS})`,
  );

  //

  const premiaOptionBusd = await new PremiaOption__factory(deployer).deploy(
    uri,
    busd,
    ZERO_ADDRESS,
    feeCalculator.address,
    ZERO_ADDRESS,
    treasury,
  );

  console.log(
    `premiaOption dai deployed at ${premiaOptionBusd.address} (Args : ${uri} / ${busd} / ${ZERO_ADDRESS} / 
    ${feeCalculator.address} / ${ZERO_ADDRESS} / ${treasury})`,
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

  const premiaMarket = await new PremiaMarket__factory(deployer).deploy(
    ZERO_ADDRESS,
    feeCalculator.address,
    treasury,
    ZERO_ADDRESS,
  );

  console.log(
    `premiaMarket deployed at ${premiaMarket.address} (Args : ${ZERO_ADDRESS} / ${feeCalculator.address} / ${treasury} / ${ZERO_ADDRESS})`,
  );

  await premiaMarket.addWhitelistedOptionContracts([premiaOptionBusd.address]);

  console.log('Whitelisted dai premiaOption contract on PremiaMarket');

  await premiaOptionBusd.setWhitelistedUniswapRouters(uniswapRouters);
  console.log('Whitelisted uniswap routers on PremiaOption Dai');

  await premiaMarket.addWhitelistedPaymentTokens([busd]);
  console.log('Added dai as market payment token');

  if (treasury !== deployer.address) {
    await feeCalculator.transferOwnership(treasury);
    console.log(`FeeCalculator ownership transferred to ${treasury}`);

    await premiaMarket.transferOwnership(treasury);
    console.log(`PremiaMarket ownership transferred to ${treasury}`);

    await premiaOptionBusd.transferOwnership(treasury);
    console.log(`PremiaOption DAI ownership transferred to ${treasury}`);
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
