---
name: ci-gha-migration-p3d
description: "P3d — CircleCI заменён на GHA (PR #29); джоба contracts красная по P3b-долгу; @liqcx-пакеты берутся из org-секрета GT_READ, не GITHUB_TOKEN"
metadata: 
  node_type: memory
  type: project
  originSessionId: 3804791f-0cd1-491a-824e-9e9c2c431dad
  modified: 2026-09-04T13:50:27.831Z
---

Миграция CI (P3d) сделана 2026-09-04 в ветке `feat-cld/gha-migration`, PR
[liqcx/synthetix-v3#29](https://github.com/liqcx/synthetix-v3/pull/29), 27 коммитов. `.circleci/`
удалён. Спека `docs/superpowers/specs/2026-09-04-circleci-to-gha-design.md`, план
`docs/superpowers/plans/2026-09-04-circleci-to-gha.md`.

Три вещи, которые не выводятся из кода и стоили отдельного расследования:

1. **`GITHUB_TOKEN` этого репозитория получает 403 на приватные `@liqcx`-пакеты.** Они публикуются из
   `liqcx/tooling` и раздают Actions-доступ по конкретным репозиториям; `synthetix-v3` в списке не был.
   Рабочее решение — org-секрет **`GT_READ`** (visibility=private, то есть виден всем приватным репо
   орг): `GT_READ: ${{ secrets.GT_READ }}`. В `monorepo` хватает `GITHUB_TOKEN` только потому, что для
   `@liqcx/eslint-config` доступ выдан вручную. Тот же рецепт понадобится любому новому потребителю
   канона.

2. **`gitleaks` в форке нужно запускать с `--no-git`.** Скан истории (3176 коммитов, 349 МБ, ~2 мин)
   находит 14 утечек в upstream-истории Synthetix 2021–2023 (`.yarn/releases/*.cjs`, удалённые
   `packages/**`) — форк её переписать не может, гейт был бы красным вечно. И: allowlist-регексп для
   адресов обязан иметь хвостовую границу — `0x[a-fA-F0-9]{40}([^a-fA-F0-9]|$)`, иначе он матчит первые
   40 hex приватного ключа `0x<64hex>` и отключает правило `eth-private-key-no-prefix`.

3. **Джоба `contracts` красная и влита такой сознательно** — решение владельца, 2026-09-04. Причина не
   в workflow: 11 из 16 пакетов со скриптом `storage:dump` не объявляют `@usecannon/cli` (не резолвится
   `hardhat-cannon` → `Cannot find module 'axios'`), 13 импортируют `@synthetixio/*` из Solidity, не
   объявляя зависимость. Долг P3b; `markets/perps-market` и `protocol/synthetix` — образцы для починки.
   Диагноз записан в `CLAUDE.md`. Пока это не починено, `storage:dump` и `size-contracts` не работают
   нигде — ни в CI, ни локально.

Ночной прогон (`nightly-contracts.yml`) ни разу не выполнялся: `workflow_dispatch` доступен только для
workflow, уже лежащих в дефолтной ветке. Открытый вопрос — влезет ли `build-testable` в раннер с 4 ГБ.

Связано: [[foundry-stand-after-pnpm]], [[gh-repo-liqcx-synthetix-v3]].
