---
name: architecture-review-2026-09-25
description: "Обзор архитектуры perps-market от 2026-09-25 (main @ c59d8204, agentbox) — 12 карточек после закрытия карточек 1–2 обзора 07.09; верхняя: модуль ликвидации; карточка 6 обзора 07.09 устарела (async-дверь на Foundry смаршрутизирована, не хватает шага settle); карточка 3 обзора 05.09 не выложена и ждёт «го»; таблица остатков словаря стенда; пути и share-ссылки"
metadata:
  type: project
---

Обзор 2026-09-25 (`main @ c59d8204`, машина agentbox). Файлы: markdown-близнец
`/home/alex/Work/perps/synthetix-v3/architecture-review-20260925-2045.md` и HTML рядом
(scratchpad сессии, не репо); share-ссылки (`share` удаляет файлы старше 30 дней):
HTML https://agentbox.tail9ba5ab.ts.net/share/architecture-review-20260925-2045-4969ba7b.html, MD https://agentbox.tail9ba5ab.ts.net/share/architecture-review-20260925-2045-b48f48bd.md.
Рендер HTML на agentbox скриншотом не проверен — браузера нет (playwright-плагин ждёт /opt/google/chrome); проверка
HTML статическая (парсер, 10 Mermaid-блоков, метки с «:»/«/» закавычены). Проверка с мака — как в [[architecture-review-2026-09-04]]:
`python3 -m http.server` + playwright. Генератор: `gen_report.py` + `stand_cards.py` в том же scratchpad (одни карточки → HTML и MD).

Прошлые обзоры: 02.09, 03.09, 04.09 (карточки памяти есть), 05.09 и 07.09 (карточек обзора в памяти **нет** — известны только
карточки 1, 2, 4, 6 обзора 07.09 по спекам и карточка 3 обзора 05.09; карточки 3 и 5 обзора 07.09 этой сессии неизвестны).
Закрыто и не предлагалось снова: ворота, Settlement, OrderMode, assess/квота, valuation/flagReward/KeeperCosts, LiquidationFlag,
параметры стенда, CollateralChange, словарь стенда, один стенд/два адаптера.

Карточки (порядок отчёта; двое обходчиков — контракты и стенды):

1. **Вопрос «сколько получит кипер» — один модуль ликвидации** (Strong, **верхняя рекомендация**): пять файлов; кап
   `keeperReward` дважды с разными входами — ожидание `PerpsAccount.sol:603-610` (reward, flag+liquidate cost,
   `collateralValueWithoutDiscount`, член окон) и выплата `LiquidationModule.sol:291` (keeperRewards, costOfExecution,
   availableMargin, без окон); шесть построений оценки в модуле (:47,54,90,121,146,173,185); флаг поднимает библиотека,
   опускает модуль (:265-269); четыре оракульных вызова стоимости кипера на один `liquidate`. Тесты — только через `liquidate*`.
2. **Async-дверь — вторая дверь тех же ворот** (Strong, второй кандидат): из 13 fn `AsyncOrder` снаружи нужны только
   `checkPendingOrder`/`reset`; комиссия в трёх местах (`AsyncOrder.quote:262-266`, `AsyncOrderModule:132-134`,
   `BookOrderModule:63-64`); `validateCancellation:290-310` — ворота наизнанку; `_cancelOrder:68-78` — второй писатель
   `AccountCharged`, платит киперу мимо `Settlement.payFees`; `validateRequest:237` пишет фандинг на commit; мёртвое
   `PerpsMarket.Data.asyncOrders:62` (layout). Foundry: settle/cancel 0 файлов. CRIT-1: шов проверки цены у async-двери есть
   (`SettlementStrategy.priceVerificationContract`), книжная дверь его не спрашивает.
3. **Книжная дверь называет виновника батча** (Strong; карточка 3 обзора 05.09 — подтверждено: не выложено, `BookOrderRejected`/
   `MAX_BOOK_ORDERS` в коде нет; разбор в [[architecture-review-card3-batch-culprit]] ждёт «го», не переразбирать).
4. **Предусловие аккаунта на стенде — три дороги, перевёрнутая полярность дверей** (Strong): `traderAccountIds` 66 файлов
   без залога → 47 сырых `before`; глаголы 15 файлов; сырой `createAccount` 3; `stand.bookAccounts` исполняет только Foundry
   (`Bootstrap.t.sol:189`), Hardhat переводит всё вне `bookAccountIds` в ONCHAIN (`bootstrapTraders.ts:97`) — аккаунты 2/3 на
   двух стендах в разных режимах; 12 `setBookMode` руками.
5. **Толерантность цены — свойство вопроса, а не вызывающего** (Worth exploring): восемь вызывающих `valuation` выбирают
   tolerance; вьюха DEFAULT / дверь STRICT системно; `transferLiquidatedSynth:119-123` — DEFAULT внутри STRICT-ликвидации.
6. **Чтение аккаунта — одна картина вместо шести оценок** (Worth exploring): `PerpsAccountModule` 17 fn, шесть вьюх строят
   свою оценку; два правила в модуле (:165-173, :227-228).
7. **Ставка процента — глобальный побочный эффект в записи позиции** (Worth exploring): `PerpsMarket.updatePositionData:273` →
   `InterestRate.update(ONE_MONTH)` → скан всех рынков второй раз за ордер; `CollateralChange` ходит в ядро напрямую (:154,252,271,278).
