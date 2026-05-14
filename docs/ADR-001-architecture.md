# ADR-001: Arquitetura do EMS Gap Filler

| Campo  | Valor |
|--------|-------|
| Status | **Aceito** (implementação em curso) |
| Data   | 2026-05-08 |
| Última revisão | 2026-05-11 (incorpora recon de medidores 08/05 + suíte de testes + CI) |
| Cliente | Conec LG (Manaus) |
| Repo    | gitlab.com/ems5833927/ems-gap-filler (id 81970992) — transfer mater12123 → ems5833927 **concluído** |

## 1. Contexto

O sistema EMS recebe telemetria de 81 medidores ativos via MQTT e armazena em
TimescaleDB (`mqtt.sensordatarecord`). Em produção observamos **gaps reais de até
9 horas** em sensores 10120-10123, comprovados via query de detecção. O dashboard
EMS consome `mqtt.last_sensor_value` + CAGs hierárquicos (`sdr_hourly`, `sdr_daily`,
`sdr_monthly`) e fica com séries temporais incompletas.

Cada medidor físico **(EGX300 Schneider e Carlo Gavazzi)** mantém histórico local
acessível via FTP ou HTTPS, podendo cobrir os gaps quando o caminho MQTT falha.

### Volume e dimensões de produção

| Métrica | Valor |
|---|---|
| Leituras/dia | 4-5 milhões |
| Sensores ativos | 81 |
| Hypertable | 463 chunks, 455 comprimidos (98%) |
| Compressão automática | após 7 dias |
| CAG hourly | refresh 15min, start_offset 3 dias, end_offset 10min |
| CAG daily / monthly | hierárquicos (cascata) |
| TimescaleDB | 2.21.0 |
| PostgreSQL | 17.5 |
| Banco timezone | America/Manaus |

## 1.bis Causa-raiz revisada (2026-05-08)

Conversa com stakeholder Cesar Augusto + análise do dashboard revelou que **o
problema real NÃO é gap de leitura, é dado anômalo na fonte que se propaga**.

Caso confirmado em prod (07/05/2026, sensor BM):

```
CSV linha 83:  07/05/2026 23:37  →  7.728.922.624 kWh  (timestamp fora de ordem
                                                         entre 05:20 e 05:30)

Banco mqtt.sensordatarecord:  esse mesmo valor 7,728,922.624 KWH ficou propagado
                              entre 18:00 e 21:00 do dia anterior

CAG sdr_hourly (last(value, time)):  pegou o valor errado como ultimo do bucket
                                     gerou kwh delta = -6,437 (impossivel)
                                     depois 0, depois +8,699 (recuperacao)

Dashboard:  desenhou um "V" no grafico de Real Energy/Factory
```

**Implicação no design:** o worker NÃO é apenas gap-filler. É um
**reconciliador de telemetria** que:

1. Detecta valores anômalos via regras de domínio (KWH monotônico, range físico,
   ordem temporal)
2. Aplica regras em AMBAS as fontes (banco e CSV) — porque o próprio CSV
   contém a linha 83 errada
3. Substitui via `UPDATE sdr_active=false` (soft-delete) + `INSERT` da leitura
   correta — append-only mantido, CAG já filtra `WHERE sdr_active=true`
4. Refresh `sdr_hourly` (e em cascata `daily`/`monthly`) sempre que houver
   correção

## 2. Decisão

Construir o serviço **`ems-gap-filler`** em Java 21 + Spring Boot 3.4 num
repositório separado, com **2 modos de operação complementares**:

### Modo RECENT (automático)

- Loop `@Scheduled` de **15 em 15 min** — default `0 5/15 * * * *` → `:05, :20, :35, :50`
  (5 min após o refresh do CAG hourly em `:00/:15/:30/:45`); configurável via `gapfiller.recent.cron`
- Janela default: últimas 24 horas (re-varrida a cada ciclo — idempotente; `gapfiller.recent.window-hours`)
- Para cada sensor ativo:
    1. Busca leituras `WHERE sdr_active=true` na janela
    2. `AnomalyDetector` aplica regras (KWH monotônico, range físico, ordem
       temporal, duplicatas)
    3. Busca leituras do CSV via `MeterDataSource`
    4. Aplica as mesmas regras no CSV (filtra anomalias do CSV antes de usar)
    5. Para cada anomalia banco com substituto válido CSV →
       `softDelete + insert` correto
    6. Para cada leitura CSV ausente do banco → INSERT (gap real)
    7. Para cada anomalia banco SEM substituto CSV → soft-delete + flag manual
