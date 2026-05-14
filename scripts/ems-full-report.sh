#!/usr/bin/env bash
# =============================================================================
# ems-full-report.sh - RELATORIO COMPLETO em UMA execucao no .112
#
# Sobe o ems-gap-filler-test, dispara backfill no sensor escolhido, espera concluir,
# tira /api/v1/report, dump dos docker service logs e roda queries read-only no PG do
# ambiente. Tudo na tela (e tambem salvo em /tmp/ems-full-<env>-<ts>.txt) pra colar.
#
# USO (no .112):
#   T='glpat-...'
#   curl -s 'https://gitlab.com/api/v4/projects/81970992/repository/files/scripts%2Fems-full-report.sh/raw?ref=main&private_token='"$T" -o /tmp/full.sh
#   sudo -v
#   EMS_ENV=prd bash /tmp/full.sh                # PRD, sensor 30, janela [agora-3h, agora-1h]
#   EMS_ENV=hom EMS_BF_SENSOR=10110 bash /tmp/full.sh
#
# Variaveis:
#   EMS_ENV=hom|prd       default hom
#   EMS_BF_SENSOR         sensor pro backfill (default 30)
#   EMS_BF_START/END      janela em natural-lang p/ GNU date (default "3 hours ago" / "1 hour ago", em Manaus)
#   EMS_JAR_VERSION       default 0.2.0-r6   (r6 = escala /1M energia gipam; r5 refresh CAG; r4 parser ISO)
#   EMS_SUDO_PASS         senha do sudo (se nao rodou `sudo -v` antes); ou passa como $1
#   EMS_POLL_MAX_SECS     timeout do poll do backfill em segundos (default 360 = 6min, p/ acomodar fetch FTP ~76s)
# =============================================================================
set -euo pipefail

if [ -n "${1:-}" ]; then EMS_SUDO_PASS="$1"; fi

PROJECT_ID=81970992
JAR_VERSION="${EMS_JAR_VERSION:-0.2.0-r6}"
EMS_ENV="${EMS_ENV:-hom}"
BFS="${EMS_BF_SENSOR:-30}"
POLL_MAX="${EMS_POLL_MAX_SECS:-360}"
HOST_PORT=18080
NAME=ems-gap-filler-test
BASE_IMG=eclipse-temurin:21-jre
LOCAL_IMG=ems-gap-filler-test:local
GITLAB_TOKEN="${GITLAB_TOKEN:-glpat-1KBJACUAPmj8f3V1ivdBLmM6MQpvOjEKdTptbDV2aQ8.01.1706sk2g4}"

if [ "$EMS_ENV" = prd ]; then
  PG_PAT='ems-database-main_';    DB_PASS='Glimmer7-Enroll-Bloomers'; PROFILE=prd
  NET="${EMS_DOCKER_NETWORK:-ems-main_backend}"
  DB_HOST="${EMS_DB_HOST:-ems-database-main_timescaledb}"
else
  PG_PAT='ems-database-homolog_'; DB_PASS='Sureness-Stencil9-Flap';  PROFILE=hom
  NET="${EMS_DOCKER_NETWORK:-ems-homolog_backend}"
  DB_HOST="${EMS_DB_HOST:-ems-database-homolog_timescaledb}"
fi
DB_URL="jdbc:postgresql://${DB_HOST}:5432/energymanagementsystem"
TS=$(date +%Y%m%d-%H%M%S)
OUT="/tmp/ems-full-${EMS_ENV}-${TS}.txt"

# salva tudo num arquivo enquanto exibe na tela
exec > >(tee "$OUT") 2>&1

H(){ printf '\n\033[1;36m======================== %s ========================\033[0m\n' "$*"; }
S(){ printf '\n\033[1;33m-- %s --\033[0m\n' "$*"; }

H "[META] ems-full-report  env=$EMS_ENV  sensor=$BFS  jar=$JAR_VERSION  rede=$NET  db_host=$DB_HOST"
echo "host=$(hostname)  now=$(date -Iseconds)  arquivo=$OUT"

