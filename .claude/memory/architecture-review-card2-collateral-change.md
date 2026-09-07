---
name: architecture-review-card2-collateral-change
description: "Карточка 2 обзора 07.09 («Изменение залога — один модуль», Strong): разбор card2-collateral-change-20260907.html в ~/Documents, девять умолчаний (ждут «го»), зонд ставки число в число, поправка офчейн-предпосылки (SDK/kwenta), инвентарь пинов, план PR A/PR B"
metadata:
  type: project
---

Разбор карточки 2 обзора 07.09 (`architecture-review-20260907-0454.html`, main @ 37b51c6a) сделан 2026-09-07
по `main @ 9e21507f` (после #36): HTML `~/Documents/card2-collateral-change-20260907.html` — рядом с обзором,
локальный файл (не Artifact), проверен скриншотом (playwright + `python3 -m http.server` из scratchpad;
file:// заблокирован; скриншоты падают в `.playwright-mcp/` чекаута — удалять). **Статус: ждёт «го» на девять
умолчаний; спека, план, ветка и worktree не созданы.** После «го»: спека
`docs/superpowers/specs/2026-09-07-collateral-change-design.md` → план → **новый** worktree (старый
`.claude/worktrees/feat-cld+margin-quote` занят карточкой 1 = PR #37 draft, ветка `feat-cld/stand-vocabulary`) →
ветка `feat-cld/collateral-change` от `main` после слияния #37 (или stacked) → SDD.

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
квота `quoteCollateralChange` отвергнута (нет потребителя). PR B в monorepo (staging): ошибки двери и события
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
