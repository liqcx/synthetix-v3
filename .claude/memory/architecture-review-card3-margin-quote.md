---
name: architecture-review-card3-margin-quote
description: "Карточка 3 обзора 04.09 («ворота отвечают и сколько»): разбор card3-margin-quote-20260904.html, шесть решений с умолчаниями (ждут «го»), факты по потребителям вьюх в monorepo/SDK/kwenta/сабграфе, найденное по пути (SIP-359 только во вьюхе, ловушка порядка аргументов); «го» 04.09; PR A = synthetix-v3#30 (draft, main) сделан 04.09 через SDD; грабли стендов и хостa"
metadata: 
  node_type: memory
  type: project
  originSessionId: 8c3bd964-0924-40b0-89e5-5c15c79b60c2
  modified: 2026-09-04T11:01:14.604Z
---

Карточка 3 обзора 2026-09-04 разобрана 2026-09-04 артефактом `card3-margin-quote-20260904.html`
(в /var/folders/.../T/, рядом с прежними; локальный файл, проверен скриншотом через
`python3 -m http.server` + playwright). Чекаут sv3 в тот день был занят веткой
`feat-cld/gha-migration` (застейдженные правки P3d) — работу по карточке вести в worktree от main.

Шесть умолчаний — «го» получено 04.09:
(1) `quoteBookOrder(accountId, marketId, sizeDelta, orderPrice) → Quote{markPrice, orderFees,
availableMargin, requiredMargin}` в `IBookOrderModule`; (2) quote ревертит как дверь и аккаунт
на расчёте (режим, девиация, существование, флаг, ликвидируемость, место), маржу отдаёт числами,
капы рынка не спрашивает; (3) `PerpsAccount.assess → Assessment` ревертит для аккаунта, который
торговать не может вовсе, — `requiredMarginForOrder` вместе с ним; (4) `requiredMarginForOrder`
говорит правду о сокращении (IM сокращённой + награда + комиссии вместо 0 из SIP-359);
(5) удалить `createUpdatedPosition`, `requiredMarginImmut`; имена параметров интерфейса — в порядке
реализации `(accountId, marketId, sizeDelta)`; (6) PR B в monorepo — отдельный brainstorm после
выката роутера, отправная модель лока: два quote (size и 0) в одном multicall,
consumed = Δavailable + Δrequired.

Правило допуска в оценке: изменение проходит ⇔ `availableMargin ≥ requiredMargin`
(available — после удара и комиссий); два реверта `InsufficientMargin` ворот — его два случая,
полезная нагрузка не меняется, порядок проверок ворот не меняется.

Факты по потребителям (разведка 04.09): шлюз спрашивает цепь только `getAvailableMargin`
(`margin.service.ts:97`), требование — `size × price × bps / (1e4·1e18)` с `Market.initialMarginBps`
из Prisma (кэш 5 мин, `market.service.ts:46-65`), лок — `SUM(MarginLock)` в Postgres, reduceOnly
маржу не спрашивает (`submit-order.handler.ts:222`); допуск за швом `IMarginReader` (ADR-0026,
staging). ABI SDK рукописный (`liq-onchain/src/abis/perps-market-proxy.ts`, `book-order-module.ts`),
codegen нет, страж — `__tests__/perps-market-proxy-abi.test.ts`; monorepo `main` ~3 релиза позади
`staging` (0.42.0 — то, что стоит у kwenta). Держать сигнатуры: `requiredMarginForOrder`
(порядок реализации), `computeOrderFeesWithPrice`, `getAccountFullPositionInfo` и все «сейчас»-вьюхи;
свободны: `computeOrderFees` (bare), `requiredMarginForOrderWithPrice`, `requiredMarginImmut`.
kwenta считает max size сам (`availableMargin × maxLeverage`); `getOrderMarginPreview` никто не зовёт.
Сабграф eth_call не делает. Дрейф: `main` monorepo объявляет у `settleBookOrders` выход
`cancelledOrders`, `staging` — `outputs: []`.

