#!/bin/bash
# =============================================================================
# verify_local.sh — Verifica la LÓGICA del job Spark de retaillm en LOCAL, SIN AWS.
#
# Corre queries/spark/queries.py en Spark local (master local[*]) contra un DW
# TPC-DS DIMINUTO (muestra pipe-delimitada en data/tpcds/sample/), y comprueba
# que las 9 consultas corren y miden ("Time taken"). Es el MISMO código que en
# EMR; solo cambia que lee de disco en vez del metastore/S3. Sirve para validar
# el SQL antes de gastar un cluster.
#
# Entorno EFÍMERO de uv (no instala nada al sistema):
#   • pyspark==3.5.3   (la MISMA versión que trae EMR 7.0.0)
#   • jdk4py>=17,<18   (OpenJDK 17 como wheel; el Java del sistema no sirve)
#
# NOTA (Fase 0): schema.py / queries.py se escriben en las Fases 2-3. Mientras no
# existan, este script avisa y sale 0 (el harness ya queda listo). Las ASERCIONES
# de valores concretos se afinan en la Fase 3 contra la API final de queries.py.
#
# Uso:
#   bash scripts/measure/verify_local.sh                # verifica y limpia la caché de uv
#   bash scripts/measure/verify_local.sh --keep-cache   # conserva caché (corrida rápida)
# =============================================================================
set -uo pipefail   # sin -e: queremos reportar aunque falle una aserción

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PYVER="3.12"
PYSPARK="pyspark==3.5.3"
JDK="jdk4py>=17,<18"
KEEP_CACHE=0

SCHEMA_PY="$ROOT_DIR/warehouse/spark/schema.py"
QUERIES_PY="$ROOT_DIR/queries/spark/queries.py"
SAMPLE_DIR="$ROOT_DIR/data/tpcds/sample"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --keep-cache) KEEP_CACHE=1; shift ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) shift ;;
  esac
done

# ── Gate Fase 2/3: sin los artefactos, el harness queda listo pero no hay nada
#    que verificar todavía. Salimos 0 para no romper el flujo. ────────────────
if [[ ! -f "$QUERIES_PY" || ! -f "$SCHEMA_PY" ]]; then
  echo ""
  echo "verify_local.sh — harness listo, pero faltan artefactos de Fase 2/3:"
  [[ -f "$SCHEMA_PY"  ]] || echo "  • falta warehouse/spark/schema.py   (Fase 2)"
  [[ -f "$QUERIES_PY" ]] || echo "  • falta queries/spark/queries.py    (Fase 3)"
  echo ""
  echo "Cuando existan, este script construirá un DW sintético mínimo en"
  echo "data/tpcds/sample/ y correrá las 9 consultas en Spark local."
  exit 0
fi

command -v uv >/dev/null 2>&1 || { echo "ERROR: falta uv (este proyecto usa uv)."; exit 1; }

MARKER="$(mktemp "${TMPDIR:-/tmp}/retaillm_verify_marker.XXXXXX")"

cleanup() {
  if [[ $KEEP_CACHE -eq 1 ]]; then
    echo ""
    echo "Conservado por --keep-cache: caché de uv (pyspark, jdk4py, py4j)."
    rm -f "$MARKER"
    return
  fi
  echo ""
  echo "Limpiando lo que trajo esta corrida (caché de uv: pyspark, jdk4py, py4j)..."
  local cache
  cache="$( (cd "$ROOT_DIR" && uv cache dir) 2>/dev/null || true)"
  ( cd "$ROOT_DIR" && uv cache clean pyspark jdk4py py4j >/dev/null 2>&1 ) || true
  if [[ -n "$cache" && -d "$cache/archive-v0" ]]; then
    find "$cache/archive-v0" -maxdepth 1 -mindepth 1 -type d -newer "$MARKER" \
      -exec rm -rf {} + 2>/dev/null || true
  fi
  rm -f "$MARKER"
}
trap cleanup EXIT INT TERM

PASS=0
FAIL=0
check() {  # check <nombre> <logfile> <patrón> [patrón...]
  local name="$1" log="$2"; shift 2
  local ok=1 pat
  for pat in "$@"; do
    grep -qF -- "$pat" "$log" || { ok=0; echo "      ✗ falta en la salida: «$pat»"; }
  done
  if [[ $ok -eq 1 ]]; then echo "    ✓ $name"; PASS=$((PASS + 1));
  else echo "    ✗ $name"; FAIL=$((FAIL + 1)); fi
}

echo ""
echo "╔══════════════════════════════════════════════════╗"
echo "║   verify_local.sh — Spark local, sin AWS         ║"
echo "╚══════════════════════════════════════════════════╝"
echo "  Spark: $PYSPARK   JDK: $JDK (vía uv, efímero)"
echo "  Muestra DW: $SAMPLE_DIR"
echo "  (la 1ª corrida construye pyspark en la caché de uv; puede tardar 1-2 min)"
echo ""

# ── Launcher genérico: fija JAVA_HOME (jdk4py) y ejecuta el .py real ──────────
RUNNER="$(mktemp "${TMPDIR:-/tmp}/retaillm_run.XXXXXX.py")"
cat > "$RUNNER" <<'PY'
import os, sys, runpy
from jdk4py import JAVA_HOME
os.environ['JAVA_HOME'] = str(JAVA_HOME)
os.environ['PATH'] = str(JAVA_HOME / 'bin') + os.pathsep + os.environ['PATH']
target = sys.argv[1]
sys.argv = [os.path.basename(target)] + sys.argv[2:]
runpy.run_path(target, run_name='__main__')
PY
trap 'rm -f "$RUNNER"' EXIT INT TERM

UVRUN=(uv run --python "$PYVER" --with "$PYSPARK" --with "$JDK" python)

# ── Correr las 9 consultas contra la muestra local ───────────────────────────
# Convención (a fijar en Fase 3): queries.py acepta --sample <dir> para leer el
# DW local en vez del metastore, registrando las 5 vistas vía schema.load_dw.
echo "[1/1] queries.py — 9 consultas sobre el DW sintético"
LOG="$(mktemp "${TMPDIR:-/tmp}/retaillm_queries.XXXXXX.log")"
"${UVRUN[@]}" "$RUNNER" "$QUERIES_PY" --sample "$SAMPLE_DIR" --query all > "$LOG" 2>&1

# Aserciones de VALORES sobre la muestra fija (data/tpcds/sample). Confirman que
# el SQL es correcto y que las FK NULL se descartan en los JOIN con customer.
check "las 9 consultas corren y miden"          "$LOG" "Time taken"
check "Q2 ventas por tienda: Centro = 310.00"   "$LOG" "Tienda_Centro" "310.00"
check "Q5 top producto Centro: Cafe = 260.00"   "$LOG" "260.00"
check "Q6 ticket promedio: Beto = 107.50"       "$LOG" "107.50"
check "Q7 ingreso producto: Cafe = 310.00"      "$LOG" "310.00"
check "Q8 top gasto: Beto Diaz = 215.00"        "$LOG" "Diaz" "215.00"

# ── Resumen ──────────────────────────────────────────────────────────────────
echo ""
echo "──────────────────────────────────────────────────"
echo "  Resultado: $PASS OK, $FAIL fallidos"
if [[ $FAIL -ne 0 ]]; then
  echo "  Log (se borra al salir): $LOG"
  echo "  Revisa con --keep-cache si necesitas depurar."
  echo "──────────────────────────────────────────────────"
  exit 1
fi
rm -f "$LOG"
echo "  ✓ El job Spark corre y mide en local."
echo "──────────────────────────────────────────────────"
