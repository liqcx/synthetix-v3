---
name: lerna-to-moon-pr39
description: Миграция synthetix-v3 с lerna на moon — PR #39 (слит 08.09), что в нём намеренно красное и где лежат отчёты прогона
metadata:
  type: project
---

Ветка `feat-cld/moon-migration` → **PR #39** в `liqcx/synthetix-v3`, открыт и слит в `main` 08.09.2026
(merge `734c92d4`): 28 коммитов, 97 файлов. Lerna удалена (три её скрипта не могли работать — чужой скоуп
`@synthetixio`), moon заведён на 32 проекта / 267 задач, CI на `moon run`.

**PR не должен позеленеть, и это записано в его теле.** Пять красных унаследованы от `main`:
`storage:dump` и `core-modules:build-contracts` (долг P3b), mocha в `core-utils`
(`ERR_IMPORT_ATTRIBUTE_MISSING` на Node 24), matchstick в `perps-market/subgraph`, одна запись
`@usecannon/router` в `pnpm deps`. Прежде чем чинить «красноту PR», проверить, не из этого ли списка.

Критерий приёмки — паритет с `6835e6fa`, а не зелень. Проверяется тремя гейтами в
`scripts/moon-parity/` (набор задач / тела / рёбра и кэш по разрешённому графу); оракул —
`docs/superpowers/plans/2026-09-07-lerna-to-moon-baseline.txt`, 324 пары.

Отчёты и ревью всех шести задач + финальное ревью лежат в
`.superpowers/sdd/2026-09-07-lerna-to-moon/` — **папка в .gitignore**, то есть умрёт вместе с
чекаутом и в PR её нет. Там же журнал с семнадцатью решениями, принятыми по ходу прогона.

Связано: [[ci-gha-migration-p3d]] (тот же долг P3b), [[memory-in-repo]].
