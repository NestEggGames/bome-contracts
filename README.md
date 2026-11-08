# BOME · 迷因之书 / Book of Meme

把全世界的迷因写进同一本书——铸造，就是把你的名字写进书里。本仓库是 BOME 代币与公平铸造合约的完整源码，已在 BNB Smart Chain 主网部署并运行。

A book that collects all the world's memes, co-written by its holders — minting is writing your name into the book. This repository contains the full source of the BOME token and fair-mint contract, deployed and live on BNB Smart Chain mainnet.

- **Contract / 合约地址：** `0x22eDBF20C377629EbC474BEbF5D15EA5A9f28088`
- **BscScan:** https://bscscan.com/address/0x22eDBF20C377629EbC474BEbF5D15EA5A9f28088
- **Website / 官网：** https://bome.lol
- **Chain:** BNB Smart Chain (chainId 56)
- **License:** MIT

## 机制 / Mechanism

总供应 888,800,000,000 BOME，部署时全额铸入合约，此后无任何增发。合约无 owner、无升级代理、无任何部署后可改的开关。

Total supply is 888,800,000,000 BOME, minted in full to the contract at deployment, with no further issuance ever. The contract has no owner, no upgrade proxy, and no post-deployment switches.

- **铸造 / Mint：** 10,000 份，每份 0.003 BNB；每份 **55,550,000 BOME 全额归买家**（铸造共分发 555,500,000,000）。须持有 .ai Agent ID（币安 Agent ID）方可铸造。基础额度每个 Agent ID 20 份，单笔上限 20 份，精确付款、多付回滚。
  10,000 lots at 0.003 BNB each; **the full 55,550,000 BOME per lot goes to the buyer** (555,500,000,000 distributed by minting in total). Minting requires holding an .ai Agent ID. Base quota is 20 lots per Agent ID, per-transaction cap 20 lots, exact payment only.
- **邀请 / Invites：** 邀请成功一份，邀请人额度 +1，上不封顶。邀请关系在被邀请人首次铸造时绑定，不可更改。
  Each successful invite adds +1 lot to the inviter's quota, uncapped. The inviter is bound at the invitee's first mint and is immutable.
- **两种结局 / Two endings only：** 铸造窗口为开启后 24 小时。售罄（10,000 份打满）即开盘——募集的 80%（24 BNB）连同总供应中未铸出的剩余 **333,300,000,000 BOME** 注入 PancakeSwap V2 池，LP 全部打入死地址，另 20%（6 BNB）自动付给项目金库。24 小时未售罄，则全部付款按名单自动原路全额退款，买家已铸的代币同时销毁。
  The mint window is 24 hours. On sellout the pool opens immediately — 80% of the raise (24 BNB) plus the unminted supply remainder of **333,300,000,000 BOME** seed a PancakeSwap V2 pool with LP sent to the dead address, and 20% (6 BNB) is paid to the project treasury. If the sale does not sell out within 24 hours, every payment is automatically refunded in full and the buyers' minted tokens are burned.
- **交易税 / Tax：** 开盘后买卖各 2%，分配为 50% 运营 / 40% 分红 / 5% 销毁 / 5% 回流加池。普通转账不收税。
  After the pool opens, buys and sells carry a 2% tax split 50% marketing / 40% dividends / 5% burn / 5% liquidity. Plain transfers are untaxed.
- **分红（版税）/ Dividends (royalties)：** 以 BOME 本币发放，按合格流通权重分配，自行领取，最低领取 1,000 BOME。分红只来自分红税腿：每次入账按 10/11 记入持有人应得池、1/11 记入邀请奖金池；邀请人永久获得每位被邀请人分红的 +10%，只从奖金池额外发放，绝不扣被邀请人的应得。
  Dividends are paid in BOME itself, weighted by eligible circulating balance, claim-based, minimum claim 1,000 BOME. They are funded solely by the dividend tax leg: each funding splits 10/11 into holder entitlements and 1/11 into a dedicated inviter-bonus reserve. Inviters permanently receive +10% of each invitee's dividend, paid extra from the bonus reserve only — never deducted from the invitee.

## 构建与测试 / Build & Test

Toolchain: Hardhat, Solidity **0.8.28**, `viaIR: true`, optimizer enabled (200 runs), EVM `cancun`.

```bash
npm install
npx hardhat compile
npx hardhat test
```

`test/bome.test.js` runs entirely in-process against mocks in `contracts/mocks/` (mock Agent ID registry, Pancake factory/router/pair) and covers the full lifecycle: gated minting, quota and invite stacking, sellout pool opening, the refund path, tax processing and two-pot dividend claims.

The deployed bytecode was produced from exactly this source with the settings above; the standard-input JSON, constructor arguments and a bytecode-reproduction check are published alongside this repository in the open-source release package.
