#!/bin/bash
# =============================================================================
# run_emr.sh — Crea UN cluster EMR con Hadoop + Hive + Spark para retaillm.
#
# Fusión de sparky/run_spark.sh + hive_big/run_hive.sh: un solo cluster con los
# TRES motores (Hadoop + Hive + Spark) sobre los MISMOS datos TPC-DS en S3.
# Sube los artefactos (DDL Hive, job Spark, consultas) a S3 y —si existe el
# setup.hql— crea las 5 tablas EXTERNAL en el HIVE METASTORE. Como en EMR Spark
# usa ese metastore por defecto, las tablas quedan visibles para `hive -f`,
# `spark.sql()` y `spark-sql -e` por el mismo nombre (clave para la 6.3 justa y
# para el Skill 4 del agente).
#
# Pre-requisito: datos TPC-DS ya en s3://<bucket>/raw/<tabla>/  (Fase 1).
#
# Uso:
#   bash scripts/cluster/run_emr.sh --bucket <b>
#   bash scripts/cluster/run_emr.sh --bucket <b> --key-pair <kp> --core-count 4
#   bash scripts/cluster/run_emr.sh --bucket <b> --no-setup        # solo aprovisionar
#
# Flags:
#   --bucket <b>          bucket S3 con raw/<tabla>/ (default entrepot-retail-tpcds-20260610)
#   --key-pair <kp>       habilita las sesiones interactivas (hive_shell / pyspark_shell)
#   --core-count <n>      nº de nodos CORE (default 4)
#   --instance-type <t>   tipo de instancia (default m4.large)
#   --no-setup            no ejecuta setup.hql (no crea las tablas todavía)
#   --region <r>          región AWS (default us-east-1)
# =============================================================================
set -euo pipefail

BUCKET="entrepot-retail-tpcds-20260610"
REGION="us-east-1"
KEY_PAIR=""
CORE_COUNT=4
INSTANCE_TYPE="m4.large"
DO_SETUP=1
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DDL_LOCAL="$ROOT_DIR/warehouse/hive/ddl/setup.hql"
SPARK_SCHEMA="$ROOT_DIR/warehouse/spark/schema.py"
HQL_QUERIES="$ROOT_DIR/queries/hive/queries.hql"
PY_QUERIES="$ROOT_DIR/queries/spark/queries.py"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --bucket)        BUCKET="$2";        shift 2 ;;
    --region)        REGION="$2";        shift 2 ;;
    --key-pair)      KEY_PAIR="$2";      shift 2 ;;
    --core-count)    CORE_COUNT="$2";    shift 2 ;;
    --instance-type) INSTANCE_TYPE="$2"; shift 2 ;;
    --no-setup)      DO_SETUP=0;         shift   ;;
    -h|--help)       sed -n '2,33p' "$0"; exit 0 ;;
    *) shift ;;
  esac
done

echo ""
echo "╔══════════════════════════════════════════════════╗"
echo "║   retaillm — EMR (Hadoop + Hive + Spark)         ║"
echo "╚══════════════════════════════════════════════════╝"
echo "  Bucket : s3://$BUCKET"
echo "  Región : $REGION"
echo "  Nodos  : 1 master + $CORE_COUNT core ($INSTANCE_TYPE)"
echo "  Setup  : $([[ $DO_SETUP -eq 1 ]] && echo 'crea las 5 tablas (setup.hql)' || echo 'omitido (--no-setup)')"
echo ""

# ── Verificar AWS ─────────────────────────────────────────────────────────────
aws sts get-caller-identity --query 'Account' --output text > /dev/null || {
  echo "ERROR: AWS CLI no configurado (pega las credenciales del Learner Lab)."
  exit 1
}

# ── Verificar datos en S3 (al menos store_sales) ──────────────────────────────
echo "Verificando datos TPC-DS en S3..."
if ! aws s3 ls "s3://$BUCKET/raw/store_sales/" >/dev/null 2>&1; then
  echo "ERROR: no hay datos en s3://$BUCKET/raw/store_sales/"
  echo "Genera primero el dataset:  bash scripts/data/generate_tpcds.sh --bucket $BUCKET"
  exit 1
fi
echo "✓ raw/store_sales/ encontrado."
echo ""