Найдено по пути: SIP-359 (сокращение без IM) живёт только во вьюхе — ворота форка требуют IM с
сокращённой позиции и требовали до ворот (`validateRequest` до cd1639df^); давать ли воротам
исключение — продуктовый вопрос вне карточки. Интерфейс `IAsyncOrderModule.requiredMarginForOrder`
объявляет `(marketId, accountId)`, реализация `(accountId, marketId)` — селектор общий, SDK 0.42.0
держит «ARG-ORDER TRAP». Тест `Order.reduceSize.test.ts:193-211` сходится только потому, что
комиссии фикстуры 0.

**Why:** карточка идёт через PR в двух репо и тот же апгрейд роутера, что карточка 1; без записи
решений и карты потребителей разбор пришлось бы повторять.
**How to apply:** работа идёт в worktree `.claude/worktrees/feat-cld+margin-quote` (EnterWorktree, ветка
переименована в `feat-cld/margin-quote`, база main 821feed5; в свежем worktree нужно собрать
`utils/core-utils` и `utils/hardhat-storage` через `bun x tsc --noEmit false --project src/tsconfig.json`,
иначе hardhat не найдёт `@synthetixio/hardhat-storage/dist`). Спека
`docs/superpowers/specs/2026-09-04-margin-quote-design.md` (коммит 826eba1c, «ок» пользователя 04.09) и план
`docs/superpowers/plans/2026-09-04-margin-quote.md` (76d8727e, пять задач: assess под воротами → quoteBookOrder +
таблица Hardhat на фикстурах ворот → async-вьюхи и удаления → Foundry → дамп/доки/прогоны/газ/PR).
Выполнено 04.09 subagent-driven: ветка `feat-cld/margin-quote` = коммиты 7ad63c21 (assess), 6ff6462d
(quoteBookOrder + PositionChange.quote.test.ts), 9b8d9eff (async-вьюхи, удаления), 808eef79 (Quote.t.sol),
2f553d55 (дамп, поправка к спеке ворот), 0798a10e (волна правок финального ревью: assess отдаёт
загруженный `PerpsMarket.Data storage` вторым значением — ворота не хешируют load дважды; поле `fees`
из Assessment убрано; quote проверяет девиацию раньше двери, как расчёт; natspec: quote не видит батч и
не спрашивает perpsSystem; describe с `setKeeperRewardGuards(5, 0, 1000, 1)` пинит награду в
requiredMargin; строка нулевого ордера в таблице ворот). **PR A = liqcx/synthetix-v3#30** (draft, база
main, 04.09). Газ батча 100 матчей: 89,016,862 → 89,816,230 (+0,9 %, дубль PerpsMarket.load ≈ 5 слов
памяти на ордер под квадратичным членом) → 89,125,411 (+0,12 %). Тесты: quote 22, ворота 34, Orders 229,
Account 93, Position 99, Liquidation 67 (по файлам; каталогом флейкает и на базе), Market 154, forge 19.
Запарковано: Quote.t.sol сравнивает 0 == 0 по награде (стенд Foundry без параметров ликвидации);
хелпер PerpsMarket «fill, затем fee» (два текста по две строки). PR B в monorepo — после роутера с
#30 на контуре; тело PR #30 описывает модель допуска «два quote в одном multicall».

Грабли 04.09: solc требует `@return` на каждое именованное возвращаемое значение, если есть хоть одно;
`hardhat storage:verify` нужен файл `storage.new.dump.json` — verify до `cp && rm`; каталог Liquidation
целиком флейкает before-all таймаутами (и на main), по файлам зелёный; MarketDebt.test флейкает в пачке;
хук worktree-сессии отказывает сложным bash-командам с `git`/`cd` — дробить; в свежем worktree
собирать utils/core-utils и utils/hardhat-storage; `.superpowers/` не в .gitignore — добавлен в
`.git/info/exclude`; хук UserPromptSubmit «/phase» просит выбрать план при «продолжай» — записан
`.claude/active-plan`. Исполнитель задачи 3 стёр `~/.local/share/cannon/ipfs_cache` (12 ГиБ,
регенерируемый) из-за ENOSPC на хосте (было ~100 МиБ свободно от чужой активности).

Связано: [[architecture-review-2026-09-04]], [[architecture-review-card1-order-mode]], [[foundry-stand-after-pnpm]], [[gh-repo-liqcx-synthetix-v3]]
