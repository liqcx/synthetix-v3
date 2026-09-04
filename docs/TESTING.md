# Запуск тестов Synthetix V3

## Пререквизиты

| Инструмент | Версия | Проверка |
|------------|--------|----------|
| Node.js | 24.14.0 (пин в `.prototools`) | `node --version` |
| pnpm | 11.1.2 (пин в `.prototools` и `packageManager` в package.json) | `pnpm --version` |
| Foundry (Anvil) | >= 1.5.0 | `anvil --version` |
| IPFS | любая | `curl -s http://127.0.0.1:5001/api/v0/version` |

`proto install` ставит Node и pnpm ровно тех версий, что закреплены в `.prototools`.

### Установка Foundry

```bash
curl -L https://foundry.paradigm.xyz | bash
foundryup
```

### Установка IPFS

Скачать [IPFS Desktop](https://docs.ipfs.tech/install/ipfs-desktop/) или:

```bash
# macOS
brew install ipfs
ipfs init
ipfs daemon
```

IPFS должен быть доступен на `http://127.0.0.1:5001`.

---

## Шаг 1: Установка зависимостей

```bash
cd synthetix-v3
pnpm install
```

pnpm 11.1.2 зашит в репозиторий через `.prototools` (proto) и `packageManager` в package.json.
Workspace-пакеты:

- `utils/**` — утилиты, общий конфиг
- `protocol/**` — core protocol (synthetix)
- `markets/**` — рынки (perps-market, spot-market)
- `auxiliary/**` — вспомогательные контракты

---

## Шаг 2: Настройка Cannon

Cannon — фреймворк для деплоя контрактов. Использует IPFS для хранения артефактов.

```bash
pnpm cannon setup
```

Проверить/отредактировать конфиг:

```bash
cat ~/.local/share/cannon/settings.json
```

Должно быть:

```json
{
  "ipfsUrl": "http://0.0.0.0:5001",
  "publishIpfsUrl": "http://0.0.0.0:5001",
  "writeIpfsUrl": "http://0.0.0.0:5001"
}
```

---

## Шаг 3: Миграция Cannon state dumps (если нужно)

При обновлении Foundry/Anvil с версии < 1.0 на >= 1.5 старые cannon-кеши становятся несовместимыми. Симптомы:

```text
Error: Failed to decode state dump
Error: Best hash not found
```

Скрипт `scripts/fix-cannon-state-dumps.py` мигрирует старый формат в новый:

```bash
python3 scripts/fix-cannon-state-dumps.py
```

Что делает:

1. Сканирует `~/.local/share/cannon/ipfs_cache/*.json`
2. Находит `chainDump` в старом формате (без поля `best_block_number`)
3. Добавляет недостающие поля: `best_block_number`, `blocks`, `transactions`, `historical_states`
4. Создает `.bak` резервную копию перед перезаписью

Запускать **один раз** после обновления Foundry. Если кеша нет или всё уже в новом формате — скрипт ничего не делает.

---

## Шаг 4: Генерация testable-контрактов

```bash
pnpm generate-testable
```

Генерирует объединённые контракты (router из модулей) в `contracts/generated/` для пакетов:

- `protocol/synthetix`
- `protocol/oracle-manager`
- `utils/core-modules`
- `auxiliary/PythERC7412Wrapper`

Это нужно **перед** `build-testable`. У `markets/perps-market` своего `generate-testable` нет, но его зависимости (synthetix, oracle-manager) его требуют.

---

## Шаг 5: Сборка проекта

```bash
# Сборка testable-артефактов (с моками для тестов)
pnpm build-testable
```

Собирает testable-версии из `cannonfile.test.toml` в топологическом порядке — с моками, тестовыми оракулами, FeeCollectorMock и т.д. Внутри каждого пакета `cannon:build` автоматически вызывает `hardhat compile`, поэтому отдельная компиляция не нужна.

Без этого шага тесты не найдут зависимости (например `synthetix:3.13.1-testable`) и упадут с ошибкой `could not find package`.

Порядок сборки определяется зависимостями между пакетами:

```text
utils/core-contracts (compile)
  → utils/core-modules (compile)
    → protocol/synthetix (cannon:build cannonfile.test.toml)
      → protocol/oracle-manager (cannon:build cannonfile.test.toml)
        → markets/spot-market (cannon:build cannonfile.test.toml)
          → markets/perps-market (cannon:build cannonfile.test.toml)
```

### Альтернативные команды

```bash
# Production сборка (cannonfile.toml, без моков) — для деплоя, не для тестов
pnpm build

# Только компиляция Solidity (без cannon)
pnpm build:contracts
```

---

## Шаг 6: Запуск тестов

### Все тесты во всех пакетах

```bash
pnpm test
```

Это выполняет `CANNON_REGISTRY_PRIORITY=local bun x hardhat test` в каждом workspace параллельно.

### Тесты конкретного пакета

```bash
cd markets/perps-market
pnpm test
```

### Конкретный тестовый файл

```bash
cd markets/perps-market
CANNON_REGISTRY_PRIORITY=local bun x hardhat test test/integration/Orders/OffchainAsyncOrder.commit.test.ts
```

### Тесты по каталогам (рекомендуется для perps-market)

```bash
cd markets/perps-market

# Конкретная папка
CANNON_REGISTRY_PRIORITY=local bun x hardhat test 'test/integration/Orders/*.test.ts'

# Несколько папок
CANNON_REGISTRY_PRIORITY=local bun x hardhat test \
  'test/integration/Orders/*.test.ts' \
  'test/integration/Market/*.test.ts'
```

> **Важно:** При запуске всех ~58 тестовых файлов perps-market одновременно
> Anvil деградирует по памяти после ~30 файлов (известный баг Foundry).
> Рекомендуется запускать тесты по каталогам.

### Foundry-тесты perps-market

Стенд Foundry (`markets/perps-market/tests/*.t.sol`) воспроизводит тот же testable-протокол, что и
Hardhat-стенд: `build-testable` генерирует из `cannonfile.test.toml` его clone-вариант
`cannonfile.test.foundry.toml` (скрипт `scripts/foundry-cannonfile.ts`) и пишет `script/Deploy.sol`
через `cannon:build --write-script`. Оба файла — результат сборки, в git их нет.

Сценарий поверх протокола — пул, обеспечение, рынки, фондирование трейдеров, аккаунты в книге —
описан один раз в `markets/perps-market/test/stand.json` (целые числа в человеческих единицах,
доли и комиссии в bps). Hardhat-адаптер (`test/bootstrap/`) импортирует его как модуль, Foundry
(`tests/Bootstrap.t.sol`) читает через `stdJson`; пять BOOK-тестов и оба Foundry-теста торгуют
рынок и аккаунты, которые он называет. Словарь книги — `bookOrder`, `settleBook`,
`openBookAccount`, `openBookPosition` — есть в обоих адаптерах под одними именами
(`test/helpers/book.ts` и `tests/Bootstrap.t.sol`).

```bash
cd markets/perps-market
pnpm build-testable            # Hardhat-пакет + ~1 мин на генерацию script/Deploy.sol
pnpm forge-test                # forge test
```

В CI стенд perps-market гоняется в ночном прогоне (`nightly-contracts.yml`) — ему нужен
`script/Deploy.sol`, который появляется только после `build-testable`. Запустить руками:
`gh workflow run nightly-contracts.yml --repo liqcx/synthetix-v3 -f suite=markets/perps-market`.
Стенды, которым Cannon не нужен (`treasury-market`, `Faucet`), проверяются на каждом PR в джобе
`contracts`. `RewardsDistributor` и `RewardsDistributorExternal` сейчас не гоняются нигде в CI:
их тесты импортируют `forge-std/src/mocks/`, а такого пути нет ни в одном тегированном релизе
forge-std (только в плавающем `#master`, который `deps:mismatched` как раз запрещает).

---

## Что происходит при `pnpm test`

### 1. Cannon Build

Hardhat запускает задачу `cannon:build` с файлом `cannonfile.test.toml`:

1. Поднимает локальный **Anvil** (EVM-ноду) на `127.0.0.1:8545`
2. Деплоит все контракты из cannonfile на Anvil
3. Создает маппинг адресов и ABI
4. Публикует артефакты в IPFS (при первом запуске)

При повторных запусках Cannon находит кешированный стейт в IPFS и пропускает деплой.

### 2. Bootstrap (`coreBootstrap`)

Файл: `utils/core-utils/src/utils/bootstrap/tests.ts`

```typescript
coreBootstrap({ cannonfile: 'cannonfile.test.toml' })
```

Выполняется в `before()` хуке Mocha:

1. Вызывает `hre.run('cannon:build')` — получает outputs с контрактами
2. Генерирует typechain-типы в `test/generated/typechain/`
3. Создает ethers.js provider и 10 signer-ов
4. Устанавливает балансы (10000 ETH каждому)
5. Настраивает `anvil_setBlockTimestampInterval = 1`

Возвращает:

- `getContract(name)` — получить ethers.Contract по имени
- `getSigners()` — массив signer-ов
- `getProvider()` — ethers.providers.JsonRpcProvider
- `createSnapshot()` — создать точку восстановления

### 3. Snapshot/Restore

Для изоляции тестов используется механизм EVM snapshot:

```text
Cannon build → чистый стейт
  │
  ├─ evm_snapshot (базовый)
  │
  ├─ Тестовый файл 1
  │   ├─ before() → evm_snapshot
  │   ├─ it('test A') — меняет стейт
  │   ├─ it('test B') — меняет стейт
  │   └─ before() → evm_revert → откат к чистому стейту
  │
  ├─ Тестовый файл 2
  │   └─ ... аналогично
  └─ ...
```

Каждый describe-блок стартует с одинакового состояния.

### 4. Bootstrap тестов perps-market

Файл: `markets/perps-market/test/bootstrap/bootstrap.ts`

```typescript
const { getProvider, getSigners, getContract, createSnapshot } = coreBootstrap<Proxies>(params);
const restoreSnapshot = createSnapshot();

export function bootstrap() {
  before(restoreSnapshot);
  // Загружает контракты: Core, USD, SpotMarket, PerpsMarket, OracleManager...
}

export function bootstrapMarkets(data) {
  // Настраивает рынки, трейдеров, оракулы, коллатералы
}
```

---

## Переменные окружения

| Переменная | Описание | Где используется |
|------------|----------|-----------------|
| `CANNON_REGISTRY_PRIORITY=local` | Искать cannon-пакеты сначала в локальном кеше | `pnpm test`, `pnpm build` |
| `REPORT_GAS=true` | Включить отчет по gas usage | `bun x hardhat test` |

---

## Структура тестов perps-market

```text
markets/perps-market/
├── cannonfile.test.toml          # Cannon-конфиг для тестов (с моками)
├── hardhat.config.ts             # Hardhat-конфиг (mocha timeout: 30s)
├── test/
│   ├── bootstrap/
│   │   ├── bootstrap.ts          # Главный bootstrap
│   │   ├── bootstrapPerpsMarkets.ts
│   │   └── bootstrapTraders.ts
│   └── integration/
│       ├── Account/              # Тесты аккаунтов
│       ├── Orders/               # Тесты ордеров
│       ├── Market/               # Тесты рынков
│       ├── Liquidation/          # Тесты ликвидаций
│       └── ...
├── tests/                        # Foundry-стенд: Bootstrap.t.sol + *.t.sol
└── generated/                    # Авто-генерация (typechain, deployments)
```

---

## Решение проблем

### IPFS не запущен

```text
Error: Failed to upload to IPFS. Make sure you have a local IPFS daemon running
Error: connect ECONNREFUSED 0.0.0.0:5001
```

**Решение:** Запустить IPFS daemon:

```bash
ipfs daemon
# или открыть IPFS Desktop
```

### Cannon не находит пакет

```text
Error: could not find package synthetix:3.13.1-testable
```

**Решение:** Сначала собрать зависимости:

```bash
# Из корня
pnpm build-testable
```

### Тесты зависают на `restoreSnapshot`

Проблема: Anvil деградирует при использовании раздутого cannon-кеша с накопленными историческими состояниями.

**Решение 1 (рекомендуется):** Удалить cannon-кеш и пересобрать:

```bash
rm -rf ~/.local/share/cannon/ipfs_cache/
pnpm build-testable
```

**Решение 2:** Запускать тесты по каталогам, а не все сразу:

```bash
CANNON_REGISTRY_PRIORITY=local bun x hardhat test 'test/integration/Orders/*.test.ts'
```

### `Failed to decode state dump` / `Best hash not found`

Cannon-кеш содержит state dumps в старом формате Anvil.

**Решение:**

```bash
python3 scripts/fix-cannon-state-dumps.py
```

### Hardhat не поддерживает текущую версию Node.js

```text
WARNING: You are currently using Node.js v24.14.0, which is not supported by Hardhat
Error HH502: Couldn't download compiler version list
```

**Решение:** Переключиться на Node.js 20.x:

```bash
nvm use 20
```

### Компиляция Solidity падает

```bash
# Очистить и пересобрать
pnpm clean
pnpm build
```

### Cannon build слишком долгий

Первый `cannon:build` занимает несколько минут (деплой всех контрактов). Последующие запуски используют кеш из IPFS и выполняются за секунды.

---

## Ключевые файлы

| Файл | Назначение |
|------|------------|
| `package.json` (корень) | Workspace-конфиг, глобальные скрипты |
| `utils/common-config/hardhat.config.ts` | Общий hardhat-конфиг для всех пакетов |
| `utils/core-utils/src/utils/bootstrap/tests.ts` | `coreBootstrap()` — настройка тестовой среды |
| `utils/core-utils/src/utils/mocha/snapshot.ts` | `snapshotCheckpoint()` — EVM snapshot/restore |
| `markets/perps-market/cannonfile.test.toml` | Cannon-конфиг для тестов perps-market |
| `markets/perps-market/hardhat.config.ts` | Hardhat-конфиг perps-market |
| `~/.local/share/cannon/settings.json` | Настройки Cannon (IPFS URL) |
