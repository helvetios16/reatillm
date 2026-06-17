#!/bin/bash
# =============================================================================
# run_remote.sh  |  retaillm — Fase 5, backend 'emr' de la Skill 4 (ejecución)
#
# Ejecuta UN SQL en el clúster EMR real y vuelca su stdout. Lo invoca
# agentic/skills/s4_execute.py por subprocess:
#     bash run_remote.sh <hive|spark> "<SQL>"
#
# Reusa el mecanismo SSH probado de scripts/measure/monitor.sh:
#   - lee .emr_state (CLUSTER_ID, BUCKET, REGION) dejado por run_emr.sh
#   - abre el puerto 22 para la IP actual
#   - sube una clave efímera por EC2 Instance Connect (vale ~60s)
#   - corre `hive -e` / `spark-sql -e` en el master (Hive Metastore compartido)
#
# Las 5 tablas existen en el metastore (Fase 2), así que ambos motores las ven
# por nombre sin re-declarar nada. Solo emite a stdout lo que devuelve el motor;
# los diagnósticos van a stderr para no contaminar el parseo en Python.
#
# NOTA (se prueba/afina recién con clúster, en la Fase 4): el formato exacto del
# stdout de hive/spark-sql se valida ahí; hoy queda validado con `bash -n`.
# =============================================================================
set -uo pipefail

log() { echo "$@" >&2; }   # diagnósticos -> stderr

ENGINE="${1:-}"
SQL="${2:-}"
if [[ -z "$ENGINE" || -z "$SQL" ]]; then
  log "uso: run_remote.sh <hive|spark> \"<SQL>\""
  exit 2
fi
case "$ENGINE" in
  hive)  REMOTE_CMD=(hive -S -e "$SQL") ;;
  spark) REMOTE_CMD=(spark-sql -S -e "$SQL") ;;
  *) log "motor inválido: $ENGINE (usa hive|spark)"; exit 2 ;;
esac

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_FILE="$ROOT_DIR/.emr_state"
[[ -f "$STATE_FILE" ]] || { log "ERROR: falta $STATE_FILE (corre scripts/cluster/run_emr.sh)"; exit 1; }
# shellcheck disable=SC1090
source "$STATE_FILE"   # CLUSTER_ID, BUCKET, REGION

STATUS=$(aws emr describe-cluster --cluster-id "$CLUSTER_ID" --region "$REGION" \
  --query 'Cluster.Status.State' --output text 2>/dev/null || echo UNKNOWN)
case "$STATUS" in
  RUNNING|WAITING) ;;
  *) log "ERROR: cluster $CLUSTER_ID no está activo (estado: $STATUS)"; exit 1 ;;
esac

read -r MASTER_DNS AZ < <(aws emr describe-cluster \
  --cluster-id "$CLUSTER_ID" --region "$REGION" \
  --query 'Cluster.[MasterPublicDnsName, Ec2InstanceAttributes.Ec2AvailabilityZone]' \
  --output text)
MASTER_ID=$(aws emr list-instances --cluster-id "$CLUSTER_ID" --region "$REGION" \
  --instance-group-type MASTER --query 'Instances[0].Ec2InstanceId' --output text)
log "  Master: $MASTER_DNS ($MASTER_ID, $AZ)  motor=$ENGINE"

# ── Abrir puerto 22 para la IP actual ────────────────────────────────────────
MY_IP=$(curl -s https://checkip.amazonaws.com | tr -d '[:space:]')
SG=$(aws emr describe-cluster --cluster-id "$CLUSTER_ID" --region "$REGION" \
  --query 'Cluster.Ec2InstanceAttributes.EmrManagedMasterSecurityGroup' --output text)
aws ec2 authorize-security-group-ingress --region "$REGION" --group-id "$SG" \
  --protocol tcp --port 22 --cidr "${MY_IP}/32" >/dev/null 2>&1 \
  && log "  ✓ puerto 22 abierto para $MY_IP" \
  || log "  (regla de puerto 22 ya existía)"

# ── Clave efímera (limpieza garantizada) ─────────────────────────────────────
TMP_KEY="/tmp/retaillm_agent_$$"
rm -f "$TMP_KEY" "${TMP_KEY}.pub"
trap 'rm -f "$TMP_KEY" "${TMP_KEY}.pub"' EXIT
ssh-keygen -t rsa -b 2048 -f "$TMP_KEY" -N "" -q

SSH_OPTS=(-i "$TMP_KEY" -o StrictHostKeyChecking=no -o ServerAliveInterval=30 -o ConnectTimeout=15)

push_key() {
  aws ec2-instance-connect send-ssh-public-key --region "$REGION" \
    --instance-id "$MASTER_ID" --availability-zone "$AZ" \
    --instance-os-user hadoop --ssh-public-key "file://${TMP_KEY}.pub" \
    --output text --query 'Success' > /dev/null
}

# ── Ejecutar el SQL en el master; SOLO el resultado va a stdout ───────────────
log "  Ejecutando consulta en el master..."
push_key
ssh "${SSH_OPTS[@]}" "hadoop@$MASTER_DNS" "${REMOTE_CMD[@]}"
RC=$?
log "  rc=$RC"
exit $RC
