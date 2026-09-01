# ems-gap-filler

Worker que reconcilia telemetria do EMS (TimescaleDB) a partir dos CSVs dos medidores
físicos (Schneider EGX300 via FTP, Carlo Gavazzi via HTTPS) quando o caminho MQTT falha
ou grava dado anômalo. Detecta anomalias (KWH não-monotônico, fora de range, fora de
ordem, duplicata), substitui via soft-delete (`sdr_active=false`) + INSERT da leitura
correta — append-only — e dá refresh nos CAGs.

## Modos de operação

- **RECENT** (automático): loop de 15 em 15 min (`:05, :20, :35, :50`), janela últimas 24h — corrige gaps **e** valores que o backend do app gravou errado, re-varrendo a janela a cada ciclo (idempotente)
- **HISTORICAL** (manual): `POST /api/v1/backfill`, janela arbitrária até 2 anos; se a
  janela tem chunk(s) comprimido(s) (> 7 dias), roda dentro do `CompressionGuard`
  (pausa `policy_compression` → decompress → reconcilia → recompress → reabilita)

Ver [docs/ADR-001-architecture.md](docs/ADR-001-architecture.md) para detalhes.

## Stack

- Java 21 LTS + Spring Boot 3.4
- TimescaleDB (mesmo banco do EMS) via Spring JDBC
- Apache Commons Net (FTP), OpenCSV (parser)
- ShedLock (lock distribuído pro cron), Flyway (migrations em schema `ems`)
- Micrometer + Prometheus (`/actuator/prometheus`)
- Testes: JUnit 5 + AssertJ + Mockito (unit) + Testcontainers/TimescaleDB (integração)

## Estrutura

```
src/main/java/br/com/ledstar/ems/gapfiller/
├── GapFillerApplication.java
├── domain/         (records - SensorMeter, Gap, Anomaly, BackfillRequest, SensorReading, ValueTypeRule, DerivedSensorFormula)
├── application/    (services + interfaces - ReconciliationService, AnomalyDetector, *Repository, MeterDataSource, CompressionGuard)
├── infra/
│   ├── postgres/   (Jdbc*Repository, JdbcCompressionGuard)
│   ├── ftp/        (FtpEgx300DataSource, EgxCsvParser)
│   ├── http/       (HttpsCarloGavazziDataSource)
│   └── scheduler/  (GapFillerScheduler - @Profile("!test"))
├── api/            (BackfillController)
└── config/         (ShedLockConfig)
```

## Rodar / testar local

```bash
mvn spring-boot:run -Dspring-boot.run.profiles=dev   # precisa de Postgres+TimescaleDB local
mvn test                                              # testes unitarios (*Test.java)
mvn verify                                            # + testes de integracao (*IT.java, Testcontainers - precisa de Docker)
```

## Build container

```bash
docker build -t ems-gap-filler:0.2.0 .
```

## Endpoints

- `POST /api/v1/backfill` — submit HISTORICAL backfill (202 + UUID)
- `GET /api/v1/backfill/{id}` — status
- `GET /api/v1/report` — diagnóstico read-only: migrations aplicadas, `ems.ftp_source`, `ems.backfill_request` (status/inserted/skipped/erro), `ems.gap_log` (anomalias tratadas + agregados) e sanity da telemetria (`mqtt.sensordatarecord` / `ems.sensor` / FK). Tolerante a ambiente vazio. `scripts/ems-deploy.ps1` puxa esse endpoint após o run e empacota `report.json` + `RESUMO.txt` no zip de logs.
- `GET /actuator/health` — health (usado pelo healthcheck do container)
- `GET /actuator/prometheus` — métricas

## Deploy

O ambiente da LG só é alcançável via ponte Windows `150.150.251.133`. Dois caminhos:

1. **Permanente — container dedicado no servidor EMS** (`scripts/deploy-server.sh`): roda **no servidor
   `150.150.251.112`, por quem tem acesso ao docker** (root ou user no grupo `docker`). Sobe um container
   `ems-gap-filler` (não toca em nada existente) na **mesma rede docker do postgres do ambiente**
   (`EMS_DOCKER_NETWORK` no `.env` — o script lista as redes/containers pra ajudar a achar), builda a imagem,
   `docker compose up -d` (auto-restart + healthcheck, 1 CPU / 768 MB, bind 127.0.0.1). Default profile `hom`
   (`172.25.0.3`), cron OFF; profile `prd` (`172.25.0.7`) pede confirmação `PROD`. **Começar pela rede da HOM,
   validar, depois trocar `.env` (profile/DB/rede) pra PRD.** Build precisa de internet no servidor (imagens base
   + deps Maven); sem internet → buildar noutra máquina e `docker save`/`load`.

2. **Validação / temporário — JAR na ponte** (`scripts/ems-deploy.ps1`): roda **na ponte
   `150.150.251.133`**. Baixa o JAR do último build de `main` no CI, abre túnel SSH
   `127.0.0.1:15432 → <pg do ambiente>:5432` (via `cesar.silva`), roda o JAR como processo
   Java na ponte, espera o `/actuator/health`, faz smoke test (HOM) e puxa o `GET /api/v1/report`
   pra gerar `report.json` + `RESUMO.txt` no zip de logs (`~\Downloads\`). **Não é durável**
   (morre se a ponte/processo cair) — é pra validar o fluxo.

   ```powershell
   # na ponte 150.150.251.133:
   $t='glpat-...' ; $f='scripts%2Fems-deploy.ps1'
   iwr -Uri "https://gitlab.com/api/v4/projects/81970992/repository/files/$f/raw?ref=main" -Headers @{'PRIVATE-TOKEN'=$t} -OutFile ems-deploy.ps1
   powershell -ExecutionPolicy Bypass -File ems-deploy.ps1            # HOM, cron OFF, smoke test (1 backfill 1h)
   powershell -ExecutionPolicy Bypass -File ems-deploy.ps1 -DryRun   # HOM, ZERO reconcile: so boot+Flyway+API+report
   powershell -ExecutionPolicy Bypass -File ems-deploy.ps1 -Env prd  # PRD, cron OFF (pede confirmacao)
   powershell -ExecutionPolicy Bypass -File ems-deploy.ps1 -Env prd -Yes -EnableCron   # PRD, cron ON
   ```

   **Kill-switches (env vars → `GapFillerScheduler`, default ON):** `GAPFILLER_RECENT_ENABLED`
   (sweep RECENT horário; o script seta `false` por padrão, `-EnableCron` liga) e
   `GAPFILLER_HISTORICAL_ENABLED` (drain da fila de backfill; com `-DryRun` vira `false` **e** o
   smoke test é pulado → o worker não toca em telemetria nenhuma, só Flyway no schema `ems`).

> ⚠️ Antes de ligar o cron em PRD: o `EgxCsvParser` ainda não foi validado contra o `.csv` **cru**
> do FTP (só contra exports xlsx normalizados pelo Excel). Recomendado: `-DryRun` primeiro →
> deploy com cron OFF → 1 backfill manual numa janela pequena → conferir o resultado → só então cron ON.

## Scripts auxiliares (em `scripts/`)

Rodam na ponte Windows `150.150.251.133` — ver `EMS-WORKER-RESUME.txt` para o estado/contexto.
Recon dos medidores (`ems-recon.ps1`), introspecção do banco via túnel (`ems-db-tunnel.ps1`),
deploy (`ems-deploy.ps1`, `deploy-server.sh`). O `ems-deploy-homolog.ps1` está **deprecado**
(baixa o JAR antigo `v0.1.1`) — usar `ems-deploy.ps1`.

<!-- verificado em 2026-09-01 -->
