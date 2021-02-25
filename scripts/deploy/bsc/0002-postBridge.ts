import { ethers } from 'hardhat';
import {
  PremiaFeeDiscount__factory,
  PremiaMaker__factory,
  PremiaStaking__factory,
} from '../../../contractsTyped';
import { parseEther } from 'ethers/lib/utils';

async function main() {
  const [deployer] = await ethers.getSigners();

  let busd: string;
  let premia: string | undefined;
  let premiaOptionBusd: string;
  let treasury: string;
  let uniswapRouters = [
    '0x05fF2B0DB69458A0750badebc4f9e13aDd608C7F', // PancakeSwap router
  ];

  premia = '';
  premiaOptionBusd = '';
  busd = '0xe9e7cea3dedca5984780bafc599bd69add087d56';
  treasury = '0x2332Cc88B8355E07E7334265c52B292fd43547CA';

  //

  const xPremia = await new PremiaStaking__factory(deployer).deploy(premia);
  console.log(
    `PremiaStaking deployed at ${xPremia.address} (Args : ${premia})`,
  );

  const premiaMaker = await new PremiaMaker__factory(deployer).deploy(
    premia,
    xPremia.address,
    treasury,
  );
  console.log(
    `PremiaMaker deployed at ${premiaMaker.address} (Args : ${premia} / ${xPremia.address} / ${treasury})`,
  );

  const premiaFeeDiscount = await new PremiaFeeDiscount__factory(
    deployer,
  ).deploy(xPremia.address);
  console.log(
    `PremiaFeeDiscount deployed at ${premiaFeeDiscount.address} (Args : ${xPremia.address})`,
  );

  //

  await premiaFeeDiscount.setStakeLevels([
    { amount: parseEther('5000'), discount: 2500 }, // -25%
    { amount: parseEther('50000'), discount: 5000 }, // -50%
    { amount: parseEther('250000'), discount: 7500 }, // -75%
    { amount: parseEther('500000'), discount: 9500 }, // -95%
  ]);
  console.log('Added PremiaFeeDiscount stake levels');

  const oneMonth = 30 * 24 * 3600;
  await premiaFeeDiscount.setStakePeriod(oneMonth, 10000);
  await premiaFeeDiscount.setStakePeriod(3 * oneMonth, 12500);
  await premiaFeeDiscount.setStakePeriod(6 * oneMonth, 15000);
  await premiaFeeDiscount.setStakePeriod(12 * oneMonth, 20000);
  console.log('Added premiaFeeDiscount stake periods');

  if (treasury !== deployer.address) {
    await premiaFeeDiscount.transferOwnership(treasury);
    console.log(`PremiaFeeDiscount ownership transferred to ${treasury}`);

    await premiaMaker.transferOwnership(treasury);
    console.log(`PremiaMaker ownership transferred to ${treasury}`);
  }

  await premiaMaker.addWhitelistedRouter(uniswapRouters);
  console.log('Whitelisted uniswap routers on PremiaMaker');

  // ToDo post deployment :
  // - Set premiaFeeDiscount addr on feeCalculator
  // - Set premiaMaker as feeRecipient on Market and Option contract
}

// We recommend this pattern to be able to use async/await everywhere
// and properly handle errors.
main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
