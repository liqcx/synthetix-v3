---
name: ci-red-deps-router
description: обе джобы ci.yml зелёные с 08.09 — lint (осиротевший @usecannon/router, PR #41) и contracts (долг P3b, PR #42); оба слиты в main 08.09
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

Починка: PR #41 (слит 08.09, мердж `074b8409`; коммит `ce5a3c58`) —
`pnpm deps:fix` + обязательный
`pnpm dedupe` следом — install без dedupe переписывает peer-суффикс
`axios-retry@4.5.0(axios@1.16.1(debug@4.4.3))` и роняет `pnpm dedupe --check`.
Пакет `@usecannon/router@4.1.3` остаётся в локе транзитивно через форк Cannon.

**contracts.** Красная независимо, долг P3b, под pnpm не проходила ни разу: 12 из 16 пакетов со
storage-dump импортируют `@synthetixio/*` из Solidity, не объявляя пакет (yarn подкладывал
хойстингом). moon идёт по графу от листьев, поэтому падали по два пакета за прогон, остальные
скрывались за ними. Починка — PR #42 (слит 08.09, мердж `899f7605`), ветка `feat-cld/p3b-contract-deps`:
`workspace:*` на каждый реальный импорт (включая транзитивные — SpotMarketOracle нужен
`@synthetixio/main` из-за ISpotMarketFactoryModule) **плюс** запись в `depcheck.ignoreMatches`,
иначе солидити-импорт читается как неиспользуемая зависимость и валит `pnpm deps`.
`@usecannon/cli` не понадобился нигде. Два импорта объявить нельзя — `oracle-manager` → `main`
и `spot-market` → `perps-market` смотрят в пакет, который уже зависит от них; moon отвечает
`action_graph::would_cycle`. Оба — моки, каждый пакет теперь держит свою копию (в
`markets/spot-market/contracts/mocks/AggregatorV3Mock.sol` этот приём был и до того).
Ещё в PR #42: `utils/deps/deps.js` сливал `depcheck` пакета с глобальным поверхностно, из-за чего
`ignoreMatches` пакета молча отменял глобальный список. Подробности: [[ci-gha-migration-p3d]].

Чтение логов джобов: [[gh-run-logs-self-hosted]].

Не проверено ни одним прогоном CI: два мока работают на тестах, а не на компиляции
(`protocol/oracle-manager/test/common/oracleNode.ts`, spot-market `AsyncOrderModule.pyth.test.ts`) —
это `nightly-contracts.yml`, а слили не дожидаясь CI.
