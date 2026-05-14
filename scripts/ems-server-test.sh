#!/usr/bin/env bash
# =============================================================================
# ems-server-test.sh - sobe o ems-gap-filler num servico/container de TESTE no
# servidor (150.150.251.112, Docker Swarm), conectando no Postgres do ambiente.
# Tudo na tela: discovery, boot, Flyway, /api/v1/report, logs.
#
# O .112 e SWARM e o timescaledb de cada ambiente vive numa rede overlay
# (ems-homolog_backend / ems-main_backend) que nao e "attachable" -> nesse caso
# o worker sobe como `docker service` (swarm consegue anexar). Em host bridge
# normal, sobe como `docker run`. Detecta sozinho.
#
# NAO e o deploy permanente. Servico/container = ems-gap-filler-test, cron RECENT
# OFF, JAR pre-buildado (generic package) embutido numa imagem local. Em HOM faz
# 1 smoke-test backfill; em PRD nunca toca telemetria automaticamente.
#
# USO (no .112):
#   T='glpat-...'
#   curl -sSL -H "PRIVATE-TOKEN: $T" \
#     "https://gitlab.com/api/v4/projects/81970992/repository/files/scripts%2Fems-server-test.sh/raw?ref=main" \
#     -o /tmp/ems-server-test.sh
#   GITLAB_TOKEN="$T" EMS_ENV=hom EMS_SUDO_PASS="<senha-sudo>" bash /tmp/ems-server-test.sh
#
# Variaveis:
#   GITLAB_TOKEN          (obrigatorio) baixa o jar do generic package
#   EMS_SUDO_PASS         senha do sudo (so se 'docker' precisar de sudo)
#   EMS_ENV=hom|prd       default hom    (casa com o timescaledb cujo nome contem 'homolog'/'main')
#   EMS_DOCKER_NETWORK    rede do postgres; se vazio, auto-detecta pelo container do timescaledb
#   EMS_DB_HOST           host do banco no DB_URL; se vazio, usa o nome do service (overlay DNS) ou o IP
#   EMS_SMOKE=0|1         default: 1 em hom, 0 em prd
#   EMS_BACKFILL=1        faz 1 POST /api/v1/backfill (sensor EMS_BF_SENSOR, default 30) numa janela
#                         [agora-3h, agora-1h] Manaus -> vale pra ver o reconcile contra dado real em prd
#   EMS_KEEP=0|1          default 1: deixa de pe no fim (0 = remove service/container + tmp)
#   EMS_JAR_VERSION       default 0.2.0-r6   (r6 = escala /1M energia gipam; r5 CAG; r4 parser ISO)
# =============================================================================
set -euo pipefail

# args posicionais opcionais (terminal da ponte embaralha paste longo -> linha curta e melhor):
#   $1 = EMS_SUDO_PASS (senha do sudo). Se voce rodou 'sudo -v' antes, nem precisa.
if [ -n "${1:-}" ]; then EMS_SUDO_PASS="$1"; fi

PROJECT_ID=81970992
EMS_ENV="${EMS_ENV:-hom}"
JAR_VERSION="${EMS_JAR_VERSION:-0.2.0-r6}"
BASE_IMG="${EMS_JRE_IMG:-eclipse-temurin:21-jre}"
LOCAL_IMG=ems-gap-filler-test:local
HOST_PORT="${EMS_HOST_PORT:-18080}"
NAME=ems-gap-filler-test
# token hardcoded (igual ao ems-deploy.ps1 / deploy-server.sh que ja estao no repo); expira 2026-06-04
GITLAB_TOKEN="${GITLAB_TOKEN:-glpat-1KBJACUAPmj8f3V1ivdBLmM6MQpvOjEKdTptbDV2aQ8.01.1706sk2g4}"

if [ "$EMS_ENV" = prd ]; then
  PG_PAT='_main_';    DB_PASS='Glimmer7-Enroll-Bloomers'; PROFILE=prd; SMOKE_DEF=0
  : "${EMS_DOCKER_NETWORK:=ems-main_backend}"; : "${EMS_DB_HOST:=ems-database-main_timescaledb}"
else
  PG_PAT='_homolog_'; DB_PASS='Sureness-Stencil9-Flap';  PROFILE=hom; SMOKE_DEF=1
  : "${EMS_DOCKER_NETWORK:=ems-homolog_backend}"; : "${EMS_DB_HOST:=ems-database-homolog_timescaledb}"
fi
export EMS_DOCKER_NETWORK EMS_DB_HOST
EMS_SMOKE="${EMS_SMOKE:-$SMOKE_DEF}"

