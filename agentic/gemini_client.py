#!/usr/bin/env python3
# ============================================================
# gemini_client.py  |  retaillm — Fase 5 (wrapper del SDK Gemini)
#
# Único punto de contacto con la API. Usa el SDK NUEVO `google-genai`
# (no el legacy `google-generativeai`) y el modelo Flash.
#
#   from gemini_client import GeminiClient
#   g = GeminiClient()
#   data = g.generate_json(system="...", prompt="...")   # -> dict
#   text = g.generate_text(prompt="...")                 # -> str
#
# Config por entorno:
#   GEMINI_API_KEY   (obligatorio; lo pone el usuario)  -> aistudio.google.com/api-keys
#   GEMINI_MODEL     (opcional; default gemini-2.5-flash)
#
# generate_json fuerza salida JSON (response_mime_type) y reintenta ante errores
# de red/cuota o JSON inválido, con backoff exponencial.
# ============================================================
import json
import os
import time

DEFAULT_MODEL = os.environ.get("GEMINI_MODEL", "gemini-2.5-flash")
MAX_RETRIES = 6
BACKOFF_BASE = 1.5  # segundos: 1.5, 2.25, 3.4, ...
# El free tier permite ~5 req/min. Espaciamos las llamadas para no chocar con el
# 429 (configurable; 0 = sin throttle, p.ej. en cuenta de pago).
MIN_INTERVAL = float(os.environ.get("GEMINI_MIN_INTERVAL", "13"))
_last_call = [0.0]  # mutable para compartir entre instancias


class GeminiError(RuntimeError):
    pass


class GeminiClient:
    def __init__(self, model=None, api_key=None):
        self.model = model or DEFAULT_MODEL
        key = api_key or os.environ.get("GEMINI_API_KEY")
        if not key:
            raise GeminiError(
                "Falta GEMINI_API_KEY en el entorno. "
                "Obtén una en https://aistudio.google.com/api-keys y expórtala:\n"
                "  export GEMINI_API_KEY=...")
        try:
            from google import genai  # SDK nuevo: pip install google-genai
        except ImportError as e:  # pragma: no cover - entorno sin la dep
            raise GeminiError(
                "Falta el SDK 'google-genai'. Instálalo con: pip install google-genai\n"
                "(NO es el legacy 'google-generativeai').") from e
        self._genai = genai
        self.client = genai.Client(api_key=key)

    # ── núcleo: una llamada con reintentos ───────────────────────────────
    def _throttle(self):
        if MIN_INTERVAL <= 0:
            return
        wait = MIN_INTERVAL - (time.time() - _last_call[0])
        if wait > 0:
            time.sleep(wait)
        _last_call[0] = time.time()

    def _call(self, contents, config):
        last = None
        for attempt in range(MAX_RETRIES):
            try:
                self._throttle()
                resp = self.client.models.generate_content(
                    model=self.model, contents=contents, config=config)
                text = (resp.text or "").strip()
                if not text:
                    raise GeminiError("respuesta vacía del modelo")
                return text
            except Exception as e:  # red, cuota, vacío...
                last = e
                if attempt < MAX_RETRIES - 1:
                    # Ante 429, espera el tiempo que pide la API (o un mínimo holgado).
                    delay = _retry_delay(e)
                    time.sleep(delay if delay else BACKOFF_BASE ** (attempt + 1))
        raise GeminiError(f"Gemini falló tras {MAX_RETRIES} intentos: {last}")

    # ── texto libre ──────────────────────────────────────────────────────
    def generate_text(self, prompt, system=None):
        config = {"temperature": 0.2}
        if system:
            config["system_instruction"] = system
        return self._call(prompt, config)

    # ── JSON estructurado (S1/S2/S3) ─────────────────────────────────────
    def generate_json(self, prompt, system=None):
        config = {
            "temperature": 0.1,
            "response_mime_type": "application/json",
        }
        if system:
            config["system_instruction"] = system
        last = None
        for attempt in range(MAX_RETRIES):
            text = self._call(prompt, config)
            try:
                return json.loads(_strip_fences(text))
            except json.JSONDecodeError as e:
                last = e
                if attempt < MAX_RETRIES - 1:
                    time.sleep(BACKOFF_BASE ** (attempt + 1))
        raise GeminiError(f"el modelo no devolvió JSON válido: {last}")


def _retry_delay(exc):
    """Si el error trae un retryDelay (429), devuelve los segundos (con margen)."""
    msg = str(exc)
    if "429" not in msg and "RESOURCE_EXHAUSTED" not in msg:
        return 0
    import re
    m = re.search(r"retry.{0,3}in\s+([0-9.]+)s|'retryDelay':\s*'([0-9]+)s", msg)
    if m:
        secs = float(m.group(1) or m.group(2))
        return secs + 2
    return 20.0  # 429 sin detalle: espera holgada para que se reabra la ventana


def _strip_fences(text):
    """Quita ```json ... ``` si el modelo igual envolvió la respuesta."""
    t = text.strip()
    if t.startswith("```"):
        t = t.split("\n", 1)[1] if "\n" in t else t
        if t.endswith("```"):
            t = t[: -3]
        if t.lstrip().startswith("json"):
            t = t.lstrip()[4:]
    return t.strip()
