#!/bin/bash
# =============================================================================
# reuse_cluster.sh — Apunta retaillm a un cluster EMR YA creado, sin aprovisionar
#                    otro. Solo escribe .emr_state (NO llama a AWS para crear).
#
# Útil si el cluster sigue vivo de una sesión anterior (o lo creó otra persona) y
# quieres usar monitor.sh / hive_shell.sh / pyspark_shell.sh sin gastar en un
# cluster nuevo. El cluster debe seguir ACTIVO (WAITING/RUNNING); los otros
# scripts lo verifican.
#
# Uso:
#   bash scripts/cluster/reuse_cluster.sh --cluster-id j-XXXXXXXX
#   bash scripts/cluster/reuse_cluster.sh --cluster-id j-XXXXXXXX --bucket <b> --region <r>
#
# Flags:
#   --cluster-id <id>   ID del cluster EMR a reutilizar (REQUERIDO)
#   --bucket <b>        bucket de datos (default entrepot-retail-tpcds-20260610)
#   --region <r>        región AWS (default us-east-1)
# =============================================================================
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
STATE_FILE="$ROOT_DIR/.emr_state"

CLUSTER_ID=""
BUCKET="entrepot-retail-tpcds-20260610"
REGION="us-east-1"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cluster-id) CLUSTER_ID="$2"; shift 2 ;;
    --bucket)     BUCKET="$2";     shift 2 ;;
    --region)     REGION="$2";     shift 2 ;;
    -h|--help)    sed -n '2,24p' "$0"; exit 0 ;;
    *) echo "Flag desconocido: $1"; exit 1 ;;
  esac
done

[[ -n "$CLUSTER_ID" ]] || { echo "ERROR: --cluster-id es requerido."; exit 1; }

# ── Respaldar .emr_state si ya existía ───────────────────────────────────────
if [[ -f "$STATE_FILE" ]]; then
  cp "$STATE_FILE" "$STATE_FILE.bak"
  echo "Aviso: .emr_state ya existía → respaldado en .emr_state.bak"
fi

{
  echo "CLUSTER_ID=$CLUSTER_ID"
  echo "BUCKET=$BUCKET"
  echo "REGION=$REGION"
} > "$STATE_FILE"

echo ""
echo "✓ Escrito .emr_state (cluster reutilizado, sin aprovisionar):"
echo "    CLUSTER_ID=$CLUSTER_ID"
echo "    BUCKET=$BUCKET"
echo "    REGION=$REGION"
echo ""
echo "Ahora puedes usar el cluster directamente:"
echo "    bash scripts/measure/monitor.sh --engine hive|spark   # medir"
echo "    bash scripts/shell/hive_shell.sh                      # sesión Hive"
echo "    bash scripts/shell/pyspark_shell.sh                   # sesión pyspark"
echo ""
echo "(El cluster debe seguir ACTIVO; los scripts lo verifican.)"
