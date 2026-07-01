#!/bin/bash
# =============================================================================
# generate_tpcds.sh — Genera el dataset TPC-DS (SF10) y lo sube a S3, en UN comando.
#
# Orquesta TODO el flujo desde tu Mac (preferencia de automatización del proyecto):
#   1. Lanza una EC2 generadora (c5.xlarge + 40 GB EBS, Amazon Linux 2023).
#   2. Por SSH (EC2 Instance Connect, sin key pair), ejecuta en remoto:
#      instalar toolchain → clonar gregrahn/tpcds-kit → make OS=LINUX →
#      dsdgen -SCALE 10 -PARALLEL 4 → aws s3 cp de los .dat a raw/<tabla>/.
#   3. Verifica el tamaño en S3.
#   4. Termina la EC2 (siempre, incluso si algo falla; salvo --keep).
#
# Lo único MANUAL: tener pegadas las credenciales del Learner Lab y el lab activo.
# Idempotente: crea el bucket si falta y, si ya existe el marcador raw/_SUCCESS,
# omite la generación (usa --force para regenerar).
#
# ⚠️ La EC2 necesita un instance profile con acceso de escritura a S3. En AWS
# Academy Learner Lab es 'LabInstanceProfile' (rol LabRole). Cámbialo con
# --instance-profile si tu entorno usa otro.
#
# Uso:
#   bash scripts/data/generate_tpcds.sh --bucket entrepot-retail-tpcds-20260610
#   bash scripts/data/generate_tpcds.sh --bucket <b> --scale 10 --parallel 4
#   bash scripts/data/generate_tpcds.sh --bucket <b> --keep      # no termina la EC2 (debug)
#   bash scripts/data/generate_tpcds.sh --bucket <b> --force     # regenera aunque exista
#
# Flags:
#   --bucket <b>            bucket S3 destino (default entrepot-retail-tpcds-20260610)
#   --scale <n>            scale factor TPC-DS (default 10 ≈ 10 GB)
#   --parallel <n>         procesos dsdgen en paralelo (default 4)
#   --instance-type <t>    tipo EC2 generadora (default c5.xlarge)
#   --volume-size <gb>     tamaño del disco EBS (default 40)
#   --instance-profile <p> instance profile con acceso a S3 (default LabInstanceProfile)
#   --region <r>           región AWS (default us-east-1)
#   --keep                 no termina la EC2 al acabar (para depurar)
#   --force                regenera aunque exista raw/_SUCCESS
# =============================================================================
set -euo pipefail

BUCKET="entrepot-retail-tpcds-20260610"
SCALE=10
PARALLEL=4
INSTANCE_TYPE="c5.xlarge"
VOLUME_SIZE=40
INSTANCE_PROFILE="LabInstanceProfile"
REGION="us-east-1"
KEEP=0
FORCE=0

NAME_TAG="retaillm-tpcds-gen"
OS_USER="ec2-user"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
STATE_FILE="$ROOT_DIR/scripts/data/.ec2_state"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --bucket)           BUCKET="$2";           shift 2 ;;
    --scale)            SCALE="$2";            shift 2 ;;
    --parallel)         PARALLEL="$2";         shift 2 ;;
    --instance-type)    INSTANCE_TYPE="$2";    shift 2 ;;
    --volume-size)      VOLUME_SIZE="$2";      shift 2 ;;
    --instance-profile) INSTANCE_PROFILE="$2"; shift 2 ;;
    --region)           REGION="$2";           shift 2 ;;
    --keep)             KEEP=1;                shift   ;;
    --force)            FORCE=1;               shift   ;;
    -h|--help)          sed -n '2,46p' "$0";   exit 0  ;;
    *) shift ;;
  esac
done

echo ""
echo "╔══════════════════════════════════════════════════╗"
echo "║   retaillm — Generación TPC-DS (SF$SCALE → S3)"
echo "╚══════════════════════════════════════════════════╝"
echo "  Bucket   : s3://$BUCKET/raw/"
echo "  Scale    : SF$SCALE  ·  dsdgen -PARALLEL $PARALLEL"
echo "  EC2      : $INSTANCE_TYPE + ${VOLUME_SIZE}GB EBS (AL2023)"
echo "  Perfil   : $INSTANCE_PROFILE"
echo "  Región   : $REGION"
echo ""

