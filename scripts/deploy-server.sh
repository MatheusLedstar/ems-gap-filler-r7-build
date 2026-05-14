#!/usr/bin/env bash
# =============================================================================
# DEPLOY-SERVER.SH - deploy do ems-gap-filler como CONTAINER no servidor 150.150.251.112
#
# QUEM EXECUTA: alguem com acesso ao docker no servidor (root OU user no grupo `docker`).
#               Sobe um container dedicado pro worker - nao mexe em nenhum container existente.
#
# Como usar (no servidor 150.150.251.112):
#
#   # 1) baixar este script + o docker-compose.yml + o .env.example
#   T='glpat-...'
#   B="https://gitlab.com/api/v4/projects/81970992/repository/files"
#   mkdir -p ~/ems-gap-filler && cd ~/ems-gap-filler
#   for f in scripts%2Fdeploy-server.sh docker-compose.yml .env.example Dockerfile ; do
#     curl -fsSL -H "PRIVATE-TOKEN: $T" "$B/$f/raw?ref=main" -o "$(basename ${f//\%2F//})"
#   done
#   # (ou: git clone https://oauth2:$T@gitlab.com/ems5833927/ems-gap-filler.git . )
#
#   # 2) descobrir a rede docker do postgres do ambiente:
#   docker ps                                                   # acha o container do timescaledb
#   docker inspect <pg-container> -f '{{json .NetworkSettings.Networks}}'
#
#   # 3) configurar o .env (COMECAR PELA HOM):
#   cp .env.example .env && nano .env
#     #   SPRING_PROFILES_ACTIVE=hom
#     #   DB_URL=jdbc:postgresql://172.25.0.3:5432/energymanagementsystem   (HOM)
#     #   DB_PASSWORD=Sureness-Stencil9-Flap                                 (HOM)
#     #   EMS_DOCKER_NETWORK=<a rede do passo 2>
#     #   GAPFILLER_RECENT_ENABLED=false       (cron OFF ate validar)
#
#   # 4) rodar:
#   INSTALL_DIR="$PWD" bash deploy-server.sh        # (ou: sudo bash deploy-server.sh, se preferir /opt)
#
# Pra ir pra PROD depois (so apos validar a HOM):
#   editar o .env -> SPRING_PROFILES_ACTIVE=prd, DB_URL ...172.25.0.7..., DB_PASSWORD=Glimmer7-Enroll-Bloomers,
#   EMS_DOCKER_NETWORK=<rede de PRD, se diferente> -> rodar de novo (o script pede confirmacao "PROD").
#
# SEGURANCAS:
#   - Container DEDICADO (ems-gap-filler), nao toca em nenhum container/stack existente
#   - Junta na rede docker do ambiente (EMS_DOCKER_NETWORK) so pra alcancar o postgres por IP
#   - Default profile = 'hom' (172.25.0.3 - banco vazio do worker; sem o schema do app EMS)
#   - GAPFILLER_RECENT_ENABLED=false por padrao (sweep RECENT OFF; ligar so apos validacao manual)
#   - GAPFILLER_HISTORICAL_ENABLED=true por padrao (fila de backfill drena); =false deixa o worker
#     inerte (so Flyway no schema 'ems' + API), sem tocar em telemetria
#   - Migration V76 (FK ftp_source->sensor) e CONDICIONAL: cria a FK so se ems.sensor existir
#     (no PRD existe; no HOM vazio vira no-op com NOTICE) - nunca falha a migration
#   - Limites: 1 CPU + 768MB RAM; healthcheck + auto-restart; bind 127.0.0.1 (so docker exec acessa)
# =============================================================================

set -euo pipefail

# ---- CONFIG -----------------------------------------------------------------
GITLAB_PROJECT_ID="${GITLAB_PROJECT_ID:-81970992}"
GITLAB_TOKEN="${GITLAB_TOKEN:-}"
# INSTALL_DIR: onde o repo/compose/.env ficam. Default /opt (precisa root); use INSTALL_DIR=$PWD se nao for root.
INSTALL_DIR="${INSTALL_DIR:-/opt/ems-gap-filler}"
ENV_FILE="${ENV_FILE:-${INSTALL_DIR}/.env}"
COMPOSE_FILE="${INSTALL_DIR}/docker-compose.yml"
# -----------------------------------------------------------------------------

