// Construye un gráfico de barras a partir de las filas de un resultado del agente:
// eje X = primera columna de texto (etiqueta), eje Y = última columna numérica.
import type { ChartData, ChartOptions } from 'chart.js'
import type { AgentRecord, Cell } from '@/types/dashboard'

const ACCENT = '#e08a3c'

export function toNum(v: Cell | undefined): number | null {
  if (v === null || v === undefined) return null
  if (typeof v === 'number') return v
  const n = parseFloat(v)
  return Number.isNaN(n) ? null : n
}

export interface BarChart {
  data: ChartData<'bar'>
  options: ChartOptions<'bar'>
}

export function chartFor(rec: AgentRecord): BarChart | null {
  const rows = rec?.rows ?? []
  if (!rows.length || !Array.isArray(rows[0])) return null
  const ncols = rows[0].length

  let metricIdx = -1
  for (let c = ncols - 1; c >= 0; c--) {
    if (toNum(rows[0][c]) !== null) {
      metricIdx = c
      break
    }
  }
  if (metricIdx === -1) return null

  // Primera columna que no sea la métrica, sea o no numérica (p.ej. "mes"=12
  // es una etiqueta válida aunque sea un número; antes solo se aceptaban
  // columnas de texto y una fila como Q03 caía al fallback "#1").
  let labelIdx = -1
  for (let c = 0; c < ncols; c++) {
    if (c !== metricIdx) {
      labelIdx = c
      break
    }
  }

  const top = rows.slice(0, 15)
  const labels = top.map((r, i) => (labelIdx >= 0 ? String(r[labelIdx]) : `#${i + 1}`))
  const data = top.map((r) => toNum(r[metricIdx]))
  const metricName = rec.columns?.[metricIdx] ?? 'valor'

  return {
    data: {
      labels,
      datasets: [{ label: metricName, backgroundColor: ACCENT, data, maxBarThickness: 64 }],
    },
    options: {
      indexAxis: labels.length > 6 ? 'y' : 'x',
      responsive: true,
      maintainAspectRatio: false,
      plugins: { legend: { labels: { color: '#e6edf3' } } },
      scales: {
        x: { ticks: { color: '#93a1b0' }, grid: { color: '#2d3947' } },
        y: { ticks: { color: '#93a1b0' }, grid: { color: '#2d3947' } },
      },
    },
  }
}
