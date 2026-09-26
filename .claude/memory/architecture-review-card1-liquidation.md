---
name: architecture-review-card1-liquidation
description: "Карточка 1 обзора 25.09 («Вопрос „сколько получит кипер“ — один модуль ликвидации», Strong): grilling 25.09, двенадцать умолчаний («все ок»), находка advisor про guard капа, спека 2026-09-25-liquidation-module-design.md, ветка feat-cld/liquidation-module в worktree, статус прогона"
metadata:
  type: project
---

Разбор карточки 1 обзора 25.09 сделан 2026-09-25 на agentbox через `grilling` (один раунд, 12 вопросов;
пользователь: «все ок» — все рекомендованные ответы приняты). Спека:
`docs/superpowers/specs/2026-09-25-liquidation-module-design.md`; глоссарий `CONTEXT.md` (новый, корень репо,
английский, только термины). Ветка `feat-cld/liquidation-module` от `origin/main @ c59d8204` в worktree
`<checkout>/.claude/worktrees/feat-cld+liquidation-module` (upstream снят намеренно; push только
`git push -u origin feat-cld/liquidation-module` при открытии PR). **Статус 26.09: прогон SDD завершён, draft PR liqcx/synthetix-v3#55 (`refactor(perps-market): Liquidation — the liquidation of an account is one module`, база `main`); ветка 18 коммитов от c59d8204 (спека+CONTEXT 664b1f4d, план 5fac468b + 7 правок, Task 1 6b25db2f, Task 2 d66711e2, Task 3 d71d3780 + фикс 6377af6e, Task 4 8c0283b3, волна правок f5ea5764 + 26b824b1, память). Финальное ревью ветки (opus): «готово к слиянию с правками» — волна правок: три глагола ликвидации сначала оценивают аккаунт (STRICT), потом читают стоимости, как база (при устаревших и цене, и узле — отказ по цене); +4 пина (три на этот порядок, один на вторую грань кромки: нулевая награда и нулевые стоимости → requirement 0), forge 63/63; спека получила абзац «As run», тело PR переписано (две грани кромки, что с ними движется, честный абзац про газ с подгонкой −1,05k·n + 35·n², Markets/GlobalPerpsMarket 14/2). Слияние — решение владельца; после слияния — строка статуса в обзоре 25.09 и чистка копий памяти в основном чекауте (`git checkout -- .claude/memory/MEMORY.md .claude/memory/memory-in-repo.md`, удалить untracked копии) перед `git pull`.** Итог: ABI обоих модулей и раскладка storage без изменений (дамп: +библиотека `Liquidation`, тип окна `LiquidationWindow`); forge 63/63 (12 пинов в `LiquidationReward.t.sol`); Hardhat 70 файлов 619/94 — все 94 красных совпадают с базой по именам (база красная на Linux, nightly 36112820296; колеблются `KeeperRewards.Caps`, `Liquidation.marginOnly.feeds`, `Account/PayDebt`, `Market/MarketDebt`). Газ: `liquidate` −31,6k (−5,7 %), `liquidateMarginOnly` −32,5k, батч с повторными аккаунтами (two sellers) −942k (−4,9 %); батч из новых открытий в пределах долей процента (100 матчей +249k = +0,26 % — память кадра батча, вызовов не добавилось; принято по прецеденту карточки 2 от 03.09). Ревью Task 3 отменило моё решение о жадном чтении стоимостей в `assess`: пустой аккаунт на базе отвечал без узла стоимостей, жадное чтение добавляло отказ при упавшем узле (RedStone-фид MegaETH ревертит при >10 с) — теперь чтение ленивое в базовом порядке, два пина с `vm.mockCallRevert` (новый класс дефектов DP-217). Грабли прогона: solhint из каталога пакета не видит `.solhint.json` и пропускает всё — только из корня; `script/Deploy.sol` содержит байткод модулей — мутационные зонды требуют `pnpm build-testable:foundry` после каждой правки; Forge пишет `[FAIL: reason] name()` — grep `^\[FAIL\]` пуст; `test/integration/Markets/GlobalPerpsMarket.test.ts` (Markets во множественном числе) вне всех глобов гарда; pre-commit hook на agentbox не установлен; opus-исполнитель ставит трейлер своей модели — два коммита (d71d3780, 6377af6e) я нормализовал под строку своей сессии, финальное ревью решение отменило (правила пользователя о трейлере нет): дальше исполнители оставляют свою строку, история не переписана. Оставлено (в теле PR названо): ветка `liquidate` для пустого eligible-аккаунта без пина (логика базовая; Foundry-стенд с одним snxUSD такой аккаунт не строит); Foundry-пины perps-market гоняет только nightly (ci.yml — forge только treasury-market) — кандидат в карточку.