# ── Verificar credenciales ────────────────────────────────────────────────────
aws sts get-caller-identity --query 'Arn' --output text >/dev/null || {
  echo "ERROR: AWS CLI no configurado o credenciales expiradas."
  echo "Repega access key / secret / session token desde 'AWS Details' del lab."
  exit 1
}

# ── Crear bucket si no existe (idempotente) ───────────────────────────────────
if ! aws s3 ls "s3://$BUCKET/" >/dev/null 2>&1; then
  echo "Creando bucket s3://$BUCKET ..."
  if [[ "$REGION" == "us-east-1" ]]; then
    aws s3api create-bucket --bucket "$BUCKET" --region "$REGION" >/dev/null
  else
    aws s3api create-bucket --bucket "$BUCKET" --region "$REGION" \
      --create-bucket-configuration "LocationConstraint=$REGION" >/dev/null
  fi
  echo "  ✓ Bucket creado."
fi

# ── Saltar si ya está generado (marcador _SUCCESS) ────────────────────────────
if [[ $FORCE -eq 0 ]] && aws s3 ls "s3://$BUCKET/raw/_SUCCESS" >/dev/null 2>&1; then
  echo "✓ raw/_SUCCESS ya existe → el dataset ya está generado. Nada que hacer."
  echo "  (usa --force para regenerar, o borra s3://$BUCKET/raw/_SUCCESS)"
  exit 0
fi

# ── Evitar duplicados: ¿ya hay un generador vivo? ─────────────────────────────
EXISTING=$(aws ec2 describe-instances --region "$REGION" \
  --filters "Name=tag:Name,Values=$NAME_TAG" \
            "Name=instance-state-name,Values=pending,running,stopping,stopped" \
  --query 'Reservations[].Instances[].InstanceId' --output text)
if [[ -n "$EXISTING" ]]; then
  echo "ERROR: ya existe un generador vivo: $EXISTING"
  echo "Termínalo primero:  bash scripts/data/terminate_generator.sh"
  exit 1
fi

# ── Trap: terminar la EC2 ante cualquier salida (éxito, fallo o Ctrl+C) ───────
INSTANCE_ID=""
terminate_instance() {
  [[ -z "$INSTANCE_ID" ]] && return 0
  if [[ $KEEP -eq 1 ]]; then
    echo ""
    echo "  --keep: la EC2 $INSTANCE_ID sigue VIVA (recuerda terminarla):"
    echo "  bash scripts/data/terminate_generator.sh"
    return 0
  fi
  echo ""
  echo "  Terminando EC2 generadora $INSTANCE_ID ..."
  aws ec2 terminate-instances --region "$REGION" --instance-ids "$INSTANCE_ID" \
    --query 'TerminatingInstances[].CurrentState.Name' --output text 2>/dev/null || true
  rm -f "$STATE_FILE"
}
trap terminate_instance EXIT

# ── Resolver AMI de Amazon Linux 2023 ─────────────────────────────────────────
echo "[ 1/5 ] Resolviendo AMI de Amazon Linux 2023..."
AMI_ID=$(aws ssm get-parameters --region "$REGION" \
  --names /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 \
  --query 'Parameters[0].Value' --output text)
echo "        AMI: $AMI_ID"

# ── Lanzar la EC2 generadora (instance profile + EBS mayor) ───────────────────
echo ""
echo "[ 2/5 ] Lanzando EC2 $INSTANCE_TYPE (+${VOLUME_SIZE}GB EBS)..."
INSTANCE_ID=$(aws ec2 run-instances --region "$REGION" \
  --image-id "$AMI_ID" \
  --instance-type "$INSTANCE_TYPE" \
  --count 1 \
  --iam-instance-profile "Name=$INSTANCE_PROFILE" \
  --block-device-mappings "[{\"DeviceName\":\"/dev/xvda\",\"Ebs\":{\"VolumeSize\":$VOLUME_SIZE,\"VolumeType\":\"gp3\",\"DeleteOnTermination\":true}}]" \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$NAME_TAG}]" \
  --query 'Instances[0].InstanceId' --output text)
