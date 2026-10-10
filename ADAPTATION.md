# Adaptation for the contracts-only launch of the Marginalia companions

This launch deploys the three EIP-1167 implementation targets on Ethereum mainnet (chain id 1), each with
no constructor arguments: `MarginaliaRouter`, `MarginaliaJudge`, `MarginaliaTreasury`. A later univ4_hook
launch (`MarginaliaHook`) clones them in its constructor and calls each clone's one-shot `init`. No token,
pool or hook is deployed here. Nothing has an owner, a pause or an upgrade.

Every change below is the smallest one that satisfies a launch rule or fixes an audit finding that
reproduced. The contracts' economics (judge threshold 2 IMD, oracle price 0.5 IMD, prize split 50/30/20,
treasury drip 2% a day, no action fee) are untouched.

## Launch rules

| Change | File | Why |
|---|---|---|
| Each implementation's constructor fills its own init guard (`hook = address(this)`; the judge's placeholder oracle signer is also `address(this)`, since the base refuses zero). Constructors take no arguments and call no contract. | `src/MarginaliaRouter.sol`, `src/MarginaliaJudge.sol`, `src/MarginaliaTreasury.sol` | The launch policy forbids configuration after deployment, and the constructor runs on an empty chain in the launch checks. Clones start with empty storage, so the hook's `init` on each clone still runs exactly once (audit finding 892269e9…, which reproduced: before this change anyone could call `init` on the published implementations and point them at a hook of their choosing; `test/Companions.t.sol::testImplementationsCannotBeInitialised`, `testClonesInitialiseOnce`). |
| `launch.json` moved to `jobs/launch-hook.json`; its notes now say the judge buys one ranking per week. | `jobs/launch-hook.json` | The file in the tree was the later hook launch's univ4_hook manifest, not this evm_contracts launch's, and a launch.json in the builder's tree is checked as this launch's manifest (audit finding cdada475…). The manifest step writes this launch's `launch.json`: kind `evm_contracts`, contracts `MarginaliaRouter`, `MarginaliaJudge`, `MarginaliaTreasury`, each with `constructorArgs: []`. The hook launch's manifest is kept for that launch. |

Not changed, by the rules: `foundry.toml` (already `bytecode_hash = "none"`), `remappings.txt`, `lib/`,
`dependencies.json`. The three runtimes contain no DELEGATECALL, CALLCODE or SELFDESTRUCT and are 14,052 /
10,334 / 1,427 bytes (the protected evm_contracts floor was rehearsed locally with the built bytecode and
passes). All library calls (`OracleAttestation`, `MarginaliaTypes`, `PriceAdapters`, `Clones`, OpenZeppelin
`SafeERC20`) are internal, so the bytecode is fully linked.

## Audit findings that reproduced, and their fixes

