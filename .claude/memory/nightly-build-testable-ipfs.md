---
name: nightly-build-testable-ipfs
description: Ночной прогон упирается в build-testable — cannon не может забрать trusted-multicall-forwarder; причина двойная: битый TLS у *.repo.usecannon.com и резолв неприпиненного тега через чейн. Своя IPFS-нода это НЕ чинит — провайдеров CID в публичной сети ноль
metadata:
  type: project
---

08.09, ручной прогон `nightly-contracts.yml` на main (`f54a7845`, ран 34208940073) —
**первый раз, когда ночной дошёл дальше `generate-testable`**: все прогоны 05–08.09 падали
именно там по долгу P3b ([[ci-red-deps-router]]). Теперь падает `moon run :build-testable`
на `oracle-manager`, шаг `provision.trusted_multicall_forwarder`:
`could not download cannon package data from "QmUmov9…": … ssl/tls alert handshake failure (SSL alert number 40)`.

## Две причины, сложенные вместе

1. **Дефолтный эндпоинт cannon мёртв для всех.** `getCannonRepoRegistryUrl()`
   (`cannon-builder/src/constants.ts:54`) отдаёт `https+ipfs://<region>.repo.usecannon.com`
   (регион по таймзоне; на раннере `us-east`). У `us-east.`, `us-west.` и `sg.` TLS-рукопожатие
   падает — **и с моего мака тоже** (`curl` → `sslv3 alert handshake failure`). Апекс
   `repo.usecannon.com` по TLS живой (те же IP Cloudflare), но `/ipfs/<cid>` отдаёт 404.
   Похоже на непокрытый универсальным сертификатом второй уровень `*.repo.usecannon.com`.
2. **Раннер резолвит тег через чейн.** `source = "trusted-multicall-forwarder"` без версии →
   мутабельный `latest@main`. У раннера `~/.local/share/cannon` пустой, локальный реестр молчит,
   отвечает ончейн-реестр — и даёт CID, чьи байты лежат только у usecannon.

## Почему локально проходит — НЕ из-за своей ноды

Локальный прогон резолвит **другой** CID и берёт его из файлового кэша:
`Downloading ipfs://QmfZVeQh4kHLUpjtqULP1ZFqga743eSNxywp1bfuZmjMoF via ~/.local/share/cannon/ipfs_cache`.
Работает устаревший локальный тег `tags/trusted-multicall-forwarder_latest_13370-main.txt` от
когда-то собранного локально пакета. Моя kubo-нода к делу не относится: нужного блока у неё нет
(`block/stat offline` → not found), и у демона 0 пиров.

## Вариант «поднять свою IPFS-ноду» не решает задачу

`https://delegated-ipfs.dev/routing/v1/providers/<cid>` отдаёт `{"Providers":[]}` для обоих CID —
и для нужного раннеру, и для того, что лежит у меня. Публичные шлюзы (ipfs.io, dweb.link, w3s.link,
pinata) отвечают 504/404. Пакеты cannon в публичный DHT не анонсируются, они живут только на
собственном repo-сервисе usecannon. Своя kubo на srvrhtz подключилась бы к той же сети, где
провайдеров ноль. Как зеркало она годится только для контента, который мы сами туда положим, —
а байтов нужного CID взять неоткуда.

Инфраструктурно место готово (это единственный плюс варианта): в
`infra/compose/githubrunner/docker-compose.yml` уже стоит `bazel-remote` ровно такой формы —
сервис в том же compose-app, резолвится по DNS-имени в общей сети, без ingress, с cpus/mem_limit.
Хост 16 ядер / 61 ГБ, текущий потолок 17 / 41.

## Что выглядит рабочим

Пакет есть в репозитории: `auxiliary/TrustedMulticallForwarder/cannonfile.toml`
(`trusted-multicall-forwarder`, версия 0.0.4, чистый Foundry, исключён из moon в
`.moon/workspace.yml:12` — нет package.json). Если собрать его в локальный реестр до
`build-testable`, provision резолвится локально и до IPFS дело не доходит.
Мешает гвард `cannon-cli/src/commands/build.ts:157`: при пустом локальном реестре и наличии
пакета в ончейне сборка отвергается («already published … bump the `version`»). На моей машине
гвард молчит, потому что локальный URL уже есть. Значит нужен либо бамп версии, либо обход гварда.
Проверено: `cannon build` без `--rpc-url` виснет в реконнекте — нужен свой anvil
(`--chain-id 13370`) и `--private-key`.

Отдельная история — пин версии в provision (cannon сам предупреждает про `latest@main`):
это чинит воспроизводимость, но не доступность — припиненный CID точно так же некому отдать.

Оба мока из PR #42 проверены **локально**, не в CI: `protocol/oracle-manager` — 54 теста,
0 падений (в том числе `ChainlinkNode`, идущий в `getContractFactory('AggregatorV3Mock')`);
`markets/spot-market` — 189 тестов, 0 падений (в том числе
`AsyncOrderModule pyth … handles revert properly`, дёргающий
`MockPythERC7412Wrapper.setAlwaysRevertFlag`). Через тот же `.github/scripts/run-suites.sh`.