echo "        Instance ID: $INSTANCE_ID"
{
  echo "INSTANCE_ID=$INSTANCE_ID"
  echo "REGION=$REGION"
} > "$STATE_FILE"

# ── Esperar a que esté lista para SSH (status checks OK) ──────────────────────
echo ""
echo "[ 3/5 ] Esperando 'running' + status checks (puede tardar 1-2 min)..."
aws ec2 wait instance-running --region "$REGION" --instance-ids "$INSTANCE_ID"
aws ec2 wait instance-status-ok --region "$REGION" --instance-ids "$INSTANCE_ID"

read -r PUB_DNS PUB_IP AZ SG < <(aws ec2 describe-instances \
  --region "$REGION" --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].[PublicDnsName,PublicIpAddress,Placement.AvailabilityZone,SecurityGroups[0].GroupId]' \
  --output text)
HOST="$PUB_DNS"; [[ -z "$HOST" || "$HOST" == "None" ]] && HOST="$PUB_IP"
if [[ -z "$HOST" || "$HOST" == "None" ]]; then
  echo "ERROR: la EC2 no tiene DNS/IP pública para SSH (¿subnet sin auto-assign?)."
  exit 1   # el trap EXIT termina la instancia
fi
echo "        Host: $HOST   AZ: $AZ   SG: $SG"

