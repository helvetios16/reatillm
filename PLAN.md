# PLAN — Data Engineering para Retail (Hive, Spark y LLM)

> **Curso:** BigData 2026A — UNSA · Escuela de Ciencia de la Computación
> **Trabajo:** Unidad II — *Data Engineering para Retail utilizando Hive, Spark y LLM*
> **Spec:** [`proyecto02.pdf`](./proyecto02.pdf) · **Emitido:** 2026-06-10 · **Entrega:**
> sin fecha dura en el PDF ("hasta la hora indicada por el profesor") — plazo flexible.

---

## Objetivo

Montar una plataforma de análisis sobre un **Data Warehouse Retail (TPC-DS, 10 GB)** en
**Amazon EMR**, comparar el rendimiento de **Apache Hive (HiveQL)** vs **Apache Spark
(Spark SQL)**, y añadir una **capa de análisis agéntico con LLM (Gemini)** que traduzca
lenguaje natural → SQL mediante el paradigma de *skills*.

**Tablas obligatorias:** `customer`, `item`, `store`, `date_dim`, `store_sales`
(`store_sales` = tabla de hechos FACT; el resto, dimensiones).

---

## Cómo vamos a trabajar (filosofía, heredada de `sparky`)

El directorio `/Users/sebastian/Documents/Variety/sparky` ya resolvió la parte difícil:
crear clúster EMR, correr Spark sobre S3 y **medir CPU/memoria/tiempo automáticamente**
(`monitor.sh` + `correlate.sh`). **Clonamos ese patrón** para `retaillm` en vez de
reinventarlo.

**Regla de oro:** verificar la lógica en local (sin gastar clúster) → un solo clúster
para todo → medir → terminar el clúster.

**Automatización (preferencia del usuario):** los scripts automatizan **lo más posible**
— idealmente un comando por fase que orqueste todo el flujo (prender EC2 → generar → subir
→ verificar → apagar). Lo **manual** lo hace el usuario: pegar las credenciales temporales
del AWS Academy Learner Lab y arrancar el lab. Scripts con defaults sensatos, sin recetas
largas de copiar/pegar.

Tenemos **dos repos gemelos** ya probados de donde copiar:
- **`/Users/sebastian/Documents/Variety/sparky`** → lado **Spark** (`run_spark.sh`,
  `pyspark_shell.sh`, `monitor.sh` con muestreo CPU/mem, `correlate.sh`, `verify_local.sh`).
- **`/Users/sebastian/Documents/Variety/hive_big`** → lado **Hive** (`hql/{setup,partition,queries}.hql`,
  `run_hive.sh` que crea cluster con `Name=Hadoop Name=Hive` y corre `.hql` como step,
  `hive_shell.sh` sesión interactiva vía EC2 Instance Connect).

**Nuevo / a construir (aquí va el esfuerzo real):**
1. Generar datos **TPC-DS** (ambos repos usaban datasets ya en S3).
2. **Fusionar** los dos harness en uno solo (`retaillm/` con Hive **y** Spark sobre el
   mismo cluster y los mismos datos S3) y, sobre todo, **generalizar `monitor.sh`** para
   medir CPU/mem de **`hive -f`** además de `spark-submit` (hive_big no mide CPU/mem, solo
   "Time taken") — esto es lo que habilita la comparación 6.3 real.
3. La **capa agéntica con Gemini** (totalmente nuevo — el diferenciador).

---

## Fases

| Fase | Nombre | Cubre del PDF | ¿Reutiliza sparky? |
|------|--------|---------------|---------------------|
| **0** | **Andamiaje y entorno** — adaptar los scripts de sparky a retaillm (estructura `retaillm/`, `run_emr.sh`, `monitor.sh`, `verify_local.sh`, `reuse_cluster.sh`) | Infra base | ✅ Casi tal cual |
| **1** | **Datos TPC-DS** — compilar tpcds-kit, generar 10 GB, subir las 5 tablas a S3 | Sec. 3, 4 | ⚠️ Patrón S3, generación nueva |
| **2** | **Data Warehouse** — DDL de las 5 tablas en Hive y lectura/vistas en Spark | Obj. a, b | 🆕 Nuevo (modelo dimensional) |
| **3** | **Consultas analíticas (6.1)** — las 9 consultas en **HiveQL** y en **Spark SQL** | Sec. 6.1; Obj. c, d | ✅ Estructura del job `.py` de taxiscope |
| **4** | **Comparación de rendimiento (6.3)** — tiempo, CPU, memoria Hive vs Spark | Sec. 6.3; Obj. e | ✅ `monitor.sh` + `correlate.sh` |
| **5** | **Capa agéntica con Gemini (6.2)** — skills NL→intención→SQL→ejecución→presentación | Sec. 6.2; Obj. f, g | 🆕 Totalmente nuevo |
| **6** | **Comparación manual vs agéntico (6.4)** + ventajas/limitaciones | Sec. 6.4; Obj. h | 🆕 Nuevo |
| **7** | **Entregable** — PDF con resultados + plus (visualización, gráficos, insights) | Sec. IV | 🆕 Nuevo |

### Dependencias

```
0 ─→ 1 ─→ 2 ─→ 3 ─→ 4
              └─→ 5 ─→ 6
        (4, 5 y 6 alimentan) ─→ 7
```

- `0→1→2→3` es la cadena obligatoria y secuencial.
- Las fases **4** y **5** parten ambas de la **3** (consultas ya escritas); orden libre una vez hay clúster con datos.
- La fase **6** necesita la **3** (manual) y la **5** (agéntico).
- La fase **7** consolida todo.

---

## Decisiones

- [x] **Hive real (Hive CLI / Beeline)** — EMR con apps `Hadoop + Hive + Spark`.
      HiveQL corre en **Tez** (motor por defecto en EMR 7, genuinamente distinto a
      Spark) → la comparación 6.3 es legítima. DDL y consultas en `.hql` vía
      `hive -f`/beeline; lado Spark en `.py` con `spark.sql()`.
- [x] **Generar TPC-DS desde cero** con `tpcds-kit` (`dsdgen -SCALE 10`) → subir las
      5 tablas `.dat` a S3. No se reutiliza dataset existente.
