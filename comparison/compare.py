#!/usr/bin/env python3
# ============================================================
# compare.py  |  retaillm — Fase 6: comparación manual vs agéntico (6.4)
#
# Contrasta el flujo MANUAL (SQL de la Fase 3, queries/spark/queries.py) contra
# el AGÉNTICO (SQL generado por Gemini en la Fase 5, results/agentic/q*.json):
#
#   - Correctitud: corre AMBOS SQL sobre la MISMA muestra local y compara los
#     resultados (mismo dato => comparación justa). Veredicto por pregunta.
#   - Calidad del SQL: checks estáticos (usa ss_net_paid, INNER JOIN, GROUP BY...).
#   - Latencia: tiempo de ejecución del agente (de su JSON) vs del manual (aquí).
#   - Selección de motor: el motor que eligió S3 vs la heurística esperada.
#
# Salida: results/comparison/comparison.md (tabla + ventajas/limitaciones).
#
# Pensado para correr vía comparison/run_compare.sh (entorno uv con pyspark+jdk4py).
# Si aún no existe la salida de la Fase 5 (results/agentic/), igual escribe la
# sección cualitativa (ventajas/limitaciones) y avisa.
# ============================================================
import glob
import json
import os
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
_ROOT = os.path.dirname(_HERE)
sys.path.insert(0, os.path.join(_ROOT, "agentic"))
sys.path.insert(0, os.path.join(_ROOT, "queries", "spark"))

AGENTIC_DIR = os.path.join(_ROOT, "results", "agentic")
SAMPLE_DIR = os.path.join(_ROOT, "data", "tpcds", "sample")
OUT_DIR = os.path.join(_ROOT, "results", "comparison")

# Mapeo pregunta del agente (índice en agentic/questions.txt) -> id de consulta
# manual en queries/spark/queries.py (QUERIES). None = sin contraparte manual.
MANUAL_MAP = {
    1: 7,     # 5 productos con mayor ingreso   -> Q7 productos con mayor ingreso
    2: 2,     # tienda con mayores ventas       -> Q2 ventas por tienda
    3: 3,     # mes con mayores ingresos        -> Q3 ventas por mes
    4: 8,     # 10 mejores clientes por gasto   -> Q8 top clientes por gasto total
    5: None,  # productos más vendidos x unidad -> sin manual (manual usa ingreso)
    6: 6,     # ticket promedio por cliente     -> Q6 ticket promedio por cliente
    7: 4,     # ventas por día de la semana     -> Q4 ventas por día de la semana
    8: 1,     # 20 clientes con más compras     -> Q1 top 20 clientes por nº compras
    9: 5,     # productos más vendidos x tienda -> Q5 top productos por tienda (RANK)
    10: 9,    # ranking de meses por ventas     -> Q9 ranking mensual de ventas
}


# ── normalización / comparación de resultados ─────────────────────────────
def _norm_cell(v):
    if v is None:
        return ""
    if isinstance(v, float):
        return f"{round(v, 2):.2f}"
    try:
        return f"{round(float(v), 2):.2f}"
    except (TypeError, ValueError):
        return str(v).strip()


def _norm_rows(rows):
    return [tuple(_norm_cell(c) for c in r) for r in rows]


def _top_metric(rows):
    """Última celda numérica de la primera fila (la cifra 'cabecera')."""
    if not rows:
        return None
    for v in reversed(rows[0]):
        try:
            return round(float(v), 2)
        except (TypeError, ValueError):
            continue
    return None


def compare_results(agent_rows, manual_rows):
    a, m = _norm_rows(agent_rows), _norm_rows(manual_rows)
    # El SQL manual puede traer columnas extra de diagnóstico que NO son la
    # métrica comparada (p.ej. num_tickets en Q6). Recortamos ambos lados al
    # ancho común para comparar solo dimensiones + métrica, no esos extras.
    w = min(min((len(r) for r in a), default=0),
            min((len(r) for r in m), default=0))
    if w:
        a = [r[:w] for r in a]
        m = [r[:w] for r in m]
    if a == m:
        return "EXACTA", "✓", "resultados idénticos"
    if a and len(a) < len(m) and a == m[: len(a)]:
        return "PARCIAL", "✓", f"el agente pidió top-{len(a)}; prefijo coincide con el manual"
    if m and len(m) < len(a) and m == a[: len(m)]:
        return "PARCIAL", "✓", f"el manual es top-{len(m)}; prefijo coincide con el agente"
    am, mm = _top_metric(a), _top_metric(m)
    if am is not None and am == mm:
        return "CABECERA", "≈", f"difieren en filas pero la cifra principal coincide ({am})"
    return "DIFIERE", "✗", f"cabecera agente={am} vs manual={mm}"


# ── calidad estática del SQL del agente ───────────────────────────────────
def sql_quality(sql, expects_revenue=True):
    up = sql.upper()
    flags = []
    if expects_revenue:
        flags.append(("ss_net_paid", "SS_NET_PAID" in up))
    flags.append(("INNER JOIN", "JOIN" in up and not any(
        x in up for x in ("LEFT JOIN", "RIGHT JOIN", "FULL JOIN"))))
    flags.append(("GROUP BY", "GROUP BY" in up))
    flags.append(("ORDER BY", "ORDER BY" in up))
    return flags


# ── carga de la salida del agente (Fase 5) ────────────────────────────────
def load_agent_records():
    recs = {}
    for path in sorted(glob.glob(os.path.join(AGENTIC_DIR, "q*.json"))):
        with open(path, encoding="utf-8") as f:
            r = json.load(f)
        recs[r["n"]] = r
    return recs


