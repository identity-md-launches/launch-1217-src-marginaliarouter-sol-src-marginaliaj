// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MarginaliaJudge} from "../src/MarginaliaJudge.sol";
import {OracleAttestation, OracleAttestationConsumer} from "../src/OracleAttestation.sol";
import {IIntake} from "../src/interfaces/IIntake.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @dev The least hook the judge needs: one thesis (id 1) in week 1, a funded pool, IMD on request.
contract StubHook {
    MockERC20 public imdToken;

    constructor(MockERC20 t) {
        imdToken = t;
    }

    function imd() external view returns (address) {
        return address(imdToken);
    }

    function week() external pure returns (uint32) {
        return 2;
    }

    function JUDGE_PRICE() external pure returns (uint256) {
        return 0.5 ether;
    }

    function thesisPool(uint32) external pure returns (uint256) {
        return 10 ether;
    }

    function potMarg() external pure returns (uint256) {
        return 0;
    }

    function thesesOfWeek(uint32) external pure returns (bytes32[] memory ids) {
        ids = new bytes32[](1);
        ids[0] = bytes32(uint256(1));
    }

    function noteMeta(bytes32 id) external pure returns (address, uint32, bool) {
        return (address(0xA11CE), 1, id == bytes32(uint256(1)));
    }

    function drawForJudging(uint32, uint256 amount) external {
        imdToken.transfer(msg.sender, amount);
    }

    function payJudged(uint32, bytes32[3] calldata) external {}

    function sellPotMarg(uint256) external pure returns (uint256) {
        return 0;
    }
}

