<script setup lang="ts">
import { ref, nextTick } from 'vue'
import ResultCard from '@/components/ResultCard.vue'
import { ask as askApi, type EngineChoice } from '@/lib/api'
import type { AgentRecord } from '@/types/dashboard'

interface Msg {
  role: 'user' | 'agent'
  text?: string
  rec?: AgentRecord
  loading?: boolean
  error?: string
  engine?: EngineChoice
}

const question = ref('')
const engine = ref<EngineChoice>('spark')
const sending = ref(false)
const messages = ref<Msg[]>([])
const logEl = ref<HTMLElement | null>(null)

const datasets = [
  { icon: '🛒', name: 'Ventas', desc: 'producto, cliente, tienda, fecha, unidades, importe' },
  { icon: '🏪', name: 'Tiendas', desc: 'nombre, ciudad, estado' },
  { icon: '📦', name: 'Productos', desc: 'nombre, categoría, marca, precio' },
  { icon: '👥', name: 'Clientes', desc: 'nombre, año de nacimiento' },
  { icon: '📅', name: 'Fechas', desc: 'año, mes, día de la semana' },
]
const examples = [
  '¿Qué tienda tuvo mayores ventas?',
  '¿Cuáles son los 5 productos con mayor ingreso?',
  '¿Quiénes son los 10 mejores clientes por gasto?',
  '¿Cuáles son las ventas por día de la semana?',
  '¿Cuál es el ticket promedio por cliente?',
]

async function scrollDown() {
  await nextTick()
  if (logEl.value) logEl.value.scrollTop = logEl.value.scrollHeight
}

async function send(q?: string) {
  const text = (q ?? question.value).trim()
  if (!text || sending.value) return
  question.value = ''
  sending.value = true
  messages.value.push({ role: 'user', text, engine: engine.value })
  const agentMsg: Msg = { role: 'agent', loading: true }
  messages.value.push(agentMsg)
  scrollDown()
  try {
    agentMsg.rec = await askApi(text, engine.value)
  } catch (e) {
    agentMsg.error =
      `No se pudo consultar el agente (${(e as Error).message}). ` +
      '¿Está corriendo el backend?  →  bash retail/run_ui.sh'
  } finally {
    agentMsg.loading = false
    sending.value = false
    scrollDown()
  }
}
</script>

<template>
  <section class="chat">
    <div ref="logEl" class="chat-log">
      <!-- Bienvenida (chat vacío) -->
      <div v-if="!messages.length" class="welcome">
        <h2>💬 Pregúntale a tus datos</h2>
        <p class="muted">
          Escribe en lenguaje natural. El agente genera el SQL, lo ejecuta en el motor que elijas
          (⚡ Spark / 🐝 Hive) sobre el Data Warehouse y te responde con gráfico e insight.
        </p>
        <div class="w-data">
          <span v-for="d in datasets" :key="d.name" class="w-chip" :title="d.desc">
            {{ d.icon }} {{ d.name }}
          </span>
        </div>
        <div class="w-ex">
          <div class="muted w-ex-h">Prueba con:</div>
          <button v-for="ex in examples" :key="ex" class="ex" @click="send(ex)">{{ ex }}</button>
        </div>
      </div>

      <!-- Conversación -->
      <template v-for="(m, i) in messages" :key="i">
        <div v-if="m.role === 'user'" class="row user">
          <div class="bubble u">
            <span class="eng-tag">{{ m.engine === 'hive' ? '🐝' : '⚡' }}</span>{{ m.text }}
          </div>
        </div>
        <div v-else class="row agent">
          <div v-if="m.loading" class="bubble a thinking">
            <span class="dot" /> <span class="dot" /> <span class="dot" />
            <span class="muted think-t">generando SQL · eligiendo plan · ejecutando…</span>
          </div>
          <div v-else-if="m.error" class="bubble a err-b">{{ m.error }}</div>
          <ResultCard v-else-if="m.rec" :rec="m.rec" :hide-question="true" class="a-card" />
        </div>
      </template>
    </div>

    <!-- Barra de entrada -->
    <form class="composer" @submit.prevent="send()">
      <select v-model="engine" class="eng-select" :disabled="sending" aria-label="Motor">
        <option value="spark">⚡ Spark</option>
        <option value="hive">🐝 Hive</option>
      </select>
      <input
        v-model="question"
        type="text"
        class="composer-input"
        placeholder="Escribe tu pregunta…"
        :disabled="sending"
      />
      <button class="send-btn" type="submit" :disabled="sending || !question.trim()" aria-label="Enviar">
        {{ sending ? '…' : '↑' }}
      </button>
    </form>
  </section>