- Erro num sensor não aborta o ciclo — loga e segue (o próximo ciclo, em ≤15 min, re-tenta)
- Refresh `sdr_hourly` em cascata se houver correção
- Lock distribuído `gapfiller-recent-sweep` via ShedLock (`lockAtMostFor=14min`, p/ não bloquear 2 ciclos)

### Modo HISTORICAL (manual)

- Endpoint `POST /api/v1/backfill` recebe `{sensorIds?, windowStart, windowEnd}`
- Persiste em `ems.backfill_request` com status `QUEUED` e retorna `202 Accepted`
- Worker drena fila a cada 60s, processa **um por vez** (lock
  `gapfiller-historical-queue`, max 6h)
- Janela arbitrária (até 2 anos = start_offset CAG monthly)
- Se janela > 7 dias: `decompress_chunk()` antes do INSERT, `compress_chunk()`
  depois
- Se janela > 3 dias: `CALL refresh_continuous_aggregate(view, start, end)` em
  cascata (hourly → daily → monthly)
- Status via `GET /api/v1/backfill/{id}`. Se algum dos sensores pedidos falhar na reconciliação
  (ex: erro de DB), a request vai pra `FAILED` carregando a 1ª mensagem (`bfr_error`) — não vira
  `COMPLETED 0/0` silencioso. (No modo RECENT o ciclo só loga e segue — ele re-tenta em ≤15 min.)

## 3. Schema das 3 novas tabelas (em `ems`)

```
ems.ftp_source       catálogo medidor + credenciais (senha pgp_sym_encrypt)
ems.gap_log          append-only - cada gap detectado com mode/inserted/skipped
ems.backfill_request fila de HISTORICAL com status QUEUED → RUNNING → COMPLETED|FAILED
```

Migrations Flyway prefixadas `V70__`..`V76__` (schema `ems`, history em
`ems.ems_gap_filler_flyway_history`, `baseline-on-migrate=true`).

> **V76 — FK condicional.** A FK `ems.ftp_source.fts_sensor → ems.sensor(sen_id)`
> **não** é declarada inline no `V70`: o HOM (`150.150.251.112`, profile `hom`)
> sobe um TimescaleDB "vazio" que ainda não tem o schema do app EMS — `ems.sensor`
> não existe lá, e um `REFERENCES` inline faria `CREATE TABLE ems.ftp_source` falhar
> e o worker não subiria. O `V76__add_ftp_source_fk_conditional.sql` é um bloco
> `DO $$ … $$` que só faz o `ALTER TABLE … ADD CONSTRAINT` se `to_regclass('ems.sensor')`
> não for nulo, com `EXCEPTION WHEN OTHERS` pra nunca falhar a migration. No PRD
> (`ems.sensor` populado) a FK é criada normalmente; no HOM vira no-op (NOTICE).

## 4. Estratégias técnicas

### 4.1 Dedup pré-INSERT

A hypertable **não tem UNIQUE em `(sensor, valuetype, creation)`** —
PK composta é `(sdr_id, sdr_creation, sdr_sensor)` e `sdr_id` é sequence.

Existe **índice btree não-UNIQUE** já preparado:
`idx_sensordatarecord_sensor_type_creation (sdr_sensor, sdr_valuetype, sdr_creation DESC)`.

**Decisão:** worker faz `SELECT 1 WHERE sensor=? AND valuetype=? AND creation=?`
antes do INSERT, em batch (`WHERE (sensor, valuetype, creation) IN (...)`).
Custo amortizado: O(log n) por leitura via index hit.

**Alternativa rejeitada:** criar UNIQUE INDEX CONCURRENTLY. Risco em chunks
comprimidos — exige descomprimir tudo. Decisão revisitada caso volume de
duplicatas justifique.

### 4.2 Compression handling

Chunks com mais de 7 dias estão comprimidos via `policy_compression`. INSERT em
chunk comprimido **falha** (TimescaleDB rejeita).

**Fluxo HISTORICAL > 7d:**

```
1) computar minStart, maxEnd dos gaps
2) decompress_chunk('mqtt._hyper_X_Y_chunk') para cada chunk afetado
3) executar INSERTs em batch (lote 1000)
4) compress_chunk('...') para recomprimir
```

