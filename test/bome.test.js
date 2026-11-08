const { expect } = require("chai");
const { ethers } = require("hardhat");

const DEAD = "0x000000000000000000000000000000000000dEaD";
const LOT_PRICE = ethers.parseEther("0.003");
const PER_LOT = ethers.parseEther("55550000"); // 55,550,000 BOME, all to the buyer
const TOTAL_SUPPLY = ethers.parseEther("888800000000");
const POOL_TOKENS = ethers.parseEther("333300000000"); // supply remainder, not a per-lot deduction
const SALE_TOKENS = ethers.parseEther("555500000000");
const B = (x) => ethers.parseEther(String(x)); // whole-BOME amounts

async function latestTs() {
  return (await ethers.provider.getBlock("latest")).timestamp;
}

async function deployAll(startTime) {
  const signers = await ethers.getSigners();
  const treasury = signers[3];
  const Registry = await ethers.getContractFactory("MockAgentIdRegistry");
  const registry = await Registry.deploy();
  const WBNB = await ethers.getContractFactory("MockWBNB");
  const wbnb = await WBNB.deploy();
  const Factory = await ethers.getContractFactory("MockPancakeFactory");
  const factory = await Factory.deploy();
  const Router = await ethers.getContractFactory("MockPancakeRouter");
  const router = await Router.deploy(await factory.getAddress(), await wbnb.getAddress());
  const BOME = await ethers.getContractFactory("BOME");
  const bome = await BOME.deploy(
    startTime,
    await registry.getAddress(),
    await factory.getAddress(),
    await router.getAddress(),
    await wbnb.getAddress(),
    await factory.pairInitCodeHash(),
    treasury.address
  );
  return { signers, treasury, registry, wbnb, factory, router, bome };
}

async function grantIds(registry, addrs) {
  const CHUNK = 200;
  for (let i = 0; i < addrs.length; i += CHUNK) {
    await registry.setIds(addrs.slice(i, i + CHUNK), true);
  }
}

/// 500 distinct buyers x 20 lots = 10,000 lots sellout.
/// firstInviter: wallet bound as inviter of buyers[0] (optional).
async function sellout(bome, registry, buyers, firstInviter) {
  await grantIds(registry, buyers.map((b) => b.address));
  for (let i = 0; i < buyers.length; i++) {
    const inv = i === 0 && firstInviter ? firstInviter : ethers.ZeroAddress;
    await bome.connect(buyers[i]).mint(20, inv, { value: LOT_PRICE * 20n });
  }
}

async function pairReserves(bome, pair) {
  const [r0, r1] = await pair.getReserves();
  const t0 = await pair.token0();
  const bomeAddr = await bome.getAddress();
  return t0 === bomeAddr ? { bome: r0, wbnb: r1 } : { bome: r1, wbnb: r0 };
}

