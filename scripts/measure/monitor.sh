#!/bin/bash
# =============================================================================
# monitor.sh — Corre las 9 consultas en el MASTER MIDIENDO el consumo
#              (snapshots tipo htop, AUTOMÁTICOS), para Hive O Spark.
#
# Generaliza el monitor.sh de sparky (que solo medía spark-submit) con
# --engine hive|spark. El armazón es idéntico: lanza un muestreador en el master
# (top + mpstat por núcleo) cada --interval s MIENTRAS corre el job, guarda todos
# los frames, extrae el FRAME PICO (mayor uso de CPU) y trae todo a
# results/<engine>/<fecha>/ en tu máquina. Solo cambia el comando medido:
#   --engine spark → spark-submit queries.py --query all
#   --engine hive  → hive -f queries.hql
#
# ⚠️ Mide el MASTER (driver en client mode). El cómputo distribuido vive en los
# nodos CORE; el TIEMPO es real y comparable, CPU/mem del master es indicativo.
# (Limitación declarada en la comparación 6.3 — ver PLAN.md.)
#
# Pre-requisito: cluster ya creado con run_emr.sh (deja .emr_state) y, para Spark,
# las consultas leen del metastore compartido (creado por el setup de run_emr.sh).
#
# Uso:
#   bash scripts/measure/monitor.sh --engine hive
#   bash scripts/measure/monitor.sh --engine spark --interval 1
#
# Flags:
#   --engine hive|spark   motor a medir (REQUERIDO)
#   --interval <s>        segundos entre snapshots (default 2)
# =============================================================================
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
STATE_FILE="$ROOT_DIR/.emr_state"

ENGINE=""
INTERVAL=2

while [[ $# -gt 0 ]]; do
  case "$1" in
    --engine)   ENGINE="$2";   shift 2 ;;
    --interval) INTERVAL="$2"; shift 2 ;;
    -h|--help)  sed -n '2,30p' "$0"; exit 0 ;;
    *) shift ;;
  esac
done

if [[ "$ENGINE" != "hive" && "$ENGINE" != "spark" ]]; then
  echo "ERROR: --engine hive|spark es requerido."
  exit 1
fi

if [[ ! -f "$STATE_FILE" ]]; then
  echo "ERROR: no se encontró $STATE_FILE — ejecuta run_emr.sh primero."
  exit 1
fi
source "$STATE_FILE"          # CLUSTER_ID, BUCKET, REGION

# ── PROYECTO-ESPECÍFICO: artefacto local + comando remoto por motor ───────────
if [[ "$ENGINE" == "spark" ]]; then
  JOB_LOCAL="$ROOT_DIR/queries/spark/queries.py"
  JOB_REMOTE="queries.py"
  LABEL="Spark SQL — las 9 consultas (spark-submit)"
  # PYTHONUNBUFFERED + hora por línea ya lo aporta el wrapper de abajo.
  REMOTE_CMD="PYTHONUNBUFFERED=1 spark-submit --conf spark.ui.showConsoleProgress=false /tmp/$JOB_REMOTE --query all"
else
  JOB_LOCAL="$ROOT_DIR/queries/hive/queries.hql"
  JOB_REMOTE="queries.hql"
  LABEL="HiveQL — las 9 consultas (hive -f)"
  REMOTE_CMD="hive -f /tmp/$JOB_REMOTE"
fi

if [[ ! -f "$JOB_LOCAL" ]]; then
  echo "ERROR: no existe $JOB_LOCAL (¿ya escribiste las consultas de la Fase 3?)."
  exit 1
fi

echo ""
echo "╔══════════════════════════════════════════════════╗"
echo "║   Monitor de consumo — retaillm ($ENGINE)"
echo "╚══════════════════════════════════════════════════╝"
echo "  Cluster  : $CLUSTER_ID"
echo "  Bucket   : s3://$BUCKET"
echo "  Job      : $LABEL"
echo "  Muestreo : cada ${INTERVAL}s (top + mpstat por núcleo)"
echo ""

