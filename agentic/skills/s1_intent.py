#!/usr/bin/env python3
# ============================================================
# s1_intent.py  |  retaillm — Fase 5, Skill 1: Interpretación de intención
#
# NL -> intent estructurado (JSON). No genera SQL; solo entiende QUÉ se pide.
#   run(gemini, question) -> {
#       metric, dimension, filters[], order, limit, tables[], needs_window
#   }
# ============================================================
import schema_context

SYSTEM = (
    "Eres un analista de datos de retail. Traduces una pregunta en lenguaje "
    "natural a una INTENCIÓN estructurada sobre un Data Warehouse TPC-DS. "
    "No escribes SQL. Respondes SOLO con un objeto JSON."
)

_SCHEMA_HINT = (
    "Devuelve EXACTAMENTE este JSON:\n"
    "{\n"
    '  "metric": "métrica principal en palabras (p.ej. \\"suma de ss_net_paid\\")",\n'
    '  "dimension": "por qué se agrupa (p.ej. \\"tienda\\", \\"mes\\", \\"cliente\\") o null",\n'
    '  "filters": ["condiciones en palabras, [] si no hay"],\n'
    '  "order": "asc | desc (del ranking pedido)",\n'
    '  "limit": <entero o null>,\n'
    '  "tables": ["tablas necesarias del esquema"],\n'
    '  "needs_window": <true si requiere RANK/ventana, false si no>\n'
    "}"
)


def run(gemini, question):
    prompt = (
        f"{schema_context.schema_prompt()}\n\n"
        f"{_SCHEMA_HINT}\n\n"
        f"Pregunta: {question}"
    )
    intent = gemini.generate_json(prompt, system=SYSTEM)
    # Defensa: normaliza claves esperadas para que las skills siguientes no rompan.
    intent.setdefault("metric", None)
    intent.setdefault("dimension", None)
    intent.setdefault("filters", [])
    intent.setdefault("order", "desc")
    intent.setdefault("limit", None)
    intent.setdefault("tables", [])
    intent.setdefault("needs_window", False)
    return intent
