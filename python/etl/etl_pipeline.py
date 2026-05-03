# ============================================================
# etl_pipeline.py — End-to-end ETL: extract from BQ, transform, reload
# Author: Pratham Bharadwaj
# Use case: Sales funnel + churn risk pipeline (mirrors Intuit work)
# Run: python etl_pipeline.py --project my-gcp-project --env prod
# ============================================================

import argparse
import logging
import pandas as pd
from datetime import datetime, timedelta

from utils.bigquery_client import BigQueryClient
from utils.transformers import (
    clean_dataframe,
    add_date_parts,
    flag_churn_risk,
    compute_rfm,
    compute_funnel_conversion,
    monthly_cohort_retention,
)

logging.basicConfig(level=logging.INFO, format="%(asctime)s — %(levelname)s — %(message)s")
logger = logging.getLogger(__name__)

# ── CONFIG ───────────────────────────────────────────────────
FUNNEL_STAGES = [
    "Lead Created",
    "Demo Scheduled",
    "Proposal Sent",
    "Contract Signed",
    "Closed Won",
]

CHURN_THRESHOLDS = {"high": 90, "medium": 60, "low": 30}

# ── EXTRACT ──────────────────────────────────────────────────

def extract_transactions(client: BigQueryClient, lookback_days: int = 365) -> pd.DataFrame:
    """Pull transaction data for RFM scoring."""
    cutoff = (datetime.today() - timedelta(days=lookback_days)).strftime("%Y-%m-%d")
    sql = f"""
        SELECT
            customer_id,
            transaction_id,
            transaction_date,
            amount,
            product_line,
            region
        FROM `analytics.transactions`
        WHERE transaction_date >= '{cutoff}'
          AND status = 'completed'
    """
    return client.run_query(sql)


def extract_funnel_events(client: BigQueryClient) -> pd.DataFrame:
    """Pull current funnel stage per lead."""
    sql = """
        SELECT
            lead_id,
            customer_id,
            stage_name,
            stage_entered_at,
            sales_rep_id,
            segment
        FROM `analytics.funnel_stages`
        WHERE is_current_stage = TRUE
    """
    return client.run_query(sql)


def extract_customer_logins(client: BigQueryClient) -> pd.DataFrame:
    """Pull last login date per customer for churn risk scoring."""
    sql = """
        SELECT
            customer_id,
            MAX(login_date) AS last_login_date,
            COUNT(*) AS total_logins_90d
        FROM `analytics.customer_logins`
        WHERE login_date >= DATE_SUB(CURRENT_DATE(), INTERVAL 90 DAY)
        GROUP BY customer_id
    """
    return client.run_query(sql)


# ── TRANSFORM ─────────────────────────────────────────────────

def transform_transactions(df: pd.DataFrame) -> pd.DataFrame:
    logger.info("Transforming transactions...")
    df = clean_dataframe(df)
    df = add_date_parts(df, "transaction_date")
    df["amount"] = pd.to_numeric(df["amount"], errors="coerce").fillna(0)
    return df


def transform_churn_risk(logins_df: pd.DataFrame) -> pd.DataFrame:
    logger.info("Computing churn risk tiers...")
    logins_df = clean_dataframe(logins_df)
    logins_df["last_login_date"] = pd.to_datetime(logins_df["last_login_date"])
    logins_df["days_since_login"] = (
        pd.Timestamp.today() - logins_df["last_login_date"]
    ).dt.days
    logins_df = flag_churn_risk(logins_df, "days_since_login", CHURN_THRESHOLDS)
    return logins_df


def transform_rfm(transactions_df: pd.DataFrame) -> pd.DataFrame:
    logger.info("Computing RFM scores...")
    return compute_rfm(
        transactions_df,
        customer_col="customer_id",
        date_col="transaction_date",
        amount_col="amount"
    )


def transform_funnel(funnel_df: pd.DataFrame) -> pd.DataFrame:
    logger.info("Computing funnel conversion...")
    funnel_df = clean_dataframe(funnel_df)
    return compute_funnel_conversion(
        funnel_df,
        stage_col="stage_name",
        customer_col="customer_id",
        stage_order=FUNNEL_STAGES
    )


def transform_cohorts(transactions_df: pd.DataFrame) -> pd.DataFrame:
    logger.info("Building cohort retention matrix...")
    return monthly_cohort_retention(
        transactions_df,
        customer_col="customer_id",
        date_col="transaction_date"
    )


# ── LOAD ──────────────────────────────────────────────────────

def load_results(client: BigQueryClient, df: pd.DataFrame,
                 dataset: str, table: str, mode: str = "WRITE_TRUNCATE") -> None:
    if df.empty:
        logger.warning(f"Empty DataFrame — skipping load to {dataset}.{table}")
        return
    # Convert Period columns to string before loading to BQ
    for col in df.columns:
        if hasattr(df[col], "dt") and hasattr(df[col].dt, "to_timestamp"):
            df[col] = df[col].astype(str)
    client.load_dataframe(df, dataset, table, write_mode=mode)


# ── ORCHESTRATE ───────────────────────────────────────────────

def run_pipeline(project_id: str, output_dataset: str = "analytics_output") -> None:
    logger.info("=" * 60)
    logger.info("Starting ETL pipeline")
    logger.info("=" * 60)

    client = BigQueryClient(project_id=project_id)

    # Extract
    transactions_raw = extract_transactions(client)
    logins_raw       = extract_customer_logins(client)
    funnel_raw       = extract_funnel_events(client)

    # Transform
    transactions  = transform_transactions(transactions_raw)
    churn_risk    = transform_churn_risk(logins_raw)
    rfm_scores    = transform_rfm(transactions)
    funnel_stats  = transform_funnel(funnel_raw)
    cohort_matrix = transform_cohorts(transactions)

    # Load
    load_results(client, churn_risk,    output_dataset, "churn_risk_scores")
    load_results(client, rfm_scores,    output_dataset, "rfm_scores")
    load_results(client, funnel_stats,  output_dataset, "funnel_conversion")
    load_results(client, cohort_matrix.reset_index(), output_dataset, "cohort_retention")

    logger.info("Pipeline complete.")


# ── ENTRY POINT ───────────────────────────────────────────────

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Sales analytics ETL pipeline")
    parser.add_argument("--project",  required=True, help="GCP project ID")
    parser.add_argument("--dataset",  default="analytics_output", help="Output BQ dataset")
    args = parser.parse_args()

    run_pipeline(project_id=args.project, output_dataset=args.dataset)