# ── ejecución local del SQL (reusa el backend local de la Skill 4) ────────
def run_local(sql, spark):
    from skills import s4_execute
    return s4_execute.run(sql, "spark", "local", spark=spark)


# ── secciones cualitativas (no dependen de datos) ─────────────────────────
VENTAJAS = [
    "Accesibilidad: responde en lenguaje natural sin conocer el esquema ni SQL.",
    "Rapidez de exploración: de la pregunta al resultado en un paso.",
    "Selección automática de motor (Hive/Spark) según la forma de la consulta.",
    "Genera además un insight en lenguaje natural sobre el resultado.",
    "El contexto de esquema + glosario reduce errores y fija las métricas de negocio.",
]
LIMITACIONES = [
    "Riesgo de SQL incorrecto o alucinado (columnas/métricas equivocadas).",
    "Depende fuertemente del contexto de esquema inyectado (schema_context.py).",
    "Costo y latencia del LLM (intención + generación) sobre el tiempo de cómputo.",
    "No determinismo: dos corridas pueden producir SQL distinto.",
    "Requiere validación humana para análisis críticos (el manual es auditable).",
]


def build_report(rows_md, n_ok, n_cmp, ran):
    lines = []
    lines.append("# Fase 6 — Comparación manual vs agéntico (6.4)\n")
    if not ran:
        lines.append("> ⚠️ **Aún no hay salida de la Fase 5** (`results/agentic/q*.json`).")
        lines.append("> Corre primero `bash agentic/run_agent.sh --target local` (necesita "
                     "`GEMINI_API_KEY`).\n> La sección cualitativa de abajo no depende de datos.\n")
    else:
        lines.append(f"_Correctitud sobre la muestra local: **{n_ok}/{n_cmp}** preguntas con "
                     "contraparte manual coinciden (✓ o ≈)._\n")
        lines.append("## Tabla comparativa\n")
        lines.append("| Q | Pregunta | Motor agente | t agente (s) | t manual (s) | "
                     "Correctitud | Nota | Calidad SQL |")
        lines.append("|---|----------|--------------|--------------|--------------|"
                     "-------------|------|-------------|")
        lines += rows_md
        lines.append("")
        lines.append("_Calidad SQL: ✓ = el SQL del agente cumple el check; "
                     "claves: np=usa ss_net_paid, ij=INNER JOIN, gb=GROUP BY, ob=ORDER BY._\n")
    lines.append("## Ventajas del flujo agéntico\n")
    lines += [f"- {v}" for v in VENTAJAS]
    lines.append("\n## Limitaciones del flujo agéntico\n")
    lines += [f"- {l}" for l in LIMITACIONES]
    lines.append("")
    return "\n".join(lines)


def fmt_quality(flags):
    short = {"ss_net_paid": "np", "INNER JOIN": "ij", "GROUP BY": "gb", "ORDER BY": "ob"}
    return " ".join(f"{short.get(k, k)}{'✓' if ok else '✗'}" for k, ok in flags)


def main():
    os.makedirs(OUT_DIR, exist_ok=True)
    records = load_agent_records()

    if not records:
        report = build_report([], 0, 0, ran=False)
        out = os.path.join(OUT_DIR, "comparison.md")
        with open(out, "w", encoding="utf-8") as f:
            f.write(report)
        print(f"Sin salida de la Fase 5; escrita solo la parte cualitativa -> {out}")
        return 0

    # Spark local una sola vez (reusa el backend de la Skill 4).
    from skills import s4_execute
    import queries  # queries/spark/queries.py -> QUERIES
    spark = s4_execute.make_local_spark(SAMPLE_DIR)

    rows_md, n_ok, n_cmp = [], 0, 0
    for n in sorted(records):
        rec = records[n]
        q = rec["question"]
        agent_sql = rec.get("sql", "")
        agent_engine = rec.get("engine", "?")
        agent_t = rec.get("result", {}).get("time_taken", "?")
        manual_id = MANUAL_MAP.get(n)

        if not agent_sql:
            rows_md.append(f"| {n} | {q} | {agent_engine} | {agent_t} | — | — | "
                           f"sin SQL del agente | — |")
            continue

        # SQL del agente, re-ejecutado localmente (mismo dato que el manual).
        try:
            ag = run_local(agent_sql, spark)
            agent_rows = ag["rows"]
        except Exception as e:
            rows_md.append(f"| {n} | {q} | {agent_engine} | {agent_t} | — | ✗ | "
                           f"el SQL del agente falló: {type(e).__name__} | — |")
            continue

        quality = fmt_quality(sql_quality(agent_sql))

        if manual_id is None:
            rows_md.append(f"| {n} | {q} | {agent_engine} | {agent_t} | — | — | "
                           f"sin contraparte manual | {quality} |")
            continue

        manual_sql = queries.QUERIES[manual_id][1]
        man = run_local(manual_sql, spark)
        n_cmp += 1
        _verdict, mark, nota = compare_results(agent_rows, man["rows"])
        if mark in ("✓", "≈"):
            n_ok += 1
        rows_md.append(
            f"| {n} | {q} | {agent_engine} | {agent_t} | {man['time_taken']} | "
            f"{mark} | {nota} (vs Q{manual_id}) | {quality} |")

    spark.stop()

    report = build_report(rows_md, n_ok, n_cmp, ran=True)
    out = os.path.join(OUT_DIR, "comparison.md")
    with open(out, "w", encoding="utf-8") as f:
        f.write(report)
    print(f"\nCorrectitud: {n_ok}/{n_cmp} con contraparte manual coinciden.")
    print(f"Reporte -> {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
