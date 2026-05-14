#!/usr/bin/env bash
# =============================================================================
# ems-deploy-prod.sh — DEPLOY PERMANENTE do ems-gap-filler no .112 (Docker Swarm).
#
# Diferença do ems-server-test.sh:
#   - Service name = "ems-gap-filler" (sem o "-test")
#   - GAPFILLER_RECENT_ENABLED=true  (cron sweep das ultimas 24h a cada 15 min ligado)
#   - GAPFILLER_HISTORICAL_ENABLED=true (drena backfill manual via POST /api/v1/backfill)
#   - NAO faz smoke nem backfill automatico - o cron toma conta
#   - Pede confirmacao "PROD" se EMS_ENV=prd
#   - Bind 127.0.0.1 (so docker exec acessa, nada exposto externamente)
#
# Diferença do scripts/deploy-server.sh (legado, host bridge normal):
#   - Aqui SOBE como `docker service` na overlay (.112 e Swarm, ems-main_backend
#     nao e attachable — `docker compose up` falharia).
#   - Baixa o JAR do generic package (versionado), nao builda no host.
#
# USO (no .112):
#   sudo -v
#   T='glpat-...'
#   curl -s "https://gitlab.com/api/v4/projects/81970992/repository/files/scripts%2Fems-deploy-prod.sh/raw?ref=main&private_token=$T" -o /tmp/deploy-prod.sh
#   EMS_ENV=prd bash /tmp/deploy-prod.sh
#
# Variaveis:
#   EMS_ENV=hom|prd          (default hom — exige confirmacao 'PROD' se =prd)
#   EMS_JAR_VERSION          (default 0.2.0-r6 — versao validada em PRD em 13/05/2026)
#   GITLAB_TOKEN             (obrigatorio pra baixar o JAR do generic package)
#   EMS_SUDO_PASS            (senha sudo, se 'docker' precisar; ou $1 posicional)
#   EMS_RECENT_ENABLED       (default true — sweep automatico das ultimas 24h)
#   EMS_HOST_PORT            (default 18080 — porta 127.0.0.1, so pra docker exec)
# =============================================================================
set -euo pipefail

if [ -n "${1:-}" ]; then EMS_SUDO_PASS="$1"; fi

PROJECT_ID=81970992
EMS_ENV="${EMS_ENV:-hom}"
JAR_VERSION="${EMS_JAR_VERSION:-0.2.0-r6}"
RECENT_ENABLED="${EMS_RECENT_ENABLED:-true}"
HOST_PORT="${EMS_HOST_PORT:-18080}"
NAME="ems-gap-filler"   # nome FINAL (sem -test)
BASE_IMG="${EMS_JRE_IMG:-eclipse-temurin:21-jre}"
LOCAL_IMG="ems-gap-filler:$JAR_VERSION"
GITLAB_TOKEN="${GITLAB_TOKEN:-glpat-1KBJACUAPmj8f3V1ivdBLmM6MQpvOjEKdTptbDV2aQ8.01.1706sk2g4}"

if [ "$EMS_ENV" = prd ]; then
  DB_PASS='Glimmer7-Enroll-Bloomers'; PROFILE=prd
  : "${EMS_DOCKER_NETWORK:=ems-main_backend}"
  : "${EMS_DB_HOST:=ems-database-main_timescaledb}"
else
  DB_PASS='Sureness-Stencil9-Flap';  PROFILE=hom
  : "${EMS_DOCKER_NETWORK:=ems-homolog_backend}"
  : "${EMS_DB_HOST:=ems-database-homolog_timescaledb}"
fi
DB_URL="jdbc:postgresql://${EMS_DB_HOST}:5432/energymanagementsystem"

say(){ printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }
warn(){ printf '\033[1;33m%s\033[0m\n' "$*"; }
err(){ printf '\033[1;31m%s\033[0m\n' "$*"; }

