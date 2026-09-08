---
name: ci-red-deps-router
description: lint в ci.yml красный на main с 05.09 (PR #32) из-за осиротевшего @usecannon/router; contracts красная отдельно по долгу P3b
metadata:
  type: project
---

**lint.** С 2026-09-05 (мердж PR #32, коммит 1918c695 удалил
`markets/perps-market/scripts/upgrade-router-megaeth-testnet.js`) шаг `pnpm deps`
падает: `@usecannon/router: 4.1.3` остался в devDependencies перпс-маркета без
единственного потребителя. Последний зелёный lint — PR #31 (04.09); поверх красного
влилось восемь PR (#32–#40), потому что джоб на ветках тоже был красный и на него не
смотрели. Шаги 10–16 (`deps:mismatched`, `deps:circular`, `liqcx-tooling-sync`,
actionlint, gitleaks, yamllint, markdownlint) при этом **skipped**, а не зелёные.

Починка: ветка `feat-cld/deps-router-gate`, коммит `ce5a3c58` (08.09, запушен, PR не открыт) —
`pnpm deps:fix` + обязательный
`pnpm dedupe` следом — install без dedupe переписывает peer-суффикс
`axios-retry@4.5.0(axios@1.16.1(debug@4.4.3))` и роняет `pnpm dedupe --check`.
Пакет `@usecannon/router@4.1.3` остаётся в локе транзитивно через форк Cannon.

**contracts.** Красная независимо и по другой причине — долг P3b: 11 из 16 пакетов со
storage-dump не объявляют `@usecannon/cli`, 13 — `@synthetixio/*`. Эта карточка её не
трогает, ран целиком зелёным от неё не станет. Подробности: [[ci-gha-migration-p3d]].

Чтение логов джобов: [[gh-run-logs-self-hosted]].