say(){ printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }
warn(){ printf '\033[1;33m%s\033[0m\n' "$*"; }
have(){ command -v "$1" >/dev/null 2>&1; }
pp(){ if have python3; then python3 -m json.tool 2>/dev/null || cat; else cat; fi; }

# ---- docker: direto ou via sudo -------------------------------------------
_DK=(docker)
if ! docker ps >/dev/null 2>&1; then
  if sudo -n true 2>/dev/null; then _DK=(sudo -n docker)
  elif [ -n "${EMS_SUDO_PASS:-}" ]; then
    printf '%s\n' "$EMS_SUDO_PASS" | sudo -S -p '' -v 2>/dev/null || { echo "sudo recusou a senha (EMS_SUDO_PASS)"; exit 1; }
    _DK=(sudo -n docker)
  else echo "'docker' precisa de sudo e nenhuma senha foi passada (EMS_SUDO_PASS)."; exit 1; fi
fi
dk(){ "${_DK[@]}" "$@"; }

say "0) docker / ambiente"
dk version --format 'client {{.Client.Version}}  server {{.Server.Version}}' || { echo "sem acesso ao docker"; exit 1; }
[ "${_DK[0]}" = sudo ] && echo "(usando 'sudo docker')"
SWARM=$(dk info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null || echo inactive)
echo "EMS_ENV=$EMS_ENV  profile=$PROFILE  swarm=$SWARM  jar=$JAR_VERSION  smoke=$EMS_SMOKE"
have curl || { echo "curl nao encontrado no host"; exit 1; }

say "1) achando o postgres do ambiente ('$PG_PAT' no nome, imagem timescaledb)"
PG_CID=$(dk ps --format '{{.ID}}|{{.Names}}|{{.Image}}' | awk -F'|' -v p="$PG_PAT" 'tolower($3) ~ /timescale\/timescaledb/ && tolower($2) ~ p {print $1; exit}')
if [ -z "$PG_CID" ]; then
  warn "nao achei container timescaledb com '$PG_PAT' no nome. Containers:"
  dk ps --format '  {{.Names}}  [{{.Image}}]'
  echo "passe EMS_DOCKER_NETWORK=<rede> e EMS_DB_HOST=<host-ou-ip> na mao."
  PG_SVC=""; PG_NET="${EMS_DOCKER_NETWORK:-}"; PG_IP=""
else
  PG_NAME=$(dk inspect -f '{{.Name}}' "$PG_CID" | sed 's#^/##')
  PG_SVC=$(dk inspect -f '{{index .Config.Labels "com.docker.swarm.service.name"}}' "$PG_CID" 2>/dev/null || true)
  [ -z "$PG_SVC" ] && PG_SVC=$(printf '%s' "$PG_NAME" | sed 's#\.[0-9].*##')
  PG_NET=$(dk inspect -f '{{range $k,$v := .NetworkSettings.Networks}}{{$k}}{{"\n"}}{{end}}' "$PG_CID" | grep -vx 'ingress' | grep -v '^$' | head -1)
  PG_IP=$(dk inspect -f "{{with index .NetworkSettings.Networks \"$PG_NET\"}}{{.IPAddress}}{{end}}" "$PG_CID")
  echo "  container : $PG_NAME"
  echo "  service   : $PG_SVC"
  echo "  rede      : $PG_NET   (driver: $(dk network inspect "$PG_NET" -f '{{.Driver}}' 2>/dev/null || echo '?'))"
  echo "  IP        : $PG_IP"
fi
NET="${EMS_DOCKER_NETWORK:-$PG_NET}"
[ -n "$NET" ] || { echo "sem rede pro postgres - aborta (passe EMS_DOCKER_NETWORK)"; exit 1; }
DB_HOST="${EMS_DB_HOST:-${PG_SVC:-$PG_IP}}"
[ -n "$DB_HOST" ] || { echo "sem host do banco - aborta (passe EMS_DB_HOST)"; exit 1; }
NET_DRIVER=$(dk network inspect "$NET" -f '{{.Driver}}' 2>/dev/null || echo bridge)
MODE=run; { [ "$NET_DRIVER" = overlay ] && [ "$SWARM" = active ]; } && MODE=service
DB_URL="jdbc:postgresql://${DB_HOST}:5432/energymanagementsystem"
echo "  -> rede=$NET ($NET_DRIVER)  db_host=$DB_HOST  modo=$MODE"
echo "  -> DB_URL=$DB_URL"