- [x] **Estrategia de scaffolding:** **copiar + adaptar** los scripts de `sparky` y
      `hive_big` (heredar lo ya probado), no reescribir desde cero.
- [x] **Bucket de datos:** `entrepot-retail-tpcds-20260610`
      (*entrepôt de données* = "Data Warehouse" en francés; sin tildes/mayúsculas por reglas S3).
- [x] **Definición de "ventas"/"ingresos" = `ss_net_paid`** (lo pagado por el cliente,
      tras descuentos, antes de impuestos). `SUM(ss_net_paid)` = ingreso/ventas;
      `SUM` por cliente = gasto total; ticket promedio = promedio del total por
      `ss_ticket_number`. "Nº de compras" = `COUNT(DISTINCT ss_ticket_number)`.
      Excepción: "productos más vendidos" (6.2) = `SUM(ss_quantity)` (unidades).
- [x] **Tablas externas `TEXTFILE` + JOINs (sin particionar).** Las 5 tablas como
      `EXTERNAL` sobre los `.dat` crudos en S3; Hive y Spark leen *exactamente* los
      mismos bytes → comparación 6.3 limpia y justa. No se materializa Parquet.
- [x] **El agente Gemini ejecuta sobre el cluster EMR real** (Hive o Spark vivos,
      reusando el SSH de `monitor.sh`/`hive_shell.sh`). La selección de motor
      (Skill 3) es real, no simulada.
- [x] **Plus (Fase 7) = gráficos matplotlib** desde los resultados de las 9 consultas
      + insights escritos.
- [x] **Hive y Spark comparten el Hive Metastore en EMR** (`spark.sql.catalogImplementation
      =hive` por defecto). Las 5 tablas se crean **una sola vez** con el DDL Hive
      (`setup.hql`) y quedan visibles para `hive -f`, `spark.sql()` y `spark-sql -e` por
      el mismo nombre. → Hive y Spark leen la *misma* definición de tabla (6.3 más justa)
      y el Skill 4 del agente puede ejecutar en cualquiera de los dos. `schema.py`
      (`read.csv`) queda **solo** para `verify_local` offline (sin metastore).
- [x] **Lado Spark de 6.1 = PySpark `queries.py`** (con `spark.sql()` sobre las tablas
      del metastore, patrón taxiscope) + `queries.hql` Hive en paralelo. Las consultas
      son el mismo SQL salvo dialecto; se cuida el subconjunto común (RANK/OVER,
      COUNT DISTINCT, JOIN — compatibles en ambos).
- [x] **Medición 6.3 = master como proxy.** `monitor.sh` muestrea CPU/mem en el MASTER
      (driver). El cómputo distribuido vive en los nodos CORE → se **declara como
      limitación** en 6.3/6.4: el *tiempo* es real; CPU/mem del master es indicativo, no
      la carga total del clúster.
- [x] **Skill 3 (agente) elige UN motor** (Hive o Spark) por pregunta y ejecuta ahí
      (lo que pide el PDF), no corre ambos.
- [ ] **Dimensionamiento del clúster:** sparky usó 1 master + 4 core m4.large.
      TPC-DS 10 GB + Hive puede pedir un poco más. Se afina en la Fase 0/1.

---

## Entorno (heredado de sparky)

- **Cuenta AWS:** AWS Academy Learner Lab `136372089807`, rol `voclabs` (smendozaf@unsa.edu.pe)
- **Región:** us-east-1 · **EMR:** 7.0.0 (Hadoop + Hive + Spark) · **Instancias:** m4.large
- ⚠️ **Learner Lab con tiempo límite** → terminar el clúster al final de cada sesión.

---

## Detalle de fases

<!-- Se irá completando a medida que profundizamos cada fase. -->

### Fase 0 — Andamiaje y entorno  ✅ COMPLETADA (2026-06-15)

**Estrategia:** copiar + adaptar (heredar lo probado de `sparky` y `hive_big`).
**Bucket:** `entrepot-retail-tpcds-20260610`.

**Hecho:** estructura `retaillm/` creada + 8 scripts escritos y validados (`bash -n` OK,
ejecutables). `correlate.sh` probado con datos sintéticos (parsea marcadores Hive y Spark).
`.gitignore` ampliado (`.emr_state`, `data/tpcds/*`, `results/*`, cachés). Sin tocar AWS.

| Script | Rol | Origen |
|--------|-----|--------|
| `scripts/cluster/run_emr.sh` | crea 1 cluster Hadoop+Hive+Spark, sube artefactos, corre `setup.hql` (tablas en metastore) | fusión run_spark+run_hive |
| `scripts/cluster/reuse_cluster.sh` | apunta `.emr_state` a un cluster vivo (sin crear) | sparky, simplificado |
| `scripts/cluster/cleanup.sh` | termina cluster + borra artefactos, PRESERVA `raw/` | sparky/hive_big |
| `scripts/shell/hive_shell.sh` | sesión Hive interactiva en el master | hive_big, layout plano |
| `scripts/shell/pyspark_shell.sh` | sesión pyspark interactiva | sparky, layout plano |
| `scripts/measure/monitor.sh` | mide CPU/mem/tiempo con `--engine hive\|spark` | sparky, generalizado |
| `scripts/measure/correlate.sh` | mapea pico CPU → consulta (Hive y Spark) | sparky, isHeader adaptado |
| `scripts/measure/verify_local.sh` | valida el SQL Spark en local (uv+pyspark+jdk4py); degrada si falta Fase 2/3 | sparky |

**Pendiente de afinar en fases siguientes:** `monitor.sh`/`verify_local.sh` referencian
`queries.{hql,py}` y `setup.hql` (Fases 2-3); la convención `queries.py --sample <dir>` de
`verify_local` se fija en la Fase 3.

**Meta:** dejar lista la estructura de `retaillm/` y los scripts de ciclo de vida del
clúster, adaptando lo de `sparky`, **antes** de generar datos o escribir consultas. Que
crear/reutilizar/medir/terminar el clúster sea un comando, no una receta manual.

**Estructura objetivo del repo:**

