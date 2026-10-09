// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Currency} from "v4-core/src/types/Currency.sol";

/// @notice The IMD LaunchFactory's launch interface, as verified on Ethereum mainnet
/// (0x12c63b581d07093f6126bc02263c58f7eadaa96f). Used only by the fork rehearsal.
interface ILaunchFactory {
    struct Launch {
        bytes32 kind;
        uint64 launchNumber;
        uint64 recordedAt;
        bytes32 sourceCommit;
        bytes32 manifestHash;
        bytes32 attestationHash;
        bytes32 verifierKey;
        string sourceRepoUrl;
    }

    struct LaunchParams {
        uint64 launchNumber;
        bytes32 kind;
        bytes tokenCreationCode;
        bytes hookCreationCode;
        bytes32 hookSalt;
        uint160 hookFlags;
        uint256 totalSupply;
        uint16 poolBps;
        address remainderTo;
        bytes32 merkleRoot;
        uint64 contributorLockSeconds;
        uint64 sweepDelaySeconds;
        Currency pairedCurrency;
        uint24 fee;
        int24 tickSpacing;
        uint160 sqrtPriceX96;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        Launch record;
        uint256[] agentIds;
        address requester;
    }

    function deployer() external view returns (address);
    function predictToken(uint64 launchNumber, bytes calldata tokenCreationCode) external view returns (address);
    function launch(LaunchParams calldata params) external returns (address token, address hook, address distributor);
    function claimFees(uint64 launchNumber) external;
}
