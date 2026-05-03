-- ============================================================
-- CHURN ANALYSIS — Risk scoring & early warning patterns
-- Author: Pratham Bharadwaj
-- Use case: Reducing attrition at Intuit (100K+ customers, ~2% target churn)
-- Platform: BigQuery
-- ============================================================


-- ─────────────────────────────────────────
-- 1. 90-DAY INACTIVITY CHURN FLAG
-- Business use: Flag customers who haven't logged in for 90 days
-- ─────────────────────────────────────────
SELECT
    customer_id,
    last_login_date,
    DATE_DIFF(CURRENT_DATE(), last_login_date, DAY) AS days_inactive,
    CASE
        WHEN DATE_DIFF(CURRENT_DATE(), last_login_date, DAY) > 90  THEN 'high_risk'
        WHEN DATE_DIFF(CURRENT_DATE(), last_login_date, DAY) > 60  THEN 'medium_risk'
        WHEN DATE_DIFF(CURRENT_DATE(), last_login_date, DAY) > 30  THEN 'low_risk'
        ELSE 'active'
    END AS churn_risk_tier
FROM customer_logins
WHERE is_active = TRUE
ORDER BY days_inactive DESC;


-- ─────────────────────────────────────────
-- 2. RFM SCORING — Recency, Frequency, Monetary
-- Business use: Tier customers by engagement depth for proactive retention
-- ─────────────────────────────────────────
WITH rfm_raw AS (
    SELECT
        customer_id,
        DATE_DIFF(CURRENT_DATE(), MAX(transaction_date), DAY)   AS recency_days,
        COUNT(DISTINCT transaction_id)                           AS frequency,
        SUM(amount)                                              AS monetary
    FROM transactions
    WHERE transaction_date >= DATE_SUB(CURRENT_DATE(), INTERVAL 365 DAY)
    GROUP BY customer_id
),
rfm_scored AS (
    SELECT
        customer_id,
        recency_days,
        frequency,
        monetary,
        NTILE(5) OVER (ORDER BY recency_days ASC)   AS r_score,   -- lower recency = better
        NTILE(5) OVER (ORDER BY frequency DESC)      AS f_score,
        NTILE(5) OVER (ORDER BY monetary DESC)       AS m_score
    FROM rfm_raw
)
SELECT
    customer_id,
    recency_days,
    frequency,
    ROUND(monetary, 2)          AS monetary,
    r_score,
    f_score,
    m_score,
    (r_score + f_score + m_score) AS rfm_total,
    CASE
        WHEN (r_score + f_score + m_score) >= 13 THEN 'Champions'
        WHEN (r_score + f_score + m_score) >= 10 THEN 'Loyal'
        WHEN (r_score + f_score + m_score) >= 7  THEN 'At Risk'
        ELSE 'Churned / Lost'
    END AS customer_segment
FROM rfm_scored
ORDER BY rfm_total DESC;


-- ─────────────────────────────────────────
-- 3. CHURN PREDICTION FEATURES
-- Business use: Feed into ML model or rule-based churn scoring
-- Used at Intuit for billing discrepancy + consent cohort analysis
-- ─────────────────────────────────────────
SELECT
    c.customer_id,
    c.plan_type,
    c.signup_date,
    DATE_DIFF(CURRENT_DATE(), c.signup_date, DAY)           AS tenure_days,

    -- Recency signals
    DATE_DIFF(CURRENT_DATE(), l.last_login_date, DAY)       AS days_since_login,
    DATE_DIFF(CURRENT_DATE(), t.last_transaction_date, DAY) AS days_since_purchase,

    -- Engagement signals
    COALESCE(t.transactions_last_90d, 0)                    AS transactions_last_90d,
    COALESCE(s.support_tickets_last_90d, 0)                 AS support_tickets_last_90d,
    COALESCE(f.features_used_last_30d, 0)                   AS features_used_last_30d,

    -- Billing signals
    COALESCE(b.failed_payments_last_6m, 0)                  AS failed_payments_last_6m,
    COALESCE(b.billing_disputes, 0)                         AS billing_disputes,

    -- Label
    CASE WHEN c.churned_date IS NOT NULL THEN 1 ELSE 0 END  AS is_churned
FROM customers c
LEFT JOIN login_summary l        ON c.customer_id = l.customer_id
LEFT JOIN transaction_summary t  ON c.customer_id = t.customer_id
LEFT JOIN support_summary s      ON c.customer_id = s.customer_id
LEFT JOIN feature_summary f      ON c.customer_id = f.customer_id
LEFT JOIN billing_summary b      ON c.customer_id = b.customer_id;


-- ─────────────────────────────────────────
-- 4. MONTH-OVER-MONTH CHURN RATE
-- Business use: Executive dashboard metric — is churn improving?
-- ─────────────────────────────────────────
WITH monthly AS (
    SELECT
        DATE_TRUNC(period_date, MONTH)             AS month,
        COUNT(DISTINCT customer_id)                AS total_customers,
        COUNT(DISTINCT CASE WHEN churned THEN customer_id END) AS churned_customers
    FROM customer_monthly_status
    GROUP BY DATE_TRUNC(period_date, MONTH)
)
SELECT
    month,
    total_customers,
    churned_customers,
    ROUND(churned_customers * 100.0 / NULLIF(total_customers, 0), 2) AS churn_rate_pct,
    ROUND(
        churned_customers * 100.0 / NULLIF(total_customers, 0)
        - LAG(churned_customers * 100.0 / NULLIF(total_customers, 0))
            OVER (ORDER BY month),
    2) AS churn_rate_change_ppt
FROM monthly
ORDER BY month;