```
retaillm/
├── PLAN.md
├── proyecto02.pdf
├── .emr_state             # estado del cluster (runtime; gitignored)
├── scripts/               # subcarpetas por función
│   ├── cluster/           # ciclo de vida del cluster
│   │   ├── run_emr.sh         # crea cluster Hadoop+Hive+Spark, sube artefactos, setup.hql
│   │   ├── reuse_cluster.sh   # apunta .emr_state a un cluster vivo (sin crear)
│   │   └── cleanup.sh         # termina cluster + borra artefactos, PRESERVA raw/
│   ├── shell/            # sesiones interactivas en el master
│   │   ├── hive_shell.sh      # Hive CLI vía EC2 Instance Connect
│   │   └── pyspark_shell.sh   # pyspark REPL
│   ├── measure/         # medición + verificación
│   │   ├── monitor.sh         # CPU/mem/tiempo; --engine hive|spark (ADAPTADO)
│   │   ├── correlate.sh       # mapea pico de CPU → consulta
│   │   └── verify_local.sh    # lógica Spark en local sin AWS (uv+pyspark+jdk4py)
│   └── data/            # generación TPC-DS (Fase 1)
│       ├── generate_tpcds.sh    # orquestador 1 comando: EC2 → genera → sube → termina
│       ├── connect_generator.sh # SSH a la EC2 generadora (debug)
│       └── terminate_generator.sh
├── data/tpcds/sample/    # muestra local para verify_local (Fase 1)
├── warehouse/
│   ├── hive/ddl/setup.hql     # CREATE EXTERNAL TABLE de las 5 tablas (Fase 2)
│   └── spark/schema.py        # read.csv + vistas para verify_local (Fase 2)
├── queries/
│   ├── hive/queries.hql       # las 9 consultas en HiveQL (Fase 3)
│   └── spark/queries.py       # las 9 consultas en Spark SQL (Fase 3)
├── agentic/skills/       # capa Gemini NL→SQL, 5 skills (Fase 5)
└── results/              # mediciones y salidas (Fases 4, 6; gitignored)
```

**Qué se reutiliza casi tal cual (copiar + reapuntar rutas/bucket):**
- de **`sparky`**: `reuse_cluster.sh`, `cleanup.sh`, `pyspark_shell.sh`, `correlate.sh`,
  `verify_local.sh` (patrón `uv run --with pyspark==3.5.3 + jdk4py` para validar la lógica
  Spark sin gastar clúster).
- de **`hive_big`**: `hive_shell.sh` (sesión Hive interactiva vía EC2 Instance Connect — ya
  resuelve SSH al master, apertura de puerto 22, key efímera), y el esqueleto de `run_hive.sh`
  (creación de cluster con Hive + lanzar `.hql` como step con timer).

**Qué hay que ADAPTAR / FUSIONAR (lo nuevo de esta fase):**
1. **`run_emr.sh`** = fusión de `sparky/run_spark.sh` + `hive_big/run_hive.sh`. Un solo cluster
   con `--applications Name=Hadoop Name=Hive Name=Spark`, que sube **los `.hql` y los `.py`** a S3.
2. **`monitor.sh`** = el de sparky (mide CPU/mem de `spark-submit`) generalizado a
   `--engine hive|spark`, para muestrear CPU/mem mientras corre **`hive -f` _o_ `spark-submit`**.
   ⚠️ Es lo más nuevo: `hive_big` **no** mide CPU/mem (solo "Time taken"). Este script es el que
   hace posible la comparación 6.3 (tiempo **+ CPU + memoria**) sobre los dos motores reales.
3. **DDL de datos `.dat`**: TPC-DS genera texto delimitado por `|`, así que el `setup.hql` será
   `ROW FORMAT DELIMITED FIELDS TERMINATED BY '|' STORED AS TEXTFILE` (no `STORED AS PARQUET`
   como en hive_big). Detalle de Fase 2, pero condiciona el formato en que subimos datos en Fase 1.

**Dimensionamiento inicial:** arrancar con 1 master + 4 core m4.large (como sparky); subir
core-count si Hive sobre 10 GB va lento. Bucket de datos: `entrepot-retail-tpcds-20260610`.

**Salida de la fase:** scripts ejecutables (validados con `bash -n`, sin tocar AWS todavía) y
la estructura de carpetas creada. Aún **no** se crea clúster ni se gastan recursos.

**Confirmado:** copiar + adaptar los scripts de `sparky`/`hive_big` (no reescribir);
bucket `entrepot-retail-tpcds-20260610`.

### Fase 1 — Datos TPC-DS  ✅ COMPLETADA (scripts) (2026-06-15)

**Meta:** generar el dataset TPC-DS (scale factor 10) con `tpcds-kit` y dejar las **5 tablas
obligatorias** en S3, una carpeta por tabla, listas para que Hive y Spark las lean.

**Hecho:** 3 scripts en `scripts/data/`, validados (`bash -n` incl. el script remoto embebido;
enrutado `sed` por tabla probado). **Aún no ejecutados** (requiere lab AWS activo).

| Script | Rol |
|--------|-----|
| `scripts/data/generate_tpcds.sh` | **orquestador de 1 comando**: lanza EC2 → genera+sube → verifica → termina |
| `scripts/data/connect_generator.sh` | SSH a la EC2 generadora (depurar una corrida con `--keep`) |
| `scripts/data/terminate_generator.sh` | limpieza manual de la EC2 si quedó viva |

**Decisiones de implementación (más allá del PLAN inicial):**
- **Instance profile `LabInstanceProfile`** (rol `LabRole` del Learner Lab) en la EC2, para que
  el `aws s3 cp` **dentro** de la instancia tenga permiso de escritura a S3. Flag `--instance-profile`.
- **Idempotencia por marcador `raw/_SUCCESS`**: si existe, se omite la generación (`--force` regenera).
  El bucket se crea si falta.
- **`trap EXIT` termina la EC2 siempre** (éxito, fallo o Ctrl+C), salvo `--keep`. Sin fugas de saldo.
- **Generación + subida corren EN la EC2** sobre una sola sesión SSH (EC2 Instance Connect, sin
  key pair), igual que `monitor.sh`. Disco **40 GB EBS gp3**; datos en `~/tpcds-data`.

#### ¿Dónde generar? → EC2 Linux (sandbox), no en el Mac ni en el master EMR