/// @notice The oracle-consumer reference's conformance test, with MarginaliaJudge as the consumer: deployed at
/// the protocol's vector address on the vector's chain, with the vector's signer, trusting this contract as its
/// Intake. It is the one test that ties the judge's struct, type string and domain to what the oracle signs.
contract JudgeConformanceTest is Test, IIntake {
    // ---- the protocol's vector: do not change these ----
    uint256 constant VECTOR_CHAIN = 11155111;
    address constant VECTOR_CONSUMER = 0x0000000000000000000000000000000000002748;
    bytes32 constant VECTOR_DIGEST = 0x95fefa8b7c529852f4e2b6aec888930eb2bf5078e6443a85808e36df19e1325c;
    bytes constant VECTOR_SIGNATURE =
        hex"a26b14918607eb565af126beb54d3c5d19e923c41506def500b3521a4f9aa6d603ab44fd22f15dd2191732961a7131e4641244add8b0f09f20e6ae64381be8481b";
    /// @dev anvil's second account: the vector's attester. A test key, never a real one.
    address constant SIGNER = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;
    uint256 constant SIGNER_KEY = 0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d;
    uint64 constant ISSUED_AT = 1800000000;
    uint64 constant EXPIRES_AT = 1800003600;

    string constant CALLBACK =
        "onOracleResult(bytes32,(bytes32,uint256,bytes32,uint8,bytes,uint256,uint64,uint64,bytes32,bytes32,uint16,uint16,uint16,uint64,uint64),bytes)";

    MarginaliaJudge judge;
    StubHook stub;
    MockERC20 imd;
    uint256 requests;

    function setUp() public {
        vm.chainId(VECTOR_CHAIN);
        vm.warp(ISSUED_AT);
        vm.roll(1000);
        imd = new MockERC20("Identity.md", "IMD", 1_000 ether);
        stub = new StubHook(imd);
        imd.transfer(address(stub), 100 ether);
        // The judge is only ever a clone of the implementation: runtime code at a fresh address, then init.
        vm.etch(VECTOR_CONSUMER, address(new MarginaliaJudge()).code);
        judge = MarginaliaJudge(VECTOR_CONSUMER);
        judge.init(address(stub), address(this), bytes32("oracle.request@oracle-1"), SIGNER);
    }

    // ---- this contract is the judge's Intake ----

    function priceOf(bytes32, address) external pure returns (uint256) {
        return 0.5 ether;
    }

    function request(bytes32, bytes calldata body, Callback calldata cb, address asset, uint256 amount)
        external
        payable
        returns (bytes32 requestId)
    {
        require(cb.target == VECTOR_CONSUMER && cb.selector == judge.onOracleResult.selector, "callback");
        require(amount == 0.5 ether && asset == address(imd), "price");
        IERC20(asset).transferFrom(msg.sender, address(this), amount);
        requests += 1;
        requestId = keccak256(abi.encode(requests, body));
    }

    function vector() internal pure returns (OracleAttestation.Attestation memory a) {
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = bytes32(uint256(1));
        a = OracleAttestation.Attestation({
            requestId: 0x0000000000004000800000000000000100000000000000000000000000000000,
            chainId: 1,
            questionHash: 0x2117f4362ebfa37aa8a8c0fed548604fe09ac46faf8ae7559cd64780f26a46fb,
            answerType: OracleAttestation.ANSWER_BYTES32_LIST,
            answer: abi.encode(ids),
            figure: 12345,
            fromBlock: 100,
            toBlock: 200,
            blockHash: bytes32(uint256(7)),
            panelJobId: 0x0000000000004000800000000000000200000000000000000000000000000000,
            panelSize: 7,
            quorum: 5,
            agreed: 7,
            issuedAt: ISSUED_AT,
            expiresAt: EXPIRES_AT
        });
    }

    /// @dev The protocol's vector attestation is a panel of five with quorum four; the judge asks for seven
    /// and five, so the signed vector is used only for the digest, and answers are signed with the vector's key.
    function protocolVector() internal pure returns (OracleAttestation.Attestation memory a) {
        a = vector();
        a.panelSize = 5;
        a.quorum = 4;
        a.agreed = 5;
    }

    function _sign(OracleAttestation.Attestation memory a) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_KEY, judge.attestationDigest(a));
        return abi.encodePacked(r, s, v);
    }

    /// @notice The digest the judge verifies is the one the oracle signs.
    function test_digestMatchesTheProtocol() public view {
        assertEq(
            judge.attestationDigest(protocolVector()), VECTOR_DIGEST, "struct, type string or domain differs"
        );
        // and the protocol's own signature verifies against it
        assertEq(vm.addr(SIGNER_KEY), SIGNER);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_KEY, VECTOR_DIGEST);
        assertEq(
            abi.encodePacked(r, s, v),
            VECTOR_SIGNATURE,
            "the vector key does not reproduce the vector signature"
        );
    }

    /// @notice The callback's selector is the one the intake calls.
    function test_callbackSelectorIsCanonical() public view {
        assertEq(
            judge.onOracleResult.selector, bytes4(keccak256(bytes(CALLBACK))), "callback parameters differ"
        );
        assertEq(judge.onOracleResult.selector, bytes4(0x510379c7));
    }

    /// @notice An answer signed by the vector's key, delivered the way the writer delivers it, under the stipend.
    function test_acceptsASignatureFromTheVectorKeyAsDelivered() public {
        bytes32 reqId = judge.requestJudging(1);
        OracleAttestation.Attestation memory a = vector();
        judge.onOracleResult{gas: 200_000}(reqId, a, _sign(a));
        assertTrue(judge.consumed(a.requestId));
        assertTrue(judge.judgedSet(1));
        assertEq(judge.judgedOf(1)[0], bytes32(uint256(1)));
        // the same attestation cannot be presented twice
        bytes32 again = judge.requestJudging(0);
        bytes memory sig = _sign(a);
        vm.expectRevert(
            abi.encodeWithSelector(OracleAttestationConsumer.AlreadyConsumed.selector, a.requestId)
        );
        judge.onOracleResult(again, a, sig);
    }

    function test_refusesTheWrongSenderTamperingAndExpiry() public {
        bytes32 reqId = judge.requestJudging(1);
        OracleAttestation.Attestation memory a = vector();
        bytes memory sig = _sign(a);
        vm.prank(address(0xBAD));
        vm.expectRevert(MarginaliaJudge.OnlyIntake.selector);
        judge.onOracleResult(reqId, a, sig);
        vm.expectRevert(MarginaliaJudge.UnknownRequest.selector);
        judge.onOracleResult(keccak256("never requested"), a, sig);
        a.figure = 1;
        vm.expectRevert(OracleAttestationConsumer.BadSignature.selector);
        judge.onOracleResult(reqId, a, sig);
        a.figure = 12345;
        vm.warp(EXPIRES_AT + 1);
        vm.expectRevert(
            abi.encodeWithSelector(OracleAttestationConsumer.AttestationExpired.selector, EXPIRES_AT)
        );
        judge.onOracleResult(reqId, a, sig);
        // a failed delivery leaves the request pending until the deadline, then it can be made again
        vm.expectRevert(MarginaliaJudge.AlreadyRequested.selector);
        judge.requestJudging(1);
        vm.warp(ISSUED_AT + judge.REQUEST_TTL());
        bytes32 second = judge.requestJudging(1);
        assertTrue(second != reqId);
        vm.warp(ISSUED_AT);
        vm.expectRevert(MarginaliaJudge.UnknownRequest.selector);
        judge.onOracleResult(reqId, a, sig);
        judge.onOracleResult(second, a, sig);
        assertTrue(judge.judgedSet(1));
    }
}
