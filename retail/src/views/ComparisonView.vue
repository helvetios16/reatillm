<script setup lang="ts">
import { computed } from 'vue'
import { marked } from 'marked'
import { useDashboardStore } from '@/stores/dashboard'

const store = useDashboardStore()
const html = computed(() => {
  const md = store.data?.comparison_md ?? ''
  return md ? (marked.parse(md) as string) : ''
})
</script>

<template>
  <section class="view">
    <h2 class="section-title">Comparación manual vs agéntico</h2>
    <p class="section-note">
      El mismo SQL escrito a mano frente al generado por el LLM, re-ejecutados
      sobre la misma muestra. Veredicto de correctitud, calidad del SQL y ventajas/limitaciones.
    </p>

    <p v-if="store.error" class="empty">{{ store.error }}</p>
    <div v-else-if="html" class="card md" v-html="html"></div>
    <p v-else class="empty">
      Aún no hay <code>comparison.md</code>. Corre <code>bash comparison/run_compare.sh</code> y luego
      <code>python3 build_data.py</code>.
    </p>
  </section>
</template>
