import type { AgentRecord } from '@/types/dashboard'

export type EngineChoice = 'auto' | 'hive' | 'spark'

// Llama al backend (ui server.py) para una consulta en lenguaje natural en vivo.
// engine: 'auto' = el agente decide; 'hive'/'spark' = lo fuerza el usuario.
export async function ask(question: string, engine: EngineChoice = 'auto'): Promise<AgentRecord> {
  const res = await fetch(`${import.meta.env.BASE_URL}api/ask`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ question, engine }),
  })
  if (!res.ok) throw new Error(`HTTP ${res.status}`)
  return (await res.json()) as AgentRecord
}
