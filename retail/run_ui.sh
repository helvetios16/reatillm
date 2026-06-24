#!/bin/bash
# =============================================================================
# run_ui.sh  |  retaillm — retail/ UI: backend interactivo en un entorno uv
#
# Prepara las deps y corre retail/server.py con Gemini + PySpark listos, de modo
# que la interfaz pueda hacer consultas en vivo (POST /api/ask).
#   • pyspark==3.5.3   (backend local; misma versión que EMR 7.0.0)
#   • jdk4py>=17,<18   (OpenJDK 17 como wheel)
#   • google-genai     (SDK de Gemini)
#
# Antes de servir, regenera public/data/dashboard.json desde ../results/.
#
# Uso:
#   bash retail/run_ui.sh                 # backend en :8000 (sirve dist/ si existe)
#   UI_PORT=9000 bash retail/run_ui.sh    # otro puerto
#
# Flujo recomendado:
#   1) cd retail && bun install && bun run build     # compila la app a dist/
#   2) bash retail/run_ui.sh                         # abre http://localhost:8000
#   (desarrollo con hot-reload: 'bun run dev' en otra terminal; proxa /api aquí)
# =============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
PYVER="3.12"
PYSPARK="pyspark==3.5.3"
JDK="jdk4py>=17,<18"
GENAI="google-genai"

command -v uv >/dev/null 2>&1 || { echo "ERROR: falta uv (este proyecto usa uv)."; exit 1; }

ENV_FILE="$ROOT/.env"
if [[ -f "$ENV_FILE" ]]; then
  set -a; # shellcheck disable=SC1090
  source "$ENV_FILE"; set +a
fi
# Default = opencode (no necesita key). Solo el backend gemini exige GEMINI_API_KEY.
if [[ "${LLM_BACKEND:-opencode}" == "gemini" || "${LLM_BACKEND:-opencode}" == "google" ]]; then
  [[ -n "${GEMINI_API_KEY:-}" ]] || {
    echo "ERROR: backend gemini sin GEMINI_API_KEY. Obtén una en https://aistudio.google.com/api-keys y:"
    echo "  export GEMINI_API_KEY=...    (o quita LLM_BACKEND para usar opencode, el default)"
    exit 1
  }
fi

# Refresca los datos del dashboard (solo stdlib; usa el python del sistema).
python3 "$HERE/build_data.py" || echo "AVISO: no se pudo regenerar dashboard.json (sigo igual)."

# Launcher que fija JAVA_HOME (jdk4py) antes de correr server.py.
RUNNER="$(mktemp "${TMPDIR:-/tmp}/retaillm_ui_run.XXXXXX")"
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
  python "$RUNNER" "$HERE/server.py"
