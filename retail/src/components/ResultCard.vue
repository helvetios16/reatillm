<script setup lang="ts">
import { computed, ref } from 'vue'
import { Bar } from 'vue-chartjs'
import { chartFor } from '@/lib/resultChart'
import type { AgentRecord } from '@/types/dashboard'

const props = withDefaults(
  defineProps<{ rec: AgentRecord; showN?: boolean; hideQuestion?: boolean }>(),
  { showN: false, hideQuestion: false },
)

const chart = computed(() => chartFor(props.rec))
const padN = (n?: number) => String(n ?? 0).padStart(2, '0')
const showData = ref(false)

// ¿Tenemos el desglose LLM vs motor? (consultas en vivo lo traen)
const hasBreakdown = computed(
  () => props.rec.llm_seconds != null || props.rec.engine_seconds != null,
)
const totalTime = computed(() => {
  const l = props.rec.llm_seconds ?? 0
  const e = props.rec.engine_seconds ?? 0
  return hasBreakdown.value ? Math.round((l + e) * 100) / 100 : null
})
</script>

<template>
  <div class="card">
    <div class="q-head">
      <span v-if="showN && rec.n != null" class="n">Q{{ padN(rec.n) }}</span>
      <strong v-if="!hideQuestion">{{ rec.question }}</strong>
      <span v-if="rec.engine" :class="['badge', rec.engine]">{{ rec.engine }}</span>
      <span v-if="hasBreakdown" class="muted small times">
        <span v-if="rec.llm_seconds != null">🧠 LLM {{ rec.llm_seconds }}s</span>
        <span v-if="rec.engine_seconds != null"> · ⚙️ {{ rec.engine }} {{ rec.engine_seconds }}s</span>
        <span v-if="totalTime != null"> · Σ {{ totalTime }}s</span>
      </span>
      <span v-else-if="rec.time_taken != null" class="muted small">· {{ rec.time_taken }}s</span>
      <span v-if="rec.ok === false" class="badge err">error</span>
    </div>

    <p v-if="rec.error" class="muted err-text">{{ rec.error }}</p>

    <div class="grid cols-2">
      <div>
        <div v-if="chart" class="chart-box"><Bar :data="chart.data" :options="chart.options" /></div>
        <p v-else class="muted">Sin datos numéricos para graficar.</p>
      </div>
      <div>
        <p v-if="rec.engine_razon" class="muted small mb">
          <strong>Motor {{ rec.engine }}:</strong> {{ rec.engine_razon }}
        </p>

        <div class="sql-label">🧾 Consulta SQL generada</div>
        <pre class="sql">{{ rec.sql }}</pre>

        <button v-if="rec.rows?.length" class="link-btn" @click="showData = !showData">
          {{ showData ? '▾' : '▸' }} Tabla de datos ({{ rec.total_rows ?? rec.rows.length }} filas{{ (rec.total_rows ?? rec.rows.length) > rec.rows.length ? `, mostrando ${rec.rows.length}` : '' }})
        </button>
        <div v-show="showData" class="table-wrap">
          <table class="md">
            <thead>
              <tr><th v-for="(c, i) in rec.columns" :key="i">{{ c }}</th></tr>
            </thead>
            <tbody>
              <tr v-for="(r, ri) in rec.rows.slice(0, 50)" :key="ri">
                <td v-for="(cell, ci) in r" :key="ci">{{ cell }}</td>
              </tr>
            </tbody>
          </table>
        </div>

        <div v-if="rec.insight" class="insight">💡 {{ rec.insight }}</div>
      </div>
    </div>
  </div>
</template>

<style scoped>
.small { font-size: 12px; }
.sql-label { font-size: 12px; color: var(--muted); font-weight: 700; margin-bottom: 4px; }
.mb { margin: 0 0 8px; }
.err { background: rgba(248, 113, 113, 0.15); color: var(--warn); border: 1px solid rgba(248, 113, 113, 0.4); }
.err-text { color: var(--warn); margin-top: 10px; }
.link-btn {
  display: block; background: none; border: none; color: var(--muted);
  font-size: 13px; cursor: pointer; padding: 6px 0; text-align: left;
}
.link-btn:hover { color: var(--text); }
.table-wrap { overflow-x: auto; }
</style>