# ---- docker: direto ou via sudo --------------------------------------------
_DK=(docker)
if ! docker ps >/dev/null 2>&1; then
  if sudo -n true 2>/dev/null; then _DK=(sudo -n docker)
  elif [ -n "${EMS_SUDO_PASS:-}" ]; then
    printf '%s\n' "$EMS_SUDO_PASS" | sudo -S -p '' -v 2>/dev/null || { echo "sudo recusou a senha"; exit 1; }
    _DK=(sudo -n docker)
  else echo "precisa de sudo. roda 'sudo -v' antes ou passa a senha como \$1."; exit 1; fi
fi
dk(){ "${_DK[@]}" "$@"; }
# PG container: filtra por IMAGEM timescale + nome com prefixo 'ems-database-main_'/'ems-database-homolog_'
# (prefixo completo pra eliminar ambiguidade com 'ems-main_backend', 'ems-main_traefik' etc).
PG_CID=$(dk ps --format '{{.ID}}|{{.Names}}|{{.Image}}' | awk -F'|' -v p="$PG_PAT" 'tolower($3) ~ /timescale/ && tolower($2) ~ p {print $1; exit}')
if [ -z "$PG_CID" ]; then
  echo "[ERRO] nao achei container postgres do ambiente '$EMS_ENV' (padrao '$PG_PAT' + imagem timescale)."
  echo "Containers ativos com 'timescale' na imagem:"
  dk ps --format '  {{.ID}}  {{.Names}}  [{{.Image}}]' | grep -i timescale || echo '  (nenhum)'
  echo "Tente: EMS_PG_CONTAINER=<id> bash $0  (ou ajuste PG_PAT no script)"
  PG_CID="${EMS_PG_CONTAINER:-}"
fi
[ -n "$PG_CID" ] && echo "PG_CID=$PG_CID  ($(dk inspect -f '{{.Name}}' "$PG_CID" 2>/dev/null | sed 's#^/##'))"
pg(){
  if [ -z "$PG_CID" ]; then echo "[skip-pg] PG_CID vazio"; return 0; fi
  dk exec -i "$PG_CID" psql -U ems_user -d energymanagementsystem -P pager=off -c "$1"
}

H "[1] DOCKER + AMBIENTE"
dk version --format 'docker client {{.Client.Version}}  server {{.Server.Version}}'
dk info --format 'swarm={{.Swarm.LocalNodeState}}  containers={{.Containers}}  node={{.Name}}'
echo "postgres do ambiente:"; dk ps --format '  {{.Names}}  [{{.Image}}]' | grep -i timescaledb
echo "PG_CID=$PG_CID"

H "[2] BAIXANDO JAR $JAR_VERSION (generic package)"
TMP=$(mktemp -d /tmp/ems-full.XXXXXX)
JAR_URL="https://gitlab.com/api/v4/projects/${PROJECT_ID}/packages/generic/ems-gap-filler/${JAR_VERSION}/ems-gap-filler-0.2.0-SNAPSHOT.jar"
curl -fSL -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" -o "$TMP/app.jar" "$JAR_URL"
SZ=$(stat -c%s "$TMP/app.jar" 2>/dev/null || stat -f%z "$TMP/app.jar")
echo "jar=$TMP/app.jar  size=$SZ bytes"
[ "$SZ" -gt 1000000 ] || { echo "JAR INVALIDO"; exit 1; }

H "[3] BUILD IMAGEM LOCAL ($LOCAL_IMG)"
cat > "$TMP/Dockerfile" <<EOF
FROM ${BASE_IMG}
COPY app.jar /app.jar
ENV TZ=America/Manaus
ENTRYPOINT ["java","-Duser.timezone=America/Manaus","-Xms256m","-Xmx512m","-jar","/app.jar"]
EOF
dk build -t "$LOCAL_IMG" "$TMP" 2>&1 | tail -6

H "[4] (RE)CRIANDO SERVICE $NAME na overlay $NET"
dk rm -f "$NAME" >/dev/null 2>&1 || true
dk service rm "$NAME" >/dev/null 2>&1 || true
sleep 2
dk service create --name "$NAME" --network "$NET" --replicas 1 \
  --restart-condition on-failure --restart-max-attempts 2 \
  --publish "published=${HOST_PORT},target=8080,mode=host" --no-resolve-image \
  --env SPRING_PROFILES_ACTIVE="$PROFILE" --env DB_URL="$DB_URL" \
  --env DB_USER=ems_user --env DB_PASSWORD="$DB_PASS" \
  --env SERVER_PORT=8080 --env GAPFILLER_RECENT_ENABLED=false \
  --env GAPFILLER_HISTORICAL_ENABLED=true --env TZ=America/Manaus \
  "$LOCAL_IMG" >/dev/null
