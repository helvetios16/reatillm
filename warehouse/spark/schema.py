#!/usr/bin/env python3
# ============================================================
# schema.py  |  retaillm — Fase 2 (lado Spark del Data Warehouse)
#
# IMPORTANTE: en EMR, Spark lee las 5 tablas del HIVE METASTORE compartido
# (creado por warehouse/hive/ddl/setup.hql), así que en el clúster NO se usa este
# archivo: las consultas hacen spark.sql("... FROM store_sales") directamente.
#
# Este módulo existe SOLO para verify_local (offline, sin metastore): registra las
# 5 tablas como vistas temporales leyendo una muestra .dat local, con los MISMOS
# nombres que el metastore, para validar el SQL antes de gastar clúster.
#
# Gotcha del pipe final: dsdgen cierra cada fila con un '|' extra → el lector CSV
# de Spark vería N+1 columnas. Cada esquema declara una columna dummy final
# `_extra` que absorbe ese campo; load_dw la descarta tras leer.
# ============================================================
from pyspark.sql.types import (
    StructType, StructField,
    LongType, IntegerType, StringType, DecimalType,
)


def _money(p=7, s=2):
    return DecimalType(p, s)


# ── customer (18 + dummy) ────────────────────────────────────────────
CUSTOMER = StructType([
    StructField("c_customer_sk", LongType()),
    StructField("c_customer_id", StringType()),
    StructField("c_current_cdemo_sk", LongType()),
    StructField("c_current_hdemo_sk", LongType()),
    StructField("c_current_addr_sk", LongType()),
    StructField("c_first_shipto_date_sk", LongType()),
    StructField("c_first_sales_date_sk", LongType()),
    StructField("c_salutation", StringType()),
    StructField("c_first_name", StringType()),
    StructField("c_last_name", StringType()),
    StructField("c_preferred_cust_flag", StringType()),
    StructField("c_birth_day", IntegerType()),
    StructField("c_birth_month", IntegerType()),
    StructField("c_birth_year", IntegerType()),
    StructField("c_birth_country", StringType()),
    StructField("c_login", StringType()),
    StructField("c_email_address", StringType()),
    StructField("c_last_review_date", StringType()),
    StructField("_extra", StringType()),
])

# ── item (22 + dummy) ────────────────────────────────────────────────
ITEM = StructType([
    StructField("i_item_sk", LongType()),
    StructField("i_item_id", StringType()),
    StructField("i_rec_start_date", StringType()),
    StructField("i_rec_end_date", StringType()),
    StructField("i_item_desc", StringType()),
    StructField("i_current_price", _money()),
    StructField("i_wholesale_cost", _money()),
    StructField("i_brand_id", IntegerType()),
    StructField("i_brand", StringType()),
    StructField("i_class_id", IntegerType()),
    StructField("i_class", StringType()),
    StructField("i_category_id", IntegerType()),
    StructField("i_category", StringType()),
    StructField("i_manufact_id", IntegerType()),
    StructField("i_manufact", StringType()),
    StructField("i_size", StringType()),
    StructField("i_formulation", StringType()),
    StructField("i_color", StringType()),
    StructField("i_units", StringType()),
    StructField("i_container", StringType()),
    StructField("i_manager_id", IntegerType()),
    StructField("i_product_name", StringType()),
    StructField("_extra", StringType()),
])

# ── store (29 + dummy) ───────────────────────────────────────────────
STORE = StructType([
    StructField("s_store_sk", LongType()),
    StructField("s_store_id", StringType()),
    StructField("s_rec_start_date", StringType()),
    StructField("s_rec_end_date", StringType()),
    StructField("s_closed_date_sk", LongType()),
    StructField("s_store_name", StringType()),
    StructField("s_number_employees", IntegerType()),
    StructField("s_floor_space", IntegerType()),
    StructField("s_hours", StringType()),
    StructField("s_manager", StringType()),
    StructField("s_market_id", IntegerType()),
    StructField("s_geography_class", StringType()),
    StructField("s_market_desc", StringType()),
    StructField("s_market_manager", StringType()),
    StructField("s_division_id", IntegerType()),
    StructField("s_division_name", StringType()),
    StructField("s_company_id", IntegerType()),
    StructField("s_company_name", StringType()),
    StructField("s_street_number", StringType()),
    StructField("s_street_name", StringType()),
    StructField("s_street_type", StringType()),
    StructField("s_suite_number", StringType()),
    StructField("s_city", StringType()),
    StructField("s_county", StringType()),
    StructField("s_state", StringType()),
    StructField("s_zip", StringType()),
    StructField("s_country", StringType()),
    StructField("s_gmt_offset", _money(5, 2)),
    StructField("s_tax_precentage", _money(5, 2)),
    StructField("_extra", StringType()),
])

