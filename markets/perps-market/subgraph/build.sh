#!/bin/bash

set -e

for namespace in base-mainnet-andromeda base-sepolia-andromeda megaeth-testnet-production megaeth-testnet-staging; do
  echo '>' graph build "subgraph.$namespace.yaml" --output-dir "./build/$namespace"
  pnpm exec graph build "subgraph.$namespace.yaml" --output-dir "./build/$namespace"
done