sleep 2
dk service ps "$NAME" --no-trunc

H "[5] AGUARDANDO /actuator/health UP (timeout 120s)"
OK=0
for i in $(seq 1 60); do
  sleep 2
  h=$(curl -s -m 3 "http://127.0.0.1:${HOST_PORT}/actuator/health" 2>/dev/null || true)
  case "$h" in *'"status":"UP"'*) OK=1; break;; esac
done
if [ "$OK" -ne 1 ]; then
  echo "NAO subiu UP. log:"; dk service logs --tail 120 "$NAME" 2>&1
  echo "(deixado de pe pra investigar; rode 'sudo docker service rm $NAME' pra remover)"
  exit 1
fi
echo "UP em ${i}*2s"

H "[6] POST /api/v1/backfill - sensor $BFS"
# Default 2h: barato e rapido. Pra exercitar o fix r5 (refresh CAG) em PRD apos limpar
# anomalias recentes, ampliar com EMS_BF_START='24 hours ago' (mais chance de encontrar
# outliers ainda vivos -> dispara softDelete/replace -> dispara refresh).
WS=$(TZ=America/Manaus date -d "${EMS_BF_START:-3 hours ago}" +%Y-%m-%dT%H:%M:00)
WE=$(TZ=America/Manaus date -d "${EMS_BF_END:-1 hour ago}"   +%Y-%m-%dT%H:%M:00)
echo "windowStart=$WS  windowEnd=$WE  (Manaus)"
RESP=$(curl -s -X POST "http://127.0.0.1:${HOST_PORT}/api/v1/backfill" \
  -H 'Content-Type: application/json' -H 'X-Requested-By: full-report' \
  -d "{\"sensorIds\":[$BFS],\"windowStart\":\"$WS\",\"windowEnd\":\"$WE\"}")
echo "submit -> $RESP"
RID=$(printf '%s' "$RESP" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("id",""))' 2>/dev/null || true)
echo "request_id=$RID"

S "polling status (timeout ${POLL_MAX}s; FTP fetch demora ~76s)"
ELAPSED=0
while [ "$ELAPSED" -lt "$POLL_MAX" ]; do
  sleep 5; ELAPSED=$((ELAPSED + 5))
  S2=$(curl -s "http://127.0.0.1:${HOST_PORT}/api/v1/backfill/$RID" 2>/dev/null || true)
  printf '  [t=%3ds] %s\n' "$ELAPSED" "$S2"
  case "$S2" in *'"status":"COMPLETED"'*|*'"status":"FAILED"'*|*'"status":"CANCELLED"'*) break;; esac
done

H "[7] GET /api/v1/report?limit=500"
curl -s "http://127.0.0.1:${HOST_PORT}/api/v1/report?limit=500" | (python3 -m json.tool 2>/dev/null || cat)

H "[8] docker service logs (--tail 400, inclui CSV-HEAD-SAMPLE se parser falhou)"
dk service logs "$NAME" --tail 400 2>&1

H "[9] QUERIES READ-ONLY no Postgres de $EMS_ENV (via docker exec psql)"

S "[9.1] ems.gap_log (linhas gravadas pelo worker)"
pg "SELECT gpl_id, to_char(gpl_creation,'YYYY-MM-DD HH24:MI:SS') gravado, gpl_sensor, gpl_mode, gpl_inserted, gpl_skipped, left(gpl_status, 120) gpl_status, gpl_request_id FROM ems.gap_log ORDER BY gpl_creation DESC LIMIT 20;"

S "[9.2] ems.backfill_request (10 mais recentes)"
pg "SELECT bfr_id, bfr_status, bfr_sensor_ids::text sensors, to_char(bfr_window_start,'YYYY-MM-DD HH24:MI') ini, to_char(bfr_window_end,'YYYY-MM-DD HH24:MI') fim, bfr_inserted, bfr_skipped, to_char(bfr_finished_at - bfr_started_at, 'MI:SS') duracao, left(bfr_error, 120) erro FROM ems.backfill_request ORDER BY bfr_created_at DESC LIMIT 10;"

