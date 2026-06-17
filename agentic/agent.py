#!/usr/bin/env python3
# ============================================================
# agent.py  |  retaillm — Fase 5: orquestador de la capa agéntica (6.2)
#
# Encadena las 5 skills por cada pregunta en lenguaje natural:
#   S1 intención -> S2 SQL -> S3 motor -> S4 ejecución -> S5 presentación
# y guarda el rastro completo en results/agentic/q<NN>.json.
#
# Uso:
#   # end-to-end LOCAL (sin AWS, sobre la muestra) — necesita GEMINI_API_KEY
#   python agent.py --target local
#   python agent.py --target local --question "¿los 5 productos más vendidos?"
#
#   # sobre el clúster EMR real (Fase 4 en marcha)
#   python agent.py --target emr
#
# Pensado para correr vía agentic/run_agent.sh (entorno uv con pyspark+jdk4py+
# google-genai), igual que verify_local prepara el entorno de Spark local.
# ============================================================
import argparse
import json
import os
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, _HERE)  # para importar schema_context y skills/

from gemini_client import GeminiClient, GeminiError  # noqa: E402
from skills import s1_intent, s2_sql, s3_engine, s4_execute, s5_present  # noqa: E402

_ROOT = os.path.dirname(_HERE)
QUESTIONS_FILE = os.path.join(_HERE, "questions.txt")
OUT_DIR = os.path.join(_ROOT, "results", "agentic")
SAMPLE_DIR = os.path.join(_ROOT, "data", "tpcds", "sample")


def load_questions(path):
    qs = []
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith("#"):
                qs.append(line)
    return qs


def process(question, n, gemini, target, spark):
    """Corre las 5 skills sobre una pregunta. Devuelve el registro (dict)."""
    record = {"n": n, "question": question, "target": target}
    try:
        intent = s1_intent.run(gemini, question)
        record["intent"] = intent

        sql_out = s2_sql.run(gemini, question, intent)
        record["sql"] = sql_out["sql"]
        record["sql_explicacion"] = sql_out["explicacion"]

        engine_out = s3_engine.run(gemini, intent, sql_out["sql"])
        record["engine"] = engine_out["engine"]
        record["engine_razon"] = engine_out["razon"]

        result = s4_execute.run(
            sql_out["sql"], engine_out["engine"], target,
            spark=spark, sample_dir=SAMPLE_DIR)
        record["result"] = {k: result[k] for k in
                            ("columns", "rows", "time_taken", "rc", "raw_stdout")}

        pres = s5_present.run(gemini, question, result)
        record["tabla_md"] = pres["tabla_md"]
        record["insight"] = pres["insight"]
        record["ok"] = (result["rc"] == 0)
    except Exception as e:
        record["ok"] = False
        record["error"] = f"{type(e).__name__}: {e}"
    return record


def print_record(rec):
    print("\n" + "=" * 70)
    print(f"Q{rec['n']:02d}  {rec['question']}")
    print("-" * 70)
    if not rec.get("ok"):
        print(f"  ✗ ERROR: {rec.get('error', 'desconocido')}")
        if rec.get("sql"):
            print(f"  SQL generado:\n{rec['sql']}")
        return
    print(f"  motor : {rec['engine']}  ({rec['engine_razon']})")
    print(f"  SQL   : {rec['sql_explicacion']}")
    print(f"\n{rec['tabla_md']}")
    print(f"\n  💡 {rec['insight']}")
    rt = rec["result"]["time_taken"]
    print(f"\n  (ejecución {rec['target']}, {rt}s)")


def main():
    ap = argparse.ArgumentParser(description="Agente NL->SQL retaillm (Fase 5)")
    ap.add_argument("--target", choices=["local", "emr"], default="local",
                    help="local: PySpark sobre la muestra; emr: clúster real")
    ap.add_argument("--question", default=None,
                    help="una sola pregunta NL (en vez de questions.txt)")
    ap.add_argument("--questions-file", default=QUESTIONS_FILE)
    ap.add_argument("--limit", type=int, default=None,
                    help="procesar solo las primeras N preguntas")
    ap.add_argument("--out", default=OUT_DIR, help="directorio de salida JSON")
    args = ap.parse_args()

    if args.question:
        questions = [args.question]
    else:
        questions = load_questions(args.questions_file)
        if args.limit:
            questions = questions[: args.limit]
    if not questions:
        print("No hay preguntas que procesar.")
        return 1

    try:
        gemini = GeminiClient()
    except GeminiError as e:
        print(f"ERROR: {e}")
        return 2

    spark = None
    if args.target == "local":
        print("Iniciando Spark local sobre la muestra (puede tardar la 1ª vez)...")
        spark = s4_execute.make_local_spark(SAMPLE_DIR)

    os.makedirs(args.out, exist_ok=True)
    records = []
    for i, q in enumerate(questions, start=1):
        rec = process(q, i, gemini, args.target, spark)
        records.append(rec)
        print_record(rec)
        with open(os.path.join(args.out, f"q{i:02d}.json"), "w", encoding="utf-8") as f:
            json.dump(rec, f, ensure_ascii=False, indent=2)

    if spark is not None:
        spark.stop()

    ok = sum(1 for r in records if r.get("ok"))
    print("\n" + "=" * 70)
    print(f"Resumen: {ok}/{len(records)} preguntas OK  →  {args.out}/q*.json")
    return 0 if ok == len(records) else 1


if __name__ == "__main__":
    sys.exit(main())