Умолчания (Q1–Q12): (1) одна библиотека `contracts/storage/Liquidation.sol` без своего слота — форма
`Settlement`/`CollateralChange`/`LiquidationFlag`; `LiquidationModule` остаётся дверью кипера из 8 однострочников.
(2) имя `Liquidation`; тип окна `storage/Liquidation.sol` → `storage/LiquidationWindow.sol`
(`storage:verify` сравнивает у одноимённых полей только slot/offset/size — `verify-mutations.ts:67-85`; удаление
библиотеки — `log`). (3) переезжают 11 функций `PerpsAccount` + `getAccountRequiredMargins` как
`Liquidation.requirement(v)` → (IM, MM, payout) — один проход по позициям сохраняется (спека 04.09, решение 7);
остаются `valuation`, `getAvailableMargin`, `seizeCollateral`, `getNumberOfUpdatedFeedsRequired`,
`applyPositionChange`, `hasOpenPositions`. (4) кап одним текстом `payout(rewards, costs, capBase)`; requirement =
`payout(flagReward(ctx, coll, 0), flag + liq, coll) + (windows − 1) × payout(0, liq, 0)`; новый Foundry-пин на два
окна. (5) `Costs {flag, liquidate}` один раз за вход → 4 оракульных вызова → 2 в `liquidate`/`liquidateMarginOnly`
и в `assess` (там тоже было 4 на каждый ордер батча!); `LiquidationFlag.flag(id)` возвращает только изъятое;
Foundry-пин `vm.expectCall(oracle, processWithRuntime-selector, 2)`. (6) кипер явным параметром; модуль читает
`_msgSender()` один раз; `maxLiquidatableAmount(market, requested, keeper)` перестаёт читать sender. (7) `LiquidationFlag`
остаётся отдельной библиотекой (читатели `assess`, `CollateralChange`); `Liquidation` поднимает и опускает флаг.
(8) окна и ёмкость (`maxLiquidatableAmount`, `_updateLiquidationData`, `currentLiquidationCapacity`) переезжают в
`Liquidation`, поле `liquidationData` остаётся в `PerpsMarket.Data`. (9) пять глаголов + четыре чтения; толерантность
внутри библиотеки (действие STRICT, `can*` DEFAULT); события `ILiquidationModule.*` из библиотеки. (10) ABI/слоты/числа
не меняются, кроме одной кромки (ниже); едет следующим апгрейдом роутера без lockstep. (11) guard: Hardhat
`Liquidation/` 12 (пофайлово), `KeeperRewards/` 5, `Account/`, `Position/`, `Orders/` (пофайлово), `Market/`; Foundry
`LiquidationReward.t.sol` + три новых пина (два окна; кромка; число оракульных вызовов); таблица газа: `liquidate`,
батч 2/20/50/200 (ожидается падение — в `assess` два вызова оракула вместо четырёх). (12) без design-it-twice; `CONTEXT.md`
заведён.

**Находка advisor (25.09), принята как умолчание A:** у выплаты есть guard `rewards + cost == 0 → 0`
(`LiquidationModule:287`), у ожидания нет (`PerpsAccount:597-612`): при `liquidateCost == 0` и `minKeeperRewardUsd > 0`
аккаунт держит `(windows − 1) × min(minReward, maxReward)` за окна, за которые киперу не платят. Канон — платёжная
семантика: requirement следует за payout; единственное видимое изменение числа, на стендах не запинено (все
`KeeperRewards.*` держат `liquidateCost` 5555, `Liquidation.reward` — 15, описание стенда — нули и в стоимостях, и
в guard-ах), на контурах недостижимо (cost node ценит газ). Новый Foundry-пин кромки красный на базе.

Факты среды agentbox (25.09): `node_modules` в основном чекауте не было — `pnpm install --frozen-lockfile` в worktree;
`ipfs` не установлен, `~/.local/share/cannon` нет — локальный реестр Cannon пуст; рецепт свежей машины — nightly:
`moon run :build-ts` → `:generate-testable` → регистрация trusted-multicall-forwarder и mintable-token в локальном
реестре → `moon run :build-testable` (последовательно, anvil 8545) → сюиты. Тулчейн через mise (proto/moon/pnpm/bun/forge/anvil есть).

**Why:** карточки закрываются через разбор → «го» → спека → план → PR; без записи умолчаний и находки guard-а новая
сессия переисследует пять файлов ликвидации.
**How to apply:** план — `docs/superpowers/plans/2026-09-25-liquidation-module.md` в формате плана CollateralChange
(Task 0 базовая линия + среда, тесты-пины красные на базе, библиотека, документы + PR); состояние прогона —
`plan-state` в worktree. Если пользователь заменит умолчание — обновить этот файл и спеку. После слияния — строка
статуса в [[architecture-review-2026-09-25]].

Связано: [[architecture-review-2026-09-25]], [[architecture-review-card2-account-valuation]],
[[architecture-review-card2-collateral-change]], [[foundry-stand-after-pnpm]], [[memory-in-repo]],
[[gh-repo-liqcx-synthetix-v3]]