`tpcds-kit` se compila con `gcc`/`make` en Linux; en macOS (Darwin) es quisquilloso y subir
10 GB desde casa es lento. Generamos en una **EC2 Amazon Linux 2023** (que ya tiene `gcc`/`make`
vía `yum` y sube a S3 a velocidad de AWS), y la terminamos al acabar. **Reutilizamos
`hive_big/sandbox/`** (`launch_test_instance.sh` + `connect_test_instance.sh`: lanzan AL2023 y
entran por EC2 Instance Connect sin key pair). No tocamos el cluster EMR (caro y con tiempo límite)
para esto.

**Adaptaciones al sandbox** (vs el original t2.micro):
- Instancia más grande para compilar/generar: **`c5.xlarge`** (4 vCPU) o `m5.xlarge`.
- **Volumen EBS mayor**: el root de AL2023 es ~8 GB y no caben 10 GB de datos → añadir
  `--block-device-mappings` con ~40 GB.

#### Herramienta: `tpcds-kit` (fork de gregrahn)

Usamos `github.com/gregrahn/tpcds-kit` (compila en Linux/gcc modernos; el zip oficial de TPC es
más viejo y áspero). Solo necesitamos **`dsdgen`** (generador de datos); **no** `dsqgen` (generador
de las 99 consultas del benchmark) porque escribimos nuestras propias 9 consultas.

```bash
# en la EC2:
sudo yum -y install gcc make flex bison git
git clone https://github.com/gregrahn/tpcds-kit.git
cd tpcds-kit/tools && make OS=LINUX        # produce ./dsdgen y ./dsqgen
```

#### Qué generar — DECIDIDO: SF10 completo (24 tablas, ~10 GB en S3)

Generamos el **dataset entero a SF10** (≈10 GB reales en S3 → "10 GB" literal del PDF, a prueba de
objeciones), pero en Fase 2 solo creamos tablas Hive/Spark para las **5 obligatorias**. El resto
de tablas quedan en S3 sin usarse.

```bash
mkdir -p /data
# dataset completo en paralelo (4 trozos). Sin -TABLE => las 24 tablas.
for C in 1 2 3 4; do
  ./dsdgen -SCALE 10 -PARALLEL 4 -CHILD $C -DIR /data -FORCE -DELIMITER '|' &
done; wait
```

Tamaños aprox. a SF10 de **las 5 que sí usaremos** (el total de 24 tablas ≈ 10 GB):

| Tabla | Filas aprox. (SF10) | Tamaño | Rol |
|-------|--------------------|--------|-----|
| `store_sales` | ~28.8 M | ~2.6 GB | hechos (FACT) |
| `customer` | ~500 K | ~75 MB | dimensión |
| `item` | ~102 K | ~5 MB | dimensión |
| `date_dim` | ~73 K | ~10 MB | dimensión |
| `store` | ~102 | <1 MB | dimensión |

Con `-PARALLEL 4`, las tablas grandes salen en trozos (`store_sales_1_4.dat` … `_4_4.dat`); las
pequeñas en un solo archivo.

#### Layout en S3 (una carpeta por tabla)

Subimos las **24 tablas** (para los ~10 GB reales), cada una a su prefijo → cada `CREATE EXTERNAL
TABLE` de Hive apunta a su `LOCATION` (igual que hive_big enrutaba `raw_a/` `raw_b/`). Las 5 que
usamos:

```
s3://entrepot-retail-tpcds-20260610/raw/
  ├── customer/customer_1_4.dat … customer_4_4.dat
  ├── item/item_1_4.dat … item_4_4.dat
  ├── date_dim/date_dim_1_4.dat … date_dim_4_4.dat
  ├── store/store_1_4.dat … store_4_4.dat
  ├── store_sales/store_sales_1_4.dat … store_sales_4_4.dat
  └── … (las otras 19 tablas de TPC-DS, en S3 pero sin usar)
```

`dsdgen` nombra los archivos `<tabla>_<child>_<parallel>.dat`; un loop los enruta a
`raw/<tabla>/` por nombre de archivo.

⚠️ **`-PARALLEL 4` parte TODAS las tablas, no solo las grandes** → `customer`, `item`,
`store`, `date_dim` también salen en 4 trozos (las muy pequeñas como `store`, ~102 filas,
generan trozos minúsculos o vacíos; un trozo vacío en S3 no rompe a Hive/Spark, que leen
todo el prefijo). Como cada tabla es un prefijo `raw/<tabla>/` con sus N trozos, da igual
para el `CREATE EXTERNAL TABLE` (apunta al prefijo, no al archivo). Si molestan los trozos
vacíos, alternativa: generar las 4 dimensiones pequeñas con un `dsdgen` extra **sin**
`-PARALLEL` (archivo único por tabla).

#### Gotchas a tener presentes (condicionan Fase 2)

- **Formato `.dat`**: texto delimitado por `|`, sin cabecera → Hive `ROW FORMAT DELIMITED FIELDS
  TERMINATED BY '|' STORED AS TEXTFILE`.
- **Pipe final**: `dsdgen` termina cada fila con un `|` extra (campo vacío sobrante). Hive ignora
  el campo de más si la tabla declara exactamente sus N columnas → no rompe, pero hay que saberlo.
- **Orden/columnas fijas**: el esquema de cada tabla viene del spec TPC-DS (`tools/tpcds.sql` del
  kit trae el DDL ANSI que adaptaremos a Hive en Fase 2): `store_sales` 23 col, `customer` 18,
  `item` 22, `date_dim` 28, `store` 29.

#### Nuevo script de la fase: `scripts/generate_tpcds.sh` (orquestador de 1 comando)

Según la preferencia de automatización, el script corre **desde el Mac** y hace TODO el flujo solo:

1. Prende la EC2 generadora (`c5.xlarge` + 40 GB EBS) — reusa `launch_test_instance.sh`.
2. Por SSH (EC2 Instance Connect), ejecuta en remoto: instalar toolchain → `git clone` tpcds-kit
   → `make OS=LINUX` → `dsdgen -SCALE 10 -PARALLEL 4`.
3. Sube los `.dat` a `s3://…/raw/<tabla>/` (el `aws s3 cp` corre **dentro** de la EC2 → rápido).
4. Verifica (`aws s3 ls --summarize --human-readable`).
5. **Apaga la EC2** (`terminate_test_instance.sh`).

