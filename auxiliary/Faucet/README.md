# Faucet

Generic testnet faucet contract. Holds pre-minted ERC-20 pools and gates per-(user, token) claims via configurable cooldown. Intended for MegaETH testnet and any similar environment where users need fake tokens to exercise the product.

See design spec: `monorepo/docs/superpowers/specs/2026-04-11-fusdc-faucet-design.md`.

## Why this is pure Foundry

Every other `auxiliary/*` project uses a Hardhat + Foundry + Cannon hybrid because they ship as modules of the Synthetix Router Proxy and need Cannon for versioned, composable deployments. The Faucet is a standalone, self-contained contract that never enters the protocol — so it doesn't need Hardhat, Cannon, or cannonfile registration. `forge` alone is enough.

## Contract

`Faucet.sol` inherits the repo-wide `Ownable` (two-step nominate/accept transfer). All state is direct (not namespaced storage — this contract is not a module).

Key methods:

- `claim(address token)` — public, cooldown-gated
- `addToken(token, amount, cooldown)` — owner, register a new token
- `setEnabled(token, bool)` — owner, toggle claim availability
- `setClaimAmount(token, newAmount)` / `setClaimCooldown(token, newCooldown)` — owner
- `withdraw(token, to, amount)` — owner, evacuate pool
- `nextClaimAt(user, token)` / `getRegisteredTokens()` — views

## Deploy

```bash
cd auxiliary/Faucet
forge script script/Deploy.s.sol:DeployFaucet \
  --rpc-url https://carrot.megaeth.com/rpc \
  --private-key $DEPLOYER_PRIVATE_KEY \
  --broadcast
```

The deployer becomes the initial Faucet owner.

## First-time setup (register fUSDC + initial pool)

```bash
export FAUCET=0x...          # deployed Faucet address
export TOKEN=0x7E58474Fd67c921F85592C2131A25e55f38A5715  # fUSDC on MegaETH testnet
export INITIAL_POOL=4000000000000   # 4M fUSDC (6 decimals)
export CLAIM_AMOUNT=400000000       # 400 fUSDC
export CLAIM_COOLDOWN=86400         # 24h

forge script script/Setup.s.sol:SetupFaucet \
  --rpc-url https://carrot.megaeth.com/rpc \
  --private-key $SETUP_PRIVATE_KEY \
  --broadcast
```

The broadcast signer must be **both** the token owner (for `mint`) and the Faucet owner (for `addToken`). If these are different EOAs, run the two calls separately via `cast send`.

## Top-up when the pool runs low

```bash
export FAUCET=0x...
export TOKEN=0x7E58474Fd67c921F85592C2131A25e55f38A5715
export AMOUNT=1000000000000   # 1M fUSDC

forge script script/TopUp.s.sol:TopUp \
  --rpc-url https://carrot.megaeth.com/rpc \
  --private-key $TOKEN_OWNER_PRIVATE_KEY \
  --broadcast
```

Signer must be the token owner.

## Registering a new token later

Re-run `Setup.s.sol` with different env vars. No contract changes needed.

## Reconfiguring an existing token

Use `cast send`:

```bash
cast send $FAUCET "setClaimAmount(address,uint128)" $TOKEN $NEW_AMOUNT \
  --rpc-url $RPC_URL --private-key $FAUCET_OWNER_KEY

cast send $FAUCET "setClaimCooldown(address,uint64)" $TOKEN $NEW_COOLDOWN \
  --rpc-url $RPC_URL --private-key $FAUCET_OWNER_KEY

cast send $FAUCET "setEnabled(address,bool)" $TOKEN true \
  --rpc-url $RPC_URL --private-key $FAUCET_OWNER_KEY
```

## Emergency evacuation

If the Faucet needs to be redeployed (bug, migration, etc.), pull the remaining pool first:

```bash
cast send $FAUCET "withdraw(address,address,uint256)" $TOKEN $RECIPIENT $AMOUNT \
  --rpc-url $RPC_URL --private-key $FAUCET_OWNER_KEY
```

## Tests

```bash
cd auxiliary/Faucet
forge test -vv
```
