---
name: architecture-review-card2-collateral-change
description: "Карточка 2 обзора 07.09 («Изменение залога — один модуль», Strong): разбор card2-collateral-change-20260907.html в ~/Documents, девять умолчаний («го» 07.09), зонд ставки число в число, поправка офчейн-предпосылки (SDK/kwenta), инвентарь пинов; PR A synthetix-v3#38 слит 08.09, PR B monorepo#747 draft 08.09"
metadata:
  type: project
---

Разбор карточки 2 обзора 07.09 (`architecture-review-20260907-0454.html`, main @ 37b51c6a) сделан 2026-09-07
по `main @ 9e21507f` (после #36): HTML `~/Documents/card2-collateral-change-20260907.html` — рядом с обзором,
локальный файл (не Artifact), проверен скриншотом (playwright + `python3 -m http.server` из scratchpad;
file:// заблокирован; скриншоты падают в `.playwright-mcp/` чекаута — удалять). **Слита 08.09 (merge 1fbb39dd): PR liqcx/synthetix-v3#38 — https://github.com/liqcx/synthetix-v3/pull/38 ; контракты на контурах
ещё не обновлены (роутер: PerpsAccountModule и всё, что компилирует PerpsAccount/GlobalPerpsMarket — набор из сборки; едет с #30–#37).
После слияния основной чекаут стоял на чужой ветке feat-cld/moon-migration — main туда не подтягивался, копии памяти оставлены как живые; все четыре
задачи плана закрыты с чистыми ревью; финальное ревью ветки (opus): 0 BLOCKER, 3 SHOULD-FIX в тексте спеки — закрыты волной
b7734bd6 (реревью чистое); «Ready to merge: with fixes» → готово, мержить руками пользователя.** Коммиты: 92920695 спека, 0797c07a план,
5423fcc2+14f58d71 таблицы двери (красные на базе ровно на трёх изменившихся ответах), d521c5fa библиотека + двери + удаления
(ABI-имена модуля без изменений: 25 ошибок / 4 события / 17 функций; storage:verify чист), 1eea77a4 отложенные миноры
(try/finally у капа, строка «платит чужой», natspec), 34873ee6 заметка в спеке событий расчёта. Guard: Account 117, Position 99,
Liquidation 38, Orders 229, Market 154, Suspend+Stand 17, KeeperRewards 28; forge 9 suites / 53 tests. Газ (Hardhat receipts, зонд
плана): депозит 192 022 → 191 946, вывод 221 685 → 221 985, payDebt 183 565 → 183 294; forge депозит 147 436 → 147 360, вывод
159 335 → 159 635; батч 100 матчей 92 259 058 без изменений. Грабли: `getWithdrawableMargin` у аккаунта с позицией дрейфует на
блок начисления процентов — в таблице чтение с `{ blockTag: 'pending' }`, чтобы совпасть с ревертом из eth_estimateGas; forge
`Account` из core затеняется структурой forge-std → импорт `Account as CoreAccount`; forge `vm.expectRevert(bytes)` принимает
более короткий фактический реверт как префикс (DP-075) — мутировать селектор, а не «добавлять аргумент»; одиночный
`markdownlint-cli2 <file>` красный из-за markdown в gitignored `.superpowers/**`, gate CI — `pnpm lint:md`. Найдено, не на карточку:
`AccountLiquidatable` из правила вывода срабатывает ниже IM+reward, не только у ликвидируемого (карточка 4); вьюха DEFAULT vs
дверь STRICT. **«Го» на девять умолчаний — 07.09 (вечер).**
Спека `docs/superpowers/specs/2026-09-07-collateral-change-design.md` (коммит 92920695) и план
`docs/superpowers/plans/2026-09-07-collateral-change.md` (0797c07a) — на ветке `feat-cld/collateral-change` от
`main @ 6835e6fa` (после слияния #37) в worktree `.claude/worktrees/feat-cld+margin-quote` (освободился, #37 слит;
upstream у ветки не ставится намеренно). Прогон SDD: `plan-state` в `<worktree>/.claude/plans/2026-09-07-collateral-change/`,
леджер `<worktree>/.superpowers/sdd/2026-09-07-collateral-change/progress.md`; четыре задачи: 0 база (ABI-имена модуля,
счётчики, газ дверей зондом), 1 таблицы двери на обоих стендах против базы (красные ровно на трёх изменившихся ответах),
2 библиотека + двери + удаления + ABI-диф + storage + три мутации, 3 документы + guard + draft PR. Два уточнения сверх
умолчаний, записанные в спеку: `ModifyCollateral.failures.test.ts` поглощается таблицей (`git mv` →
`CollateralChange.door.test.ts`); `NonexistentDebt` называет запрошенный аккаунт, а не `account.id` (был 0 для аккаунта
без депозитов) — третий изменившийся ответ рядом с двумя от порядка «кто стучится» (PermissionDenied / AccountNotFound
вместо InvalidId при незнакомом залоге). Оговорка про синт в правиле ставки (wash с точностью до согласия цен ядра и
спота) — в спеке. После слияния PR: в основном чекауте `git checkout -- .claude/memory/MEMORY.md` и удалить untracked копию
файла памяти перед `git pull` (копии тех же файлов закоммичены на ветке).

Умолчания: (1) библиотека `contracts/storage/CollateralChange.sol` без своего storage — как `Settlement`
называет процедуру; альтернативы `Collateral`, `Margin` отвергнуты (спорят с `PerpsCollateralConfiguration`
и со словом «margin» = оценка). (2) три глагола `validate` (view, ревертит по порядку, ничего не возвращает),
`make`, `payDebt`; дверь оставляет флаг `PERPS_SYSTEM`, `Account.exists`, право
`_PERPS_MODIFY_COLLATERAL_PERMISSION`; `validate` — крючок под будущую квоту, селектора не создаёт.
(3) переезжают правила без других вызывающих — с ошибками: `_depositMargin`/`_withdrawMargin`,
`validateMaxCollaterals`, `validateWithdrawableAmount`, `PerpsAccount.payDebt` (внешний `depositMarketUsd`),
`GlobalPerpsMarket.validateCollateralAmount`; остаются `getWithdrawableMargin(v)`, `create` (два вызывающих:
дверь и `settlePositionChange:898`), `updateCollateralAmount`, `updateAccountDebt`, `charge`, `seizeCollateral`,
`AccountLiquidatable` (три смысла — карточка 4; карточка 4 оставляет себе четыре вопроса — «вывод залога» уходит сюда). (4) порядок проверок как сегодня; проверка дистрибьютора
уходит в библиотеку после «кто стучится» — видно только при двух дефектах, одна строка таблицы пинит;
`InvalidDistributor` :55 недостижим на стендах (нужен LAM с нулевым дистрибьютором) — не пинится.
(5) ставка — правило одним текстом в библиотеке: `payDebt` зовёт `InterestRate.update(DEFAULT)` и издаёт
`InterestRateUpdated`, `make` — нет (snxUSD — wash точно, синт — с точностью до согласия цены ядра и спота); пин с мутацией — депозит НЕ издаёт `InterestRateUpdated` («ставка та же»
мутацию не поймала бы: депозит — wash). (6) события из библиотеки квалифицированным именем
(`IPerpsAccountModule.CollateralModified`/`DebtPaid`, `IGlobalPerpsMarketModule.InterestRateUpdated`), ABI
модуля не меняется. (7) наружу ничего нового: число даёт `getWithdrawableMargin`, причину — симуляция двери;
квота `quoteCollateralChange` отвергнута (нет потребителя). PR B = **monorepo#747** draft 08.09 (ветка `feat-cld/collateral-change-abi` от staging b54bd5da, worktree `.worktrees/orderbook-sdk`, коммит 99242fe9; 18 ошибок + 3 события в `perps-market-proxy.ts`, guard-тест пришпилен к селекторам скомпилированных артефактов, `collateral-flow.md` с id по контурам prod 3 / staging 1 и таблицей дверей; без бампа версии). Было: ошибки двери и события
`CollateralModified`/`DebtPaid` в `liq-onchain/src/abis/perps-market-proxy.ts` (сейчас 2 события, 0 ошибок — и на
staging), правило долга и таблица id в `docs/protocols/synthetix-v3/collateral-flow.md`. (8) пины: Hardhat
`Account/CollateralChange.door.test.ts` (таблица двери + двойной дефект, `payDebt`: `PendingOrderExists`,
`FeatureUnavailable`, правило ставки), Foundry `tests/CollateralChange.t.sol` (первые `expectRevert` на этой
поверхности; `payDebt` только `NonexistentDebt` — стенд без спота долг создать не может). (9) выкат — обычный
апгрейд роутера без lockstep (селекторы/события/ошибки те же, сабграф и deployments не трогаются,
`Account_Permissions.e2e.js:131-133` с сигнатурой руками живёт); газ батча по построению не меняется;
базовые числа зонда: депозит snxUSD 192 034, вывод 395 024, `payDebt` 303 701.

Факты (проверены 07.09): дверь `modifyCollateral` = 13 шагов (`PerpsAccountModule.sol:46-96`) через
PerpsCollateralConfiguration, GlobalPerpsMarket, LiquidationFlag, PerpsAccount, AsyncOrder + приватные ходы в
ядро (:346-390); `payDebt` (:127-144) в форке не менялся с апстримного ccc1439d; `InterestRate.update` зовут
`PerpsMarket.updatePositionData:273` (ONE_MONTH), `payDebt:139`, `updateInterestRate:270`. Библиотеки у
хранилища уже ходят в ядро трижды (`PerpsAccount.payDebt:313`, `Settlement.payFees:90-96`,
`seizeCollateral:722`); «отказ спеки ворот» из обзора на самом деле — вариант B спеки событий расчёта
(про знание библиотеки, не про вызовы). **Зонд ставки** (стенд Hardhat, params 0.0003/0.75/0.01, аккаунт 5
держит 20 ETH, аккаунт 4 с долгом 26 242 на snxETH-залоге): депозит/вывод snxUSD и депозит синта — Δ delegated
= 0 точно, событий нет; `payDebt` — Δ delegated = +долг точно, утилизация 0.039999 → 0.038976, хранимая ставка
1.1999e-3 → 0.877e-3, событие есть. Ядро: `depositMarketUsd` делает `creditCapacityD18 += amount`
(`MarketManagerModule.sol:270-271`); `delegated = withdrawableUsd − perps totalCollateralValue`
(`GlobalPerpsMarket.sol:145-153`). Вьюха `utilizationRate()` считает locked credit при ONE_MONTH
(`PerpsMarketFactoryModule.sol:174`), `update(DEFAULT)` — при DEFAULT: на стенде 2000 против 1500.
`PayDebt.test.ts:214` уже пинит «withdrawableUsd ядра растёт ровно на долг». Контуры MegaETH: оба омнибуса
включают `tomls/omnibus-base-sepolia-andromeda/perps/global.toml` — ставка 0.000025/0.80/0.01 живая; залоги
snxUSD (кап MaxUint256) и sUSDC (кап 100 M, дисконты 0). Офчейн (агент, monorepo main 0.28.2 / staging 0.47.1,
kwenta ^0.42.0): правило долга в SDK — только JSDoc (`collateral.ts:88-93`, `repay-builder.ts:37-38`,
`deposit.ts:91-94`); kwenta бьёт вывод `getWithdrawableMargin` через `collateral.margins()` — верно; `RepayBuilder.
thenWithdraw` + `useRepay` без вызывающих, kwenta не зовёт `payDebt`/`debt()`; `withdrawLocked`
(`DepositWithdrawCrossMargin.tsx:87`) не различает долг и IM-лок; шлюз читает только `getAvailableMargin`;
портфель читает `collateralModifieds` как нетто-депозиты. Тесты: `Account/` 12 файлов 97 it; 48 файлов зовут
`modifyCollateral` сами, 67/71 через фикстуру; не запинены `InvalidDistributor` :55, `create` :72, `payDebt`
`FeatureUnavailable`/`PendingOrderExists`/`InterestRateUpdated`; Foundry: `depositMargin` `Bootstrap.t.sol:453`,
сырой вывод `OrderMode.t.sol:85`, ноль `expectRevert` на поверхности, `payDebt` отсутствует. Сабграф: `CollateralModified`
индексируется (`subgraph.template.yaml:64-67`), `DebtPaid`/`AccountCharged`/`InterestRateUpdated` — нет.

**Why:** карточки закрываются через разбор → «го» → спека → план → PR; без записи умолчаний, зонда и офчейн-фактов
новая сессия переисследует ядро, стенды и SDK.
**How to apply:** после «го» — писать спеку по разбору (правило ставки — natspec из раздела 3 разбора); если
пользователь заменил умолчание — обновить этот файл; Foundry-близнец не пытается создать долг; стендовый зонд
повторяется тем же разовым тестом (`interestRateParams` + открытая позиция другого аккаунта + долг через
snxETH-залог, как `PayDebt.test.ts`).

Связано: [[architecture-review-2026-09-04]], [[architecture-review-card3-batch-culprit]],
[[architecture-review-card2-account-valuation]], [[foundry-stand-after-pnpm]], [[memory-in-repo]],
[[gh-repo-liqcx-synthetix-v3]]