# ── Verificar cluster activo ─────────────────────────────────────────────────
STATUS=$(aws emr describe-cluster --cluster-id "$CLUSTER_ID" --region "$REGION" \
  --query 'Cluster.Status.State' --output text)
if [[ "$STATUS" != "WAITING" && "$STATUS" != "RUNNING" ]]; then
  echo "ERROR: cluster $CLUSTER_ID no está activo (estado: $STATUS)"
  exit 1
fi

# ── Datos del master ─────────────────────────────────────────────────────────
read -r MASTER_DNS AZ < <(aws emr describe-cluster \
  --cluster-id "$CLUSTER_ID" --region "$REGION" \
  --query 'Cluster.[MasterPublicDnsName, Ec2InstanceAttributes.Ec2AvailabilityZone]' \
  --output text)
MASTER_ID=$(aws emr list-instances --cluster-id "$CLUSTER_ID" --region "$REGION" \
  --instance-group-type MASTER --query 'Instances[0].Ec2InstanceId' --output text)
echo "  Master   : $MASTER_DNS  ($MASTER_ID, $AZ)"

# ── Abrir puerto 22 para la IP actual ────────────────────────────────────────
MY_IP=$(curl -s https://checkip.amazonaws.com | tr -d '[:space:]')
SG=$(aws emr describe-cluster --cluster-id "$CLUSTER_ID" --region "$REGION" \
  --query 'Cluster.Ec2InstanceAttributes.EmrManagedMasterSecurityGroup' --output text)
aws ec2 authorize-security-group-ingress --region "$REGION" --group-id "$SG" \
  --protocol tcp --port 22 --cidr "${MY_IP}/32" 2>/dev/null \
  && echo "  ✓ Puerto 22 abierto para $MY_IP" \
  || echo "  (regla de puerto 22 ya existía)"

# ── Key temporal + script remoto (limpieza garantizada) ──────────────────────
TMP_KEY="/tmp/emr_monitor_$$"
REMOTE_SH="/tmp/emr_monitor_remote_$$.sh"
rm -f "$TMP_KEY" "${TMP_KEY}.pub" "$REMOTE_SH"
trap 'rm -f "$TMP_KEY" "${TMP_KEY}.pub" "$REMOTE_SH"' EXIT
ssh-keygen -t rsa -b 2048 -f "$TMP_KEY" -N "" -q

SSH_OPTS=(-i "$TMP_KEY" -o StrictHostKeyChecking=no -o ServerAliveInterval=30 -o ConnectTimeout=15)

push_key() {
  # La clave de EC2 Instance Connect vale ~60s para ESTABLECER la conexión.
  aws ec2-instance-connect send-ssh-public-key --region "$REGION" \
    --instance-id "$MASTER_ID" --availability-zone "$AZ" \
    --instance-os-user hadoop --ssh-public-key "file://${TMP_KEY}.pub" \
    --output text --query 'Success' > /dev/null
}

# ── Script que corre EN el master: muestreador en background + el job ────────
cat > "$REMOTE_SH" <<EOF
#!/bin/bash
set -uo pipefail
M=/tmp/measure
rm -rf "\$M"; mkdir -p "\$M"

sampler() {
  while true; do
    echo "================ SNAPSHOT \$(date '+%Y-%m-%d %H:%M:%S') ================"
    # top -bn2: la 2ª iteración trae el %CPU instantáneo (no el de boot).
    top -bn2 -d 1 | awk 'BEGIN{b=0} /^top - /{b++} b==2{print}' | head -20
    if command -v mpstat >/dev/null 2>&1; then
      echo "--- mpstat (uso por núcleo) ---"
      mpstat -P ALL 1 1 2>/dev/null | awk 'NR>3'
    fi
    echo ""
    sleep $INTERVAL
  done
}

sampler > "\$M/snaps.log" 2>&1 &
SAMP=\$!
echo "[monitor] sampler PID \$SAMP (cada ${INTERVAL}s)"
echo "[monitor] $ENGINE: $REMOTE_CMD"
echo ""

# A cada línea de salida se le antepone la HORA de pared [HH:MM:SS] para
# CORRELACIONAR cada consulta con los snapshots (correlate.sh).
$REMOTE_CMD 2>"\$M/job.err" \
  | while IFS= read -r line; do printf '[%s] %s\n' "\$(date '+%H:%M:%S')" "\$line"; done \
  | tee "\$M/job.out"
RC=\${PIPESTATUS[0]}

sleep 1
kill "\$SAMP" 2>/dev/null || true
wait "\$SAMP" 2>/dev/null || true

echo "" | tee -a "\$M/job.out"
echo "[monitor] job rc=\$RC" | tee -a "\$M/job.out"
echo "----- últimas líneas de stderr -----" >> "\$M/job.out"
tail -8 "\$M/job.err" >> "\$M/job.out" 2>/dev/null || true
EOF

# ── Subir job + script remoto, y ejecutarlos ─────────────────────────────────
STAMP=$(date +%Y%m%d-%H%M%S)
RESULTS="$ROOT_DIR/results/$ENGINE/$STAMP"
mkdir -p "$RESULTS"

echo ""
echo "  Subiendo job y muestreador al master..."
push_key
scp "${SSH_OPTS[@]}" "$JOB_LOCAL" "hadoop@$MASTER_DNS:/tmp/$JOB_REMOTE"
scp "${SSH_OPTS[@]}" "$REMOTE_SH" "hadoop@$MASTER_DNS:/tmp/monitor_remote.sh"

echo "  Ejecutando + midiendo (verás la salida del job en vivo)..."
echo "  ────────────────────────────────────────────────────────"
ssh "${SSH_OPTS[@]}" "hadoop@$MASTER_DNS" "bash /tmp/monitor_remote.sh" || true
echo "  ────────────────────────────────────────────────────────"

# ── Traer los resultados (re-empuja la key: el job pudo durar >60s) ──────────
echo "  Descargando snapshots..."
push_key
scp "${SSH_OPTS[@]}" "hadoop@$MASTER_DNS:/tmp/measure/snaps.log" "$RESULTS/" 2>/dev/null || true
scp "${SSH_OPTS[@]}" "hadoop@$MASTER_DNS:/tmp/measure/job.out"   "$RESULTS/" 2>/dev/null || true
scp "${SSH_OPTS[@]}" "hadoop@$MASTER_DNS:/tmp/measure/job.err"   "$RESULTS/" 2>/dev/null || true

# ── Extraer el FRAME PICO (mayor uso de CPU = menor idle) ────────────────────
if [[ -s "$RESULTS/snaps.log" ]]; then
  awk '
    function flush(){ if(cur!=""){ blk[n]=cur; use[n]=u; n++ } }
    /^================ SNAPSHOT/ { flush(); cur=$0 ORS; u=0; next }
    { cur=cur $0 ORS }
    /%Cpu\(s\)/ { for(i=1;i<=NF;i++) if($i ~ /^id/){ u=100-$(i-1) } }
    END{
      flush(); best=-1; bi=0
      for(i=0;i<n;i++) if(use[i]>best){ best=use[i]; bi=i }
      printf "%s", blk[bi]
      printf "\n>>> PICO de uso de CPU en el master: %.1f%%  (de %d snapshots)\n", best, n
    }
  ' "$RESULTS/snaps.log" > "$RESULTS/pico.txt"
fi

# ── Resumen ──────────────────────────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════════════╗"
echo "║   MEDICIÓN COMPLETA ($ENGINE)"
echo "╚══════════════════════════════════════════════════╝"
echo "  Carpeta : $RESULTS"
echo ""
echo "  Archivos:"
echo "    pico.txt   → snapshot tipo htop en el MOMENTO DE MAYOR USO (captura ESTE)"
echo "    snaps.log  → todos los snapshots de la corrida"
echo "    job.out    → salida del job con HORA por línea (correlaciona con snaps.log)"
echo "    job.err    → stderr del motor (para depurar)"
echo ""
if [[ -s "$RESULTS/pico.txt" ]]; then
  grep "PICO de uso" "$RESULTS/pico.txt" | sed 's/^/  /'
fi
echo ""
echo "  Correlacionar consumo ↔ consulta:"
echo "    bash scripts/measure/correlate.sh $RESULTS"
echo ""