| Finding | Fix | Test |
|---|---|---|
| **[high] 7b7670f6… Judge: an unanswered or rejected oracle request locks the week's thesis prize forever.** Reproduced: `requestJudging(w)` reverted `AlreadyRequested` for ever once the Intake never called back. | `src/MarginaliaJudge.sol`: `requestedAt[week]` and `REQUEST_TTL = 3 days`. A week whose request got no answer by then may be requested again; the old request id is forgotten (`pendingDay` deleted, `RequestCleared` emitted), so a late answer to it is refused with `UnknownRequest`. A delivered ranking that names none of the week's theses is stored as a judged week with no winners (`Judged` with three zero ids) instead of reverting, so `payJudged` rolls the pool into the current week, as the oracle-consumer reference requires ("a no answer is a result to store, never a revert"). A judged week can no longer be re-requested (`AlreadyJudged`). | `testUnansweredRequestCanBeMadeAgain`, `testNoWinnersIsStoredAndRollsThePoolForward`, `JudgeConformance.t.sol::test_refusesTheWrongSenderTamperingAndExpiry` |
| **[high] 1aaa3f75… Thesis pool of any week with no thesis, or under the 2 IMD threshold, is locked forever.** Reproduced: after a treasury drip in a quiet week, `thesisPool(w)` stayed at 60 IMD with no path out. | `src/MarginaliaHook.sol`: `sweep(2, week)` rolls a week's thesis pool into the current week once the week is over plus `SWEEP_AFTER`, exactly as kinds 0 and 1 do for the refund and leaderboard pools. This is the hook's code, which the later univ4_hook launch deploys; the fix is in this repository so that launch carries it. Hook runtime is 23,091 bytes (cap 24,576), initcode 24,650 (cap 49,152). | `testQuietWeekThesisPoolRollsForward` (the audit's proof, with its `sweep(2, w)` call) |
| **[medium] c991c78c… Judge: request body passes the Intake's 16 KiB limit at ~230 theses; quadratic concat.** Reproduced: 256 theses gave an 18,217-byte body at ~30M gas. | `src/MarginaliaJudge.sol`: `MAX_JUDGED = 200`: the first 200 theses posted in a week (posting order) are put to the panel, which keeps the body near 14 KiB on any chain id; the allow list is written once into a buffer of its exact size (linear). A full week of 256 theses now requests at ~5M gas. | `testBodyStaysUnderTheIntakeLimitWithAFullWeek`, `testQuestionBodyShape` |
| **[medium] b76d0406… Judge: exact-equality check against `JUDGE_PRICE` stops all judging if the Intake price moves.** Reproduced: 0.6 or 0.4 IMD reverted `PriceMismatch`. | `src/MarginaliaJudge.sol`: the live `priceOf` is paid as it is, up to `PRICE_CAP_BPS = 20_000` (twice the hook's `JUDGE_PRICE`, i.e. at most 1 IMD); zero or above the cap still reverts. The action id stays fixed at `init` by the hook: the brief asks for no owner on any contract, so a new Intake action version (`oracle-2`) would need a new hook launch. That is a documented limit, not a change. The live price was read from the mainnet Intake while adapting: 0.5 IMD. | `testJudgePaysTheLivePriceUpToACap` |
| **[medium] 892269e9… Implementations are initialisable by anyone.** Reproduced. | See "Launch rules" above. | `testImplementationsCannotBeInitialised`, `testClonesInitialiseOnce` |
| **[medium] 2961f6c1… Router: a user-supplied v3/v2 pool lets a note claim class Traded without a real trade.** Reproduced: a pool contract of the caller's own passed. | `src/MarginaliaRouter.sol`: `V3_FACTORY` (0x1F98431c8aD98523631AE4a59f267346ea31F984) and `V2_FACTORY` (0x5C69bEe701ef814a2B6a3EDD4B1652CB9cc5aA6f), Ethereum mainnet's canonical Uniswap factories, as constants like the hook's other mainnet addresses. `_tradeV3` requires `factory.getPool(token0, token1, pool.fee()) == pool`; `_tradeV2` requires `factory.getPair(token0, token1) == pair`; otherwise `UnknownVenue`. Checked on use, never in the constructor. Both addresses were verified on mainnet while adapting (`cast code` shows code; `feeAmountTickSpacing(500)` returns 10 on the v3 factory; `allPairsLength()` returns ~524k on the v2 factory). The hook is bound to one chain by its own constants, so a per-chain argument would add nothing. | `testFakeV3PoolCannotProveATrade`, `testFakeV2PairCannotProveATrade`, `testCanonicalV2PairProvesATrade`, `testV3LegBuyingImdWorks` |
| **[low] 76d699df… Router: a v3 X leg that sells IMD always reverts.** Reproduced: the leftover sweep refunded the note's IMD and underflowed. | `src/MarginaliaRouter.sol::_tradeV3`: the leg's spend is the router's balance delta of `tokenIn` across the swap; only `amountIn - spent` is refunded. | `testV3LegSellingImdRefundsOnlyTheUnspentPart` |
| **[low] d7b0ec7f… Treasury accepts ETH that can never leave.** Reproduced. | `src/MarginaliaTreasury.sol`: `receive()` and the `Received` event removed; ETH sent to the treasury or its clones reverts. Other ERC-20s handed in still cannot be moved (v1 has no conversion); the NatSpec says so. | `testTreasuryRejectsEth` |
| **[low] 7f2be1db… Judge accepts attestations from a smaller panel than it asked for.** Reproduced. | `src/MarginaliaJudge.sol::onOracleResult`: `a.panelSize < PANEL_SIZE` is `BadAnswer`, beside the existing `agreed >= quorum` and `quorum >= QUORUM` checks. | `testJudgeRefusesASmallerPanel` |
| **[low] cdada475… launch.json in the tree is the later univ4_hook manifest.** Reproduced. | See "Launch rules" above. `src/MarginaliaImpls.sol` still holds the rehearsal placeholders: the three addresses this launch produces are not known until it runs, and the hook launch must set them before it builds (a clone of a codeless address accepts `init` silently). | n/a |
| [info] 80f2085a… scope statement. | Nothing to do. | n/a |

None of the eleven findings failed to reproduce.

## Also added

- `test/JudgeConformance.t.sol`: the oracle-consumer reference's conformance test with `MarginaliaJudge` as the
  consumer, deployed (as a clone would be: runtime code at a fresh address, then `init`) at the protocol's vector
  address on the vector's chain. It pins the digest to the protocol's vector digest, the callback selector to
  the canonical one (`0x510379c7`), and exercises delivery under the 200,000-gas stipend, the wrong sender,
  an unknown id, a tampered attestation, an expired one, replay, and the clear-after-deadline path.
- `testCallbackFitsTheIntakeStipend`: a three-winner ranking delivered with exactly 200,000 gas.

## Verification

```
forge build --sizes
forge test                                  # 40 tests: Lifecycle 20, Companions 16, JudgeConformance 4; fork suite skipped
```

The protected evm_contracts floor (`Contracts.protected.t.sol`) was rehearsed locally against the built
bytecode of the three contracts with generated salts and predicted addresses, and passes.

- `test/fork/MainnetLaunch.t.sol`: `setUp` now reads `MAINNET_RPC_URL` with `vm.envOr` and calls `vm.skip`
  when it is unset, instead of `vm.envString`, which reverted and failed the suite. Required by the launch
  rule that tests pass with an empty environment and no network under a plain `forge test`. With the
  variable set the rehearsal runs unchanged; it needs a mainnet RPC and was not run here.

## Open items for the deployer and the hook launch

- After this launch, set `ROUTER_IMPL`, `JUDGE_IMPL` and `TREASURY_IMPL` in `src/MarginaliaImpls.sol` to
  the deployed addresses before the hook launch builds.
- The hook launch's manifest draft is `jobs/launch-hook.json`.
- The judge's Intake action id and oracle signer are fixed at the hook's constants (`oracle.request@oracle-1`,
  signer 0x5598Aa9146215Bc13eb26f2c692Ad1461Fd32982, an EOA on mainnet today). With no owner anywhere, a
  changed action id or signer needs a new hook launch; a moved price up to 1 IMD does not.
