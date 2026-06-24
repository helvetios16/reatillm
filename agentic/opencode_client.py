#!/usr/bin/env python3
# ============================================================
# opencode_client.py  |  retaillm — backend LLM alterno (opencode CLI)
#
# Misma interfaz que gemini_client.GeminiClient (generate_text / generate_json)
# pero usando el CLI `opencode run` con un modelo (por defecto uno GRATUITO), de
# modo que el agente funcione sin la cuota de Gemini (que se agota en el free tier).
#
#   from opencode_client import OpencodeClient
#   c = OpencodeClient()
#   txt  = c.generate_text(prompt, system=...)   # -> str
#   data = c.generate_json(prompt, system=...)   # -> dict
#
# Config por entorno:
#   OPENCODE_MODEL   (opcional; default opencode/deepseek-v4-flash-free)
#   OPENCODE_BIN     (opcional; si el binario no está en PATH)
#
# Reúsa GeminiError como tipo de error común para que los `except GeminiError`
# del agente y del server funcionen igual con cualquier backend.
# ============================================================
import json
import os
import re
import shutil
import subprocess
import tempfile
import time

from gemini_client import GeminiError  # tipo de error común

DEFAULT_MODEL = os.environ.get("OPENCODE_MODEL", "opencode/deepseek-v4-flash-free")
MAX_RETRIES = 4
BACKOFF_BASE = 1.6
CALL_TIMEOUT = int(os.environ.get("OPENCODE_TIMEOUT", "120"))  # s por llamada

_ANSI = re.compile(r"\x1b\[[0-9;]*m")
# Encabezado que imprime opencode antes de la respuesta: "> build · <modelo>"
_HEADER = re.compile(r"^>\s+\S+\s+·\s+.*$", re.MULTILINE)


def _find_bin():
    return (os.environ.get("OPENCODE_BIN")
            or shutil.which("opencode")
            or os.path.expanduser("~/.opencode/bin/opencode"))


def _clean(raw):
    """Quita ANSI y el banner; devuelve solo la respuesta del modelo."""
    t = _ANSI.sub("", raw)
    m = None
    for m in _HEADER.finditer(t):
        pass  # nos quedamos con el ÚLTIMO encabezado
    if m:
        t = t[m.end():]
    return t.strip()


def _extract_json(text):
    """Intenta json.loads; si falla, recorta el primer bloque {...} o [...]."""
    t = text.strip()
    if t.startswith("```"):
        t = t.split("\n", 1)[1] if "\n" in t else t
        if t.rstrip().endswith("```"):
            t = t.rstrip()[:-3]
        if t.lstrip().lower().startswith("json"):
            t = t.lstrip()[4:]
    t = t.strip()
    try:
        return json.loads(t)
    except json.JSONDecodeError:
        pass
    m = re.search(r"(\{.*\}|\[.*\])", t, re.DOTALL)
    if m:
        return json.loads(m.group(1))
    raise json.JSONDecodeError("sin JSON en la salida", t, 0)


class OpencodeClient:
    def __init__(self, model=None):
        self.model = model or DEFAULT_MODEL
        self.bin = _find_bin()
        if not self.bin or not os.path.exists(self.bin):
            raise GeminiError(
                "No se encontró el binario 'opencode'. Instálalo (https://opencode.ai) "
                "o exporta OPENCODE_BIN con la ruta.")
        # cwd neutral: que opencode NO lea el contexto del proyecto (AGENTS.md, etc.)
        self._cwd = os.path.join(tempfile.gettempdir(), "retaillm_opencode")
        os.makedirs(self._cwd, exist_ok=True)

    # ── una llamada con reintentos ───────────────────────────────────────
    def _call(self, prompt, system=None):
        full = f"{system}\n\n{prompt}" if system else prompt
        last = None
        for attempt in range(MAX_RETRIES):
            try:
                proc = subprocess.run(
                    [self.bin, "run", "--model", self.model, "--pure",
                     "--log-level", "ERROR"],
                    input=full, capture_output=True, text=True,
                    cwd=self._cwd, timeout=CALL_TIMEOUT)
                if proc.returncode != 0:
                    raise GeminiError(
                        f"opencode rc={proc.returncode}: {proc.stderr.strip()[:200]}")
                out = _clean(proc.stdout)
                if not out:
                    raise GeminiError("respuesta vacía de opencode")
                return out
            except subprocess.TimeoutExpired as e:
                last = e
            except GeminiError as e:
                last = e
            if attempt < MAX_RETRIES - 1:
                time.sleep(BACKOFF_BASE ** (attempt + 1))
        raise GeminiError(f"opencode falló tras {MAX_RETRIES} intentos: {last}")

    # ── texto libre ──────────────────────────────────────────────────────
    def generate_text(self, prompt, system=None):
        return self._call(prompt, system)

    # ── JSON estructurado (S1/S2/S3) ─────────────────────────────────────
    def generate_json(self, prompt, system=None):
        sys_json = (system or "")
        sys_json += ("\n\nIMPORTANTE: responde EXCLUSIVAMENTE con JSON válido, "
                     "sin markdown, sin ```, sin texto antes ni después.")
        last = None
        for attempt in range(MAX_RETRIES):
            text = self._call(prompt, sys_json.strip())
            try:
                return _extract_json(text)
            except json.JSONDecodeError as e:
                last = e
                if attempt < MAX_RETRIES - 1:
                    time.sleep(BACKOFF_BASE ** (attempt + 1))
        raise GeminiError(f"opencode no devolvió JSON válido: {last}")
