---
name: architecture-review-card1-order-mode
description: "Карточка 1 обзора 03.09 («дверь аккаунта — один модуль», дом CRIT-2): разбор card1-account-door-20260904.html, решения по умолчанию приняты 04.09, спека и планы в docs/superpowers, ветка feat-cld/order-mode; статус PR A/B/C/D"
metadata: 
  node_type: memory
  type: project
  originSessionId: ab6a3743-bafe-4a90-8a8e-7873c55c52c8
  modified: 2026-09-04T06:28:27.476Z
---

Карточка 1 обзора 2026-09-03 разобрана 2026-09-04 артефактом `card1-account-door-20260904.html`
(в /var/folders/.../T/, рядом с прежними). Пользователь сказал «го» на пять умолчаний:
(1) библиотека `OrderMode` в `contracts/storage/` рядом с `PerpsAccount` (как `Settlement`), владеет
полями `orderMode`/`orderModeChangeTime`, функции `current`/`admit`/`set` (`of` в Solidity зарезервировано); (2) `setBookMode`/`getOrderMode`
переезжают в `PerpsAccountModule`/`IPerpsAccountModule` (селекторы те же, офчейн не видит);
(3) CRIT-2 закрывается флагом `settleBookOrders` (allowlist владельца, рождается закрытым) — PR B +
PR C в synthetix-deployments (allowlist до `upgradeTo`); (4) мёртвый гард вывода залога удаляется,
дверь вывод не регулирует; (5) имя `OrderMode`, «дверь» остаётся словом обзора/ADR.

Правила двери: BOOK — умолчание; книга открыта в BOOK и в окне 15 с после переключения в любую
сторону, async — только в ONCHAIN; переключение с висящим async-ордером отказывает
`PendingOrderExists` (MED-2, INFO-3 закрыты по построению — `settleOrder` режим не спрашивает);
set в тот же режим — ничего (ни окна, ни события); первый set из умолчания — сразу; `current` не
сообщает окно, пока `orderModeChangeTime == 0`.

Документы: спека `docs/superpowers/specs/2026-09-04-order-mode-design.md`, планы
`docs/superpowers/plans/2026-09-04-order-mode.md` (PR A) и `2026-09-04-book-settler-allowlist.md`
(PR B). Ветки: `feat-cld/order-mode` (PR A, база main), `feat-cld/book-settler-allowlist` (PR B,
stacked). PR C (deployments: настройка адреса сеттлера в омнибусах, invoke allowlist, шаг в
`upgrade-router-bookdefault.js`, e2e `Book_Order_Trading` вносит свой кошелёк) и PR D (доки
monorepo: security-model, book-order-module.md, SKILL.md, TSDoc accounts.ts/account.ts) — после.
Адреса сеттлеров контуров нужно спросить у пользователя (или снять с цепи по `from` последних
`settleBookOrders`).

Найдено по пути: `bootstrapTraders` не может импортировать helpers (runtime-цикл через
`helpers/computeFees.ts`); Foundry-стенд не имел стратегии расчёта — добавляется из
`test/stand.json` (`marketDefaults.settlementStrategy`), верификатор — `MockPythERC7412Wrapper`
(clone его деплоит, ключ `deployer.getAddress("MockPythERC7412Wrapper")`); `foundry.toml` пинит
`block_timestamp` 2025 года; `assertRevert` печатает bytes16 как `0x`+32 hex, bytes32 — 64 hex;
ошибки библиотек попадают в ABI модуля (в ABI BookOrderModule уже `InvalidParameter`,
`FeatureUnavailable`).

Ход PR A (04.09): коммиты c9e93301 (helpers + flaggedLiquidation зелёный), 9dbec326 (OrderMode +
модули + таблица двери Hardhat, 19 строк, мутация гарда `||` красит 4 строки), 6516e1f2 (Foundry:
стратегия из stand.json, onchainTrader, OrderMode.t.sol 7 тестов, первые реверты стенда),
572e3fd4 (леджер MED-2/INFO-3, BookOrder.test.ts без блока режимов). Грабли: `of` — reserved
word в Solidity (парсеры prettier/solhint падают с TypeError, компилятор — ParserError);
pre-commit гоняет `prettier --check` корневой версией — файл, отформатированный пакетным
prettier (`bootstrapPerpsMarkets.ts`), хук отверг; форматировать из корня репо. Флейк
`OffchainAsyncOrder.commit › check position is live` (panic 0x11) при прогоне группы файлов,
поодиночке проходит. Газ батча 100 матчей: 89,009,207 (было 88,999,489).

PR A = liqcx/synthetix-v3#27 (draft, база main, ветка `feat-cld/order-mode`), все каталоги зелёные
(Account 89, Orders 229, Position 76, Liquidation 67, KeeperRewards 28, Market 154; forge 7+3+5).
PR B (ветка `feat-cld/book-settler-allowlist`, stacked на A): коммиты 1874aa11 (флаг
`settleBookOrders` + проверка + allowlist кипера в bootstrapTraders + 4 строки таблицы), f2dfd437
(Foundry: `_configurePerps` вносит address(this), тест вызывающего), 5d3e90bc (леджер CRIT-2 →
Fixed, CLAUDE.md). В synthetix-deployments выписана чужая ветка `feat-cld/book-settlement-module`
(спека+план «книжный сеттлмент как модуль», untracked .claude/active-plan) — базу PR C выбирать
с пользователем. e2e `Book_Order_Trading` рассчитывает книгу случайным кошельком (`fundedWallet`),
для PR C его нужно вносить в allowlist владельцем (impersonate на форке).

Итог 04.09: PR A = synthetix-v3#27 и PR B = #28 слиты в main (71651720, 821feed5) по «мержи все
pr's synthetix-v3»; контракты на контурах ещё не обновлены (роутер: BookOrderModule,
AsyncOrderModule, PerpsAccountModule),
PR D = monorepo#745 (draft, staging, worktree `monorepo/.worktrees/order-mode-docs`; мержить после
выката роутера с #27+#28). PR C (deployments) не начат — ждёт ответов: адрес сеттлера прода
(staging по цепи: 0xAc2B0280c1bB7F465De5efF160C62EC17BD9045D; на проде последние
BookOrderSettled ~27.8M блоков слал владелец 0x8fF5bE45…), база/worktree (чекаут занят веткой
feat-cld/book-settlement-module с сегодняшней спекой кандидата 7, где запланированы фикстура
сеттлера и тест неавторизованного сеттлера — e2e-часть PR C логично отдать той арке).

**Why:** карточка идёт через четыре PR в трёх репо; без записи решений и порядка выката разбор
пришлось бы повторять.
**How to apply:** статус PR обновлять здесь; после слияния A/B — деплой (PR C) строго
«allowlist → upgradeTo»; следующая карточка обзора — 3 или 4.

Связано: [[architecture-review-2026-09-03]], [[foundry-stand-after-pnpm]], [[gh-repo-liqcx-synthetix-v3]]