say "2) baixando jar $JAR_VERSION (generic package)"
TMP=$(mktemp -d /tmp/ems-gap-filler-test.XXXXXX)
JAR_URL="https://gitlab.com/api/v4/projects/${PROJECT_ID}/packages/generic/ems-gap-filler/${JAR_VERSION}/ems-gap-filler-0.2.0-SNAPSHOT.jar"
curl -fSL -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" -o "$TMP/app.jar" "$JAR_URL"
sz=$(stat -c%s "$TMP/app.jar" 2>/dev/null || stat -f%z "$TMP/app.jar")
echo "  $TMP/app.jar  ($sz bytes)"; [ "$sz" -gt 1000000 ] || { echo "jar invalido (<1MB)"; rm -rf "$TMP"; exit 1; }

say "3) build da imagem local ($LOCAL_IMG) com o jar embutido"
cat > "$TMP/Dockerfile" <<EOF
FROM ${BASE_IMG}
COPY app.jar /app.jar
ENV TZ=America/Manaus
ENTRYPOINT ["java","-Duser.timezone=America/Manaus","-Xms256m","-Xmx512m","-jar","/app.jar"]
EOF
dk build -t "$LOCAL_IMG" "$TMP" >/dev/null
echo "  ok: $LOCAL_IMG"

say "4) (re)criando $NAME (modo $MODE)"
dk rm -f "$NAME" >/dev/null 2>&1 || true            # remove container avulso de run anterior
dk service rm "$NAME" >/dev/null 2>&1 || true       # e service de run anterior
sleep 1
ENVS=( -e SPRING_PROFILES_ACTIVE="$PROFILE" -e DB_URL="$DB_URL" -e DB_USER=ems_user -e DB_PASSWORD="$DB_PASS"
       -e SERVER_PORT=8080 -e GAPFILLER_RECENT_ENABLED=false -e GAPFILLER_HISTORICAL_ENABLED=true -e TZ=America/Manaus )
if [ "$MODE" = service ]; then
  SENVS=(); for ((i=0;i<${#ENVS[@]};i+=2)); do SENVS+=( --env "${ENVS[$((i+1))]}" ); done
  dk service create --name "$NAME" --network "$NET" --replicas 1 \
    --restart-condition on-failure --restart-max-attempts 2 \
    --publish "published=${HOST_PORT},target=8080,mode=host" \
    --no-resolve-image "${SENVS[@]}" "$LOCAL_IMG" >/dev/null
  echo "  service criado. tasks:"; dk service ps "$NAME" --no-trunc 2>/dev/null | sed 's/^/    /' || true
  LOGS=(service logs "$NAME"); RMC=(service rm "$NAME")
else
  dk rm -f "$NAME" >/dev/null 2>&1 || true
  dk run -d --name "$NAME" -p "127.0.0.1:${HOST_PORT}:8080" "${ENVS[@]}" "$LOCAL_IMG" >/dev/null
  dk network connect "$NET" "$NAME" 2>/dev/null && echo "  conectado na rede '$NET'" || warn "  nao conectou em '$NET'"
  LOGS=(logs "$NAME"); RMC=(rm -f "$NAME")
fi

say "5) aguardando /actuator/health UP (timeout 120s)"
ok=0
for i in $(seq 1 60); do
  sleep 2
  st=$(curl -s -m 3 "http://127.0.0.1:${HOST_PORT}/actuator/health" 2>/dev/null || true)
  case "$st" in *'"status":"UP"'*) ok=1; break;; esac
done
if [ "$ok" -ne 1 ]; then
  warn "NAO ficou UP. log:"
  dk "${LOGS[@]}" --tail 120 2>&1 || true
  echo
  warn "deixado de pe pra investigar:"
  echo "  ${_DK[*]} ${LOGS[*]} -f"
  [ "$MODE" = service ] && echo "  ${_DK[*]} service ps $NAME --no-trunc"
  echo "  causa provavel: rede/host do banco -> re-rode com EMS_DOCKER_NETWORK=<rede> EMS_DB_HOST=<host>"
  echo "  pra remover:  ${_DK[*]} ${RMC[*]} ; rm -rf $TMP"
  exit 1
fi
echo "  UP."

# backfill manual (EMS_BACKFILL=1): sensor EMS_BF_SENSOR (default 30), janela [agora-3h, agora-1h] em Manaus.
# Vale pra hom E prd (em prd e o jeito de ver o reconcile contra dado real, controlado).
if [ "${EMS_BACKFILL:-0}" = 1 ]; then
  BFS="${EMS_BF_SENSOR:-30}"
  WS=$(TZ=America/Manaus date -d "${EMS_BF_START:-3 hours ago}" +%Y-%m-%dT%H:%M:00 2>/dev/null || date -u -d "3 hours ago" +%Y-%m-%dT%H:%M:00)
  WE=$(TZ=America/Manaus date -d "${EMS_BF_END:-1 hour ago}"   +%Y-%m-%dT%H:%M:00 2>/dev/null || date -u -d "1 hour ago"   +%Y-%m-%dT%H:%M:00)
  say "6) backfill manual: sensor $BFS, janela $WS .. $WE (Manaus)"
  RESP=$(curl -s -X POST "http://127.0.0.1:${HOST_PORT}/api/v1/backfill" -H 'Content-Type: application/json' \
         -H 'X-Requested-By: server-test' -d "{\"sensorIds\":[$BFS],\"windowStart\":\"$WS\",\"windowEnd\":\"$WE\"}")
  echo "  submit -> $RESP"
  RID=$(printf '%s' "$RESP" | (have python3 && python3 -c 'import sys,json;print(json.load(sys.stdin).get("id",""))' || sed -n 's/.*"id":"\([^"]*\)".*/\1/p'))
  for i in $(seq 1 20); do
    sleep 5; S=$(curl -s "http://127.0.0.1:${HOST_PORT}/api/v1/backfill/$RID" 2>/dev/null || true)
    echo "  poll: $S"
    case "$S" in *'"status":"COMPLETED"'*|*'"status":"FAILED"'*|*'"status":"CANCELLED"'*) break;; esac
  done
elif [ "$EMS_SMOKE" = 1 ] && [ "$EMS_ENV" = hom ]; then
  say "6) smoke-test: POST /api/v1/backfill (sensor 30, janela 1h)"
  WS=$(TZ=America/Manaus date -d "2 hours ago" +%Y-%m-%dT%H:%M:%S 2>/dev/null || date -u -d "2 hours ago" +%Y-%m-%dT%H:%M:%S)
  WE=$(TZ=America/Manaus date -d "1 hour ago"  +%Y-%m-%dT%H:%M:%S 2>/dev/null || date -u -d "1 hour ago"  +%Y-%m-%dT%H:%M:%S)
  RESP=$(curl -s -X POST "http://127.0.0.1:${HOST_PORT}/api/v1/backfill" -H 'Content-Type: application/json' \
         -H 'X-Requested-By: server-test' -d "{\"sensorIds\":[30],\"windowStart\":\"$WS\",\"windowEnd\":\"$WE\"}")
  echo "  submit -> $RESP"
  RID=$(printf '%s' "$RESP" | (have python3 && python3 -c 'import sys,json;print(json.load(sys.stdin).get("id",""))' || sed -n 's/.*"id":"\([^"]*\)".*/\1/p'))
  for i in $(seq 1 18); do
    sleep 5; S=$(curl -s "http://127.0.0.1:${HOST_PORT}/api/v1/backfill/$RID" 2>/dev/null || true)
    echo "  poll: $S"
    case "$S" in *'"status":"COMPLETED"'*|*'"status":"FAILED"'*|*'"status":"CANCELLED"'*) break;; esac
  done
