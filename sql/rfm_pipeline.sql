-- ============================================================
-- RFM ANALYSIS — E-Commerce Dataset
-- Author: Alexandre Faizibaioff
-- Dataset: UCI Online Retail (via Kaggle, by Carrie1)
-- Tool: Google BigQuery
-- Last updated: 2026-04
--
-- Overview:
--   This script segments customers using the RFM framework:
--   - Recency   → how recently a customer bought
--   - Frequency → how often they buy
--   - Monetary  → how much they spend
--
--   Each metric is scored 1–5 using NTILE quintiles.
--   Scores are summed and mapped to business segments.
-- ============================================================


-- ============================================================
-- STEP 1: Clean raw data
-- ============================================================
-- Removes columns irrelevant to RFM (StockCode, Description, Country).
-- Filters out:
--   · Rows with no CustomerID (anonymous sessions)
--   · Negative quantities (returns/cancellations)
--   · Unit prices at or near zero (likely data entry errors)
--   · Computes TotalAmount = Quantity × UnitPrice per line item.

CREATE OR REPLACE TABLE `sales.sales_clean` AS
SELECT 
  InvoiceNo,
  CustomerID,
  InvoiceDate,
  Quantity,
  UnitPrice,
  ROUND(Quantity * UnitPrice, 2) AS TotalAmount
FROM `sales.sales_raw`
WHERE CustomerID IS NOT NULL
AND Quantity > 0
AND UnitPrice > 0.01;


-- ============================================================
-- STEP 2: Calculate RFM metrics and assign quintile scores
-- ============================================================
-- Reference date: one day after the last transaction in the dataset
-- (2011-12-10), used as a proxy for "today" so recency is reproducible.
--
-- Metrics per customer:
--   · recency   = days since last purchase (lower = better)
--   · frequency = number of distinct invoices (higher = better)
--   · monetary  = total revenue generated (higher = better)
--
-- Scores (1–5) via NTILE applied directly to each metric:
--   · r_score: score 5 = bought most recently
--   · f_score: score 5 = bought most often
--   · m_score: score 5 = spent the most

CREATE OR REPLACE VIEW `sales.rfm_metrics`
AS
WITH current_date AS(
  SELECT DATE ('2011-12-10') AS analysis_date 
),
rfm AS (
  SELECT
    CustomerID,
    MAX(InvoiceDate) AS last_order_date,
    DATE_DIFF((SELECT analysis_date FROM current_date), MAX(DATE(InvoiceDate)), DAY) AS recency,
    COUNT(DISTINCT InvoiceNo) AS frequency,
    ROUND(SUM(TotalAmount),2) AS monetary
  FROM `sales.sales_clean`
  GROUP BY CustomerID
)
SELECT
  rfm.*,
  ROW_NUMBER() OVER(ORDER BY recency ASC) AS r_rank,
  ROW_NUMBER() OVER(ORDER BY frequency DESC) AS f_rank,
  ROW_NUMBER() OVER(ORDER BY monetary DESC) AS m_rank
FROM rfm;

CREATE OR REPLACE VIEW `sales.rfm_scores`
AS
SELECT
  *,
  NTILE(5) OVER(ORDER BY r_rank DESC) AS r_score,
  NTILE(5) OVER(ORDER BY f_rank DESC) AS f_score,
  NTILE(5) OVER(ORDER BY m_rank DESC) AS m_score
FROM `sales.rfm_metrics`;


-- ============================================================
-- STEP 3: Compute total RFM score and assign business segments
-- ============================================================
-- rfm_total_score = r_score + f_score + m_score  (range: 3–15)
--
-- Segmentation thresholds (based on total score):
--   13–15 → Champions           : best customers across all dimensions
--   10–12 → Loyal Customers     : frequent, high-value, recent
--    8–9  → Potential Loyalists : promising, not yet consistent
--    6–7  → At Risk             : used to buy but drifting away
--    4–5  → Hibernating         : low engagement, may still recover
--    3    → Lost                : haven't bought in a long time, low value
--

CREATE OR REPLACE VIEW `sales.rfm_total_scores`
AS
SELECT
  CustomerID,
  recency,
  frequency,
  monetary,
  r_score,
  f_score,
  m_score,
  (r_score + f_score + m_score) AS rfm_total_score
FROM `sales.rfm_scores`
ORDER BY rfm_total_score DESC;

CREATE OR REPLACE TABLE `sales.rfm_segments_final`
AS
SELECT
  CustomerID,
  recency,
  frequency,
  monetary,
  r_score,
  f_score,
  m_score,
  rfm_total_score,
  CASE
    WHEN rfm_total_score >= 13 THEN 'Champions'
    WHEN rfm_total_score >= 10 THEN 'Loyal Customers'
    WHEN rfm_total_score >= 8 THEN 'Potential Loyalists'
    WHEN rfm_total_score >= 6 THEN 'At Risk'
    WHEN rfm_total_score >= 4 THEN 'Hibernating'
    ELSE 'Lost'
  END AS rfm_segment
FROM `sales.rfm_total_scores`
ORDER BY rfm_total_score DESC;