describe("BOME — mint gating, quota, invites", function () {
  it("reverts before startTime", async function () {
    const { bome, registry, signers } = await deployAll((await latestTs()) + 100000);
    const u = signers[10];
    await registry.setId(u.address, true);
    await expect(
      bome.connect(u).mint(1, ethers.ZeroAddress, { value: LOT_PRICE })
    ).to.be.revertedWith("not started");
  });

  it("reverts without an Agent ID", async function () {
    const { bome, signers } = await deployAll(await latestTs());
    const u = signers[10];
    await expect(
      bome.connect(u).mint(1, ethers.ZeroAddress, { value: LOT_PRICE })
    ).to.be.revertedWith("no agent id");
  });

  it("requires exact payment: underpay and overpay both revert", async function () {
    const { bome, registry, signers } = await deployAll(await latestTs());
    const u = signers[10];
    await registry.setId(u.address, true);
    await expect(
      bome.connect(u).mint(2, ethers.ZeroAddress, { value: LOT_PRICE * 2n - 1n })
    ).to.be.revertedWith("exact payment");
    await expect(
      bome.connect(u).mint(2, ethers.ZeroAddress, { value: LOT_PRICE * 2n + 1n })
    ).to.be.revertedWith("exact payment");
    await bome.connect(u).mint(2, ethers.ZeroAddress, { value: LOT_PRICE * 2n });
    expect(await bome.balanceOf(u.address)).to.equal(PER_LOT * 2n);
    expect(await bome.contributions(u.address)).to.equal(LOT_PRICE * 2n);
  });

  it("invite binding: +1 quota per invited person, stacks uncapped, per-tx cap still binds", async function () {
    const { bome, registry, signers } = await deployAll(await latestTs());
    const A = signers[10], Bw = signers[11], C = signers[12];
    await grantIds(registry, [A.address, Bw.address, C.address]);

    // B and C bind A as inviter at their first mint -> A quota 20 + 2.
    await bome.connect(Bw).mint(1, A.address, { value: LOT_PRICE });
    await bome.connect(C).mint(1, A.address, { value: LOT_PRICE });
    expect(await bome.inviterOf(Bw.address)).to.equal(A.address);
    expect(await bome.quotaOf(A.address)).to.equal(22n);

    // Rebinding is impossible: B mints again naming someone else.
    await bome.connect(Bw).mint(1, C.address, { value: LOT_PRICE });
    expect(await bome.inviterOf(Bw.address)).to.equal(A.address);
    expect(await bome.quotaOf(A.address)).to.equal(22n); // no double grant

    // Per-tx cap is 20 even though A's quota is 22.
    await expect(
      bome.connect(A).mint(21, ethers.ZeroAddress, { value: LOT_PRICE * 21n })
    ).to.be.revertedWith("lots per tx");

    await bome.connect(A).mint(20, ethers.ZeroAddress, { value: LOT_PRICE * 20n });
    await bome.connect(A).mint(2, ethers.ZeroAddress, { value: LOT_PRICE * 2n });
    expect(await bome.mintedLots(A.address)).to.equal(22n);
    await expect(
      bome.connect(A).mint(1, ethers.ZeroAddress, { value: LOT_PRICE })
    ).to.be.revertedWith("quota exceeded");
  });

  it("locks transfers during the mint phase", async function () {
    const { bome, registry, signers } = await deployAll(await latestTs());
    const u = signers[10], v = signers[11];
    await registry.setId(u.address, true);
    await bome.connect(u).mint(1, ethers.ZeroAddress, { value: LOT_PRICE });
    await expect(bome.connect(u).transfer(v.address, 1n)).to.be.revertedWith("transfers locked");
    await expect(bome.connect(u).transfer(await bome.predictedPair(), 1n)).to.be.revertedWith("pair gated");
  });
});

describe("BOME — sellout settlement", function () {
  it("opens the pool: 24 BNB + 333.3B seeded, LP to dead, 6 BNB to treasury", async function () {
    const { bome, registry, factory, treasury, signers } = await deployAll(await latestTs());
    const buyers = signers.slice(20, 520);
    const treasuryBefore = await ethers.provider.getBalance(treasury.address);
    await sellout(bome, registry, buyers);

    expect(await bome.opened()).to.equal(true);
    expect(await bome.totalLotsMinted()).to.equal(10000n);
    expect(await bome.saleTokensRemaining()).to.equal(0n);
    expect(await bome.poolReserveTokens()).to.equal(0n);

    const pairAddr = await bome.pair();
    expect(pairAddr).to.equal(await bome.predictedPair());
    expect(pairAddr).to.equal(await factory.getPair(await bome.getAddress(), await bome.wbnb()));
    const pair = await ethers.getContractAt("MockPancakePair", pairAddr);
    const res = await pairReserves(bome, pair);
    expect(res.bome).to.equal(POOL_TOKENS);
    expect(res.wbnb).to.equal(ethers.parseEther("24"));

    // All LP sits at the dead address (plus the 1000 wei protocol lock).
    const lpDead = await pair.balanceOf(DEAD);
    expect(lpDead).to.be.gt(0n);
    expect(await pair.totalSupply()).to.equal(lpDead + 1000n);

    // Treasury got exactly 6 BNB; the contract holds no BNB anymore.
    expect(await ethers.provider.getBalance(treasury.address)).to.equal(
      treasuryBefore + ethers.parseEther("6")
    );
    expect(await ethers.provider.getBalance(await bome.getAddress())).to.equal(0n);

    // Buyers hold the full 555.5B (55.55M per lot, nothing deducted);
    // the contract keeps NOTHING: sale (555.5B) + pool (333.3B) exhaust
    // the supply, and there is no pre-seeded dividend pad.
    expect(await bome.balanceOf(buyers[0].address)).to.equal(PER_LOT * 20n);
    expect(await bome.balanceOf(await bome.getAddress())).to.equal(TOTAL_SUPPLY - SALE_TOKENS - POOL_TOKENS);
    expect(await bome.dividendReserve()).to.equal(0n);
    expect(await bome.bonusReserve()).to.equal(0n);

    // Transfers are live after the open (plain transfer: untaxed).
    await bome.connect(buyers[0]).transfer(buyers[1].address, 123n);
    expect(await bome.balanceOf(buyers[1].address)).to.equal(PER_LOT * 20n + 123n);
  });
});

