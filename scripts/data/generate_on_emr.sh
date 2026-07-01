#!/bin/bash
# =============================================================================
# generate_on_emr.sh — Genera TPC-DS SF10 EN el nodo master del clúster EMR
#                      (alternativa a generate_tpcds.sh cuando ec2:RunInstances
#                      está bloqueado por la política del lab AWS Academy).
#
# Pre-requisito: clúster ya creado con run_emr.sh (deja .emr_state).
#
# Uso:
#   bash scripts/data/generate_on_emr.sh
#   bash scripts/data/generate_on_emr.sh --bucket <b> --scale 10 --parallel 4
#
# Flags:
#   --bucket <b>     bucket S3 destino (default: lee BUCKET de .emr_state)
#   --scale <n>      scale factor (default 10)
#   --parallel <n>   número de children dsdgen (default 4, uno a la vez → menos disco)
#   --region <r>     región AWS (default: lee REGION de .emr_state)
# =============================================================================
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
STATE_FILE="$ROOT_DIR/.emr_state"
SCALE=10
PARALLEL=4
BUCKET=""
REGION=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --bucket)   BUCKET="$2";   shift 2 ;;
    --scale)    SCALE="$2";    shift 2 ;;
    --parallel) PARALLEL="$2"; shift 2 ;;
    --region)   REGION="$2";   shift 2 ;;
    *) shift ;;
  esac
done

[[ -f "$STATE_FILE" ]] || { echo "ERROR: no existe $STATE_FILE — corre run_emr.sh primero."; exit 1; }
_DEST_BUCKET="$BUCKET"   # guarda el --bucket override antes de sourcing
source "$STATE_FILE"     # carga CLUSTER_ID, BUCKET (del cluster original), REGION
# El --bucket de la línea de comandos tiene prioridad sobre el del state file
[[ -n "$_DEST_BUCKET" ]] && BUCKET="$_DEST_BUCKET"
[[ -n "$BUCKET" ]] || { echo "ERROR: pasa --bucket <dest> (p.ej. el bucket SF10)"; exit 1; }
[[ -n "$REGION" ]] || REGION="us-east-1"

echo ""
echo "╔══════════════════════════════════════════════════╗"
echo "║   retaillm — Generación TPC-DS en el master EMR  ║"
echo "╚══════════════════════════════════════════════════╝"
echo "  Cluster  : $CLUSTER_ID"
echo "  Bucket   : s3://$BUCKET/raw/"
echo "  Scale    : SF$SCALE  ·  dsdgen -PARALLEL $PARALLEL (secuencial)"
echo "  Región   : $REGION"
echo ""

STATUS=$(aws emr describe-cluster --cluster-id "$CLUSTER_ID" --region "$REGION" \
  --query 'Cluster.Status.State' --output text)
if [[ "$STATUS" != "WAITING" && "$STATUS" != "RUNNING" ]]; then
  echo "ERROR: cluster $CLUSTER_ID no está activo (estado: $STATUS)"
  exit 1
fi

read -r MASTER_DNS AZ < <(aws emr describe-cluster \
  --cluster-id "$CLUSTER_ID" --region "$REGION" \
  --query 'Cluster.[MasterPublicDnsName, Ec2InstanceAttributes.Ec2AvailabilityZone]' \
  --output text)
MASTER_ID=$(aws emr list-instances --cluster-id "$CLUSTER_ID" --region "$REGION" \
  --instance-group-type MASTER --query 'Instances[0].Ec2InstanceId' --output text)
echo "  Master   : $MASTER_DNS  ($MASTER_ID, $AZ)"