# ── date_dim (28 + dummy) ────────────────────────────────────────────
DATE_DIM = StructType([
    StructField("d_date_sk", LongType()),
    StructField("d_date_id", StringType()),
    StructField("d_date", StringType()),
    StructField("d_month_seq", IntegerType()),
    StructField("d_week_seq", IntegerType()),
    StructField("d_quarter_seq", IntegerType()),
    StructField("d_year", IntegerType()),
    StructField("d_dow", IntegerType()),
    StructField("d_moy", IntegerType()),
    StructField("d_dom", IntegerType()),
    StructField("d_qoy", IntegerType()),
    StructField("d_fy_year", IntegerType()),
    StructField("d_fy_quarter_seq", IntegerType()),
    StructField("d_fy_week_seq", IntegerType()),
    StructField("d_day_name", StringType()),
    StructField("d_quarter_name", StringType()),
    StructField("d_holiday", StringType()),
    StructField("d_weekend", StringType()),
    StructField("d_following_holiday", StringType()),
    StructField("d_first_dom", IntegerType()),
    StructField("d_last_dom", IntegerType()),
    StructField("d_same_day_ly", IntegerType()),
    StructField("d_same_day_lq", IntegerType()),
    StructField("d_current_day", StringType()),
    StructField("d_current_week", StringType()),
    StructField("d_current_month", StringType()),
    StructField("d_current_quarter", StringType()),
    StructField("d_current_year", StringType()),
    StructField("_extra", StringType()),
])

# ── store_sales (23 + dummy, FACT) ───────────────────────────────────
STORE_SALES = StructType([
    StructField("ss_sold_date_sk", LongType()),
    StructField("ss_sold_time_sk", LongType()),
    StructField("ss_item_sk", LongType()),
    StructField("ss_customer_sk", LongType()),
    StructField("ss_cdemo_sk", LongType()),
    StructField("ss_hdemo_sk", LongType()),
    StructField("ss_addr_sk", LongType()),
    StructField("ss_store_sk", LongType()),
    StructField("ss_promo_sk", LongType()),
    StructField("ss_ticket_number", LongType()),
    StructField("ss_quantity", IntegerType()),
    StructField("ss_wholesale_cost", _money()),
    StructField("ss_list_price", _money()),
    StructField("ss_sales_price", _money()),
    StructField("ss_ext_discount_amt", _money()),
    StructField("ss_ext_sales_price", _money()),
    StructField("ss_ext_wholesale_cost", _money()),
    StructField("ss_ext_list_price", _money()),
    StructField("ss_ext_tax", _money()),
    StructField("ss_coupon_amt", _money()),
    StructField("ss_net_paid", _money()),
    StructField("ss_net_paid_inc_tax", _money()),
    StructField("ss_net_profit", _money()),
    StructField("_extra", StringType()),
])

TABLES = {
    "customer": CUSTOMER,
    "item": ITEM,
    "store": STORE,
    "date_dim": DATE_DIM,
    "store_sales": STORE_SALES,
}


def load_dw(spark, base_path):
    """Registra las 5 tablas como vistas temporales leyendo .dat locales.

    Solo para verify_local (offline). `base_path` contiene una carpeta por tabla:
        <base_path>/customer/   <base_path>/store_sales/   ...
    En el clúster NO se usa: las tablas vienen del Hive Metastore.
    """
    for name, schema in TABLES.items():
        df = (spark.read
              .option("sep", "|")
              .schema(schema)
              .csv(f"{base_path}/{name}"))
        df = df.drop("_extra")
        df.createOrReplaceTempView(name)
    return list(TABLES.keys())
