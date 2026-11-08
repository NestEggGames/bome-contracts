// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @notice .ai Agent ID registry (ERC-721 subset, same interface as the
/// shipped BNBCAT v5 / NestEgg code): gate = balanceOf > 0.
interface IAgentIdRegistry {
    function balanceOf(address owner) external view returns (uint256);
    function handleOf(address owner) external view returns (string memory);
}

/// @notice PancakeSwap V2 factory (subset).
interface IPancakeFactory {
    function getPair(address tokenA, address tokenB) external view returns (address pair);
    function createPair(address tokenA, address tokenB) external returns (address pair);
}

/// @notice PancakeSwap V2 pair (subset).
interface IPancakePair {
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    function token0() external view returns (address);
    function token1() external view returns (address);
    function totalSupply() external view returns (uint256);
    function balanceOf(address owner) external view returns (uint256);
    function mint(address to) external returns (uint256 liquidity);
    function skim(address to) external;
    function sync() external;
}

/// @notice PancakeSwap V2 router (subset: fee-on-transfer sells + LP adds).
/// @dev swapExactTokensForETHSupportingFeeOnTransferTokens returns
/// NOTHING on the real router — declaring a return value here makes
/// every call revert on returndata decoding against the production
/// router (Grok audit 2026-11-09). Callers must measure the BNB delta.
interface IPancakeRouter {
    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;

    function addLiquidityETH(
        address token,
        uint256 amountTokenDesired,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to,
        uint256 deadline
    ) external payable returns (uint256 amountToken, uint256 amountETH, uint256 liquidity);
}

