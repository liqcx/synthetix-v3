---
name: pnpm-catalogs-migration
description: "Версии третьих сторон уехали в pnpm-каталоги (PR #45, draft 09.09); cannon:update пришлось переписать"
metadata: 
  node_type: memory
  type: project
  originSessionId: 0971fa20-3fa1-4600-b953-9a2b78129637
  modified: 2026-09-09T09:47:18.128Z
---

Ветка `feat-cld/pnpm-catalogs`, PR liqcx/synthetix-v3#45 — **draft, не слит** на 2026-09-09.
Три коммита: `32533a9f` (миграция), `ad957b8b` (переписан `cannon:update`), `c72bd9b4` (счёт
пакетов в шапке). Референс — `yulii/ops-platform/pnpm-workspace.yaml`.

203 специфайера в 31 манифесте стали `catalog:<name>`; девять именованных каталогов
(`build`, `lint`, `testing`, `hardhat`, `cannon`, `eth`, `solidity`, `subgraph`, `utils`),
дефолтного `catalog:` нет. Сама конвенция теперь записана в `CLAUDE.md` репозитория — здесь
только то, чего в тексте репо нет.

**Why:** после этого «поднять версию» = правка одной строки в `pnpm-workspace.yaml`, а не
grep по 33 манифестам; расхождений версий между пакетами больше не бывает по построению.

**How to apply:**

- Инвентарь брать по **33 импортёрам**, а не по `find -maxdepth 3`: три манифеста
  (`markets/{perps,spot}-market/subgraph`, `protocol/synthetix/subgraph`) лежат глубже и
  попадают в воркспейс через глобы `markets/**` / `protocol/**`. Первый проход их потерял.
- `pnpm list -r --json` в этой сессии отдавал `All packages up-to-date` вместо JSON (rtk-хук);
  авторитетный список проще собрать из `pnpm-lock.yaml` (секция `importers:`).
- Проверка «дрейфа разрешения нет» — посекционное сравнение лока с базой: `packages:`,
  `snapshots:`, `overrides:`, `patchedDependencies:`, `settings:` обязаны быть побайтно
  равны, а `importers:` — отличаться только строками `specifier:`. `git diff --stat` на это
  не отвечает: он показал 588 изменённых строк там, где содержательных изменений ноль.
- После любого `pnpm install` гнать `pnpm dedupe` до коммита лока — иначе `pnpm dedupe --check`
  (первый шаг джобы `lint`) падает на ключе axios-retry. См. [[bun-test-migration]] и 40a127cd.

Открытый хвост: dependabot (`.github/dependabot.yml`) теперь должен править
`pnpm-workspace.yaml`, а не манифесты — поддержка каталогов не проверена, смотреть на первом
его PR после слияния.
