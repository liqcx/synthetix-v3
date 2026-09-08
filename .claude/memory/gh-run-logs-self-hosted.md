---
name: gh-run-logs-self-hosted
description: Логи джобов CI liqcx/synthetix-v3 читаются через gh api .../actions/jobs/<id>/logs — gh run view --log[-failed] отдал пустоту
metadata:
  type: reference
---

Наблюдение 08.09 (gh 2.65.0, ран 34192473749): `gh run view <run> --job <id> --log`
и `--log-failed` вернули **пустой вывод с кодом 0** — не ошибку, просто ничего.
Причина не выяснена (раннеры self-hosted, но это догадка). Рабочий способ:

```
gh api repos/liqcx/synthetix-v3/actions/jobs/<jobId>/logs > job.log
```

`<jobId>` берётся из `gh run view <runId> --repo liqcx/synthetix-v3 --json jobs`
(поле `jobs[].databaseId`). Плюс: хук rtk перехватывает `gh run view --job …` и
отвечает «rtk: Run ID required» — для таких вызовов нужен `rtk proxy gh …`.

Репозиторий требует `--repo liqcx/synthetix-v3` у всех вызовов gh: [[gh-repo-liqcx-synthetix-v3]].
Что именно гоняет CI и какие джобы известно красные: [[ci-red-deps-router]].
