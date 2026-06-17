#!/usr/bin/env python3
# ============================================================
# queries.py  |  retaillm — Fase 3 (Consultas analíticas 6.1, Spark SQL)
#
# Las 9 consultas de 6.1 vía spark.sql(), con EXACTAMENTE el mismo SQL que
# queries/hive/queries.hql (subconjunto común Hive/Spark) → la 6.3 mide MOTOR.
#
# En el CLÚSTER: las tablas vienen del Hive Metastore compartido (creado por
# setup.hql); spark.sql("... FROM store_sales") las ve por nombre.
#   spark-submit queries.py --query all
#   spark-submit queries.py --query 5
#
# En LOCAL (verify_local, sin metastore): --sample <dir> registra las 5 vistas
# desde una muestra .dat con warehouse/spark/schema.py.
#   queries.py --sample data/tpcds/sample --query all
#
# Ingreso = SUM(ss_net_paid). INNER JOIN descarta FKs NULL (~4%) consistentemente.
# Cada consulta imprime "n. descripción" (header para correlate.sh) y su
# "Time taken: N seconds".
# ============================================================
import argparse
import os
import sys
import time

from pyspark.sql import SparkSession

# (n) -> (descripción, SQL)  — SQL idéntico al de queries.hql
QUERIES = {
    1: ("Top 20 clientes por numero de compras", """
        SELECT c.c_customer_id, c.c_first_name, c.c_last_name,
               COUNT(DISTINCT ss.ss_ticket_number) AS num_compras
        FROM store_sales ss
        JOIN customer c ON ss.ss_customer_sk = c.c_customer_sk
        GROUP BY c.c_customer_id, c.c_first_name, c.c_last_name
        ORDER BY num_compras DESC
        LIMIT 20"""),
    2: ("Ventas por tienda", """
        SELECT s.s_store_name,
               ROUND(SUM(ss.ss_net_paid), 2) AS ventas
        FROM store_sales ss
        JOIN store s ON ss.ss_store_sk = s.s_store_sk
        GROUP BY s.s_store_name
        ORDER BY ventas DESC"""),
    3: ("Ventas por mes", """
        SELECT d.d_year, d.d_moy,
               ROUND(SUM(ss.ss_net_paid), 2) AS ventas
        FROM store_sales ss
        JOIN date_dim d ON ss.ss_sold_date_sk = d.d_date_sk
        GROUP BY d.d_year, d.d_moy
        ORDER BY d.d_year, d.d_moy"""),
    4: ("Ventas por dia de la semana", """
        SELECT d.d_day_name,
               ROUND(SUM(ss.ss_net_paid), 2) AS ventas
        FROM store_sales ss
        JOIN date_dim d ON ss.ss_sold_date_sk = d.d_date_sk
        GROUP BY d.d_day_name
        ORDER BY ventas DESC"""),
    5: ("Top productos por tienda", """
        WITH ventas_prod AS (
          SELECT s.s_store_name, i.i_product_name,
                 ROUND(SUM(ss.ss_net_paid), 2) AS ventas
          FROM store_sales ss
          JOIN item  i ON ss.ss_item_sk  = i.i_item_sk
          JOIN store s ON ss.ss_store_sk = s.s_store_sk
          GROUP BY s.s_store_name, i.i_product_name
        ),
        ranked AS (
          SELECT s_store_name, i_product_name, ventas,
                 RANK() OVER (PARTITION BY s_store_name ORDER BY ventas DESC) AS rk
          FROM ventas_prod
        )
        SELECT s_store_name, i_product_name, ventas, rk
        FROM ranked
        WHERE rk <= 5
        ORDER BY s_store_name, rk"""),
    6: ("Ticket promedio por cliente", """
        WITH tickets AS (
          SELECT ss.ss_customer_sk, ss.ss_ticket_number,
                 SUM(ss.ss_net_paid) AS total_ticket
          FROM store_sales ss
          WHERE ss.ss_customer_sk IS NOT NULL
          GROUP BY ss.ss_customer_sk, ss.ss_ticket_number
        )
        SELECT c.c_customer_id, c.c_first_name, c.c_last_name,
               ROUND(AVG(t.total_ticket), 2) AS ticket_promedio,
               COUNT(*) AS num_tickets
        FROM tickets t
        JOIN customer c ON t.ss_customer_sk = c.c_customer_sk
        GROUP BY c.c_customer_id, c.c_first_name, c.c_last_name
        ORDER BY ticket_promedio DESC
        LIMIT 20"""),
    7: ("Productos con mayor ingreso", """
        SELECT i.i_item_id, i.i_product_name,
               ROUND(SUM(ss.ss_net_paid), 2) AS ingreso
        FROM store_sales ss
        JOIN item i ON ss.ss_item_sk = i.i_item_sk
        GROUP BY i.i_item_id, i.i_product_name
        ORDER BY ingreso DESC
        LIMIT 20"""),
    8: ("Top clientes por gasto total", """
        SELECT c.c_customer_id, c.c_first_name, c.c_last_name,
               ROUND(SUM(ss.ss_net_paid), 2) AS gasto_total
        FROM store_sales ss
        JOIN customer c ON ss.ss_customer_sk = c.c_customer_sk
        GROUP BY c.c_customer_id, c.c_first_name, c.c_last_name
        ORDER BY gasto_total DESC
        LIMIT 20"""),
    9: ("Ranking mensual de ventas", """
        WITH ventas_mes AS (
          SELECT d.d_year, d.d_moy,
                 ROUND(SUM(ss.ss_net_paid), 2) AS ventas
          FROM store_sales ss
          JOIN date_dim d ON ss.ss_sold_date_sk = d.d_date_sk
          GROUP BY d.d_year, d.d_moy
        )
        SELECT d_year, d_moy, ventas,
               RANK() OVER (ORDER BY ventas DESC) AS ranking
        FROM ventas_mes
        ORDER BY ranking"""),
}