Lo único manual: que el usuario tenga las credenciales del Learner Lab pegadas y el lab activo.
Hereda el patrón idempotente de `download_data.sh` (crea bucket si no existe, omite lo ya subido).

#### Salida de la fase

- Dataset SF10 (~10 GB, 24 tablas) en `s3://entrepot-retail-tpcds-20260610/raw/<tabla>/`,
  con las 5 obligatorias listas para usarse.
- Verificación de ~10 GB y recuento de archivos por `aws s3 ls --summarize --human-readable`.
- EC2 sandbox **terminada** (`terminate_test_instance.sh`) para no gastar saldo.
- **Muestra local para `verify_local`:** antes de apagar la EC2 (o con `aws s3 cp` después),
  bajar unos pocos MB (p.ej. `head` de cada `.dat` o un `dsdgen -SCALE 1` mínimo) a
  `data/tpcds/sample/` para validar el SQL Spark offline sin metastore ni clúster.
- (Aún sin cluster EMR — eso es Fase 2.)
- ℹ️ Las cardinalidades de la tabla de arriba son **aproximadas**; las exactas salen del kit
  al generar (`date_dim` ~73K y `store_sales` ~28.8M sí son firmes).

#### Decisiones — RESUELTAS

- [x] **"10 GB" = SF10 completo (24 tablas, ~10 GB reales en S3)**; Hive/Spark solo usan las 5.
- [x] **Instancia generadora:** `c5.xlarge` (4 vCPU) + **40 GB EBS**, Amazon Linux 2023, terminada al acabar.

### Fase 2 — Data Warehouse  ✅ COMPLETADA (2026-06-15)  (Obj. a, b)

**Meta:** declarar las **5 tablas obligatorias** como modelo dimensional sobre los `.dat`
ya en S3 — en **Hive** (`CREATE EXTERNAL TABLE`) y exponer las mismas en **Spark**
(vistas temporales) — para que las consultas de la Fase 3 corran idénticas en ambos motores.

**Hecho:** `warehouse/hive/ddl/setup.hql` (5 tablas EXTERNAL, columnas/orden/tipos exactos del
spec: customer 18, item 22, store 29, date_dim 28, store_sales 23) + `warehouse/spark/schema.py`
(5 `StructType` con dummy `_extra` para el pipe final; `load_dw` solo para verify_local).
**Validado con PySpark local** (smoke-test): los 5 esquemas parsean, `_extra` se descarta,
`SUM(ss_net_paid)` y `COUNT(DISTINCT ss_ticket_number)` dan resultados correctos en un JOIN
store_sales⋈store. Conteo de columnas HQL↔schema verificado.

**Modelo dimensional (esquema estrella):** `store_sales` (FACT) en el centro; `customer`,
`item`, `store`, `date_dim` (dimensiones). Claves de join:
`ss_customer_sk→c_customer_sk`, `ss_item_sk→i_item_sk`, `ss_store_sk→s_store_sk`,
`ss_sold_date_sk→d_date_sk`.

**Lado Hive — `warehouse/hive/ddl/setup.hql`** (adapta `hive_big/.../setup.hql`):
- 5 × `CREATE EXTERNAL TABLE … ROW FORMAT DELIMITED FIELDS TERMINATED BY '|' STORED AS
  TEXTFILE LOCATION '${hivevar:<TABLA>}'` apuntando a `s3://…/raw/<tabla>/`.
- Columnas y tipos **exactos del spec TPC-DS** (vienen de `tools/tpcds.sql` del kit):
  `store_sales` 23 col, `customer` 18, `item` 22, `date_dim` 28, `store` 29. Tipos:
  los `*_sk` y `*_number`/`quantity` → `BIGINT`/`INT`; importes (`ss_net_paid`,
  `ss_sales_price`, `i_current_price`…) → `DECIMAL(7,2)`; fechas (`d_date`) → `DATE` o
  `STRING`; descriptivos → `STRING`.
- ⚠️ **Pipe final de `dsdgen`**: cada fila termina en `|` extra. Declarando exactamente
  las N columnas, Hive ignora el campo sobrante → no rompe (ya anotado en Fase 1).
- Locations vía `-hivevar` (como hace `run_hive_step` en hive_big): un hivevar por tabla.

**Lado Spark — vía el Hive Metastore compartido (no requiere re-declarar tablas).**
En EMR Spark usa el metastore de Hive por defecto, así que **al correr `setup.hql` las 5
tablas ya son visibles para Spark** por nombre: `spark.sql("SELECT … FROM store_sales")`.
No hace falta `spark.read.csv` en el clúster → Hive y Spark leen la *misma* definición de
tabla (comparación 6.3 más justa) y el Skill 4 del agente puede usar `spark-sql -e`.

- `warehouse/spark/schema.py` (`load_dw(spark, bucket)` con `spark.read.csv(sep='|',
  schema=<StructType>)` + `createOrReplaceTempView`) se conserva **solo para
  `verify_local`** (offline, sin metastore). Usa los **mismos nombres de tabla** que el
  metastore, de modo que `queries.py` corre igual en clúster (catálogo del metastore) y en
  local (vistas temporales).

**Gotchas de la fase:**
- ⚠️ **Pipe final en Spark (≠ Hive).** Hive ignora el campo vacío sobrante; el lector CSV de
  Spark puede marcar la fila como corrupta al ver N+1 tokens. **Fix:** declarar en el
  `StructType` una **columna dummy final** (`_extra STRING`) que absorba el `|` de cierre, o
  preprocesar. (Solo afecta el camino `schema.py`/verify_local; en el metastore las leen las
  tablas Hive.)
- ⚠️ **Claves foráneas NULL (~4% por diseño de TPC-DS).** `store_sales` trae FKs nulas;
  los `INNER JOIN` con `date_dim`/`customer`/`store` descartan esas filas. No es error, pero
  hay que aplicar el **mismo criterio** en las 9 consultas y en el SQL del agente.

**Salida:** `setup.hql` + `schema.py` validados (`bash -n`; `schema.py` con `verify_local.sh`
sobre una muestra). Sin tocar AWS todavía si seguimos la regla de oro.

