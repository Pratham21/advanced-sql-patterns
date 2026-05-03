-- ============================================================
-- WINDOW FUNCTIONS — Production patterns for BigQuery / Hive
-- Author: Pratham Bharadwaj
-- Use case: Revenue analytics, sales performance, trend analysis
-- ============================================================


-- ─────────────────────────────────────────
-- 1. RUNNING TOTAL
-- Business use: cumulative revenue by month, YTD sales tracking
-- ─────────────────────────────────────────
SELECT
    customer_id,
    transaction_date,
    amount,
    SUM(amount) OVER (
        PARTITION BY customer_id
        ORDER BY transaction_date
        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    ) AS running_total
FROM transactions
ORDER BY customer_id, transaction_date;


-- ─────────────────────────────────────────
-- 2. RANK vs DENSE_RANK vs ROW_NUMBER
-- Business use: top N customers per region, sales rep leaderboard
-- ─────────────────────────────────────────
SELECT
    sales_rep_id,
    region,
    revenue,
    RANK()         OVER (PARTITION BY region ORDER BY revenue DESC) AS rank,           -- gaps on ties
    DENSE_RANK()   OVER (PARTITION BY region ORDER BY revenue DESC) AS dense_rank,     -- no gaps on ties
    ROW_NUMBER()   OVER (PARTITION BY region ORDER BY revenue DESC) AS row_num         -- always unique
FROM sales_performance;


-- ─────────────────────────────────────────
-- 3. LAG & LEAD — Period over period comparison
-- Business use: MoM revenue change, detecting drops in engagement
-- ─────────────────────────────────────────
SELECT
    month,
    revenue,
    LAG(revenue, 1)  OVER (ORDER BY month) AS prev_month_revenue,
    LEAD(revenue, 1) OVER (ORDER BY month) AS next_month_revenue,
    ROUND(
        (revenue - LAG(revenue, 1) OVER (ORDER BY month))
        / NULLIF(LAG(revenue, 1) OVER (ORDER BY month), 0) * 100,
    2) AS mom_growth_pct
FROM monthly_revenue;


-- ─────────────────────────────────────────
-- 4. MOVING AVERAGE — Smoothing noisy metrics
-- Business use: 7-day rolling DAU, 30-day rolling GMV
-- ─────────────────────────────────────────
SELECT
    event_date,
    daily_active_users,
    ROUND(AVG(daily_active_users) OVER (
        ORDER BY event_date
        ROWS BETWEEN 6 PRECEDING AND CURRENT ROW
    ), 0) AS rolling_7day_avg
FROM daily_metrics
ORDER BY event_date;


-- ─────────────────────────────────────────
-- 5. FIRST & LAST VALUE per partition
-- Business use: first purchase date, most recent login per customer
-- ─────────────────────────────────────────
SELECT
    customer_id,
    event_date,
    event_type,
    FIRST_VALUE(event_date) OVER (
        PARTITION BY customer_id
        ORDER BY event_date
        ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING
    ) AS first_event_date,
    LAST_VALUE(event_date) OVER (
        PARTITION BY customer_id
        ORDER BY event_date
        ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING
    ) AS last_event_date
FROM customer_events;


-- ─────────────────────────────────────────
-- 6. PERCENTILE / NTILE — Bucketing customers into tiers
-- Business use: customer value tiers (top 10%, bottom 25%)
-- ─────────────────────────────────────────
SELECT
    customer_id,
    total_spend,
    NTILE(4) OVER (ORDER BY total_spend DESC) AS spend_quartile,
    -- 1 = top 25%, 4 = bottom 25%
    PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY total_spend)
        OVER (PARTITION BY segment) AS median_spend_by_segment
FROM customer_summary;


-- ─────────────────────────────────────────
-- 7. GAPS & ISLANDS — Finding consecutive activity streaks
-- Business use: consecutive login days, active subscription streaks
-- ─────────────────────────────────────────
WITH numbered AS (
    SELECT
        customer_id,
        activity_date,
        ROW_NUMBER() OVER (PARTITION BY customer_id ORDER BY activity_date) AS rn
    FROM customer_activity
),
islands AS (
    SELECT
        customer_id,
        activity_date,
        DATE_SUB(activity_date, INTERVAL rn DAY) AS grp   -- same group = consecutive days
    FROM numbered
)
SELECT
    customer_id,
    MIN(activity_date) AS streak_start,
    MAX(activity_date) AS streak_end,
    COUNT(*) AS streak_length_days
FROM islands
GROUP BY customer_id, grp
ORDER BY customer_id, streak_start;