describe("BOME — pool-open poison tolerance", function () {
  it("opens despite WBNB dust synced into the pre-created pair", async function () {
    const { bome, registry, factory, wbnb, signers } = await deployAll(await latestTs());
    const attacker = signers[5];
    await factory.createPair(await bome.getAddress(), await wbnb.getAddress());
    const pair = await ethers.getContractAt(
      "MockPancakePair",
      await factory.getPair(await bome.getAddress(), await wbnb.getAddress())
    );
    expect(await pair.getAddress()).to.not.equal(ethers.ZeroAddress);
    await wbnb.connect(attacker).deposit({ value: 1n });
    await wbnb.connect(attacker).transfer(await pair.getAddress(), 1n);
    await pair.sync(); // dust is now locked into reserves, totalSupply still 0

    const buyers = signers.slice(20, 520);
    await sellout(bome, registry, buyers);

    expect(await bome.opened()).to.equal(true);
    const res = await pairReserves(bome, pair);
    expect(res.bome).to.equal(POOL_TOKENS);
    // The 1 wei donation was folded into the seed, not a DoS.
    expect(res.wbnb).to.equal(ethers.parseEther("24") + 1n);
    expect(await pair.balanceOf(DEAD)).to.be.gt(0n);
  });

  it("recovers unsynced WBNB donations via skim at the open", async function () {
    const { bome, registry, factory, wbnb, treasury, signers } = await deployAll(await latestTs());
    const attacker = signers[5];
    await factory.createPair(await bome.getAddress(), await wbnb.getAddress());
    const pairAddr = await factory.getPair(await bome.getAddress(), await wbnb.getAddress());
    await wbnb.connect(attacker).deposit({ value: ethers.parseEther("0.5") });
    await wbnb.connect(attacker).transfer(pairAddr, ethers.parseEther("0.5"));
    // No sync(): the donation sits as skim-able excess.

    const treasuryBefore = await ethers.provider.getBalance(treasury.address);
    const buyers = signers.slice(20, 520);
    await sellout(bome, registry, buyers);

    expect(await bome.opened()).to.equal(true);
    const pair = await ethers.getContractAt("MockPancakePair", pairAddr);
    const res = await pairReserves(bome, pair);
    expect(res.wbnb).to.equal(ethers.parseEther("24"));
    // Treasury: 6 BNB leg + the recovered 0.5 BNB donation.
    expect(await ethers.provider.getBalance(treasury.address)).to.equal(
      treasuryBefore + ethers.parseEther("6.5")
    );
  });
});