Manter `decompressedChunks` em memória ou em `ems.gap_log`.

### 4.3 CAG refresh

`policy_refresh_continuous_aggregate` agendado:

| CAG | Schedule | start_offset | end_offset |
|-----|----------|--------------|------------|
| sdr_hourly | 15min | 3 dias | 10min |
| sdr_daily | 1h | 30 dias | 1h |
| sdr_monthly | 6h | 2 anos | 1 dia |

Backfill em janela `> 3 dias` **não é coberto** pelo refresh do hourly →
worker chama `CALL refresh_continuous_aggregate('mqtt.sdr_hourly', start, end)`
após INSERT, em cascata para daily e monthly conforme janela.

### 4.4 Idempotência e segurança contra concorrência

- **ShedLock JDBC** com 2 locks: `recent-sweep` e `historical-queue`
- Sem mutação em chunks atualmente sob refresh do CAG
  (`pg_advisory_lock` opcional caso falsos positivos apareçam)
- INSERT em transação por gap (rollback se falha de rede no meio)

### 4.5 Timezone

Banco em `America/Manaus`, `sdr_creation` é `timestamp without time zone`.
Medidores também operam em horário Manaus.

**Worker NÃO converte timezone.** Container Docker do worker fixa
`TZ=America/Manaus` no Dockerfile e nas vars de ambiente.

**Pendência F7:** discrepância observada entre `sdr_json->>'_terminalTime'` e
`sdr_creation` (8h vs 4h esperado). A query Q08 do pre-ADR vai esclarecer
se o gateway envia em UTC, BRT ou outro fuso.

### 4.6 Decisões alternativas rejeitadas

**Recebedor passivo de FTP PUT do gateway.** Rejeitado porque inverteria o
controle operacional: exigiria reconfigurar EGX300/Carlo Gavazzi em campo,
abrir superfície de rede inbound e tratar autenticação/armazenamento de
arquivos recebidos. O problema confirmado é reconciliação seletiva de leituras
anômalas, não ingestão contínua de arquivos.

**Validação preventiva no `ems-api`.** Rejeitado como primeira linha de
correção porque o erro já existe no histórico e se propaga para CAGs.
Bloquear no `ems-api` ajudaria só leituras futuras, exigiria alterar o
caminho crítico MQTT/API do EMS e ainda não resolveria backfill, soft-delete
e refresh hierárquico. A validação preventiva pode ser etapa posterior, com
as mesmas regras configuráveis por sensor usadas pelo worker.

**Modbus TCP em tempo real (sem CSV).** Rejeitado porque não cobre histórico
— só leitura corrente. Útil como complemento futuro pra cross-validação em
tempo real, mas não substitui CSV pra reconciliar passado.

## 5. Stack

| Componente | Versão | Função |
|------------|--------|--------|
| Java | 21 LTS | runtime |
| Spring Boot | 3.4.1 | framework |
| Spring Web | 3.4.1 | REST API |
| Spring JDBC | 3.4.1 | data access |
| PostgreSQL JDBC | 42.7.x | driver |
| Flyway | 10.x (via Boot BOM) | migrations |
| Apache Commons Net | 3.11.1 | FTP client |
| OpenCSV | 5.9 | parser |
| ShedLock | 5.16.0 | lock distribuído |
| Micrometer + Prometheus | (Boot) | metrics |
| Testcontainers | 1.20.4 | integration tests |

## 6. APIs

```
POST   /api/v1/backfill           submit HISTORICAL (202 Accepted + UUID)
GET    /api/v1/backfill/{id}      status do backfill
GET    /api/v1/report[?limit=N]   diagnóstico read-only: Flyway history, ems.ftp_source,
                                  ems.backfill_request, ems.gap_log (+ agregados), sanity
                                  da telemetria (mqtt.sensordatarecord / ems.sensor / FK).
                                  Tolerante a ambiente vazio (HOM). scripts/ems-deploy.ps1
                                  puxa após o run e empacota report.json + RESUMO.txt no zip.
GET    /actuator/health           Spring Actuator (Docker healthcheck)
GET    /actuator/prometheus       métricas Micrometer
```

## 7. Configuração e secrets

