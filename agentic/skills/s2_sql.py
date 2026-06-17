#!/usr/bin/env python3
# ============================================================
# s2_sql.py  |  retaillm — Fase 5, Skill 2: Generación de SQL
#
# intent + esquema -> SQL restringido al esquema (subconjunto común Hive/Spark).
#   run(gemini, question, intent) -> {sql, explicacion}
#
# El SQL se sanea: una sola sentencia SELECT/WITH, sin ';' colgante ni DDL/DML.
# ============================================================
import schema_context

SYSTEM = (
    "Eres un experto en SQL analítico sobre un Data Warehouse TPC-DS (Hive/Spark). "
    "Generas UNA consulta SELECT correcta, restringida al esquema dado, usando las "
    "convenciones de negocio del glosario. Respondes SOLO con un objeto JSON."
)

_OUT_HINT = (
    "Devuelve EXACTAMENTE este JSON:\n"
    "{\n"
    '  "sql": "una sola sentencia SELECT/WITH ... (sin punto y coma final)",\n'
    '  "explicacion": "1-2 frases de qué calcula el SQL"\n'
    "}\n"
    "Reglas del SQL:\n"
    "  - SOLO SELECT/WITH. Prohibido CREATE/INSERT/DROP/UPDATE/DELETE.\n"
    "  - Usa alias de tabla (ss, c, i, s, d) e INNER JOIN según el grafo de joins.\n"
    "  - Métricas e ingresos según el glosario (ingreso = SUM(ss_net_paid)).\n"
    "  - Dialecto común Hive/Spark: evita funciones exclusivas de un motor.\n"
)


def run(gemini, question, intent):
    prompt = (
        f"{schema_context.schema_prompt()}\n\n"
        f"{schema_context.fewshot_prompt()}\n\n"
        f"{_OUT_HINT}\n\n"
        f"Pregunta: {question}\n"
        f"Intención (JSON): {intent}"
    )
    out = gemini.generate_json(prompt, system=SYSTEM)
    sql = _sanitize(out.get("sql", ""))
    return {"sql": sql, "explicacion": out.get("explicacion", "")}


def _sanitize(sql):
    """Una sola sentencia SELECT/WITH; rechaza DDL/DML y multi-statement."""
    s = sql.strip()
    if s.endswith(";"):
        s = s[:-1].strip()
    if ";" in s:
        raise ValueError("SQL con múltiples sentencias (';' interno) — rechazado")
    head = s.lstrip("( \n\t").upper()
    if not (head.startswith("SELECT") or head.startswith("WITH")):
        raise ValueError(f"SQL no es SELECT/WITH — rechazado: {s[:60]}...")
    forbidden = ("INSERT ", "UPDATE ", "DELETE ", "DROP ", "CREATE ", "ALTER ", "MERGE ")
    up = " " + s.upper()
    for kw in forbidden:
        if (" " + kw) in up:
            raise ValueError(f"SQL contiene palabra prohibida {kw.strip()} — rechazado")
    return s
