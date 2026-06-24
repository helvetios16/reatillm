# RUN — Cómo ejecutar retaillm

Guía operativa del proyecto: **Data Warehouse Retail (TPC-DS) sobre Amazon EMR** con
comparación **Hive vs Spark** y una **capa agéntica (LLM)** que traduce lenguaje natural a
SQL, más una **interfaz Vue** (dashboard + consulta en vivo).

> Plan y decisiones de diseño: [`PLAN.md`](./PLAN.md). Esta guía es el "cómo correrlo".

---

## 0. Requisitos

| Herramienta | Para qué | Notas |
|-------------|----------|-------|
| **uv** | entornos Python efímeros (PySpark, agente, comparación) | `curl -LsSf https://astral.sh/uv/install.sh \| sh` |
| **bun** (o npm) | la interfaz Vue (`retail/`) | el scaffold usa bun |
| **opencode** | backend LLM por **defecto** del agente (modelos gratis) | https://opencode.ai |
| **AWS CLI v2** | EMR + S3 (solo para el pipeline a escala) | pega las credenciales del Learner Lab |
| Gemini API key | backend LLM **opcional** (`LLM_BACKEND=gemini`) | en `.env`; el default es opencode |

`.env` (raíz, opcional — solo si usas Gemini):
```
GEMINI_API_KEY=...
```

---

## 1. Interfaz Vue — dashboard + consulta en vivo (local, sin AWS)

La forma más rápida de ver y usar todo. El backend ejecuta el agente sobre la **muestra
local** (`data/tpcds/sample/`); el dashboard lee resultados ya calculados.

```bash
cd retail
bun install                 # solo la 1ª vez
bun run build               # compila la app a dist/
bash run_ui.sh              # backend + app -> http://localhost:8000
```

- **💬 Consulta en vivo** — escribe (o clic en un ejemplo) y el agente responde
  (NL → intención → SQL → motor → ejecución → insight). El panel lista qué datos hay y
  qué se puede preguntar.
- **6.3 / 6.2 / 6.4** — rendimiento Hive vs Spark, capa agéntica, manual vs agéntico.

Desarrollo con hot-reload: `bun dev` en otra terminal (proxa `/api` al backend).

### Backend LLM (opencode por defecto)

| `LLM_BACKEND` | Cliente | Requiere |
|---------------|---------|----------|
| `opencode` (**default**) | `agentic/opencode_client.py` (CLI, modelos gratis) | `opencode` instalado |
| `gemini` | `agentic/gemini_client.py` (SDK google-genai) | `GEMINI_API_KEY` en `.env` |

```bash
bash run_ui.sh                          # opencode (default)
LLM_BACKEND=gemini bash run_ui.sh       # Gemini (necesita key)
OPENCODE_MODEL=opencode/mimo-v2.5-free bash run_ui.sh   # otro modelo
```

---

## 2. Agente por lotes (6.2) y comparación (6.4) — local

```bash
# Corre las preguntas de agentic/questions.txt sobre la muestra -> results/agentic/q*.json
bash agentic/run_agent.sh --target local
# o una sola pregunta:
bash agentic/run_agent.sh --target local --question "¿Qué tienda tuvo mayores ventas?"

# Compara el SQL del agente vs el manual (Fase 3) sobre la misma muestra -> results/comparison/
bash comparison/run_compare.sh

# Refresca el JSON que consume el dashboard
python3 retail/build_data.py
```

---

## 3. Pipeline a escala en AWS (EMR + S3) — Hive vs Spark a 1–10 GB

> Regla de oro: **un solo clúster** → medir → **terminar**. El Learner Lab factura y caduca.

### 3.1 Datos en S3 (una vez)

Si el bucket ya tiene los datos (`raw/<tabla>/`), salta este paso. Para generarlos:
```bash
bash scripts/data/generate_tpcds.sh --bucket entrepot-retail-tpcds-20260610
# (lanza una EC2, compila tpcds-kit, genera SF1≈1GB / SF10≈10GB, sube a S3 y la termina)
```