- `application.yml` com profiles `dev`, `hom`, `prd`
- Senha do banco e FTP via env vars (`DB_PASSWORD`, `FTP_*_PASSWORD`)
- Chave PGP para descifrar `ftp_source.fts_password_enc` em env var
- Cron e janela configuráveis (`gapfiller.recent.cron`, `gapfiller.recent.window-hours`)
- **Kill-switches** (default `true`; relaxed-binding p/ env vars; lidos pelo `GapFillerScheduler`):
  `gapfiller.recent.enabled` (`GAPFILLER_RECENT_ENABLED`) desliga o loop RECENT (15 min);
  `gapfiller.historical.enabled` (`GAPFILLER_HISTORICAL_ENABLED`) desliga o drain da fila de
  backfill (um `POST /api/v1/backfill` fica `QUEUED` sem ser processado). Com os dois `false`,
  o worker sobe, aplica Flyway e expõe a API mas **não toca em telemetria** — é o modo usado pelo
  `ems-deploy.ps1 -DryRun` (validação seca em HOM).

## 8. Observabilidade

- **Logs**: SLF4J + Logback → stdout (LOKI já em `:3100` faz scrape via Promtail)
- **Métricas**: Micrometer → `/actuator/prometheus` (Prometheus do EMS já existente)
- **Counters principais:**
    - `ems_gap_filler_gaps_detected_total{mode,sensor}`
    - `ems_gap_filler_readings_inserted_total{mode}`
    - `ems_gap_filler_readings_skipped_total{mode}` (dedup hits)
    - `ems_gap_filler_ftp_errors_total{ip}`
    - `ems_gap_filler_decompress_seconds`
    - `ems_gap_filler_cag_refresh_seconds`
- **Alertas**: rate de erro FTP > 50% por 1h → PagerDuty/Telegram

## 9. Riscos e mitigação

| Risco | Mitigação |
|---|---|
| Lock contention com `policy_compression` (12h) | loop RECENT só toca chunks recentes (não comprimidos); HISTORICAL em chunk comprimido roda dentro do `CompressionGuard` (ver abaixo) |
| FTP intermitente | retry com backoff exponencial (3 tentativas) |
| CSV malformado | skip da linha + alerta (não quebra batch) |
| Memory pressure em backfill grande | stream parsing OpenCSV + batch 1000 + commit por batch |
| Worker dropa em meio do backfill | request fica em RUNNING → próximo restart detecta e retoma |
| Carlo Gavazzi sem FTP | parser HTTPS dedicado + fallback graceful |
| ems_user sem permissão DDL | superuser confirmado no HOM (Q12/08-05); só precisa de CREATE no schema `ems` (owner). Reconfirmar no PRD antes do deploy |
| CSV do EGX300 é buffer circular (~101 KB) → janela curta | loop RECENT a cada 15 min captura antes do wrap; backfill profundo > janela do CSV é best-effort (gap fica marcado p/ revisão) |
| Backfill HISTORICAL em chunk comprimido (> 7d) | **mitigado** — `reconcile()` no modo HISTORICAL, se a janela tem chunk(s) comprimido(s), roda dentro de `compressionGuard.runWithDecompressed(...)` (advisory lock em conexão dedicada → pausa `policy_compression` → `decompress_chunk` → reconcilia → `compress_chunk` → reabilita a policy). Modo RECENT (24h) não toca chunks comprimidos. Resta: se a app cair entre pausar/reabilitar a policy, reabilitar manualmente (logado como erro) |
| Medidores nos gateways sem `sen_id` na planilha (1 BM, 4 UT) | confirmar com Cesar se devem ser cadastrados no EMS / `ems.ftp_source` |
| HOM é um TimescaleDB vazio (sem schema do app EMS, sem `ems.sensor`) | FK `ftp_source→sensor` é condicional (V76, ver §3); o worker sobe, aplica Flyway e expõe a API; o reconcile vira no-op em HOM (sem `mqtt.sensordatarecord`) — HOM serve só pra validar boot/migrations/API/health |

## 10. Rollback

- Kill-switches `gapfiller.recent.enabled=false` (sweep horário) e `gapfiller.historical.enabled=false`
  (drain da fila) — com os dois OFF o worker fica inerte (só Flyway + API), zero escrita em telemetria
- As migrations vivem no schema `ems` (próprio do worker) e só fazem `CREATE TABLE`
  / `ADD CONSTRAINT` — pra reverter, `DROP SCHEMA ems CASCADE` (não há `*_undo__`)
- **Zero alteração no schema `mqtt.*`** — risco zero pro EMS atual
- Container pode ser removido do `docker-compose.yml` sem impacto