elif [ "$EMS_ENV" = prd ]; then
  say "6) PRD: smoke-test automatico DESLIGADO. Backfill manual quando confiante:"
  echo "  curl -sX POST http://127.0.0.1:${HOST_PORT}/api/v1/backfill -H 'Content-Type: application/json' -H 'X-Requested-By: matheus' -d '{\"sensorIds\":[30],\"windowStart\":\"2026-05-12T08:00:00\",\"windowEnd\":\"2026-05-12T09:00:00\"}'"
fi

say "7) GET /api/v1/report?limit=2000"
curl -s "http://127.0.0.1:${HOST_PORT}/api/v1/report?limit=2000" | pp

say "8) logs (ultimas 60 linhas)"
dk "${LOGS[@]}" --tail 60 2>&1 || true

say "RESUMO"
echo "ambiente=$EMS_ENV  profile=$PROFILE  modo=$MODE  rede=$NET  db_url=$DB_URL  jar=$JAR_VERSION"
echo "$NAME  (porta no host: 127.0.0.1:${HOST_PORT})"
echo "logs ao vivo:   ${_DK[*]} ${LOGS[*]} -f"
echo "report:         curl -s http://127.0.0.1:${HOST_PORT}/api/v1/report?limit=2000 | python3 -m json.tool"
echo "parar/remover:  ${_DK[*]} ${RMC[*]} ; rm -rf $TMP"
if [ "${EMS_KEEP:-1}" = 0 ]; then dk "${RMC[@]}" >/dev/null 2>&1 || true; rm -rf "$TMP"; echo "(removido + tmp limpo - EMS_KEEP=0)"; fi
echo
warn "lembrete: e TESTE (cron OFF). Deploy permanente = scripts/deploy-server.sh"
