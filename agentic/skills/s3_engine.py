#!/usr/bin/env python3
# ============================================================
# s3_engine.py  |  retaillm — Fase 5, Skill 3: Selección de motor (Hive|Spark)
#
# intent + sql -> {engine: "hive"|"spark", razon, heuristica}
#
# Decisión REAL (en --target emr el SQL corre en el motor elegido). Heurística
# barata propone; Gemini confirma/ajusta y justifica. Si Gemini no está
# disponible o devuelve algo raro, cae a la heurística.
# ============================================================

SYSTEM = (
    "Eres un arquitecto de datos. Eliges el motor para una consulta sobre un "
    "clúster EMR con Hive y Spark sobre el MISMO Hive Metastore. "
    "REGLA: Spark es el motor por DEFECTO (mejor en agregaciones, joins, ventanas "
    "RANK/OVER y CTE). Elige Hive SOLO para lookups o filtros muy simples (sin "
    "agregación ni joins), donde su menor latencia de arranque conviene. "
    "Ante la duda, elige spark. Respondes SOLO con un objeto JSON."
)

_OUT_HINT = (
    "Devuelve EXACTAMENTE este JSON:\n"
    '{ "engine": "hive" | "spark", "razon": "1 frase justificando" }'
)


def heuristic(intent, sql):
    """Propuesta barata, sin LLM. Spark por DEFECTO; Hive solo lookups simples."""
    up = sql.upper()
    if intent.get("needs_window") or "OVER (" in up or "OVER(" in up or "RANK(" in up:
        return "spark", "usa funciones de ventana (RANK/OVER): mejor en Spark"
    if "WITH " in up:
        return "spark", "usa CTE / consulta compuesta: mejor en Spark"
    has_agg = any(k in up for k in
                  ("GROUP BY", "SUM(", "AVG(", "COUNT(", "MIN(", "MAX("))
    has_join = " JOIN " in up
    if not has_agg and not has_join:
        return "hive", "lookup/filtro simple (sin agregación ni joins): Hive arranca antes"
    return "spark", "agregación con joins: Spark por defecto"


def run(gemini, intent, sql):
    h_engine, h_razon = heuristic(intent, sql)
    result = {"engine": h_engine, "razon": h_razon, "heuristica": h_engine}
    if gemini is None:
        return result
    prompt = (
        f"{_OUT_HINT}\n\n"
        f"Heurística propuesta: {h_engine} ({h_razon}).\n"
        f"Intención: {intent}\n"
        f"SQL:\n{sql}"
    )
    try:
        out = gemini.generate_json(prompt, system=SYSTEM)
        engine = str(out.get("engine", "")).lower().strip()
        if engine in ("hive", "spark"):
            result["engine"] = engine
            result["razon"] = out.get("razon", h_razon)
    except Exception:
        pass  # nos quedamos con la heurística
    return result
