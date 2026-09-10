// SPDX-License-Identifier: MIT
// solhint-disable meta-transactions/no-msg-sender
pragma solidity >=0.8.11 <0.9.0;

import {RevertUtil} from "@synthetixio/core-contracts/contracts/utils/RevertUtil.sol";

/// @title Delegate7702
/// @notice Minimal EIP-7702 delegate. An EOA that designates this code runs owner-signed
/// batches submitted (and paid for) by anyone. Because the code executes in the EOA's own
/// context, `address(this)` is the EOA: every inner call has the EOA as `msg.sender`, the
/// replay nonce lives in the EOA's storage, and the EIP-712 domain binds the signature to
/// this one account.
/// @dev No owner, no upgrade path, no external dependencies beyond `RevertUtil`. A failed
/// inner call bubbles its revert data unchanged; an empty revert becomes
/// `RevertUtil.EmptyRevertReason()`.
contract Delegate7702 {
    struct Call {
        address to;
        uint256 value;
        bytes data;
    }

    bytes32 private constant _DOMAIN_TYPEHASH =
        keccak256(
            "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
        );
    bytes32 private constant _NAME_HASH = keccak256("Delegate7702");
    bytes32 private constant _VERSION_HASH = keccak256("1");
    bytes32 private constant _CALL_TYPEHASH =
        keccak256("Call(address to,uint256 value,bytes data)");
    bytes32 private constant _EXECUTE_TYPEHASH =
        keccak256(
            "Execute(Call[] calls,uint256 nonce,uint256 deadline)Call(address to,uint256 value,bytes data)"
        );
    bytes4 private constant _ERC1271_MAGIC = 0x1626ba7e;
    bytes4 private constant _ERC721_RECEIVED = 0x150b7a02;

    /// @notice Replay nonce of this EOA; each successful `execute` consumes one.
    uint256 public nonce;

    event Executed(uint256 indexed nonce);

    error Expired(uint256 deadline);
    error InvalidSigner(address signer);
    error NotSelf(address sender);

    receive() external payable {}

    /// @notice Runs `calls` in order if `sig` is the EOA's EIP-712 signature over
    /// `Execute(calls, nonce, deadline)`. Anyone may submit; the submitter pays gas.
    function execute(Call[] calldata calls, uint256 deadline, bytes calldata sig) external payable {
        if (block.timestamp > deadline) revert Expired(deadline);
        uint256 current = nonce;
        address signer = _recover(hashExecute(calls, current, deadline), sig);
        if (signer != address(this)) revert InvalidSigner(signer);
        nonce = current + 1;
        emit Executed(current);
        _run(calls);
    }

    /// @notice Runs `calls` when the EOA itself is the caller (e.g. from within `execute`).
    function executeSelf(Call[] calldata calls) external {
        if (msg.sender != address(this)) revert NotSelf(msg.sender);
        _run(calls);
    }

    /// @notice ERC-1271: valid when `sig` recovers to this EOA.
    function isValidSignature(bytes32 hash, bytes calldata sig) external view returns (bytes4) {
        return _recover(hash, sig) == address(this) ? _ERC1271_MAGIC : bytes4(0);
    }

    /// @notice ERC-721 receiver hook. A delegated EOA has code, so `safeMint`/`safeTransferFrom`
    /// probe it (Synthetix `createAccount` mints the account NFT this way).
    function onERC721Received(
        address,
        address,
        uint256,
        bytes calldata
    ) external pure returns (bytes4) {
        return _ERC721_RECEIVED;
    }

    /// @notice EIP-712 digest of `Execute(calls, nonce_, deadline)` for this EOA on this chain.
    function hashExecute(
        Call[] calldata calls,
        uint256 nonce_,
        uint256 deadline
    ) public view returns (bytes32) {
        bytes32[] memory hashes = new bytes32[](calls.length);
        for (uint256 i = 0; i < calls.length; i++) {
            hashes[i] = keccak256(
                abi.encode(_CALL_TYPEHASH, calls[i].to, calls[i].value, keccak256(calls[i].data))
            );
        }
        bytes32 structHash = keccak256(
            abi.encode(_EXECUTE_TYPEHASH, keccak256(abi.encodePacked(hashes)), nonce_, deadline)
        );
        bytes32 domain = keccak256(
            abi.encode(_DOMAIN_TYPEHASH, _NAME_HASH, _VERSION_HASH, block.chainid, address(this))
        );
        return keccak256(abi.encodePacked("\x19\x01", domain, structHash));
    }

    function _run(Call[] calldata calls) private {
        for (uint256 i = 0; i < calls.length; i++) {
            // solhint-disable-next-line avoid-low-level-calls
            (bool ok, bytes memory ret) = calls[i].to.call{value: calls[i].value}(calls[i].data);
            if (!ok) RevertUtil.revertWithReason(ret);
        }
    }

    function _recover(bytes32 digest, bytes calldata sig) private pure returns (address) {
        if (sig.length != 65) return address(0);
        bytes32 r = bytes32(sig[0:32]);
        bytes32 s = bytes32(sig[32:64]);
        // solhint-disable-next-line numcast/safe-cast
        uint8 v = uint8(sig[64]);
        // Raw signers (Turnkey, ledger stacks) may hand back yParity 0/1 instead of 27/28.
        if (v < 27) v += 27;
        return ecrecover(digest, v, r, s);
    }
}
