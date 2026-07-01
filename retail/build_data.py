#!/usr/bin/env python3
# ============================================================
# build_data.py  |  retaillm — retail/ UI: agrega results/ -> dashboard.json
#
# Lee las salidas reales del proyecto y produce UN solo JSON que consume la
# interfaz Vue (sin que el front tenga que parsear logs):
#
#   - 6.3 rendimiento: tiempo por consulta (Hive vs Spark), CPU y memoria pico.
#   - 6.2 agéntico   : traza NL -> intención -> SQL -> motor -> resultado -> insight.
#   - 6.4 comparación: el markdown de comparison.md tal cual (lo renderiza el front).
#
# Fuentes (../results/, relativo a este archivo):
#   results/hive/<ts>/{job.out,pico.txt}   (la corrida más reciente)
#   results/spark/<ts>/{job.out,pico.txt}
#   results/agentic/q*.json
#   results/comparison/comparison.md
#
# Solo usa la stdlib -> corre con `python3 build_data.py` sin dependencias.
# Salida: retail/public/data/dashboard.json
# ============================================================
import glob
import json
import os
import re

_HERE = os.path.dirname(os.path.abspath(__file__))
_ROOT = os.path.dirname(_HERE)
RESULTS = os.path.join(_ROOT, "results")
OUT = os.path.join(_HERE, "public", "data", "dashboard.json")


def _latest(engine):
    dirs = sorted(glob.glob(os.path.join(RESULTS, engine, "*")))
    dirs = [d for d in dirs if os.path.isdir(d)]
    return dirs[-1] if dirs else None


def _read(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            return f.read()
    except OSError:
        return ""


def _secs(ts):
    h, m, s = (int(x) for x in ts.split(":"))
    return h * 3600 + m * 60 + s


def hive_perf(run_dir):
    if not run_dir:
        return {}, None
    out = _read(os.path.join(run_dir, "job.out"))
    markers = []
    last_ts = None
    for line in out.splitlines():
        mts = re.match(r"^\[(\d\d:\d\d:\d\d)\]", line)
        if mts:
            last_ts = _secs(mts.group(1))
        mk = re.match(r"^\[(\d\d:\d\d:\d\d)\] === Q(\d+):\s*(.*?)\s*===", line)
        if mk:
            markers.append((int(mk.group(2)), mk.group(3), _secs(mk.group(1))))
    times = {}
    for i, (q, _desc, t0) in enumerate(markers):
        t1 = markers[i + 1][2] if i + 1 < len(markers) else last_ts
        if t1 is not None:
            times[q] = round(float(t1 - t0), 1)
    labels = {q: desc for q, desc, _t in markers}
    return times, labels


def spark_perf(run_dir):
    if not run_dir:
        return {}
    out = _read(os.path.join(run_dir, "job.out"))
    times = {}
    for m in re.finditer(r"Time taken:\s*([\d.]+)\s*seconds.*?consulta\s*(\d+)", out):
        times[int(m.group(2))] = round(float(m.group(1)), 1)
    return times


def peak_stats(run_dir):
    if not run_dir:
        return {}
    txt = _read(os.path.join(run_dir, "pico.txt"))
    cpu = re.search(r"PICO de uso de CPU.*?:\s*([\d.]+)%", txt)
    mem = re.search(
        r"MiB Mem\s*:\s*([\d.]+)\s*total,\s*([\d.]+)\s*free,\s*([\d.]+)\s*used", txt)
    out = {}
    if cpu:
        out["cpu_pct"] = float(cpu.group(1))
    if mem:
        out["mem_total_mib"] = float(mem.group(1))
        out["mem_used_mib"] = float(mem.group(3))
    return out


def build_performance():
    hdir, sdir = _latest("hive"), _latest("spark")
    htimes, hlabels = hive_perf(hdir)
    stimes = spark_perf(sdir)
    hstats, sstats = peak_stats(hdir), peak_stats(sdir)

    qs = sorted(set(htimes) | set(stimes))
    queries = [{
        "q": q,
        "label": (hlabels or {}).get(q, f"Q{q}"),
        "hive_s": htimes.get(q),
        "spark_s": stimes.get(q),
    } for q in qs]
    return {
        "queries": queries,
        "cpu": {"hive_pct": hstats.get("cpu_pct"), "spark_pct": sstats.get("cpu_pct")},
        "mem": {"hive_used_mib": hstats.get("mem_used_mib"),
                "spark_used_mib": sstats.get("mem_used_mib"),
                "total_mib": hstats.get("mem_total_mib") or sstats.get("mem_total_mib")},
        "totals": {
            "hive_s": round(sum(htimes.values()), 1) if htimes else None,
            "spark_s": round(sum(stimes.values()), 1) if stimes else None,
        },
        "source": {"hive": os.path.basename(hdir) if hdir else None,
                   "spark": os.path.basename(sdir) if sdir else None},
    }


def build_agentic():
    recs = []
    for path in sorted(glob.glob(os.path.join(RESULTS, "agentic", "q*.json"))):
        try:
            with open(path, encoding="utf-8") as f:
                r = json.load(f)
        except (OSError, json.JSONDecodeError):
            continue
        res = r.get("result", {}) or {}
        rows = res.get("rows", [])
        recs.append({
            "n": r.get("n"),
            "question": r.get("question", ""),
            "intent": r.get("intent", {}),
            "sql": r.get("sql", ""),
            "sql_explicacion": r.get("sql_explicacion", ""),
            "engine": r.get("engine", ""),
            "engine_razon": r.get("engine_razon", ""),
            "insight": r.get("insight", ""),
            "columns": res.get("columns", []),
            # El front (ResultCard.vue) solo muestra las primeras 50; a escala
            # SF10 algunas preguntas del agente devuelven cientos de miles de
            # filas (sin LIMIT), así que se recorta el JSON y se guarda el
            # total real aparte para no inflar el dashboard (llegó a 64 MB).
            "rows": rows[:100],
            "total_rows": len(rows),
            "time_taken": res.get("time_taken"),
            "ok": r.get("ok", False),
        })
    return recs


def main():
    data = {
        "performance": build_performance(),
        "agentic": build_agentic(),
        "comparison_md": _read(os.path.join(RESULTS, "comparison", "comparison.md")),
    }
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
    p = data["performance"]
    print(f"dashboard.json -> {OUT}")
    print(f"  rendimiento: {len(p['queries'])} consultas "
          f"(hive {p['source']['hive']}, spark {p['source']['spark']})")
    print(f"  agéntico   : {len(data['agentic'])} preguntas")
    print(f"  comparison : {'sí' if data['comparison_md'] else 'NO (vacío)'}")


if __name__ == "__main__":
    main()
