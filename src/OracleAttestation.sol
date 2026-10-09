// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";

/// @title The reasoning oracle's attestation, as a contract reads it
/// @notice The oracle answers a typed question off chain — a panel of agents reads it, a deployer
/// reproduces the answer from the chain — and signs the result as EIP-712 typed data in the
/// *consumer's* domain: this chain, this contract. A signature for one consumer is meaningless to
/// another, which is the property that lets one attester key serve every consumer without any of
/// them being able to replay an answer into a neighbour.
///
/// @dev This library is the Solidity half of `oracle-eip712.ts` in `@identitymd/protocol`. The
/// struct, the type string and the domain name are copied from there field for field, and the
/// cross-implementation vector in `test/OracleAttestation.t.sol` is what keeps them equal: a digest
/// computed by viem on one side and `_hashTypedDataV4` on the other, over the same values. Change
/// either half and the vector fails before anything is signed for real.
library OracleAttestation {
    /// @dev Field order is the typed data's. `answer` is `abi.encode` of the value under
    /// `answerType`, so a consumer reads it back with one `abi.decode`; the hash covers
    /// `keccak256(answer)` as EIP-712 requires for a dynamic field.
    struct Attestation {
        /// @dev The request's UUID as sixteen raw bytes, left-aligned. The natural replay key.
        bytes32 requestId;
        /// @dev The chain the question is *about* — the one the recipe ran on. Not necessarily the
        /// consumer's chain, which is in the domain instead.
        uint256 chainId;
        /// @dev keccak-256 of the canonical question document. A consumer that pins its question
        /// compares this, so an answer to a different question cannot be presented as its own.
        bytes32 questionHash;
        uint8 answerType;
        bytes answer;
        /// @dev The figure behind the answer where there is one: the sum, the leader's volume, the
        /// value compared. Zero otherwise.
        uint256 figure;
        uint64 fromBlock;
        uint64 toBlock;
        /// @dev The closing block's hash, so a reorg cannot quietly change what was answered.
        bytes32 blockHash;
        /// @dev The panel job's UUID, the same way. Its page and receipt hold the evidence.
        bytes32 panelJobId;
        /// @dev How many seats the request opened. With `quorum`, what the requester asked for, so a
        /// consumer that does not pin its question can still refuse a panel of two.
        uint16 panelSize;
        /// @dev How many answers had to agree for the panel to settle.
        uint16 quorum;
        /// @dev How many members gave the answer signed. At least `quorum` when the panel agreed;
        /// below it only for chain evidence, when members who ran one recipe split and the
        /// deployer's own rerun settled which of their answers was whole. A consumer that wants the
        /// panel's agreement itself, not the rerun's, requires `agreed >= quorum`.
        uint16 agreed;
        uint64 issuedAt;
        uint64 expiresAt;
    }

    /// @dev The `answerType` codes. They are the protocol enum's order and are appended to, never
    /// reordered, because a code is what a signed attestation carries.
    uint8 internal constant ANSWER_BOOL = 0;
    uint8 internal constant ANSWER_ADDRESS = 1;
    uint8 internal constant ANSWER_BYTES32 = 2;
    uint8 internal constant ANSWER_UINT256 = 3;
    uint8 internal constant ANSWER_ADDRESS_LIST = 4;
    uint8 internal constant ANSWER_BYTES32_LIST = 5;

    string internal constant DOMAIN_NAME = "IdentityMD Oracle";
    /// @dev Version 2 added `panelSize`, `quorum` and `agreed`. A version 1 signature does not
    /// verify here and a version 2 one does not verify against a version 1 consumer.
    string internal constant DOMAIN_VERSION = "2";

    bytes32 internal constant TYPEHASH = keccak256(
        "OracleAttestation(bytes32 requestId,uint256 chainId,bytes32 questionHash,uint8 answerType,bytes answer,uint256 figure,uint64 fromBlock,uint64 toBlock,bytes32 blockHash,bytes32 panelJobId,uint16 panelSize,uint16 quorum,uint16 agreed,uint64 issuedAt,uint64 expiresAt)"
    );

    /// @notice The EIP-712 `hashStruct` of an attestation: what goes under the domain separator.
    /// @dev Encoded in two halves because sixteen values in one `abi.encode` is too deep a stack
    /// for the legacy code generator, and a consumer should not need via-IR to inherit this. Every
    /// value is a static 32-byte word, so the two halves concatenated are byte for byte the one
    /// encoding EIP-712 specifies.
    function hashStruct(Attestation calldata a) internal pure returns (bytes32) {
        return keccak256(
            bytes.concat(
                abi.encode(
                    TYPEHASH,
                    a.requestId,
                    a.chainId,
                    a.questionHash,
                    a.answerType,
                    keccak256(a.answer),
                    a.figure,
                    a.fromBlock
                ),
                abi.encode(
                    a.toBlock, a.blockHash, a.panelJobId, a.panelSize, a.quorum, a.agreed, a.issuedAt, a.expiresAt
                )
            )
        );
    }
}

