---
name: cannon-fork
description: Use when touching Cannon versions or the @usecannon/* imports, editing pnpm-workspace.yaml overrides, updating the Cannon fork, or when a cannon build fails around require('ses') / a second lockdown().
---

# Cannon is a fork

`@alxwlw/cannon-builder` / `@alxwlw/cannon-cli` (from
[`alxwlw/cannon`](https://github.com/alxwlw/cannon), nonce branch on top of upstream 2.26.1) are
installed under the upstream names through `npm:` aliases, and `pnpm-workspace.yaml` `overrides`
pins the same aliases tree-wide. The overrides are load-bearing, not cosmetic:
`hardhat-cannon@2.25.1` hard-pins `@usecannon/{builder,cli}@2.25.1`, and every build here goes
through `hardhat cannon:build` — without them the fork would sit unused in `devDependencies`.
Keep imports written as `@usecannon/*`: the fork's own CLI requires the builder under that
specifier, and a second copy of the builder in one process breaks it (`require('ses')` →
a second `lockdown()`). Never `pnpm up @usecannon/...` — that drops the alias and silently
restores stock Cannon; use `pnpm cannon:update` (tag via `CANNON_TAG`, default `nonce`).
