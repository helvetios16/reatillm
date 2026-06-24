// Tipos del dashboard.json que produce build_data.py (a partir de ../results/).

export type Cell = string | number | null

export interface AgentRecord {
  n?: number
  question: string
  intent?: Record<string, unknown>
  sql: string
  sql_explicacion?: string
  engine: string
  engine_razon?: string
  insight?: string
  columns: string[]
  rows: Cell[][]
  time_taken?: number | null
  llm_seconds?: number | null
  engine_seconds?: number | null
  ok?: boolean
  error?: string | null
}

export interface QueryPerf {
  q: number
  label: string
  hive_s: number | null
  spark_s: number | null
}

export interface Performance {
  queries: QueryPerf[]
  cpu: { hive_pct: number | null; spark_pct: number | null }
  mem: { hive_used_mib: number | null; spark_used_mib: number | null; total_mib: number | null }
  totals: { hive_s: number | null; spark_s: number | null }
  source: { hive: string | null; spark: string | null }
}

export interface Dashboard {
  performance: Performance
  agentic: AgentRecord[]
  comparison_md: string
}