**Decisiones de la fase — RESUELTAS:** tablas `EXTERNAL TEXTFILE` (no Parquet, no
particionar); ingresos = `ss_net_paid`; Spark lee del **metastore compartido** (no
re-declara), `schema.py` solo para verify_local.

---

### Fase 3 — Consultas analíticas (6.1)  ✅ COMPLETADA (2026-06-16)  (Obj. c, d)

**Meta:** las **9 consultas** de 6.1, escritas **una sola vez como SQL** y ejecutadas en
los dos motores: `queries/hive/queries.hql` (`hive -f`) y `queries/spark/queries.py`
(`spark.sql()` sobre las vistas de la Fase 2). Mismo SQL → resultados idénticos → la
comparación 6.3 mide *motor*, no *consulta*.

**Hecho:** `queries/hive/queries.hql` (9 consultas + marcadores `=== Qn ===` para correlate)
y `queries/spark/queries.py` (mismo SQL vía `spark.sql`, `--query 1..9|all`, `--sample` para
verify_local; usa el metastore en el clúster). Muestra sintética en `data/tpcds/sample/`
(5 tablas, claves de join coherentes, 1 venta con FK NULL). **Validado end-to-end con
`verify_local.sh`: 6/6 aserciones OK** — las 9 consultas corren y los valores cuadran
(Centro=310, Cafe=260/tienda, ticket Beto=107.50, gasto Beto=215), confirmando que las FK
NULL se descartan en los JOIN con customer pero no en los de store/item/date.

**Mapa de las 9 consultas** (FACT `store_sales` ⋈ dimensiones; ingreso = `SUM(ss_net_paid)`):

| # | Consulta (6.1) | Esbozo SQL |
|---|----------------|-----------|
| 1 | Top 20 clientes por **nº de compras** | `ss ⋈ customer`, `COUNT(DISTINCT ss_ticket_number)`, `ORDER BY … DESC LIMIT 20` |
| 2 | **Ventas por tienda** | `ss ⋈ store`, `SUM(ss_net_paid)` group by `s_store_name` |
| 3 | **Ventas por mes** | `ss ⋈ date_dim`, group by `d_year, d_moy`, `SUM(ss_net_paid)` |
| 4 | **Ventas por día de la semana** | `ss ⋈ date_dim`, group by `d_day_name`, `SUM(ss_net_paid)` |
| 5 | **Top productos por tienda** | `ss ⋈ item ⋈ store`, `SUM(ss_net_paid)`, `RANK() OVER (PARTITION BY store ORDER BY … DESC)` |
| 6 | **Ticket promedio por cliente** | subquery `SUM` por `(c_customer_sk, ss_ticket_number)` → `AVG` por cliente |
| 7 | **Productos con mayor ingreso** | `ss ⋈ item`, `SUM(ss_net_paid)` group by `i_item_id/i_product_name`, `ORDER BY DESC` |
| 8 | **Top clientes por gasto total** | `ss ⋈ customer`, `SUM(ss_net_paid)` group by cliente, `ORDER BY DESC` |
| 9 | **Ranking mensual de ventas** | `ss ⋈ date_dim`, `SUM` por mes + `RANK() OVER (ORDER BY ventas DESC)` |

**Notas de dialecto:** `RANK()/OVER` y `COUNT(DISTINCT)` existen igual en HiveQL y Spark SQL
→ se usa el **subconjunto común** para que el SQL sea casi idéntico en ambos. Único cuidado:
`date_dim` ya trae `d_year/d_moy/d_dow/d_day_name` precomputados → no hace falta parsear
fechas (más limpio que taxiscope, que derivaba `anio/mes` de un timestamp).
**Consistencia:** todas usan `INNER JOIN` (descartan las FKs NULL ~4%, ver Fase 2) con el
mismo criterio, para que Hive, Spark y el agente den exactamente el mismo número.

**Estructura del job Spark — `queries/spark/queries.py`** (patrón taxiscope.py): `--query
1..9|all`; cada consulta es un `spark.sql("…")` **sobre las tablas del metastore** (no
`read.csv`), envuelta en timer (`Time taken: N s`) e impresa con `.show()`. En local,
`queries.py` primero llama a `schema.py.load_dw()` para registrar las vistas con los mismos
nombres (verify_local).

**Lado Hive — `queries/hive/queries.hql`:** las 9 con el mismo SQL, separadas por `;`,
dejando que Hive imprima su `Time taken` nativo. ⚠️ **Marcadores para `correlate.sh`:** antes
de cada consulta, una línea `SELECT '=== Q1: ventas por tienda ==='`; así `correlate` puede
**etiquetar** cada consulta Hive (sin marcadores solo vería los `Time taken` sin nombre, ya
que Hive no emite los headers `print()` que sí tiene el job Spark).

**Salida:** `queries.hql` + `queries.py` con las 9, validadas en local (`verify_local.sh`
sobre muestra reducida para confirmar que el SQL es correcto antes de gastar clúster).

---

### Fase 4 — Comparación de rendimiento (6.3)  (Obj. e)

**Meta:** medir **tiempo + CPU + memoria** de cada motor sobre las mismas 9 consultas y
producir la tabla comparativa Hive vs Spark. Aquí va el trabajo técnico nuevo más fuerte.

**El cambio clave — `scripts/monitor.sh --engine hive|spark`:** generalizar el `monitor.sh`
de sparky (hoy solo `spark-submit`). El armazón —abrir puerto 22, key efímera de EC2
Instance Connect, `sampler()` con `top -bn2` + `mpstat -P ALL` cada `--interval` s en el
master, extracción del **frame pico** por `awk`, pull a `results/<fecha>/`— **se reutiliza tal
cual**. Solo cambia el comando que se mide dentro del script remoto:
- `--engine spark` → `spark-submit /tmp/queries.py --query <q>` (como hoy).
- `--engine hive`  → `hive -f /tmp/queries.hql` (o una consulta suelta). Hive imprime su
  propio `Time taken`; el sampler mide CPU/mem igual que para Spark.
Esto es lo que `hive_big` **no** tenía (solo "Time taken", sin CPU/mem) y lo que hace la 6.3
legítima sobre los **dos motores reales**.

