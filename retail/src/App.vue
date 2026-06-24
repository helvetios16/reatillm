<script setup lang="ts">
import { onMounted } from 'vue'
import { useRouter } from 'vue-router'
import { useDashboardStore } from '@/stores/dashboard'

const store = useDashboardStore()
const router = useRouter()
const tabs = router.options.routes.map((r) => ({
  name: r.name as string,
  label: (r.meta?.label as string) ?? (r.name as string),
}))

onMounted(() => store.load())
</script>

<template>
  <header class="top">
    <div class="wrap bar">
      <div class="brand" title="Data Warehouse TPC-DS · EMR · Hive · Spark · LLM">
        🍂 <span>retaillm</span>
      </div>
      <nav class="tabs">
        <RouterLink
          v-for="t in tabs"
          :key="t.name"
          :to="{ name: t.name }"
          class="tab"
          active-class="active"
        >
          {{ t.label }}
        </RouterLink>
      </nav>
    </div>
  </header>

  <main class="wrap">
    <RouterView />
  </main>
</template>
