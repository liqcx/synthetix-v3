# Delegate7702

Minimal EIP-7702 delegate for gasless deposits and withdrawals. A user's EOA designates this
code once (an EIP-7702 authorization carried by the first relayed transaction); from then on
anyone — our relayer — can submit a batch the user signed off-chain and pay the gas for it.
The code runs in the EOA's own context, so every inner call has the EOA as `msg.sender`, the
protocol sees a plain EOA, and nothing in Synthetix changes.

Decision and design: `monorepo/docs/adr/0063-relayer-pays-gas-via-eip-7702-delegate.md` and
`monorepo/docs/superpowers/specs/2026-09-10-gasless-7702-relayer-design.md`.

## Why this is pure Foundry

Same reasoning as `auxiliary/Faucet`: a standalone contract that never enters the Router Proxy
needs neither Hardhat nor Cannon. `forge` alone builds, tests and deploys it.

## Contract

`Delegate7702.sol` — ownerless, not upgradeable, no dependencies beyond `RevertUtil`.

- `execute(Call[] calls, uint256 deadline, bytes sig)` — anyone may call. Checks
  `block.timestamp <= deadline`, recovers the EIP-712 signature over
  `Execute(Call[] calls,uint256 nonce,uint256 deadline)` (domain
  `{ name: "Delegate7702", version: "1", chainId, verifyingContract: <the EOA> }`), requires the
  signer to be the EOA itself, emits `Executed(nonce)`, increments `nonce`, runs the calls in
  order. A failing inner call reverts the whole batch with its own revert data.
- `executeSelf(Call[] calls)` — only when `msg.sender` is the EOA (nested from `execute`).
- `isValidSignature(bytes32, bytes)` — ERC-1271 via `ecrecover`; `0x1626ba7e` or `bytes4(0)`.
- `onERC721Received(...)` — a delegated EOA has code, so `safeMint` probes it;
  `PerpsMarketProxy.createAccount` mints the account NFT that way.
- `hashExecute(calls, nonce, deadline)` — the digest the signer must sign; matches viem
  `hashTypedData` (covered by a test vector).
- `nonce()` — per-EOA replay nonce; `receive()` accepts ETH.

## Deploy

```bash
cd auxiliary/Delegate7702
forge script script/Deploy.s.sol:DeployDelegate7702 \
  --rpc-url https://carrot.megaeth.com/rpc \
  --private-key $DEPLOYER_PRIVATE_KEY \
  --broadcast
```

One deployment per chain serves every environment (prod and staging share chainId 6343).

| Chain                  | Address                                      | Deployed                                                                            |
| ---------------------- | -------------------------------------------- | ----------------------------------------------------------------------------------- |
| MegaETH testnet (6343) | `0x49E36A50Bae8Be715dB17c0fE2C569aA656cC856` | 2026-09-10, tx `0x384c4ebe9840ba8f517bbe1667dc21f9d5687fda3a40c39bafa9dae476fe2c69` |

MegaETH prices gas in two components, and the local simulation undershoots it (`intrinsic gas
too low` on broadcast) — pass `--skip-simulation` so forge takes `eth_estimateGas` from the RPC.
The address is also recorded in `monorepo/packages/liq-onchain/src/delegate7702.ts`
(`DELEGATE7702_ADDRESS`) and `monorepo/docs/protocols/synthetix-v3/contracts.md`.

## Tests

```bash
cd auxiliary/Delegate7702
forge test -vv
```

Delegation is exercised with `vm.signAndAttachDelegation`; the EIP-712 vector in
`test_hashExecute_matchesViemVector` was produced by viem 2.52.2.
