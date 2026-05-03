# ============================================================
# analytics.py — Standalone analytics scripts for reporting
# Author: Pratham Bharadwaj
# Use case: Ad hoc analysis, executive reporting, Tableau data prep
#           Mirrors work at Intuit (cohort models) and eBay (exec deep-dives)
# ============================================================

import pandas as pd
import numpy as np
import logging
from utils.bigquery_client import BigQueryClient
from utils.transformers import monthly_cohort_retention, compute_rfm, flag_churn_risk

logger = logging.getLogger(__name__)


# ─────────────────────────────────────────
# 1. EXECUTIVE SUMMARY REPORT
# Business use: Weekly KPI snapshot for senior leadership
# Mirrors the 200+ monthly exec reports built at Verizon & eBay
# ─────────────────────────────────────────

def build_executive_summary(client: BigQueryClient) -> pd.DataFrame:
    """Pull and format weekly KPI summary for exec dashboard."""
    sql = """
        WITH weekly AS (
            SELECT
                DATE_TRUNC(event_date, WEEK) AS week_start,
                COUNT(DISTINCT customer_id)  AS active_customers,
                SUM(revenue)                 AS total_revenue,
                COUNT(DISTINCT order_id)     AS total_orders,
                AVG(revenue)                 AS avg_order_value
            FROM `analytics.orders`
            WHERE event_date >= DATE_SUB(CURRENT_DATE(), INTERVAL 12 WEEK)
            GROUP BY DATE_TRUNC(event_date, WEEK)
        )
        SELECT
            *,
            ROUND(total_revenue - LAG(total_revenue) OVER (ORDER BY week_start), 2)
                AS revenue_wow_change,
            ROUND(
                (total_revenue - LAG(total_revenue) OVER (ORDER BY week_start))
                / NULLIF(LAG(total_revenue) OVER (ORDER BY week_start), 0) * 100,
            1) AS revenue_wow_pct
        FROM weekly
        ORDER BY week_start DESC
    """
    df = client.run_query(sql)
    df["week_start"] = pd.to_datetime(df["week_start"])
    df["total_revenue"] = df["total_revenue"].round(2)
    df["avg_order_value"] = df["avg_order_value"].round(2)
    logger.info(f"Executive summary built: {len(df)} weeks")
    return df


# ─────────────────────────────────────────
# 2. CHURN RISK REPORT — For customer success team
# Business use: Weekly list of at-risk accounts to action
# ─────────────────────────────────────────

def build_churn_risk_report(client: BigQueryClient,
                             min_risk: str = "medium_risk") -> pd.DataFrame:
    """
    Pull customers at medium or high churn risk with account details.
    Output feeds into Salesforce for CSM follow-up.
    """
    sql = """
        SELECT
            c.customer_id,
            c.account_name,
            c.csm_owner,
            c.plan_type,
            c.mrr,
            c.signup_date,
            DATE_DIFF(CURRENT_DATE(), l.last_login_date, DAY) AS days_since_login,
            s.open_support_tickets,
            b.failed_payments_last_90d
        FROM `analytics.customers` c
        LEFT JOIN `analytics.login_summary` l   ON c.customer_id = l.customer_id
        LEFT JOIN `analytics.support_summary` s ON c.customer_id = s.customer_id
        LEFT JOIN `analytics.billing_summary` b ON c.customer_id = b.customer_id
        WHERE c.is_active = TRUE
    """
    df = client.run_query(sql)
    df = flag_churn_risk(df, "days_since_login")

    risk_order = {"high_risk": 0, "medium_risk": 1, "low_risk": 2, "active": 3}
    df["risk_rank"] = df["churn_risk_tier"].map(risk_order)

    if min_risk == "medium_risk":
        df = df[df["risk_rank"] <= 1]
    elif min_risk == "high_risk":
        df = df[df["risk_rank"] == 0]

    df = df.sort_values(["risk_rank", "mrr"], ascending=[True, False])
    df = df.drop(columns=["risk_rank"])

    logger.info(f"Churn risk report: {len(df):,} customers flagged ({min_risk}+)")
    return df


# ─────────────────────────────────────────
# 3. SEGMENT PERFORMANCE ANALYSIS
# Business use: Compare revenue and retention across customer segments
# Mirrors Intuit billing model analysis and eBay category deep-dives
# ─────────────────────────────────────────

def segment_performance(client: BigQueryClient) -> pd.DataFrame:
    """Aggregate KPIs by customer segment for strategic planning."""
    sql = """
        SELECT
            segment,
            plan_type,
            COUNT(DISTINCT customer_id)                    AS total_customers,
            ROUND(SUM(mrr), 2)                             AS total_mrr,
            ROUND(AVG(mrr), 2)                             AS avg_mrr,
            ROUND(AVG(tenure_days), 0)                     AS avg_tenure_days,
            ROUND(
                SUM(CASE WHEN is_churned THEN 1 ELSE 0 END) * 100.0
                / COUNT(*), 2
            )                                              AS churn_rate_pct,
            ROUND(AVG(lifetime_value), 2)                  AS avg_ltv
        FROM `analytics.customer_summary`
        GROUP BY segment, plan_type
        ORDER BY total_mrr DESC
    """
    df = client.run_query(sql)
    logger.info(f"Segment performance: {len(df)} segment-plan combinations")
    return df


# ─────────────────────────────────────────
# 4. EXPORT TO CSV — For Tableau / dashboard consumption
# Business use: Prep data files for Tableau Public or Tableau Server
# ─────────────────────────────────────────

def export_for_tableau(dfs: dict, output_dir: str = "data/output") -> None:
    """
    Export multiple DataFrames to CSV for Tableau ingestion.

    Args:
        dfs: dict of {filename: dataframe}
        output_dir: local directory to write CSVs
    """
    import os
    os.makedirs(output_dir, exist_ok=True)
    for name, df in dfs.items():
        path = os.path.join(output_dir, f"{name}.csv")
        df.to_csv(path, index=False)
        logger.info(f"Exported {len(df):,} rows → {path}")


# ── ENTRY POINT ───────────────────────────────────────────────

if __name__ == "__main__":
    import argparse
    parser = argparse.ArgumentParser(description="Run analytics reports")
    parser.add_argument("--project", required=True, help="GCP project ID")
    parser.add_argument("--report",  default="all",
                        choices=["exec_summary", "churn_risk", "segment", "all"])
    args = parser.parse_args()

    client = BigQueryClient(project_id=args.project)

    reports = {}
    if args.report in ("exec_summary", "all"):
        reports["executive_summary"] = build_executive_summary(client)
    if args.report in ("churn_risk", "all"):
        reports["churn_risk_report"] = build_churn_risk_report(client)
    if args.report in ("segment", "all"):
        reports["segment_performance"] = segment_performance(client)

    export_for_tableau(reports)
    logger.info("All reports exported.")