# ── Abrir puerto 22 para tu IP actual ─────────────────────────────────────────
MY_IP=$(curl -s https://checkip.amazonaws.com | tr -d '[:space:]')
aws ec2 authorize-security-group-ingress --region "$REGION" --group-id "$SG" \
  --protocol tcp --port 22 --cidr "${MY_IP}/32" 2>/dev/null \
  && echo "        ✓ Puerto 22 abierto para $MY_IP" \
  || echo "        (regla de puerto 22 ya existía)"

# ── Key temporal + helpers SSH (EC2 Instance Connect) ─────────────────────────
TMP_KEY="/tmp/retaillm_gen_$$"
REMOTE_SH="/tmp/retaillm_gen_remote_$$.sh"
rm -f "$TMP_KEY" "${TMP_KEY}.pub" "$REMOTE_SH"
# Encadena con el trap de terminación ya instalado (no lo sobreescribe).
trap 'rm -f "$TMP_KEY" "${TMP_KEY}.pub" "$REMOTE_SH"; terminate_instance' EXIT
ssh-keygen -t rsa -b 2048 -f "$TMP_KEY" -N "" -q
SSH_OPTS=(-i "$TMP_KEY" -o StrictHostKeyChecking=no -o ServerAliveInterval=30 -o ConnectTimeout=20)

push_key() {
  aws ec2-instance-connect send-ssh-public-key --region "$REGION" \
    --instance-id "$INSTANCE_ID" --availability-zone "$AZ" \
    --instance-os-user "$OS_USER" --ssh-public-key "file://${TMP_KEY}.pub" \
    --output text --query 'Success' > /dev/null
}

# ── Script remoto: instala, compila, genera y sube (args: bucket scale parallel) ─
cat > "$REMOTE_SH" <<'REMOTE'
#!/bin/bash
set -euo pipefail
BUCKET="$1"; SCALE="$2"; PARALLEL="$3"
DATADIR="$HOME/tpcds-data"
KIT="$HOME/tpcds-kit"

echo "[gen] instalando toolchain (gcc make flex bison byacc git)..."
# byacc provee /usr/bin/yacc, que el makefile de tpcds-kit usa para qgen.
sudo dnf -y install gcc make flex bison byacc git >/dev/null

echo "[gen] clonando gregrahn/tpcds-kit..."
rm -rf "$KIT"
git clone --depth 1 https://github.com/gregrahn/tpcds-kit.git "$KIT" >/dev/null 2>&1

echo "[gen] compilando dsdgen (make OS=LINUX, CC con -fcommon para GCC moderno)..."
# tpcds-kit no compila con GCC 10+ por defecto (-fno-common => 'multiple definition').
# -fcommon restaura el comportamiento antiguo. Si falla, mostramos el error real.
if ! make -C "$KIT/tools" OS=LINUX CC="gcc -fcommon" > /tmp/make.log 2>&1; then
  echo "[gen] ERROR compilando dsdgen:"; tail -25 /tmp/make.log; exit 1
fi
test -x "$KIT/tools/dsdgen" || { echo "[gen] ERROR: no se compiló dsdgen"; tail -25 /tmp/make.log; exit 1; }

echo "[gen] generando datos SF$SCALE en $PARALLEL procesos paralelos..."
mkdir -p "$DATADIR"
cd "$KIT/tools"   # dsdgen necesita tpcds.idx en el cwd; -DIR enruta la salida
for C in $(seq 1 "$PARALLEL"); do
  ./dsdgen -SCALE "$SCALE" -PARALLEL "$PARALLEL" -CHILD "$C" \
           -DIR "$DATADIR" -FORCE -DELIMITER '|' &
done
wait
NFILES=$(ls -1 "$DATADIR"/*.dat 2>/dev/null | wc -l)
echo "[gen] generadas $NFILES particiones; tamaño total: $(du -sh "$DATADIR" | cut -f1)"

echo "[gen] subiendo a s3://$BUCKET/raw/<tabla>/ (una carpeta por tabla)..."
cd "$DATADIR"
for f in *.dat; do
  # nombre de archivo: <tabla>_<child>_<parallel>.dat → tabla = todo antes de _N_N.dat
  tbl=$(echo "$f" | sed -E 's/_[0-9]+_[0-9]+\.dat$//')
  aws s3 cp "$f" "s3://$BUCKET/raw/$tbl/$f" --only-show-errors
done

echo "[gen] escribiendo marcador raw/_SUCCESS..."
printf 'TPC-DS SF%s generado por retaillm/generate_tpcds.sh\n' "$SCALE" > /tmp/_SUCCESS
aws s3 cp /tmp/_SUCCESS "s3://$BUCKET/raw/_SUCCESS" --only-show-errors
echo "[gen] LISTO."
REMOTE

# ── Subir y ejecutar el script remoto (la generación corre DENTRO de la EC2) ──
echo ""
echo "[ 4/5 ] Generando y subiendo (verás el log en vivo; puede tardar 10-20 min)..."
echo "        ────────────────────────────────────────────────────────"
push_key
scp "${SSH_OPTS[@]}" "$REMOTE_SH" "$OS_USER@$HOST:/tmp/gen.sh"
ssh "${SSH_OPTS[@]}" "$OS_USER@$HOST" "bash /tmp/gen.sh '$BUCKET' '$SCALE' '$PARALLEL'"
echo "        ────────────────────────────────────────────────────────"

# ── Verificar en S3 desde el Mac ──────────────────────────────────────────────
echo ""
echo "[ 5/5 ] Verificando en S3..."
if ! aws s3 ls "s3://$BUCKET/raw/_SUCCESS" >/dev/null 2>&1; then
  echo "        ⚠ No apareció raw/_SUCCESS — la generación no terminó bien."
  echo "        Revisa el log de arriba; con --keep puedes entrar a depurar:"
  echo "        bash scripts/data/connect_generator.sh"
  exit 1
fi
echo "        Tamaño total en raw/:"
aws s3 ls "s3://$BUCKET/raw/" --recursive --summarize --human-readable \
  | tail -2 | sed 's/^/        /'
echo ""
echo "        Las 5 tablas obligatorias:"
for t in customer item store date_dim store_sales; do
  SZ=$(aws s3 ls "s3://$BUCKET/raw/$t/" --recursive --summarize --human-readable \
        | grep 'Total Size' | awk -F: '{print $2}' | xargs)
  printf "          %-12s %s\n" "$t" "${SZ:-(vacío)}"
done

echo ""
echo "╔══════════════════════════════════════════════════╗"
echo "║   DATASET TPC-DS LISTO EN S3                     ║"
echo "╚══════════════════════════════════════════════════╝"
echo "  Datos    : s3://$BUCKET/raw/<tabla>/"
echo "  Marcador : s3://$BUCKET/raw/_SUCCESS"
echo ""
echo "  Siguiente (Fase 2/4): crear el cluster y las tablas"
echo "  bash scripts/cluster/run_emr.sh --bucket $BUCKET"
echo ""
# El trap EXIT termina la EC2 generadora (salvo --keep).
