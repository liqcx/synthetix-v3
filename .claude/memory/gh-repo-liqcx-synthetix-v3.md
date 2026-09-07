---
name: gh-repo-liqcx-synthetix-v3
description: "В synthetix-v3 gh без --repo уходит в архивный Synthetixio/synthetix-v3 — всегда указывать --repo liqcx/synthetix-v3; gh pr edit падает на projectCards — базу PR менять через gh api"
metadata:
  type: project
---

В `~/Work/perps/synthetix-v3` origin записан через SSH-алиас `liqcx:liqcx/synthetix-v3.git`, который `gh` не распознаёт как GitHub-URL, поэтому `gh pr create` / `gh pr list` без флага резолвятся в remote `upstream` — `Synthetixio/synthetix-v3`, а он архивный: «Repository was archived so is read-only». Пуш при этом проходит в правильный репо.

`gh pr edit <n> --base main` в этом репо падает с «GraphQL: Projects (classic) is being deprecated … (repository.pullRequest.projectCards)» и базу не меняет. Работает REST: `gh api -X PATCH repos/liqcx/synthetix-v3/pulls/<n> -f base=main` (и `-F body=@file.md` для тела).

**Why:** 2026-09-03 первая попытка открыть PR #22 упала на архивный upstream; перенацеливание #23 на main упало на projectCards.
**How to apply:** любые `gh` в этом репо — с `--repo liqcx/synthetix-v3` (и `--head <branch>` для pr create).