S "[9.3] ems.ftp_source (seed dos medidores)"
pg "SELECT fts_sensor, fts_meter_ip, fts_protocol, fts_modbus_slave_id slv, fts_csv_path, fts_active FROM ems.ftp_source ORDER BY fts_sensor;"

S "[9.4] mqtt.sensordatarecord - sensor $BFS, KWH, ultimas 24h"
pg "SELECT count(*) total, count(*) FILTER (WHERE sdr_value=0) zeros, round(min(sdr_value)::numeric, 3) min_kwh, round(max(sdr_value)::numeric, 3) max_kwh, to_char(min(sdr_creation),'YYYY-MM-DD HH24:MI') primeiro, to_char(max(sdr_creation),'YYYY-MM-DD HH24:MI') ultimo FROM mqtt.sensordatarecord WHERE sdr_sensor=$BFS AND sdr_valuetype='KWH' AND sdr_active AND sdr_creation>now()-interval '24 hours';"

S "[9.5] mqtt.sensordatarecord - sensor $BFS, todos valuetypes, ultimas 24h"
pg "SELECT sdr_valuetype, count(*) n, count(*) FILTER (WHERE sdr_value=0) zeros, to_char(max(sdr_creation),'YYYY-MM-DD HH24:MI') ultima FROM mqtt.sensordatarecord WHERE sdr_sensor=$BFS AND sdr_active AND sdr_creation>now()-interval '24 hours' GROUP BY 1 ORDER BY 1;"

S "[9.6] anomalias 'KWH zerado' nos sensores FTP - ultimos 10 dias"
pg "SELECT sdr_sensor, sdr_valuetype, count(*) FILTER (WHERE sdr_value=0) zeros, count(*) total, to_char(min(sdr_creation) FILTER (WHERE sdr_value=0),'YYYY-MM-DD HH24:MI') primeiro_zero FROM mqtt.sensordatarecord WHERE sdr_active AND sdr_sensor IN (30,21,10105,10109,10110,10111,10112,10154) AND sdr_valuetype IN ('KWH','KVARH') AND sdr_creation>now()-interval '10 days' GROUP BY 1,2 HAVING count(*) FILTER (WHERE sdr_value=0)>0 ORDER BY zeros DESC;"

S "[9.7] timescaledb - chunks comprimidos vs nao comprimidos"
pg "SELECT is_compressed, count(*) chunks, to_char(min(range_start),'YYYY-MM-DD') primeiro, to_char(max(range_end),'YYYY-MM-DD') ultimo FROM timescaledb_information.chunks WHERE hypertable_schema='mqtt' AND hypertable_name='sensordatarecord' GROUP BY 1 ORDER BY 1 DESC;"

S "[9.8] timescaledb - CAGs e procedures em mqtt.*"
pg "SELECT view_name FROM timescaledb_information.continuous_aggregates WHERE view_schema='mqtt';"
pg "SELECT n.nspname schema, p.proname nome, pg_get_function_result(p.oid) retorno FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname='mqtt' ORDER BY 2;"

S "[9.9] linhas TOCADAS pelo worker (sdr_active=false ou updated nas ultimas 24h) - sensor $BFS"
pg "SELECT sdr_valuetype, to_char(sdr_creation,'YYYY-MM-DD HH24:MI') creation, sdr_value, sdr_active, to_char(sdr_last_updated,'YYYY-MM-DD HH24:MI:SS') last_updated FROM mqtt.sensordatarecord WHERE sdr_sensor=$BFS AND (sdr_active=false OR sdr_last_updated>now()-interval '24 hours') ORDER BY sdr_last_updated DESC NULLS LAST, sdr_creation DESC, sdr_valuetype LIMIT 30;"

S "[9.10] HZ fora do range fisico [50, 65] (anomalia OUT_OF_RANGE) - sensor $BFS, ultimos 10 dias"
pg "SELECT to_char(sdr_creation,'YYYY-MM-DD HH24:MI') creation, sdr_value, sdr_active FROM mqtt.sensordatarecord WHERE sdr_sensor=$BFS AND sdr_valuetype='HZ' AND sdr_creation>now()-interval '10 days' AND (sdr_value<50 OR sdr_value>65) ORDER BY sdr_creation DESC LIMIT 30;"