# ── Subir artefactos existentes a S3 (idempotente) ────────────────────────────
echo "[ 1/4 ] Subiendo artefactos a S3 (los que existan)..."
upload_if_exists() {  # <ruta-local> <destino-s3>
  if [[ -f "$1" ]]; then
    aws s3 cp "$1" "$2" >/dev/null && echo "        ✓ $(basename "$1")  →  $2"
  else
    echo "        (omito $(basename "$1") — aún no existe)"
  fi
}
upload_if_exists "$DDL_LOCAL"    "s3://$BUCKET/ddl/setup.hql"
upload_if_exists "$HQL_QUERIES"  "s3://$BUCKET/hql/queries.hql"
upload_if_exists "$PY_QUERIES"   "s3://$BUCKET/spark/queries.py"
upload_if_exists "$SPARK_SCHEMA" "s3://$BUCKET/spark/schema.py"

# ── Verificar/crear roles IAM ─────────────────────────────────────────────────
echo ""
echo "[ 2/4 ] Verificando roles IAM..."
if ! aws iam get-role --role-name EMR_DefaultRole >/dev/null 2>&1; then
  echo "        Creando roles por defecto..."
  aws emr create-default-roles >/dev/null
  echo "        ✓ Roles creados."
else
  echo "        ✓ Roles ya existen."
fi

# ── Trap: limpiar cluster si se interrumpe ────────────────────────────────────
CLUSTER_ID=""
cleanup() {
  if [ -n "$CLUSTER_ID" ]; then
    echo ""
    echo "Interrupción detectada. Terminando cluster $CLUSTER_ID ..."
    aws emr terminate-clusters --cluster-ids "$CLUSTER_ID" --region "$REGION" 2>/dev/null || true
    echo "Cluster terminado."
  fi
  exit 1
}
trap cleanup INT TERM

# ── Espera con timer ──────────────────────────────────────────────────────────
# Sondea el estado e imprime el tiempo transcurrido cada POLL segundos (CloudShell
# se desconecta tras ~20-30 min en silencio). $1=label $2=cmd $3=ok-re $4=fail-re
POLL=30
LAST_ELAPSED=""
wait_con_timer() {
  local label="$1" status_cmd="$2" ok_re="$3" fail_re="$4"
  local start=$SECONDS state elapsed mmss
  while true; do
    state=$(eval "$status_cmd" 2>/dev/null || echo "?")
    elapsed=$((SECONDS - start))
    mmss=$(printf "%02d:%02d" $((elapsed / 60)) $((elapsed % 60)))
    LAST_ELAPSED="$mmss"
    printf "\r        [%s] %s: %-22s" "$mmss" "$label" "$state"
    if [[ "$state" =~ $ok_re ]];   then printf "\n"; return 0; fi
    if [[ "$state" =~ $fail_re ]]; then printf "\n"; return 1; fi
    sleep "$POLL"
  done
}

# Lanza un step Hive (hive -f sobre un .hql en S3) y espera con timer.
# Args: $1=nombre-step $2=ruta-s3-hql  [$3.. = hivevars "K=V"]
run_hive_step() {
  local name="$1" hql_s3="$2"; shift 2
  local args="\"hive-script\",\"--run-hive-script\",\"--args\",\"-f\",\"$hql_s3\""
  local hv
  for hv in "$@"; do
    args="$args,\"-hivevar\",\"$hv\""
  done
  STEP_ID=$(aws emr add-steps \
    --cluster-id "$CLUSTER_ID" --region "$REGION" \
    --steps "[{\"Type\":\"CUSTOM_JAR\",\"Name\":\"$name\",\"ActionOnFailure\":\"CONTINUE\",\"Jar\":\"command-runner.jar\",\"Args\":[$args]}]" \
    --query 'StepIds[0]' --output text)
  echo "        Step ID: $STEP_ID"
  wait_con_timer "step" \
    "aws emr describe-step --cluster-id $CLUSTER_ID --step-id $STEP_ID --region $REGION --query Step.Status.State --output text" \
    '^COMPLETED$' \
    '^(FAILED|CANCELLED|INTERRUPTED)$' || true
}

# ── Crear cluster EMR con Hadoop + Hive + Spark ───────────────────────────────
echo ""
echo "[ 3/4 ] Creando cluster EMR (1 master + $CORE_COUNT core $INSTANCE_TYPE)..."
echo "        Aplicaciones: Hadoop + Hive + Spark"
echo "        (puede tardar 5-10 min)"

# Roles explícitos en UN solo --ec2-attributes (no mezclar con --use-default-roles).
EC2_ATTRS="InstanceProfile=EMR_EC2_DefaultRole"
if [[ -n "$KEY_PAIR" ]]; then
  EC2_ATTRS="$EC2_ATTRS,KeyName=$KEY_PAIR"
  echo "        Key pair : $KEY_PAIR"
fi

