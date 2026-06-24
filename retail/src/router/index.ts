import { createRouter, createWebHistory } from 'vue-router'
import AskView from '@/views/AskView.vue'

const router = createRouter({
  history: createWebHistory(import.meta.env.BASE_URL),
  routes: [
    { path: '/', name: 'ask', component: AskView, meta: { label: '💬 Consulta en vivo' } },
    {
      path: '/rendimiento',
      name: 'perf',
      component: () => import('@/views/PerformanceView.vue'),
      meta: { label: '📊 Rendimiento Hive vs Spark' },
    },
    {
      path: '/agentico',
      name: 'agentic',
      component: () => import('@/views/AgenticView.vue'),
      meta: { label: '🤖 Capa agéntica (LLM)' },
    },
    {
      path: '/comparacion',
      name: 'compare',
      component: () => import('@/views/ComparisonView.vue'),
      meta: { label: '⚖️ Manual vs agéntico' },
    },
  ],
})

export default router