S "[9.11] timeline COMPLETA (14 valuetypes) do instante da 1a soft-delete deste run (extraido do log do worker)"
TS_ANOM=$(dk service logs "$NAME" --since 10m 2>&1 | sed -n "s/.*softDelete sensor=${BFS} valuetype=[^ ]* creation=\([^ ]*\) rows=.*/\1/p" | head -1)
echo "timestamp da anomalia (do log): ${TS_ANOM:-<nenhum>}"
if [ -n "$TS_ANOM" ]; then
  TS_PG=$(echo "$TS_ANOM" | sed 's/T/ /')
  pg "SELECT sdr_valuetype, sdr_value, sdr_active FROM mqtt.sensordatarecord WHERE sdr_sensor=$BFS AND sdr_creation='$TS_PG' ORDER BY sdr_active DESC, sdr_valuetype;"
fi

S "[9.12] mqtt.sensordatarecord - cardinalidade global (rapido pra contexto)"
pg "SELECT count(*) total_rows, count(DISTINCT sdr_sensor) sensors_distintos, count(DISTINCT sdr_valuetype) valuetypes_distintos, to_char(min(sdr_creation),'YYYY-MM-DD') desde, to_char(max(sdr_creation),'YYYY-MM-DD HH24:MI') ate FROM mqtt.sensordatarecord WHERE sdr_active;"

H "[10] SUMARIO DOS FIXES"
GL_COUNT=$(pg "SELECT count(*) FROM ems.gap_log WHERE gpl_request_id IS NOT NULL;" 2>/dev/null | awk '/^[[:space:]]*[0-9]+$/ {print $1; exit}')
LAST_BF=$(pg "SELECT bfr_status FROM ems.backfill_request WHERE bfr_id='$RID';" 2>/dev/null | awk '/COMPLETED|FAILED|CANCELLED|QUEUED|RUNNING/ {print $1; exit}')
echo "Fix #1 gap_log gravado:         ${GL_COUNT:-?} linhas com gpl_request_id (esperado >= 1 apos esse run)"
echo "Fix #2 replaceReading atomico:  passa por IT; com r4 (parser destravado) tende a disparar quando ha discrepancia real"
echo "Fix #3 rootMessage curto:       ver bfr_error na [9.2] - deve ser tipo 'PSQLException: ...' SEM o SQL embutido"
echo "Fix #4 (r5) refresh_continuous_aggregate INLINE LITERAL (CALL ... TIMESTAMP '...'): grep no [8] 'refresh mqtt.sdr_hourly' = OK; sem 'bad SQL grammar'"
echo "Fix #5 (r4) parser timestamp ISO: aceita 'yyyy-MM-dd HH:mm:ss' (FTP cru) + 'dd/MM/yyyy HH:mm[:ss]' (XLSX)"
echo "Fix #6 (r6) escala device-aware: GIPAM/GIMAC -> KWH/KVARH/KW_SYS/KVAR_SYS dividido por 1M (igual deconsysmodbus)"
echo "FTP fetch runtime:              ver [8] - 'FTP RETR OK ... -> N bytes' (primeira validacao real do FtpEgx300DataSource)"
echo "CSV parser:                     ver [8] - 'CSV parser sep=... produziu N leituras' = OK; se 'nao consegui parsear' GATE ABERTO -> 'CSV-HEAD-SAMPLE' loga head bruto"
echo "Backfill desse run ($RID): $LAST_BF"
REFRESH_OK=$(dk service logs "$NAME" --since 10m 2>&1 | grep -c 'refresh mqtt.sdr_hourly' || true)
REFRESH_FAIL=$(dk service logs "$NAME" --since 10m 2>&1 | grep -c 'refresh.*fallback' || true)
echo "refresh CAG hourly:             OK=${REFRESH_OK}  fallback=${REFRESH_FAIL}  (esperado: OK>=1, fallback=0 com r5)"

H "[FIM] arquivo completo: $OUT"
echo "PRA PARAR/REMOVER:  ${_DK[*]} service rm $NAME  ;  rm -rf $TMP $OUT"
