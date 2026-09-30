---
name: memory-in-repo
description: Auto-memory synthetix-v3 версионируется в .claude/memory репо; путь harness под ~/.claude/projects — симлинк, который на новой машине или новом слаге worktree надо ставить руками
metadata:
  type: project
---

С 2026-09-07 auto-memory этого проекта лежит в репо: `<checkout>/.claude/memory/` (PR liqcx/synthetix-v3#36,
ветка `feat-cld/claude-md-diet`, там же диета CLAUDE.md и три skills под `.claude/skills/`).
Путь, который читает harness, `~/.claude/projects/-Users-alex-Work-perps-synthetix-v3/memory`, — симлинк на этот
каталог; такой же симлинк стоит для слага worktree `…--claude-worktrees-feat-cld-margin-quote`. Оба ведут в
основной чекаут, копия на запись одна.

**Why:** память должна переживать клоны и быть общей для worktree и dev-agent; симлинк — состояние машины, в git
его нет.

**How to apply:** на новой машине или для нового слага worktree повторить
`ln -s /Users/alex/Work/perps/synthetix-v3/.claude/memory ~/.claude/projects/<slug>/memory`. Каждое сохранение
памяти оставляет `M .claude/memory/…` в основном чекауте — коммитить вместе с работой, иначе память не уедет в
origin. `.claude/memory/` исключён из prettier, `.claude/**` — из markdownlint и канонического gitleaks.
На agentbox (Linux, 2026-09-25) harness читает другой путь: `~/.clauth/profiles/gmail/runtime-<n>/projects/-home-alex-Work-perps-synthetix-v3/memory` — симлинк поставлен 25.09.2026 на `/home/alex/Work/perps/synthetix-v3/.claude/memory` (каталог был пустым, не симлинком).
См. [[gh-repo-liqcx-synthetix-v3]].