log() { printf "[%s] %s\n" "$(date +'%H:%M:%S')" "$*"; }
fail() { log "ERRO: $*"; exit 1; }

# ---- 1) Verificar acesso ao docker -----------------------------------------
if ! command -v docker >/dev/null 2>&1; then
  fail "docker nao encontrado no PATH."
fi
if ! docker info >/dev/null 2>&1; then
  fail "sem acesso ao docker daemon. Rode como root (sudo) ou adicione seu user ao grupo 'docker'."
fi
if ! docker compose version >/dev/null 2>&1; then
  fail "Docker Compose v2 nao disponivel. Instalar 'docker-compose-plugin'."
fi
log "Docker: $(docker --version)  |  $(docker compose version | head -1)"

# ---- 1.5) Diagnostico das redes (pra ajudar a achar a EMS_DOCKER_NETWORK) --
log "Redes docker disponiveis:"
docker network ls --format '  {{.Name}}  (driver={{.Driver}}, scope={{.Scope}})' || true
PG_CANDIDATES=$(docker ps --format '{{.Names}} {{.Image}}' | grep -iE 'timescale|postgres' || true)
if [ -n "$PG_CANDIDATES" ]; then
  log "Containers de banco em execucao (e suas redes):"
  echo "$PG_CANDIDATES" | awk '{print $1}' | while read -r c; do
    nets=$(docker inspect "$c" -f '{{range $k,$v := .NetworkSettings.Networks}}{{$k}}({{$v.IPAddress}}) {{end}}' 2>/dev/null || true)
    log "  $c -> $nets"
  done
  log "=> seta EMS_DOCKER_NETWORK no .env pra rede do postgres do ambiente que vc quer (HOM primeiro)."
else
  log "(nenhum container timescale/postgres visivel - confirme com 'docker ps -a')"
fi

# ---- 2) Clonar/atualizar repo (precisa do repo COMPLETO - o `docker compose build` usa src/) -----
mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"

if [ -d ".git" ]; then
  log "Atualizando repo existente em $INSTALL_DIR..."
  git pull --ff-only origin main
elif [ -z "$(ls -A . 2>/dev/null)" ]; then
  log "Clonando repo em $INSTALL_DIR..."
  if [ -n "$GITLAB_TOKEN" ]; then
    git clone "https://oauth2:$GITLAB_TOKEN@gitlab.com/ems5833927/ems-gap-filler.git" .
  else
    git clone "https://gitlab.com/ems5833927/ems-gap-filler.git" .
  fi
else
  fail "$INSTALL_DIR nao e um repo git e nao esta vazio. Use um diretorio vazio (INSTALL_DIR=...) ou faca 'git clone https://oauth2:\$GITLAB_TOKEN@gitlab.com/ems5833927/ems-gap-filler.git $INSTALL_DIR' voce mesmo antes de rodar."
fi

# ---- 3) Verificar .env -----------------------------------------------------
if [ ! -f "$ENV_FILE" ]; then
  log ".env nao encontrado em $ENV_FILE - copiando de .env.example"
  cp .env.example "$ENV_FILE"
  chmod 600 "$ENV_FILE"
  log ""
  log "############################################################"
  log "# AJUSTE $ENV_FILE ANTES DE PROSSEGUIR!                    #"
  log "# Especialmente: SPRING_PROFILES_ACTIVE, DB_PASSWORD       #"
  log "############################################################"
  log ""
  read -r -p "Pressione ENTER para abrir $ENV_FILE no editor (ou Ctrl+C pra cancelar) "
  ${EDITOR:-nano} "$ENV_FILE"
fi

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

# ---- 4) Validar profile + IP do banco --------------------------------------
PROFILE="${SPRING_PROFILES_ACTIVE:-hom}"
log "SPRING_PROFILES_ACTIVE = $PROFILE"

if [ "$PROFILE" = "prd" ]; then
  if [[ "${DB_URL:-}" != *"172.25.0.7"* ]]; then
    fail "PROD profile exige DB_URL apontando pra 172.25.0.7 (PRD). Atual: $DB_URL"
  fi
  read -r -p "ATENCAO: deploy em PRODUCAO. Confirme digitando 'PROD' [Ctrl+C pra cancelar]: " CONFIRM
  if [ "$CONFIRM" != "PROD" ]; then
    fail "Cancelado."
  fi
