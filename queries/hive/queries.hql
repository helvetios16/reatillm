-- ============================================================
-- queries.hql  |  retaillm — Fase 3 (Consultas analíticas 6.1, HiveQL)
--
-- Las 9 consultas de 6.1 sobre el DW TPC-DS. Mismo SQL que queries/spark/queries.py
-- (subconjunto común Hive/Spark) → la comparación 6.3 mide MOTOR, no consulta.
--
-- Ingreso/ventas = SUM(ss_net_paid).  INNER JOIN descarta FKs NULL (~4%, por
-- diseño de TPC-DS) con criterio consistente en las 9.
--
-- Cada consulta va precedida de un marcador  SELECT '=== Qn: ... ===';  para que
-- correlate.sh la ETIQUETE (Hive imprime el literal; el sampler/correlate lo usan).
-- Hive imprime "Time taken: N seconds" tras cada una → ese es el tiempo real.
--
-- Uso (en el master):  hive -f queries.hql   (las tablas vienen del metastore)
-- ============================================================

-- ── Q1: Top 20 clientes por número de compras ────────────────────────
SELECT '=== Q1: Top 20 clientes por numero de compras ===';
SELECT c.c_customer_id, c.c_first_name, c.c_last_name,
       COUNT(DISTINCT ss.ss_ticket_number) AS num_compras
FROM store_sales ss
JOIN customer c ON ss.ss_customer_sk = c.c_customer_sk
GROUP BY c.c_customer_id, c.c_first_name, c.c_last_name
ORDER BY num_compras DESC
LIMIT 20;

-- ── Q2: Ventas por tienda ────────────────────────────────────────────
SELECT '=== Q2: Ventas por tienda ===';
SELECT s.s_store_name,
       ROUND(SUM(ss.ss_net_paid), 2) AS ventas
FROM store_sales ss
JOIN store s ON ss.ss_store_sk = s.s_store_sk
GROUP BY s.s_store_name
ORDER BY ventas DESC;

-- ── Q3: Ventas por mes ───────────────────────────────────────────────
SELECT '=== Q3: Ventas por mes ===';
SELECT d.d_year, d.d_moy,
       ROUND(SUM(ss.ss_net_paid), 2) AS ventas
FROM store_sales ss
JOIN date_dim d ON ss.ss_sold_date_sk = d.d_date_sk
GROUP BY d.d_year, d.d_moy
ORDER BY d.d_year, d.d_moy;

-- ── Q4: Ventas por día de la semana ──────────────────────────────────
SELECT '=== Q4: Ventas por dia de la semana ===';
SELECT d.d_day_name,
       ROUND(SUM(ss.ss_net_paid), 2) AS ventas
FROM store_sales ss
JOIN date_dim d ON ss.ss_sold_date_sk = d.d_date_sk
GROUP BY d.d_day_name
ORDER BY ventas DESC;

-- ── Q5: Top 5 productos por tienda (RANK por tienda) ─────────────────
SELECT '=== Q5: Top productos por tienda ===';
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
ORDER BY s_store_name, rk;

-- ── Q6: Ticket promedio por cliente ──────────────────────────────────
SELECT '=== Q6: Ticket promedio por cliente ===';
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
LIMIT 20;

-- ── Q7: Productos con mayor ingreso generado ─────────────────────────
SELECT '=== Q7: Productos con mayor ingreso ===';
SELECT i.i_item_id, i.i_product_name,
       ROUND(SUM(ss.ss_net_paid), 2) AS ingreso
FROM store_sales ss
JOIN item i ON ss.ss_item_sk = i.i_item_sk
GROUP BY i.i_item_id, i.i_product_name
ORDER BY ingreso DESC
LIMIT 20;

-- ── Q8: Top clientes por gasto total ─────────────────────────────────
SELECT '=== Q8: Top clientes por gasto total ===';
SELECT c.c_customer_id, c.c_first_name, c.c_last_name,
       ROUND(SUM(ss.ss_net_paid), 2) AS gasto_total
FROM store_sales ss
JOIN customer c ON ss.ss_customer_sk = c.c_customer_sk
GROUP BY c.c_customer_id, c.c_first_name, c.c_last_name
ORDER BY gasto_total DESC
LIMIT 20;

-- ── Q9: Ranking mensual de ventas ────────────────────────────────────
SELECT '=== Q9: Ranking mensual de ventas ===';
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
ORDER BY ranking;
