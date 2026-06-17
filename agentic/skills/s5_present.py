#!/usr/bin/env python3
# ============================================================
# s5_present.py  |  retaillm — Fase 5, Skill 5: Presentación
#
# resultado -> {tabla_md, insight}
#   - tabla_md: tabla Markdown de las filas (o el raw_stdout si vino de EMR).
#   - insight : 1-2 frases en lenguaje natural que redacta Gemini sobre el
#               resultado (responde la pregunta original).
# ============================================================

SYSTEM = (
    "Eres un analista de retail. Dado el resultado de una consulta, redactas un "
    "INSIGHT breve (1-2 frases, en español) que responde la pregunta del usuario. "
    "Sé concreto: cita nombres y cifras del resultado. No inventes datos."
)

MAX_ROWS_MD = 20      # filas máximas en la tabla Markdown
MAX_ROWS_LLM = 15     # filas que se pasan al LLM para el insight


def to_markdown(columns, rows, limit=MAX_ROWS_MD):
    if not columns:
        return "_(sin filas estructuradas; ver salida cruda)_"
    head = "| " + " | ".join(str(c) for c in columns) + " |"
    sep = "| " + " | ".join("---" for _ in columns) + " |"
    body = []
    for r in rows[:limit]:
        body.append("| " + " | ".join("" if v is None else str(v) for v in r) + " |")
    extra = "" if len(rows) <= limit else f"\n_({len(rows) - limit} filas más omitidas)_"
    return "\n".join([head, sep] + body) + extra


def run(gemini, question, result):
    columns = result.get("columns") or []
    rows = result.get("rows") or []
    if columns:
        tabla_md = to_markdown(columns, rows)
        datos = _preview(columns, rows)
    else:
        # vino de EMR sin parsear: usamos el stdout crudo.
        raw = result.get("raw_stdout", "").strip()
        tabla_md = "```\n" + raw + "\n```" if raw else "_(sin salida)_"
        datos = raw[:2000]

    insight = ""
    if gemini is not None:
        prompt = (
            f"Pregunta del usuario: {question}\n\n"
            f"Resultado de la consulta:\n{datos}\n\n"
            "Redacta el insight (1-2 frases)."
        )
        try:
            insight = gemini.generate_text(prompt, system=SYSTEM).strip()
        except Exception as e:
            insight = f"(no se pudo generar insight: {e})"
    return {"tabla_md": tabla_md, "insight": insight}


def _preview(columns, rows):
    lines = [" | ".join(str(c) for c in columns)]
    for r in rows[:MAX_ROWS_LLM]:
        lines.append(" | ".join("" if v is None else str(v) for v in r))
    return "\n".join(lines)
