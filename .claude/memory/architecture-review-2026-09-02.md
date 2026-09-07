---
name: architecture-review-2026-09-02
description: Статус карточек обзора архитектуры 2026-09-02 (артефакт architecture-review-20260902-1211.html) и что по ним сделано
metadata:
  node_type: memory
  type: project
  originSessionId: d1ebb27a-36ae-4029-8c05-712127980794
  modified: 2026-09-03T17:56:24.700Z
---

Обзор архитектуры synthetix-v3/perps-market от 2026-09-02 (HTML-артефакт `architecture-review-20260902-1211.html` в /var/folders/.../T/). Статус после переоценки:

- Закрыты: 1, 2, 7, 9 (PR #19 слит).
- Открыты и повышены: 5, 6; новая 10.
- 2026-09-03: CRIT-1 исследован (артефакт), вариант A → PR #20; карточка 11 «свёртка по первой цене» (Critical) → synthetix-v3#21 + monorepo#741 (ADR-0061); #20 и #21 слиты в main днём 2026-09-03, #741 draft.
- 2026-09-03 (вечер): карточка 5 «один стенд протокола, два адаптера» разобрана (артефакт «Один стенд, два адаптера»), пользователь выбрал C1 (`test/stand.json` для TS и Solidity). PR 1 — synthetix-v3#22 слит в main 2026-09-03 (`feat-cld/foundry-stand-regenerated`: Deploy.sol генерируется в build-testable, clone `snx-perps-foundry`, интерфейсы наследованием, стенд с хелперами); PR 2 — synthetix-v3#23, слит в main 2026-09-03 (f062d9ef) (`feat-cld/book-stand-shared`; перенацелен с ветки #22 через REST `gh api -X PATCH …/pulls/23 -f base=main`, потому что `gh pr edit` падает на deprecated projectCards: `test/stand.json`, `test/bootstrap/stand.ts`, `test/helpers/book.ts`, `bookAccountIds`, Foundry читает JSON через stdJson). Проверено локально: forge 8/8, Hardhat Orders/* 222, Account/*+Position/* 146. Спека `docs/superpowers/specs/2026-09-03-one-stand-two-adapters-design.md`, планы `docs/superpowers/plans/2026-09-03-foundry-stand-regenerated.md` и `2026-09-03-book-stand-shared.md`.

**Why:** карточки закрываются по одной, каждая через артефакт-разбор → выбор варианта пользователем → PR; статус нужен, чтобы не переисследовать.
**How to apply:** перед работой над следующей карточкой сверить этот список; после слияния PR обновить строку карточки (карточка 5 закрыта: #22 и #23 слиты).

Связано: [[foundry-stand-after-pnpm]]
