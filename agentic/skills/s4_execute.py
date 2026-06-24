#!/usr/bin/env python3
# ============================================================
# s4_execute.py  |  retaillm — Fase 5, Skill 4: Ejecución del SQL
#
# Dos backends (--target):
#   local -> PySpark sobre la muestra data/tpcds/sample/ (reusa
#            warehouse/spark/schema.py::load_dw, igual que verify_local).
#            Pipeline completo SIN AWS. La elección de motor (S3) se REGISTRA
#            pero aquí siempre corre Spark local.
#   emr   -> agentic/run_remote.sh <engine> <sql>: SSH al master del clúster
#            (EC2 Instance Connect) y `hive -e` / `spark-sql -e`. Captura stdout.
#
# Salida común: {columns, rows, time_taken, rc, raw_stdout, target, engine}
# (en emr, columns/rows quedan vacíos: el parseo fino se afina en la Fase 4).
# ============================================================
import os
import subprocess
import time
from decimal import Decimal

_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


# ── backend LOCAL (PySpark sobre la muestra) ──────────────────────────────
def make_local_spark(sample_dir):
    """Crea una SparkSession local y registra las 5 vistas desde la muestra."""
    import sys
    sys.path.insert(0, os.path.join(_ROOT, "warehouse", "spark"))
    from pyspark.sql import SparkSession
    import schema  # warehouse/spark/schema.py
    spark = (SparkSession.builder
             .appName("retaillm-agent-local")
             .master("local[*]")
             .getOrCreate())
    spark.sparkContext.setLogLevel("ERROR")
    schema.load_dw(spark, sample_dir)
    return spark


def _jsonable(v):
    if isinstance(v, Decimal):
        return float(v)
    return v


def _run_local(sql, spark):
    start = time.time()
    df = spark.sql(sql)
    columns = list(df.columns)
    rows = [[_jsonable(v) for v in r] for r in df.collect()]
    return {
        "columns": columns,
        "rows": rows,
        "time_taken": round(time.time() - start, 2),
        "rc": 0,
        "raw_stdout": "",
    }


# ── backend EMR (helper bash run_remote.sh) ───────────────────────────────
def _run_emr(sql, engine):
    helper = os.path.join(_ROOT, "agentic", "run_remote.sh")
    start = time.time()
    proc = subprocess.run(
        ["bash", helper, engine, sql],
        capture_output=True, text=True)
    out = proc.stdout
    cols, rows = _parse_tsv(out)
    return {
        "columns": cols,
        "rows": rows,
        # hive/spark-sql imprimen "Time taken" en stderr; busca en ambos.
        "time_taken": _parse_time_taken(out + "\n" + proc.stderr,
                                        round(time.time() - start, 2)),
        "rc": proc.returncode,
        "raw_stdout": out + ("\n[stderr]\n" + proc.stderr if proc.stderr else ""),
    }


def _coerce(v):
    """'123' -> 123, '4.5' -> 4.5, 'NULL'/'' -> None, resto -> str."""
    s = (v or "").strip()
    if s in ("", "NULL", "null", "\\N"):
        return None
    try:
        f = float(s)
        return int(f) if f.is_integer() else f
    except ValueError:
        return s


def _parse_tsv(out):
    """Salida de hive/spark-sql -S con cabecera: TSV (1ª línea = columnas)."""
    lines = [ln for ln in out.splitlines() if ln.strip() != ""]
    lines = [ln for ln in lines
             if not ln.lower().startswith(("time taken", "fetched", "warning:"))]
    if not lines:
        return [], []
    columns = lines[0].split("\t")
    rows = [[_coerce(c) for c in ln.split("\t")] for ln in lines[1:]]
    return columns, rows


def _parse_time_taken(text, fallback):
    for line in text.splitlines():
        low = line.lower()
        if "time taken" in low:
            for tok in low.replace(":", " ").split():
                try:
                    return float(tok)
                except ValueError:
                    continue
    return fallback


# ── entrada de la skill ───────────────────────────────────────────────────
def run(sql, engine, target, spark=None, sample_dir=None):
    if target == "local":
        if spark is None:
            spark = make_local_spark(sample_dir or os.path.join(_ROOT, "data", "tpcds", "sample"))
        result = _run_local(sql, spark)
    elif target == "emr":
        result = _run_emr(sql, engine)
    else:
        raise ValueError(f"target desconocido: {target!r} (usa 'local' o 'emr')")
    result["target"] = target
    result["engine"] = engine
    return result
