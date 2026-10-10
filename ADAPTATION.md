# Adaptation for the contracts-only launch of the Marginalia companions

This launch deploys the three EIP-1167 implementation targets on Ethereum mainnet (chain id 1), each with
no constructor arguments: `MarginaliaRouter`, `MarginaliaJudge`, `MarginaliaTreasury`. A later univ4_hook
launch (`MarginaliaHook`) clones them in its constructor and calls each clone's one-shot `init`. No token,
pool or hook is deployed here. Nothing has an owner, a pause or an upgrade.

The accepted launch adaptation is retained, with the bounded revision below for reproduced findings.
Core rates remain judge threshold 2 IMD, reference oracle price 0.5 IMD, prize split 50/30/20,
treasury drip 2% a day, and no action fee. New validation and recovery limits are documented explicitly.

## Launch rules

| Change | File | Why |
|---|---|---|
| Each implementation's constructor fills its own init guard (`hook = address(this)`; the judge's placeholder oracle signer is also `address(this)`, since the base refuses zero). Constructors take no arguments and call no contract. | `src/MarginaliaRouter.sol`, `src/MarginaliaJudge.sol`, `src/MarginaliaTreasury.sol` | The launch policy forbids configuration after deployment, and the constructor runs on an empty chain in the launch checks. Clones start with empty storage, so the hook's `init` on each clone still runs exactly once (audit finding 892269e9…, which reproduced: before this change anyone could call `init` on the published implementations and point them at a hook of their choosing; `test/Companions.t.sol::testImplementationsCannotBeInitialised`, `testClonesInitialiseOnce`). |
| `launch.json` moved to `jobs/launch-hook.json`; its notes now say the judge buys one ranking per week. | `jobs/launch-hook.json` | The file in the tree was the later hook launch's univ4_hook manifest, not this evm_contracts launch's, and a launch.json in the builder's tree is checked as this launch's manifest (audit finding cdada475…). The manifest step writes this launch's `launch.json`: kind `evm_contracts`, contracts `MarginaliaRouter`, `MarginaliaJudge`, `MarginaliaTreasury`, each with `constructorArgs: []`. The hook launch's manifest is kept for that launch. |

Not changed, by the rules: `foundry.toml` (already `bytecode_hash = "none"`), `remappings.txt`, `lib/`,
`dependencies.json`. The three runtimes contain no DELEGATECALL, CALLCODE or SELFDESTRUCT and are 14,581 /
12,176 / 1,427 bytes (the protected evm_contracts floor was rehearsed locally with the built bytecode and
passes). All library calls (`OracleAttestation`, `MarginaliaTypes`, `PriceAdapters`, `Clones`, OpenZeppelin
`SafeERC20`) are internal, so the bytecode is fully linked.

## Imported audit findings addressed in the accepted round

