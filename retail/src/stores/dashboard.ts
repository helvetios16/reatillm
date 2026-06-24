import { defineStore } from 'pinia'
import { ref } from 'vue'
import type { Dashboard } from '@/types/dashboard'

// Carga (una vez) el dashboard.json estático generado por build_data.py.
export const useDashboardStore = defineStore('dashboard', () => {
  const data = ref<Dashboard | null>(null)
  const error = ref('')
  const loading = ref(false)

  async function load() {
    if (data.value || loading.value) return
    loading.value = true
    error.value = ''
    try {
      const res = await fetch(`${import.meta.env.BASE_URL}data/dashboard.json`)
      if (!res.ok) throw new Error(`HTTP ${res.status}`)
      data.value = (await res.json()) as Dashboard
    } catch (e) {
      error.value =
        `No se pudo cargar dashboard.json (${(e as Error).message}). ` +
        'Genera los datos con: python3 build_data.py'
    } finally {
      loading.value = false
    }
  }

  return { data, error, loading, load }
})
