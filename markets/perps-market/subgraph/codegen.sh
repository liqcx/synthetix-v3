#!/bin/bash

set -e
export CANNON_IPFS_URL="https://ipfs.synthetix.io"

codegen() {
  namespace=$1
  chainId=$2
  package=$3

  echo
  echo
  echo
  echo '>' cannon inspect "$package" --chain-id "$chainId" --write-deployments "./$namespace/deployments"
  pnpm exec cannon inspect "$package" --chain-id "$chainId" --write-deployments "./$namespace/deployments"

  echo
  echo
  echo
  echo '>' graph codegen "subgraph.$namespace.yaml" --output-dir "$namespace/generated"
  pnpm exec graph codegen "subgraph.$namespace.yaml" --output-dir "$namespace/generated"
  pnpm exec prettier --write "$namespace/generated"
}

codegen base-mainnet-andromeda 8453 "synthetix-omnibus:latest@andromeda"
codegen base-sepolia-andromeda 84532 "synthetix-omnibus:latest@andromeda"
# The production line carries the upstream package name it has always had — the local
# Cannon cache holds no megaeth production tag, so it is unverified rather than known
# good; expect it to fail loudly if it is wrong. Staging is verified: that tag is what
# the 2026-08-25 redeploy published, and `--write-deployments` against it produced the
# addresses now in the manifest.
codegen megaeth-testnet-production 6343 "synthetix-omnibus:latest@andromeda"
codegen megaeth-testnet-staging 6343 "snx-omnibus-megaeth-staging:3-dev@andromeda"
