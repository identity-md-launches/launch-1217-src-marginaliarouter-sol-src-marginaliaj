// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {MarginaliaRouter} from "src/MarginaliaRouter.sol";
import {MarginaliaJudge} from "src/MarginaliaJudge.sol";
import {MarginaliaTreasury} from "src/MarginaliaTreasury.sol";
import {OracleAttestation, OracleAttestationConsumer} from "src/OracleAttestation.sol";

/// @dev Rehearses the constructor-time clone/init ordering of MarginaliaHook.
contract CompanionCloneLauncher {
    MarginaliaRouter public router;
    MarginaliaJudge public judge;
    MarginaliaTreasury public treasury;

    constructor(address r, address j, address t, IPoolManager manager, address intake, address signer) {
        treasury = MarginaliaTreasury(Clones.clone(t));
        treasury.init(address(this));
        router = MarginaliaRouter(Clones.clone(r));
        router.init(manager, address(this));
        judge = MarginaliaJudge(Clones.clone(j));
        judge.init(address(this), intake, bytes32("oracle.request@oracle-1"), signer);
    }
}

contract CompanionInitializationTest is Test {
    MarginaliaRouter r;
    MarginaliaJudge j;
    MarginaliaTreasury t;

    function setUp() public {
        r = new MarginaliaRouter();
        j = new MarginaliaJudge();
        t = new MarginaliaTreasury();
    }

    function test_EmptyArgumentDeploymentHasBoundedImmutableRuntime() public view {
        address[3] memory implementations = [address(r), address(j), address(t)];
        for (uint256 k; k < implementations.length; ++k) {
            bytes memory code = implementations[k].code;
            assertGt(code.length, 0);
            assertLe(code.length, 24_576);
            for (uint256 i; i < code.length; ++i) {
                uint8 op = uint8(code[i]);
                if (op >= 0x60 && op <= 0x7f) {
                    i += op - 0x5f;
                    continue;
                }
                assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff, "mutable implementation runtime");
            }
        }
    }

    function test_ConstructorInitializesRealMinimalClonesAndLeavesTargetsLocked() public {
        CompanionCloneLauncher launcher = new CompanionCloneLauncher(
            address(r), address(j), address(t), IPoolManager(address(this)), address(this), makeAddr("signer")
        );
        assertEq(address(launcher.router().hook()), address(launcher));
        assertEq(address(launcher.judge().hook()), address(launcher));
        assertEq(address(launcher.treasury().hook()), address(launcher));
        assertEq(address(launcher.router()).code.length, 45);
        assertEq(address(launcher.judge()).code.length, 45);
        assertEq(address(launcher.treasury()).code.length, 45);
        assertEq(address(r.hook()), address(r));
        assertEq(address(j.hook()), address(j));
        assertEq(address(t.hook()), address(t));
        assertEq(address(r.manager()), address(0));
        assertEq(address(j.intake()), address(0));
        assertEq(j.oracleSigner(), address(j));
    }

    function test_InvalidRouterInitDoesNotConsumeTheOneShot() public {
        MarginaliaRouter clone = MarginaliaRouter(Clones.clone(address(r)));
        vm.expectRevert("configuration required");
        clone.init(IPoolManager(makeAddr("no code")), address(this));
        vm.expectRevert("configuration required");
        clone.init(IPoolManager(address(this)), address(0));
        assertEq(address(clone.hook()), address(0));
        clone.init(IPoolManager(address(this)), address(this));
        vm.expectRevert(MarginaliaRouter.AlreadyInitialised.selector);
        clone.init(IPoolManager(address(this)), address(this));
    }

    function test_InvalidJudgeInitRollsBackEveryFieldAndAllowsRetry() public {
        MarginaliaJudge clone = MarginaliaJudge(Clones.clone(address(j)));
        vm.expectRevert("configuration required");
        clone.init(address(0), address(this), bytes32("action"), address(this));
        vm.expectRevert("configuration required");
        clone.init(address(this), address(0), bytes32("action"), address(this));
        vm.expectRevert("configuration required");
        clone.init(address(this), address(this), bytes32(0), address(this));
        vm.expectRevert(OracleAttestationConsumer.ZeroSigner.selector);
        clone.init(address(this), address(this), bytes32("action"), address(0));
        assertEq(address(clone.hook()), address(0));
        assertEq(address(clone.intake()), address(0));
        assertEq(clone.action(), bytes32(0));
        assertEq(clone.oracleSigner(), address(0));
        clone.init(address(this), address(this), bytes32("action"), address(this));
        vm.expectRevert(MarginaliaJudge.AlreadyInitialised.selector);
        clone.init(address(this), address(this), bytes32("action"), address(this));
    }

    function test_InvalidTreasuryInitAllowsRetryWithoutTouchingSibling() public {
        MarginaliaTreasury a = MarginaliaTreasury(Clones.clone(address(t)));
        MarginaliaTreasury b = MarginaliaTreasury(Clones.clone(address(t)));
        vm.expectRevert("configuration required");
        a.init(address(0));
        a.init(address(this));
        assertEq(address(b.hook()), address(0));
        b.init(makeAddr("other test hook"));
        assertEq(address(a.hook()), address(this));
        vm.expectRevert(MarginaliaTreasury.AlreadyInitialised.selector);
        a.init(address(this));
    }

    function test_ClonedJudgeDomainUsesCloneAndCurrentChain() public {
        MarginaliaJudge a = MarginaliaJudge(Clones.clone(address(j)));
        MarginaliaJudge b = MarginaliaJudge(Clones.clone(address(j)));
        OracleAttestation.Attestation memory att;
        att.answer = abi.encode(new bytes32[](0));
        bytes32 original = a.attestationDigest(att);
        assertNotEq(original, b.attestationDigest(att));
        assertNotEq(original, j.attestationDigest(att));
        vm.chainId(block.chainid + 1);
        assertNotEq(original, a.attestationDigest(att));
    }

    function test_NoOwnerPauseUpgradeOrWithdrawalEntryPoints() public {
        CompanionCloneLauncher launcher = new CompanionCloneLauncher(
            address(r), address(j), address(t), IPoolManager(address(this)), address(this), makeAddr("signer")
        );
        address[6] memory targets = [
            address(r),
            address(j),
            address(t),
            address(launcher.router()),
            address(launcher.judge()),
            address(launcher.treasury())
        ];
        bytes[6] memory calls = [
            abi.encodeWithSignature("owner()"),
            abi.encodeWithSignature("pause()"),
            abi.encodeWithSignature("unpause()"),
            abi.encodeWithSignature("upgradeTo(address)", address(this)),
            abi.encodeWithSignature("withdraw(address,address,uint256)", address(this), address(this), 1),
            abi.encodeWithSignature("transferOwnership(address)", address(this))
        ];
        for (uint256 k; k < targets.length; ++k) {
            for (uint256 i; i < calls.length; ++i) {
                (bool ok,) = targets[k].call(calls[i]);
                assertFalse(ok, "unexpected administrative entry point");
            }
        }
    }
}
