#!/usr/bin/env python3
# ============================================================
# llm.py  |  retaillm — selector de backend LLM para el agente
#
# Devuelve el cliente LLM según LLM_BACKEND (env):
#   - "opencode" (DEFAULT)  -> opencode_client.OpencodeClient (CLI, modelos free)
#   - "gemini"              -> gemini_client.GeminiClient   (SDK google-genai)
#
# Ambos exponen la MISMA interfaz (generate_text / generate_json) y levantan
# GeminiError ante fallos, así que el resto del agente no cambia.
#
#   from llm import make_client, GeminiError
#   cliente = make_client()
# ============================================================
import os

from gemini_client import GeminiError  # re-exportado para los `except` del agente


def make_client():
    backend = os.environ.get("LLM_BACKEND", "opencode").strip().lower()
    if backend in ("gemini", "google"):
        from gemini_client import GeminiClient
        return GeminiClient()
    from opencode_client import OpencodeClient
    return OpencodeClient()


__all__ = ["make_client", "GeminiError"]