## 11. Decisões adiadas (para próximas iterações)

- Worker em modo distribuído (várias replicas) — atualmente single-instance
- TLS para FTP (FTPS) caso EGX300 suporte
- Backpressure quando hypertable está em compress concorrente
- Detecção de outliers durante backfill (delegado ao pipeline `ia.*` existente)
- **Recovery automático se a app cair com `policy_compression` pausada** — hoje o `CompressionGuard` loga "REABILITAR MANUALMENTE"; poderia ter um check no startup que reabilita jobs pausados órfãos
- **Parser dos logs binários `devN.bin`** do EGX300 — alternativa ao CSV (buffer circular) pra backfill profundo
- **Endpoint definitivo do Carlo Gavazzi** — capturar via tentativa Java (TLS legado + Basic Auth) e atualizar `fts_csv_path` dos sensores 12/13 em `ems.ftp_source`
- **Cálculo dos agregados derivados F1-F6** após soft-delete (hoje só documentado em `DerivedSensorFormula`, não executado)

---

## 12. Recon de medidores (08/05/2026)

Coleta de FTP/HTTPS dos 3 gateways (saída em `ems-recon/20260508-083901/`).

### EGX300 BM — `10.193.217.11` (firmware 4.460)

`/logging/data/` expõe **5 CSVs** + 5 binários `devN.bin` (~583 KB):

| Arquivo CSV | Slave Modbus | sen_id (planilha) |
|---|---|---|
| `MV-F3-M_1.csv`  | 1 | 30 |
| `MV-F3-1_2.csv`  | 2 | 10109 |
| `MV-F3-3_4.csv`  | 4 | **sem mapeamento na planilha** |
| `MV-F3-4_5.csv`  | 5 | 10154 |
| `LV-F3-1M_6.csv` | 6 | 21 |

### EGX300 UT — `10.194.124.49` (firmware 4.300)

`/logging/data/` expõe **8 CSVs** + 8 binários `devN.bin` (~2.1 MB):

| Arquivo CSV | Slave Modbus | sen_id (planilha) |
|---|---|---|
| `MV_F3_LM_1.csv` | 1 | **sem mapeamento** |
| `MV_F3_L1_2.csv` | 2 | 10112 |
| `MV_F3_L2_3.csv` | 3 | 10110 |
| `MV_F3_L3_4.csv` | 4 | 10111 (Compressor) |
| `MV_F3_L4_5.csv` | 5 | 10105 |
| `LV_F3_L1_6.csv` | 6 | **sem mapeamento** |
| `LV_F3_L2_7.csv` | 7 | **sem mapeamento** |
| `LV_F3_L3_8.csv` | 8 | **sem mapeamento** |

**Achado crítico:** todos os CSVs do EGX300 têm **tamanho fixo de 101 376 bytes**
→ é um **buffer circular** (histórico rolante). O download direto via `FtpWebRequest`
do .NET retorna 550 / 0 bytes — o `FtpEgx300DataSource` (Apache Commons Net, sequência
`connect→login→BINARY→PASSIVE→CWD→RETR`) ainda precisa ser validado em runtime contra
o gateway real.

### Estrutura do CSV confirmada (exports MV-F3-1 / MV-F3-4, 11/05/2026)

Dois exports completos do gateway BM (~11 400 linhas, ~39 dias 18/03→27/04) confirmaram:

- **18 colunas**, header **na linha 7** (linhas 1-2 = metadata gateway/device, 4-5 = Topic IDs internos, 3/6 vazias):
  `Error | UTC Offset (minutes) | Local Time Stamp | Voltage A-N | Voltage B-N | Voltage C-N | Voltage A-B | Voltage B-C | Voltage C-A | Current A | Current B | Current C | Frequency | Real Power Total (kW) | Reactive Power Total (kVAR) | Power Factor Sign | Real Energy (kWh) | Reactive Energy (kVARh)`
