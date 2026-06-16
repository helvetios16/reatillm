#!/bin/bash
# =============================================================================
# connect_generator.sh — SSH a la EC2 generadora (depuración), vía EC2 Instance Connect
#
# Útil si generate_tpcds.sh corrió con --keep y quieres entrar a inspeccionar la
# generación (logs, espacio en disco, reintentar dsdgen a mano). No necesitas key
# pair: se inyecta una clave temporal (60s) y se abre el puerto 22 para tu IP.
#
# Uso:
#   bash scripts/data/connect_generator.sh
#   bash scripts/data/connect_generator.sh --instance-id i-0123... --region us-east-1
# =============================================================================
set -euo pipefail

REGION="us-east-1"
INSTANCE_ID=""
OS_USER="ec2-user"
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

# ── Resolver el ID: flag > estado > búsqueda por tag ──────────────────────────
if [[ -z "$INSTANCE_ID" && -f "$STATE_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$STATE_FILE"
fi
if [[ -z "$INSTANCE_ID" || "$INSTANCE_ID" == "None" ]]; then
  INSTANCE_ID=$(aws ec2 describe-instances --region "$REGION" \
    --filters "Name=tag:Name,Values=$NAME_TAG" \
              "Name=instance-state-name,Values=running" \
    --query 'Reservations[].Instances[].InstanceId' --output text)
fi
if [[ -z "$INSTANCE_ID" || "$INSTANCE_ID" == "None" ]]; then
  echo "ERROR: no hay generador vivo. Lánzalo con:"
  echo "  bash scripts/data/generate_tpcds.sh --bucket <b> --keep"
  exit 1
fi

# ── Datos de la instancia ─────────────────────────────────────────────────────
echo "Obteniendo datos de $INSTANCE_ID..."
read -r STATE PUB_DNS PUB_IP AZ SG < <(aws ec2 describe-instances \
  --region "$REGION" --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].[State.Name,PublicDnsName,PublicIpAddress,Placement.AvailabilityZone,SecurityGroups[0].GroupId]' \
  --output text)
if [[ "$STATE" != "running" ]]; then
  echo "ERROR: la instancia no está 'running' (estado: $STATE)."
  exit 1
fi
HOST="$PUB_DNS"; [[ -z "$HOST" || "$HOST" == "None" ]] && HOST="$PUB_IP"
echo "  Host : $HOST   AZ: $AZ   SG: $SG"

# ── Abrir puerto 22 para tu IP ────────────────────────────────────────────────
MY_IP=$(curl -s https://checkip.amazonaws.com | tr -d '[:space:]')
aws ec2 authorize-security-group-ingress --region "$REGION" --group-id "$SG" \
  --protocol tcp --port 22 --cidr "${MY_IP}/32" 2>/dev/null \
  && echo "  ✓ Puerto 22 abierto para $MY_IP" \
  || echo "  (regla de puerto 22 ya existía)"

# ── Clave temporal (se borra al salir) ────────────────────────────────────────
TMP_KEY="/tmp/retaillm_gen_eic_$$"
rm -f "$TMP_KEY" "${TMP_KEY}.pub"
trap 'rm -f "$TMP_KEY" "${TMP_KEY}.pub"' EXIT
ssh-keygen -t rsa -b 2048 -f "$TMP_KEY" -N "" -q

aws ec2-instance-connect send-ssh-public-key --region "$REGION" \
  --instance-id "$INSTANCE_ID" --availability-zone "$AZ" \
  --instance-os-user "$OS_USER" --ssh-public-key "file://${TMP_KEY}.pub" \
  --output text --query 'Success' > /dev/null

echo ""
echo "  Conectando como $OS_USER@$HOST ..."
echo "  Datos generados en ~/tpcds-data ; kit en ~/tpcds-kit. 'exit' para salir."
echo ""

ssh -i "$TMP_KEY" \
    -o StrictHostKeyChecking=no \
    -o ServerAliveInterval=30 \
    -o ConnectTimeout=15 \
    -t "$OS_USER@$HOST" || true