# Filas a mostrar por consulta (no afecta la medición; solo la salida).
SHOW_ROWS = {1: 20, 2: 100, 3: 60, 4: 7, 5: 100, 6: 20, 7: 20, 8: 20, 9: 60}


def register_sample(spark, sample_dir):
    """verify_local: registra las 5 vistas desde una muestra .dat con schema.py."""
    root = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    sys.path.insert(0, os.path.join(root, "warehouse", "spark"))
    import schema  # noqa: E402
    schema.load_dw(spark, sample_dir)


def run_query(spark, n):
    desc, sql = QUERIES[n]
    print("\n%d. %s" % (n, desc))
    start = time.time()
    spark.sql(sql).show(SHOW_ROWS.get(n, 50), truncate=False)
    print("  Time taken: %.1f seconds  (consulta %d en Spark SQL)" % (time.time() - start, n))


def main():
    ap = argparse.ArgumentParser(description="Consultas 6.1 en Spark SQL — retaillm")
    ap.add_argument("--query", default="all", help="1..9 o 'all' (default all)")
    ap.add_argument("--sample", default=None,
                    help="dir con muestra .dat (verify_local; sin metastore)")
    args = ap.parse_args()

    builder = SparkSession.builder.appName("retaillm-queries-spark")
    if not args.sample:
        # En el clúster: usa el Hive Metastore compartido (tablas de setup.hql).
        builder = builder.enableHiveSupport()
    spark = builder.getOrCreate()
    spark.sparkContext.setLogLevel("ERROR")

    if args.sample:
        register_sample(spark, args.sample)

    if args.query == "all":
        ns = list(range(1, 10))
    else:
        ns = [int(args.query)]

    for n in ns:
        run_query(spark, n)
    print("")
    spark.stop()


if __name__ == "__main__":
    main()