| Finding | Fix | Test |
|---|---|---|
| **[high] 7b7670f6… Judge: an unanswered or rejected oracle request locks the week's thesis prize forever.** Reproduced: `requestJudging(w)` reverted `AlreadyRequested` for ever once the Intake never called back. | `src/MarginaliaJudge.sol`: `requestedAt[week]` and `REQUEST_TTL = 3 days`. A week whose request got no answer by then may be requested again; the old request id is forgotten (`pendingDay` deleted, `RequestCleared` emitted), so a late answer to it is refused with `UnknownRequest`. A delivered ranking that names none of the week's theses is stored as a judged week with no winners (`Judged` with three zero ids) instead of reverting, so `payJudged` rolls the pool into the current week, as the oracle-consumer reference requires ("a no answer is a result to store, never a revert"). A judged week can no longer be re-requested (`AlreadyJudged`). | `testUnansweredRequestCanBeMadeAgain`, `testNoWinnersIsStoredAndRollsThePoolForward`, `JudgeConformance.t.sol::test_refusesTheWrongSenderTamperingAndExpiry` |
| **[high] 1aaa3f75… Thesis pool of any week with no thesis, or under the 2 IMD threshold, is locked forever.** Reproduced: after a treasury drip in a quiet week, `thesisPool(w)` stayed at 60 IMD with no path out. | `src/MarginaliaHook.sol`: `sweep(2, week)` rolls a week's thesis pool into the current week once the week is over plus `SWEEP_AFTER`, exactly as kinds 0 and 1 do for the refund and leaderboard pools. This is the hook's code, which the later univ4_hook launch deploys; the fix is in this repository so that launch carries it. Hook runtime is 23,611 bytes (cap 24,576), initcode 25,263 (cap 49,152). | `testQuietWeekThesisPoolRollsForward` (the audit's proof, with its `sweep(2, w)` call) |
| **[medium] c991c78c… Judge: request body passes the Intake's 16 KiB limit at ~230 theses; quadratic concat.** Reproduced: 256 theses gave an 18,217-byte body at ~30M gas. | The accepted round bounded the list to 200 ids. This revision replaces that truncation with a bounded question naming the complete on-chain weekly collection and its `NotePosted` texts. The panel can enumerate `thesisCount` and `thesisAt`; request generation never serializes an unbounded array. | `testBodyStaysUnderTheIntakeLimitWithAFullWeek`, `testQuestionBodyShape` |
| **[medium] b76d0406… Judge: exact-equality check against `JUDGE_PRICE` stops all judging if the Intake price moves.** Reproduced: 0.6 or 0.4 IMD reverted `PriceMismatch`. | `src/MarginaliaJudge.sol`: the live `priceOf` is paid as it is, up to `PRICE_CAP_BPS = 20_000` (twice the hook's `JUDGE_PRICE`, i.e. at most 1 IMD); zero or above the cap still reverts. The action id stays fixed at `init` by the hook: the brief asks for no owner on any contract, so a new Intake action version (`oracle-2`) would need a new hook launch. That is a documented limit, not a change. The live price was read from the mainnet Intake while adapting: 0.5 IMD. | `testJudgePaysTheLivePriceUpToACap` |
| **[medium] 892269e9… Implementations are initialisable by anyone.** Reproduced. | See "Launch rules" above. | `testImplementationsCannotBeInitialised`, `testClonesInitialiseOnce` |
| **[medium] 2961f6c1… Router: a user-supplied v3/v2 pool lets a note claim class Traded without a real trade.** Reproduced: a pool contract of the caller's own passed. | `src/MarginaliaRouter.sol`: `V3_FACTORY` (0x1F98431c8aD98523631AE4a59f267346ea31F984) and `V2_FACTORY` (0x5C69bEe701ef814a2B6a3EDD4B1652CB9cc5aA6f), Ethereum mainnet's canonical Uniswap factories, as constants like the hook's other mainnet addresses. `_tradeV3` requires `factory.getPool(token0, token1, pool.fee()) == pool`; `_tradeV2` requires `factory.getPair(token0, token1) == pair`; otherwise `UnknownVenue`. Checked on use, never in the constructor. Both addresses were verified on mainnet while adapting (`cast code` shows code; `feeAmountTickSpacing(500)` returns 10 on the v3 factory; `allPairsLength()` returns ~524k on the v2 factory). The hook is bound to one chain by its own constants, so a per-chain argument would add nothing. | `testFakeV3PoolCannotProveATrade`, `testFakeV2PairCannotProveATrade`, `testCanonicalV2PairProvesATrade`, `testV3LegBuyingImdWorks` |
| **[low] 76d699df… Router: a v3 X leg that sells IMD always reverts.** Reproduced: the leftover sweep refunded the note's IMD and underflowed. | `src/MarginaliaRouter.sol::_tradeV3`: the leg's spend is the router's balance delta of `tokenIn` across the swap; only `amountIn - spent` is refunded. | `testV3LegSellingImdRefundsOnlyTheUnspentPart` |
| **[low] d7b0ec7f… Treasury accepts ETH that can never leave.** Reproduced. | `src/MarginaliaTreasury.sol`: `receive()` and the `Received` event removed; ETH sent to the treasury or its clones reverts. Other ERC-20s handed in still cannot be moved (v1 has no conversion); the NatSpec says so. | `testTreasuryRejectsEth` |
| **[low] 7f2be1db… Judge accepts attestations from a smaller panel than it asked for.** Reproduced. | `src/MarginaliaJudge.sol::onOracleResult`: `a.panelSize < PANEL_SIZE` is `BadAnswer`, beside the existing `agreed >= quorum` and `quorum >= QUORUM` checks. | `testJudgeRefusesASmallerPanel` |
| **[low] cdada475… launch.json in the tree is the later univ4_hook manifest.** Reproduced. | See "Launch rules" above. `src/MarginaliaImpls.sol` still holds the rehearsal placeholders: the three addresses this launch produces are not known until it runs, and the hook launch must set them before it builds (a clone of a codeless address accepts `init` silently). | n/a |
| [info] 80f2085a… scope statement. | Nothing to do. | n/a |

The substantive imported findings reproduced before the accepted adaptation. Against this revision's starting tree, their fixes remain effective; `.imd-responses.json` records that distinction and treats the scope statement as informational.

## Also added

- `test/JudgeConformance.t.sol`: the oracle-consumer reference's conformance test with `MarginaliaJudge` as the
  consumer, deployed (as a clone would be: runtime code at a fresh address, then `init`) at the protocol's vector
  address on the vector's chain. It pins the digest to the protocol's vector digest, the callback selector to
  the canonical one (`0x510379c7`), and exercises delivery under the 200,000-gas stipend, the wrong sender,
  an unknown id, a tampered attestation, an expired one, replay, and the clear-after-deadline path.
- `testCallbackFitsTheIntakeStipend`: a three-winner ranking delivered with exactly 200,000 gas.

## Revision: findings reproduced on the accepted tree

All seven required revision findings reproduced. Both held proofs failed on the starting tree; the two
older recovery proofs passed. `test/Revision.t.sol` adds durable regressions; the supplied unedited
proofs were also copied to `test/scratch/` and run. The latter directory is not part of the deliverable.

| Finding | Files and final change | Why / coverage |
|---|---|---|
| d40af08d… self-priced leaderboard | `src/MarginaliaHook.sol`: scored calls require `x == token`, the bound v4 pool id, IMD quote and correct orientation. Require 1,000 IMD of active virtual quote depth at posting and observation. Read that bound pool directly; remove the now-unreachable arbitrary venue pricing path. | A canonical author-created X market still permits self-pricing, so this v1 fails closed for external price-scored calls. Other tokens can still be traded and discussed as theses. Tests cover wrong subject/id/quote/orientation, thin liquidity, and a real author-created v4 pool that is refused for scoring but accepts a traded thesis. The exact fake-v3 proof passes. The bound pool's multi-block spot median is not a TWAP; market manipulation remains a pricing limitation. |
| 7dd819bb… leaderboard double payment | `src/MarginaliaHook.sol`: `leaderboardShare` returns zero when `leaderboardSwept >= leaderboardPool`. Keep the historical pro-rata base for unswept claims. | A sweep closes late claims; a repeated sweep returns `NothingToSweep`. The regression claims once, sweeps, refuses another scorer, and checks IMD claims equal live pool obligations. |
| cd552717… sweeping unpaid rankings | `src/MarginaliaJudge.sol::canSweep`, `src/MarginaliaHook.sol::sweep`: reserve prizes for live requests and judged-but-unpaid weeks. Expired unanswered requests can roll forward; their callbacks are refused at the request deadline. | Pending and stored rankings survive the 28-day sweep date. Tests pay the original 50% first prize after a refused sweep and cover expired requests, roll-forward, and a late callback. |
| cc4a1693… codeless implementations | `src/MarginaliaHook.sol` constructor checks all three implementation addresses have code before cloning. | The hook fails deployment instead of silently producing dead companions. Each absent target is tested independently, and the exact CREATE2 proof passes. This companions launch still takes no arguments and makes no constructor calls. |
| 03c58cf7… first-come judged set | `src/MarginaliaHook.sol`: retain every thesis id, add count/index views. `src/MarginaliaJudge.sol`: remove the first-200 allow-list and direct the panel to the complete collection on the named chain, hook and week. Use the count view to test eligibility without copying all ids into the request transaction. | A 257th thesis remains eligible after 256 earlier posts. The JSON body stays bounded irrespective of count; callback filtering still enforces author existence, thesis type and exact week. `test/Companions.t.sol` now checks the complete-collection question instead of the superseded truncated list. Spam can increase the panel's reading workload but cannot exclude a later id from the allow-list. |
| 1b744c9a… refund surplus | `src/MarginaliaHook.sol::sweep(0)`: move the entire expired refund balance into current leaderboard/thesis prizes in a 5:3 ratio. | Claimants have the existing 28-day window and one-stamp cap. Expired balances no longer cycle through another capped refund day. Tested with a 100,000 IMD treasury drip and a refund claim. |
| 3eeb7022… partial-fill lost claims | `src/MarginaliaHook.sol` ACT_SELL requires consumed MARG equals the requested amount, otherwise `PartialFill`. | A reverted sale preserves the swap, pot/deposit balance and ERC-6909 claims atomically. Tests exhaust pool liquidity for both pot and deposit conversions and assert all unsold MARG is still tracked. |

The advisory findings also reproduced and received focused fixes:

| Finding | Files and change | Coverage / limits |
|---|---|---|
| c9e1bc46… unbounded pot/deposit sale | `src/MarginaliaJudge.sol::convertForfeits`: at most one successful conversion per UTC day, at most 1% of active virtual MARG depth, and output at least 95% of the pre-sale spot value. `src/MarginaliaHook.sol::sellPotMarg` enforces that minimum; `claimDeposit(id, asImd, minImdOut)` adds the author's minimum. | Tests retain the rest of a large pot, refuse another same-day conversion, finish next day, and roll back a failed deposit minimum. This bounds execution size/impact; it does not authenticate a price already manipulated before the call. The original two-argument deposit call remains compatible and should be replaced by the minimum-bearing overload in clients. |
| bfe6008c… unauthenticated Attested class | `src/MarginaliaHook.sol`: downgrade Attested to Declared unless a real trade proves Traded; contract authors remain Agent. | Direct EOA class-3 posting stores Declared. No note-attestation path was added. |
| d854241c… pre-delivery hold balance | `src/MarginaliaHook.sol`: add the pending net MARG buy output, or unused noted-sell input, to the already-updated author balance. | The router pulls MARG before a sell, so it is not subtracted twice. Tests assert post-transaction balance for both sides and VOID_SOLD after selling exactly the bought amount. |
| d902949e… unlimited paid retries | `src/MarginaliaJudge.sol`: two attempts maximum per week, retaining the three-day retry deadline. | A third draw is refused; expired unjudged pools remain sweepable after 28 days. |
| b1a49e42… retry threshold | `src/MarginaliaHook.sol::drawForJudging`: apply 2 IMD eligibility only on the first attempt; every draw must still fit the remaining pool. | A 2.13 IMD initial pool can fund the retry after the first price draw puts it below 2 IMD. |
| 96ebb1e9… unobserved noted-sell refund | `src/MarginaliaHook.sol`: remember noted sells and forfeit their deposit on VOID_NO_DATA. Keep the existing keeper percentage and buy-note no-data refund. | A 90-day unobserved noted sell cannot reclaim its discounted sale's bond. This puts the bond at risk; it does not claim to make the unchanged keeper reward cover mainnet gas. |
| 67955a40… taxed X input | `src/MarginaliaRouter.sol::_run`: measure the actual input balance delta before forwarding a v2/v3 leg; reject zero or oversized budgets. | A twice-taxed v2 input succeeds without using the note's IMD or leaving router dust. V3 and v4 themselves require exact settlement and can still reject tokens taxing the pool receipt; the router cannot change that protocol limitation. |

`test/JudgeConformance.t.sol` adds the count view and revised sale signature to its stub; vector constants,
digest, callback selector and signature checks are unchanged. `test/fork/MainnetLaunch.t.sol` now exercises
external X trades with theses, since arbitrary external spot prices no longer qualify for scoring.
`README.md` describes these user-visible limits. No build configuration or dependency was changed.

## Second revision: the flash-observation finding (392cb896…)

The independent reviewer's single required finding reproduced on the accepted tree, with the reviewer's own
numbers. A contract that, inside one `poolManager.unlock`, bought 5,900 IMD of MARG on a pool 100x the depth
floor (spot +12%), called `observe` for three sybil +10% calls, sold the MARG back and settled only the
net IMD, made all three observations in three transactions 25 blocks apart; every call settled Right and
the sybils claimed 3,077.77 IMD of the week's leaderboard pool against 946.02 IMD of fees. No MARG was
held across any block. The accepted "≥3 observations ≥20 blocks apart, median" mitigation assumed a
manipulator must hold the moved price across the gaps; with flash accounting it did not have to.

The advisory finding (6218b3e5…, the reviewer's settlement of the prior round) reports no defect: the 13
confirmed fixes were left as they are.

| Finding | Files and change | Why / coverage |
|---|---|---|
| **392cb896… flash-manipulated observation price.** Reproduced: `forge test --match-path test/scratch/ProofFlashObserve.t.sol` failed on the starting tree with `3077769634732647735453 != 0`. | `src/MarginaliaHook.sol`: the reviewer's suggested fix, which keeps the design. `beforeSwap` records the pool's price before the first swap of each block (`blockOpenPrice`, `lastSwapBlock`); every price move on the bound pool is a swap through this hook, so that is the price the block opened at. `blockPrice()` returns it while `lastSwapBlock == block.number` and the spot otherwise. `observe` stores `blockPrice()`: a swap earlier or later in the same block, by anyone, cannot set an observation, so a manipulator must hold a moved price across the 20-block gaps between the three observations, exposed to arbitrage, which is the model the SPEC's median assumes. The same vector exists at posting, where a flash dump before `router.note` (or pump before `sellWithNote`) would set a depressed or inflated `postPrice` that an unmoved market then "beats": `postPrice` is now the price least favourable to the author among the block-open and the spot price (`_postingPrice`: the higher for a Buy, the lower for a Sell), which leaves the author's own swap impact counted exactly as before and makes an in-block move before the post worthless. A noted sell's deposit is sized at the lower of the two prices, so a flash pump cannot shrink the MARG at stake. Nothing else changes: the gap, the minimum of three, the median, the 6-hour window, the depth floor and all pool accounting are untouched. Hook runtime grows from 23,611 to 23,873 bytes (703 below EIP-170). | `test/Revision.t.sol`: `testRevisionFlashObservationReadsTheBlockOpenPrice` (the reviewer's scenario, with a `FlashObserver` contract that asserts a zero MARG delta: every call settles Wrong, `leaderboardShare` is 0 and `claimLeaderboard` reverts `NothingToClaim`); `testRevisionObservationIgnoresASwapLaterInTheBlock` (a pump after the observation in the same block is not read; held across the gap it is); `testRevisionFlashMoveBeforePostingCannotSetThePostPrice` (a same-block dump before a Buy post and pump before a Sell post leave `postPrice` at the block-open price, and the sell deposit at the larger size); `testRevisionHeldMoveStillSettlesRight` (a genuine, held move still scores Right through the existing path). The reviewer's unedited scenario was also run as `test/scratch/ProofFlashObserve.t.sol` and passes. |

Residual, stated for the hook launch's review: this is still not a TWAP. A manipulator who moves the price
in block N and holds it until an observation in block N+1 (and does so three times, 20+ blocks apart) is
not stopped by the block-open price; what stops them is that the position is held across a block boundary
each time, open to arbitrage and to competing observers who can call `observe` for the note in block N
itself (the gap counts from the last stored observation, so a timely honest observation in block N locks the
moved price out of block N+1 as well). The SPEC's `univ4-spot` oracle recipe remains the documented
escalation if that proves too thin; it is a design change and was not made here.

## Verification

Final checks passed with the project's unchanged Foundry configuration:

- `forge build` passed. `forge build --skip test --sizes` also passed: router 14,581 bytes, judge 12,176,
  treasury 1,427 (all three unchanged by this revision); hook 23,873 bytes (703 bytes below EIP-170), hook
  initcode 25,525 bytes.
- `forge test --no-match-path 'test/fork/*'` passed: 67 tests, zero failures (66 durable project tests
  plus the reviewer's scenario under `test/scratch/`). The first revision added 22 tests; this one adds 4.
- The three implementation targets' source and bytecode are unchanged by this revision, so the
  `Contracts.protected.t.sol` rehearsal result below stands.
- The protected `Contracts.protected.t.sol` rehearsal passed with the built bytecode of all three
  implementation targets: no-argument nonpayable constructors deploy on an empty chain through the
  CREATE2 probe, predicted addresses match, runtimes fit, and no forbidden escape opcode exists. The
  temporary harness was removed after running so plain `forge test` needs no harness environment.
- All constructor ABI inputs are empty and their bytecode link-reference tables are empty.
- The callback passes with an EOA signature and cold storage under 200,000 gas, as well as the existing
  protocol digest/selector/vector and ERC-1271 checks.
- `.imd-responses.json` answers both of this round's finding ids. `git diff --check` passes.

The fork suite requires a mainnet RPC and was skipped. Slither and Mythril were not run. No transactions
are broadcast and no wallet keys are read; the network's later manifest/deployment step launches the
three reviewed implementations.

## Open items for the deployer and the hook launch

- After this launch, set `ROUTER_IMPL`, `JUDGE_IMPL` and `TREASURY_IMPL` in `src/MarginaliaImpls.sol` to
  the deployed addresses before the hook launch builds.
- The hook launch's manifest draft is `jobs/launch-hook.json`.
- The judge's Intake action id and oracle signer are fixed at the hook's constants (`oracle.request@oracle-1`,
  signer 0x5598Aa9146215Bc13eb26f2c692Ad1461Fd32982, an EOA on mainnet today). With no owner anywhere, a
  changed action id or signer needs a new hook launch; a moved price up to 1 IMD does not.
