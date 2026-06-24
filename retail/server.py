#!/usr/bin/env python3
# ============================================================
# server.py  |  retaillm — retail/ UI: backend del dashboard interactivo
#
# HTTP server (solo stdlib) que reúsa el pipeline del agente (agentic/agent.py):
#
#   POST /api/ask     {"question": "..."}  -> registro completo del agente:
#                     intención, SQL, motor, resultado (columns/rows) e insight.
#   GET  /api/dashboard                    -> public/data/dashboard.json
#   GET  /...                              -> sirve la app compilada (dist/)
#
# El agente corre con --target local (PySpark sobre data/tpcds/sample). Gemini y
# Spark se inicializan UNA vez al arrancar; las peticiones se serializan con un
# lock (Spark + free tier de Gemini son de un solo usuario interactivo).
#
# Lanzar vía retail/run_ui.sh (entorno uv con pyspark+jdk4py+google-genai).
# Requiere GEMINI_API_KEY (lo carga run_ui.sh desde ../.env).
# ============================================================
import json
import os
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

_HERE = os.path.dirname(os.path.abspath(__file__))
_ROOT = os.path.dirname(_HERE)
sys.path.insert(0, os.path.join(_ROOT, "agentic"))

from llm import make_client, GeminiError  # noqa: E402  (backend gemini|opencode)
import agent as agent_mod  # agentic/agent.py  # noqa: E402
from skills import s4_execute  # noqa: E402

SAMPLE_DIR = os.path.join(_ROOT, "data", "tpcds", "sample")
DIST = os.path.join(_HERE, "dist")
DATA_JSON = os.path.join(_HERE, "public", "data", "dashboard.json")
SQL_DIR = os.path.join(_ROOT, "results", "live_sql")  # SQL generado por consulta
PORT = int(os.environ.get("UI_PORT", "8000"))
# local: PySpark sobre la muestra · emr: ejecuta en el clúster (.emr_state, AWS)
TARGET = os.environ.get("UI_TARGET", "local").strip().lower()

_CTYPES = {
    ".html": "text/html; charset=utf-8", ".js": "text/javascript",
    ".css": "text/css", ".json": "application/json", ".svg": "image/svg+xml",
    ".ico": "image/x-icon", ".map": "application/json", ".woff2": "font/woff2",
}

_lock = threading.Lock()
_gemini = None
_spark = None


def _init():
    global _gemini, _spark
    _gemini = make_client()
    backend = type(_gemini).__name__
    if TARGET == "emr":
        print("Modo EMR: las consultas se ejecutan en el clúster AWS (.emr_state).")
    else:
        print("Iniciando Spark local sobre la muestra (puede tardar la 1ª vez)...")
        _spark = s4_execute.make_local_spark(SAMPLE_DIR)
    print(f"Listo. Backend en http://localhost:{PORT}  (target={TARGET}, llm={backend})")


def _save_sql(rec):
    """Guarda el SQL generado como archivo .sql ejecutable (artefacto por consulta)."""
    sql = rec.get("sql")
    if not sql:
        return None
    os.makedirs(SQL_DIR, exist_ok=True)
    import time
    name = f"{time.strftime('%Y%m%d-%H%M%S')}_{rec.get('engine', 'sql')}.sql"
    path = os.path.join(SQL_DIR, name)
    header = (f"-- pregunta: {rec.get('question', '')}\n"
              f"-- motor elegido: {rec.get('engine', '?')} ({rec.get('engine_razon', '')})\n"
              f"-- target: {TARGET}\n\n")
    with open(path, "w", encoding="utf-8") as f:
        f.write(header + sql + "\n")
    return path


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _cors(self):
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")

    def _json(self, code, obj):
        body = json.dumps(obj, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self._cors()
        self.end_headers()
        self.wfile.write(body)

    def do_OPTIONS(self):
        self.send_response(204)
        self._cors()
        self.end_headers()

    def do_POST(self):
        if self.path.rstrip("/") != "/api/ask":
            return self._json(404, {"error": "ruta no encontrada"})
        try:
            n = int(self.headers.get("Content-Length", 0))
            payload = json.loads(self.rfile.read(n) or b"{}")
            question = (payload.get("question") or "").strip()
            engine_sel = (payload.get("engine") or "auto").strip().lower()
        except (ValueError, json.JSONDecodeError) as e:
            return self._json(400, {"error": f"cuerpo inválido: {e}"})
        if not question:
            return self._json(400, {"error": "falta 'question'"})
        # 'auto' -> el agente decide (S3); 'hive'/'spark' -> lo fuerza el usuario.
        force = engine_sel if engine_sel in ("hive", "spark") else None
        try:
            with _lock:
                rec = agent_mod.process(question, 0, _gemini, TARGET, _spark,
                                        force_engine=force)
            res = rec.get("result", {}) or {}
            sql_file = _save_sql(rec)
            return self._json(200, {
                "question": rec.get("question", question),
                "intent": rec.get("intent", {}),
                "sql": rec.get("sql", ""),
                "engine": rec.get("engine", ""),
                "engine_razon": rec.get("engine_razon", ""),
                "insight": rec.get("insight", ""),
                "columns": res.get("columns", []),
                "rows": res.get("rows", []),
                "time_taken": res.get("time_taken"),
                "llm_seconds": rec.get("llm_seconds"),
                "engine_seconds": rec.get("engine_seconds"),
                "target": TARGET,
                "sql_file": os.path.basename(sql_file) if sql_file else None,
                "ok": rec.get("ok", False),
                "error": rec.get("error"),
            })
        except Exception as e:  # noqa: BLE001
            return self._json(500, {"error": f"{type(e).__name__}: {e}"})

    def do_GET(self):
        path = self.path.split("?", 1)[0]
        if path.rstrip("/") == "/api/dashboard":
            if os.path.exists(DATA_JSON):
                return self._serve_file(DATA_JSON)
            return self._json(404, {"error": "dashboard.json no generado (corre build_data.py)"})
        rel = path.lstrip("/") or "index.html"
        full = os.path.normpath(os.path.join(DIST, rel))
        if not full.startswith(DIST):
            return self._json(403, {"error": "prohibido"})
        if os.path.isdir(full):
            full = os.path.join(full, "index.html")
        if not os.path.exists(full):
            index = os.path.join(DIST, "index.html")
            if os.path.exists(index):
                return self._serve_file(index)
            return self._json(404, {"error": "app no compilada. Corre: npm run build (en retail/)"})
        return self._serve_file(full)

    def _serve_file(self, full):
        ext = os.path.splitext(full)[1].lower()
        ctype = _CTYPES.get(ext, "application/octet-stream")
        with open(full, "rb") as f:
            body = f.read()
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self._cors()
        self.end_headers()
        self.wfile.write(body)


def main():
    try:
        _init()
    except GeminiError as e:
        print(f"ERROR: {e}")
        return 2
    httpd = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\nDeteniendo...")
    finally:
        if _spark is not None:
            _spark.stop()
    return 0


if __name__ == "__main__":
    sys.exit(main())
