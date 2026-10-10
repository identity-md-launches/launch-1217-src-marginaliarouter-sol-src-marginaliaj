# Marginalia — notes in the margin of every trade

A Uniswap v4 hook launch on the IMD protocol (Ethereum mainnet, paired with IMD). Buying MARG through the
router with a note attached posts a call on MARG or a thesis about any ERC-20, backed by a flat stamp
and deposit. Price-scored calls use the bound MARG/IMD pool; arbitrary external venues cannot determine
cash leaderboard payouts. The weekly thesis prize is ranked by the IMD oracle panel.
No owner, no pause, no upgrade. Spec: `SPEC.md`.

## Contracts

| Contract | Role |
|---|---|
| `Marginalia` | The launch ERC-20: 1,000,000,000 × 1e18 minted once to its deployer (the launch factory). |
| `MarginaliaHook` | The hook (flags `0x20cc`): binds the launch pool, takes the stamp and deposit on noted buys and the 1%/3% fee on sells, holds notes, observations, records and the three pools, and pays out. Its constructor clones the three companions (EIP-1167) from audited implementations and initialises each once. |
| `MarginaliaRouter` | The only path that can attach a note; optionally trades X on Uniswap v4, v3 or v2 in the same transaction so the position is proven, and refuses a note about a token other than the one traded. Plain MARG buys and sells go through any v4 router. |
| `MarginaliaJudge` | The oracle consumer: once a week buys the panel's ranking of the week's long-form theses through the IMD Intake, verifies the EIP-712 attestation, tells the hook whom to pay. Short-form calls are never judged. |
| `MarginaliaTreasury` | Receives prizes and gifts in IMD; drips 2% of its IMD into the pot daily. No withdraw, no ETH. |

## How the pot pays

Every IMD accrual (stamps, sell fees, converted forfeits, treasury drips) splits at accrual time:

| Share | Pool | Paid to |
|---|---|---|
| 50% | the week's leaderboard | every wallet with a positive net score from calls resolved that week, pro-rata by score, capped at 10% per wallet; `claimLeaderboard(week)` after the week ends |
| 30% | the week's thesis prize | the panel's top three long-form theses, 50/30/20, after `requestJudging(week)` and `payJudged(week)` |
| 20% | the day's writer refund | every non-retracted note of the day, equal split, capped at one stamp; `claimRefund(id)` after the day ends |

Unclaimed pools roll forward after 28 days (`sweep`). Expired writer refunds move to the current week's
leaderboard and thesis prizes in a 5:3 ratio. A swept leaderboard stops accepting claims. A live oracle
request or an unpaid ranking reserves its thesis prize; an expired unanswered request permits sweeping.
Leaderboard scores are difficulty-weighted, netted against wrong calls, and capped.

## Deployment order

1. Contracts-only launch (evm_contracts, no constructor arguments): `MarginaliaRouter`, `MarginaliaJudge`,
   `MarginaliaTreasury` implementations. Each constructor fills its own init guard, so the published
   implementations can never be initialised; only their clones can, once. See `ADAPTATION.md`.
2. Set the three addresses in `src/MarginaliaImpls.sol`.
3. Hook launch (manifest draft in `jobs/launch-hook.json`): the factory deploys the token and the hook; the
   hook's constructor clones the three implementations and initialises each with itself in the same transaction.

The hook's initcode and runtime must fit the EIP-3860 (49,152) and EIP-170 (24,576) caps;
`forge build --sizes` is the gate for both.

## Build and test

Solidity 0.8.26, Cancun, via-IR, optimizer 200 runs, `bytecode_hash = "none"`. All dependencies are
vendored under `lib/` (versions in `dependencies.json`); no network is needed to build or run the unit tests.

```sh
forge build --sizes
forge test --no-match-path 'test/fork/*'
```

The fork rehearsal deploys through the real IMD LaunchFactory on an Ethereum mainnet fork, impersonating
the protocol's launch wallet, and then posts a note through the router:

```sh
MAINNET_RPC_URL=https://... forge test --match-path test/fork/MainnetLaunch.t.sol -vvv
```

## Launch

The companions launch first, as a contracts-only launch whose manifest lists `MarginaliaRouter`,
`MarginaliaJudge` and `MarginaliaTreasury` with no constructor arguments. `jobs/launch-hook.json` is the
hook launch's manifest draft: `MarginaliaHook($poolManager, $token, $factory)`, permissions as listed, pool
paired with IMD at fee 12500 / tick spacing 60. The requester's share seeds the pool single-sided; the
swarm's 10% goes to the launch's distributor.

The router only counts a v3 pool or v2 pair the canonical mainnet Uniswap factory knows for its tokens as
a trade (class Traded). The judge pays the Intake's live price up to 1 IMD, may re-request a week whose
request got no answer within 3 days (at most two attempts per week), and stores a ranking with no eligible
thesis as a week with no winners (the prize rolls forward on `payJudged`). Its bounded question directs the
panel to the complete weekly collection through `thesesOfWeek`, or `thesisCount` and `thesisAt`, and to the
`NotePosted` texts. It never truncates the eligible set. The treasury takes no ETH. `sweep(2, week)` rolls
an unjudged week's thesis pool forward after 28 days, once any pending request expires.

## v1 scope and known limits

- Price-scored calls are limited to MARG on the bound MARG/IMD pool, with correct subject, quote and
  direction, and at least 1,000 IMD of active virtual quote depth at posting and observation. Calls on
  arbitrary external tokens need a trustworthy pricing path before they can be enabled. All ERC-20s
  remain available for trade-and-thesis notes. This removes self-priced cash leaderboard claims;
  the existing multi-block median is still a spot-price design and can be affected by market manipulation.
- Sells of MARG pay 3% through any router, or 1% plus the stamp through `sellWithNote` with a note and deposit attached.
- The X trade leg supports v4 pools (including native-ETH outputs), v3 pools and v2 pairs; exact-input only.
  V2 measures taxed inputs on both transfers. V3 and v4 enforce exact settlement and may reject transfer-tax
  tokens even after the router measures its input budget.
- The implementation addresses in `MarginaliaImpls.sol` are rehearsal placeholders; tests etch code there.
  The later hook constructor refuses codeless targets. Replace these with this launch's confirmed addresses.
- Unobserved noted sells forfeit their deposit; buy notes retain their existing no-data refund.
- Pot conversions are permissionless once per UTC day, capped at 1% of active virtual MARG depth, with
  at least 95% of the pre-sale spot value required. This bounds sale impact, not prior price manipulation.
  Unconverted claims remain in `potMarg`; a partial fill reverts. Deposits can always be taken as MARG;
  use `claimDeposit(id, true, minImdOut)` for an author-chosen conversion minimum. The compatible two-argument
  overload has no author-chosen minimum.
- Self-declared Attested notes are downgraded; only the implemented trade path can prove a Traded class.
- The action fee on follow trades, treasury conversion of ETH/USDC/USDT to IMD, the on-chain ERC-8004 agent
  badge (contract wallets are marked Agent), and attestation re-delivery are specified but not yet built.
- The judge binds an answer to the Intake request it paid for; it does not recompute the oracle's
  canonical question hash.