# ---- confirmacao "PROD" se for prd ------------------------------------------
if [ "$EMS_ENV" = prd ]; then
  warn ""
  warn "##################################################################"
  warn "# DEPLOY PERMANENTE em PRODUCAO                                  #"
  warn "#   service: $NAME                                                #"
  warn "#   jar:     $JAR_VERSION                                         #"
  warn "#   db:      $EMS_DB_HOST (energymanagementsystem)                #"
  warn "#   rede:    $EMS_DOCKER_NETWORK                                  #"
  warn "#   recent:  $RECENT_ENABLED  (sweep automatico a cada 15min)     #"
  warn "##################################################################"
  read -r -p "Confirme digitando 'PROD' [Ctrl+C cancela]: " CONFIRM
  if [ "$CONFIRM" != "PROD" ]; then err "Cancelado."; exit 1; fi
fi

# ---- docker (direto ou sudo) ------------------------------------------------
_DK=(docker)
if ! docker ps >/dev/null 2>&1; then
  if sudo -n true 2>/dev/null; then _DK=(sudo -n docker)
  elif [ -n "${EMS_SUDO_PASS:-}" ]; then
    printf '%s\n' "$EMS_SUDO_PASS" | sudo -S -p '' -v 2>/dev/null || { err "sudo recusou EMS_SUDO_PASS"; exit 1; }
    _DK=(sudo -n docker)
  else err "'docker' precisa de sudo. roda 'sudo -v' antes ou passa a senha como \$1."; exit 1; fi
fi
dk(){ "${_DK[@]}" "$@"; }

say "[0] ambiente"
dk version --format 'client {{.Client.Version}}  server {{.Server.Version}}'
SWARM=$(dk info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null || echo inactive)
echo "env=$EMS_ENV  profile=$PROFILE  jar=$JAR_VERSION  recent=$RECENT_ENABLED  swarm=$SWARM"
[ "$SWARM" = active ] || { err "Swarm nao ativo no host - este script eh feito pra Swarm."; exit 1; }

# ---- backup do estado anterior (se houver) ---------------------------------
if dk service ls --format '{{.Name}}' | grep -qx "$NAME"; then
  PREV_IMG=$(dk service inspect "$NAME" -f '{{(index .Spec.TaskTemplate.ContainerSpec.Image)}}' 2>/dev/null || echo '<desconhecido>')
  warn "[i] service '$NAME' JA EXISTE (imagem=$PREV_IMG) — vai ser RECRIADO com a nova imagem."
  warn "    Pra reverter: dk service update --image '$PREV_IMG' '$NAME'   (ou: dk service rm '$NAME')"
fi

say "[1] baixando JAR $JAR_VERSION do generic package"
TMP=$(mktemp -d /tmp/ems-deploy-prod.XXXXXX)
JAR_URL="https://gitlab.com/api/v4/projects/${PROJECT_ID}/packages/generic/ems-gap-filler/${JAR_VERSION}/ems-gap-filler-0.2.0-SNAPSHOT.jar"
curl -fSL -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" -o "$TMP/app.jar" "$JAR_URL"
SZ=$(stat -c%s "$TMP/app.jar" 2>/dev/null || stat -f%z "$TMP/app.jar")
[ "$SZ" -gt 1000000 ] || { err "JAR invalido (<1MB)"; rm -rf "$TMP"; exit 1; }
echo "  $TMP/app.jar  ($SZ bytes)"

say "[2] build imagem local $LOCAL_IMG"
cat > "$TMP/Dockerfile" <<EOF
FROM ${BASE_IMG}
COPY app.jar /app.jar
ENV TZ=America/Manaus
ENTRYPOINT ["java","-Duser.timezone=America/Manaus","-XX:MaxRAMPercentage=75.0","-jar","/app.jar"]
EOF
dk build -t "$LOCAL_IMG" "$TMP" >/dev/null
echo "  ok: $LOCAL_IMG"