- Timestamp local Manaus, formato `dd/MM/yyyy HH:mm[:ss]` (segundos aparecem nas linhas pós-wrap)
- `UTC Offset = -240` (minutos) = -4h → confirma "worker NÃO converte TZ"
- `Real Energy (kWh)` e `Reactive Energy (kVARh)` são **acumuladores monotônicos** (~1e12-1e14, escala bruta do gateway, não kWh limpos); `Real Power Total (kW)` vem em ~1e6 × kW (mW ou raw) → **a escala vs. o que o DB armazena ainda precisa ser confirmada**
- **O buffer circular envolve (wrap)** → ~0,5% das linhas são **lixo**: timestamps absurdos (1996, 2013, 2030…), valores ~1e17-1e67, `Error` em códigos altos. `Error == 1` é erro de comunicação recuperável (a leitura vem boa). → o `EgxCsvParser` agora **filtra** essas linhas (ano fora de [2020, anoAtual+1] OU valor não-finito/negativo/> 1e15) **antes** de qualquer leitura sair, e tolera números em `16878047232000` / `7969.058` / `7.728.264.704.000,00`.
- **O `.csv` do FTP (~101 KB) é menor que esses exports** — é um buffer rolante de poucos dias; o histórico completo (esses exports) vem de um export mais amplo (web UI do gateway / `devN.bin`). Backfill profundo (> janela do `.csv` do FTP) precisa dessa fonte mais ampla.
- **Pendência F1.bis:** confirmar contra o DB as strings de `sdr_valuetype` reais por sensor antes de habilitar a extração das outras 14 colunas (hoje o parser extrai só `Real Energy (kWh)` → valuetype `KWH`, que é o do incidente da causa-raiz). Mapa proposto coluna→valuetype já documentado em `EgxCsvParser.COLUMN_TO_VALUETYPE`.

### Carlo Gavazzi 69kV — `10.193.217.50`

Apenas porta **443 (HTTPS)** aberta. O probe genérico do PowerShell falhou no
handshake TLS ("a conexão subjacente estava fechada"); endpoints testados
(`/login.html`, `/data.json`, `/api/v1/data`, `/em24`, `/log.csv`, `/datalogger`,
`/measurements`, …) retornaram vazio. **Endpoint definitivo ainda TBD** — o
`HttpsCarloGavazziDataSource` já força TLS legado + trust-all + Basic Auth, mas o
`csvPath` candidato em `ems.ftp_source` (sensores 12/13) ainda é placeholder
`/index.html`. Modelo provável: VMU-C / EM24 da Carlo Gavazzi (Plan IDs 430/704).

### Tabela de pendências de levantamento (atualizada)

| ID | Furo | Status (11/05) |
|----|------|----------------|
| F1 | CSV real EGX300 (estrutura/decimal/TZ) | **confirmado** — 18 colunas, header na linha 7, timestamp `dd/MM/yyyy HH:mm[:ss]`, acumuladores monotônicos, buffer circular com ~0,5% de linhas-lixo (filtradas no parser). Falta: número exato no `.csv` cru do FTP + escala das potências vs DB |
| F2 | Carlo Gavazzi HTTPS endpoints | **pendente** — handshake falha; endpoint TBD |
| F3 | Próxima versão Flyway | **fechado** — worker usa table própria `ems_gap_filler_flyway_history`, sem conflito com `mqtt.flyway_schema_history` |
| F4 | Permissões `ems_user` (CREATE TABLE) | **parcial** — Q12/08-05 mostrou `ems_user` **SUPERUSER** (`rolsuper=t`) **no HOM** (o run de 08/05 caiu no HOM porque o PRD deu "too many clients"); presume-se o mesmo no PRD (mesmo role provisionado). O worker só precisa de CREATE no schema `ems` (do qual `ems_user` é owner) — não usa `CREATE EXTENSION` (`pgcrypto` é só usado, e o `timescale-it.sql` só cria extensões no container de teste). **Reconfirmar contra PRD antes do primeiro deploy lá.** |
| F5 | Chunk time interval | parcial — hypertable confirmada (463 chunks); valor exato do interval a confirmar |
| F6 | Tamanho real disco | fechado — run 07/05: 463 chunks, 455 comprimidos (98%), range 10/2024→05/2026 |
| F7 | TZ `_terminalTime` vs `sdr_creation` | **pendente** — discrepância observada (8h vs 4h); precisa de query dedicada |
| F8 | Sensores com JSON denso | parcial — run 07/05 trouxe amostras; baixa prioridade pro MVP |
| F9 | `last_sensor_value` confiável? | fechado — 69 MB / 1159 rows; usado só por `findLastReadingFor` |
| F10 | Owner hypertable + roles | fechado — `ems_user` superuser; sem owner separado |

## 13. Suíte de testes e CI

