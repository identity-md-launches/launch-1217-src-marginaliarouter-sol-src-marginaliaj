# Companion test coverage

Run offline with `forge build` and `forge test --no-match-path 'test/fork/*'`.
No new dependency, RPC, environment mutation, or production/configuration change is needed.

These tests extend the existing lifecycle and protocol-vector suites:

- `CompanionInitialization.t.sol`: argument-free implementation deployment, runtime limits and forbidden opcodes, real EIP-1167 clones initialized during a constructor, invalid initialization rollback, clone isolation, domain separation, and absent administrative entry points.
- `RouterAdversarial.t.sol`: real local v4 settlement and partial fills, both directions on v2/v3/v4, input limits and deadlines, canonical venue checks, callback authentication, subject binding, both slippage limits, atomic rollback, exact payer accounting, and preservation of unsolicited donations.
- `RouterTokenCompatibility.t.sol`: six-decimal units, optional ERC-20 return values, false returns, blocked transfers, token reentrancy, and recipient-net output slippage for a transfer-tax token.
- `TreasuryBoundaries.t.sol`: empty/dust balances, 49/50-wei boundary, permissionless calls, UTC day rollover, missed days, rounding, same-day donations, reentrancy, and rollback after the hook pulls funds then reverts.
- `JudgeAdversarial.t.sol`: real signatures verified through an ERC-1271 signer model; clone/chain/wrong-key rejection; timestamp, panel, quorum and answer decoding boundaries; threshold and price cap; request/payment rollback; retries; active request collisions; JSON body parsing; filtering and deduplication; callback gas stipend; 50/30/20 payment and replay prevention.

`../invariant/CompanionConservation.t.sol` runs 256 sequences of 64 calls with three funded actors and `fail-on-revert = true`. Its handler mixes notes, buys/sells, donations, time advancement, treasury drips, oracle requests/answers/payments, thesis forfeitures and conversions, and unauthorized callbacks. Expected refusal paths are asserted explicitly. A deterministic setup reaches payment and conversion before fuzzing, so the properties also exercise nonempty state.

The four invariant groups check:

1. Treasury donations equal its remaining IMD plus all drips; at most one successful drip per UTC day and no leftover hook approval.
2. Router and judge balances equal only tracked unsolicited donations; requests pay exactly their price; approvals clear; note authors and token deltas match the acting user.
3. The real PoolManager's IMD claims back the sum of all touched refund/leaderboard/thesis pools, and MARG claims back note deposits plus forfeitures.
4. Accepted oracle UUIDs stay consumed, judged weeks stay judged, and each week pays at most once with consistent judge/hook flags.

The bounded invariant campaign uses standard IMD/MARG tokens, fixed oracle price, and modest trades within seeded liquidity. It does not claim exhaustive hook settlement, liquidity exhaustion, mainnet deployment, or live oracle availability coverage. Stateful token transfers, allowances and v4 balances are real local contract calls. The v2 model enforces stored reserves, the 0.3% fee and constant product, but omits flash swaps, LP shares and TWAP state. V3 uses the existing canonical-factory and partial-fill callback model. Live v2/v3/Intake integration remains a fork/deployment rehearsal outside this offline suite; the preexisting fork suite skips when no RPC is configured.

One confirmed defect is reported in the root `.imd-findings.json`: v2 input transfer taxes are measured at the pair but not at the initial user-to-router pull, so the router forwards more than it received and reverts. The report embeds a standalone, locally reproduced failing Foundry proof. The passing suite does not assert that this failure is correct. Scratch proofs are excluded from submission by the assignment.
