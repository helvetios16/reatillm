#!/bin/bash
# =============================================================================
# cleanup.sh — Termina el cluster EMR de retaillm y borra SOLO lo que generó el
#              proyecto. PRESERVA el bucket y los datos TPC-DS (raw/ — generarlos
#              de nuevo cuesta tiempo y una EC2).
#
# Borra: cluster EMR + s3://<bucket>/{ddl,hql,spark,logs}/ + locales (.emr_state).
# NO borra: el bucket ni raw/ (los 10 GB de datos TPC-DS).
#
# Uso:
#   bash scripts/cluster/cleanup.sh                  # lee .emr_state
#   bash scripts/cluster/cleanup.sh --bucket <b>
#   bash scripts/cluster/cleanup.sh --keep-results   # no borra results/ local
# =============================================================================
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
STATE_FILE="$ROOT_DIR/.emr_state"

BUCKET=""
REGION="us-east-1"
CLUSTER_ID=""
KEEP_RESULTS=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --bucket)       BUCKET="$2"; shift 2 ;;
    --region)       REGION="$2"; shift 2 ;;
    --keep-results) KEEP_RESULTS=1; shift ;;
    *) shift ;;
  esac
done

if [[ -z "$BUCKET" ]] && [[ -f "$STATE_FILE" ]]; then
  source "$STATE_FILE"
  echo "  Leído desde .emr_state:"
  echo "    BUCKET=$BUCKET  |  REGION=$REGION  |  CLUSTER_ID=${CLUSTER_ID:-no guardado}"
elif [[ -z "$BUCKET" ]]; then
  echo "Uso: bash scripts/cluster/cleanup.sh --bucket <nombre-bucket>"
  echo "     (o ejecuta run_emr.sh primero para generar .emr_state)"
  exit 1
fi

echo ""
echo "╔══════════════════════════════════════════════════╗"
echo "║   Limpieza retaillm — PRESERVA bucket + datos    ║"
echo "╚══════════════════════════════════════════════════╝"
echo "  Cluster EMR : ${CLUSTER_ID:-buscar activos}"
echo "  Se borrará  : s3://$BUCKET/{ddl,hql,spark,logs}/  +  .emr_state local"
echo "  Se CONSERVA : el bucket + raw/ (los 10 GB de TPC-DS)"
echo ""
read -r -p "  ¿Continuar? [s/N] " confirm
[[ "$confirm" =~ ^[sS]$ ]] || { echo "Cancelado."; exit 0; }
echo ""

# ── 1. Terminar cluster EMR ───────────────────────────────────────────────────
echo "[ 1/3 ] Terminando cluster EMR..."
if [[ -n "${CLUSTER_ID:-}" ]]; then
  STATUS=$(aws emr describe-cluster \
    --cluster-id "$CLUSTER_ID" --region "$REGION" \
    --query 'Cluster.Status.State' --output text 2>/dev/null || echo "NOT_FOUND")
  if [[ "$STATUS" == "TERMINATED" || "$STATUS" == "TERMINATED_WITH_ERRORS" || "$STATUS" == "NOT_FOUND" ]]; then
    echo "        Cluster $CLUSTER_ID ya estaba terminado ($STATUS)."
  else
    aws emr terminate-clusters --cluster-ids "$CLUSTER_ID" --region "$REGION"
    echo "        ✓ Cluster $CLUSTER_ID terminado."
  fi
else
  ACTIVE=$(aws emr list-clusters --region "$REGION" --active \
    --query "Clusters[?Name=='retaillm-Hive-Spark'].Id" \
    --output text 2>/dev/null || echo "")
  if [[ -n "$ACTIVE" ]]; then
    aws emr terminate-clusters --cluster-ids $ACTIVE --region "$REGION"
    echo "        ✓ Clusters terminados: $ACTIVE"
  else
    echo "        No se encontraron clusters activos."
  fi
fi

# ── 2. Borrar SOLO los artefactos generados (no los datos raw/) ───────────────
echo ""
echo "[ 2/3 ] Borrando artefactos en S3 (conservando raw/)..."
for prefix in ddl hql spark logs; do
  if aws s3 ls "s3://$BUCKET/$prefix/" >/dev/null 2>&1; then
    aws s3 rm "s3://$BUCKET/$prefix/" --recursive >/dev/null
    echo "        ✓ s3://$BUCKET/$prefix/ borrado."
  else
    echo "        (s3://$BUCKET/$prefix/ no existe)"
  fi
done

# ── 3. Limpiar archivos locales ───────────────────────────────────────────────
echo ""
echo "[ 3/3 ] Limpiando archivos locales..."
rm -f "$STATE_FILE" "$STATE_FILE.bak"
echo "        ✓ .emr_state eliminado."
if [[ $KEEP_RESULTS -eq 0 ]]; then
  echo "        (results/ se conserva por defecto; usa rm -rf results/* para borrar mediciones)"
fi

echo ""
echo "╔══════════════════════════════════════════════════╗"
echo "║   Limpieza completada (datos TPC-DS preservados) ║"
echo "╚══════════════════════════════════════════════════╝"
