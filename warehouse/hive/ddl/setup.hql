-- ============================================================
-- setup.hql  |  retaillm — Fase 2 (Data Warehouse TPC-DS)
--
-- Crea las 5 tablas OBLIGATORIAS como EXTERNAL sobre los .dat de TPC-DS en S3
-- (texto delimitado por '|', sin cabecera). Esquema estrella:
--   store_sales (FACT)  ⋈  customer · item · store · date_dim (dimensiones)
--
-- En EMR, Spark usa este MISMO Hive Metastore por defecto, así que tras correr
-- este script las tablas quedan visibles para `hive -f`, `spark.sql()` y
-- `spark-sql -e` por nombre (no hay que re-declararlas en Spark).
--
-- LOCATION por -hivevar (los pasa run_emr.sh):
--   CUSTOMER ITEM STORE DATE_DIM STORE_SALES = s3://<bucket>/raw/<tabla>/
--
-- Notas:
--  • TEXTFILE + FIELDS TERMINATED BY '|'. dsdgen cierra cada fila con un '|'
--    extra; al declarar exactamente las N columnas, Hive ignora el campo sobrante.
--  • Importes = DECIMAL(7,2) (spec TPC-DS); claves *_sk/*_number = BIGINT;
--    ingreso del negocio = ss_net_paid.
--  • Columnas y orden EXACTOS del spec (no cambiar el orden: rompe el parseo '|').
-- ============================================================

-- ── customer (18 columnas) ───────────────────────────────────────────
DROP TABLE IF EXISTS customer;
CREATE EXTERNAL TABLE customer (
    c_customer_sk           BIGINT,
    c_customer_id           STRING,
    c_current_cdemo_sk      BIGINT,
    c_current_hdemo_sk      BIGINT,
    c_current_addr_sk       BIGINT,
    c_first_shipto_date_sk  BIGINT,
    c_first_sales_date_sk   BIGINT,
    c_salutation            STRING,
    c_first_name            STRING,
    c_last_name             STRING,
    c_preferred_cust_flag   STRING,
    c_birth_day             INT,
    c_birth_month           INT,
    c_birth_year            INT,
    c_birth_country         STRING,
    c_login                 STRING,
    c_email_address         STRING,
    c_last_review_date      STRING
)
ROW FORMAT DELIMITED FIELDS TERMINATED BY '|'
STORED AS TEXTFILE
LOCATION '${hivevar:CUSTOMER}';

-- ── item (22 columnas) ───────────────────────────────────────────────
DROP TABLE IF EXISTS item;
CREATE EXTERNAL TABLE item (
    i_item_sk         BIGINT,
    i_item_id         STRING,
    i_rec_start_date  STRING,
    i_rec_end_date    STRING,
    i_item_desc       STRING,
    i_current_price   DECIMAL(7,2),
    i_wholesale_cost  DECIMAL(7,2),
    i_brand_id        INT,
    i_brand           STRING,
    i_class_id        INT,
    i_class           STRING,
    i_category_id     INT,
    i_category        STRING,
    i_manufact_id     INT,
    i_manufact        STRING,
    i_size            STRING,
    i_formulation     STRING,
    i_color           STRING,
    i_units           STRING,
    i_container       STRING,
    i_manager_id      INT,
    i_product_name    STRING
)
ROW FORMAT DELIMITED FIELDS TERMINATED BY '|'
STORED AS TEXTFILE
LOCATION '${hivevar:ITEM}';

-- ── store (29 columnas) ──────────────────────────────────────────────
DROP TABLE IF EXISTS store;
CREATE EXTERNAL TABLE store (
    s_store_sk          BIGINT,
    s_store_id          STRING,
    s_rec_start_date    STRING,
    s_rec_end_date      STRING,
    s_closed_date_sk    BIGINT,
    s_store_name        STRING,
    s_number_employees  INT,
    s_floor_space       INT,
    s_hours             STRING,
    s_manager           STRING,
    s_market_id         INT,
    s_geography_class   STRING,
    s_market_desc       STRING,
    s_market_manager    STRING,
    s_division_id       INT,
    s_division_name     STRING,
    s_company_id        INT,
    s_company_name      STRING,
    s_street_number     STRING,
    s_street_name       STRING,
    s_street_type       STRING,
    s_suite_number      STRING,
    s_city              STRING,
    s_county            STRING,
    s_state             STRING,
    s_zip               STRING,
    s_country           STRING,
    s_gmt_offset        DECIMAL(5,2),
    s_tax_precentage    DECIMAL(5,2)
)
ROW FORMAT DELIMITED FIELDS TERMINATED BY '|'
STORED AS TEXTFILE
LOCATION '${hivevar:STORE}';

-- ── date_dim (28 columnas) ───────────────────────────────────────────
DROP TABLE IF EXISTS date_dim;
CREATE EXTERNAL TABLE date_dim (
    d_date_sk            BIGINT,
    d_date_id            STRING,
    d_date               STRING,
    d_month_seq          INT,
    d_week_seq           INT,
    d_quarter_seq        INT,
    d_year               INT,
    d_dow                INT,
    d_moy                INT,
    d_dom                INT,
    d_qoy                INT,
    d_fy_year            INT,
    d_fy_quarter_seq     INT,
    d_fy_week_seq        INT,
    d_day_name           STRING,
    d_quarter_name       STRING,
    d_holiday            STRING,
    d_weekend            STRING,
    d_following_holiday  STRING,
    d_first_dom          INT,
    d_last_dom           INT,
    d_same_day_ly        INT,
    d_same_day_lq        INT,
    d_current_day        STRING,
    d_current_week       STRING,
    d_current_month      STRING,
    d_current_quarter    STRING,
    d_current_year       STRING
)
ROW FORMAT DELIMITED FIELDS TERMINATED BY '|'
STORED AS TEXTFILE
LOCATION '${hivevar:DATE_DIM}';

-- ── store_sales (23 columnas, FACT) ──────────────────────────────────
DROP TABLE IF EXISTS store_sales;
CREATE EXTERNAL TABLE store_sales (
    ss_sold_date_sk        BIGINT,
    ss_sold_time_sk        BIGINT,
    ss_item_sk             BIGINT,
    ss_customer_sk         BIGINT,
    ss_cdemo_sk            BIGINT,
    ss_hdemo_sk            BIGINT,
    ss_addr_sk             BIGINT,
    ss_store_sk            BIGINT,
    ss_promo_sk            BIGINT,
    ss_ticket_number       BIGINT,
    ss_quantity            INT,
    ss_wholesale_cost      DECIMAL(7,2),
    ss_list_price          DECIMAL(7,2),
    ss_sales_price         DECIMAL(7,2),
    ss_ext_discount_amt    DECIMAL(7,2),
    ss_ext_sales_price     DECIMAL(7,2),
    ss_ext_wholesale_cost  DECIMAL(7,2),
    ss_ext_list_price      DECIMAL(7,2),
    ss_ext_tax             DECIMAL(7,2),
    ss_coupon_amt          DECIMAL(7,2),
    ss_net_paid            DECIMAL(7,2),
    ss_net_paid_inc_tax    DECIMAL(7,2),
    ss_net_profit          DECIMAL(7,2)
)
ROW FORMAT DELIMITED FIELDS TERMINATED BY '|'
STORED AS TEXTFILE
LOCATION '${hivevar:STORE_SALES}';

-- ── Verificación rápida (opcional; descomenta al correr a mano) ───────
-- SHOW TABLES;
-- SELECT COUNT(*) FROM store_sales;
-- SELECT ss_net_paid FROM store_sales LIMIT 5;
