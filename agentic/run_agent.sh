#!/bin/bash
# =============================================================================
# run_agent.sh  |  retaillm — Fase 5: lanza el agente en un entorno uv efímero
#
# Prepara las dependencias (igual idea que scripts/measure/verify_local.sh) y
# corre agentic/agent.py:
#   • pyspark==3.5.3   (backend local; misma versión que EMR 7.0.0)
#   • jdk4py>=17,<18   (OpenJDK 17 como wheel; el Java del sistema no sirve)
#   • google-genai     (SDK nuevo de Gemini)
#
# Requiere GEMINI_API_KEY en el entorno (lo pone el usuario).
#
# Uso:
#   bash agentic/run_agent.sh --target local
#   bash agentic/run_agent.sh --target local --question "¿la tienda con más ventas?"
#   bash agentic/run_agent.sh --target emr            # con clúster vivo (.emr_state)
#
# Todos los argumentos se pasan tal cual a agent.py.
# =============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYVER="3.12"
PYSPARK="pyspark==3.5.3"
JDK="jdk4py>=17,<18"
GENAI="google-genai"

command -v uv >/dev/null 2>&1 || { echo "ERROR: falta uv (este proyecto usa uv)."; exit 1; }
[[ -n "${GEMINI_API_KEY:-}" ]] || {
  echo "ERROR: falta GEMINI_API_KEY. Obtén una en https://aistudio.google.com/api-keys y:"
  echo "  export GEMINI_API_KEY=..."
  exit 1
}

# Launcher que fija JAVA_HOME (jdk4py) antes de correr agent.py (igual que verify_local).
RUNNER="$(mktemp "${TMPDIR:-/tmp}/retaillm_agent_run.XXXXXX.py")"
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

exec uv run --python "$PYVER" --with "$PYSPARK" --with "$JDK" --with "$GENAI" \
  python "$RUNNER" "$HERE/agent.py" "$@"
