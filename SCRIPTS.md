# Scripts в корневом package.json

Сборка и тесты — это таски **moon** (`moon run <project>:<task>` — один проект,
`moon run :<task>` — во всех, где таск объявлен). Скрипты ниже — тонкие шимы над ними в корневом
`package.json`, и держат старые «двоеточные» имена ради привычки (`build:contracts`,
`storage:dump`). Внутри самого moon это не так: **id таска не может содержать двоеточие**, поэтому
`storage:dump` — это `storage-dump`, `subgraph:codegen` — `subgraph-codegen`, и так далее по всей
таблице ниже.

## Сборка

| Script              | Описание                                                                    |
| ------------------- | --------------------------------------------------------------------------- |
| `clean`             | Очистка всех workspace'ов параллельно                                       |
| `build`             | Полная сборка всех пакетов в топологическом порядке (с учётом зависимостей) |
| `build:ts`          | Сборка только TypeScript                                                    |
| `build:contracts`   | Сборка только контрактов                                                    |
| `compile-contracts` | Компиляция контрактов через Cannon                                          |
| `generate-testable` | Генерация тестируемых артефактов                                            |
| `build-testable`    | Сборка тестируемых артефактов                                               |

## Тесты и проверки

| Script           | Описание                                       |
| ---------------- | ---------------------------------------------- |
| `test`           | Запуск тестов во всех workspace'ах параллельно |
| `coverage`       | Покрытие тестами                               |
| `size-contracts` | Размеры контрактов                             |
| `storage:dump`   | Дамп storage layout                            |
| `storage:verify` | Верификация storage layout                     |
| `check:storage`  | Проверка storage в топологическом порядке      |

## Линтинг

| Script                      | Описание                                   |
| --------------------------- | ------------------------------------------ |
| `lint`                      | Все проверки (prettier + eslint + solhint) |
| `lint:fix`                  | Автоисправление всего                      |
| `lint:js` / `lint:js:fix`   | ESLint для JS/TS                           |
| `lint:sol` / `lint:sol:fix` | Solhint для Solidity                       |
| `pretty` / `pretty:fix`     | Prettier для всех файлов                   |
| `lint:progress`             | ESLint с прогресс-баром                    |
| `check-staged`              | lint-staged для pre-commit хука            |

## Публикация

`publish:release`, `publish:dev` и `version:dev` (обёртки над Lerna) удалены вместе с Lerna —
пакеты несут апстримовый scope `@synthetixio`, публиковать в npm с этим форком некуда. Версии
теперь бампаются вручную одним коммитом; Cannon-публикация идёт через moon (см. корневой
`README.md`).

| Script              | Описание                                |
| ------------------- | --------------------------------------- |
| `publish-contracts` | Публикация контрактов в Cannon registry |

## Субграфы

| Script             | Описание                         |
| ------------------ | -------------------------------- |
| `subgraph:codegen` | Кодогенерация для всех субграфов |
| `subgraph:build`   | Сборка всех субграфов            |

## Зависимости

| Script            | Описание                           |
| ----------------- | ---------------------------------- |
| `deps`            | Проверка зависимостей              |
| `deps:fix`        | Автоисправление зависимостей       |
| `deps:mismatched` | Поиск несовпадающих версий         |
| `deps:circular`   | Поиск циклических зависимостей     |
| `audit`           | Аудит безопасности (severity high) |

## Cannon

Cannon приезжает форком [`alxwlw/cannon`](https://github.com/alxwlw/cannon) — пакеты
`@alxwlw/cannon-builder` и `@alxwlw/cannon-cli`, поставленные `npm:`-алиасом под апстримовыми
именами `@usecannon/*` (см. `overrides` в `pnpm-workspace.yaml`). Обычный `pnpm up @usecannon/...`
алиас сносит и молча возвращает сток — обновлять только скриптом ниже.

| Script          | Описание                                                                    |
| --------------- | --------------------------------------------------------------------------- |
| `cannon:update` | Обновление Cannon-форка; тег берётся из `CANNON_TAG` (`nonce` по умолчанию) |

## Утилиты

| Script             | Описание                                                                                         |
| ------------------ | ------------------------------------------------------------------------------------------------ |
| `docgen:contracts` | Генерация документации контрактов                                                                |
| `copy-storage`     | Копирование `storage.new.dump.json` → `storage.dump.json` (pre-commit)                           |
| `changed`          | Список затронутых проектов — теперь запросом к moon (`moon query projects --affected`), не Lerna |
