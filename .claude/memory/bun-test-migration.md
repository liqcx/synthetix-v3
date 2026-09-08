---
name: bun-test-migration
description: Миграция mocha → bun test, ветка feat-cld/bun-test-migration — спека и план на 9 задач согласованы 08.09; ключевые находки зондов (bun x hardhat = node, патч ses, export = ломает транспайлер bun) лежат в спеке в репозитории
metadata:
  type: project
---

08.09 «мигрируй mocha на bun test» → архитектурный трек. Ветка
**`feat-cld/bun-test-migration`**, спека
`docs/superpowers/specs/2026-09-08-mocha-to-bun-test-design.md` (коммиты `6a4794a1`, `ade3d743`,
`8b5d5ae7`), план `docs/superpowers/plans/2026-09-08-mocha-to-bun-test.md` (`4917b104`).
Спека и план вычитаны и одобрены; реализация ещё не начиналась.

Поводом был ночной ран [[nightly-suites-first-red]].

## Что решено (детали и числа — в спеке, тут только развилки)

- **Шим в preload, не кодмод.** 440 тестовых файлов не редактируются: репозиторий — вечный форк,
  cherry-pick из upstream должен оставаться дешёвым.
- **Изоляция процессом, не батчами.** `per-file` для всех, кто ходит через `coreBootstrap`;
  `per-package` для core-contracts и core-utils.
- **Один раннер** `.github/scripts/run-tests.ts` и для moon, и для CI — иначе `moon run <pkg>:test`
  и ночной снова разойдутся, как разошлись `bun x hardhat test` и `test-batch.js`.
- Ретраи на тест исчезают (у bun их нет), остаётся перезапуск файла в новом процессе.

## Три факта, которые дорого добывались зондами

1. **`bun x hardhat` — это node.** `bun x hardhat run` печатает `runtime: node v24.14.0`: bunx
   уважает шебанг `#!/usr/bin/env node`. Все hardhat-задачи репозитория всегда шли под node, и
   именно поэтому блокер SES не был виден.
2. **`ses` не грузится рантаймом bun** (`SES_NO_SLOPPY`): bun теряет `'use strict'` внутри функтора
   `ses/dist/ses.cjs`. Лечится одной строкой через `pnpm patch`; `ses@2.3.0` падает так же, так что
   бампом версии не чинится. Без патча под bun не грузится ни один `hardhat.config.ts` (все они
   тянут `hardhat-cannon` → `@usecannon/builder` → `ses`).
3. **`export =` ломает транспайлер bun**, но только в модуле, который вдобавок импортирует
   node-builtin (`Expected CommonJS module to have a function wrapper`). По отдельности ни одно из
   двух не воспроизводит, префикс `node:` не помогает. В репозитории ровно один такой модуль —
   `utils/core-utils/src/utils/assertions/assert-bignumber.ts:26`.

## Ловушка при снятии базлайна mocha

`mocha <файл>` **не** запускает только этот файл: конфиг `spec` подмешивается к позиционным
аргументам. Для честного базлайна нужен `--no-config --no-package`. Из-за этого же
`utils/core-utils/.mocharc.json` тянул сломанный `contracts.test.ts` в каждый батч.

Так выяснилось, что четыре AST-теста core-utils падают **и под mocha** (HH411: у
`test/fixtures/sample-project` нет своего `node_modules`, изолированный линкер pnpm не кладёт
`@synthetixio/core-contracts` туда, куда смотрит walk-up). Это долг pnpm-миграции, а не регрессия
bun — из объёма исключён.
