// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Shared types for Marginalia: a note is a falsifiable call on any ERC-20, posted by trading MARG.
library MarginaliaTypes {
    /// @dev How the note was posted. Traded = the router executed the X trade in the same transaction.
    enum Class {
        Traded,
        Declared,
        Agent,
        Attested
    }

    enum Side {
        Buy,
        Sell
    }

    enum Status {
        Open,
        Right,
        Wrong,
        VoidSold,
        VoidNoData,
        Retracted,
        ThesisOpen,
        ThesisClosed,
        ThesisForfeited
    }

    /// @dev Where X is priced. `ref` is the v4 pool id, or the v3 pool / v2 pair address left-aligned.
    enum VenueKind {
        None,
        UniV4,
        UniV3,
        UniV2
    }

    struct Venue {
        VenueKind kind;
        bytes32 ref;
        /// @dev The pool's other asset: IMD, or the native coin / WETH (priced through the hub pool).
        address quote;
        bool xIsToken0;
    }

    /// @dev What a poster sends. `targetBps` is the claimed price as a multiple of the post price in
    /// basis points: 20000 = 2x for a BUY call, 7000 = -30% for a SELL call. Zero = a thesis (no target).
    struct NoteParams {
        address x;
        Venue venue;
        Side side;
        uint32 targetBps;
        uint16 horizonDays;
        bytes32 parentId;
        uint8 class;
        string text;
    }

    struct Observation {
        uint64 blockNumber;
        uint192 price;
        uint256 balance;
    }

    struct Note {
        address author;
        address x;
        Venue venue;
        Side side;
        uint32 targetBps;
        uint16 horizonDays;
        uint8 class;
        Status status;
        uint64 postedAt;
        uint32 day;
        uint256 postPrice;
        uint256 postBalance;
        /// @dev MARG locked for the horizon. Returned fee-free on RIGHT, forfeited to the pot otherwise.
        uint256 deposit;
        bytes32 parentId;
        bytes32 textHash;
        /// @dev Children a thesis has; resolved children release the thesis deposit.
        uint32 children;
        uint32 resolvedChildren;
    }

    /// @dev hookData kinds. Only the router may send NOTE / SELL_NOTE; only the hook itself sends EXEMPT.
    uint8 internal constant DATA_NOTE = 1;
    uint8 internal constant DATA_EXEMPT = 2;
    uint8 internal constant DATA_SELL_NOTE = 3;
}
