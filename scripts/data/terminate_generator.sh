#!/bin/bash
# =============================================================================
# terminate_generator.sh — Termina la EC2 generadora de TPC-DS.
#
# generate_tpcds.sh ya termina la EC2 al acabar (vía trap). Usa este script para
# limpiar manualmente si corriste con --keep, o si el orquestador se interrumpió
# y quedó una instancia viva. Lee el ID de scripts/data/.ec2_state; si no está,
# la busca por su tag Name=retaillm-tpcds-gen.
#
# Uso:
#   bash scripts/data/terminate_generator.sh
#   bash scripts/data/terminate_generator.sh --instance-id i-0123... --region us-east-1
# =============================================================================
set -euo pipefail

REGION="us-east-1"
INSTANCE_ID=""
NAME_TAG="retaillm-tpcds-gen"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
STATE_FILE="$ROOT_DIR/scripts/data/.ec2_state"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --instance-id) INSTANCE_ID="$2"; shift 2 ;;
    --region)      REGION="$2";      shift 2 ;;
    *) shift ;;
  esac
done

if [[ -z "$INSTANCE_ID" && -f "$STATE_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$STATE_FILE"
fi
if [[ -z "$INSTANCE_ID" ]]; then
  echo "No hay ID en flag ni en estado; buscando por tag Name=$NAME_TAG..."
  INSTANCE_ID=$(aws ec2 describe-instances --region "$REGION" \
    --filters "Name=tag:Name,Values=$NAME_TAG" \
              "Name=instance-state-name,Values=pending,running,stopping,stopped" \
    --query 'Reservations[].Instances[].InstanceId' --output text)
fi

if [[ -z "$INSTANCE_ID" || "$INSTANCE_ID" == "None" ]]; then
  echo "No se encontró ningún generador vivo. Nada que terminar."
  rm -f "$STATE_FILE"
  exit 0
fi

echo ""
echo "Terminando instancia(s): $INSTANCE_ID  (región $REGION)"
aws ec2 terminate-instances --region "$REGION" --instance-ids $INSTANCE_ID \
  --query 'TerminatingInstances[].[InstanceId,CurrentState.Name]' --output text

echo "Esperando estado 'terminated'..."
aws ec2 wait instance-terminated --region "$REGION" --instance-ids $INSTANCE_ID

rm -f "$STATE_FILE"
echo ""
echo "✓ Generador terminado y estado limpiado."
echo ""
