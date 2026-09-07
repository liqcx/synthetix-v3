---
name: architecture-review-2026-09-03
description: "Обзор архитектуры perps-market от 2026-09-03 (артефакт architecture-review-20260903-2230.html) — шесть карточек, верхняя рекомендация «события расчёта — один модуль на обе двери», статус разбора: PR #25/#26/monorepo#743"
metadata:
  node_type: memory
  type: project
  originSessionId: cfde7d1d-c5fc-409e-8efa-28c79add184b
  modified: 2026-09-04T02:30:00.000Z
---

Обзор 2026-09-03 (HTML `architecture-review-20260903-2230.html` в /var/folders/.../T/) перенумеровал карточки после закрытия 1, 2, 5, 9, 11 обзора 02.09:

1. дверь аккаунта — один модуль (Strong; дом для CRIT-2, следующая арка после карточки 2)
2. события расчёта — один модуль на обе двери (Strong; **верхняя рекомендация** — сделана, см. ниже)
3. ликвидационная арифметика берёт аккаунт (Strong; дефект `getFlagKeeperCosts(ctx.accountId)` в `PerpsAccount.sol:211` — исправлен в #25)
4. апгрейд роутера у одного владельца (Strong; копии скриптов в synthetix-v3 удалить, владелец — synthetix-deployments)
5. ворота отвечают «сколько» (Worth exploring)
6. батч называет виновника в своей последовательности (Worth exploring; расходится с ADR-0060 §4)

Состояние карточки 2 (04.09.2026, по «мержи» пользователя #25 и #26 слиты в main: 0f083b0d, e95244ea; #743 ждёт деплоя сабграфа с `pnl`): пользователь сказал «го» на умолчания разбора `card2-settlement-events-20260903.html` (там же в T/). PR A = liqcx/synthetix-v3#25 (база main, ветка `feat-cld/flag-cost-feeds-and-settled-id`: аргумент flag-cost + пин `Liquidation.marginOnly.feeds.test.ts`, ключи `OrderSettled`/`PositionLiquidated` по логу). PR B = liqcx/synthetix-v3#26 (ветка `feat-cld/settlement-events`; была stacked на A, перенацелена на main через `gh api -X PATCH repos/liqcx/synthetix-v3/pulls/26 -f base=main`, потому что `gh pr edit` в этом репо не работает; `gh pr ready`/`gh pr merge --merge` работают). Конвенции: synthetix-v3 — merge-коммиты, ветки не удаляются; monorepo staging — squash. Спека и план: `docs/superpowers/{specs,plans}/2026-09-03-settlement-events*.md`. PR C = liqcx/monorepo#743 (база staging, worktree `monorepo/.worktrees/settlement-readers`, ветка `feat-cld/settlement-events-readers`); мерджить только после деплоя сабграфа с `pnl` — запрос `ORDER_SETTLEMENTS_QUERY` просит поле. Порядок деплоя: роутер (#25 + #26, через synthetix-deployments) → одна версия сабграфа с полным ресинком на обоих контурах MegaETH → #743 (`gh pr ready 743 && gh pr merge 743 --squash`). Сабграф деплоят скрипты `goldsky:megaeth-testnet-{production,staging}` в `markets/perps-market/subgraph/package.json` (пинят версию 0.0.1, для ресинка нужна новая); `goldsky` CLI на машине не залогинен (нужен интерактивный `goldsky login` от пользователя); эндпоинты приватные, без `SUBGRAPH_API_TOKEN` отвечают 401.

Газ Foundry-стенда (без fee collector): 100 матчей (200 ордеров) 87 018 290 → 88 999 489 (+2,3 %), 1 матч +0,3 %. Рост с размером батча — память: книга расчитывает батч в одном фрейме, Solidity память не освобождает, расширение квадратично; база оставляет ≈480 слов на ордер (её же цена ордера растёт с 355 k при 20 до 435 k при 200), библиотека добавляет 11 слов структур (`Change`, `Fees`). Возврат `SettledChange memory` из `Settlement.settle` — 25 обнулённых слов, никем не читавшихся — стоил +5,0 % и убран (коммит ad061fd8). Идея на следующий обзор: сброс free memory pointer на каждый ордер в `settleBookOrders` снял бы квадратичный член базы (≈18 M из 87 M на 200 ордерах).

Флейк стенда: прогон всего каталога `Orders/` иногда роняет 1–4 теста (panic 0x11 в `getOpenPosition` после async-расчёта, «cannot estimate gas» в before-all) и на базовой ветке тоже (1 из 2 прогонов); `MarketDebt.withFunding` «resets trader debt to 0» тоже падал раз в прогоне каталога; файлы поодиночке проходят. Описано в теле #26.

Найдено по пути: ликвидация шорта писала `MarketUpdated.sizeDelta` с обратным знаком (исправлено в #26: один писатель `Settlement.emitMarketUpdated`); `Liquidation.marginOnly` не видит дефект карточки 3 (аккаунт 2 = 2 фида); `mapOrderSettled` в SDK ждал полей, которых нет в схеме, и не имеет вызовов ни в monorepo, ни в kwenta (выровнен в #743); LOW-3 закрыт по построению, LOW-4 был закрыт с #21 (леджер аудита обновлён в #26). Solc 0.8.34: `emit IFace.Event(...)` из internal-функции библиотеки компилируется, событие попадает в ABI модуля без дублей (проверено scratch-сборкой forge). В monorepo тесты — `bun test` (moon-таска `test`), не vitest.

**Why:** карточки закрываются по одной через артефакт → выбор пользователя → PR; без записи статуса разбор пришлось бы повторять.
**How to apply:** обзор пересобран 04.09 — см. [[architecture-review-2026-09-04]] (карточки 1 и 2 закрыты, нумерация новая); эта запись — история и факты про газ/флейки/сабграф. После слияния #743 обновить строку про деплой сабграфа.

Связано: [[architecture-review-2026-09-02]], [[foundry-stand-after-pnpm]], [[gh-repo-liqcx-synthetix-v3]]