8. **Foundry-близнец async-двери — недостающий шаг, не композиция прокси** (Worth exploring; **карточка 6 обзора 07.09
   устарела**): роутер Foundry-стенда содержит три Async-модуля (`cannonfile.test.toml:37-47,80-96`), `scripts/foundry-cannonfile.ts`
   меняет только имя и import→clone, мок Pyth задеплоен (:157), стратегия PYTH добавлена (`Bootstrap.t.sol:355-366`), `commitOrder`
   зовут `OrderMode.t.sol:68-80` и `CollateralChange.t.sol:102-114`; нет `settleOrder`/`setBenchmarkPrice` (0 под `tests/`) и
   типизированной ручки мока (`:85` — голый address). Устаревшие комментарии «the Foundry proxy does not route the async door»:
   `test/bootstrap/verbs.ts:42-46`, `test/integration/Stand.vocabulary.test.ts:28-33`, `docs/TESTING.md:246-247`.
9. **Свободные формы стенда: 122 литерала против 2–17 файлов на глаголах** (Worth exploring): «по касанию» сдвинуло гонки, не литералы;
   `depositCollateral` 25 файлов / 57 сайтов — самая большая свободная форма; async-дверь — главная дорога к позиции (57/71 файлов).
10. **Оракулы арифметики в TS — второй адаптер правила, не пришпиленный к первому** (Worth exploring): computeFees, requiredMargins,
    fillPrice, funding-calcs, interestRate ни разу не сверены с вьюхами контракта; Foundry считает руками (`LiquidationReward.t.sol:25-27`).
11. **Конфигурация — инварианты у сеттеров, а не у читателей** (Worth exploring): 19/22, 12/17, 6/8 pass-through; guard-ы на ноль в
    `PerpsMarket:139,350,560`, `PerpsMarketConfiguration:139`.
12. **PerpsMarket — шесть вопросов и мёртвые члены** (Speculative): `computeFillPricePnl:579`, `PerpsCollateralConfiguration.isSupported:124`.

Проверено и не предлагается: preload mocha→bun:test (deletion test: концентрирует — 662 `before(` в ~70 файлах); переименование
каталогов test/integration под двери; `tests/interfaces/*Proxy.sol` по наследованию; InsufficientCollateral vs InsufficientSynthCollateral
(избыточное правило, не шов: `PerpsAccount:266` держит lockstep). Открытая карточка 4 обзора 07.09 (четыре вопроса `PerpsAccount`)
подтверждена и распределена по карточкам 1, 5, 6; три смысла `AccountLiquidatable`: :681 (assess), `CollateralChange:229`, `LiquidationFlag:82`.

Остатки словаря стенда (спека 07.09 на 37b51c6a → сейчас): `openPosition({` 121 → 122; `systems().PerpsMarket` 764 → 739; `.wait()` 15 → 0;
`commonOpenPositionProps` 9 → 9 файлов; сырой `mockSetCurrentPrice` 62 → 60; локальные обёртки liquidate 3 → 0; файлов на `standMarket()`
3 → 7 из 71; не на `stand.json` 56/61 → 64/71; inline `liquidationParams`/`liquidationGuards` 31/25 → 31/25; `receiptOf` напрямую 23 сайта / 8 файлов;
объектная форма: `settleBook({` 12, `openBookAccount({` 12, `openOnchainAccount({` 5, `settleOrder({` 4. Глаголы (файлов): liquidate 17, crash 17,
settleBook 11, bookOrder 10, openBookAccount 9, openOnchainAccount 6, depositMargin 5, settleOrder 5, openBookPosition 4, liquidateMarginOnly 4,
openOnchainPosition 2. Двери по каталогам (async/book/account/liquidate): Account 12: 8/3/10/0; KeeperRewards 5: 5/0/0/4; Liquidation 12: 10/3/10/11;
Market 11: 7/0/7/1; Orders 19: 16/4/13/2; Position 7: 7/3/6/3.

**Why:** карточки закрываются по одной через разбор → «го» → спека → PR; без записи статуса и фактов следующий обзор переисследует
контракты и стенды, а устаревшая причина карточки 6 снова попадёт в спеки.
**Статус 25.09 (вечер):** карточка 1 разобрана (grilling, «все ок»), спека и `CONTEXT.md` на ветке `feat-cld/liquidation-module` — см. [[architecture-review-card1-liquidation]]. Для карточки 2: deployments (`20edd8e`, 25.09) — staging = контур 6-dev, mark price из RedStone, async-стратегии выключены, «no async-order path»: async-дверь на контурах не используется, карточку 2 при разборе переформулировать (углублять ради общего Settlement/ворот, не ради второй живой двери).

**How to apply:** перед следующей карточкой сверить список; после «го» на карточку 1 — разбор (одна оценка на вход, один кап, флаг
вверх/вниз в одном модуле), спека, ветка `feat-cld/…` от `main`; карточка 3 — сначала «го» на умолчания разбора 06.09; при работе над
карточкой 8 или словарём стенда — исправить три устаревших комментария. После слияния PR обновить строку карточки здесь.

Связано: [[architecture-review-2026-09-04]], [[architecture-review-card3-batch-culprit]], [[architecture-review-card2-collateral-change]],
[[foundry-stand-after-pnpm]], [[memory-in-repo]], [[gh-repo-liqcx-synthetix-v3]]