</template>

<style scoped>
.chat {
  margin-top: 16px;
  display: flex;
  flex-direction: column;
  height: calc(100vh - 120px);
  min-height: 440px;
}
.chat-log {
  flex: 1;
  overflow-y: auto;
  padding: 4px 2px 8px;
  display: flex;
  flex-direction: column;
  gap: 14px;
}

/* Bienvenida */
.welcome { margin: 0 auto; max-width: 620px; text-align: center; padding: 18px 10px 6px; }
.welcome h2 { font-size: 22px; margin: 0 0 8px; }
.welcome > p { max-width: 560px; margin: 0 auto 18px; font-size: 14px; }
.w-data { display: flex; gap: 8px; flex-wrap: wrap; justify-content: center; margin-bottom: 20px; }
.w-chip {
  background: var(--panel-2); border: 1px solid var(--border); border-radius: 999px;
  padding: 5px 12px; font-size: 12.5px;
}
.w-ex { max-width: 560px; margin: 0 auto; }
.w-ex-h { font-size: 12px; margin-bottom: 8px; }
.ex {
  display: block; width: 100%; text-align: left; margin-bottom: 7px;
  background: var(--panel); color: var(--text); border: 1px solid var(--border);
  border-radius: 10px; padding: 10px 13px; font-size: 13px; cursor: pointer;
}
.ex:hover { border-color: var(--accent); }

/* Mensajes */
.row { display: flex; }
.row.user { justify-content: flex-end; }
.row.agent { justify-content: flex-start; }
.bubble { max-width: 86%; border-radius: 14px; }
.bubble.u {
  background: linear-gradient(135deg, var(--accent), var(--spark));
  color: var(--accent-ink); font-weight: 600; padding: 10px 14px;
  border-bottom-right-radius: 4px; font-size: 14px;
}
.eng-tag { margin-right: 6px; }
.a-card { width: 100%; max-width: 860px; margin: 0 !important; }
.bubble.a { background: var(--panel); border: 1px solid var(--border); padding: 12px 16px; }
.err-b { color: var(--warn); }

/* "pensando" */
.thinking { display: flex; align-items: center; gap: 5px; }
.think-t { font-size: 12.5px; margin-left: 6px; }
.dot {
  width: 7px; height: 7px; border-radius: 50%; background: var(--accent);
  display: inline-block; animation: blink 1.2s infinite both;
}
.dot:nth-child(2) { animation-delay: 0.2s; }
.dot:nth-child(3) { animation-delay: 0.4s; }
@keyframes blink { 0%, 80%, 100% { opacity: 0.25; } 40% { opacity: 1; } }

/* Composer */
.composer {
  display: flex; gap: 10px; align-items: center;
  padding-top: 12px; border-top: 1px solid var(--border); margin-top: 6px;
}
.eng-select {
  background: var(--panel-2); color: var(--text); border: 1px solid var(--border);
  border-radius: 10px; padding: 11px 10px; font-size: 13px; font-weight: 600; cursor: pointer;
}
.composer-input {
  flex: 1; background: #140f0a; border: 1px solid var(--border); border-radius: 12px;
  padding: 12px 15px; color: var(--text); font-size: 15px;
}
.composer-input:focus { outline: none; border-color: var(--accent); }
.send-btn {
  background: linear-gradient(135deg, var(--accent), var(--spark)); color: var(--accent-ink);
  border: none; border-radius: 12px; width: 46px; height: 46px; font-size: 20px;
  font-weight: 800; cursor: pointer; flex: none;
}
.send-btn:disabled { opacity: 0.5; cursor: not-allowed; }
</style>
