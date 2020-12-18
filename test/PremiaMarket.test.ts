import { ethers } from 'hardhat';
import { utils } from 'ethers';
import { expect } from 'chai';
import { SignerWithAddress } from '@nomiclabs/hardhat-ethers/dist/src/signer-with-address';
import {
  TestErc20__factory,
  TestPremiaMarket,
  TestPremiaMarket__factory,
  TestPremiaOption,
  TestPremiaOption__factory,
} from '../contractsTyped';
import { TestErc20 } from '../contractsTyped';
import { PremiaOptionTestUtil } from './utils/PremiaOptionTestUtil';
import { IOrder, IOrderCreated } from '../types';
import { PremiaMarketTestUtil } from './utils/PremiaMarketTestUtil';

let eth: TestErc20;
let dai: TestErc20;
let premiaOption: TestPremiaOption;
let premiaMarket: TestPremiaMarket;
let admin: SignerWithAddress;
let user1: SignerWithAddress;
let user2: SignerWithAddress;
let user3: SignerWithAddress;
let treasury: SignerWithAddress;
const tax = 0.01;

let optionTestUtil: PremiaOptionTestUtil;
let marketTestUtil: PremiaMarketTestUtil;

describe('PremiaMarket', () => {
  beforeEach(async () => {
    [admin, user1, user2, user3, treasury] = await ethers.getSigners();
    const erc20Factory = new TestErc20__factory(user1);
    eth = await erc20Factory.deploy();
    dai = await erc20Factory.deploy();

    const premiaOptionFactory = new TestPremiaOption__factory(user1);
    premiaOption = await premiaOptionFactory.deploy(
      'dummyURI',
      eth.address,
      treasury.address,
    );

    const premiaMarketFactory = new TestPremiaMarket__factory(user1);
    premiaMarket = await premiaMarketFactory.deploy(admin.address);

    optionTestUtil = new PremiaOptionTestUtil({
      eth,
      dai,
      premiaOption,
      writer1: user1,
      writer2: user2,
      user1: user3,
      treasury,
      tax,
    });

    marketTestUtil = new PremiaMarketTestUtil({
      eth,
      dai,
      premiaOption,
      premiaMarket,
      admin,
      writer1: user1,
      writer2: user2,
      user1: user3,
      treasury,
    });

    await premiaMarket.addWhitelistedOptionContracts([premiaOption.address]);
    await premiaOption
      .connect(admin)
      .setApprovalForAll(premiaMarket.address, true);
    await eth
      .connect(admin)
      .increaseAllowance(
        premiaOption.address,
        ethers.utils.parseEther('10000'),
      );
    await dai
      .connect(admin)
      .increaseAllowance(
        premiaOption.address,
        ethers.utils.parseEther('10000'),
      );
    await eth
      .connect(admin)
      .increaseAllowance(
        premiaMarket.address,
        ethers.utils.parseEther('10000'),
      );

    await premiaOption.setToken(
      eth.address,
      utils.parseEther('1'),
      utils.parseEther('10'),
    );

    await premiaMarket.addWhitelistedPaymentTokens([eth.address]);
  });

  describe('createOrder', () => {
    it('should create an order', async () => {
      await optionTestUtil.mintAndWriteOption(admin, 5);
      const orderCreated = await marketTestUtil.createOrder(admin);

      expect(orderCreated.hash).to.not.be.undefined;

      let amount = await premiaMarket.amounts(orderCreated.hash);

      expect(amount).to.eq(1);
    });

    it('should create multiple orders', async () => {
      await optionTestUtil.mintAndWriteOption(admin, 5);

      const newOrder = marketTestUtil.getDefaultOrder(admin);

      const tx = await premiaMarket.connect(admin).createOrders(
        [
          {
            ...newOrder,
            expirationTime: 0,
            salt: 0,
          },
          {
            ...newOrder,
            expirationTime: 0,
            salt: 0,
          },
        ],
        [2, 3],
      );

      const filter = premiaMarket.filters.OrderCreated(
        null,
        null,
        null,
        null,
        null,
        null,
        null,
        null,
        null,
        null,
        null,
      );
      const r = await premiaMarket.queryFilter(filter, tx.blockHash);

      const events = r.map((el) => (el.args as any) as IOrderCreated);

      expect(events.length).to.eq(2);

      const order1Amount = await premiaMarket.amounts(events[0].hash);
      const order2Amount = await premiaMarket.amounts(events[1].hash);

      expect(order1Amount).to.eq(2);
      expect(order2Amount).to.eq(3);
    });

    it('should fail creating an order if option contract is not whitelisted', async () => {
      await premiaMarket.removeWhitelistedOptionContracts([
        premiaOption.address,
      ]);
      await optionTestUtil.mintAndWriteOption(admin, 5);
      await expect(marketTestUtil.createOrder(admin)).to.be.revertedWith(
        'Option contract not whitelisted',
      );
    });

    it('should fail creating an order if payment token is not whitelisted', async () => {
      await premiaMarket.removeWhitelistedPaymentTokens([eth.address]);
      await optionTestUtil.mintAndWriteOption(admin, 5);
      await expect(marketTestUtil.createOrder(admin)).to.be.revertedWith(
        'Payment token not whitelisted',
      );
    });

    it('should fail creating an order if option is expired', async () => {
      await optionTestUtil.mintAndWriteOption(admin, 5);
      await premiaMarket.setTimestamp(1e7);
      await expect(marketTestUtil.createOrder(admin)).to.be.revertedWith(
        'Option expired',
      );
    });
  });

  describe('isOrderValid', () => {
    it('should detect multiple orders as valid', async () => {
      await optionTestUtil.mintAndWriteOption(admin, 5);
      const order1 = await marketTestUtil.createOrder(admin);
      const order2 = await marketTestUtil.createOrder(admin);

      const areValid = await premiaMarket.areOrdersValid([
        marketTestUtil.convertOrderCreatedToOrder(order1),
        marketTestUtil.convertOrderCreatedToOrder(order2),
      ]);
      expect(areValid.length).to.eq(2);
      expect(areValid[0]).to.be.true;
      expect(areValid[1]).to.be.true;
    });

    describe('sell order', () => {
      it('should detect sell order as valid if maker still own NFTs and transfer is approved', async () => {
        await optionTestUtil.mintAndWriteOption(admin, 5);
        const order = await marketTestUtil.createOrder(admin);

        const isValid = await premiaMarket.isOrderValid(
          marketTestUtil.convertOrderCreatedToOrder(order),
        );
        expect(isValid).to.be.true;
      });

      it('should detect sell order as invalid if maker has not approved NFT transfers', async () => {
        await optionTestUtil.mintAndWriteOption(admin, 5);
        const order = await marketTestUtil.createOrder(admin);
        await premiaOption
          .connect(admin)
          .setApprovalForAll(premiaMarket.address, false);

        const isValid = await premiaMarket.isOrderValid(
          marketTestUtil.convertOrderCreatedToOrder(order),
        );
        expect(isValid).to.be.false;
      });

      it('should detect sell order as invalid if maker does not own NFTs anymore', async () => {
        await optionTestUtil.mintAndWriteOption(admin, 5);
        const order = await marketTestUtil.createOrder(admin);
        await premiaOption.connect(admin).cancelOption(1, 5);

        const isValid = await premiaMarket.isOrderValid(
          marketTestUtil.convertOrderCreatedToOrder(order),
        );
        expect(isValid).to.be.false;
      });

      it('should detect sell order as invalid if amount to sell left is 0', async () => {
        await optionTestUtil.mintAndWriteOption(admin, 5);
        const order = await marketTestUtil.createOrder(admin);

        await eth.connect(user1).mint(ethers.utils.parseEther('100'));
        await eth
          .connect(user1)
          .increaseAllowance(
            premiaMarket.address,
            ethers.utils.parseEther('10000'),
          );
        await premiaMarket
          .connect(user1)
          .fillOrder(marketTestUtil.convertOrderCreatedToOrder(order), 5);

        const isValid = await premiaMarket.isOrderValid(
          marketTestUtil.convertOrderCreatedToOrder(order),
        );
        expect(isValid).to.be.false;
      });
    });

    describe('buy order', () => {
      it('should detect buy order as valid if maker still own ERC20 and transfer is approved', async () => {
        await optionTestUtil.mintAndWriteOption(user1, 1);

        await eth.connect(admin).mint(ethers.utils.parseEther('1.015'));
        const order = await marketTestUtil.createOrder(admin, { isBuy: true });

        const isValid = await premiaMarket.isOrderValid(
          marketTestUtil.convertOrderCreatedToOrder(order),
        );
        expect(isValid).to.be.true;
      });

      it('should detect buy order as invalid if maker does not have enough to cover price + fee', async () => {
        await optionTestUtil.mintAndWriteOption(user1, 1);

        await eth.connect(admin).mint(ethers.utils.parseEther('1.0'));
        const order = await marketTestUtil.createOrder(admin, { isBuy: true });

        const isValid = await premiaMarket.isOrderValid(
          marketTestUtil.convertOrderCreatedToOrder(order),
        );
        expect(isValid).to.be.false;
      });

      it('should detect buy order as invalid if maker did not approved ERC20', async () => {
        await optionTestUtil.mintAndWriteOption(user1, 1);

        await eth.connect(admin).mint(ethers.utils.parseEther('10'));
        await eth.connect(admin).approve(premiaMarket.address, 0);
        const order = await marketTestUtil.createOrder(admin, { isBuy: true });

        const isValid = await premiaMarket.isOrderValid(
          marketTestUtil.convertOrderCreatedToOrder(order),
        );
        expect(isValid).to.be.false;
      });

      it('should detect buy order as invalid if amount to buy left is 0', async () => {
        await optionTestUtil.mintAndWriteOption(user1, 1);

        await eth.connect(admin).mint(ethers.utils.parseEther('1.015'));
        const order = await marketTestUtil.createOrder(admin, { isBuy: true });

        await premiaOption
          .connect(user1)
          .setApprovalForAll(premiaMarket.address, true);
        await premiaMarket
          .connect(user1)
          .fillOrder(marketTestUtil.convertOrderCreatedToOrder(order), 1);

        const isValid = await premiaMarket.isOrderValid(
          marketTestUtil.convertOrderCreatedToOrder(order),
        );
        expect(isValid).to.be.false;
      });

      it('should detect order as invalid if expired', async () => {
        await optionTestUtil.mintAndWriteOption(user1, 1);

        await eth.connect(admin).mint(ethers.utils.parseEther('1.015'));
        const order = await marketTestUtil.createOrder(admin, { isBuy: true });
        await premiaMarket.setTimestamp(1e8);

        const isValid = await premiaMarket.isOrderValid(
          marketTestUtil.convertOrderCreatedToOrder(order),
        );
        expect(isValid).to.be.false;
      });
    });
  });

  describe('fillOrder', () => {
    describe('any side', () => {
      it('should fail filling order if order is not found', async () => {
        const order: IOrder = {
          ...marketTestUtil.getDefaultOrder(admin, { isBuy: true }),
          expirationTime: 0,
          salt: 0,
        };
        await expect(
          premiaMarket.connect(admin.address).fillOrder(order, 1),
        ).to.be.revertedWith('Order not found');
      });

      it('should fail filling order if order is expired', async () => {
        const maker = user1;
        const taker = user2;
        const order = await marketTestUtil.setupOrder(maker, taker, {
          isBuy: true,
        });
        await premiaMarket.setTimestamp(1e8);

        await expect(
          premiaMarket
            .connect(taker)
            .fillOrder(marketTestUtil.convertOrderCreatedToOrder(order), 1),
        ).to.be.revertedWith('Order expired');
      });

      it('should fail filling order if maxAmount set is 0', async () => {
        const maker = user1;
        const taker = user2;
        const order = await marketTestUtil.setupOrder(maker, taker, {
          isBuy: true,
        });

        await expect(
          premiaMarket
            .connect(taker)
            .fillOrder(marketTestUtil.convertOrderCreatedToOrder(order), 0),
        ).to.be.revertedWith('MaxAmount must be > 0');
      });

      it('should fail filling order if taker is specified, and someone else than taker tries to fill order', async () => {
        const maker = user1;
        const taker = user2;
        const order = await marketTestUtil.setupOrder(maker, taker, {
          taker: user3.address,
          isBuy: true,
        });

        await expect(
          premiaMarket
            .connect(taker)
            .fillOrder(marketTestUtil.convertOrderCreatedToOrder(order), 1),
        ).to.be.revertedWith('Not specified taker');
      });

      it('should successfully fill order if taker is specified, and the one who tried to fill', async () => {
        const maker = user1;
        const taker = user2;
        const order = await marketTestUtil.setupOrder(maker, taker, {
          taker: taker.address,
          isBuy: true,
        });

        await premiaMarket
          .connect(taker)
          .fillOrder(marketTestUtil.convertOrderCreatedToOrder(order), 1);

        const optionBalanceMaker = await premiaOption.balanceOf(
          maker.address,
          1,
        );
        const optionBalanceTaker = await premiaOption.balanceOf(
          taker.address,
          1,
        );

        expect(optionBalanceMaker).to.eq(1);
        expect(optionBalanceTaker).to.eq(0);
      });

      it('should fill multiple orders', async () => {
        const maker = user1;
        const taker = user2;

        const order1 = await marketTestUtil.setupOrder(maker, taker, {
          isBuy: false,
          amount: 2,
        });

        const order2 = await marketTestUtil.setupOrder(maker, taker, {
          isBuy: false,
          amount: 2,
        });

        await premiaMarket
          .connect(taker)
          .fillOrders(
            [
              marketTestUtil.convertOrderCreatedToOrder(order1),
              marketTestUtil.convertOrderCreatedToOrder(order2),
            ],
            [2, 2],
          );

        const optionBalanceMaker = await premiaOption.balanceOf(
          maker.address,
          1,
        );
        const optionBalanceTaker = await premiaOption.balanceOf(
          taker.address,
          1,
        );

        expect(optionBalanceMaker).to.eq(0);
        expect(optionBalanceTaker).to.eq(4);
      });
    });

    describe('sell order', () => {
      it('should fill 2 sell orders', async () => {
        const maker = user1;
        const taker = user2;
        const treasury = admin;

        const order = await marketTestUtil.setupOrder(maker, taker, {
          isBuy: false,
          amount: 2,
        });

        let orderAmount = await premiaMarket.amounts(order.hash);
        expect(orderAmount).to.eq(2);

        await premiaMarket
          .connect(taker)
          .fillOrder(marketTestUtil.convertOrderCreatedToOrder(order), 2);

        const optionBalanceMaker = await premiaOption.balanceOf(
          maker.address,
          1,
        );
        const optionBalanceTaker = await premiaOption.balanceOf(
          taker.address,
          1,
        );

        expect(optionBalanceMaker).to.eq(0);
        expect(optionBalanceTaker).to.eq(2);

        const ethBalanceMaker = await eth.balanceOf(maker.address);
        const ethBalanceTaker = await eth.balanceOf(taker.address);
        const ethBalanceTreasury = await eth.balanceOf(treasury.address);

        expect(ethBalanceMaker).to.eq(ethers.utils.parseEther('1.97'));
        expect(ethBalanceTaker).to.eq(0);
        expect(ethBalanceTreasury).to.eq(ethers.utils.parseEther('0.06'));

        orderAmount = await premiaMarket.amounts(order.hash);
        expect(orderAmount).to.eq(0);
      });

      it('should fail filling sell order if maker does not have options', async () => {
        const maker = user1;
        const taker = user2;

        const order = await marketTestUtil.setupOrder(maker, taker, {
          isBuy: false,
        });
        await premiaOption
          .connect(maker)
          .safeTransferFrom(maker.address, admin.address, 1, 1, '0x00');
        await expect(
          premiaMarket
            .connect(taker)
            .fillOrder(marketTestUtil.convertOrderCreatedToOrder(order), 1),
        ).to.be.revertedWith('ERC1155: insufficient balance for transfer');
      });

      it('should fail filling sell order if taker does not have enough tokens', async () => {
        const maker = user1;
        const taker = user2;

        const order = await marketTestUtil.setupOrder(maker, taker, {
          isBuy: false,
        });
        await eth
          .connect(taker)
          .transfer(admin.address, ethers.utils.parseEther('0.01'));
        await expect(
          premiaMarket
            .connect(taker)
            .fillOrder(marketTestUtil.convertOrderCreatedToOrder(order), 1),
        ).to.be.revertedWith('ERC20: transfer amount exceeds balance');
      });

      it('should fill sell order for 1/2 if only 1 left to sell', async () => {
        const maker = user1;
        const taker = user2;
        const treasury = admin;

        const order = await marketTestUtil.setupOrder(maker, taker, {
          isBuy: false,
          amount: 1,
        });
        await premiaMarket
          .connect(taker)
          .fillOrder(marketTestUtil.convertOrderCreatedToOrder(order), 2);

        const optionBalanceMaker = await premiaOption.balanceOf(
          maker.address,
          1,
        );
        const optionBalanceTaker = await premiaOption.balanceOf(
          taker.address,
          1,
        );

        expect(optionBalanceMaker).to.eq(0);
        expect(optionBalanceTaker).to.eq(1);

        const ethBalanceMaker = await eth.balanceOf(maker.address);
        const ethBalanceTaker = await eth.balanceOf(taker.address);
        const ethBalanceTreasury = await eth.balanceOf(treasury.address);

        expect(ethBalanceMaker).to.eq(ethers.utils.parseEther('0.985'));
        expect(ethBalanceTaker).to.eq(0);
        expect(ethBalanceTreasury).to.eq(ethers.utils.parseEther('0.03'));
      });
    });

    describe('buy order', () => {
      it('should fill 2 buy orders', async () => {
        const maker = user1;
        const taker = user2;
        const treasury = admin;

        const order = await marketTestUtil.setupOrder(maker, taker, {
          isBuy: true,
          amount: 2,
        });

        let orderAmount = await premiaMarket.amounts(order.hash);
        expect(orderAmount).to.eq(2);

        await premiaMarket
          .connect(taker)
          .fillOrder(marketTestUtil.convertOrderCreatedToOrder(order), 2);

        const optionBalanceMaker = await premiaOption.balanceOf(
          maker.address,
          1,
        );
        const optionBalanceTaker = await premiaOption.balanceOf(
          taker.address,
          1,
        );

        expect(optionBalanceMaker).to.eq(2);
        expect(optionBalanceTaker).to.eq(0);

        const ethBalanceMaker = await eth.balanceOf(maker.address);
        const ethBalanceTaker = await eth.balanceOf(taker.address);
        const ethBalanceTreasury = await eth.balanceOf(treasury.address);

        expect(ethBalanceMaker).to.eq(0);
        expect(ethBalanceTaker).to.eq(ethers.utils.parseEther('1.97'));
        expect(ethBalanceTreasury).to.eq(ethers.utils.parseEther('0.06'));

        orderAmount = await premiaMarket.amounts(order.hash);
        expect(orderAmount).to.eq(0);
      });

      it('should fail filling buy order if maker does not have enough token', async () => {
        const maker = user1;
        const taker = user2;

        const order = await marketTestUtil.setupOrder(maker, taker, {
          isBuy: true,
        });
        await eth
          .connect(maker)
          .transfer(admin.address, ethers.utils.parseEther('0.01'));
        await expect(
          premiaMarket
            .connect(taker)
            .fillOrder(marketTestUtil.convertOrderCreatedToOrder(order), 1),
        ).to.be.revertedWith('ERC20: transfer amount exceeds balance');
      });

      it('should fail filling buy order if taker does not have enough options', async () => {
        const maker = user1;
        const taker = user2;

        const order = await marketTestUtil.setupOrder(maker, taker, {
          isBuy: true,
        });
        await premiaOption
          .connect(taker)
          .safeTransferFrom(taker.address, admin.address, 1, 1, '0x00');
        await expect(
          premiaMarket
            .connect(taker)
            .fillOrder(marketTestUtil.convertOrderCreatedToOrder(order), 1),
        ).to.be.revertedWith('ERC1155: insufficient balance for transfer');
      });

      it('should fill buy order for 1/2 if only 1 left to buy', async () => {
        const maker = user1;
        const taker = user2;
        const treasury = admin;

        const order = await marketTestUtil.setupOrder(maker, taker, {
          isBuy: true,
          amount: 1,
        });
        await premiaMarket
          .connect(taker)
          .fillOrder(marketTestUtil.convertOrderCreatedToOrder(order), 2);

        const optionBalanceMaker = await premiaOption.balanceOf(
          maker.address,
          1,
        );
        const optionBalanceTaker = await premiaOption.balanceOf(
          taker.address,
          1,
        );

        expect(optionBalanceMaker).to.eq(1);
        expect(optionBalanceTaker).to.eq(0);

        const ethBalanceMaker = await eth.balanceOf(maker.address);
        const ethBalanceTaker = await eth.balanceOf(taker.address);
        const ethBalanceTreasury = await eth.balanceOf(treasury.address);

        expect(ethBalanceMaker).to.eq(0);
        expect(ethBalanceTaker).to.eq(ethers.utils.parseEther('0.985'));
        expect(ethBalanceTreasury).to.eq(ethers.utils.parseEther('0.03'));
      });
    });
  });

  describe('cancelOrder', () => {
    it('should cancel an order', async () => {
      const maker = user1;
      const taker = user2;

      const order = await marketTestUtil.setupOrder(maker, taker, {
        isBuy: true,
        amount: 1,
      });

      let orderAmount = await premiaMarket.amounts(order.hash);
      expect(orderAmount).to.eq(1);

      await premiaMarket
        .connect(maker)
        .cancelOrder(marketTestUtil.convertOrderCreatedToOrder(order));

      orderAmount = await premiaMarket.amounts(order.hash);
      expect(orderAmount).to.eq(0);
    });

    it('should fail cancelling order if not called by order maker', async () => {
      const maker = user1;
      const taker = user2;

      const order = await marketTestUtil.setupOrder(maker, taker, {
        isBuy: true,
        amount: 1,
      });

      await expect(
        premiaMarket
          .connect(taker)
          .cancelOrder(marketTestUtil.convertOrderCreatedToOrder(order)),
      ).to.be.revertedWith('Not order maker');
    });

    it('should fail cancelling order if order not found', async () => {
      const maker = user1;
      const taker = user2;

      const order = await marketTestUtil.setupOrder(maker, taker, {
        isBuy: true,
        amount: 1,
      });

      await premiaMarket
        .connect(taker)
        .fillOrder(marketTestUtil.convertOrderCreatedToOrder(order), 1);

      await expect(
        premiaMarket
          .connect(taker)
          .cancelOrder(marketTestUtil.convertOrderCreatedToOrder(order)),
      ).to.be.revertedWith('Order not found');
    });

    it('should cancel multiple orders', async () => {
      const maker = user1;
      const taker = user2;

      const order1 = await marketTestUtil.setupOrder(maker, taker, {
        isBuy: true,
        amount: 1,
      });

      const order2 = await marketTestUtil.setupOrder(maker, taker, {
        isBuy: true,
        amount: 1,
      });

      let order1Amount = await premiaMarket.amounts(order1.hash);
      let order2Amount = await premiaMarket.amounts(order2.hash);
      expect(order1Amount).to.eq(1);
      expect(order2Amount).to.eq(1);

      await premiaMarket
        .connect(maker)
        .cancelOrders([
          marketTestUtil.convertOrderCreatedToOrder(order1),
          marketTestUtil.convertOrderCreatedToOrder(order2),
        ]);

      order1Amount = await premiaMarket.amounts(order1.hash);
      order2Amount = await premiaMarket.amounts(order2.hash);
      expect(order1Amount).to.eq(0);
      expect(order2Amount).to.eq(0);
    });
  });
});
