---
name: nightly-build-testable-ipfs
description: Ночной прогон упирался в build-testable (cannon не мог забрать trusted-multicall-forwarder). Своя IPFS-нода НЕ чинит — провайдеров CID ноль. Починка: собирать in-repo пакет в локальный реестр, версия 0.0.4-liqcx.1
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

## Починка (сделана)

Пакет есть в репозитории: `auxiliary/TrustedMulticallForwarder/cannonfile.toml`
(`trusted-multicall-forwarder`, версия 0.0.4, чистый Foundry, исключён из moon в
`.moon/workspace.yml:12` — нет package.json). Если собрать его в локальный реестр до
`build-testable`, provision резолвится локально и до IPFS дело не доходит.
Гвард `cannon-cli/src/commands/build.ts:157` (при пустом локальном реестре и наличии пакета
в ончейне — «already published … bump the `version`») снят бампом версии **0.0.4 → 0.0.4-liqcx.1**.
Версию никто не называет: oracle-manager провижнит по имени, governance берёт пресет
`@with-synthetix` из `cannonfile.clone.toml`.

**`--chain-id` передавать нельзя.** Cannon поднимает свой anvil только когда флага нет
(`cannon-cli/src/util/build.ts:127`); с флагом он идёт в frame / `127.0.0.1:8545` и виснет
в реконнекте. С внешним anvil по `--rpc-url` — `this.provider.snapshot is not a function`
(нужен именно cannon-овский узел).

Проверено на пустом `CANNON_DIRECTORY` (это и есть состояние раннера):
`cannon build cannonfile.toml` пишет `tags/trusted-multicall-forwarder_latest_13370-main.txt`
(build.ts:489 регистрирует и `<version>`, и `latest`), после чего
`moon run oracle-manager:build-testable` даёт `Resolving … via local` и читает блоб из
локального файлового кэша. Шаг добавлен в `nightly-contracts.yml` перед `moon run :build-testable`.

Грабли локально: `utils/common-config/hardhat.config.ts:35` жёстко прописывает
`http://localhost:8545`, и `ANVIL_PORT` понимает только perps-market — чужой anvil на 8545
ломает cannon-сборку любого другого пакета.

Отдельная история — пин версии в provision (cannon сам предупреждает про `latest@main`):
это чинит воспроизводимость, но не доступность — припиненный CID точно так же некому отдать.

Оба мока из PR #42 проверены **локально**, не в CI: `protocol/oracle-manager` — 54 теста,
0 падений (в том числе `ChainlinkNode`, идущий в `getContractFactory('AggregatorV3Mock')`);
`markets/spot-market` — 189 тестов, 0 падений (в том числе
`AsyncOrderModule pyth … handles revert properly`, дёргающий
`MockPythERC7412Wrapper.setAlwaysRevertFlag`). Через тот же `.github/scripts/run-suites.sh`.
