# ============================================================
# transformers.py — Reusable Pandas transformation functions
# Author: Pratham Bharadwaj
# Use case: Data cleaning and transformation in ETL pipelines
#           Used at Tesla (KPI pipelines) and Intuit (billing data)
# ============================================================

import pandas as pd
import numpy as np
import logging

logger = logging.getLogger(__name__)


def clean_dataframe(df: pd.DataFrame) -> pd.DataFrame:
    """
    Standard cleaning steps applied at the start of every pipeline.
    - Strip whitespace from string columns
    - Lowercase column names
    - Drop exact duplicate rows
    - Reset index
    """
    df.columns = df.columns.str.strip().str.lower().str.replace(" ", "_")
    str_cols = df.select_dtypes(include="object").columns
    df[str_cols] = df[str_cols].apply(lambda col: col.str.strip())
    before = len(df)
    df = df.drop_duplicates().reset_index(drop=True)
    logger.info(f"Removed {before - len(df):,} duplicate rows")
    return df


def add_date_parts(df: pd.DataFrame, date_col: str) -> pd.DataFrame:
    """
    Explode a date column into year, month, week, day, quarter.
    Useful for time-series aggregations and dashboard filters.
    """
    df[date_col] = pd.to_datetime(df[date_col])
    df[f"{date_col}_year"]    = df[date_col].dt.year
    df[f"{date_col}_month"]   = df[date_col].dt.month
    df[f"{date_col}_quarter"] = df[date_col].dt.quarter
    df[f"{date_col}_week"]    = df[date_col].dt.isocalendar().week.astype(int)
    df[f"{date_col}_day"]     = df[date_col].dt.day
    df[f"{date_col}_weekday"] = df[date_col].dt.day_name()
    return df


def flag_churn_risk(df: pd.DataFrame, days_col: str,
                    thresholds: dict = None) -> pd.DataFrame:
    """
    Add a churn_risk_tier column based on days since last activity.
    Default thresholds mirror Intuit's 90-day inactivity model.

    Args:
        df: DataFrame with a days-since-last-activity column
        days_col: Column name containing days since last activity (int)
        thresholds: Dict with keys 'high', 'medium', 'low' (days)
    """
    if thresholds is None:
        thresholds = {"high": 90, "medium": 60, "low": 30}

    conditions = [
        df[days_col] > thresholds["high"],
        df[days_col] > thresholds["medium"],
        df[days_col] > thresholds["low"],
    ]
    choices = ["high_risk", "medium_risk", "low_risk"]
    df["churn_risk_tier"] = np.select(conditions, choices, default="active")
    tier_counts = df["churn_risk_tier"].value_counts().to_dict()
    logger.info(f"Churn risk distribution: {tier_counts}")
    return df


def compute_rfm(df: pd.DataFrame, customer_col: str, date_col: str,
                amount_col: str, snapshot_date: pd.Timestamp = None) -> pd.DataFrame:
    """
    Compute RFM (Recency, Frequency, Monetary) scores per customer.
    Returns a DataFrame with rfm_segment column.

    Used at Intuit for customer health scoring across 100K+ accounts.
    """
    if snapshot_date is None:
        snapshot_date = pd.Timestamp.today()

    df[date_col] = pd.to_datetime(df[date_col])

    rfm = df.groupby(customer_col).agg(
        recency_days  = (date_col, lambda x: (snapshot_date - x.max()).days),
        frequency     = (date_col, "count"),
        monetary      = (amount_col, "sum")
    ).reset_index()

    rfm["r_score"] = pd.qcut(rfm["recency_days"], q=5, labels=[5, 4, 3, 2, 1]).astype(int)
    rfm["f_score"] = pd.qcut(rfm["frequency"].rank(method="first"), q=5, labels=[1, 2, 3, 4, 5]).astype(int)
    rfm["m_score"] = pd.qcut(rfm["monetary"].rank(method="first"), q=5, labels=[1, 2, 3, 4, 5]).astype(int)
    rfm["rfm_total"] = rfm["r_score"] + rfm["f_score"] + rfm["m_score"]

    rfm["rfm_segment"] = pd.cut(
        rfm["rfm_total"],
        bins=[0, 6, 9, 12, 15],
        labels=["Lost", "At Risk", "Loyal", "Champion"]
    )
    logger.info(f"RFM segmentation complete for {len(rfm):,} customers")
    return rfm


def compute_funnel_conversion(df: pd.DataFrame, stage_col: str,
                              customer_col: str, stage_order: list) -> pd.DataFrame:
    """
    Compute step-by-step funnel conversion and drop-off rates.

    Args:
        df: DataFrame with one row per customer per stage
        stage_col: Column with stage names
        customer_col: Column with customer/lead IDs
        stage_order: Ordered list of stage names top-to-bottom
    """
    records = []
    for i, stage in enumerate(stage_order):
        count = df[df[stage_col] == stage][customer_col].nunique()
        records.append({"stage": stage, "stage_order": i + 1, "users": count})

    funnel = pd.DataFrame(records)
    funnel["prev_users"] = funnel["users"].shift(1)
    funnel["conversion_pct"] = (
        funnel["users"] / funnel["prev_users"] * 100
    ).round(1)
    funnel["drop_off_pct"] = (100 - funnel["conversion_pct"]).round(1)
    funnel["pct_of_total"] = (
        funnel["users"] / funnel["users"].iloc[0] * 100
    ).round(1)
    return funnel.fillna({"conversion_pct": 100.0, "drop_off_pct": 0.0})


def monthly_cohort_retention(df: pd.DataFrame, customer_col: str,
                              date_col: str) -> pd.DataFrame:
    """
    Build a monthly cohort retention matrix.
    Returns a pivot table: cohort_month × period_number → retention %.
    """
    df[date_col] = pd.to_datetime(df[date_col])
    df["cohort_month"] = df.groupby(customer_col)[date_col].transform("min").dt.to_period("M")
    df["period_month"] = df[date_col].dt.to_period("M")
    df["period_number"] = (df["period_month"] - df["cohort_month"]).apply(lambda x: x.n)

    cohort_sizes = df.groupby("cohort_month")[customer_col].nunique()
    retention = df.groupby(["cohort_month", "period_number"])[customer_col].nunique().reset_index()
    retention.columns = ["cohort_month", "period_number", "customers"]
    retention["cohort_size"] = retention["cohort_month"].map(cohort_sizes)
    retention["retention_pct"] = (retention["customers"] / retention["cohort_size"] * 100).round(1)

    matrix = retention.pivot(index="cohort_month", columns="period_number", values="retention_pct")
    logger.info(f"Cohort matrix built: {matrix.shape[0]} cohorts × {matrix.shape[1]} periods")
    return matrix
