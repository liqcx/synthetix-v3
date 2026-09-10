// SPDX-License-Identifier: MIT
pragma solidity >=0.8.11 <0.9.0;

import {Test} from "forge-std/Test.sol";
import {Delegate7702} from "../src/Delegate7702.sol";
import {Counter} from "./mocks/Counter.sol";

contract Delegate7702Test is Test {
    event Executed(uint256 indexed nonce);

    Delegate7702 internal impl;
    Counter internal counter;

    uint256 internal constant USER_PK = 0xA11CE;
    uint256 internal constant STRANGER_PK = 0xB0B;
    address internal user;
    address internal relayer = address(0xCAFE);
    uint256 internal deadline;

    function setUp() public {
        impl = new Delegate7702();
        counter = new Counter();
        user = vm.addr(USER_PK);
        vm.deal(user, 1 ether);
        deadline = block.timestamp + 5 minutes;
        // Signs the EIP-7702 authorization with the user's key and applies it to the next call.
        vm.signAndAttachDelegation(address(impl), USER_PK);
    }

    // ---- helpers ------------------------------------------------------------------------

    function delegate() internal view returns (Delegate7702) {
        return Delegate7702(payable(user));
    }

    function twoCalls() internal view returns (Delegate7702.Call[] memory calls) {
        calls = new Delegate7702.Call[](2);
        calls[0] = Delegate7702.Call(address(counter), 0, abi.encodeCall(Counter.inc, (1)));
        calls[1] = Delegate7702.Call(address(counter), 1 wei, abi.encodeCall(Counter.inc, (2)));
    }

    function sign(
        uint256 pk,
        Delegate7702.Call[] memory calls,
        uint256 nonce_,
        uint256 dl
    ) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, delegate().hashExecute(calls, nonce_, dl));
        return abi.encodePacked(r, s, v);
    }

    // ---- execute ------------------------------------------------------------------------

    function test_execute_runsBatchOfTwoFromEoa() public {
        Delegate7702.Call[] memory calls = twoCalls();
        bytes memory sig = sign(USER_PK, calls, 0, deadline);

        vm.expectEmit(address(user));
        emit Executed(0);
        vm.prank(relayer);
        delegate().execute(calls, deadline, sig);

        assertEq(counter.count(), 3);
        assertEq(counter.lastSender(), user, "inner msg.sender is the EOA");
        assertEq(counter.received(), 1 wei, "value comes from the EOA balance");
        assertEq(delegate().nonce(), 1);
    }

    function test_execute_acceptsYParitySignature() public {
        Delegate7702.Call[] memory calls = twoCalls();
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(
            USER_PK,
            delegate().hashExecute(calls, 0, deadline)
        );
        bytes memory sig = abi.encodePacked(r, s, v - 27); // yParity form: 0 or 1

        vm.prank(relayer);
        delegate().execute(calls, deadline, sig);
        assertEq(delegate().nonce(), 1);
    }

    function test_execute_rejectsReplay() public {
        Delegate7702.Call[] memory calls = twoCalls();
        bytes memory sig = sign(USER_PK, calls, 0, deadline);
        vm.prank(relayer);
        delegate().execute(calls, deadline, sig);

        // Same signature, nonce moved on: the digest recovers to a different address.
        vm.expectPartialRevert(Delegate7702.InvalidSigner.selector);
        vm.prank(relayer);
        delegate().execute(calls, deadline, sig);
        assertEq(counter.count(), 3);
    }

    function test_execute_rejectsExpired() public {
        Delegate7702.Call[] memory calls = twoCalls();
        bytes memory sig = sign(USER_PK, calls, 0, deadline);
        vm.warp(deadline + 1);

        vm.expectRevert(abi.encodeWithSelector(Delegate7702.Expired.selector, deadline));
        vm.prank(relayer);
        delegate().execute(calls, deadline, sig);
    }

    function test_execute_rejectsWrongSigner() public {
        Delegate7702.Call[] memory calls = twoCalls();
        bytes memory sig = sign(STRANGER_PK, calls, 0, deadline);

        vm.expectRevert(
            abi.encodeWithSelector(Delegate7702.InvalidSigner.selector, vm.addr(STRANGER_PK))
        );
        vm.prank(relayer);
        delegate().execute(calls, deadline, sig);
        assertEq(delegate().nonce(), 0, "nonce untouched");
    }

    function test_execute_bubblesInnerRevert() public {
        Delegate7702.Call[] memory calls = new Delegate7702.Call[](2);
        calls[0] = Delegate7702.Call(address(counter), 0, abi.encodeCall(Counter.inc, (1)));
        calls[1] = Delegate7702.Call(address(counter), 0, abi.encodeCall(Counter.fail, (7)));
        bytes memory sig = sign(USER_PK, calls, 0, deadline);

        vm.expectRevert(abi.encodeWithSelector(Counter.Boom.selector, 7));
        vm.prank(relayer);
        delegate().execute(calls, deadline, sig);
        assertEq(counter.count(), 0, "whole batch rolled back");
    }

    // ---- executeSelf --------------------------------------------------------------------

    function test_executeSelf_rejectsNonSelf() public {
        vm.expectRevert(abi.encodeWithSelector(Delegate7702.NotSelf.selector, relayer));
        vm.prank(relayer);
        delegate().executeSelf(twoCalls());
    }

    function test_executeSelf_runsWhenCalledBySelf() public {
        Delegate7702.Call[] memory inner = twoCalls();
        Delegate7702.Call[] memory outer = new Delegate7702.Call[](1);
        outer[0] = Delegate7702.Call(user, 0, abi.encodeCall(Delegate7702.executeSelf, (inner)));
        bytes memory sig = sign(USER_PK, outer, 0, deadline);

        vm.prank(relayer);
        delegate().execute(outer, deadline, sig);
        assertEq(counter.count(), 3);
    }

    // ---- ERC-1271 / ERC-721 / receive ---------------------------------------------------

    function test_isValidSignature_magicForOwnerZeroOtherwise() public view {
        bytes32 hash = keccak256("hello");
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(USER_PK, hash);
        assertEq(delegate().isValidSignature(hash, abi.encodePacked(r, s, v)), bytes4(0x1626ba7e));

        (v, r, s) = vm.sign(STRANGER_PK, hash);
        assertEq(delegate().isValidSignature(hash, abi.encodePacked(r, s, v)), bytes4(0));
        assertEq(delegate().isValidSignature(hash, hex"00"), bytes4(0), "malformed length");
    }

    function test_onERC721Received_returnsSelector() public view {
        assertEq(delegate().onERC721Received(relayer, address(0), 1, ""), bytes4(0x150b7a02));
    }

    function test_receive_acceptsEth() public {
        vm.deal(relayer, 1 ether);
        vm.prank(relayer);
        (bool ok, ) = user.call{value: 0.5 ether}("");
        assertTrue(ok);
        assertEq(user.balance, 1.5 ether);
    }

    // ---- delegation lifetime / EIP-712 --------------------------------------------------

    function test_delegation_persistsAcrossTransactions() public {
        Delegate7702.Call[] memory calls = twoCalls();
        vm.prank(relayer);
        delegate().execute(calls, deadline, sign(USER_PK, calls, 0, deadline));

        // A later transaction, no new authorization attached: the designator is still there.
        vm.roll(block.number + 10);
        vm.warp(block.timestamp + 60);
        assertEq(user.code, abi.encodePacked(hex"ef0100", address(impl)));
        vm.prank(relayer);
        delegate().execute(calls, deadline, sign(USER_PK, calls, 1, deadline));
        assertEq(delegate().nonce(), 2);
        assertEq(counter.count(), 6);
    }

    /// Vector produced by viem `hashTypedData` (2.52.2) for chainId 31337 and
    /// verifyingContract = vm.addr(0xA11CE) = 0xe05fcC23807536bEe418f142D19fa0d21BB0cfF7.
    function test_hashExecute_matchesViemVector() public view {
        assertEq(user, 0xe05fcC23807536bEe418f142D19fa0d21BB0cfF7);
        assertEq(block.chainid, 31337);
        Delegate7702.Call[] memory calls = new Delegate7702.Call[](2);
        calls[0] = Delegate7702.Call(0x1111111111111111111111111111111111111111, 0, "");
        calls[1] = Delegate7702.Call(0x2222222222222222222222222222222222222222, 1, hex"deadbeef");
        assertEq(
            delegate().hashExecute(calls, 0, 1_700_000_000),
            0x3883f90b815699ca8cb686cd2e3dcdfa978fb3caae555f0f931d46b713ef525b
        );
    }
}
