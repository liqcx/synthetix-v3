#!/bin/bash

set -e

# Schema and ABI are network-independent, so the generated types are too: one run
# serves every network. Output lands in src/generated, next to the handlers that
# import it as './generated/...'.
pnpm exec graph codegen subgraph.megaeth-testnet-staging.yaml --output-dir src/generated
pnpm exec prettier --write src/generated
