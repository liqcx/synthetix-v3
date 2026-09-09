---
name: cannon-fork
description: Use when touching Cannon versions or the @usecannon/* imports, editing pnpm-workspace.yaml overrides, updating the Cannon fork, or when a cannon build fails around require('ses') / a second lockdown().
---

# Cannon is a fork

`@alxwlw/cannon-builder` / `@alxwlw/cannon-cli` (from
[`alxwlw/cannon`](https://github.com/alxwlw/cannon), nonce branch on top of upstream 2.26.1) are
installed under the upstream names through `npm:` aliases. The version is written **once**, in the
`cannon` catalog of `pnpm-workspace.yaml`; the 14 manifests that use it say `catalog:cannon`, and
`overrides` pins the same aliases tree-wide by back-reference (`$@usecannon/builder`, which pnpm
resolves through the root manifest's catalog specifier). The overrides are load-bearing, not
cosmetic:
`hardhat-cannon@2.25.1` hard-pins `@usecannon/{builder,cli}@2.25.1`, and every build here goes
through `hardhat cannon:build` — without them the fork would sit unused in `devDependencies`.
Keep imports written as `@usecannon/*`: the fork's own CLI requires the builder under that
specifier, and a second copy of the builder in one process breaks it (`require('ses')` →
a second `lockdown()`). Never `pnpm up @usecannon/...` — that drops the alias and silently
restores stock Cannon, and even given the alias explicitly it writes 14 literals back into the
manifests and leaves the catalog entry stale (pnpm 11.1.2 has no catalog-aware update). Use
`pnpm cannon:update` (tag via `CANNON_TAG`, default `nonce`), which edits the catalog entry and
then reinstalls; it is `scripts/cannon-update.ts`, whose header carries the rest.
