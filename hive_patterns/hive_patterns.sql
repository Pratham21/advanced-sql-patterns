-- ============================================================
-- HIVE PATTERNS — Optimised HiveQL for large-scale pipelines
-- Author: Pratham Bharadwaj
-- Use case: Hadoop pipelines at Walt Disney (500GB+ daily), Verizon data layers
-- Platform: Apache Hive on Hadoop
-- ============================================================


-- ─────────────────────────────────────────
-- 1. PARTITIONED TABLE CREATION
-- Best practice: always partition by date on large event tables
-- Avoids full table scans — critical at 500GB+ daily volumes
-- ─────────────────────────────────────────
CREATE TABLE IF NOT EXISTS customer_events (
    customer_id     BIGINT,
    event_type      STRING,
    event_value     DOUBLE,
    session_id      STRING,
    platform        STRING
)
PARTITIONED BY (event_date STRING, region STRING)
STORED AS ORC
TBLPROPERTIES ('orc.compress' = 'SNAPPY');

-- Always specify partition in WHERE to trigger partition pruning
SELECT
    customer_id,
    event_type,
    COUNT(*) AS event_count
FROM customer_events
WHERE event_date = '2024-01-15'   -- partition pruning — reads only this partition
  AND region = 'US'
GROUP BY customer_id, event_type;


-- ─────────────────────────────────────────
-- 2. DYNAMIC PARTITION INSERT
-- Business use: Load daily data into partitioned table automatically
-- ─────────────────────────────────────────
SET hive.exec.dynamic.partition = true;
SET hive.exec.dynamic.partition.mode = nonstrict;
SET hive.exec.max.dynamic.partitions = 10000;

INSERT OVERWRITE TABLE customer_events
PARTITION (event_date, region)
SELECT
    customer_id,
    event_type,
    event_value,
    session_id,
    platform,
    DATE_FORMAT(created_at, 'yyyy-MM-dd') AS event_date,
    region
FROM raw_customer_events
WHERE created_at >= '2024-01-01';


-- ─────────────────────────────────────────
-- 3. BUCKETING — Even data distribution for join optimisation
-- Business use: Speed up joins between large customer tables
-- ─────────────────────────────────────────
CREATE TABLE customer_bucketed (
    customer_id     BIGINT,
    segment         STRING,
    lifetime_value  DOUBLE
)
CLUSTERED BY (customer_id) INTO 256 BUCKETS
STORED AS ORC;

-- Bucket map join — avoids full shuffle when joining bucketed tables
SET hive.optimize.bucketmapjoin = true;
SET hive.auto.convert.join = true;

SELECT
    c.customer_id,
    c.segment,
    SUM(t.amount) AS total_spend
FROM customer_bucketed c
JOIN transactions_bucketed t ON c.customer_id = t.customer_id
GROUP BY c.customer_id, c.segment;


-- ─────────────────────────────────────────
-- 4. MAP-SIDE AGGREGATION — Reduce shuffle for large GROUP BY
-- Business use: Aggregate billions of rows efficiently
-- ─────────────────────────────────────────
SET hive.map.aggr = true;
SET hive.groupby.skewindata = true;   -- handles skewed keys (e.g. one customer with 10M events)

SELECT
    event_type,
    region,
    COUNT(*)        AS event_count,
    COUNT(DISTINCT customer_id) AS unique_customers,
    SUM(event_value) AS total_value
FROM customer_events
WHERE event_date BETWEEN '2024-01-01' AND '2024-01-31'
GROUP BY event_type, region;


-- ─────────────────────────────────────────
-- 5. SESSIONISATION — Group events into sessions
-- Business use: Customer journey analysis, used at Disney for ticketing behaviour
-- ─────────────────────────────────────────
WITH event_gaps AS (
    SELECT
        customer_id,
        event_type,
        event_timestamp,
        LAG(event_timestamp) OVER (
            PARTITION BY customer_id
            ORDER BY event_timestamp
        ) AS prev_event_timestamp
    FROM customer_events_flat
),
session_flags AS (
    SELECT
        customer_id,
        event_type,
        event_timestamp,
        CASE
            WHEN prev_event_timestamp IS NULL THEN 1
            WHEN (UNIX_TIMESTAMP(event_timestamp) - UNIX_TIMESTAMP(prev_event_timestamp)) > 1800
                THEN 1   -- new session if gap > 30 mins
            ELSE 0
        END AS is_new_session
    FROM event_gaps
),
sessions AS (
    SELECT
        customer_id,
        event_type,
        event_timestamp,
        SUM(is_new_session) OVER (
            PARTITION BY customer_id
            ORDER BY event_timestamp
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        ) AS session_id
    FROM session_flags
)
SELECT
    customer_id,
    session_id,
    MIN(event_timestamp) AS session_start,
    MAX(event_timestamp) AS session_end,
    COUNT(*)             AS events_in_session,
    ROUND(
        (UNIX_TIMESTAMP(MAX(event_timestamp)) - UNIX_TIMESTAMP(MIN(event_timestamp))) / 60,
    1)                   AS session_duration_mins
FROM sessions
GROUP BY customer_id, session_id
ORDER BY customer_id, session_id;


-- ─────────────────────────────────────────
-- 6. ORC + SNAPPY OPTIMISATION TIPS
-- Comments-only reference used for Hadoop pipeline documentation
-- ─────────────────────────────────────────

-- Use ORC format for analytical workloads (columnar, predicate pushdown)
-- Use SNAPPY compression for balance of speed vs size
-- Use ZLIB for maximum compression on cold/archive data
-- Avoid small files — merge with:
--   SET hive.merge.mapfiles = true;
--   SET hive.merge.mapredfiles = true;
--   SET hive.merge.size.per.task = 256000000;  -- 256MB target file size

-- Check partition statistics to help query planner:
-- ANALYZE TABLE customer_events PARTITION(event_date='2024-01-15') COMPUTE STATISTICS;
-- ANALYZE TABLE customer_events COMPUTE STATISTICS FOR COLUMNS customer_id, event_type;
