# MintableToken

An in-repo copy of the Cannon package `mintable-token:1.8@permissionless-mint`,
which `auxiliary/BuybackSnx` and `auxiliary/OwnedFeeCollector` provision from
their `cannonfile.test.toml`.

## Why it is vendored

The upstream package exists only on Cannon's own repo service. Its regional
hostnames (`us-east.repo.usecannon.com` and friends) fail the TLS handshake with
alert 40 from everywhere, the apex `repo.usecannon.com` 404s the blob, delegated
routing reports zero providers for the CID and every public gateway times out —
so on a runner with an empty local registry the provision cannot be satisfied at
all. Building this package into the local registry first makes the provision
resolve `via local` and never touch the network. Same reasoning, and the same
shape, as `auxiliary/TrustedMulticallForwarder`.

## Fidelity

`src/MintableToken.sol` is the upstream source, recovered from a cached copy of
the package's own code blob (`solcVersion 0.8.23+commit.f704f362`,
`sourceName src/MintableToken.sol`), with three deliberate differences:

- **`mint` has no `onlyOwner`.** The cached blob is the `main` preset; the
  consumers ask for `permissionless-mint`, whose definition was not cached.
  Permissionless minting is what the preset name says and what the tests need:
  `OwnedFeeCollector`'s suite mints as an impersonated
  `0x48914229deDd5A9922f44441ffCCfC2Cb7856Ee9` while `BuybackSnx`'s mints as the
  first signer, and neither cannonfile passes an `owner` option — no single
  owner satisfies both.
- **OpenZeppelin v5, not the v4.9 upstream compiled against.** v5.0.0 is the tag
  `TrustedMulticallForwarder` already pins, so the two Foundry packages stay on
  one version; the only source change it forces is `Ownable(tokenOwner)` in the
  constructor instead of `_transferOwnership(owner)` in the body. v5 drops
  `increaseAllowance`/`decreaseAllowance` from the ERC-20 surface; nothing here
  calls them.
- **Constructor parameters renamed** (`owner` → `tokenOwner` and so on) to stop
  them shadowing the inherited `owner()`, `name()` and `symbol()`. Parameter
  names are not part of the ABI.

`cannonfile.toml` is the upstream definition verbatim — the same six settings,
the same CREATE2 contract operation named `MintableToken`, which is what
`imports.usd.contracts.MintableToken.address` and `getContract('usd.MintableToken')`
read — except for two things:

- **`version = "1.8-liq.1"`**, because `cannon build` refuses a package that
  already exists on the on-chain registry, and `1.8` does. The three
  `cannonfile.test.toml` provisions name the bumped version.
- **`setting.owner` has a default** (the deploying signer). Upstream's `main`
  preset makes it required; neither consumer passes one, so
  `permissionless-mint` must default it too.
