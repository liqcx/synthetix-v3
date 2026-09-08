---
name: nightly-suites-first-red
description: Ран 34219846229 (08.09) — первый ночной, дошедший до самих сюит; 6 из 7 красные. Две независимые причины: жёсткий --timeout 10000 в test-batch.js (перебивает 30–120 с из hardhat.config пакетов) и слом utils/core-utils на Node 24 (JSON-импорт без import attributes)
metadata:
  type: project
---

Ран `34219846229` (08.09, ветка `feat-cld/nightly-tmf-local`, `6f7098f8`, job `102040121679`) —
первый ночной, у которого `build-testable` **зелёный** (20 мин) после стены mintable-token
([[nightly-build-testable-ipfs]]). Шаг «Hardhat integration suites» упал за 47 мин,
«Foundry stand» — skipped.

| сюита | итог | время |
| --- | --- | --- |
| protocol/synthetix | ❌ | 1005 с |
| protocol/oracle-manager | ❌ | 802 с |
| markets/spot-market | ❌ | 255 с |
| markets/perps-market | ❌ | 203 с |
| utils/core-modules | ❌ | 538 с |
| utils/core-contracts | ✅ | 11 с |
| utils/core-utils | ❌ | 3 с |

## Причина 1 — `--timeout 10000` зашит в раннер

`.github/scripts/test-batch.js:28` вызывает mocha напрямую, поэтому `mocha.timeout` из
`hardhat.config.ts` пакетов **не применяется**: protocol/synthetix, utils/core-modules,
utils/core-contracts просят 120 000, spot-market и perps-market — 30 000, а CI даёт 10 000.
Значение унаследовано дословно из `.circleci/test-batch.js` (коммит `5adc5aa3`), где оно
работало: CircleCI держал **по контейнеру на сюиту** и `parallelism` 1–8 (perps-market — 8),
плюс node **20.17.0**. GHA-порт гоняет все семь сюит подряд в одном job на self-hosted
раннере 2 CPU / 4 ГБ, разделяемом всей орг.

Симптом: падают почти исключительно `"before all"`-хуки с одной write-транзакцией
(`create the account`, `transfer the account`, `setup oracle manager node`) —
25 таймаутов в protocol/synthetix, 24 в oracle-manager, 10 в spot-market, 5 в core-modules.
Хук `prepareNode` из `core-utils/src/utils/bootstrap/tests.ts:23` ставит себе
`this.timeout(900000)` — поэтому сборки cannon проходят, а тесты нет.

**Вторичный шум, не отдельный дефект**: mocha `--retries 2` переигрывает тест, чья
транзакция уже легла на цепочку → `TokenAlreadyMinted("99")` (perps-market CreateAccount,
`DEBTOR = 42`, т.е. не наследство от batch 1), `TokenAlreadyMinted("1")` /
`AlreadyInitialized()` (core-modules NftModule/DecayTokenModule), уехавший decay
(`99e18` vs `97.02e18` = лишний шаг времени). Внешний цикл `BATCH_RETRIES=5` умножает это
на пять и сжигает по ~17 мин на сюиту.

Хеши деплоя cannon сцеплены между батчами внутри сюиты (perps-market: batch1
`QmT61SZ7…` → `QmQKgk54…`, batch2 `QmQKgk54…` → `QmUeJ6L4…`) — пакет пересохраняется
после каждого процесса. Оркестрового anvil на 8545 при этом никто не наследует:
`Address already in use` в логе нет ни разу, 43 старта anvil прошли чисто.

**Контрдовод в пользу «дело в раннере, а не в коде»**: oracle-manager (54 теста) и
spot-market (189 тестов) проходили **локально через тот же `run-suites.sh`** с тем же
10-секундным таймаутом (проверка моков PR #42, см. [[nightly-build-testable-ipfs]]).

## Причина 2 — utils/core-utils ломается на загрузке под Node 24

`Exception during run: TypeError: Module ".../test/fixtures/dummy-abi.json" needs an import
attribute of "type: json"` — 3 секунды, пять попыток подряд, ни один тест не запущен.
Источник один: `test/utils/ethers/contracts.test.ts:4`
`import dummyABI from '../../fixtures/dummy-abi.json'`. Node 24 перечитывает `.ts` как ESM
(`MODULE_TYPELESS_PACKAGE_JSON`), а ESM требует `with { type: 'json' }`; под CircleCI-шным
node 20 + `ts-node/register` файл компилировался в CJS и `require` json проходил.

Батчинг тут не спасает: `utils/core-utils/.mocharc.json` задаёт
`"spec": ["test/**/*.test.ts"]`, mocha **объединяет** spec из конфига с позиционными
аргументами, поэтому любой батч грузит все файлы сюиты, включая сломанный.

Воспроизводится локально за секунды:
`node …/mocha.js --require ts-node/register --exit test/utils/assertions/assert-bignumber.test.ts`
→ `ERR_IMPORT_ATTRIBUTE_MISSING`.

## Куда чинить

1. `test-batch.js` — вынести таймаут в `MOCHA_TIMEOUT` (дефолт 120 000), перестать
   перебивать бюджеты пакетов.
2. `utils/core-utils/test/utils/ethers/contracts.test.ts` — импорт JSON с атрибутом
   (или `fs.readFileSync`).
3. После зелёного — снизить `BATCH_RETRIES`, сейчас 5 попыток на заведомо красной сюите
   растягивают шаг до 47 мин.
