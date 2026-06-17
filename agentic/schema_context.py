#!/usr/bin/env python3
# ============================================================
# schema_context.py  |  retaillm — Fase 5 (capa agéntica, contexto del LLM)
#
# Fuente de verdad LEGIBLE del esquema que se inyecta en los prompts de Gemini
# (S1 intención, S2 SQL). Es deliberadamente texto plano y autocontenido (no
# importa pyspark) para poder construirlo aunque el agente corra en --target emr
# desde el Mac sin pyspark.
#
# Las columnas/joins coinciden con warehouse/hive/ddl/setup.hql y
# warehouse/spark/schema.py (las 5 tablas obligatorias). El glosario fija las
# convenciones de negocio de la Fase 3 (ingreso = ss_net_paid, INNER JOIN, …)
# para que el SQL generado sea correcto y comparable con el manual.
# ============================================================

# (tabla) -> (rol, [columnas]).  Subconjunto de columnas RELEVANTES para análisis
# (no las 23/29 completas: lo justo para que el LLM arme métricas y dimensiones
# sin alucinar nombres). store_sales es la tabla de hechos (FACT).
TABLES = {
    "store_sales": (
        "FACT — una fila por línea de venta (item dentro de un ticket)",
        [
            "ss_sold_date_sk  BIGINT  -- FK -> date_dim.d_date_sk",
            "ss_item_sk       BIGINT  -- FK -> item.i_item_sk",
            "ss_customer_sk   BIGINT  -- FK -> customer.c_customer_sk (puede ser NULL)",
            "ss_store_sk      BIGINT  -- FK -> store.s_store_sk",
            "ss_ticket_number BIGINT  -- id del ticket (varias filas comparten ticket)",
            "ss_quantity      INT     -- unidades vendidas",
            "ss_sales_price   DECIMAL(7,2)",
            "ss_net_paid      DECIMAL(7,2)  -- INGRESO/VENTAS del negocio",
            "ss_net_profit    DECIMAL(7,2)",
        ],
    ),
    "customer": (
        "DIM — clientes",
        [
            "c_customer_sk BIGINT  -- PK",
            "c_customer_id STRING",
            "c_first_name  STRING",
            "c_last_name   STRING",
            "c_birth_year  INT",
            "c_email_address STRING",
        ],
    ),
    "item": (
        "DIM — productos",
        [
            "i_item_sk      BIGINT  -- PK",
            "i_item_id      STRING",
            "i_product_name STRING",
            "i_category     STRING",
            "i_brand        STRING",
            "i_current_price DECIMAL(7,2)",
        ],
    ),
    "store": (
        "DIM — tiendas",
        [
            "s_store_sk   BIGINT  -- PK",
            "s_store_id   STRING",
            "s_store_name STRING",
            "s_city       STRING",
            "s_state      STRING",
        ],
    ),
    "date_dim": (
        "DIM — calendario",
        [
            "d_date_sk   BIGINT  -- PK",
            "d_date      STRING  -- 'YYYY-MM-DD'",
            "d_year      INT",
            "d_moy       INT     -- mes del año (1-12)",
            "d_dom       INT     -- día del mes",
            "d_day_name  STRING  -- nombre del día",
        ],
    ),
}

# Grafo de joins (FK de la FACT -> PK de la dimensión).
JOINS = [
    "store_sales.ss_customer_sk = customer.c_customer_sk",
    "store_sales.ss_item_sk     = item.i_item_sk",
    "store_sales.ss_store_sk    = store.s_store_sk",
    "store_sales.ss_sold_date_sk = date_dim.d_date_sk",
]

# Glosario de negocio (convenciones de la Fase 3).
GLOSSARY = [
    "INGRESO / VENTAS = SUM(ss_net_paid)  (lo pagado por el cliente, tras descuentos, antes de impuestos).",
    "UNIDADES vendidas = SUM(ss_quantity).",
    "GASTO TOTAL de un cliente = SUM(ss_net_paid) agrupado por cliente.",
    "Un TICKET es un ss_ticket_number; 'ticket promedio' = AVG del total por ticket.",
    "Usar SIEMPRE INNER JOIN: descarta las FK NULL (~4%) de forma consistente con el SQL manual.",
    "Importes redondeados con ROUND(x, 2).",
    "NO inventar columnas ni tablas: usar EXCLUSIVAMENTE las 5 tablas y columnas listadas.",
    "Dialecto: subconjunto común Hive / Spark SQL (sirve idéntico en ambos motores).",
]

# Pocos ejemplos (few-shot) para anclar el estilo del SQL al de la Fase 3.
FEWSHOT = [
    (
        "¿Cuáles son los 5 productos con mayor ingreso?",
        "SELECT i.i_item_id, i.i_product_name, ROUND(SUM(ss.ss_net_paid), 2) AS ingreso\n"
        "FROM store_sales ss JOIN item i ON ss.ss_item_sk = i.i_item_sk\n"
        "GROUP BY i.i_item_id, i.i_product_name\n"
        "ORDER BY ingreso DESC LIMIT 5",
    ),
    (
        "¿Qué tienda tiene mayores ventas?",
        "SELECT s.s_store_name, ROUND(SUM(ss.ss_net_paid), 2) AS ventas\n"
        "FROM store_sales ss JOIN store s ON ss.ss_store_sk = s.s_store_sk\n"
        "GROUP BY s.s_store_name\n"
        "ORDER BY ventas DESC",
    ),
]


def _tables_block():
    lines = []
    for name, (role, cols) in TABLES.items():
        lines.append(f"TABLE {name}  ({role})")
        for c in cols:
            lines.append(f"    {c}")
        lines.append("")
    return "\n".join(lines).rstrip()


def schema_prompt():
    """Bloque de texto con esquema + joins + glosario, para inyectar en prompts."""
    parts = ["=== ESQUEMA (5 tablas TPC-DS, esquema estrella) ===", _tables_block()]
    parts.append("\n=== JOINS (FK de la FACT -> PK de la dimensión) ===")
    parts += [f"    {j}" for j in JOINS]
    parts.append("\n=== GLOSARIO / REGLAS DE NEGOCIO ===")
    parts += [f"  - {g}" for g in GLOSSARY]
    return "\n".join(parts)


def fewshot_prompt():
    """Bloque de ejemplos NL -> SQL para anclar el estilo del SQL generado."""
    out = ["=== EJEMPLOS (estilo de SQL esperado) ==="]
    for q, sql in FEWSHOT:
        out.append(f"Pregunta: {q}\nSQL:\n{sql}\n")
    return "\n".join(out).rstrip()


def table_names():
    return list(TABLES.keys())


if __name__ == "__main__":
    # Inspección rápida del contexto que verá el LLM.
    print(schema_prompt())
    print()
    print(fewshot_prompt())