say "[3] criar/atualizar service $NAME"
if dk service ls --format '{{.Name}}' | grep -qx "$NAME"; then
  # update in-place (zero-downtime se replicas>1; com 1 replica derruba e sobe a nova)
  dk service update --force \
    --image "$LOCAL_IMG" \
    --env-add SPRING_PROFILES_ACTIVE="$PROFILE" \
    --env-add DB_URL="$DB_URL" \
    --env-add DB_USER=ems_user \
    --env-add DB_PASSWORD="$DB_PASS" \
    --env-add SERVER_PORT=8080 \
    --env-add GAPFILLER_RECENT_ENABLED="$RECENT_ENABLED" \
    --env-add GAPFILLER_HISTORICAL_ENABLED=true \
    --env-add TZ=America/Manaus \
    "$NAME" >/dev/null
  echo "  service atualizado"
else
  dk service create --name "$NAME" \
    --network "$EMS_DOCKER_NETWORK" \
    --replicas 1 \
    --restart-condition on-failure --restart-max-attempts 3 \
    --publish "published=${HOST_PORT},target=8080,mode=host" \
    --limit-cpu 1.0 --limit-memory 768M \
    --reserve-cpu 0.25 --reserve-memory 256M \
    --no-resolve-image \
    --env SPRING_PROFILES_ACTIVE="$PROFILE" \
    --env DB_URL="$DB_URL" \
    --env DB_USER=ems_user \
    --env DB_PASSWORD="$DB_PASS" \
    --env SERVER_PORT=8080 \
    --env GAPFILLER_RECENT_ENABLED="$RECENT_ENABLED" \
    --env GAPFILLER_HISTORICAL_ENABLED=true \
    --env TZ=America/Manaus \
    "$LOCAL_IMG" >/dev/null
  echo "  service criado"
fi
sleep 2
dk service ps "$NAME" --no-trunc 2>/dev/null | sed 's/^/    /'

say "[4] aguardando /actuator/health UP (timeout 180s)"
ok=0
for i in $(seq 1 90); do
  sleep 2
  st=$(curl -s -m 3 "http://127.0.0.1:${HOST_PORT}/actuator/health" 2>/dev/null || true)
  case "$st" in *'"status":"UP"'*) ok=1; break;; esac
done
if [ "$ok" -ne 1 ]; then
  err "NAO ficou UP em 180s. logs:"
  dk service logs --tail 120 "$NAME" 2>&1 || true
  err "service deixado de pe pra investigar:  dk service ps $NAME --no-trunc  /  dk service logs -f $NAME"
  exit 1
fi
echo "  UP (em $((i*2))s)"

say "[5] resumo"
echo "  service    : $NAME"
echo "  imagem     : $LOCAL_IMG  (jar 0.2.0-r6)"
echo "  rede       : $EMS_DOCKER_NETWORK"
echo "  db         : $EMS_DB_HOST"
echo "  profile    : $PROFILE"
echo "  recent     : $RECENT_ENABLED"
echo "  porta local: 127.0.0.1:${HOST_PORT}  (so docker exec via overlay tambem)"
echo
echo "  logs:    ${_DK[*]} service logs -f $NAME"
echo "  health:  curl -s http://127.0.0.1:${HOST_PORT}/actuator/health"
echo "  report:  curl -s http://127.0.0.1:${HOST_PORT}/api/v1/report | python3 -m json.tool"
echo "  backfill manual:"
echo "    curl -sX POST http://127.0.0.1:${HOST_PORT}/api/v1/backfill \\"
echo "      -H 'Content-Type: application/json' -H 'X-Requested-By: admin' \\"
echo "      -d '{\"sensorIds\":[30],\"windowStart\":\"2026-05-13T08:00:00\",\"windowEnd\":\"2026-05-13T10:00:00\"}'"
echo
echo "  PARAR:    ${_DK[*]} service rm $NAME"
echo "  REVERTER imagem: ${_DK[*]} service update --image '<imagem-antiga>' $NAME"

rm -rf "$TMP"

if [ "$RECENT_ENABLED" = true ]; then
  warn ""
  warn "[!] cron RECENT ON: o primeiro sweep das ultimas 24h roda em ate 15 min (cron '0 5/15 * * * *')."
  warn "    Acompanhe com:  ${_DK[*]} service logs -f $NAME | grep -E 'reconcile|substituido|softDelete|refresh'"
fi