/// @title What a contract inherits to accept oracle attestations
/// @notice Verifies that an attestation was signed by this consumer's oracle signer, for this
/// consumer, and is inside its validity window. What the consumer then *does* with the answer is
/// its own business: this contract decodes, it never acts.
///
/// @dev Replay is deliberately not tracked here. Some consumers want one action per request; some
/// want to read the same attestation from several functions; some key on `questionHash` rather than
/// `requestId`. `consumed` and `_consume` are offered for the first kind and cost nothing to the
/// others. A consumer that neither consumes nor keys on something else **accepts the same signed
/// answer as many times as it is presented** — for as long as it is valid — and must want that.
///
/// The signer is one address, so the natural rotation story is to point it at an
/// `OracleSignerRegistry`, which answers ERC-1271 for the keys it lists; `SignatureChecker` takes
/// that path for any signer with code. A consumer that prefers to hold a bare key overrides
/// nothing and rotates through `_setOracleSigner`.
abstract contract OracleAttestationConsumer is EIP712 {
    using OracleAttestation for OracleAttestation.Attestation;

    error AttestationExpired(uint64 expiresAt);
    error AttestationNotYetValid(uint64 issuedAt);
    error BadSignature();
    error AlreadyConsumed(bytes32 requestId);
    error WrongAnswerType(uint8 expected, uint8 got);
    error ZeroSigner();

    event OracleSignerSet(address indexed signer);

    /// @dev How far ahead of this chain's clock an `issuedAt` may sit. The attester stamps with
    /// its own wall clock; a block's timestamp is a validator's. Five minutes is generous for
    /// honest drift and still short of anything that could be called pre-signing.
    uint64 public constant ISSUED_AT_TOLERANCE = 5 minutes;

    /// @notice The address every attestation must verify against: a key, or a registry of keys.
    address public oracleSigner;

    /// @notice Request ids this consumer has acted on, for consumers that call `_consume`.
    mapping(bytes32 => bool) public consumed;

    constructor(address signer) EIP712(OracleAttestation.DOMAIN_NAME, OracleAttestation.DOMAIN_VERSION) {
        _setOracleSigner(signer);
    }

    /// @notice The digest the oracle signed: this consumer's domain over the attestation.
    /// @dev Public so an off-chain party — the attester, a test, a reader — can ask the consumer
    /// what it will check rather than reimplementing the domain. Equal to `oracleAttestationDigest`
    /// in the protocol package for the same consumer and message.
    function attestationDigest(OracleAttestation.Attestation calldata a) public view returns (bytes32) {
        return _hashTypedDataV4(a.hashStruct());
    }

    /// @notice Reverts unless the attestation is current and signed for this consumer.
    /// @dev Checks the window first because a stale signature is the common failure and the cheap
    /// one to report. Does not check `a.chainId` — the chain the question was about is a fact
    /// about the question, and whether it is the right one is for the consumer to decide alongside
    /// `questionHash`. A validator can nudge `block.timestamp` by seconds; the window is minutes
    /// to days wide and the tolerance absorbs the other end, so that is not a lever here.
    function _verifyAttestation(OracleAttestation.Attestation calldata a, bytes calldata signature) internal view {
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp > a.expiresAt) revert AttestationExpired(a.expiresAt);
        // forge-lint: disable-next-line(block-timestamp)
        if (a.issuedAt > block.timestamp + ISSUED_AT_TOLERANCE) revert AttestationNotYetValid(a.issuedAt);
        if (!SignatureChecker.isValidSignatureNow(oracleSigner, attestationDigest(a), signature)) {
            revert BadSignature();
        }
    }

    /// @notice Marks a request id as acted on, once.
    /// @dev Opt-in. Call it after `_verifyAttestation` and before the effect, in the same function,
    /// so a re-presented attestation fails here rather than repeating the effect.
    function _consume(bytes32 requestId) internal {
        if (consumed[requestId]) revert AlreadyConsumed(requestId);
        consumed[requestId] = true;
    }

    /// @dev The hook a consumer wires to whatever authority it has. Not exposed here: this contract
    /// does not know who is allowed to rotate, and an unguarded public setter would be the whole
    /// oracle's key in anyone's hands. The zero address is refused because a consumer with no
    /// signer only finds out on its first attestation, with `BadSignature`, which points nowhere.
    function _setOracleSigner(address signer) internal {
        if (signer == address(0)) revert ZeroSigner();
        oracleSigner = signer;
        emit OracleSignerSet(signer);
    }

    function decodeBool(OracleAttestation.Attestation calldata a) internal pure returns (bool) {
        _expectType(a, OracleAttestation.ANSWER_BOOL);
        return abi.decode(a.answer, (bool));
    }

    function decodeAddress(OracleAttestation.Attestation calldata a) internal pure returns (address) {
        _expectType(a, OracleAttestation.ANSWER_ADDRESS);
        return abi.decode(a.answer, (address));
    }

    function decodeBytes32(OracleAttestation.Attestation calldata a) internal pure returns (bytes32) {
        _expectType(a, OracleAttestation.ANSWER_BYTES32);
        return abi.decode(a.answer, (bytes32));
    }

    function decodeUint256(OracleAttestation.Attestation calldata a) internal pure returns (uint256) {
        _expectType(a, OracleAttestation.ANSWER_UINT256);
        return abi.decode(a.answer, (uint256));
    }

    function decodeAddressList(OracleAttestation.Attestation calldata a) internal pure returns (address[] memory) {
        _expectType(a, OracleAttestation.ANSWER_ADDRESS_LIST);
        return abi.decode(a.answer, (address[]));
    }

    function decodeBytes32List(OracleAttestation.Attestation calldata a) internal pure returns (bytes32[] memory) {
        _expectType(a, OracleAttestation.ANSWER_BYTES32_LIST);
        return abi.decode(a.answer, (bytes32[]));
    }

    /// @dev The type is signed, so decoding under another is not a parsing accident to tolerate:
    /// an address read as a uint256 is a number that means nothing and a uint256 read as an address
    /// is twelve bytes of somebody's balance, silently dropped.
    function _expectType(OracleAttestation.Attestation calldata a, uint8 expected) private pure {
        if (a.answerType != expected) revert WrongAnswerType(expected, a.answerType);
    }
}
