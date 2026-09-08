---
name: nightly-build-testable-ipfs
description: После закрытия P3b ночной прогон упирается в build-testable — раннер не может забрать пакет trusted-multicall-forwarder с IPFS (SSL alert 40); локально проходит из-за своей ноды на 0.0.0.0:5001
metadata:
  type: project
---

08.09, ручной прогон `nightly-contracts.yml` на main (`f54a7845`, ран 34208940073) —
**первый раз, когда ночной дошёл дальше `generate-testable`**: все прогоны 05–08.09 падали
именно там по долгу P3b ([[ci-red-deps-router]]). Теперь падает следующий шаг,
`moon run :build-testable`, на `oracle-manager`:

```
Executing [provision.trusted_multicall_forwarder]...
  Resolving trusted-multicall-forwarder:latest@main (Chain ID: 13370) via local, 0x8E5C…
Error: could not download cannon package data from "QmUmov9YJE4MVH52U8AwBVNCbk8C1VYazU8huCS1QetRp1":
  write EPROTO … ssl3_read_bytes:ssl/tls alert handshake failure … SSL alert number 40
```

Реестр (`CANNON_REGISTRY_PRIORITY=local`) хеш **находит**, падает уже загрузка блоба с IPFS.
К коду отношения не имеет: до этого места oracle-manager успел скомпилироваться, задеплоить
InitialProxy, OracleRouter и позвать `upgradeTo`.

Локально тот же `moon run oracle-manager:build-testable` проходит, потому что в
`~/.local/share/cannon/settings.json` стоит своя нода: `ipfsUrl: http://0.0.0.0:5001`.
У раннера такой настройки нет, и cannon уходит на публичный шлюз. Ручка —
переменная окружения **`CANNON_IPFS_URL`** (`cannon-cli/src/settings.ts:165`, дефолт — файловая
настройка `ipfsUrl`, на раннере пустая). Варианты: задать её в `nightly-contracts.yml`,
поднять IPFS-ноду на проде рядом с раннерами, либо запинить `source` у provision
(cannon сам предупреждает: `trusted-multicall-forwarder` взят без версии, `latest@main`).

Оба мока из PR #42 проверены **локально**, не в CI:
`protocol/oracle-manager` — 54 теста, 0 падений (в том числе `ChainlinkNode`, который и ходит
в `getContractFactory('AggregatorV3Mock')`); `markets/spot-market` — 189 тестов, 0 падений
(в том числе `AsyncOrderModule pyth … handles revert properly`, который дёргает
`MockPythERC7412Wrapper.setAlwaysRevertFlag`). Прогон через тот же
`.github/scripts/run-suites.sh` с `SUITE_FILTER`.