### 3.2 Crear el clúster (+ tablas en el metastore)

```bash
bash scripts/cluster/run_emr.sh --core-count 2        # 1 master + 2 core (1 GB)
# crea cluster Hadoop+Hive+Spark, sube artefactos y corre setup.hql (5 tablas EXTERNAL sobre S3)
# guarda CLUSTER_ID/BUCKET/REGION en .emr_state
```

### 3.3 Medir rendimiento Hive vs Spark (6.3)

```bash
bash scripts/measure/monitor.sh --engine hive    # -> results/hive/<fecha>/
bash scripts/measure/monitor.sh --engine spark   # -> results/spark/<fecha>/
# cada uno corre las 9 consultas y muestrea CPU/mem en el master + tiempo por consulta
```

### 3.4 Agente sobre el clúster (camino `--target emr` de la UI)

```bash
# ejecuta el SQL del agente en el clúster real (lee .emr_state)
bash agentic/run_remote.sh hive  "SELECT s.s_store_name, ROUND(SUM(ss.ss_net_paid),2) v
  FROM store_sales ss JOIN store s ON ss.ss_store_sk=s.s_store_sk GROUP BY s.s_store_name ORDER BY v DESC LIMIT 5"
```
(El SQL viaja en base64 por SSH para no romperse; `EC2 Instance Connect`, sin key pair.)

### 3.5 Refrescar el dashboard con la corrida real y TERMINAR el clúster

```bash
python3 retail/build_data.py                              # toma la corrida EMR más reciente
aws emr terminate-clusters --cluster-ids "$(grep CLUSTER_ID .emr_state | cut -d= -f2)" --region us-east-1
# (cleanup.sh borra ddl/hql/spark/logs y .emr_state, PERO pide confirmación interactiva;
#  para terminar sin prompt usa el terminate-clusters de arriba)
```

Verifica que no quede nada facturando:
```bash
aws emr list-clusters --active --query 'Clusters[].Id' --output text     # vacío
aws ec2 describe-instances --filters Name=instance-state-name,Values=running \
  --query 'Reservations[].Instances[].InstanceId' --output text          # vacío
```
Lo único que queda es el bucket S3 con `raw/` (centavos al mes; intencional).

---

## 4. Mapa del repositorio

```
retaillm/
├── PLAN.md / RUN.md          # plan de diseño / esta guía
├── scripts/                  # ciclo de vida del clúster, generación de datos, medición
│   ├── cluster/{run_emr,reuse_cluster,cleanup}.sh
│   ├── data/{generate_tpcds,connect_generator,terminate_generator}.sh
│   └── measure/{monitor,correlate,verify_local}.sh
├── warehouse/                # esquema: hive/ddl/setup.hql + spark/schema.py
├── queries/                  # las 9 consultas 6.1: hive/queries.hql + spark/queries.py
├── agentic/                  # capa LLM (Fase 5)
│   ├── agent.py · llm.py · gemini_client.py · opencode_client.py
│   ├── schema_context.py · run_agent.sh · run_remote.sh
│   └── skills/ (s1..s5)
├── comparison/               # 6.4: compare.py + run_compare.sh
├── retail/                   # interfaz Vue 3 + TS (dashboard + consulta en vivo)
│   ├── build_data.py · server.py · run_ui.sh
│   └── src/{views,components,stores,lib}
├── data/tpcds/sample/        # muestra local para validación offline
└── results/                  # salidas (gitignored): hive/ spark/ agentic/ comparison/
```

---

## 5. Flujo recomendado de principio a fin

1. **Local primero** (sin gastar AWS): `retail/` → ver dashboard y probar consultas con opencode.
2. **Validar lógica**: `agentic/run_agent.sh --target local` + `comparison/run_compare.sh`.
3. **A escala** (cuando haga falta): `run_emr.sh` → `monitor.sh hive|spark` → `run_remote.sh`
   → `build_data.py` → **terminar el clúster**.
