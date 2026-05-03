-- ============================================================
-- FUNNEL ANALYSIS — Sales & product funnel patterns
-- Author: Pratham Bharadwaj
-- Use case: Lead-to-close tracking (Intuit), e-commerce conversion (eBay)
-- Platform: BigQuery
-- ============================================================


-- ─────────────────────────────────────────
-- 1. BASIC FUNNEL — Step-by-step conversion counts
-- Business use: How many leads make it through each sales stage?
-- ─────────────────────────────────────────
SELECT
    funnel_stage,
    COUNT(DISTINCT customer_id)                                          AS users_at_stage,
    ROUND(
        COUNT(DISTINCT customer_id) * 100.0
        / FIRST_VALUE(COUNT(DISTINCT customer_id)) OVER (ORDER BY stage_order),
    1)                                                                   AS pct_of_top_of_funnel
FROM (
    SELECT customer_id, 'Lead Created'     AS funnel_stage, 1 AS stage_order FROM leads
    UNION ALL
    SELECT customer_id, 'Demo Scheduled'  AS funnel_stage, 2 AS stage_order FROM demos
    UNION ALL
    SELECT customer_id, 'Proposal Sent'   AS funnel_stage, 3 AS stage_order FROM proposals
    UNION ALL
    SELECT customer_id, 'Contract Signed' AS funnel_stage, 4 AS stage_order FROM contracts
    UNION ALL
    SELECT customer_id, 'Closed Won'      AS funnel_stage, 5 AS stage_order FROM closed_deals
) funnel
GROUP BY funnel_stage, stage_order
ORDER BY stage_order;


-- ─────────────────────────────────────────
-- 2. DROP-OFF RATE between stages
-- Business use: Which stage loses the most leads? Where to focus sales effort?
-- ─────────────────────────────────────────
WITH funnel_counts AS (
    SELECT
        stage_order,
        funnel_stage,
        COUNT(DISTINCT customer_id) AS users
    FROM funnel_events
    GROUP BY stage_order, funnel_stage
),
with_prev AS (
    SELECT
        stage_order,
        funnel_stage,
        users,
        LAG(users) OVER (ORDER BY stage_order) AS prev_stage_users
    FROM funnel_counts
)
SELECT
    funnel_stage,
    users,
    prev_stage_users,
    ROUND((prev_stage_users - users) * 100.0 / NULLIF(prev_stage_users, 0), 1) AS drop_off_pct
FROM with_prev
ORDER BY stage_order;


-- ─────────────────────────────────────────
-- 3. TIME TO CONVERT — How long does each stage take?
-- Business use: Identify slow stages, set SLA benchmarks for sales team
-- ─────────────────────────────────────────
SELECT
    stage_name,
    ROUND(AVG(days_in_stage), 1)    AS avg_days,
    MIN(days_in_stage)              AS min_days,
    MAX(days_in_stage)              AS max_days,
    APPROX_QUANTILES(days_in_stage, 100)[OFFSET(50)] AS median_days,
    APPROX_QUANTILES(days_in_stage, 100)[OFFSET(90)] AS p90_days
FROM (
    SELECT
        stage_name,
        DATE_DIFF(stage_exit_date, stage_enter_date, DAY) AS days_in_stage
    FROM stage_transitions
    WHERE stage_exit_date IS NOT NULL
)
GROUP BY stage_name
ORDER BY avg_days DESC;


-- ─────────────────────────────────────────
-- 4. FUNNEL BY SEGMENT — Compare conversion across customer segments
-- Business use: Do enterprise customers convert better than SMB?
-- ─────────────────────────────────────────
SELECT
    segment,
    COUNT(DISTINCT CASE WHEN stage >= 1 THEN customer_id END) AS leads,
    COUNT(DISTINCT CASE WHEN stage >= 2 THEN customer_id END) AS demos,
    COUNT(DISTINCT CASE WHEN stage >= 3 THEN customer_id END) AS proposals,
    COUNT(DISTINCT CASE WHEN stage >= 4 THEN customer_id END) AS closed,
    ROUND(
        COUNT(DISTINCT CASE WHEN stage >= 4 THEN customer_id END) * 100.0
        / NULLIF(COUNT(DISTINCT CASE WHEN stage >= 1 THEN customer_id END), 0),
    1) AS overall_conversion_pct
FROM customer_funnel_stages
GROUP BY segment
ORDER BY overall_conversion_pct DESC;


-- ─────────────────────────────────────────
-- 5. MULTI-TOUCH ATTRIBUTION — First touch vs last touch
-- Business use: Which marketing channel deserves credit for the conversion?
-- Used at Verizon for campaign attribution
-- ─────────────────────────────────────────
WITH touchpoints AS (
    SELECT
        customer_id,
        channel,
        touched_at,
        ROW_NUMBER() OVER (PARTITION BY customer_id ORDER BY touched_at ASC)  AS first_touch_rank,
        ROW_NUMBER() OVER (PARTITION BY customer_id ORDER BY touched_at DESC) AS last_touch_rank
    FROM marketing_touches
    WHERE customer_id IN (SELECT customer_id FROM converted_customers)
)
SELECT
    channel,
    COUNT(CASE WHEN first_touch_rank = 1 THEN 1 END) AS first_touch_conversions,
    COUNT(CASE WHEN last_touch_rank  = 1 THEN 1 END) AS last_touch_conversions
FROM touchpoints
GROUP BY channel
ORDER BY first_touch_conversions DESC;