**`correlate.sh` se reutiliza casi sin cambios:** ya mapea cada `Time taken` ↔ ventana ↔ pico
de CPU leyendo `job.out` (líneas con `[HH:MM:SS]`) y `snaps.log`, y el script remoto antepone
la hora a cada línea. Segmenta por `Time taken` igual en Hive. **Único añadido:** las líneas
marcador `SELECT '=== Qn … ==='` en `queries.hql` (Fase 3) para que las consultas Hive salgan
**etiquetadas** (Hive no emite los headers `print()` del job Spark).

⚠️ **Limitación declarada (va en el informe 6.3/6.4):** `monitor.sh` mide CPU/mem en el
**MASTER** (driver), no en los nodos CORE donde corre el cómputo distribuido. Por tanto el
**tiempo de ejecución es real y comparable**, pero CPU/mem del master es un **indicador**
(driver Spark client-mode vs driver Hive/Tez), no la carga total del clúster. Se reporta como
tal para no sobre-vender la medición.

**Protocolo de medición (regla de oro — un solo clúster):**
1. `run_emr.sh` (Hadoop+Hive+Spark) una vez → setup de tablas (Hive) y vistas (Spark).
2. `monitor.sh --engine hive` sobre las 9 → `results/hive/<fecha>/`.
3. `monitor.sh --engine spark` sobre las 9 → `results/spark/<fecha>/`.
4. `correlate.sh` en cada carpeta → pico de CPU por consulta.
5. Terminar el clúster.

**Salida:** tabla por consulta con `tiempo (s) | pico CPU % | mem`, para Hive y Spark, +
`pico.txt`/`snaps.log` como evidencia. Alimenta la Fase 7.

**A afinar aquí:** dimensionamiento del clúster (decisión abierta). Arrancar 1 master + 4
core m4.large; subir core-count si Hive sobre los 10 GB va lento.

---

### Fase 5 — Capa agéntica con Gemini (6.2)  ✅ IMPLEMENTADA (código, 2026-06-17)  (Obj. f, g)

> **Estado:** las 10 piezas de `agentic/` están escritas y validadas en local:
> `py_compile` + `bash -n` OK; el **backend local de la Skill 4** corre SQL real sobre
> `data/tpcds/sample/` con PySpark y extrae filas correctas (`Tienda_Centro=310.00`, coincide
> con `verify_local`). **Falta** el end-to-end con LLM (S1/S2/S3/S5) y el backend `emr`, que
> requieren `GEMINI_API_KEY` y clúster vivo respectivamente (pasos manuales del usuario).
> Lanzar con `bash agentic/run_agent.sh --target local`.

**Meta:** un agente que recibe preguntas en **lenguaje natural** y, vía **5 skills**, las
traduce a SQL y las ejecuta, devolviendo resultado + insight. Totalmente nuevo — es el
diferenciador del proyecto.

**Estrategia LOCAL-FIRST (clave: se construye SIN la Fase 4).** La Fase 4 NO es prerrequisito
de la 5 (la 5 depende de la 3 + un backend de ejecución; la 6 depende de 3+5). Para poder
desarrollar y validar TODO en el Mac sin AWS, la **Skill 4 tiene dos backends** (`--target`):
- `local` → corre el SQL del agente vía **PySpark sobre `data/tpcds/sample/`**, reusando
  `warehouse/spark/schema.py::load_dw` (igual que `verify_local`). Pipeline completo
  NL→intent→SQL→resultado→insight **sin clúster**.
- `emr` → corre sobre el clúster real (ver Skill 4). Se ejercita recién cuando exista clúster;
  ahí se hacen los ajustes (parseo de stdout, dialecto Hive vs Spark).

**Decisiones de implementación — RESUELTAS (2026-06-17):**
- **SDK = `google-genai`** (el NUEVO; *no* el legacy `google-generativeai`) + modelo **Gemini
  Flash**. JSON mode para S1/S2/S3; reintentos centralizados en `gemini_client.py`. Key desde
  el env `GEMINI_API_KEY`.
- **Ejecución EMR = helper bash.** Se extrae el mecanismo EC2 Instance Connect de
  `scripts/measure/monitor.sh` a `agentic/run_remote.sh` (`run_remote.sh <engine> <sql>` →
  stdout); `s4_execute.py` lo llama por `subprocess`. **No** paramiko (evita duplicar lógica
  ya probada).

**Arquitectura — `agentic/` (Python + `google-genai`):**
```
agentic/
├── agent.py            # orquestador: encadena S1→S5, escribe results/agentic/<n>.json
├── schema_context.py   # 5 tablas (cols + grafo de joins) + glosario → contexto del LLM
├── gemini_client.py    # wrapper del SDK (key del env, modelo Flash, JSON mode, reintentos)
├── run_remote.sh       # helper bash: SQL+engine → SSH al master (extraído de monitor.sh)
├── skills/
│   ├── s1_intent.py    # Skill 1 — Interpretación de intención
│   ├── s2_sql.py       # Skill 2 — Generación de SQL
│   ├── s3_engine.py    # Skill 3 — Selección de motor (Hive|Spark)
│   ├── s4_execute.py   # Skill 4 — Ejecución (backend local | emr)
│   └── s5_present.py   # Skill 5 — Presentación (tabla + insight)
└── questions.txt       # las 5+ preguntas NL de 6.2
```

**Contratos de datos entre skills** (las hace piezas independientes y testeables):

| Skill | Entrada | Salida (JSON) |
|-------|---------|---------------|
| **S1 Intención** | pregunta NL | `{metric, dimension, filters[], order, limit, tables[], needs_window}` |
| **S2 SQL** | intent + `schema_context` | `{sql, explicacion}` |
| **S3 Motor** | intent + sql | `{engine: hive\|spark, razon}` |
| **S4 Ejecución** | sql + engine + target | `{columns[], rows[], time_taken, rc, raw_stdout}` |
| **S5 Presentación** | pregunta + columns/rows | `{tabla_md, insight}` |

**`schema_context.py`** (evita que el SQL alucine): las 5 tablas con sus columnas (derivadas de
`setup.hql`), el **grafo de joins** (`ss_customer_sk→customer`, `ss_item_sk→item`,
`ss_store_sk→store`, `ss_sold_date_sk→date_dim`) y el **glosario de negocio**
(`ingreso/ventas = SUM(ss_net_paid)`, `unidades = SUM(ss_quantity)`, `ticket = por
ss_ticket_number`, usar `INNER JOIN` que descarta ~4% FKs NULL, nunca inventar columnas).