CLUSTER_ID=$(aws emr create-cluster \
  --name "retaillm-Hive-Spark" \
  --release-label emr-7.0.0 \
  --applications Name=Hadoop Name=Hive Name=Spark \
  --instance-groups \
    "InstanceGroupType=MASTER,InstanceCount=1,InstanceType=$INSTANCE_TYPE" \
    "InstanceGroupType=CORE,InstanceCount=$CORE_COUNT,InstanceType=$INSTANCE_TYPE" \
  --service-role EMR_DefaultRole \
  --ec2-attributes "$EC2_ATTRS" \
  --region "$REGION" \
  --log-uri "s3://$BUCKET/logs/" \
  --no-auto-terminate \
  --enable-debugging \
  --query 'ClusterId' \
  --output text)

echo "        Cluster ID: $CLUSTER_ID"

# Guardar estado YA: si CloudShell se cae, el cluster sigue vivo y se puede limpiar.
{
  echo "CLUSTER_ID=$CLUSTER_ID"
  echo "BUCKET=$BUCKET"
  echo "REGION=$REGION"
} > "$ROOT_DIR/.emr_state"

echo "        (IDs guardados en .emr_state)"
echo "        Esperando estado WAITING..."
wait_con_timer "cluster" \
  "aws emr describe-cluster --cluster-id $CLUSTER_ID --region $REGION --query Cluster.Status.State --output text" \
  '^(WAITING|RUNNING)$' \
  '^(TERMINATED|TERMINATED_WITH_ERRORS)$' || {
    echo "ERROR: el cluster no llegó a estado activo."
    aws emr terminate-clusters --cluster-ids "$CLUSTER_ID" --region "$REGION" 2>/dev/null || true
    exit 1
  }
T_CLUSTER="$LAST_ELAPSED"
echo "        ✓ Cluster listo  (aprovisionamiento: $T_CLUSTER)"

# ── Setup de las 5 tablas EXTERNAL en el metastore (compartido Hive↔Spark) ─────
T_SETUP="(omitido)"
if [[ "$DO_SETUP" -eq 1 ]]; then
  echo ""
  echo "[ 4/4 ] Creando las 5 tablas EXTERNAL en el Hive Metastore (setup.hql)..."
  if [[ ! -f "$DDL_LOCAL" ]]; then
    echo "        ⚠ Aún no existe warehouse/hive/ddl/setup.hql (Fase 2)."
    echo "        El cluster queda listo; corre el setup cuando exista el DDL."
  else
    run_hive_step "Setup-DW-retaillm" "s3://$BUCKET/ddl/setup.hql" \
      "CUSTOMER=s3://$BUCKET/raw/customer/" \
      "ITEM=s3://$BUCKET/raw/item/" \
      "STORE=s3://$BUCKET/raw/store/" \
      "DATE_DIM=s3://$BUCKET/raw/date_dim/" \
      "STORE_SALES=s3://$BUCKET/raw/store_sales/"
    T_SETUP="$LAST_ELAPSED"
    SSTATUS=$(aws emr describe-step \
      --cluster-id "$CLUSTER_ID" --step-id "$STEP_ID" --region "$REGION" \
      --query 'Step.Status.State' --output text)
    if [[ "$SSTATUS" != "COMPLETED" ]]; then
      echo "        ⚠ El setup FALLÓ ($SSTATUS). Revisa los logs:"
      echo "        aws s3 cp s3://$BUCKET/logs/$CLUSTER_ID/steps/$STEP_ID/stderr.gz - | gunzip -c"
      T_SETUP="FALLÓ ($SSTATUS)"
    else
      echo "        ✓ 5 tablas creadas (visibles para Hive y Spark)."
    fi
  fi
else
  echo ""
  echo "[ 4/4 ] Setup omitido (--no-setup)."
fi

# ── Resultado ─────────────────────────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════════════╗"
echo "║   CLUSTER LISTO                                  ║"
echo "╚══════════════════════════════════════════════════╝"
echo "  Cluster ID : $CLUSTER_ID"
echo "  Logs       : s3://$BUCKET/logs/"
echo ""
echo "  ── Tiempos ──────────────────────────────────────"
echo "    Aprovisionar cluster : $T_CLUSTER"
echo "    Setup tablas (step)  : $T_SETUP"
echo ""
echo "  ── Medir el rendimiento (Fase 4) ────────────────"
echo "  bash scripts/measure/monitor.sh --engine hive"
echo "  bash scripts/measure/monitor.sh --engine spark"
echo ""
echo "  ── Sesiones interactivas (requieren --key-pair aquí) ──"
echo "  bash scripts/shell/hive_shell.sh      # Hive CLI en el master"
echo "  bash scripts/shell/pyspark_shell.sh   # pyspark REPL en el master"
echo ""
echo "  ── Terminar cluster (evitar costos) ─────────────"
echo "  bash scripts/cluster/cleanup.sh"
