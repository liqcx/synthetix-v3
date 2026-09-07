---
name: architecture-review-card2-account-valuation
description: "Карточка 2 обзора 04.09 («ликвидационная арифметика берёт аккаунт»): разбор card2-account-valuation-20260904.html, восемь решений («го» 04.09), PR liqcx/synthetix-v3#31 draft сделан 04.09 через SDD (9 коммитов, газ +0,18 %), решения контроллера, грабли (порт 8545 занят чужим anvil → ANVIL_PORT; storage:verify ругается на memory-структуры), follow-up карточки"
metadata: 
  node_type: memory
  type: project
  originSessionId: 680b5a2c-ac9b-4c23-98e3-b34859f11619
  modified: 2026-09-04T14:41:08.507Z
---

Карточка 2 обзора 2026-09-04 разобрана 2026-09-04 артефактом `card2-account-valuation-20260904.html`
(в /var/folders/.../T/, рядом с прежними; локальный файл, проверен скриншотом через
`python3 -m http.server 8765` + playwright MCP; скриншоты падают в корень worktree — удалять).
База — `main` @ 8bbc3e71 (слияние #30, 04.09 14:18Z). Работа идёт в том же worktree
`.claude/worktrees/feat-cld+margin-quote` (он изолирован; имя каталога устарело), ветка
`feat-cld/account-valuation` создана от origin/main 04.09, upstream снят (`--unset-upstream`, чтобы
push не ушёл в main). Сборка core-utils лежит в `utils/core-utils/utils` (tsconfig outDir `..`), а не
в `dist` — проверять `ls utils/core-utils/utils/assertions`; hardhat-storage — в `dist`. Базовый прогон
feeds-теста зелёный (6 passing).

Восемь умолчаний (**«го» получено 04.09**):
(1) `struct Valuation { MemoryContext ctx; collateralValueWithDiscount; collateralValueWithoutDiscount }`,
`valuation(self, tolerance)`; `Assessment { Valuation valuation; oldPosition; newPosition; availableMargin;
requiredMargin }`; читатели допуска берут Valuation; части (`getOpenPositionsAndCurrentPrices`,
`getTotalCollateralValue`) остаются для читателей «только позиции». (2) Толерантность вывода —
STRICT для обеих (апстрим до 31d0b06c) — **единственное изменение поведения**: вывод синта при
протухшей цене синта ревертит `OracleDataRequired`; альтернатива DEFAULT обе. (3) `KeeperCosts.
getFlagKeeperCosts(self, PerpsAccount.Data storage account)` — имя прежнее, тип параметра ловит
отставших; `getNumberOfUpdatedFeedsRequired` остаётся в PerpsAccount. (4) `flagReward(ctx,
collateralValue, keeper)` одним текстом, `address(0)` = никем не endorsed; правило «залоговая награда
удерживается, если endorsed на рынке последней позиции» сохраняется. (5) `isEligibleForMarginLiquidation(v)`
через `getPossibleLiquidationReward(v)` (для пустого ctx = сегодняшняя формула). (6) База капа выплаты —
seized как сегодня (`_liquidateAccount(ctx, flagCost, seized, flagged)`); альтернатива — читать из
оценки и снять возвраты у `seizeCollateral`. (7) Окна — свой проход `liquidationWindows(ctx)`,
`getKeeperRewardsAndCosts` уходит. (8) Два новых пина: `Liquidation/Liquidation.reward.test.ts`
(«что аккаунт обязан держать — то кипер и получает», обе ветви max, endorsed = только стоимость) и
`Account/ModifyCollateral.withdraw.staleness.test.ts` (строгость обеих половин; спот
`updatePriceData(synthId, buy, sell, 50)` как в `bootstrapSynthMarkets.ts:78`).

Факты (проверены 04.09): прелюдий 9 в 3 файлах (async-вьюхи ушли в #30) — LiquidationModule
:51-59/:98-110 STRICT, :218-225/:240-246 DEFAULT; PerpsAccountModule :250-256/:266-273/:296-306 DEFAULT;
PerpsAccount `validateWithdrawableAmount` :369-376 STRICT/DEFAULT, `assess` :717-723 DEFAULT. Фиды
считают 4: PerpsAccount :217-219, :274-276, :596/:650, LiquidationModule :118-120. До 31d0b06c шов был
`getFlagKeeperCosts(self, accountId)` и считал фиды сам; `KeeperCosts.sol:8,19` — неиспользуемые
import/using PerpsAccount, след прежнего шва. Раскол толерантности вывода — в самом 31d0b06c
(до него `getWithdrawableMargin(self, STRICT)`); локальный `upstream/main` (2025-06-12) 31d0b06c не
содержит. Награда за флаг: PerpsAccount :611-639/:641-662 (ожидание) и LiquidationModule :304-333
(выплата, endorsed-поворот, `min(i, len-1)` — реликт); база капа одна: `seizeCollateral` → 
`transferLiquidatedSynth` → тот же `valueInUsd`/`indexPrice(sell)` при DEFAULT. Флагнутый не может
внести залог (`modifyCollateral` → `checkLiquidation` :69). `storage.dump.json` пишет memory-структуры
(MemoryContext :677, Assessment :873) — регенерировать. Пины наград порознь: KeeperRewards/* (выплата),
Order.marginValidation (требование); равенство не пинит никто.

**Why:** карточка идёт тем же апгрейдом роутера, что карточка 1 и #30; без записи решений разбор
пришлось бы повторять.
**How to apply:** сделано 04.09 subagent-driven: спека 10b607a2 («ок» 04.09), план 2f6ead3b, коммиты
7232e4f2 (Valuation + пин строгости вывода: RED 4/1 → GREEN 5/0), 9e78042d (flagReward одним текстом,
KeeperCosts(account), пин Liquidation.reward.test.ts 3 — проходит и до, и после), 739e6714 (порт стенда из
`ANVIL_PORT`, url из той же переменной — Hardhat валидирует сырой конфиг до extendConfig), 5e59b44f (дамп,
заметки в спеках), f113f044 (perf: один проход по позициям — приватные `_positionFlagReward` и
`_withCollateralReward`, общие для flagReward и getAccountRequiredMargins; `_possibleLiquidationReward(v,
reward, windows)`; `seizedMarginValue`; мёртвые using/import), 1adcda29 (матчер селектора substring(0, 10)
в двух тестах), 748bfc46 (спека после финального ревью). **PR = liqcx/synthetix-v3#31** (draft, main).
Газ батча 100 матчей: 89,125,411 → 90,568,686 (+1,62 % при трёх проходах по позициям: memory от
abi.encode в PerpsMarketConfiguration.load под квадратичным членом батча, getAccountRequiredMargins
зовётся дважды на assess) → 89,286,558 (+0,18 %, остаток — Assessment на слово глубже). Тесты на HEAD:
Liquidation 11 файлов, KeeperRewards 28, Account 98, gate 34 + quote 22, Orders margin 6, forge 19.
Решения контроллера (SDD): storage:verify ошибки по memory-структуре Assessment приняты (как 0798a10e в
#30; строки verify процитированы в PR); чужой anvil на 8545 (dry-run omnibus-megaeth-testnet-staging из
perps/monorepo) не убит — порт стенда стал настраиваемым.
Follow-up (не в PR): двухрыночный endorsed-случай (правило последней позиции); один экспортированный
`receiptOf` вместо пяти копий опроса receipt; научить hardhat-storage verify пропускать структуры,
недостижимые из storage; два вызова оракула за стоимостью флага в liquidate; liquidateMarginOnly
повторяет flagForLiquidation. Заметка выката: на графе с circuit breaker строгий допуск даёт fallback-цену,
а не реверт. Не делаем (замечено): `liquidateMarginOnly` через
`flagForLiquidation`, двойной вызов оракула за стоимостью флага в `liquidate`, правило последней позиции.

Связано: [[architecture-review-2026-09-04]], [[architecture-review-card3-margin-quote]], [[foundry-stand-after-pnpm]], [[gh-repo-liqcx-synthetix-v3]]