describe("BOME — refund path (not sold out in 24h)", function () {
  it("pushes 100% refunds in batches, skips a rejecting wallet, no double refunds", async function () {
    const { bome, registry, signers } = await deployAll(await latestTs());
    const U1 = signers[10], U2 = signers[11], U3 = signers[12];
    const Rejector = await ethers.getContractFactory("RejectingMinter");
    const rejector = await Rejector.deploy();
    const rejectorAddr = await rejector.getAddress();
    await grantIds(registry, [U1.address, U2.address, U3.address, rejectorAddr]);

    await bome.connect(U1).mint(5, ethers.ZeroAddress, { value: LOT_PRICE * 5n });
    await rejector.mintBome(await bome.getAddress(), 10, ethers.ZeroAddress, { value: LOT_PRICE * 10n });
    await bome.connect(U2).mint(3, ethers.ZeroAddress, { value: LOT_PRICE * 3n });
    await bome.connect(U3).mint(2, ethers.ZeroAddress, { value: LOT_PRICE * 2n });

    expect(await bome.refundsActive()).to.equal(false);
    await ethers.provider.send("evm_increaseTime", [24 * 3600 + 1]);
    await ethers.provider.send("evm_mine", []);
    expect(await bome.refundsActive()).to.equal(true);
    await expect(
      bome.connect(U1).mint(1, ethers.ZeroAddress, { value: LOT_PRICE })
    ).to.be.revertedWith("mint ended");

    // One batch covers everyone; the rejecting wallet is skipped, not fatal.
    const tx = await bome.refundBatch(10);
    await expect(tx).to.changeEtherBalances(
      [U1, U2, U3],
      [LOT_PRICE * 5n, LOT_PRICE * 3n, LOT_PRICE * 2n]
    );
    expect(await bome.contributions(U1.address)).to.equal(0n);
    expect(await bome.contributions(U2.address)).to.equal(0n);
    expect(await bome.contributions(rejectorAddr)).to.equal(LOT_PRICE * 10n); // still owed
    expect(await ethers.provider.getBalance(await bome.getAddress())).to.equal(LOT_PRICE * 10n);

    // Refunded buyers' minted BOME was burned to the dead address in the
    // same flow (5 + 3 + 2 = 10 lots); the still-owed rejecting wallet
    // keeps its tokens and its lot record.
    expect(await bome.balanceOf(U1.address)).to.equal(0n);
    expect(await bome.balanceOf(U2.address)).to.equal(0n);
    expect(await bome.balanceOf(U3.address)).to.equal(0n);
    expect(await bome.balanceOf(DEAD)).to.equal(PER_LOT * 10n);
    expect(await bome.balanceOf(rejectorAddr)).to.equal(PER_LOT * 10n);
    expect(await bome.mintedLots(U1.address)).to.equal(0n);

    // No double refund.
    await expect(bome.connect(U1).claimRefund()).to.be.revertedWith("already refunded");
    // A second batch makes no progress on the rejecting wallet but returns.
    await bome.refundBatch(10);
    expect(await ethers.provider.getBalance(await bome.getAddress())).to.equal(LOT_PRICE * 10n);

    // Pool never opened; refunded tokens are burned, the rest stay locked.
    expect(await bome.opened()).to.equal(false);
    await expect(bome.connect(U1).transfer(U2.address, 1n)).to.be.revertedWith("transfers locked");
  });

  it("claimRefund pays the BNB and burns the buyer's minted BOME", async function () {
    const { bome, registry, signers } = await deployAll(await latestTs());
    const U = signers[13];
    await grantIds(registry, [U.address]);
    await bome.connect(U).mint(4, ethers.ZeroAddress, { value: LOT_PRICE * 4n });
    expect(await bome.balanceOf(U.address)).to.equal(PER_LOT * 4n);

    await ethers.provider.send("evm_increaseTime", [24 * 3600 + 1]);
    await ethers.provider.send("evm_mine", []);
    expect(await bome.refundsActive()).to.equal(true);

    const tx = await bome.connect(U).claimRefund();
    await expect(tx).to.changeEtherBalance(U, LOT_PRICE * 4n);
    expect(await bome.balanceOf(U.address)).to.equal(0n);
    expect(await bome.balanceOf(DEAD)).to.equal(PER_LOT * 4n);
    expect(await bome.contributions(U.address)).to.equal(0n);
    await expect(bome.connect(U).claimRefund()).to.be.revertedWith("already refunded");
  });
});

