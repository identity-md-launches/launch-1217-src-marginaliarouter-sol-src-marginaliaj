# Companion test coverage

Run offline with `forge build` and `forge test --no-match-path 'test/fork/*'`.
No new dependency, RPC, environment mutation, or production/configuration change is needed.

These tests extend the existing lifecycle and protocol-vector suites:

- `CompanionInitialization.t.sol`: argument-free implementation deployment, runtime limits and forbidden opcodes, real EIP-1167 clones initialized during a constructor, invalid initialization rollback, clone isolation, domain separation, and absent administrative entry points.
- `RouterAdversarial.t.sol`: real local v4 settlement and partial fills, both directions on v2/v3/v4, input limits and deadlines, canonical venue checks, callback authentication, subject binding, both slippage limits, atomic rollback, exact payer accounting, and preservation of unsolicited donations.
- `RouterTokenCompatibility.t.sol`: six-decimal units, optional ERC-20 return values, false returns, blocked transfers, token reentrancy, recipient-net output slippage, and twice-taxed v2 inputs. The input regression checks exact user debit, both burns, real pair reserves, preserved router donations, and atomic rollback of burns/allowances on either leg's slippage. A fully taxed input must revert without spending donations.
- `TreasuryBoundaries.t.sol`: empty/dust balances, 49/50-wei boundary, permissionless calls, UTC day rollover, missed days, rounding, same-day donations, reentrancy, and rollback after the hook pulls funds then reverts.
- `CompanionBlockPrice.t.sol`: what the companions see of the hook's block-open price (`blockPrice`): a same-block pump cannot lower the noted-sell minimum or deposit (the exact `NoteTooSmall` boundary, wrapped by the PoolManager, with full rollback), a same-block dump raises the deposit and sets the price the author must beat, a traded note whose X leg is the bound pool itself posts at the author's own pushed price with both outputs delivered, a sell call with a buy leg is refused as a subject mismatch, and a forfeit conversion delivers at least the judge's 95% floor of the spot it reads. The judge's floor follows the calling transaction's spot rather than the block-open price; that gap is reported in `.imd-findings.json` with a failing proof, not asserted.
- `JudgeAdversarial.t.sol`: real signatures verified through an ERC-1271 signer model; clone/chain/wrong-key rejection; timestamp, panel, quorum and answer decoding boundaries; threshold and price cap; request/payment rollback; two-attempt retry budget; exact request-expiry boundary; active request collisions; complete-collection JSON body parsing; filtering and deduplication; callback gas stipend; 50/30/20 payment and replay prevention. A failed retry preserves its accounting but cannot revive the expired original request.

`../invariant/CompanionConservation.t.sol` runs 256 sequences of 64 calls with three funded actors and `fail-on-revert = true`. Its handler mixes notes, buys/sells, donations, time advancement, treasury drips, oracle requests/answers/payments, thesis forfeitures and conversions, and unauthorized callbacks. Expected refusal paths are asserted explicitly. A deterministic setup reaches payment and conversion before fuzzing, so the properties also exercise nonempty state.

The four invariant groups check:

1. Treasury donations equal its remaining IMD plus all drips; at most one successful drip per UTC day and no leftover hook approval.
2. Router and judge balances equal only tracked unsolicited donations; requests pay exactly their price; approvals clear; note authors and token deltas match the acting user.
3. The real PoolManager's IMD claims back the sum of all touched refund/leaderboard/thesis pools, and MARG claims back note deposits plus forfeitures.
4. Accepted oracle UUIDs stay consumed, judged weeks stay judged, each week pays at most once, and each week buys at most two requests. Conversions occur at most once per UTC day, sell at most 1% of pre-swap virtual MARG reserves, and burn/credit exactly the corresponding PoolManager claims.

The handler explicitly checks expired callbacks, exhausted retries, first-request-only threshold eligibility, and same-day conversion refusals. A deterministic sequence also reaches these revised failure paths, then checks all four invariant groups. The original custody assertions remain in place; expected refusals do not suppress unexpected reverts.

The bounded invariant campaign uses standard IMD/MARG tokens, fixed oracle price, and modest trades within seeded liquidity. It does not claim exhaustive hook settlement, liquidity exhaustion, mainnet deployment, or live oracle availability coverage. Stateful token transfers, allowances and v4 balances are real local contract calls. The v2 model enforces stored reserves, the 0.3% fee and constant product, but omits flash swaps, LP shares and TWAP state. V3 uses the existing canonical-factory and partial-fill callback model. Live v2/v3/Intake integration remains a fork/deployment rehearsal outside this offline suite; the preexisting fork suite skips when no RPC is configured.

The prior round's v2 input-tax finding is fixed in the supplied implementation: the router now measures its initial receipt before forwarding the input. The added deterministic and 1,000-run fuzz regressions exercise that fix against `CheckedV2Pair`, including rounding and unrelated donations. This revision changes only tests and this coverage note; it retains the existing deployment, treasury, protocol-vector, lifecycle, and hook regression suites.

Revision verification: `forge build` passed; `forge test --no-match-path 'test/fork/*'` passed all 117 tests; default `forge test` passed 117 tests with zero failures and one skipped fork suite (no RPC configured). All four invariants passed across 256 sequences of 64 calls, with zero unexpected reverts. Build artifacts and logs were directed to `test/scratch/`; no configuration or dependency changes are needed to reproduce the suite.