### Testes unitários (`mvn test` — surefire, `*Test.java`)

| Classe | Cobre |
|---|---|
| `AnomalyDetectorTest` (5) | NON_MONOTONIC (linha 83), OUT_OF_RANGE (V/HZ), DUPLICATE_TIMESTAMP, sequência KWH válida |
| `EgxCsvParserTest` (8) | header dinâmico (18 colunas reais, linha 7), timestamp `HH:mm[:ss]`, número plain/US-decimal/grouping-BR, filtro de janela, infer de valuetype, **descarte das linhas-lixo do buffer circular** (`isPlausible`), `Error=1` mantido |
| `ReconciliationServiceTest` (8) | substitui anomalia c/ substituto CSV; marca p/ revisão sem substituto; preenche gap; no-op se CSV vazio; pula sensor sem datasource; **erro num sensor → `sensorsFailed`/`firstError` na summary, lote segue**; HISTORICAL c/ chunk comprimido roda dentro do `CompressionGuard`; HISTORICAL sem chunk comprimido não usa |
| `BackfillControllerTest` (4) | POST → 202 + QUEUED; POST sem `windowStart` → 400; GET → 200; GET inexistente → 404 |
| `ReportControllerTest` (3) | `GET /api/v1/report` → 200 c/ as seções esperadas; tolera tabela ausente (seção vira `{"error":…}`, nunca 500); respeita `limit` máximo |
| `GapFillerSchedulerTest` (6) | `recentSweep` roda só se `recent.enabled`; `drainHistoricalQueue` não toca na fila se `historical.enabled=false`; com fila vazia consulta e para; com pendente faz `RUNNING → reconcile → COMPLETED`; **se algum sensor falhou → `RUNNING → reconcile → FAILED` (não COMPLETED)** |
| `JdbcSensorMeterRepositoryTest` (2) | sem chave cripto o SQL não menciona `pgp_sym_decrypt` (lê `fts_password_enc` cru); com chave, usa `pgp_sym_decrypt(...::bytea, ?)` |

### Testes de integração (`mvn verify` — failsafe, `*IT.java`, Testcontainers)

Sobem um container `timescale/timescaledb:2.21.0-pg17` (mesma versão de prod);
`db/timescale-it.sql` recria o mínimo de `mqtt`/`ems` (inclusive `ems.sensor`) e o
Flyway roda V70..V76 por cima — então o `V76` cria a FK no ambiente de IT.
`GapFillerScheduler` é `@Profile("!test")` (cron não dispara na suíte).

| Classe | Cobre |
|---|---|
| `MigrationAndSeedIT` | migrations criam as 6 tabelas do schema `ems`; Flyway history tem V70..V76; seed V74 = 10 medidores (8 FTP + 2 HTTPS); mapeamento do medidor BM; sem `fts_sensor` órfão; `V76` criou a constraint `fk_ftp_source_sensor` (porque o IT tem `ems.sensor`) |
| `JdbcSensorMeterRepositoryIT` | `findActive()` = 10; `findBySensorId` mapeia todas as colunas (FTP c/ slave, HTTPS sem slave); inexistente → empty |
| `JdbcBackfillRequestRepositoryIT` | ciclo QUEUED→RUNNING→COMPLETED (`started_at`/`finished_at`); `findNextQueued` pega o mais antigo e ignora não-QUEUED; `updateStatus(FAILED, msg)` |
| `JdbcTelemetryRepositoryIT` | `insertBatch` idempotente (dedup pré-INSERT, sem UNIQUE); `findActiveReadings` respeita janela meio-aberta + soft-delete; soft-delete + insert grava valor corrigido (append-only); `findReadingTimestamps` distinct ordenado |
| `JdbcGapLogRepositoryIT` | `record()` grava gap e a coluna gerada `gpl_duration_sec` |
| `JdbcCompressionGuardIT` (3) | `findCompressedChunksFor` vs `timescaledb_information.chunks` (vazio em banco fresco); `runWithDecompressed` executa o work e devolve o resultado; libera o advisory lock mesmo com exceção no work (chamada seguinte funciona) |

### CI (`.gitlab-ci.yml`)

`build` (compile main+test) → `test` (`mvn verify` com `services: docker:27-dind`
pros Testcontainers) → `docker-build` (só na branch `main`; push pro registry
comentado). Roda nos shared runners do GitLab.com (suportam dind privilegiado).
