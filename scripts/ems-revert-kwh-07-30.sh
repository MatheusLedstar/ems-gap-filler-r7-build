#!/usr/bin/env bash
# =============================================================================
# ems-revert-kwh-07-30.sh — REVERT manual da leitura KWH errada que o worker
# inseriu em prod em 2026-05-13 07:30 (escala raw 1.577e14, antes do fix r6).
#
# Em prod 13/05/2026 o run 3091048a-c970-4ab6-86da-d8978e89116d detectou
# NON_MONOTONIC no sensor 30 valuetype KWH creation 2026-05-13T07:30 e fez:
#   1) softDelete da linha original (valor ~1.577e8, escala correta MWh)
#   2) insertBatch com a leitura do CSV (~1.577e14, escala RAW do gateway)
#      -> ISSO QUEBROU A ESCALA da curva.
#
# Este script faz o oposto: inativa o INSERT errado e reativa o original.
# DRY-RUN por padrao (mostra o SELECT antes). Pra aplicar: passa --apply.
#
# Uso no .112:
#   bash /tmp/ems-revert-kwh-07-30.sh           # dry-run, so SELECT
#   bash /tmp/ems-revert-kwh-07-30.sh --apply   # roda os UPDATEs
# =============================================================================
set -euo pipefail

APPLY=0
if [ "${1:-}" = "--apply" ]; then APPLY=1; fi

_DK=(docker)
if ! docker ps >/dev/null 2>&1; then
  if sudo -n true 2>/dev/null; then _DK=(sudo -n docker)
  else echo "precisa de sudo. roda 'sudo -v' antes."; exit 1; fi
fi
dk(){ "${_DK[@]}" "$@"; }

PG_CID=$(dk ps --format '{{.ID}}|{{.Names}}|{{.Image}}' \
  | awk -F'|' 'tolower($3) ~ /timescale/ && tolower($2) ~ /ems-database-main_/ {print $1; exit}')
[ -n "$PG_CID" ] || { echo "nao achei o postgres do main"; exit 1; }
echo "PG_CID=$PG_CID  ($(dk inspect -f '{{.Name}}' "$PG_CID" | sed 's#^/##'))"

pg(){ dk exec -i "$PG_CID" psql -U ems_user -d energymanagementsystem -P pager=off -c "$1"; }

echo
echo "==[1]== As 2 linhas em (sensor=30, valuetype=KWH, creation=2026-05-13 07:30:00):"
pg "SELECT sdr_id, sdr_value, sdr_active,
           to_char(sdr_creation,'YYYY-MM-DD HH24:MI:SS') creation,
           to_char(sdr_last_updated,'YYYY-MM-DD HH24:MI:SS') last_updated
      FROM mqtt.sensordatarecord
     WHERE sdr_sensor=30 AND sdr_valuetype='KWH'
       AND sdr_creation='2026-05-13 07:30:00'
     ORDER BY sdr_id;"

echo
echo "==[2]== Esperado:"
echo "  - 1 linha com sdr_active=false e sdr_value ~1.577e8   (escala MWh, original — re-ATIVAR)"
echo "  - 1 linha com sdr_active=true  e sdr_value ~1.577e14  (escala RAW, inserida pelo worker — INATIVAR)"

if [ "$APPLY" -ne 1 ]; then
  echo
  echo "==[DRY-RUN]== Pra aplicar:  bash $0 --apply"
  exit 0
fi

echo
echo "==[3]== Aplicando UPDATEs (transacao atomica)..."
# A 'linha errada': sdr_value > 1e10 E sdr_active=true (a que entrou pelo worker)
# A 'linha boa'  : sdr_value < 1e10 E sdr_active=false (a soft-deletada original)
pg "BEGIN;
UPDATE mqtt.sensordatarecord
   SET sdr_active = false, sdr_last_updated = now()
 WHERE sdr_sensor=30 AND sdr_valuetype='KWH'
   AND sdr_creation='2026-05-13 07:30:00'
   AND sdr_active=true AND sdr_value > 1e10;

UPDATE mqtt.sensordatarecord
   SET sdr_active = true, sdr_last_updated = now()
 WHERE sdr_sensor=30 AND sdr_valuetype='KWH'
   AND sdr_creation='2026-05-13 07:30:00'
   AND sdr_active=false AND sdr_value < 1e10;
COMMIT;"

echo
echo "==[4]== Confere o estado pos-revert:"
pg "SELECT sdr_id, sdr_value, sdr_active,
           to_char(sdr_last_updated,'YYYY-MM-DD HH24:MI:SS') last_updated
      FROM mqtt.sensordatarecord
     WHERE sdr_sensor=30 AND sdr_valuetype='KWH'
       AND sdr_creation='2026-05-13 07:30:00'
     ORDER BY sdr_id;"

echo
echo "==[5]== Refresh CAG mqtt.sdr_hourly pra janela afetada:"
pg "CALL refresh_continuous_aggregate('mqtt.sdr_hourly', TIMESTAMP '2026-05-13 07:00:00', TIMESTAMP '2026-05-13 08:00:00');"

echo
echo "OK — leitura errada do worker invertida, curva restaurada, CAG atualizado."