**Las 5 skills (paradigma del PDF):**
1. **Intención** — Gemini clasifica la pregunta → intent estructurado.
   Ej.: *"¿los 5 productos más vendidos?"* → `{metric: SUM(ss_quantity), dimension: item, limit: 5}`.
2. **Generación de SQL** — Gemini genera SQL **restringido a `schema_context`** (5 tablas,
   claves, glosario) → subconjunto común Hive/Spark (mismo dialecto que la Fase 3).
3. **Selección de motor** — heurística (ventanas/CTE/agregación pesada → Spark; lookup/filtro
   simple → Hive) refinada por Gemini, con razón. **Decisión real** porque S4 ejecuta de verdad.
4. **Ejecución** — backend `local` (PySpark/sample) o `emr` (`run_remote.sh`: push de key
   efímera por EC2 Instance Connect, `hive -e` _o_ `spark-sql -e` en el master, lee
   `.emr_state` para el `CLUSTER_ID`). Captura stdout + `Time taken`.
   ✅ En EMR funciona porque las 5 tablas están en el **Hive Metastore compartido** (Fase 2):
   tanto `hive -e` como `spark-sql -e` las ven por nombre, sin re-declarar nada.
5. **Presentación** — formatea el resultado como tabla y Gemini redacta un **insight** corto
   en lenguaje natural.

**Las preguntas NL de 6.2** (mínimo 5): *5 productos más vendidos · tienda con mayores ventas ·
mes con mayores ingresos · 10 mejores clientes · productos con mayores ingresos* (+ libres).
Varias coinciden conceptualmente con consultas de 6.1 → permite **validar** que el SQL
generado por el agente da el mismo resultado que el SQL manual.

**Validación sin clúster (cómo se prueba ahora):**
- End-to-end local: `agent.py --target local` corre las 5+ preguntas sobre la muestra.
- Correctitud vs manual: para las preguntas que coinciden con la Fase 3, comparar el resultado
  del SQL del agente contra `queries.py --sample` → tabla ✓/✗ (anticipo local de la Fase 6).

**Limitaciones conocidas a ajustar con la Fase 4:**
- En `--target local` siempre corre Spark → la elección de motor de S3 se **registra pero no se
  ejerce** hasta el clúster.
- El **parseo de stdout** de `hive -e`/`spark-sql -e` solo se confirma en EMR real.
- Posibles diferencias de **dialecto Hive vs Spark** que la muestra local no revela.

**Orden de implementación sugerido** (cada pieza validable en local): `schema_context.py` →
`gemini_client.py` → `s1_intent.py` → `s2_sql.py` → `s4_execute.py` (local) + `agent.py` mínimo
(primer end-to-end sobre la muestra) → `s3_engine.py`, `s5_present.py`, `questions.txt` →
`run_remote.sh` (backend `emr`, se prueba recién con clúster).

**Pre-requisito operativo (solo para `--target emr`):** clúster vivo + `GEMINI_API_KEY` en el
entorno (lo manual del usuario). API key: aistudio.google.com/api-keys.

**Salida:** `agent.py` corre las 5+ preguntas end-to-end y guarda, por pregunta: NL → intent →
SQL generado → motor elegido → resultado → insight, en `results/agentic/`.

---

### Fase 6 — Comparación manual vs agéntico (6.4)  (Obj. h)

**Meta:** contrastar el flujo **manual** (SQL escrito a mano en Fase 3) vs el **agéntico**
(SQL generado por Gemini en Fase 5) y enumerar **ventajas y limitaciones**.

**Qué se compara** (sobre las preguntas que existen en ambos lados):
- **Correctitud:** ¿el SQL del agente devuelve el mismo resultado que el manual? (diff de
  resultados; tabla ✓/✗ por pregunta).
- **Calidad del SQL:** joins correctos, métrica correcta (`ss_net_paid` vs otra), uso de
  `DISTINCT`, manejo de NULLs.
- **Esfuerzo / accesibilidad:** escribir SQL (requiere conocer el esquema) vs preguntar en
  NL; tiempo del humano.
- **Latencia / costo:** overhead del LLM (intención+generación) sobre el tiempo de ejecución.
- **Selección de motor:** ¿el agente eligió bien Hive/Spark?

**Salida:** tabla comparativa + sección de **ventajas** (accesibilidad sin SQL, rapidez de
exploración, selección automática de motor) y **limitaciones** (riesgo de SQL incorrecto/
alucinado, dependencia del contexto de esquema, costo del LLM, no determinismo). Necesita la
Fase 3 (manual) y la Fase 5 (agéntico) ya corridas.

---

### Fase 7 — Entregable  (Sec. IV + plus)

**Meta:** consolidar todo en un **PDF** con nombre del autor arriba, más el **plus** de
visualización para puntaje extra.

**Contenido:**
1. Intro: DW Retail TPC-DS 10 GB sobre EMR; arquitectura (Hadoop+Hive+Spark, S3, Gemini).
2. Fase 1-2: generación de datos + modelo dimensional (DDL de las 5 tablas).
3. Fase 3: las 9 consultas (SQL) con muestras de resultado.
4. **Fase 4 (6.3):** tabla comparativa Hive vs Spark — tiempo, CPU, memoria — + análisis.
5. **Fase 5 (6.2):** capa agéntica — diagrama de las 5 skills + traza NL→SQL→resultado.
6. **Fase 6 (6.4):** manual vs agéntico — tabla + ventajas/limitaciones.
7. **Plus — `results/plots/` con matplotlib:** un script `scripts/make_plots.py` que toma los
   CSV de resultados (9 consultas + tabla 6.3) y genera **gráficos** (barras: ventas por
   tienda / top productos / top clientes; líneas: ventas por mes, ranking mensual; barras
   comparativas: tiempo y CPU Hive vs Spark) + 3-4 **insights** escritos.

**Salida:** PDF final + carpeta `results/` con evidencia (mediciones, gráficos, trazas del
agente). Subir al aula virtual antes de la hora indicada.
