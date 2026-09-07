---
name: foundry-stand-after-pnpm
description: "Стенды perps-market после карточки 5 (#22 + #23): генерируемый Deploy.sol, test/stand.json как общее описание сценария, хелперы книги в обоих адаптерах; грабли pnpm/Cannon/lint/ethers, найденные 2026-09-03"
metadata:
  node_type: memory
  type: project
  originSessionId: d1ebb27a-36ae-4029-8c05-712127980794
  modified: 2026-09-03T17:57:05.440Z
---

Состояние стендов `markets/perps-market` после веток `feat-cld/foundry-stand-regenerated` (#22) и `feat-cld/book-stand-shared` (#23, stacked), 2026-09-03:

- `script/Deploy.sol` и `cannonfile.test.foundry.toml` — build-артефакты, в .gitignore. `pnpm build-testable` (или `build-testable:foundry`) генерирует их: `scripts/foundry-cannonfile.ts` делает из `cannonfile.test.toml` clone-вариант (`name = "snx-perps-foundry"`, `[import.synthetix]` → `[clone.synthetix]`), затем `hardhat cannon:build … --write-script script/Deploy.sol --write-script-format foundry --wipe`. Ключи скрипта: `PerpsMarketProxy`, `synthetix.CoreProxy`, `synthetix.USDProxy`, `synthetix.AccountProxy`, `synthetix.oracle_manager.Proxy`, `synthetix.CollateralMock`; spot не клонируется, Bootstrap передаёт в `initializeFactory` `makeAddr("SpotMarketProxy")`.
- Cannon ограничивает preset (`with-<name>`) 24 символами — имя clone-пакета ≤ 19 символов.
- `foundry.toml`: remappings на `node_modules/@synthetixio/<pkg>/` (pnpm не хостит в корень), `optimizer_runs = 200`, `fs_permissions` только на `./test/stand.json`. `FOUNDRY_REMAPPINGS` env не переопределяет ключ из toml.
- **Одно описание сценария** — `test/stand.json` (целые в человеческих единицах, доли/комиссии в bps, потому что stdJson не читает дроби): collateral price 2000 + ratios, pool 1 / lpStake 1000, marketDefaults, markets[] (25 Ether 1000, fees 3/8 bps), trader {stake 100000, pool 2}, bookAccounts [2,3]. TS-читатель `test/bootstrap/stand.ts` (`stand`, `bps`, `snxUsdFor` = stake×price/issuanceRatio, `standMarket()`); Foundry читает через `stdJson` в `tests/Bootstrap.t.sol`. Hardhat-адаптер ассертит то, что `createStakedPool` из main/test/common хардкодит (ratios); трейдеры стейкают в пул 2 и минтят по формуле (40M snxUSD вместо прежних 20M — абсолютный баланс кошелька тесты не читают). `bootstrapMarkets({ bookAccountIds })` — эти аккаунты не переключаются в ONCHAIN.
- Словарь книги под одними именами: TS `test/helpers/book.ts` (`bookOrder`, `settleBook`, `openBookAccount`, `openBookPosition`), Solidity `BootstrapTest` (`bookOrder`, `sortByAccountId`, `settleBook`, `openBookAccount`, `depositMargin`, `bookTrader`, `openBookPosition`, `stake(owner,pool,collateral)`, `fundStaker`, `warp`, `createPerpsMarket`). В BootstrapTest `ETH_PRICE`/`ethMarketId`/`poolId` — state-переменные (первый рынок описания), не constant: в наследниках инициализировать поля от них в `setUp`, не в объявлении.
- Интерфейсы: `tests/interfaces/ICoreProxy.sol` — наследование всех модулей ядра кроме `IPoolModule` (конфликт `CapacityLocked` с `IVaultModule`; пул через `IPoolModule(address(core))`), `IOwnable` вместо пустого `IOwnerModule`; `IOracleManagerProxy is INodeModule, IOwnable, IUUPSImplementation`.
- Замер: батч 100 матчей (200 ордеров) в одном `settleBookOrders` — 87,0 M газа на рынке описания (в #22 на рынке без комиссий было 92,2 M).
- **ethers v5 после `evm_revert`**: `tx.wait()` может зависнуть до таймаута теста — `_getInternalBlockNumber` не даёт номеру блока уйти назад, а `poll()` выходит рано, пока цепь не перегонит дореверт-высоту. `settleBook` ждёт майнинга циклом `provider.getTransactionReceipt(hash) === null`. Существующие `tx.wait()` после restore проходят только потому, что Anvil обычно успевает смайнить до первой проверки.
- `bun x hardhat test` не раскрывает glob сам — пути файлов передавать явно или неквотированным glob'ом (zsh раскроет); квотированный `'test/…/*.test.ts'` → «Cannot find module».
- Prettier: в perps-market версия пакетная и корневая расходятся на форматировании union-типов; pre-commit хук использует пакетную — форматировать `.ts` из `markets/perps-market` (`pnpm exec prettier --write`), ESLint — из корня репо (конфиг резолвит `./tsconfig.eslint.json` от cwd).
- Регрессия P3b: `eslint-plugin-progress` — workspace-пакет, pnpm не линковал его в корень → любой `eslint` из корня падал; починено `"eslint-plugin-progress": "workspace:*"` в корневом package.json.
- Pre-commit хук иногда зависает/падает разово на `.sol` (lint-staged + solhint печатает NDJSON в AI-окружении): после таймаута остаётся stash «lint-staged automatic backup» — проверить `git stash show --name-only` и дропнуть; повтор коммита с таймаутом ≥5 мин проходит.
- forge для perps-market не запускается ни в CircleCI, ни где-либо ещё до P3d.

**Why:** эти факты стоили нескольких прогонов; без них легко снова предложить vm.etch, длинное имя клона, `tx.wait()` после restore или запуск eslint из пакета.
**How to apply:** при любых правках стендов perps-market (Hardhat bootstrap или Foundry tests) начинать с этого списка; новые параметры сценария добавлять в `test/stand.json` и читать в обоих адаптерах, не хардкодить в одном.

Связано: [[architecture-review-2026-09-02]], [[gh-repo-liqcx-synthetix-v3]]

Два стенда на одной машине (с 739e6714, ветка карточки 2): `ANVIL_PORT=8555 CANNON_REGISTRY_PRIORITY=local bun x hardhat test …` и `ANVIL_PORT=8555 pnpm build-testable:foundry` — порт anvil и url провайдера берутся из `networks.cannon` в hardhat.config.ts пакета; по умолчанию 8545, который чужой cannon dry-run (fork MegaETH из monorepo/deployments) может держать часами. Хук worktree-сессии отказывает `$(ls …)` даже в не-git командах — списки файлов передавать явно.
