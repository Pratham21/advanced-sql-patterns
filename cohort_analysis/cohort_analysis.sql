-- ============================================================
-- COHORT ANALYSIS — Retention & behavioural cohort patterns
-- Author: Pratham Bharadwaj
-- Use case: Customer retention (Intuit), billing cycle cohorts, payroll adoption
-- Platform: BigQuery
-- ============================================================


-- ─────────────────────────────────────────
-- 1. MONTHLY RETENTION COHORT MATRIX
-- Business use: What % of Jan customers are still active in Feb, Mar, Apr?
-- Classic retention heatmap input
-- ─────────────────────────────────────────
WITH cohort_base AS (
    SELECT
        customer_id,
        DATE_TRUNC(first_purchase_date, MONTH) AS cohort_month
    FROM (
        SELECT
            customer_id,
            MIN(purchase_date) AS first_purchase_date
        FROM purchases
        GROUP BY customer_id
    )
),
cohort_activity AS (
    SELECT
        cb.customer_id,
        cb.cohort_month,
        DATE_DIFF(DATE_TRUNC(p.purchase_date, MONTH), cb.cohort_month, MONTH) AS months_since_first
    FROM cohort_base cb
    JOIN purchases p ON cb.customer_id = p.customer_id
)
SELECT
    cohort_month,
    months_since_first                                               AS period,
    COUNT(DISTINCT customer_id)                                      AS active_customers,
    ROUND(
        COUNT(DISTINCT customer_id) * 100.0
        / FIRST_VALUE(COUNT(DISTINCT customer_id))
            OVER (PARTITION BY cohort_month ORDER BY months_since_first),
    1)                                                               AS retention_pct
FROM cohort_activity
GROUP BY cohort_month, months_since_first
ORDER BY cohort_month, months_since_first;


-- ─────────────────────────────────────────
-- 2. PRE/POST MIGRATION COHORT COMPARISON
-- Business use: Did the pricing migration hurt retention?
-- Used at Intuit post billing model transition
-- ─────────────────────────────────────────
WITH pre_cohort AS (
    SELECT customer_id, 'pre_migration' AS cohort_type
    FROM customers
    WHERE signup_date < '2024-01-01'
),
post_cohort AS (
    SELECT customer_id, 'post_migration' AS cohort_type
    FROM customers
    WHERE signup_date >= '2024-01-01'
),
all_cohorts AS (
    SELECT * FROM pre_cohort
    UNION ALL
    SELECT * FROM post_cohort
)
SELECT
    ac.cohort_type,
    COUNT(DISTINCT ac.customer_id)                                           AS total_customers,
    COUNT(DISTINCT CASE WHEN s.is_active THEN ac.customer_id END)           AS active_customers,
    ROUND(
        COUNT(DISTINCT CASE WHEN s.is_active THEN ac.customer_id END) * 100.0
        / COUNT(DISTINCT ac.customer_id),
    1)                                                                       AS retention_pct
FROM all_cohorts ac
LEFT JOIN customer_status s ON ac.customer_id = s.customer_id
GROUP BY ac.cohort_type;


-- ─────────────────────────────────────────
-- 3. FEATURE ADOPTION COHORT
-- Business use: Are customers who adopted feature X in month 1 more retained?
-- Used at Intuit for payroll adoption tracking
-- ─────────────────────────────────────────
WITH adoption AS (
    SELECT
        customer_id,
        MIN(feature_used_date) AS first_adoption_date
    FROM feature_usage
    WHERE feature_name = 'payroll'
    GROUP BY customer_id
),
adoption_cohorts AS (
    SELECT
        c.customer_id,
        CASE
            WHEN a.first_adoption_date IS NULL                          THEN 'never_adopted'
            WHEN DATE_DIFF(a.first_adoption_date, c.signup_date, DAY) <= 30 THEN 'early_adopter'
            ELSE 'late_adopter'
        END AS adoption_segment
    FROM customers c
    LEFT JOIN adoption a ON c.customer_id = a.customer_id
)
SELECT
    adoption_segment,
    COUNT(DISTINCT ac.customer_id)                                            AS customers,
    ROUND(AVG(s.lifetime_value), 2)                                           AS avg_ltv,
    ROUND(AVG(s.tenure_days), 0)                                              AS avg_tenure_days,
    ROUND(
        COUNT(DISTINCT CASE WHEN s.is_churned THEN ac.customer_id END) * 100.0
        / COUNT(DISTINCT ac.customer_id),
    1)                                                                        AS churn_pct
FROM adoption_cohorts ac
JOIN customer_stats s ON ac.customer_id = s.customer_id
GROUP BY adoption_segment
ORDER BY churn_pct ASC;


-- ─────────────────────────────────────────
-- 4. BILLING CYCLE COHORT
-- Business use: Do monthly vs annual subscribers behave differently?
-- ─────────────────────────────────────────
SELECT
    billing_cycle,
    DATE_TRUNC(signup_date, MONTH)           AS cohort_month,
    COUNT(DISTINCT customer_id)              AS cohort_size,
    ROUND(AVG(months_active), 1)             AS avg_months_active,
    ROUND(
        SUM(CASE WHEN is_churned THEN 1 ELSE 0 END) * 100.0
        / COUNT(*),
    1)                                       AS churn_rate_pct
FROM customer_billing_summary
GROUP BY billing_cycle, cohort_month
ORDER BY cohort_month, billing_cycle;