/// @notice WBNB (subset).
interface IWETH {
    function deposit() external payable;
    function withdraw(uint256) external;
    function transfer(address to, uint256 value) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

/// @title BOME — Book of Meme (BSC)
/// @notice Single-contract clone of the FLOKI AGENT mechanics per SPEC v0.2:
/// fixed-lot fair mint (10,000 lots x 0.003 BNB) behind the .ai Agent ID
/// gate, invite quota stacking, sellout-only pool opening (24 BNB + 333.3B
/// BOME into Pancake V2, LP to the dead address, 6 BNB to treasury), a 24h
/// full-refund ending if the sale does not sell out, a 2% trade tax split
/// 50/40/5/5 (marketing / dividends / burn / liquidity), and dividends paid
/// in BOME itself with a permanent +10% inviter bonus on every claim.
///
/// Deliberate deviations from the original (SPEC section 6): NO proxy, NO
/// owner, NO post-deployment setters of any kind — every address and
/// parameter is fixed in the constructor. Every lot is backed by a real
/// payment held in this contract; nothing is pre-written into the state.
contract BOME is ERC20, ReentrancyGuard {
    // ------------------------------------------------------------------
    // Constants (SPEC v0.2 parameter table)
    // ------------------------------------------------------------------
    uint256 public constant TOTAL_SUPPLY = 888_800_000_000 ether; // 888.8B
    uint256 public constant TOTAL_LOTS = 10_000;
    uint256 public constant LOT_PRICE = 0.003 ether;
    /// Every lot pays the buyer the FULL 55,550,000 BOME. Chain-verified
    /// against the original (2026-11-09 correction): FLOKI's pre-open mint
    /// transfers are all exact multiples of 55,550,000 — nothing is
    /// deducted per lot. (The original's liquidityTokensPerLot of
    /// 33,330,000 is per-lot ACCOUNTING of the pool reserve below, and
    /// its 60% MINT_LP_BPS applies to the BNB leg only.)
    uint256 public constant TOKENS_PER_LOT = 55_550_000 ether;
    /// Tokens distributed to buyers across the whole sale:
    /// 10,000 x 55,550,000 = 555.5B.
    uint256 public constant SALE_TOKENS = 555_500_000_000 ether;
    /// Tokens seeded into the opening pool: 333.3B — the non-sale
    /// remainder of the supply (888.8B total - 555.5B sale). It is NOT
    /// withheld from buyers; SALE_TOKENS + POOL_TOKENS == TOTAL_SUPPLY,
    /// so no internal account remains: dividends are funded solely by
    /// the 40% tax legs accumulated after the open (see _fundDividends).
    uint256 public constant POOL_TOKENS = 333_300_000_000 ether;
    uint256 public constant BASE_QUOTA = 20;
    uint256 public constant MAX_PER_TX = 20;
    uint256 public constant MINT_WINDOW = 24 hours;
    /// Of the 30 BNB raised at sellout: 80% seeds the pool, 20% treasury.
    uint256 public constant POOL_BNB = 24 ether;
    uint256 public constant TREASURY_BNB = 6 ether;

    uint256 public constant TAX_BPS = 200; // 2% on pair buys/sells
    uint256 public constant MARKETING_BPS = 5000; // of the tax
    uint256 public constant DIVIDEND_BPS = 4000;
    uint256 public constant BURN_BPS = 500;
    // liquidity leg takes the remainder of each slice (no dust stranded)

    /// Auto tax processing fires once the pot reaches this size (SPEC:
    /// minimum trigger 10,000,000 BOME, mirroring the original).
    uint256 public constant MIN_TAX_PROCESS = 10_000_000 ether;
    /// Chunked settlement (NewWolf deadlock lesson): one processTaxes call
    /// handles at most MAX_TAX_SLICE, and at most MAX_TAX_PER_BLOCK is
    /// processed per block (the "averaging window" that keeps any single
    /// sell slice small against the pool). The pot is never sold whole.
    uint256 public constant MAX_TAX_SLICE = 50_000_000 ether;
    uint256 public constant MAX_TAX_PER_BLOCK = 50_000_000 ether;

    uint256 public constant MIN_DIVIDEND_CLAIM = 1_000 ether;
    uint256 public constant INVITER_DIVIDEND_BPS = 1000; // +10% of each claim

    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;
    uint256 internal constant MAGNITUDE = 2 ** 128;

    // ------------------------------------------------------------------
    // Immutable wiring (constructor-fixed, no setters — SPEC section 6)
    // ------------------------------------------------------------------
    IAgentIdRegistry public immutable registry;
    IPancakeFactory public immutable factory;
    IPancakeRouter public immutable router;
    address public immutable wbnb;
    bytes32 public immutable pairInitCodeHash;
    /// Treasury AND marketing wallet are the same project wallet (SPEC s.8).
    address public immutable treasury;
    uint256 public immutable startTime;
    uint256 public immutable endTime;
    /// CREATE2 address of the BOME/WBNB pair, known before it exists
    /// (ported from BNBCAT v5 CheeseToken).
    address public immutable predictedPair;

    // ------------------------------------------------------------------
    // Mint state
    // ------------------------------------------------------------------
    uint256 public totalLotsMinted;
    uint256 public saleTokensRemaining;
    uint256 public poolReserveTokens;
    mapping(address => uint256) public mintedLots;
    mapping(address => uint256) public bonusQuota;
    mapping(address => address) public inviterOf;
    mapping(address => bool) public hasMinted;
    /// Contributor roster (first-mint order) + paid-in BNB per wallet,
    /// used by the push-refund path. contributions[x] is zeroed on refund.
    address[] public contributors;
    mapping(address => uint256) public contributions;
    mapping(address => bool) public refunded;
    uint256 public refundCursor;

    // ------------------------------------------------------------------
    // Pool / tax state
    // ------------------------------------------------------------------
    bool public opened;
    address public pair;
    uint256 public taxPot;
    uint256 public lastTaxBlock;
    uint256 public taxProcessedInBlock;
    bool internal _inTaxProcessing;
    /// @dev Set only inside _burnMintedTokens so the refund burn
    /// (buyer -> DEAD) can pass the pre-open transfer lock.
    bool internal _inRefundBurn;

    // ------------------------------------------------------------------
    // Dividend state (magnified dividend-per-token, paid in BOME)
    // ------------------------------------------------------------------
    uint256 public dividendReserve;
    /// @notice Pre-funded inviter-bonus pot (see _fundDividends): bonuses
    /// are paid ONLY from here, never from dividendReserve, so a bonus can
    /// never consume another holder's entitlement.
    uint256 public bonusReserve;
    uint256 public magnifiedDividendPerToken;
    mapping(address => int256) internal _dividendCorrections;
    mapping(address => uint256) public withdrawnDividends;
    /// Sum of balances that earn dividends (excludes this contract, the
    /// pair, the router and the dead address).
    uint256 public eligibleSupply;

    // ------------------------------------------------------------------
    // Events
    // ------------------------------------------------------------------
    event Minted(address indexed buyer, uint256 lots, uint256 paidBNB);
    event InviterBound(address indexed inviter, address indexed invitee);
    event PoolOpened(address indexed pair, uint256 bnbSeeded, uint256 tokensSeeded, uint256 treasuryPaid);
    event Refunded(address indexed contributor, uint256 amountBNB);
    event RefundFailed(address indexed contributor, uint256 amountBNB);
    event TaxCollected(address indexed from, uint256 amount);
    event TaxProcessed(uint256 amount, uint256 marketingBNB, uint256 dividendTokens, uint256 burnedTokens, uint256 liquidityTokens);
    event DividendsClaimed(address indexed holder, uint256 amount, address indexed inviter, uint256 inviterBonus);

    constructor(
        uint256 startTime_,
        address registry_,
        address factory_,
        address router_,
        address wbnb_,
        bytes32 pairInitCodeHash_,
        address treasury_
    ) ERC20("BOME", "BOME") {
        require(startTime_ > 0, "start");
        require(registry_ != address(0) && factory_ != address(0) && router_ != address(0), "zero addr");
        require(wbnb_ != address(0) && treasury_ != address(0), "zero addr");
        registry = IAgentIdRegistry(registry_);
        factory = IPancakeFactory(factory_);
        router = IPancakeRouter(router_);
        wbnb = wbnb_;
        pairInitCodeHash = pairInitCodeHash_;
        treasury = treasury_;
        startTime = startTime_;
        endTime = startTime_ + MINT_WINDOW;
        predictedPair = _pairFor(address(this), wbnb_, factory_, pairInitCodeHash_);

        // Whole supply minted once, to this contract; sub-accounts below
        // isolate it (SPEC section 3.1). Nothing is pre-sold or pre-held
        // by any wallet.
        _mint(address(this), TOTAL_SUPPLY);
        saleTokensRemaining = SALE_TOKENS;
        poolReserveTokens = POOL_TOKENS;
        // dividendReserve deliberately starts at ZERO: the sale and pool
        // allocations above exhaust the supply, and dividends are funded
        // solely by the 40% tax legs credited by _fundDividends after
        // the pool opens. There is no pre-seeded dividend pad.
    }

    receive() external payable {}

    // ------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------
    function quotaOf(address user) public view returns (uint256) {
        return BASE_QUOTA + bonusQuota[user];
    }

    function contributorsLength() external view returns (uint256) {
        return contributors.length;
    }

    function refundsActive() public view returns (bool) {
        return !opened && block.timestamp >= endTime && totalLotsMinted < TOTAL_LOTS;
    }

    function accumulativeDividendOf(address account) public view returns (uint256) {
        int256 v = int256(magnifiedDividendPerToken * balanceOf(account)) + _dividendCorrections[account];
        if (v <= 0) return 0;
        return uint256(v) / MAGNITUDE;
    }

    function withdrawableDividendOf(address account) public view returns (uint256) {
        uint256 acc = accumulativeDividendOf(account);
        uint256 withdrawn = withdrawnDividends[account];
        return acc > withdrawn ? acc - withdrawn : 0;
    }

    // ------------------------------------------------------------------
    // Mint
    // ------------------------------------------------------------------
    /// @notice Buy `lots` lots at exactly 0.003 BNB each. `inviter` binds
    /// permanently at the buyer's FIRST mint (zero address = none); the
    /// binding grants the inviter +1 lot of quota per invited person,
    /// stacking without cap on top of the base quota (SPEC section 2).
    function mint(uint256 lots, address inviter) external payable nonReentrant {
        require(block.timestamp >= startTime, "not started");
        require(block.timestamp < endTime, "mint ended");
        require(!opened, "opened");
        require(lots >= 1 && lots <= MAX_PER_TX, "lots per tx");
        require(msg.value == lots * LOT_PRICE, "exact payment");
        require(registry.balanceOf(msg.sender) > 0, "no agent id");
        require(totalLotsMinted + lots <= TOTAL_LOTS, "sold out");
        require(mintedLots[msg.sender] + lots <= quotaOf(msg.sender), "quota exceeded");

        if (!hasMinted[msg.sender]) {
            hasMinted[msg.sender] = true;
            contributors.push(msg.sender);
            if (inviter != address(0) && inviter != msg.sender) {
                inviterOf[msg.sender] = inviter;
                bonusQuota[inviter] += 1;
                emit InviterBound(inviter, msg.sender);
            }
        }

        mintedLots[msg.sender] += lots;
        contributions[msg.sender] += msg.value;
        totalLotsMinted += lots;
        uint256 userTokens = lots * TOKENS_PER_LOT;
        saleTokensRemaining -= userTokens;
        // Issuance out of the contract's sale account. Transfers are
        // otherwise locked until the pool opens (see _update).
        _update(address(this), msg.sender, userTokens);
        emit Minted(msg.sender, lots, msg.value);

        if (totalLotsMinted == TOTAL_LOTS) {
            _settleAndOpen();
        }
    }

    // ------------------------------------------------------------------
    // Sellout settlement: open the pool (dust-tolerant, ported pattern)
    // ------------------------------------------------------------------
    /// @dev Pool opening follows the BNBCAT v5 fix-F1 pattern, adapted to a
    /// single contract:
    ///  - The pair address is CREATE2-predicted in the constructor and the
    ///    token gates transfers into it until the open (see _update), so
    ///    BOME-side seeding/syncing by third parties is impossible.
    ///  - WBNB-side donations are still possible (WBNB is a foreign
    ///    token): unsynced excess is skimmed back and recovered, and any
    ///    WBNB already synced into reserves is FOLDED into the seed (it
    ///    can only add value to a pool whose LP is burned) — the open
    ///    never requires an untouched pair (AGENTS.md dust lesson).
    ///  - Liquidity is seeded by direct transfer + pair.mint, never via
    ///    router.addLiquidity (which would follow a poisoned ratio).
    function _settleAndOpen() internal {
        address p = factory.getPair(address(this), wbnb);
        if (p == address(0)) {
            p = factory.createPair(address(this), wbnb);
        }
        require(p == predictedPair, "pair mismatch");
        // A real LP position cannot exist yet: minting LP needs BOME in
        // the pair, and BOME cannot enter the pair before this moment.
        require(IPancakePair(p).totalSupply() == 0, "pair seeded");
        pair = p;
        opened = true;

        // Recover unsynced donations (skim moves balance-over-reserve).
        IPancakePair(p).skim(address(this));
        uint256 recoveredBnb = 0;
        uint256 skimmedWbnb = IWETH(wbnb).balanceOf(address(this));
        if (skimmedWbnb > 0) {
            IWETH(wbnb).withdraw(skimmedWbnb);
            recoveredBnb = skimmedWbnb;
        }

        // Synced dust check: the BOME reserve must be zero (gate), the
        // WBNB reserve may hold folded-in dust.
        (uint112 r0, uint112 r1,) = IPancakePair(p).getReserves();
        uint256 rBome = IPancakePair(p).token0() == address(this) ? uint256(r0) : uint256(r1);
        require(rBome == 0, "bome in pair");

        // Seed exactly 24 BNB + the full 333.3B reserve on top of any
        // folded dust; all LP goes to the dead address.
        uint256 seedTokens = poolReserveTokens;
        poolReserveTokens = 0;
        _update(address(this), p, seedTokens);
        IWETH(wbnb).deposit{value: POOL_BNB}();
        require(IWETH(wbnb).transfer(p, POOL_BNB), "wbnb xfer");
        require(IPancakePair(p).mint(DEAD) > 0, "zero liquidity");

        // 20% treasury leg (6 BNB) plus any skim-recovered donation BNB.
        uint256 toTreasury = TREASURY_BNB + recoveredBnb;
        (bool ok,) = treasury.call{value: toTreasury}("");
        require(ok, "treasury pay");
        emit PoolOpened(p, POOL_BNB, seedTokens, toTreasury);
    }

    // ------------------------------------------------------------------
    // Refund path (24h elapsed, not sold out): push refunds, batched
    // ------------------------------------------------------------------
    /// @notice Anyone can push refunds to the contributor roster, in
    /// batches. Each contributor is refunded 100% of what they paid,
    /// exactly once. A contributor whose wallet rejects BNB is skipped
    /// (marked failed, state restored) and can self-claim via
    /// claimRefund() — one bad wallet can never stall the batch.
    function refundBatch(uint256 maxCount) external nonReentrant returns (uint256 processed) {
        require(refundsActive(), "refunds not active");
        uint256 n = contributors.length;
        while (processed < maxCount && refundCursor < n) {
            address c = contributors[refundCursor];
            refundCursor++;
            if (refunded[c]) continue;
            uint256 amt = contributions[c];
            if (amt == 0) continue;
            refunded[c] = true;
            uint256 lots = mintedLots[c];
            mintedLots[c] = 0;
            contributions[c] = 0;
            processed++;
            (bool ok,) = c.call{value: amt}("");
            if (ok) {
                _burnMintedTokens(c, lots);
                emit Refunded(c, amt);
            } else {
                refunded[c] = false;
                contributions[c] = amt;
                mintedLots[c] = lots;
                emit RefundFailed(c, amt);
            }
        }
    }

    /// @notice Self-service fallback for a contributor whose push refund
    /// failed (e.g. a wallet that rejects plain BNB transfers).
    function claimRefund() external nonReentrant {
        require(refundsActive(), "refunds not active");
        require(!refunded[msg.sender], "already refunded");
        uint256 amt = contributions[msg.sender];
        require(amt > 0, "nothing to refund");
        refunded[msg.sender] = true;
        uint256 lots = mintedLots[msg.sender];
        mintedLots[msg.sender] = 0;
        contributions[msg.sender] = 0;
        (bool ok,) = msg.sender.call{value: amt}("");
        require(ok, "refund transfer failed");
        _burnMintedTokens(msg.sender, lots);
        emit Refunded(msg.sender, amt);
    }

    /// @dev On a paid refund, the buyer's minted BOME is burned in the
    /// same flow (moved to the dead address, like the tax burn leg;
    /// totalSupply is unchanged). Capped at the buyer's actual balance so
    /// a discrepancy can never block or revert the BNB refund.
    function _burnMintedTokens(address buyer, uint256 lots) internal {
        uint256 amt = lots * TOKENS_PER_LOT;
        uint256 bal = balanceOf(buyer);
        if (amt > bal) amt = bal;
        if (amt > 0) {
            bool prev = _inRefundBurn;
            _inRefundBurn = true;
            _update(buyer, DEAD, amt);
            _inRefundBurn = prev;
        }
    }

    // ------------------------------------------------------------------
    // Tax processing — chunked by design (never whole-pot)
    // ------------------------------------------------------------------
    /// @notice Process one slice of the tax pot. Permissionless.
    /// Slice split (of the BOME slice): 50% marketing (swapped to BNB,
    /// straight to the project wallet), 40% dividends (kept in BOME,
    /// credited to holders), 5% burned (to the dead address), remainder
    /// (~5%) liquidity (half swapped to BNB, re-paired, LP to dead).
    function processTaxes(uint256 amount) public nonReentrant returns (uint256 processed) {
        require(opened, "not opened");
        require(amount > 0 && amount <= MAX_TAX_SLICE, "slice size");
        require(amount <= taxPot, "exceeds pot");
        if (block.number != lastTaxBlock) {
            lastTaxBlock = block.number;
            taxProcessedInBlock = 0;
        }
        require(taxProcessedInBlock + amount <= MAX_TAX_PER_BLOCK, "block cap");
        taxProcessedInBlock += amount;
        taxPot -= amount;
        processed = amount;

        uint256 marketing = (amount * MARKETING_BPS) / 10_000;
        uint256 dividend = (amount * DIVIDEND_BPS) / 10_000;
        uint256 burn = (amount * BURN_BPS) / 10_000;
        uint256 liquidity = amount - marketing - dividend - burn;

        bool prev = _inTaxProcessing;
        _inTaxProcessing = true;

        if (burn > 0) {
            _update(address(this), DEAD, burn);
        }
        if (dividend > 0) {
            _fundDividends(dividend);
        }
        uint256 marketingBnb = 0;
        if (marketing > 0) {
            marketingBnb = _swapBomeForBnb(marketing, treasury);
        }
        if (liquidity > 0) {
            uint256 half = liquidity / 2;
            uint256 bnbOut = half > 0 ? _swapBomeForBnb(half, address(this)) : 0;
            uint256 tokenPart = liquidity - half;
            if (bnbOut > 0 && tokenPart > 0) {
                _approve(address(this), address(router), tokenPart);
                // LP straight to the dead address; mins are 95% of the
                // intended amounts (enough slack for quote drift between
                // the swap and the add, tight enough to blunt sandwiching);
                // any leftover dust simply stays in this contract.
                router.addLiquidityETH{value: bnbOut}(
                    address(this),
                    tokenPart,
                    (tokenPart * 95) / 100,
                    (bnbOut * 95) / 100,
                    DEAD,
                    block.timestamp + 600
                );
            }
        }

        _inTaxProcessing = prev;
        emit TaxProcessed(amount, marketingBnb, dividend, burn, liquidity);
    }

    /// @dev Two-pot funding (design A, user-approved 2026-11-09): of each
    /// dividend-leg amount, 10/11 accrues as holder entitlements
    /// (dividendReserve + the magnified index) and 1/11 pre-funds the
    /// inviter-bonus pot (bonusReserve). A claim's +10% inviter bonus is
    /// at most 10% of that claim, and bonuses in aggregate can never
    /// exceed 1/11 of total funding = 10% of the 10/11 entitlement pool —
    /// so the bonus pot is structurally sufficient while entitlement
    /// claims are backed solely by dividendReserve and can never come up
    /// short because of a bonus.
    function _fundDividends(uint256 amount) internal {
        uint256 entitlementPart = (amount * 10) / 11;
        bonusReserve += amount - entitlementPart;
        dividendReserve += entitlementPart;
        if (eligibleSupply > 0) {
            magnifiedDividendPerToken += (entitlementPart * MAGNITUDE) / eligibleSupply;
        }
        // If nobody is eligible yet the entitlement part simply waits in
        // dividendReserve; it is credited by later distributions'
        // accounting. The bonus part waits in bonusReserve the same way.
    }

    /// @dev Spot quote from the pair with the Pancake 0.25% fee, used only
    /// to derive a 2%-slippage minOut for tax swaps (anti-dump window).
    function _quoteBnbOut(uint256 amountIn) internal view returns (uint256) {
        (uint112 r0, uint112 r1,) = IPancakePair(pair).getReserves();
        (uint256 rIn, uint256 rOut) =
            IPancakePair(pair).token0() == address(this) ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
        if (rIn == 0 || rOut == 0) return 0;
        uint256 inWithFee = amountIn * 9975;
        return (inWithFee * rOut) / (rIn * 10_000 + inWithFee);
    }

    /// @dev The real router's fee-on-transfer sell returns nothing, so the
    /// BNB received is measured as the recipient's balance delta.
    function _swapBomeForBnb(uint256 amount, address to) internal returns (uint256 bnbOut) {
        _approve(address(this), address(router), amount);
        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = wbnb;
        uint256 minOut = (_quoteBnbOut(amount) * 98) / 100;
        uint256 balBefore = to.balance;
        router.swapExactTokensForETHSupportingFeeOnTransferTokens(amount, minOut, path, to, block.timestamp + 600);
        bnbOut = to.balance - balBefore;
    }

    function _maybeAutoProcessTaxes() internal {
        if (_inTaxProcessing || taxPot < MIN_TAX_PROCESS) return;
        uint256 slice = taxPot < MAX_TAX_SLICE ? taxPot : MAX_TAX_SLICE;
        try this.processTaxes(slice) {} catch {}
    }

    // ------------------------------------------------------------------
    // Dividends (paid in BOME; inviter earns +10% on top, SPEC section 2)
    // ------------------------------------------------------------------
    /// @notice Claim accrued dividends. Minimum claim 1,000 BOME.
    /// @dev Referral accounting (two-pot, design A): the claim itself is
    /// paid in full from dividendReserve, which backs ONLY holder
    /// entitlements (see _fundDividends) — it can never be short because
    /// of bonuses. The inviter's bonus is amount/10 paid ON TOP of the
    /// claim (the claimer is never deducted), drawn SOLELY from
    /// bonusReserve — the 1/11 slice pre-funded at every distribution —
    /// and is skipped for that claim only if the bonus pot does not
    /// cover it. The bonus is a plain transfer to the inviter; it does
    /// not alter the inviter's own dividend entitlement bookkeeping
    /// (their corrections are adjusted by the balance change itself,
    /// keeping their accrual exact).
    function claimDividends() external nonReentrant returns (uint256 amount) {
        amount = withdrawableDividendOf(msg.sender);
        require(amount >= MIN_DIVIDEND_CLAIM, "below min claim");
        withdrawnDividends[msg.sender] += amount;
        dividendReserve -= amount;
        _update(address(this), msg.sender, amount);

        uint256 bonus = 0;
        address inviter = inviterOf[msg.sender];
        if (inviter != address(0)) {
            bonus = (amount * INVITER_DIVIDEND_BPS) / 10_000;
            if (bonus > 0 && bonusReserve >= bonus) {
                bonusReserve -= bonus;
                _update(address(this), inviter, bonus);
            } else {
                bonus = 0;
            }
        }
        emit DividendsClaimed(msg.sender, amount, inviter, bonus);
    }

    // ------------------------------------------------------------------
    // Transfer logic: pre-open lock + pair gate + trade tax
    // ------------------------------------------------------------------
    function _isDividendExcluded(address account) internal view returns (bool) {
        return account == address(0) || account == address(this) || account == pair
            || account == predictedPair || account == DEAD || account == address(router);
    }

    function _applyDividendDelta(address account, int256 delta) internal {
        if (delta == 0 || _isDividendExcluded(account)) return;
        if (delta > 0) {
            _dividendCorrections[account] -= int256(magnifiedDividendPerToken * uint256(delta));
            eligibleSupply += uint256(delta);
        } else {
            _dividendCorrections[account] += int256(magnifiedDividendPerToken * uint256(-delta));
            eligibleSupply -= uint256(-delta);
        }
    }

    function _moveWithAccounting(address from, address to, uint256 value) internal {
        if (value == 0) return;
        super._update(from, to, value);
        _applyDividendDelta(from, -int256(value));
        _applyDividendDelta(to, int256(value));
    }

    function _update(address from, address to, uint256 value) internal override {
        // Deployment mint (to this contract) and nothing else with a zero
        // side ever occurs: the burn leg goes to DEAD, not address(0).
        if (from == address(0) || to == address(0)) {
            super._update(from, to, value);
            return;
        }

        if (!opened) {
            // Pair gate (BNBCAT v5 fix F1): nothing enters the predicted
            // pair before the open except this contract's own seed move.
            if (to == predictedPair) {
                require(from == address(this), "pair gated");
            }
            // Mint-phase lock: tokens are non-transferable until the pool
            // opens; only the contract itself moves tokens (issuance),
            // plus the refund burn (buyer -> DEAD) inside a paid refund.
            require(from == address(this) || _inRefundBurn, "transfers locked");
            _moveWithAccounting(from, to, value);
            return;
        }

        // Post-open: 2% tax on pair buys/sells only; plain transfers and
        // this contract's own moves (seed, tax swaps, claims) are exempt.
        uint256 tax = 0;
        address p = pair;
        if (
            value > 0 && p != address(0) && from != address(this) && to != address(this)
                && (from == p || to == p)
        ) {
            tax = (value * TAX_BPS) / 10_000;
        }
        if (tax == 0) {
            _moveWithAccounting(from, to, value);
        } else {
            // Process the EXISTING pot before this trade's tax lands.
            // Doing it afterwards would let the nested tax swaps sync the
            // pair's reserves over this trade's just-arrived tokens and
            // corrupt the outer router swap's input measurement (the
            // classic in-transfer auto-swap desync). The nested attempt is
            // try/caught, so a locked/failing pair can never brick a trade.
            _maybeAutoProcessTaxes();
            _moveWithAccounting(from, to, value - tax);
            _moveWithAccounting(from, address(this), tax);
            taxPot += tax;
            emit TaxCollected(from, tax);
        }
    }

    // ------------------------------------------------------------------
    // CREATE2 pair prediction (ported verbatim from BNBCAT v5)
    // ------------------------------------------------------------------
    function _pairFor(address tokenA, address tokenB, address factory_, bytes32 initHash)
        internal
        pure
        returns (address pair_)
    {
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        pair_ = address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(hex"ff", factory_, keccak256(abi.encodePacked(token0, token1)), initHash)
                    )
                )
            )
        );
    }
}
