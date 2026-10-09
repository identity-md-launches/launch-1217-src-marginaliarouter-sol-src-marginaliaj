// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice The companion implementations the hook clones (EIP-1167) in its constructor. They are deployed
/// first, as a contracts-only IMD launch, and these constants are set to those addresses before the hook
/// launch. The clones are immutable proxies; each is initialised once by the hook in the launch transaction.
/// @dev REPLACE before mainnet: the values below are rehearsal placeholders (tests etch code at them).
library MarginaliaImpls {
    address internal constant ROUTER_IMPL = 0x00000000000000000000000000000000000a0001;
    address internal constant JUDGE_IMPL = 0x00000000000000000000000000000000000A0002;
    address internal constant TREASURY_IMPL = 0x00000000000000000000000000000000000A0003;
}