describe("BOME — tax, chunked processing, dividends", function () {
  it("full flow: trade tax, auto + manual slices, claims, inviter +10%", async function () {
    const ctx = await deployAll(await latestTs());
    const { bome, registry, treasury, router, wbnb, signers } = ctx;
    const inviter = signers[7];
    const buyers = signers.slice(20, 520);
    await sellout(bome, registry, buyers, inviter.address);
    expect(await bome.inviterOf(buyers[0].address)).to.equal(inviter.address);

    const pairAddr = await bome.pair();
    const pair = await ethers.getContractAt("MockPancakePair", pairAddr);
    const treasuryBefore = await ethers.provider.getBalance(treasury.address);
    const lpDeadBefore = await pair.balanceOf(DEAD);

    // Sells go through the router, like real trades (pull + swap atomic).
    const sell = async (seller, amount) => {
      await bome.connect(seller).approve(await router.getAddress(), amount);
      await router
        .connect(seller)
        .swapExactTokensForETHSupportingFeeOnTransferTokens(
          amount,
          0,
          [await bome.getAddress(), await wbnb.getAddress()],
          seller.address,
          (await latestTs()) + 600
        );
    };

    // Sells accrue the pot; auto-processing fires at the START of the
    // first trade that finds the pot at/above the 10M trigger (it always
    // processes the pre-existing pot, never the current trade's tax).
    // Each buyer holds 1,111M BOME (20 lots x the full 55.55M).
    await sell(buyers[2], B(1_110_600_000)); // keeps only 400,000 BOME
    expect(await bome.taxPot()).to.equal(B(22_212_000));
    await sell(buyers[0], B(400_000_000)); // auto-processes 22.212M first
    expect(await bome.taxPot()).to.equal(B(8_000_000)); // only its own tax
    await sell(buyers[1], B(400_000_000)); // pot below trigger: no auto
    expect(await bome.taxPot()).to.equal(B(16_000_000));
    // Burn leg of the 22.212M slice: 5% = 1,110,600 BOME to the dead address.
    expect(await bome.balanceOf(DEAD)).to.equal(B(1_110_600));
    // Marketing leg was swapped to BNB and reached the treasury.
    expect(await ethers.provider.getBalance(treasury.address)).to.be.gt(treasuryBefore);
    // Liquidity leg added LP at the dead address.
    expect(await pair.balanceOf(DEAD)).to.be.gt(lpDeadBefore);

    // Process the remaining pot in manual slices, down to zero.
    await bome.processTaxes(B(8_000_000));
    expect(await bome.taxPot()).to.equal(B(8_000_000));
    await bome.processTaxes(B(8_000_000));
    expect(await bome.taxPot()).to.equal(0n);
    await expect(bome.processTaxes(1n)).to.be.revertedWith("exceeds pot");
    await expect(bome.processTaxes(B(50_000_001))).to.be.revertedWith("slice size");

    // Buy side is taxed too: pair sends 100M, buyer receives 98M, pot +2M.
    const b5before = await bome.balanceOf(buyers[5].address);
    await pair.sendToken(await bome.getAddress(), buyers[5].address, B(100_000_000));
    expect(await bome.balanceOf(buyers[5].address)).to.equal(b5before + B(98_000_000));
    expect(await bome.taxPot()).to.equal(B(2_000_000));

    // Dividends are funded SOLELY by the 40% tax legs of the slices
    // processed so far (22.212M auto + 16M manual): no pad exists. Each
    // funding splits two-pot (design A): 10/11 accrues as entitlements
    // in dividendReserve, 1/11 pre-funds inviter bonuses in bonusReserve.
    const entOf = (x) => (B(x) * 10n) / 11n; // per-funding floor, as coded
    const legs = [8_884_800, 3_200_000, 3_200_000];
    const expDiv = legs.reduce((s, x) => s + entOf(x), 0n);
    const expBonus = legs.reduce((s, x) => s + (B(x) - entOf(x)), 0n);
    expect(await bome.dividendReserve()).to.equal(expDiv);
    expect(await bome.bonusReserve()).to.equal(expBonus);
    expect(expDiv + expBonus).to.equal(B(8_884_800) + B(6_400_000));

    // Dividend claim: buyers[0] (invited, holds 711M after its sell)
    // claims in full; the inviter receives exactly +10% on top, claimer
    // not deducted. Each pot falls by exactly its own outflow.
    const claimable = await bome.withdrawableDividendOf(buyers[0].address);
    expect(claimable).to.be.gte(B(1000));
    const inviterBefore = await bome.balanceOf(inviter.address);
    await bome.connect(buyers[0]).claimDividends();
    expect(await bome.balanceOf(buyers[0].address)).to.equal(B(711_000_000) + claimable);
    expect(await bome.balanceOf(inviter.address)).to.equal(inviterBefore + claimable / 10n);
    expect(await bome.dividendReserve()).to.equal(expDiv - claimable);
    expect(await bome.bonusReserve()).to.equal(expBonus - claimable / 10n);
    expect(await bome.withdrawableDividendOf(buyers[0].address)).to.equal(0n);
    // Nothing left to claim -> below the 1,000 BOME minimum.
    await expect(bome.connect(buyers[0]).claimDividends()).to.be.revertedWith("below min claim");
    // buyers[2] kept only 400,000 BOME: entitlement is dust -> reverts too.
    await expect(bome.connect(buyers[2]).claimDividends()).to.be.revertedWith("below min claim");
  });

  it("two-pot stress: sequential invited claims pay in full, bonuses never touch entitlements", async function () {
    const ctx = await deployAll(await latestTs());
    const { bome, registry, router, wbnb, signers } = ctx;
    const inviters = [signers[7], signers[8], signers[9]];
    const buyers = signers.slice(20, 520);
    await grantIds(registry, buyers.map((b) => b.address));
    for (let i = 0; i < buyers.length; i++) {
      const inv = i < 3 ? inviters[i].address : ethers.ZeroAddress;
      await bome.connect(buyers[i]).mint(20, inv, { value: LOT_PRICE * 20n });
    }
    expect(await bome.opened()).to.equal(true);

    const sell = async (seller, amount) => {
      await bome.connect(seller).approve(await router.getAddress(), amount);
      await router
        .connect(seller)
        .swapExactTokensForETHSupportingFeeOnTransferTokens(
          amount,
          0,
          [await bome.getAddress(), await wbnb.getAddress()],
          seller.address,
          (await latestTs()) + 600
        );
    };
    await sell(buyers[3], B(1_110_600_000)); // pot: 22.212M
    await sell(buyers[4], B(400_000_000)); // auto-processes the 22.212M slice first
    await bome.processTaxes(B(8_000_000));
    expect(await bome.taxPot()).to.equal(0n);

    // Total dividend-leg funding: 40% of (22.212M + 8M) = 12,084,800 BOME,
    // split across the two pots with nothing lost.
    const funded = B(8_884_800) + B(3_200_000);
    const divRes0 = await bome.dividendReserve();
    const bonusRes0 = await bome.bonusReserve();
    expect(divRes0 + bonusRes0).to.equal(funded);
    expect(bonusRes0).to.be.gt(0n);

    // The three invited holders hold identical balances -> identical claims.
    const claimables = [];
    for (let i = 0; i < 3; i++) {
      claimables.push(await bome.withdrawableDividendOf(buyers[i].address));
    }
    expect(claimables[0]).to.be.gte(B(1000));
    expect(claimables[1]).to.equal(claimables[0]);
    expect(claimables[2]).to.equal(claimables[0]);

    // Sequential claims: every invitee paid in full, every inviter +10%.
    let claimedTotal = 0n;
    let bonusTotal = 0n;
    for (let i = 0; i < 3; i++) {
      const invBefore = await bome.balanceOf(inviters[i].address);
      await bome.connect(buyers[i]).claimDividends();
      expect(await bome.balanceOf(buyers[i].address)).to.equal(B(1_111_000_000) + claimables[i]);
      expect(await bome.balanceOf(inviters[i].address)).to.equal(invBefore + claimables[i] / 10n);
      claimedTotal += claimables[i];
      bonusTotal += claimables[i] / 10n;
    }
    // Each pot fell by exactly its own outflow; total outflow <= funded.
    expect(await bome.dividendReserve()).to.equal(divRes0 - claimedTotal);
    expect(await bome.bonusReserve()).to.equal(bonusRes0 - bonusTotal);
    expect(claimedTotal + bonusTotal).to.be.lte(funded);

    // The last claimer (no inviter, claims after all bonuses were paid)
    // is still paid in full — bonuses never ate entitlements.
    const last = await bome.withdrawableDividendOf(buyers[5].address);
    expect(last).to.be.gte(B(1000));
    const balBefore = await bome.balanceOf(buyers[5].address);
    await bome.connect(buyers[5]).claimDividends();
    expect(await bome.balanceOf(buyers[5].address)).to.equal(balBefore + last);
    expect(await bome.dividendReserve()).to.equal(divRes0 - claimedTotal - last);
    expect(await bome.bonusReserve()).to.equal(bonusRes0 - bonusTotal);

    // Physical backing: the contract's BOME balance covers both pots
    // plus whatever tax pot remains.
    const contractBal = await bome.balanceOf(await bome.getAddress());
    expect(contractBal).to.be.gte(
      (await bome.dividendReserve()) + (await bome.bonusReserve()) + (await bome.taxPot())
    );
  });
});
