#!/bin/bash
# =============================================================================
# run_compare.sh  |  retaillm — Fase 6: corre la comparación manual vs agéntico
#
# Entorno uv efímero (igual patrón que verify_local / run_agent), SIN google-genai
# porque compare.py no llama al LLM: solo re-ejecuta SQL (agente y manual) sobre
# la muestra local y los compara.
#   • pyspark==3.5.3   (misma versión que EMR 7.0.0)
#   • jdk4py>=17,<18   (OpenJDK 17 como wheel)
#
# Uso:
#   bash comparison/run_compare.sh
#
# Lee results/agentic/q*.json (salida de la Fase 5) y escribe
# results/comparison/comparison.md. Si la Fase 5 aún no corrió, escribe solo la
# sección cualitativa (ventajas/limitaciones).
# =============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYVER="3.12"
PYSPARK="pyspark==3.5.3"
JDK="jdk4py>=17,<18"

command -v uv >/dev/null 2>&1 || { echo "ERROR: falta uv (este proyecto usa uv)."; exit 1; }

# Nota: las X van al FINAL (macOS mktemp no sustituye si hay sufijo .py después).
RUNNER="$(mktemp "${TMPDIR:-/tmp}/retaillm_compare_run.XXXXXX")"
trap 'rm -f "$RUNNER"' EXIT INT TERM
cat > "$RUNNER" <<'PY'
import os, sys, runpy
from jdk4py import JAVA_HOME
os.environ['JAVA_HOME'] = str(JAVA_HOME)
os.environ['PATH'] = str(JAVA_HOME / 'bin') + os.pathsep + os.environ['PATH']
target = sys.argv[1]
sys.argv = [os.path.basename(target)] + sys.argv[2:]
runpy.run_path(target, run_name='__main__')
PY

exec uv run --python "$PYVER" --with "$PYSPARK" --with "$JDK" \
  python "$RUNNER" "$HERE/compare.py" "$@"
