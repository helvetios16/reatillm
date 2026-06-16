#!/bin/bash
# =============================================================================
# correlate.sh — Relaciona el CONSUMO con la CONSULTA que lo causó.
#
# Lee una carpeta de resultados de monitor.sh (results/<engine>/<fecha>/) con:
#   pico.txt   (frame del pico, lleva hora)
#   snaps.log  (todos los frames, cada uno con hora)
#   job.out    (salida del job, con [HH:MM:SS] en cada línea)
#
# y como job.out y snaps.log comparten la HORA de pared, imprime:
#   • qué consulta estaba en curso en el PICO global, y
#   • una tabla: cada consulta → su ventana [inicio–fin] → el pico de CPU de ESA
#     consulta (máximo 100−idle de los frames de snaps.log dentro de su ventana).
#
# Sirve igual para Hive y Spark: segmenta por "Time taken" (que ambos imprimen).
# Las etiquetas vienen de los headers del job Spark (queries.py: "1. ...") o de
# las líneas marcador de Hive (queries.hql: "=== Qn: ... ===").
#
# Uso:
#   bash scripts/measure/correlate.sh <carpeta-results>
#   bash scripts/measure/correlate.sh results/hive/20260615-142258
# =============================================================================
set -uo pipefail

DIR="${1:-}"
[[ -n "$DIR" ]] || { echo "Uso: bash scripts/measure/correlate.sh <carpeta-results>"; exit 1; }
[[ -d "$DIR" ]] || { echo "ERROR: no existe la carpeta '$DIR'"; exit 1; }

JOB="$DIR/job.out"
SNAPS="$DIR/snaps.log"
PICO="$DIR/pico.txt"
[[ -f "$JOB"  ]] || { echo "ERROR: falta $JOB (¿corriste monitor.sh?)"; exit 1; }
[[ -f "$SNAPS" ]] || SNAPS=/dev/null   # sin snaps: tabla sin picos, pero sí los segmentos

# ── Pico global (hora + %CPU) desde pico.txt ─────────────────────────────────
PICO_TS=""
PICO_CPU=""
if [[ -f "$PICO" ]]; then
  PICO_TS=$(awk '/SNAPSHOT/{print $4; exit}' "$PICO")
  PICO_CPU=$(awk -F'master: ' '/PICO de uso/{split($2,a,"%"); print a[1]; exit}' "$PICO")
fi

echo ""
echo "╔══════════════════════════════════════════════════╗"
echo "║   correlate — consumo ↔ consulta                 ║"
echo "╚══════════════════════════════════════════════════╝"
echo "  Carpeta : $DIR"
if [[ -n "$PICO_TS" ]]; then
  echo "  Pico    : ${PICO_CPU:-?}% CPU a las $PICO_TS"
else
  echo "  Pico    : (sin pico.txt; muestro solo segmentos de job.out)"
fi
echo ""

awk -v pts="$PICO_TS" -v pcpu="$PICO_CPU" '
  function isHeader(s) {
    # Spark (queries.py): "1. ..." ;  Hive (queries.hql): "=== Qn: ... ==="
    return (s ~ /^=== Q/ || s ~ /^[0-9]+\. / || s ~ /^[A-Z]\. /)
  }
  function clean(s) { gsub(/^=== /, "", s); gsub(/ ===$/, "", s); return s }
  function trunc(s, w) { return (length(s) > w) ? substr(s, 1, w-1) "…" : s }

  # ── 1er archivo: job.out → segmentos delimitados por "Time taken" ──────────
  NR==FNR {
    if (substr($0,1,1) != "[") next
    ts   = substr($0,2,8)
    rest = substr($0,12)
    sub(/^[ \t]+/, "", rest)   # las líneas "Time taken"/resultados van indentadas
    if (segActive == 0) { curStart=ts; curLabel=""; segActive=1 }
    if (curLabel == "" && isHeader(rest)) curLabel = clean(rest)
    if (rest ~ /^Time taken:/) {
      n++; S[n]=curStart; E[n]=ts
      L[n] = (curLabel=="" ? trunc(rest,34) : trunc(curLabel,34))
      segActive=0
    }
    next
  }

  # ── 2do archivo: snaps.log → frames (hora, uso=100-idle) ───────────────────
  {
    if ($2 == "SNAPSHOT") { ft=$4; next }
    if ($0 ~ /%Cpu\(s\)/) {
      idle = -1
      for (i=1; i<=NF; i++) if ($i ~ /^id/) idle = $(i-1) + 0
      if (idle >= 0 && ft != "") { fc++; FT[fc]=ft; FU[fc]=100-idle }
    }
  }

  END {
    if (n == 0) { print "  (no se encontraron consultas con \"Time taken\" en job.out)"; exit }

    # Pico de CPU por segmento (máximo de los frames dentro de su ventana)
    for (i=1; i<=n; i++) {
      best = -1
      for (k=1; k<=fc; k++)
        if (FT[k] >= S[i] && FT[k] <= E[i] && FU[k] > best) best = FU[k]
      PK[i] = best
    }

    # ¿Qué segmento contiene el pico global?
    picoSeg = 0
    if (pts != "") {
      for (i=1; i<=n; i++) if (pts >= S[i] && pts <= E[i]) picoSeg = i
      if (picoSeg == 0)  # cae en un hueco: usa el último que empezó antes del pico
        for (i=1; i<=n; i++) if (S[i] <= pts) picoSeg = i
    }

    if (pts != "") {
      if (picoSeg > 0)
        printf "  Consulta activa en el PICO:  %s\n\n", L[picoSeg]
      else if (pts < S[1])
        printf "  El PICO (%s) ocurrió ANTES de la 1ª consulta medida — arranque del\n  motor / lectura de metadatos. Ver tabla abajo.\n\n", pts
      else
        printf "  El PICO (%s) cayó ENTRE consultas medidas (transición). Ver tabla abajo.\n\n", pts
    }

    printf "  %-36s %-19s %8s\n", "Consulta", "Ventana", "PicoCPU"
    printf "  %-36s %-19s %8s\n", "------------------------------------", "-------------------", "--------"
    for (i=1; i<=n; i++) {
      pk = (PK[i] < 0) ? "  -  " : sprintf("%6.1f%%", PK[i])
      mark = (i == picoSeg) ? "  ← PICO" : ""
      printf "  %-36s [%s–%s] %8s%s\n", L[i], S[i], E[i], pk, mark
    }
    print ""
  }
' "$JOB" "$SNAPS"