fi

# ---- 5) Build da imagem ----------------------------------------------------
# Precisa de internet (puxa as imagens base maven:3.9-eclipse-temurin-21 e eclipse-temurin:21-jre-alpine
# + deps Maven). Se o servidor for sem internet: builde a imagem noutra maquina, `docker save` -> `docker load` aqui.
log "Building imagem ems-gap-filler:0.2.0 (~3min na 1a vez, depois cache)..."
docker compose -f "$COMPOSE_FILE" build

# ---- 6) Sondar conectividade com o banco a partir do HOST (informativo) ----
# OBS: o que importa e o CONTAINER (na rede EMS_DOCKER_NETWORK) alcancar o DB; o host pode nao
# alcancar o IP de overlay e isso e ok. Aqui so avisamos - quem manda e o healthcheck do container.
DB_HOST=$(echo "${DB_URL}" | sed -E 's|jdbc:postgresql://([^:/]+).*|\1|')
DB_PORT=$(echo "${DB_URL}" | sed -E 's|jdbc:postgresql://[^:]+:([0-9]+).*|\1|')
if timeout 5 bash -c "echo > /dev/tcp/${DB_HOST}/${DB_PORT}" 2>/dev/null; then
  log "conectividade host -> ${DB_HOST}:${DB_PORT} OK"
else
  log "AVISO: host nao alcancou ${DB_HOST}:${DB_PORT} via TCP (pode ser normal p/ IP de overlay)."
  log "       Se o container nao ficar healthy, confira EMS_DOCKER_NETWORK e o DB_URL (use o nome"
  log "       do container do postgres, ex jdbc:postgresql://timescaledb:5432/..., se o IP nao colar)."
fi

# ---- 7) Subir container -----------------------------------------------------
log "Subindo container ems-gap-filler na rede '${EMS_DOCKER_NETWORK:-docker_gwbridge}'..."
docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" up -d

# ---- 8) Aguardar health UP --------------------------------------------------
log "Aguardando /actuator/health (timeout 3min)..."
HEALTHY=0
for i in $(seq 1 90); do
  STATUS=$(docker inspect --format='{{.State.Health.Status}}' ems-gap-filler 2>/dev/null || echo "starting")
  if [ "$STATUS" = "healthy" ]; then
    HEALTHY=1
    break
  fi
  sleep 2
done

if [ "$HEALTHY" = "1" ]; then
  log "Container HEALTHY"
else
  log "Container NAO ficou healthy em 3min. Veja os logs:"
  docker compose -f "$COMPOSE_FILE" logs --tail=100 ems-gap-filler
  fail "Deploy falhou no health check"
fi

# ---- 9) Resumo --------------------------------------------------------------
log ""
log "===================================================="
log "  DEPLOY OK"
log "===================================================="
log "  Profile:         $PROFILE"
log "  DB:              $DB_HOST:$DB_PORT"
log "  Rede docker:     ${EMS_DOCKER_NETWORK:-docker_gwbridge}"
log "  RECENT cron:     ${GAPFILLER_RECENT_ENABLED:-false}  (15 em 15 min se true)"
log "  HISTORICAL fila: ${GAPFILLER_HISTORICAL_ENABLED:-true}"
log ""
log "  Logs:       docker logs -f ems-gap-filler"
log "  Health:     docker exec ems-gap-filler curl -s http://127.0.0.1:8080/actuator/health"
log "  Report:     docker exec ems-gap-filler curl -s http://127.0.0.1:8080/api/v1/report"
log "  Backfill:   docker exec ems-gap-filler curl -sX POST http://127.0.0.1:8080/api/v1/backfill \\"
log "                  -H 'Content-Type: application/json' -H 'X-Requested-By: admin' \\"
log "                  -d '{\"sensorIds\":[30],\"windowStart\":\"2026-05-08T00:00:00\",\"windowEnd\":\"2026-05-08T01:00:00\"}'"
log "  Status bf:  docker exec ems-gap-filler curl -s http://127.0.0.1:8080/api/v1/backfill/<id>"
log "  Stop:       docker compose -f $COMPOSE_FILE down   (ou: docker rm -f ems-gap-filler)"
log "===================================================="
