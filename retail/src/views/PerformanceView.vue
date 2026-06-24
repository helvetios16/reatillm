<script setup lang="ts">
import { computed } from 'vue'
import { Bar } from 'vue-chartjs'
import type { ChartOptions } from 'chart.js'
import { useDashboardStore } from '@/stores/dashboard'

const store = useDashboardStore()
const perf = computed(() => store.data?.performance ?? null)

const HIVE = '#e7b13a'
const SPARK = '#cf6a3a'

const opts = (yTitle?: string): ChartOptions<'bar'> => ({
  responsive: true,
  maintainAspectRatio: false,
  plugins: {
    legend: { labels: { color: '#e6edf3' } },
    tooltip: { mode: 'index', intersect: false },
  },
  scales: {
    x: { ticks: { color: '#93a1b0' }, grid: { color: '#2d3947' } },
    y: {
      beginAtZero: true,
      ticks: { color: '#93a1b0' },
      grid: { color: '#2d3947' },
      title: { display: !!yTitle, text: yTitle ?? '', color: '#93a1b0' },
    },
  },
})

const labels = computed(() => perf.value?.queries.map((q) => `Q${q.q}`) ?? [])

const timeData = computed(() => ({
  labels: labels.value,
  datasets: [
    { label: 'Hive (s)', backgroundColor: HIVE, data: perf.value?.queries.map((q) => q.hive_s) ?? [] },
    { label: 'Spark (s)', backgroundColor: SPARK, data: perf.value?.queries.map((q) => q.spark_s) ?? [] },
  ],
}))

const cpuData = computed(() => ({
  labels: ['Hive', 'Spark'],
  datasets: [
    {
      label: 'Pico de CPU en el master (%)',
      backgroundColor: [HIVE, SPARK],
      data: [perf.value?.cpu.hive_pct ?? null, perf.value?.cpu.spark_pct ?? null],
    },
  ],
}))

const memData = computed(() => ({
  labels: ['Hive', 'Spark'],
  datasets: [
    {
      label: 'Memoria usada en el pico (MiB)',
      backgroundColor: [HIVE, SPARK],
      data: [perf.value?.mem.hive_used_mib ?? null, perf.value?.mem.spark_used_mib ?? null],
    },
  ],
}))

const speedup = computed(() => {
  const h = perf.value?.totals.hive_s
  const s = perf.value?.totals.spark_s
  return h && s ? (h / s).toFixed(2) : '—'
})
</script>

<template>
  <section class="view">
    <h2 class="section-title">Comparación de rendimiento</h2>
    <p v-if="perf" class="section-note">
      Mismo SQL, mismas tablas (metastore compartido), mismo clúster EMR. Corridas: Hive
      <code>{{ perf.source.hive }}</code> · Spark <code>{{ perf.source.spark }}</code>.
    </p>
    <p v-if="store.error" class="empty">{{ store.error }}</p>
    <p v-else-if="!perf" class="loading">Cargando…</p>

    <template v-if="perf">
      <div class="kpis">
        <div class="kpi">
          <div class="label">Tiempo total Hive</div>
          <div class="value">{{ perf.totals.hive_s ?? '—' }} <small>s</small></div>
        </div>
        <div class="kpi">
          <div class="label">Tiempo total Spark</div>
          <div class="value">{{ perf.totals.spark_s ?? '—' }} <small>s</small></div>
        </div>
        <div class="kpi">
          <div class="label">Spark más rápido</div>
          <div class="value">{{ speedup }}×</div>
        </div>
        <div class="kpi">
          <div class="label">Pico CPU (master)</div>
          <div class="value">{{ perf.cpu.hive_pct }}% <small>/ {{ perf.cpu.spark_pct }}%</small></div>
        </div>
      </div>

      <div class="card">
        <h3>Tiempo de ejecución por consulta (s)</h3>
        <div class="chart-box tall"><Bar :data="timeData" :options="opts('segundos')" /></div>
        <p class="muted micro">
          Nota: Q1 incluye el arranque en frío del motor (sesión Tez en Hive, warm-up de JVM en Spark).
        </p>
      </div>

      <div class="grid cols-2">
        <div class="card">
          <h3>Uso de CPU (pico en el master)</h3>
          <div class="chart-box"><Bar :data="cpuData" :options="opts('%')" /></div>
        </div>
        <div class="card">
          <h3>Uso de memoria (pico en el master)</h3>
          <div class="chart-box"><Bar :data="memData" :options="opts('MiB')" /></div>
        </div>
      </div>

      <div class="card">
        <p class="muted micro" style="margin: 0">
          ⚠️ Limitación declarada: CPU y memoria se muestrean en el <strong>master</strong> (driver).
          El cómputo distribuido vive en los nodos core, por lo que el <em>tiempo</em> es comparable
          pero CPU/mem del master son indicativos, no la carga total del clúster.
        </p>
      </div>
    </template>
  </section>
</template>

<style scoped>
.micro { font-size: 12px; margin-top: 10px; }
</style>