# Abrir puerto 22
MY_IP=$(curl -s https://checkip.amazonaws.com | tr -d '[:space:]')
SG=$(aws emr describe-cluster --cluster-id "$CLUSTER_ID" --region "$REGION" \
  --query 'Cluster.Ec2InstanceAttributes.EmrManagedMasterSecurityGroup' --output text)
aws ec2 authorize-security-group-ingress --region "$REGION" --group-id "$SG" \
  --protocol tcp --port 22 --cidr "${MY_IP}/32" 2>/dev/null \
  && echo "  ✓ Puerto 22 abierto para $MY_IP" \
  || echo "  (regla de puerto 22 ya existía)"

# Clave efímera
TMP_KEY="/tmp/retaillm_gen_emr_$$"
REMOTE_SH="/tmp/retaillm_gen_emr_remote_$$.sh"
rm -f "$TMP_KEY" "${TMP_KEY}.pub" "$REMOTE_SH"
trap 'rm -f "$TMP_KEY" "${TMP_KEY}.pub" "$REMOTE_SH"' EXIT
ssh-keygen -t rsa -b 2048 -f "$TMP_KEY" -N "" -q

SSH_OPTS=(-i "$TMP_KEY" -o StrictHostKeyChecking=no -o ServerAliveInterval=30 -o ConnectTimeout=20)

push_key() {
  aws ec2-instance-connect send-ssh-public-key --region "$REGION" \
    --instance-id "$MASTER_ID" --availability-zone "$AZ" \
    --instance-os-user hadoop --ssh-public-key "file://${TMP_KEY}.pub" \
    --output text --query 'Success' > /dev/null
}

# Script remoto: instala dsdgen, genera tabla-por-tabla con -TABLE (ahorra disco).
# Solo se generan las 5 tablas del DW estrella. Máximo uso en disco: ~1.5 GB por iter.
cat > "$REMOTE_SH" <<REMOTE
#!/bin/bash
set -euo pipefail
BUCKET="\$1"; SCALE="\$2"; PARALLEL="\$3"
DATADIR="/tmp/tpcds-data"
KIT="/tmp/tpcds-kit"
TABLES="customer item store date_dim store_sales"

echo "[gen] disco disponible:"
df -h /tmp 2>/dev/null || df -h /
echo "[gen] instalando toolchain (gcc make flex bison byacc git)..."
sudo dnf -y install gcc make flex bison byacc git >/dev/null 2>&1 \
  || sudo yum -y install gcc make flex bison byacc git >/dev/null 2>&1

echo "[gen] clonando gregrahn/tpcds-kit..."
rm -rf "\$KIT"
git clone --depth 1 https://github.com/gregrahn/tpcds-kit.git "\$KIT" >/dev/null 2>&1

echo "[gen] compilando dsdgen (make OS=LINUX CC con -fcommon)..."
if ! make -C "\$KIT/tools" OS=LINUX CC="gcc -fcommon" > /tmp/make.log 2>&1; then
  echo "[gen] ERROR compilando dsdgen:"; tail -20 /tmp/make.log; exit 1
fi
test -x "\$KIT/tools/dsdgen" || { echo "[gen] ERROR: no existe dsdgen compilado"; exit 1; }
echo "[gen] dsdgen compilado OK"

mkdir -p "\$DATADIR"
cd "\$KIT/tools"

# Para cada tabla y cada child: genera → sube → borra (máx ~1.5 GB en disco a la vez).
for TBL in \$TABLES; do
  for C in \$(seq 1 "\$PARALLEL"); do
    echo ""
    echo "[gen] === \$TBL child \$C / \$PARALLEL ==="
    ./dsdgen -SCALE "\$SCALE" -PARALLEL "\$PARALLEL" -CHILD "\$C" \
             -TABLE "\$TBL" -DIR "\$DATADIR" -FORCE -DELIMITER '|' 2>&1 | tail -3
    for f in "\$DATADIR"/\${TBL}_*.dat; do
      [[ -f "\$f" ]] || continue
      aws s3 cp "\$f" "s3://\$BUCKET/raw/\$TBL/\$(basename \$f)" --only-show-errors
      rm -f "\$f"
    done
    echo "[gen] \$TBL child \$C subido."
  done
done

echo ""
printf 'TPC-DS SF%s generado en EMR master — retaillm\n' "\$SCALE" > /tmp/_SUCCESS
aws s3 cp /tmp/_SUCCESS "s3://\$BUCKET/raw/_SUCCESS" --only-show-errors
echo "[gen] ✓ raw/_SUCCESS escrito."
echo "[gen] Tamaño de las 5 tablas en S3:"
for t in customer item store date_dim store_sales; do
  SZ=\$(aws s3 ls "s3://\$BUCKET/raw/\$t/" --recursive --summarize --human-readable \
         | grep 'Total Size' | awk -F: '{print \$2}' | xargs)
  printf "  %-12s %s\n" "\$t" "\${SZ:-(vacío)}"
done
echo "[gen] LISTO."
REMOTE

echo ""
echo "[ 1/2 ] Subiendo script de generación al master..."
push_key
scp "${SSH_OPTS[@]}" "$REMOTE_SH" "hadoop@$MASTER_DNS:/tmp/gen_on_emr.sh"

echo "[ 2/2 ] Generando SF$SCALE en el master (puede tardar 30-60 min)..."
echo "        ────────────────────────────────────────────────────────"
push_key
ssh "${SSH_OPTS[@]}" "hadoop@$MASTER_DNS" "bash /tmp/gen_on_emr.sh '$BUCKET' '$SCALE' '$PARALLEL'"
echo "        ────────────────────────────────────────────────────────"

echo ""
echo "╔══════════════════════════════════════════════════╗"
echo "║   GENERACIÓN COMPLETA                            ║"
echo "╚══════════════════════════════════════════════════╝"
echo "  s3://$BUCKET/raw/ listo para el benchmark."
echo ""
echo "  Siguiente:"
echo "  bash scripts/measure/monitor.sh --engine hive"
echo "  bash scripts/measure/monitor.sh --engine spark"
