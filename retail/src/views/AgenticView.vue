<script setup lang="ts">
import { computed } from 'vue'
import ResultCard from '@/components/ResultCard.vue'
import { useDashboardStore } from '@/stores/dashboard'

const store = useDashboardStore()
const records = computed(() => store.data?.agentic ?? [])
</script>

<template>
  <section class="view">
    <h2 class="section-title">Capa de análisis agéntico</h2>
    <p class="section-note">
      Cada pregunta en lenguaje natural recorre las 5 skills: intención → SQL → selección de motor →
      ejecución → presentación con insight generado por el LLM.
    </p>

    <p v-if="store.error" class="empty">{{ store.error }}</p>
    <p v-else-if="!records.length" class="empty">
      Aún no hay resultados del agente. Corre <code>bash agentic/run_agent.sh --target local</code> y
      luego <code>python3 build_data.py</code>.
    </p>

    <ResultCard v-for="rec in records" :key="rec.n" :rec="rec" :show-n="true" />
  </section>
</template>
