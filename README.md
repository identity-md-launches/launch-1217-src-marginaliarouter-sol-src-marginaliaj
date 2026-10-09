# Marginalia — notes in the margin of every trade

A Uniswap v4 hook launch on the IMD protocol (Ethereum mainnet, paired with IMD). Buying MARG through the
router with a note attached posts a falsifiable call on any ERC-20, backed by a flat stamp and a flat
refundable deposit. Calls resolve against on-chain price observations; right calls get their deposit back,
everything else feeds a pot that pays the best-argued notes of the day, ranked by the IMD oracle panel.
No owner, no pause, no upgrade. Spec: `SPEC.md`.

## Contracts

| Contract | Role |
|---|---|
| `Marginalia` | The launch ERC-20: 1,000,000,000 × 1e18 minted once to its deployer (the launch factory). |
| `MarginaliaHook` | The hook (flags `0x20cc`): binds the launch pool, takes the stamp and deposit on noted buys and the 1%/3% fee on sells, holds notes, observations, records and the pot, and pays out. Its constructor deploys the three companions. |
| `MarginaliaRouter` | The only path that can attach a note; optionally trades X on Uniswap v4, v3 or v2 in the same transaction so the position is proven, and refuses a note about a token other than the one traded. Plain MARG buys and sells go through any v4 router. |
| `MarginaliaJudge` | The oracle consumer: buys one panel ranking per day through the IMD Intake, verifies the EIP-712 attestation, tells the hook whom to pay. |
| `MarginaliaTreasury` | Receives prizes and gifts; drips 2% of its IMD into the pot daily. No withdraw. |

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

`launch.json` is the factory manifest: `MarginaliaHook($poolManager, $token, $factory)`, permissions as
listed, pool paired with IMD at fee 12500 / tick spacing 60. The requester's share seeds the pool
single-sided; the swarm's 10% goes to the launch's distributor.

## v1 scope and known limits

- Price adapters assume 18-decimal assets on both sides. Quotes other than IMD, ETH or WETH are refused.
- Sells of MARG always pay the 3% quiet fee in v1 (the 1% noted-sell discount is specified, not built).
- The X trade leg supports v4 pools (including native-ETH pairs), v3 pools and v2 pairs; exact-input only.
- The hook's initcode embeds its three companions and must stay under EIP-3860's 49,152 bytes; `forge build --sizes` is the gate (the fork test does not enforce it).
- The action fee on follow trades, treasury conversion of ETH/USDC/USDT to IMD, the on-chain ERC-8004 agent
  badge (contract wallets are marked Agent), and attestation re-delivery are specified but not yet built.
- The judge binds an answer to the Intake request it paid for; it does not recompute the oracle's
  canonical question hash.
