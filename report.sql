--Summary (Sheet 1)
WITH date_periods AS (SELECT 'Past Week'                                                         AS period,
                             DATE_SUB(DATE_TRUNC(CURRENT_DATE(), WEEK(MONDAY)), INTERVAL 1 WEEK) AS start_dt,
                             DATE_SUB(DATE_TRUNC(CURRENT_DATE(), WEEK(MONDAY)), INTERVAL 1 DAY)  AS end_dt
                      UNION ALL
                      SELECT 'Past Month',
                             DATE_TRUNC(DATE_SUB(CURRENT_DATE(), INTERVAL 1 MONTH), MONTH),
                             DATE_SUB(DATE_TRUNC(CURRENT_DATE(), MONTH), INTERVAL 1 DAY)
                      UNION ALL
                      SELECT 'Trailing 3 Months',
                             DATE_SUB(DATE_TRUNC(CURRENT_DATE(), WEEK(MONDAY)), INTERVAL 3 MONTH),
                             CURRENT_DATE()),
     vq AS (SELECT v.lot                                                                                   AS lot_nbr,
                   AVG(CAST(JSON_EXTRACT(v.output_details_json,
                                         '$.vuequote_results.vpq_result.proquote_amount') AS NUMERIC))     AS vq_amt,
                   AVG(CAST(JSON_EXTRACT(v.output_details_json,
                                         '$.vuequote_results.vpq_result.proquote_amount_low') AS NUMERIC)) AS vq_amt_low,
                   AVG(CAST(JSON_EXTRACT(v.output_details_json,
                                         '$.vuequote_results.vpq_result.proquote_amount_high') AS NUMERIC)) AS vq_amt_high
            FROM `cprtpr-dataplatform-sp1`.usviews.v_us_lot_image_damage_scores_fact v
            GROUP BY v.lot),
     lot_base AS (SELECT f.lot_nbr,
                         f.inv_dt AS sale_date,
                         CASE
                             WHEN f.BU_hrchy_levl2 = 'BluCar' AND f.seller_parent_company <> 'TFSS'
                                 THEN 'BluCar ex-TFSS'
                             WHEN f.BU_hrchy_levl2 = 'Insurance' OR f.seller_parent_company = 'TFSS'
                                 THEN 'Insurance + TFSS'
                             END  AS breakout
                  FROM `cprtpr-dataplatform-sp1`.usviews.v_us_lot_fact f
                  WHERE f.inv_dt BETWEEN DATE_SUB(CURRENT_DATE(), INTERVAL 13 MONTH) AND CURRENT_DATE()),
-- ---------------------------------------------------------------------
-- Per-breakout cleansing filters:
--   Insurance + TFSS  → STRICT actuarial gates (acv/repair_cost thresholds,
--                       high_bid floor, repair/acv ratio, loss_type_cd='C' for PQ.AI)
--   BluCar ex-TFSS    → LOOSE gates only (matches Local Python seller report)
-- Same column shape per UNION arm so downstream CTEs are unchanged.
-- ---------------------------------------------------------------------
-- PQ Cleansed lots — Insurance + TFSS (strict)
     lot_errors_ins AS (SELECT f.lot_nbr,
                               f.inv_dt       AS sale_date,
                               f.high_bid_amt AS sale_price,
                               f.BU_hrchy_levl2,
                               f.seller_parent_company,
                               f.proquote_amt_new,
                               CASE
                                   WHEN f.proquote_amt_new > 0 THEN f.proquote_amt_new
                                   WHEN f.proquote_amt > 0 THEN f.proquote_amt
                                   END        AS proquote_amt
                        FROM `cprtpr-dataplatform-sp1`.usviews.v_us_lot_fact f
                        WHERE (f.BU_hrchy_levl2 = 'Insurance' OR f.seller_parent_company = 'TFSS')
                          AND f.inv_dt BETWEEN DATE_SUB(CURRENT_DATE(), INTERVAL 13 MONTH) AND CURRENT_DATE()
                          AND f.lot_type_cd IN ('V')
                          AND f.acv < 100000
                          AND f.acv >= 1000.01
                          AND f.repair_cost >= 1000.01
                          AND f.acv <> f.repair_cost
                          AND f.high_bid_amt > 0.5 * (f.acv - f.repair_cost)
                          AND f.cat_id = -1
                          AND f.repair_cost / f.acv < 2
                          AND (f.proquote_amt_new IS NOT NULL)),
-- PQ Cleansed lots — BluCar ex-TFSS (loose, matches seller report)
     lot_errors_blu AS (SELECT f.lot_nbr,
                               f.inv_dt       AS sale_date,
                               f.high_bid_amt AS sale_price,
                               f.BU_hrchy_levl2,
                               f.seller_parent_company,
                               f.proquote_amt_new,
                               CASE
                                   WHEN f.proquote_amt_new > 0 THEN f.proquote_amt_new
                                   WHEN f.proquote_amt > 0 THEN f.proquote_amt
                                   END        AS proquote_amt
                        FROM `cprtpr-dataplatform-sp1`.usviews.v_us_lot_fact f
                        WHERE f.BU_hrchy_levl2 = 'BluCar' AND f.seller_parent_company <> 'TFSS'
                          AND f.inv_dt BETWEEN DATE_SUB(CURRENT_DATE(), INTERVAL 13 MONTH) AND CURRENT_DATE()
                          AND f.lot_type_cd IN ('V')
                          AND f.acv < 100000
                          AND f.cat_id = -1
                          --AND f.acv >= 1000.01
                          --AND f.repair_cost >= 1000.01
                          --AND f.acv <> f.repair_cost
                          --AND f.high_bid_amt > 0.5 * (f.acv - f.repair_cost)
                          --AND f.repair_cost / f.acv < 2
                          AND (f.proquote_amt_new IS NOT NULL)),
     lot_errors AS (SELECT * FROM lot_errors_ins
                    UNION ALL
                    SELECT * FROM lot_errors_blu),
-- PQ.AI Cleansed lots — Insurance + TFSS (strict: collision only)
     lot_errors_pqai_ins AS (SELECT f.lot_nbr,
                                    f.inv_dt       AS sale_date,
                                    f.high_bid_amt AS sale_price,
                                    f.BU_hrchy_levl2,
                                    f.seller_parent_company,
                                    v.vq_amt,
                                    v.vq_amt_low,
                                    v.vq_amt_high,
                                    'Insurance + TFSS' AS breakout
                             FROM `cprtpr-dataplatform-sp1`.usviews.v_us_lot_fact f
                                      INNER JOIN vq v ON f.lot_nbr = v.lot_nbr
                             WHERE (f.BU_hrchy_levl2 = 'Insurance' OR f.seller_parent_company = 'TFSS')
                               AND f.inv_dt BETWEEN DATE_SUB(CURRENT_DATE(), INTERVAL 13 MONTH) AND CURRENT_DATE()
                               AND f.lot_type_cd IN ('V')
                               AND f.acv < 100000
                               AND f.loss_type_cd = 'C'
                               AND f.cat_id = -1
                               AND v.vq_amt IS NOT NULL),
-- PQ.AI Cleansed lots — BluCar ex-TFSS (loose: all loss types)
     lot_errors_pqai_blu AS (SELECT f.lot_nbr,
                                    f.inv_dt       AS sale_date,
                                    f.high_bid_amt AS sale_price,
                                    f.BU_hrchy_levl2,
                                    f.seller_parent_company,
                                    v.vq_amt,
                                    v.vq_amt_low,
                                    v.vq_amt_high,
                                    'BluCar ex-TFSS' AS breakout
                             FROM `cprtpr-dataplatform-sp1`.usviews.v_us_lot_fact f
                                      INNER JOIN vq v ON f.lot_nbr = v.lot_nbr
                             WHERE f.BU_hrchy_levl2 = 'BluCar' AND f.seller_parent_company <> 'TFSS'
                               AND f.inv_dt BETWEEN DATE_SUB(CURRENT_DATE(), INTERVAL 13 MONTH) AND CURRENT_DATE()
                               AND f.lot_type_cd IN ('V')
                               AND f.acv < 100000
                               AND f.cat_id = -1
                               --AND f.loss_type_cd = 'C'
                               AND v.vq_amt IS NOT NULL),
     lot_errors_pqai AS (SELECT * FROM lot_errors_pqai_ins
                         UNION ALL
                         SELECT * FROM lot_errors_pqai_blu),
     classified AS (SELECT lot_nbr,
                           sale_date,
                           sale_price,
                           BU_hrchy_levl2,
                           seller_parent_company,
                           proquote_amt_new,
                           proquote_amt,
                           CASE
                               WHEN BU_hrchy_levl2 = 'BluCar' AND seller_parent_company <> 'TFSS' THEN 'BluCar ex-TFSS'
                               WHEN BU_hrchy_levl2 = 'Insurance' OR seller_parent_company = 'TFSS'
                                   THEN 'Insurance + TFSS'
                               END AS breakout
                    FROM lot_errors),
-- Units Sold from base
     units_sold AS (SELECT b.breakout,
                           dp.period,
                           COUNT(DISTINCT b.lot_nbr) AS `Units Sold`
                    FROM lot_base b
                             JOIN date_periods dp ON b.sale_date BETWEEN dp.start_dt AND dp.end_dt
                    WHERE b.breakout IN ('Insurance + TFSS', 'BluCar ex-TFSS')
                    GROUP BY b.breakout, dp.period),
-- PQ Cleansed aggregation
     agg AS (SELECT c.breakout,
                    dp.period,
                    COUNT(DISTINCT c.lot_nbr)                                     AS `PQ Cleansed Units Sold`,
                    ROUND(AVG(sale_price), 2)                                     AS `ASP - PQ Cleansed`,
                    ROUND(AVG(proquote_amt), 2)                                   AS `Avg ProQuote - Cleansed`,
                    ROUND(SAFE_DIVIDE(AVG(proquote_amt), AVG(sale_price)) - 1, 4) AS `PQ Mean Error Pct - Cleansed`,
                    ROUND(AVG(ABS(proquote_amt - sale_price)), 2)                 AS `PQ MAE - Cleansed`,
                    ROUND(AVG(ABS(proquote_amt - sale_price) / NULLIF(ABS(sale_price), 0)),
                          4)                                                      AS `PQ MAPE - Cleansed`
             FROM classified c
                      JOIN date_periods dp ON c.sale_date BETWEEN dp.start_dt AND dp.end_dt
             WHERE c.breakout IN ('Insurance + TFSS', 'BluCar ex-TFSS')
             GROUP BY c.breakout, dp.period),
-- PQ.AI Cleansed aggregation
     agg_pqai AS (SELECT p.breakout,
                         dp.period,
                         COUNT(DISTINCT p.lot_nbr)                                   AS `PQ_ai Cleansed Units Sold`,
                         ROUND(AVG(p.sale_price), 2)                                 AS `ASP - PQ_ai Cleansed`,
                         ROUND(AVG(p.vq_amt), 2)                                     AS `Avg PQ_ai - Cleansed`,
                         ROUND(SAFE_DIVIDE(AVG(p.vq_amt), AVG(p.sale_price)) - 1, 4) AS `PQ_ai Mean Error Pct - Cleansed`,
                         ROUND(AVG(ABS(p.vq_amt - p.sale_price)), 2)                 AS `PQ_ai MAE - Cleansed`,
                         ROUND(AVG(ABS(p.vq_amt - p.sale_price) / NULLIF(ABS(p.sale_price), 0)),
                               4)                                                    AS `PQ_ai MAPE - Cleansed`,
                         ROUND(AVG(p.vq_amt_low), 2)                                     AS `Avg PQ_ai Low - Cleansed`,
                         ROUND(SAFE_DIVIDE(AVG(p.vq_amt_low), AVG(p.sale_price)) - 1, 4) AS `PQ_ai Low Mean Error Pct - Cleansed`,
                         ROUND(AVG(ABS(p.vq_amt_low - p.sale_price)), 2)                 AS `PQ_ai Low MAE - Cleansed`,
                         ROUND(AVG(ABS(p.vq_amt_low - p.sale_price) / NULLIF(ABS(p.sale_price), 0)),
                               4)                                                        AS `PQ_ai Low MAPE - Cleansed`,
                         ROUND(AVG(p.vq_amt_high), 2)                                     AS `Avg PQ_ai High - Cleansed`,
                         ROUND(SAFE_DIVIDE(AVG(p.vq_amt_high), AVG(p.sale_price)) - 1, 4) AS `PQ_ai High Mean Error Pct - Cleansed`,
                         ROUND(AVG(ABS(p.vq_amt_high - p.sale_price)), 2)                 AS `PQ_ai High MAE - Cleansed`,
                         ROUND(AVG(ABS(p.vq_amt_high - p.sale_price) / NULLIF(ABS(p.sale_price), 0)),
                               4)                                                         AS `PQ_ai High MAPE - Cleansed`
                  FROM lot_errors_pqai p
                           JOIN date_periods dp ON p.sale_date BETWEEN dp.start_dt AND dp.end_dt
                  WHERE p.breakout IN ('Insurance + TFSS', 'BluCar ex-TFSS')
                  GROUP BY p.breakout, dp.period)
SELECT u.breakout,
       u.period,
       u.`Units Sold`,
       a.`PQ Cleansed Units Sold`,
       ap.`PQ_ai Cleansed Units Sold`,
       ROUND(SAFE_DIVIDE(a.`PQ Cleansed Units Sold`, u.`Units Sold`), 4)     AS `% Sold with ProQuote Cleansed`,
       ROUND(SAFE_DIVIDE(ap.`PQ_ai Cleansed Units Sold`, u.`Units Sold`), 4) AS `% Sold with ProQuote_ai Cleansed`,
       a.`ASP - PQ Cleansed`,
       a.`Avg ProQuote - Cleansed`,
       a.`PQ Mean Error Pct - Cleansed`,
       a.`PQ MAE - Cleansed`,
       a.`PQ MAPE - Cleansed`,
       ap.`ASP - PQ_ai Cleansed`,
       ap.`Avg PQ_ai - Cleansed`,
       ap.`PQ_ai Mean Error Pct - Cleansed`,
       ap.`PQ_ai MAE - Cleansed`,
       ap.`PQ_ai MAPE - Cleansed`,
       ap.`Avg PQ_ai Low - Cleansed`,
       ap.`PQ_ai Low Mean Error Pct - Cleansed`,
       ap.`PQ_ai Low MAE - Cleansed`,
       ap.`PQ_ai Low MAPE - Cleansed`,
       ap.`Avg PQ_ai High - Cleansed`,
       ap.`PQ_ai High Mean Error Pct - Cleansed`,
       ap.`PQ_ai High MAE - Cleansed`,
       ap.`PQ_ai High MAPE - Cleansed`
FROM units_sold u
         LEFT JOIN agg a ON u.breakout = a.breakout AND u.period = a.period
         LEFT JOIN agg_pqai ap ON u.breakout = ap.breakout AND u.period = ap.period
ORDER BY u.breakout,
         CASE u.period
             WHEN 'Past Week' THEN 1
             WHEN 'Past Month' THEN 2
             WHEN 'Trailing 3 Months' THEN 3
             END;

-- =====================================================================
-- BluCar ex-TFSS (Sheet 2)
-- =====================================================================
-- PQ.ai Error ACV Bucket View - BluCar ex-TFSS
WITH date_periods AS (
    SELECT 'Past Week' AS period,
           DATE_SUB(DATE_TRUNC(CURRENT_DATE(), WEEK(MONDAY)), INTERVAL 1 WEEK) AS start_dt,
           DATE_SUB(DATE_TRUNC(CURRENT_DATE(), WEEK(MONDAY)), INTERVAL 1 DAY) AS end_dt
    UNION ALL
    SELECT 'Past Month',
           DATE_TRUNC(DATE_SUB(CURRENT_DATE(), INTERVAL 1 MONTH), MONTH),
           DATE_SUB(DATE_TRUNC(CURRENT_DATE(), MONTH), INTERVAL 1 DAY)
    UNION ALL
    SELECT 'Trailing 3 Months',
           DATE_SUB(DATE_TRUNC(CURRENT_DATE(), WEEK(MONDAY)), INTERVAL 3 MONTH),
           CURRENT_DATE()
),
cte AS (
    SELECT lot AS lot_nbr, crt_dt AS latest_pqai, output_details_json, lids_version
    FROM (
        SELECT v.lot, v.crt_dt, v.output_details_json, v.lids_version,
               ROW_NUMBER() OVER (PARTITION BY v.lot ORDER BY v.crt_dt DESC) AS rn
        FROM `cprtpr-dataplatform-sp1`.usviews.v_us_lot_image_damage_scores_fact v
        WHERE CAST(JSON_EXTRACT(v.output_details_json,
            '$.vuequote_results.vpq_result.proquote_amount') AS NUMERIC) IS NOT NULL
    )
    WHERE rn = 1
),
cte_pq AS (
    SELECT lot_nbr, 1 AS pq_flag
    FROM `cprtpr-dataplatform-sp1`.usviews.v_us_lot_fact
    -- BluCar ex-TFSS cte_pq: loose PQ-cleansed gates (matches seller report)
    WHERE BU_hrchy_levl2 = 'BluCar'
      AND seller_parent_company <> 'TFSS'
      AND inv_dt >= '2025-01-01'
      AND lot_type_cd IN ('V')
      AND cat_id = -1
      AND acv < 100000
      --AND acv >= 1000.01
      --AND repair_cost >= 1000.01
      --AND acv <> repair_cost
      --AND high_bid_amt > 0.5 * (acv - repair_cost)
      --AND repair_cost / acv < 2
      AND proquote_amt_new IS NOT NULL
),
cte_pqai AS (
    SELECT f.lot_nbr, 1 AS pqai_flag
    FROM `cprtpr-dataplatform-sp1`.usviews.v_us_lot_fact f
    INNER JOIN cte ON f.lot_nbr = cte.lot_nbr
    -- BluCar ex-TFSS cte_pqai: all loss types (no collision-only restriction)
    WHERE f.BU_hrchy_levl2 = 'BluCar'
      AND f.seller_parent_company <> 'TFSS'
      AND f.inv_dt >= '2025-01-01'
      AND f.lot_type_cd IN ('V')
      AND f.cat_id = -1
      AND f.acv < 100000
      --AND f.loss_type_cd = 'C'
),
cte3 AS (
    SELECT
        l.lot_nbr, inv_dt, acv, high_bid_amt,
        lot_type_cd, loss_type_desc, lot_make_cd,
        CASE
            WHEN l.proquote_amt_new > 0 THEN l.proquote_amt_new
            WHEN l.proquote_amt > 0 THEN l.proquote_amt
        END AS proquote_amt_cleansed,
        CAST(JSON_EXTRACT(cte.output_details_json,
            '$.vuequote_results.vpq_result.proquote_amount') AS NUMERIC) AS PQ_ai_amt,
        CAST(JSON_EXTRACT(cte.output_details_json,
            '$.vuequote_results.vpq_result.proquote_amount_low') AS NUMERIC) AS PQ_ai_amt_low,
        CAST(JSON_EXTRACT(cte.output_details_json,
            '$.vuequote_results.vpq_result.proquote_amount_high') AS NUMERIC) AS PQ_ai_amt_high,
        cte_pq.pq_flag,
        cte_pqai.pqai_flag
    FROM `cprtpr-dataplatform-sp1`.usviews.v_us_lot_fact l
        LEFT JOIN cte ON cte.lot_nbr = l.lot_nbr
        LEFT JOIN cte_pq ON cte_pq.lot_nbr = l.lot_nbr
        LEFT JOIN cte_pqai ON cte_pqai.lot_nbr = l.lot_nbr
    WHERE BU_hrchy_levl2 = 'BluCar'
      AND seller_parent_company <> 'TFSS'
      AND inv_dt >= '2025-01-01'
)
SELECT dp.period,
       CASE
           WHEN acv < 5000 THEN 'a. Less than 5k'
           WHEN acv >= 5000 AND acv < 10000 THEN 'b. 5-10k'
           WHEN acv >= 10000 AND acv < 15000 THEN 'c. 10-15k'
           WHEN acv >= 15000 AND acv < 20000 THEN 'd. 15-20k'
           WHEN acv >= 20000 AND acv < 30000 THEN 'e. 20-30k'
           WHEN acv >= 30000 AND acv < 40000 THEN 'f. 30-40k'
           WHEN acv >= 40000 AND acv < 50000 THEN 'g. 40-50k'
           ELSE 'h. 50k+'
       END AS ACV_Bucket,
       COUNT(DISTINCT lot_nbr)                                                                        AS `Units Sold`,
       COUNT(DISTINCT CASE WHEN pq_flag = 1 THEN lot_nbr END)                                        AS `PQ Cleansed Units Sold`,
       COUNT(DISTINCT CASE WHEN pqai_flag = 1 THEN lot_nbr END)                                      AS `PQ_ai Cleansed Units Sold`,
       ROUND(SAFE_DIVIDE(COUNT(DISTINCT CASE WHEN pq_flag = 1 THEN lot_nbr END),
                         COUNT(DISTINCT lot_nbr)), 4)                                                 AS `% Sold with ProQuote Cleansed`,
       ROUND(SAFE_DIVIDE(COUNT(DISTINCT CASE WHEN pqai_flag = 1 THEN lot_nbr END),
                         COUNT(DISTINCT lot_nbr)), 4)                                                 AS `% Sold with ProQuote_ai Cleansed`,
       -- PQ Cleansed metrics
       ROUND(AVG(CASE WHEN pq_flag = 1 THEN high_bid_amt END), 2)                                    AS `ASP - PQ Cleansed`,
       ROUND(AVG(CASE WHEN pq_flag = 1 THEN proquote_amt_cleansed END), 2)                           AS `Avg ProQuote - Cleansed`,
       ROUND(SAFE_DIVIDE(AVG(CASE WHEN pq_flag = 1 THEN proquote_amt_cleansed END),
                         AVG(CASE WHEN pq_flag = 1 THEN high_bid_amt END)) - 1, 4)                   AS `PQ Mean Error Pct - Cleansed`,
       ROUND(AVG(CASE WHEN pq_flag = 1 THEN ABS(proquote_amt_cleansed - high_bid_amt) END), 2)       AS `PQ MAE - Cleansed`,
       ROUND(AVG(CASE WHEN pq_flag = 1
           THEN ABS(proquote_amt_cleansed - high_bid_amt) / NULLIF(ABS(high_bid_amt), 0) END), 4)    AS `PQ MAPE - Cleansed`,
       -- PQAI Cleansed metrics
       ROUND(AVG(CASE WHEN pqai_flag = 1 THEN high_bid_amt END), 2)                                  AS `ASP - PQ_ai Cleansed`,
       ROUND(AVG(CASE WHEN pqai_flag = 1 THEN PQ_ai_amt END), 2)                                     AS `Avg PQ_ai - Cleansed`,
       ROUND(SAFE_DIVIDE(AVG(CASE WHEN pqai_flag = 1 THEN PQ_ai_amt END),
                         AVG(CASE WHEN pqai_flag = 1 THEN high_bid_amt END)) - 1, 4)                 AS `PQ_ai Mean Error Pct - Cleansed`,
       ROUND(AVG(CASE WHEN pqai_flag = 1 THEN ABS(PQ_ai_amt - high_bid_amt) END), 2)                 AS `PQ_ai MAE - Cleansed`,
       ROUND(AVG(CASE WHEN pqai_flag = 1
           THEN ABS(PQ_ai_amt - high_bid_amt) / NULLIF(ABS(high_bid_amt), 0) END), 4)                AS `PQ_ai MAPE - Cleansed`,
       -- PQAI Cleansed Low metrics
       ROUND(AVG(CASE WHEN pqai_flag = 1 THEN PQ_ai_amt_low END), 2)                                 AS `Avg PQ_ai Low - Cleansed`,
       ROUND(SAFE_DIVIDE(AVG(CASE WHEN pqai_flag = 1 THEN PQ_ai_amt_low END),
                         AVG(CASE WHEN pqai_flag = 1 THEN high_bid_amt END)) - 1, 4)                 AS `PQ_ai Low Mean Error Pct - Cleansed`,
       ROUND(AVG(CASE WHEN pqai_flag = 1 THEN ABS(PQ_ai_amt_low - high_bid_amt) END), 2)             AS `PQ_ai Low MAE - Cleansed`,
       ROUND(AVG(CASE WHEN pqai_flag = 1
           THEN ABS(PQ_ai_amt_low - high_bid_amt) / NULLIF(ABS(high_bid_amt), 0) END), 4)            AS `PQ_ai Low MAPE - Cleansed`,
       -- PQAI Cleansed High metrics
       ROUND(AVG(CASE WHEN pqai_flag = 1 THEN PQ_ai_amt_high END), 2)                                AS `Avg PQ_ai High - Cleansed`,
       ROUND(SAFE_DIVIDE(AVG(CASE WHEN pqai_flag = 1 THEN PQ_ai_amt_high END),
                         AVG(CASE WHEN pqai_flag = 1 THEN high_bid_amt END)) - 1, 4)                 AS `PQ_ai High Mean Error Pct - Cleansed`,
       ROUND(AVG(CASE WHEN pqai_flag = 1 THEN ABS(PQ_ai_amt_high - high_bid_amt) END), 2)            AS `PQ_ai High MAE - Cleansed`,
       ROUND(AVG(CASE WHEN pqai_flag = 1
           THEN ABS(PQ_ai_amt_high - high_bid_amt) / NULLIF(ABS(high_bid_amt), 0) END), 4)           AS `PQ_ai High MAPE - Cleansed`
FROM cte3
JOIN date_periods dp ON cte3.inv_dt BETWEEN dp.start_dt AND dp.end_dt
GROUP BY 1, 2
ORDER BY
    CASE dp.period WHEN 'Past Week' THEN 1 WHEN 'Past Month' THEN 2 WHEN 'Trailing 3 Months' THEN 3 END,
    ACV_Bucket;


-- PQ.ai Error Sale Price Bucket View - BluCar ex-TFSS
WITH date_periods AS (
    SELECT 'Past Week' AS period,
           DATE_SUB(DATE_TRUNC(CURRENT_DATE(), WEEK(MONDAY)), INTERVAL 1 WEEK) AS start_dt,
           DATE_SUB(DATE_TRUNC(CURRENT_DATE(), WEEK(MONDAY)), INTERVAL 1 DAY) AS end_dt
    UNION ALL
    SELECT 'Past Month',
           DATE_TRUNC(DATE_SUB(CURRENT_DATE(), INTERVAL 1 MONTH), MONTH),
           DATE_SUB(DATE_TRUNC(CURRENT_DATE(), MONTH), INTERVAL 1 DAY)
    UNION ALL
    SELECT 'Trailing 3 Months',
           DATE_SUB(DATE_TRUNC(CURRENT_DATE(), WEEK(MONDAY)), INTERVAL 3 MONTH),
           CURRENT_DATE()
),
cte AS (
    SELECT lot AS lot_nbr, crt_dt AS latest_pqai, output_details_json, lids_version
    FROM (
        SELECT v.lot, v.crt_dt, v.output_details_json, v.lids_version,
               ROW_NUMBER() OVER (PARTITION BY v.lot ORDER BY v.crt_dt DESC) AS rn
        FROM `cprtpr-dataplatform-sp1`.usviews.v_us_lot_image_damage_scores_fact v
        WHERE CAST(JSON_EXTRACT(v.output_details_json,
            '$.vuequote_results.vpq_result.proquote_amount') AS NUMERIC) IS NOT NULL
    )
    WHERE rn = 1
),
cte_pq AS (
    SELECT lot_nbr, 1 AS pq_flag
    FROM `cprtpr-dataplatform-sp1`.usviews.v_us_lot_fact
    -- BluCar ex-TFSS cte_pq: loose PQ-cleansed gates (matches seller report)
    WHERE BU_hrchy_levl2 = 'BluCar'
      AND seller_parent_company <> 'TFSS'
      AND inv_dt >= '2025-01-01'
      AND lot_type_cd IN ('V')
      AND cat_id = -1
      AND acv < 100000
      --AND acv >= 1000.01
      --AND repair_cost >= 1000.01
      --AND acv <> repair_cost
      --AND high_bid_amt > 0.5 * (acv - repair_cost)
      --AND repair_cost / acv < 2
      AND proquote_amt_new IS NOT NULL
),
cte_pqai AS (
    SELECT f.lot_nbr, 1 AS pqai_flag
    FROM `cprtpr-dataplatform-sp1`.usviews.v_us_lot_fact f
    INNER JOIN cte ON f.lot_nbr = cte.lot_nbr
    -- BluCar ex-TFSS cte_pqai: all loss types (no collision-only restriction)
    WHERE f.BU_hrchy_levl2 = 'BluCar'
      AND f.seller_parent_company <> 'TFSS'
      AND f.inv_dt >= '2025-01-01'
      AND f.lot_type_cd IN ('V')
      AND f.cat_id = -1
      AND f.acv < 100000
      --AND f.loss_type_cd = 'C'
),
cte3 AS (
    SELECT
        l.lot_nbr, inv_dt, acv, high_bid_amt,
        lot_type_cd, loss_type_desc, lot_make_cd,
        CASE
            WHEN l.proquote_amt_new > 0 THEN l.proquote_amt_new
            WHEN l.proquote_amt > 0 THEN l.proquote_amt
        END AS proquote_amt_cleansed,
        CAST(JSON_EXTRACT(cte.output_details_json,
            '$.vuequote_results.vpq_result.proquote_amount') AS NUMERIC) AS PQ_ai_amt,
        CAST(JSON_EXTRACT(cte.output_details_json,
            '$.vuequote_results.vpq_result.proquote_amount_low') AS NUMERIC) AS PQ_ai_amt_low,
        CAST(JSON_EXTRACT(cte.output_details_json,
            '$.vuequote_results.vpq_result.proquote_amount_high') AS NUMERIC) AS PQ_ai_amt_high,
        cte_pq.pq_flag,
        cte_pqai.pqai_flag
    FROM `cprtpr-dataplatform-sp1`.usviews.v_us_lot_fact l
        LEFT JOIN cte ON cte.lot_nbr = l.lot_nbr
        LEFT JOIN cte_pq ON cte_pq.lot_nbr = l.lot_nbr
        LEFT JOIN cte_pqai ON cte_pqai.lot_nbr = l.lot_nbr
    WHERE BU_hrchy_levl2 = 'BluCar'
      AND seller_parent_company <> 'TFSS'
      AND inv_dt >= '2025-01-01'
)
SELECT dp.period,
       CASE
           WHEN high_bid_amt < 500 THEN 'a. 0-500'
           WHEN high_bid_amt >= 500 AND high_bid_amt < 1000 THEN 'b. 500-1000'
           WHEN high_bid_amt >= 1000 AND high_bid_amt < 2500 THEN 'c. 1000-2500'
           WHEN high_bid_amt >= 2500 AND high_bid_amt < 5000 THEN 'd. 2500-5000'
           WHEN high_bid_amt >= 5000 AND high_bid_amt < 10000 THEN 'e. 5000-10000'
           WHEN high_bid_amt >= 10000 AND high_bid_amt < 20000 THEN 'f. 10000-20000'
           ELSE 'g. 20000+'
       END AS Sale_Price_Bucket,
       COUNT(DISTINCT lot_nbr)                                                                        AS `Units Sold`,
       COUNT(DISTINCT CASE WHEN pq_flag = 1 THEN lot_nbr END)                                        AS `PQ Cleansed Units Sold`,
       COUNT(DISTINCT CASE WHEN pqai_flag = 1 THEN lot_nbr END)                                      AS `PQ_ai Cleansed Units Sold`,
       ROUND(SAFE_DIVIDE(COUNT(DISTINCT CASE WHEN pq_flag = 1 THEN lot_nbr END),
                         COUNT(DISTINCT lot_nbr)), 4)                                                 AS `% Sold with ProQuote Cleansed`,
       ROUND(SAFE_DIVIDE(COUNT(DISTINCT CASE WHEN pqai_flag = 1 THEN lot_nbr END),
                         COUNT(DISTINCT lot_nbr)), 4)                                                 AS `% Sold with ProQuote_ai Cleansed`,
       -- PQ Cleansed metrics
       ROUND(AVG(CASE WHEN pq_flag = 1 THEN high_bid_amt END), 2)                                    AS `ASP - PQ Cleansed`,
       ROUND(AVG(CASE WHEN pq_flag = 1 THEN proquote_amt_cleansed END), 2)                           AS `Avg ProQuote - Cleansed`,
       ROUND(SAFE_DIVIDE(AVG(CASE WHEN pq_flag = 1 THEN proquote_amt_cleansed END),
                         AVG(CASE WHEN pq_flag = 1 THEN high_bid_amt END)) - 1, 4)                   AS `PQ Mean Error Pct - Cleansed`,
       ROUND(AVG(CASE WHEN pq_flag = 1 THEN ABS(proquote_amt_cleansed - high_bid_amt) END), 2)       AS `PQ MAE - Cleansed`,
       ROUND(AVG(CASE WHEN pq_flag = 1
           THEN ABS(proquote_amt_cleansed - high_bid_amt) / NULLIF(ABS(high_bid_amt), 0) END), 4)    AS `PQ MAPE - Cleansed`,
       -- PQAI Cleansed metrics
       ROUND(AVG(CASE WHEN pqai_flag = 1 THEN high_bid_amt END), 2)                                  AS `ASP - PQ_ai Cleansed`,
       ROUND(AVG(CASE WHEN pqai_flag = 1 THEN PQ_ai_amt END), 2)                                     AS `Avg PQ_ai - Cleansed`,
       ROUND(SAFE_DIVIDE(AVG(CASE WHEN pqai_flag = 1 THEN PQ_ai_amt END),
                         AVG(CASE WHEN pqai_flag = 1 THEN high_bid_amt END)) - 1, 4)                 AS `PQ_ai Mean Error Pct - Cleansed`,
       ROUND(AVG(CASE WHEN pqai_flag = 1 THEN ABS(PQ_ai_amt - high_bid_amt) END), 2)                 AS `PQ_ai MAE - Cleansed`,
       ROUND(AVG(CASE WHEN pqai_flag = 1
           THEN ABS(PQ_ai_amt - high_bid_amt) / NULLIF(ABS(high_bid_amt), 0) END), 4)                AS `PQ_ai MAPE - Cleansed`,
       -- PQAI Cleansed Low metrics
       ROUND(AVG(CASE WHEN pqai_flag = 1 THEN PQ_ai_amt_low END), 2)                                 AS `Avg PQ_ai Low - Cleansed`,
       ROUND(SAFE_DIVIDE(AVG(CASE WHEN pqai_flag = 1 THEN PQ_ai_amt_low END),
                         AVG(CASE WHEN pqai_flag = 1 THEN high_bid_amt END)) - 1, 4)                 AS `PQ_ai Low Mean Error Pct - Cleansed`,
       ROUND(AVG(CASE WHEN pqai_flag = 1 THEN ABS(PQ_ai_amt_low - high_bid_amt) END), 2)             AS `PQ_ai Low MAE - Cleansed`,
       ROUND(AVG(CASE WHEN pqai_flag = 1
           THEN ABS(PQ_ai_amt_low - high_bid_amt) / NULLIF(ABS(high_bid_amt), 0) END), 4)            AS `PQ_ai Low MAPE - Cleansed`,
       -- PQAI Cleansed High metrics
       ROUND(AVG(CASE WHEN pqai_flag = 1 THEN PQ_ai_amt_high END), 2)                                AS `Avg PQ_ai High - Cleansed`,
       ROUND(SAFE_DIVIDE(AVG(CASE WHEN pqai_flag = 1 THEN PQ_ai_amt_high END),
                         AVG(CASE WHEN pqai_flag = 1 THEN high_bid_amt END)) - 1, 4)                 AS `PQ_ai High Mean Error Pct - Cleansed`,
       ROUND(AVG(CASE WHEN pqai_flag = 1 THEN ABS(PQ_ai_amt_high - high_bid_amt) END), 2)            AS `PQ_ai High MAE - Cleansed`,
       ROUND(AVG(CASE WHEN pqai_flag = 1
           THEN ABS(PQ_ai_amt_high - high_bid_amt) / NULLIF(ABS(high_bid_amt), 0) END), 4)           AS `PQ_ai High MAPE - Cleansed`
FROM cte3
JOIN date_periods dp ON cte3.inv_dt BETWEEN dp.start_dt AND dp.end_dt
GROUP BY 1, 2
ORDER BY
    CASE dp.period WHEN 'Past Week' THEN 1 WHEN 'Past Month' THEN 2 WHEN 'Trailing 3 Months' THEN 3 END,
    Sale_Price_Bucket;


-- PQ.ai Error Loss Type - BluCar ex-TFSS
WITH date_periods AS (
    SELECT 'Past Week' AS period,
           DATE_SUB(DATE_TRUNC(CURRENT_DATE(), WEEK(MONDAY)), INTERVAL 1 WEEK) AS start_dt,
           DATE_SUB(DATE_TRUNC(CURRENT_DATE(), WEEK(MONDAY)), INTERVAL 1 DAY) AS end_dt
    UNION ALL
    SELECT 'Past Month',
           DATE_TRUNC(DATE_SUB(CURRENT_DATE(), INTERVAL 1 MONTH), MONTH),
           DATE_SUB(DATE_TRUNC(CURRENT_DATE(), MONTH), INTERVAL 1 DAY)
    UNION ALL
    SELECT 'Trailing 3 Months',
           DATE_SUB(DATE_TRUNC(CURRENT_DATE(), WEEK(MONDAY)), INTERVAL 3 MONTH),
           CURRENT_DATE()
),
cte AS (
    SELECT lot AS lot_nbr, crt_dt AS latest_pqai, output_details_json, lids_version
    FROM (
        SELECT v.lot, v.crt_dt, v.output_details_json, v.lids_version,
               ROW_NUMBER() OVER (PARTITION BY v.lot ORDER BY v.crt_dt DESC) AS rn
        FROM `cprtpr-dataplatform-sp1`.usviews.v_us_lot_image_damage_scores_fact v
        WHERE CAST(JSON_EXTRACT(v.output_details_json,
            '$.vuequote_results.vpq_result.proquote_amount') AS NUMERIC) IS NOT NULL
    )
    WHERE rn = 1
),
cte_pq AS (
    SELECT lot_nbr, 1 AS pq_flag
    FROM `cprtpr-dataplatform-sp1`.usviews.v_us_lot_fact
    -- BluCar ex-TFSS cte_pq: loose PQ-cleansed gates (matches seller report)
    WHERE BU_hrchy_levl2 = 'BluCar'
      AND seller_parent_company <> 'TFSS'
      AND inv_dt >= '2025-01-01'
      AND lot_type_cd IN ('V')
      AND cat_id = -1
      AND acv < 100000
      --AND acv >= 1000.01
      --AND repair_cost >= 1000.01
      --AND acv <> repair_cost
      --AND high_bid_amt > 0.5 * (acv - repair_cost)
      --AND repair_cost / acv < 2
      AND proquote_amt_new IS NOT NULL
),
cte_pqai AS (
    SELECT f.lot_nbr, 1 AS pqai_flag
    FROM `cprtpr-dataplatform-sp1`.usviews.v_us_lot_fact f
    INNER JOIN cte ON f.lot_nbr = cte.lot_nbr
    -- BluCar ex-TFSS cte_pqai: all loss types (no collision-only restriction)
    WHERE f.BU_hrchy_levl2 = 'BluCar'
      AND f.seller_parent_company <> 'TFSS'
      AND f.inv_dt >= '2025-01-01'
      AND f.lot_type_cd IN ('V')
      AND f.cat_id = -1
      AND f.acv < 100000
      --AND f.loss_type_cd = 'C'
),
cte3 AS (
    SELECT
        l.lot_nbr, inv_dt, acv, high_bid_amt,
        lot_type_cd, loss_type_desc, lot_make_cd,
        CASE
            WHEN l.proquote_amt_new > 0 THEN l.proquote_amt_new
            WHEN l.proquote_amt > 0 THEN l.proquote_amt
        END AS proquote_amt_cleansed,
        CAST(JSON_EXTRACT(cte.output_details_json,
            '$.vuequote_results.vpq_result.proquote_amount') AS NUMERIC) AS PQ_ai_amt,
        CAST(JSON_EXTRACT(cte.output_details_json,
            '$.vuequote_results.vpq_result.proquote_amount_low') AS NUMERIC) AS PQ_ai_amt_low,
        CAST(JSON_EXTRACT(cte.output_details_json,
            '$.vuequote_results.vpq_result.proquote_amount_high') AS NUMERIC) AS PQ_ai_amt_high,
        cte_pq.pq_flag,
        cte_pqai.pqai_flag
    FROM `cprtpr-dataplatform-sp1`.usviews.v_us_lot_fact l
        LEFT JOIN cte ON cte.lot_nbr = l.lot_nbr
        LEFT JOIN cte_pq ON cte_pq.lot_nbr = l.lot_nbr
        LEFT JOIN cte_pqai ON cte_pqai.lot_nbr = l.lot_nbr
    WHERE BU_hrchy_levl2 = 'BluCar'
      AND seller_parent_company <> 'TFSS'
      AND inv_dt >= '2025-01-01'
)
SELECT dp.period,
       loss_type_desc AS Loss_Type_Bucket,
       COUNT(DISTINCT lot_nbr)                                                                        AS `Units Sold`,
       COUNT(DISTINCT CASE WHEN pq_flag = 1 THEN lot_nbr END)                                        AS `PQ Cleansed Units Sold`,
       COUNT(DISTINCT CASE WHEN pqai_flag = 1 THEN lot_nbr END)                                      AS `PQ_ai Cleansed Units Sold`,
       ROUND(SAFE_DIVIDE(COUNT(DISTINCT CASE WHEN pq_flag = 1 THEN lot_nbr END),
                         COUNT(DISTINCT lot_nbr)), 4)                                                 AS `% Sold with ProQuote Cleansed`,
       ROUND(SAFE_DIVIDE(COUNT(DISTINCT CASE WHEN pqai_flag = 1 THEN lot_nbr END),
                         COUNT(DISTINCT lot_nbr)), 4)                                                 AS `% Sold with ProQuote_ai Cleansed`,
       -- PQ Cleansed metrics
       ROUND(AVG(CASE WHEN pq_flag = 1 THEN high_bid_amt END), 2)                                    AS `ASP - PQ Cleansed`,
       ROUND(AVG(CASE WHEN pq_flag = 1 THEN proquote_amt_cleansed END), 2)                           AS `Avg ProQuote - Cleansed`,
       ROUND(SAFE_DIVIDE(AVG(CASE WHEN pq_flag = 1 THEN proquote_amt_cleansed END),
                         AVG(CASE WHEN pq_flag = 1 THEN high_bid_amt END)) - 1, 4)                   AS `PQ Mean Error Pct - Cleansed`,
       ROUND(AVG(CASE WHEN pq_flag = 1 THEN ABS(proquote_amt_cleansed - high_bid_amt) END), 2)       AS `PQ MAE - Cleansed`,
       ROUND(AVG(CASE WHEN pq_flag = 1
           THEN ABS(proquote_amt_cleansed - high_bid_amt) / NULLIF(ABS(high_bid_amt), 0) END), 4)    AS `PQ MAPE - Cleansed`,
       -- PQAI Cleansed metrics
       ROUND(AVG(CASE WHEN pqai_flag = 1 THEN high_bid_amt END), 2)                                  AS `ASP - PQ_ai Cleansed`,
       ROUND(AVG(CASE WHEN pqai_flag = 1 THEN PQ_ai_amt END), 2)                                     AS `Avg PQ_ai - Cleansed`,
       ROUND(SAFE_DIVIDE(AVG(CASE WHEN pqai_flag = 1 THEN PQ_ai_amt END),
                         AVG(CASE WHEN pqai_flag = 1 THEN high_bid_amt END)) - 1, 4)                 AS `PQ_ai Mean Error Pct - Cleansed`,
       ROUND(AVG(CASE WHEN pqai_flag = 1 THEN ABS(PQ_ai_amt - high_bid_amt) END), 2)                 AS `PQ_ai MAE - Cleansed`,
       ROUND(AVG(CASE WHEN pqai_flag = 1
           THEN ABS(PQ_ai_amt - high_bid_amt) / NULLIF(ABS(high_bid_amt), 0) END), 4)                AS `PQ_ai MAPE - Cleansed`,
       -- PQAI Cleansed Low metrics
       ROUND(AVG(CASE WHEN pqai_flag = 1 THEN PQ_ai_amt_low END), 2)                                 AS `Avg PQ_ai Low - Cleansed`,
       ROUND(SAFE_DIVIDE(AVG(CASE WHEN pqai_flag = 1 THEN PQ_ai_amt_low END),
                         AVG(CASE WHEN pqai_flag = 1 THEN high_bid_amt END)) - 1, 4)                 AS `PQ_ai Low Mean Error Pct - Cleansed`,
       ROUND(AVG(CASE WHEN pqai_flag = 1 THEN ABS(PQ_ai_amt_low - high_bid_amt) END), 2)             AS `PQ_ai Low MAE - Cleansed`,
       ROUND(AVG(CASE WHEN pqai_flag = 1
           THEN ABS(PQ_ai_amt_low - high_bid_amt) / NULLIF(ABS(high_bid_amt), 0) END), 4)            AS `PQ_ai Low MAPE - Cleansed`,
       -- PQAI Cleansed High metrics
       ROUND(AVG(CASE WHEN pqai_flag = 1 THEN PQ_ai_amt_high END), 2)                                AS `Avg PQ_ai High - Cleansed`,
       ROUND(SAFE_DIVIDE(AVG(CASE WHEN pqai_flag = 1 THEN PQ_ai_amt_high END),
                         AVG(CASE WHEN pqai_flag = 1 THEN high_bid_amt END)) - 1, 4)                 AS `PQ_ai High Mean Error Pct - Cleansed`,
       ROUND(AVG(CASE WHEN pqai_flag = 1 THEN ABS(PQ_ai_amt_high - high_bid_amt) END), 2)            AS `PQ_ai High MAE - Cleansed`,
       ROUND(AVG(CASE WHEN pqai_flag = 1
           THEN ABS(PQ_ai_amt_high - high_bid_amt) / NULLIF(ABS(high_bid_amt), 0) END), 4)           AS `PQ_ai High MAPE - Cleansed`
FROM cte3
JOIN date_periods dp ON cte3.inv_dt BETWEEN dp.start_dt AND dp.end_dt
GROUP BY 1, 2
ORDER BY
    CASE dp.period WHEN 'Past Week' THEN 1 WHEN 'Past Month' THEN 2 WHEN 'Trailing 3 Months' THEN 3 END,
    Loss_Type_Bucket;


-- PQ.ai Error Lot Type - BluCar ex-TFSS
WITH date_periods AS (
    SELECT 'Past Week' AS period,
           DATE_SUB(DATE_TRUNC(CURRENT_DATE(), WEEK(MONDAY)), INTERVAL 1 WEEK) AS start_dt,
           DATE_SUB(DATE_TRUNC(CURRENT_DATE(), WEEK(MONDAY)), INTERVAL 1 DAY) AS end_dt
    UNION ALL
    SELECT 'Past Month',
           DATE_TRUNC(DATE_SUB(CURRENT_DATE(), INTERVAL 1 MONTH), MONTH),
           DATE_SUB(DATE_TRUNC(CURRENT_DATE(), MONTH), INTERVAL 1 DAY)
    UNION ALL
    SELECT 'Trailing 3 Months',
           DATE_SUB(DATE_TRUNC(CURRENT_DATE(), WEEK(MONDAY)), INTERVAL 3 MONTH),
           CURRENT_DATE()
),
cte AS (
    SELECT lot AS lot_nbr, crt_dt AS latest_pqai, output_details_json, lids_version
    FROM (
        SELECT v.lot, v.crt_dt, v.output_details_json, v.lids_version,
               ROW_NUMBER() OVER (PARTITION BY v.lot ORDER BY v.crt_dt DESC) AS rn
        FROM `cprtpr-dataplatform-sp1`.usviews.v_us_lot_image_damage_scores_fact v
        WHERE CAST(JSON_EXTRACT(v.output_details_json,
            '$.vuequote_results.vpq_result.proquote_amount') AS NUMERIC) IS NOT NULL
    )
    WHERE rn = 1
),
cte_pq AS (
    SELECT lot_nbr, 1 AS pq_flag
    FROM `cprtpr-dataplatform-sp1`.usviews.v_us_lot_fact
    -- BluCar ex-TFSS cte_pq: loose PQ-cleansed gates (matches seller report)
    WHERE BU_hrchy_levl2 = 'BluCar'
      AND seller_parent_company <> 'TFSS'
      AND inv_dt >= '2025-01-01'
      AND lot_type_cd IN ('V')
      AND cat_id = -1
      AND acv < 100000
      --AND acv >= 1000.01
      --AND repair_cost >= 1000.01
      --AND acv <> repair_cost
      --AND high_bid_amt > 0.5 * (acv - repair_cost)
      --AND repair_cost / acv < 2
      AND proquote_amt_new IS NOT NULL
),
cte_pqai AS (
    SELECT f.lot_nbr, 1 AS pqai_flag
    FROM `cprtpr-dataplatform-sp1`.usviews.v_us_lot_fact f
    INNER JOIN cte ON f.lot_nbr = cte.lot_nbr
    -- BluCar ex-TFSS cte_pqai: all loss types (no collision-only restriction)
    WHERE f.BU_hrchy_levl2 = 'BluCar'
      AND f.seller_parent_company <> 'TFSS'
      AND f.inv_dt >= '2025-01-01'
      AND f.lot_type_cd IN ('V')
      AND f.cat_id = -1
      AND f.acv < 100000
      --AND f.loss_type_cd = 'C'
),
cte3 AS (
    SELECT
        l.lot_nbr, inv_dt, acv, high_bid_amt,
        lot_type_cd, loss_type_desc, lot_make_cd,
        CASE
            WHEN l.proquote_amt_new > 0 THEN l.proquote_amt_new
            WHEN l.proquote_amt > 0 THEN l.proquote_amt
        END AS proquote_amt_cleansed,
        CAST(JSON_EXTRACT(cte.output_details_json,
            '$.vuequote_results.vpq_result.proquote_amount') AS NUMERIC) AS PQ_ai_amt,
        CAST(JSON_EXTRACT(cte.output_details_json,
            '$.vuequote_results.vpq_result.proquote_amount_low') AS NUMERIC) AS PQ_ai_amt_low,
        CAST(JSON_EXTRACT(cte.output_details_json,
            '$.vuequote_results.vpq_result.proquote_amount_high') AS NUMERIC) AS PQ_ai_amt_high,
        cte_pq.pq_flag,
        cte_pqai.pqai_flag
    FROM `cprtpr-dataplatform-sp1`.usviews.v_us_lot_fact l
        LEFT JOIN cte ON cte.lot_nbr = l.lot_nbr
        LEFT JOIN cte_pq ON cte_pq.lot_nbr = l.lot_nbr
        LEFT JOIN cte_pqai ON cte_pqai.lot_nbr = l.lot_nbr
    WHERE BU_hrchy_levl2 = 'BluCar'
      AND seller_parent_company <> 'TFSS'
      AND inv_dt >= '2025-01-01'
)
SELECT dp.period,
       lot_type_cd AS Lot_Type_Bucket,
       COUNT(DISTINCT lot_nbr)                                                                        AS `Units Sold`,
       COUNT(DISTINCT CASE WHEN pq_flag = 1 THEN lot_nbr END)                                        AS `PQ Cleansed Units Sold`,
       COUNT(DISTINCT CASE WHEN pqai_flag = 1 THEN lot_nbr END)                                      AS `PQ_ai Cleansed Units Sold`,
       ROUND(SAFE_DIVIDE(COUNT(DISTINCT CASE WHEN pq_flag = 1 THEN lot_nbr END),
                         COUNT(DISTINCT lot_nbr)), 4)                                                 AS `% Sold with ProQuote Cleansed`,
       ROUND(SAFE_DIVIDE(COUNT(DISTINCT CASE WHEN pqai_flag = 1 THEN lot_nbr END),
                         COUNT(DISTINCT lot_nbr)), 4)                                                 AS `% Sold with ProQuote_ai Cleansed`,
       -- PQ Cleansed metrics
       ROUND(AVG(CASE WHEN pq_flag = 1 THEN high_bid_amt END), 2)                                    AS `ASP - PQ Cleansed`,
       ROUND(AVG(CASE WHEN pq_flag = 1 THEN proquote_amt_cleansed END), 2)                           AS `Avg ProQuote - Cleansed`,
       ROUND(SAFE_DIVIDE(AVG(CASE WHEN pq_flag = 1 THEN proquote_amt_cleansed END),
                         AVG(CASE WHEN pq_flag = 1 THEN high_bid_amt END)) - 1, 4)                   AS `PQ Mean Error Pct - Cleansed`,
       ROUND(AVG(CASE WHEN pq_flag = 1 THEN ABS(proquote_amt_cleansed - high_bid_amt) END), 2)       AS `PQ MAE - Cleansed`,
       ROUND(AVG(CASE WHEN pq_flag = 1
           THEN ABS(proquote_amt_cleansed - high_bid_amt) / NULLIF(ABS(high_bid_amt), 0) END), 4)    AS `PQ MAPE - Cleansed`,
       -- PQAI Cleansed metrics
       ROUND(AVG(CASE WHEN pqai_flag = 1 THEN high_bid_amt END), 2)                                  AS `ASP - PQ_ai Cleansed`,
       ROUND(AVG(CASE WHEN pqai_flag = 1 THEN PQ_ai_amt END), 2)                                     AS `Avg PQ_ai - Cleansed`,
       ROUND(SAFE_DIVIDE(AVG(CASE WHEN pqai_flag = 1 THEN PQ_ai_amt END),
                         AVG(CASE WHEN pqai_flag = 1 THEN high_bid_amt END)) - 1, 4)                 AS `PQ_ai Mean Error Pct - Cleansed`,
       ROUND(AVG(CASE WHEN pqai_flag = 1 THEN ABS(PQ_ai_amt - high_bid_amt) END), 2)                 AS `PQ_ai MAE - Cleansed`,
       ROUND(AVG(CASE WHEN pqai_flag = 1
           THEN ABS(PQ_ai_amt - high_bid_amt) / NULLIF(ABS(high_bid_amt), 0) END), 4)                AS `PQ_ai MAPE - Cleansed`,
       -- PQAI Cleansed Low metrics
       ROUND(AVG(CASE WHEN pqai_flag = 1 THEN PQ_ai_amt_low END), 2)                                 AS `Avg PQ_ai Low - Cleansed`,
       ROUND(SAFE_DIVIDE(AVG(CASE WHEN pqai_flag = 1 THEN PQ_ai_amt_low END),
                         AVG(CASE WHEN pqai_flag = 1 THEN high_bid_amt END)) - 1, 4)                 AS `PQ_ai Low Mean Error Pct - Cleansed`,
       ROUND(AVG(CASE WHEN pqai_flag = 1 THEN ABS(PQ_ai_amt_low - high_bid_amt) END), 2)             AS `PQ_ai Low MAE - Cleansed`,
       ROUND(AVG(CASE WHEN pqai_flag = 1
           THEN ABS(PQ_ai_amt_low - high_bid_amt) / NULLIF(ABS(high_bid_amt), 0) END), 4)            AS `PQ_ai Low MAPE - Cleansed`,
       -- PQAI Cleansed High metrics
       ROUND(AVG(CASE WHEN pqai_flag = 1 THEN PQ_ai_amt_high END), 2)                                AS `Avg PQ_ai High - Cleansed`,
       ROUND(SAFE_DIVIDE(AVG(CASE WHEN pqai_flag = 1 THEN PQ_ai_amt_high END),
                         AVG(CASE WHEN pqai_flag = 1 THEN high_bid_amt END)) - 1, 4)                 AS `PQ_ai High Mean Error Pct - Cleansed`,
       ROUND(AVG(CASE WHEN pqai_flag = 1 THEN ABS(PQ_ai_amt_high - high_bid_amt) END), 2)            AS `PQ_ai High MAE - Cleansed`,
       ROUND(AVG(CASE WHEN pqai_flag = 1
           THEN ABS(PQ_ai_amt_high - high_bid_amt) / NULLIF(ABS(high_bid_amt), 0) END), 4)           AS `PQ_ai High MAPE - Cleansed`
FROM cte3
JOIN date_periods dp ON cte3.inv_dt BETWEEN dp.start_dt AND dp.end_dt
GROUP BY 1, 2
ORDER BY
    CASE dp.period WHEN 'Past Week' THEN 1 WHEN 'Past Month' THEN 2 WHEN 'Trailing 3 Months' THEN 3 END,
    Lot_Type_Bucket;


-- PQ.ai Error AutoGrade Bucket - BluCar ex-TFSS
WITH date_periods AS (
    SELECT 'Past Week' AS period,
           DATE_SUB(DATE_TRUNC(CURRENT_DATE(), WEEK(MONDAY)), INTERVAL 1 WEEK) AS start_dt,
           DATE_SUB(DATE_TRUNC(CURRENT_DATE(), WEEK(MONDAY)), INTERVAL 1 DAY) AS end_dt
    UNION ALL
    SELECT 'Past Month',
           DATE_TRUNC(DATE_SUB(CURRENT_DATE(), INTERVAL 1 MONTH), MONTH),
           DATE_SUB(DATE_TRUNC(CURRENT_DATE(), MONTH), INTERVAL 1 DAY)
    UNION ALL
    SELECT 'Trailing 3 Months',
           DATE_SUB(DATE_TRUNC(CURRENT_DATE(), WEEK(MONDAY)), INTERVAL 3 MONTH),
           CURRENT_DATE()
),
cte AS (
    SELECT lot AS lot_nbr, crt_dt AS latest_pqai, output_details_json, lids_version
    FROM (
        SELECT v.lot, v.crt_dt, v.output_details_json, v.lids_version,
               ROW_NUMBER() OVER (PARTITION BY v.lot ORDER BY v.crt_dt DESC) AS rn
        FROM `cprtpr-dataplatform-sp1`.usviews.v_us_lot_image_damage_scores_fact v
        WHERE CAST(JSON_EXTRACT(v.output_details_json,
            '$.vuequote_results.vpq_result.proquote_amount') AS NUMERIC) IS NOT NULL
    )
    WHERE rn = 1
),
cte_pq AS (
    SELECT lot_nbr, 1 AS pq_flag
    FROM `cprtpr-dataplatform-sp1`.usviews.v_us_lot_fact
    -- BluCar ex-TFSS cte_pq: loose PQ-cleansed gates (matches seller report)
    WHERE BU_hrchy_levl2 = 'BluCar'
      AND seller_parent_company <> 'TFSS'
      AND inv_dt >= '2025-01-01'
      AND lot_type_cd IN ('V')
      AND cat_id = -1
      AND acv < 100000
      --AND acv >= 1000.01
      --AND repair_cost >= 1000.01
      --AND acv <> repair_cost
      --AND high_bid_amt > 0.5 * (acv - repair_cost)
      --AND repair_cost / acv < 2
      AND proquote_amt_new IS NOT NULL
),
cte_pqai AS (
    SELECT f.lot_nbr, 1 AS pqai_flag
    FROM `cprtpr-dataplatform-sp1`.usviews.v_us_lot_fact f
    INNER JOIN cte ON f.lot_nbr = cte.lot_nbr
    -- BluCar ex-TFSS cte_pqai: all loss types (no collision-only restriction)
    WHERE f.BU_hrchy_levl2 = 'BluCar'
      AND f.seller_parent_company <> 'TFSS'
      AND f.inv_dt >= '2025-01-01'
      AND f.lot_type_cd IN ('V')
      AND f.cat_id = -1
      AND f.acv < 100000
      --AND f.loss_type_cd = 'C'
),
cte3 AS (
    SELECT
        l.lot_nbr, inv_dt, acv, high_bid_amt,
        lot_type_cd, loss_type_desc, auto_grade_orig,
        CASE
            WHEN l.proquote_amt_new > 0 THEN l.proquote_amt_new
            WHEN l.proquote_amt > 0 THEN l.proquote_amt
        END AS proquote_amt_cleansed,
        CAST(JSON_EXTRACT(cte.output_details_json,
            '$.vuequote_results.vpq_result.proquote_amount') AS NUMERIC) AS PQ_ai_amt,
        CAST(JSON_EXTRACT(cte.output_details_json,
            '$.vuequote_results.vpq_result.proquote_amount_low') AS NUMERIC) AS PQ_ai_amt_low,
        CAST(JSON_EXTRACT(cte.output_details_json,
            '$.vuequote_results.vpq_result.proquote_amount_high') AS NUMERIC) AS PQ_ai_amt_high,
        cte_pq.pq_flag,
        cte_pqai.pqai_flag
    FROM `cprtpr-dataplatform-sp1`.usviews.v_us_lot_fact l
        LEFT JOIN cte ON cte.lot_nbr = l.lot_nbr
        LEFT JOIN cte_pq ON cte_pq.lot_nbr = l.lot_nbr
        LEFT JOIN cte_pqai ON cte_pqai.lot_nbr = l.lot_nbr
    WHERE BU_hrchy_levl2 = 'BluCar'
      AND seller_parent_company <> 'TFSS'
      AND inv_dt >= '2025-01-01'
)
SELECT dp.period,
       CASE
           WHEN auto_grade_orig IS NULL THEN 'Blank'
           WHEN auto_grade_orig < 1 THEN '0 - 0.9'
           WHEN auto_grade_orig < 2 THEN '1 - 1.9'
           WHEN auto_grade_orig < 3 THEN '2 - 2.9'
           WHEN auto_grade_orig < 4 THEN '3 - 3.9'
           ELSE '4 - 5'
       END AS AutoGrade_Bucket,
       COUNT(DISTINCT lot_nbr)                                                                        AS `Units Sold`,
       COUNT(DISTINCT CASE WHEN pq_flag = 1 THEN lot_nbr END)                                        AS `PQ Cleansed Units Sold`,
       COUNT(DISTINCT CASE WHEN pqai_flag = 1 THEN lot_nbr END)                                      AS `PQ_ai Cleansed Units Sold`,
       ROUND(SAFE_DIVIDE(COUNT(DISTINCT CASE WHEN pq_flag = 1 THEN lot_nbr END),
                         COUNT(DISTINCT lot_nbr)), 4)                                                 AS `% Sold with ProQuote Cleansed`,
       ROUND(SAFE_DIVIDE(COUNT(DISTINCT CASE WHEN pqai_flag = 1 THEN lot_nbr END),
                         COUNT(DISTINCT lot_nbr)), 4)                                                 AS `% Sold with ProQuote_ai Cleansed`,
       -- PQ Cleansed metrics
       ROUND(AVG(CASE WHEN pq_flag = 1 THEN high_bid_amt END), 2)                                    AS `ASP - PQ Cleansed`,
       ROUND(AVG(CASE WHEN pq_flag = 1 THEN proquote_amt_cleansed END), 2)                           AS `Avg ProQuote - Cleansed`,
       ROUND(SAFE_DIVIDE(AVG(CASE WHEN pq_flag = 1 THEN proquote_amt_cleansed END),
                         AVG(CASE WHEN pq_flag = 1 THEN high_bid_amt END)) - 1, 4)                   AS `PQ Mean Error Pct - Cleansed`,
       ROUND(AVG(CASE WHEN pq_flag = 1 THEN ABS(proquote_amt_cleansed - high_bid_amt) END), 2)       AS `PQ MAE - Cleansed`,
       ROUND(AVG(CASE WHEN pq_flag = 1
           THEN ABS(proquote_amt_cleansed - high_bid_amt) / NULLIF(ABS(high_bid_amt), 0) END), 4)    AS `PQ MAPE - Cleansed`,
       -- PQAI Cleansed metrics
       ROUND(AVG(CASE WHEN pqai_flag = 1 THEN high_bid_amt END), 2)                                  AS `ASP - PQ_ai Cleansed`,
       ROUND(AVG(CASE WHEN pqai_flag = 1 THEN PQ_ai_amt END), 2)                                     AS `Avg PQ_ai - Cleansed`,
       ROUND(SAFE_DIVIDE(AVG(CASE WHEN pqai_flag = 1 THEN PQ_ai_amt END),
                         AVG(CASE WHEN pqai_flag = 1 THEN high_bid_amt END)) - 1, 4)                 AS `PQ_ai Mean Error Pct - Cleansed`,
       ROUND(AVG(CASE WHEN pqai_flag = 1 THEN ABS(PQ_ai_amt - high_bid_amt) END), 2)                 AS `PQ_ai MAE - Cleansed`,
       ROUND(AVG(CASE WHEN pqai_flag = 1
           THEN ABS(PQ_ai_amt - high_bid_amt) / NULLIF(ABS(high_bid_amt), 0) END), 4)                AS `PQ_ai MAPE - Cleansed`,
       -- PQAI Cleansed Low metrics
       ROUND(AVG(CASE WHEN pqai_flag = 1 THEN PQ_ai_amt_low END), 2)                                 AS `Avg PQ_ai Low - Cleansed`,
       ROUND(SAFE_DIVIDE(AVG(CASE WHEN pqai_flag = 1 THEN PQ_ai_amt_low END),
                         AVG(CASE WHEN pqai_flag = 1 THEN high_bid_amt END)) - 1, 4)                 AS `PQ_ai Low Mean Error Pct - Cleansed`,
       ROUND(AVG(CASE WHEN pqai_flag = 1 THEN ABS(PQ_ai_amt_low - high_bid_amt) END), 2)             AS `PQ_ai Low MAE - Cleansed`,
       ROUND(AVG(CASE WHEN pqai_flag = 1
           THEN ABS(PQ_ai_amt_low - high_bid_amt) / NULLIF(ABS(high_bid_amt), 0) END), 4)            AS `PQ_ai Low MAPE - Cleansed`,
       -- PQAI Cleansed High metrics
       ROUND(AVG(CASE WHEN pqai_flag = 1 THEN PQ_ai_amt_high END), 2)                                AS `Avg PQ_ai High - Cleansed`,
       ROUND(SAFE_DIVIDE(AVG(CASE WHEN pqai_flag = 1 THEN PQ_ai_amt_high END),
                         AVG(CASE WHEN pqai_flag = 1 THEN high_bid_amt END)) - 1, 4)                 AS `PQ_ai High Mean Error Pct - Cleansed`,
       ROUND(AVG(CASE WHEN pqai_flag = 1 THEN ABS(PQ_ai_amt_high - high_bid_amt) END), 2)            AS `PQ_ai High MAE - Cleansed`,
       ROUND(AVG(CASE WHEN pqai_flag = 1
           THEN ABS(PQ_ai_amt_high - high_bid_amt) / NULLIF(ABS(high_bid_amt), 0) END), 4)           AS `PQ_ai High MAPE - Cleansed`
FROM cte3
JOIN date_periods dp ON cte3.inv_dt BETWEEN dp.start_dt AND dp.end_dt
GROUP BY 1, 2
ORDER BY
    CASE dp.period WHEN 'Past Week' THEN 1 WHEN 'Past Month' THEN 2 WHEN 'Trailing 3 Months' THEN 3 END,
    CASE AutoGrade_Bucket
        WHEN '0 - 0.9' THEN 1
        WHEN '1 - 1.9' THEN 2
        WHEN '2 - 2.9' THEN 3
        WHEN '3 - 3.9' THEN 4
        WHEN '4 - 5'   THEN 5
        WHEN 'Blank'   THEN 6
    END;


-- PQ.ai Error Title Type - BluCar ex-TFSS
WITH date_periods AS (
    SELECT 'Past Week' AS period,
           DATE_SUB(DATE_TRUNC(CURRENT_DATE(), WEEK(MONDAY)), INTERVAL 1 WEEK) AS start_dt,
           DATE_SUB(DATE_TRUNC(CURRENT_DATE(), WEEK(MONDAY)), INTERVAL 1 DAY) AS end_dt
    UNION ALL
    SELECT 'Past Month',
           DATE_TRUNC(DATE_SUB(CURRENT_DATE(), INTERVAL 1 MONTH), MONTH),
           DATE_SUB(DATE_TRUNC(CURRENT_DATE(), MONTH), INTERVAL 1 DAY)
    UNION ALL
    SELECT 'Trailing 3 Months',
           DATE_SUB(DATE_TRUNC(CURRENT_DATE(), WEEK(MONDAY)), INTERVAL 3 MONTH),
           CURRENT_DATE()
),
cte AS (
    SELECT lot AS lot_nbr, crt_dt AS latest_pqai, output_details_json, lids_version
    FROM (
        SELECT v.lot, v.crt_dt, v.output_details_json, v.lids_version,
               ROW_NUMBER() OVER (PARTITION BY v.lot ORDER BY v.crt_dt DESC) AS rn
        FROM `cprtpr-dataplatform-sp1`.usviews.v_us_lot_image_damage_scores_fact v
        WHERE CAST(JSON_EXTRACT(v.output_details_json,
            '$.vuequote_results.vpq_result.proquote_amount') AS NUMERIC) IS NOT NULL
    )
    WHERE rn = 1
),
cte_pq AS (
    SELECT lot_nbr, 1 AS pq_flag
    FROM `cprtpr-dataplatform-sp1`.usviews.v_us_lot_fact
    -- BluCar ex-TFSS cte_pq: loose PQ-cleansed gates (matches seller report)
    WHERE BU_hrchy_levl2 = 'BluCar'
      AND seller_parent_company <> 'TFSS'
      AND inv_dt >= '2025-01-01'
      AND lot_type_cd IN ('V')
      AND cat_id = -1
      AND acv < 100000
      --AND acv >= 1000.01
      --AND repair_cost >= 1000.01
      --AND acv <> repair_cost
      --AND high_bid_amt > 0.5 * (acv - repair_cost)
      --AND repair_cost / acv < 2
      AND proquote_amt_new IS NOT NULL
),
cte_pqai AS (
    SELECT f.lot_nbr, 1 AS pqai_flag
    FROM `cprtpr-dataplatform-sp1`.usviews.v_us_lot_fact f
    INNER JOIN cte ON f.lot_nbr = cte.lot_nbr
    -- BluCar ex-TFSS cte_pqai: all loss types (no collision-only restriction)
    WHERE f.BU_hrchy_levl2 = 'BluCar'
      AND f.seller_parent_company <> 'TFSS'
      AND f.inv_dt >= '2025-01-01'
      AND f.lot_type_cd IN ('V')
      AND f.cat_id = -1
      AND f.acv < 100000
      --AND f.loss_type_cd = 'C'
),
cte3 AS (
    SELECT
        l.lot_nbr, inv_dt, acv, high_bid_amt,
        lot_type_cd, loss_type_desc, lot_make_cd,
        l.sales_title_grp_long_desc,
        CASE
            WHEN l.proquote_amt_new > 0 THEN l.proquote_amt_new
            WHEN l.proquote_amt > 0 THEN l.proquote_amt
        END AS proquote_amt_cleansed,
        CAST(JSON_EXTRACT(cte.output_details_json,
            '$.vuequote_results.vpq_result.proquote_amount') AS NUMERIC) AS PQ_ai_amt,
        CAST(JSON_EXTRACT(cte.output_details_json,
            '$.vuequote_results.vpq_result.proquote_amount_low') AS NUMERIC) AS PQ_ai_amt_low,
        CAST(JSON_EXTRACT(cte.output_details_json,
            '$.vuequote_results.vpq_result.proquote_amount_high') AS NUMERIC) AS PQ_ai_amt_high,
        cte_pq.pq_flag,
        cte_pqai.pqai_flag
    FROM `cprtpr-dataplatform-sp1`.usviews.v_us_lot_fact l
        LEFT JOIN cte ON cte.lot_nbr = l.lot_nbr
        LEFT JOIN cte_pq ON cte_pq.lot_nbr = l.lot_nbr
        LEFT JOIN cte_pqai ON cte_pqai.lot_nbr = l.lot_nbr
    WHERE BU_hrchy_levl2 = 'BluCar'
      AND seller_parent_company <> 'TFSS'
      AND inv_dt >= '2025-01-01'
)
SELECT dp.period,
       sales_title_grp_long_desc AS Title_Type_Bucket,
       COUNT(DISTINCT lot_nbr)                                                                        AS `Units Sold`,
       COUNT(DISTINCT CASE WHEN pq_flag = 1 THEN lot_nbr END)                                        AS `PQ Cleansed Units Sold`,
       COUNT(DISTINCT CASE WHEN pqai_flag = 1 THEN lot_nbr END)                                      AS `PQ_ai Cleansed Units Sold`,
       ROUND(SAFE_DIVIDE(COUNT(DISTINCT CASE WHEN pq_flag = 1 THEN lot_nbr END),
                         COUNT(DISTINCT lot_nbr)), 4)                                                 AS `% Sold with ProQuote Cleansed`,
       ROUND(SAFE_DIVIDE(COUNT(DISTINCT CASE WHEN pqai_flag = 1 THEN lot_nbr END),
                         COUNT(DISTINCT lot_nbr)), 4)                                                 AS `% Sold with ProQuote_ai Cleansed`,
       -- PQ Cleansed metrics
       ROUND(AVG(CASE WHEN pq_flag = 1 THEN high_bid_amt END), 2)                                    AS `ASP - PQ Cleansed`,
       ROUND(AVG(CASE WHEN pq_flag = 1 THEN proquote_amt_cleansed END), 2)                           AS `Avg ProQuote - Cleansed`,
       ROUND(SAFE_DIVIDE(AVG(CASE WHEN pq_flag = 1 THEN proquote_amt_cleansed END),
                         AVG(CASE WHEN pq_flag = 1 THEN high_bid_amt END)) - 1, 4)                   AS `PQ Mean Error Pct - Cleansed`,
       ROUND(AVG(CASE WHEN pq_flag = 1 THEN ABS(proquote_amt_cleansed - high_bid_amt) END), 2)       AS `PQ MAE - Cleansed`,
       ROUND(AVG(CASE WHEN pq_flag = 1
           THEN ABS(proquote_amt_cleansed - high_bid_amt) / NULLIF(ABS(high_bid_amt), 0) END), 4)    AS `PQ MAPE - Cleansed`,
       -- PQAI Cleansed metrics
       ROUND(AVG(CASE WHEN pqai_flag = 1 THEN high_bid_amt END), 2)                                  AS `ASP - PQ_ai Cleansed`,
       ROUND(AVG(CASE WHEN pqai_flag = 1 THEN PQ_ai_amt END), 2)                                     AS `Avg PQ_ai - Cleansed`,
       ROUND(SAFE_DIVIDE(AVG(CASE WHEN pqai_flag = 1 THEN PQ_ai_amt END),
                         AVG(CASE WHEN pqai_flag = 1 THEN high_bid_amt END)) - 1, 4)                 AS `PQ_ai Mean Error Pct - Cleansed`,
       ROUND(AVG(CASE WHEN pqai_flag = 1 THEN ABS(PQ_ai_amt - high_bid_amt) END), 2)                 AS `PQ_ai MAE - Cleansed`,
       ROUND(AVG(CASE WHEN pqai_flag = 1
           THEN ABS(PQ_ai_amt - high_bid_amt) / NULLIF(ABS(high_bid_amt), 0) END), 4)                AS `PQ_ai MAPE - Cleansed`,
       -- PQAI Cleansed Low metrics
       ROUND(AVG(CASE WHEN pqai_flag = 1 THEN PQ_ai_amt_low END), 2)                                 AS `Avg PQ_ai Low - Cleansed`,
       ROUND(SAFE_DIVIDE(AVG(CASE WHEN pqai_flag = 1 THEN PQ_ai_amt_low END),
                         AVG(CASE WHEN pqai_flag = 1 THEN high_bid_amt END)) - 1, 4)                 AS `PQ_ai Low Mean Error Pct - Cleansed`,
       ROUND(AVG(CASE WHEN pqai_flag = 1 THEN ABS(PQ_ai_amt_low - high_bid_amt) END), 2)             AS `PQ_ai Low MAE - Cleansed`,
       ROUND(AVG(CASE WHEN pqai_flag = 1
           THEN ABS(PQ_ai_amt_low - high_bid_amt) / NULLIF(ABS(high_bid_amt), 0) END), 4)            AS `PQ_ai Low MAPE - Cleansed`,
       -- PQAI Cleansed High metrics
       ROUND(AVG(CASE WHEN pqai_flag = 1 THEN PQ_ai_amt_high END), 2)                                AS `Avg PQ_ai High - Cleansed`,
       ROUND(SAFE_DIVIDE(AVG(CASE WHEN pqai_flag = 1 THEN PQ_ai_amt_high END),
                         AVG(CASE WHEN pqai_flag = 1 THEN high_bid_amt END)) - 1, 4)                 AS `PQ_ai High Mean Error Pct - Cleansed`,
       ROUND(AVG(CASE WHEN pqai_flag = 1 THEN ABS(PQ_ai_amt_high - high_bid_amt) END), 2)            AS `PQ_ai High MAE - Cleansed`,
       ROUND(AVG(CASE WHEN pqai_flag = 1
           THEN ABS(PQ_ai_amt_high - high_bid_amt) / NULLIF(ABS(high_bid_amt), 0) END), 4)           AS `PQ_ai High MAPE - Cleansed`
FROM cte3
JOIN date_periods dp ON cte3.inv_dt BETWEEN dp.start_dt AND dp.end_dt
GROUP BY 1, 2
ORDER BY
    CASE dp.period WHEN 'Past Week' THEN 1 WHEN 'Past Month' THEN 2 WHEN 'Trailing 3 Months' THEN 3 END,
    Title_Type_Bucket;


-- =====================================================================
-- Insurance + TFSS (Sheet 3)
-- =====================================================================
-- PQ.ai Error ACV Bucket View - Insurance + TFSS
WITH date_periods AS (
    SELECT 'Past Week' AS period,
           DATE_SUB(DATE_TRUNC(CURRENT_DATE(), WEEK(MONDAY)), INTERVAL 1 WEEK) AS start_dt,
           DATE_SUB(DATE_TRUNC(CURRENT_DATE(), WEEK(MONDAY)), INTERVAL 1 DAY) AS end_dt
    UNION ALL
    SELECT 'Past Month',
           DATE_TRUNC(DATE_SUB(CURRENT_DATE(), INTERVAL 1 MONTH), MONTH),
           DATE_SUB(DATE_TRUNC(CURRENT_DATE(), MONTH), INTERVAL 1 DAY)
    UNION ALL
    SELECT 'Trailing 3 Months',
           DATE_SUB(DATE_TRUNC(CURRENT_DATE(), WEEK(MONDAY)), INTERVAL 3 MONTH),
           CURRENT_DATE()
),
cte AS (
    SELECT lot AS lot_nbr, crt_dt AS latest_pqai, output_details_json, lids_version
    FROM (
        SELECT v.lot, v.crt_dt, v.output_details_json, v.lids_version,
               ROW_NUMBER() OVER (PARTITION BY v.lot ORDER BY v.crt_dt DESC) AS rn
        FROM `cprtpr-dataplatform-sp1`.usviews.v_us_lot_image_damage_scores_fact v
        WHERE CAST(JSON_EXTRACT(v.output_details_json,
            '$.vuequote_results.vpq_result.proquote_amount') AS NUMERIC) IS NOT NULL
    )
    WHERE rn = 1
),
cte_pq AS (
    SELECT lot_nbr, 1 AS pq_flag
    FROM `cprtpr-dataplatform-sp1`.usviews.v_us_lot_fact
    WHERE (BU_hrchy_levl2 = 'Insurance' OR seller_parent_company = 'TFSS')
      AND inv_dt >= '2025-01-01'
      AND lot_type_cd IN ('V')
      AND cat_id = -1
      AND acv < 100000
      AND acv >= 1000.01
      AND repair_cost >= 1000.01
      AND acv <> repair_cost
      AND high_bid_amt > 0.5 * (acv - repair_cost)
      AND repair_cost / acv < 2
      AND proquote_amt_new IS NOT NULL
),
cte_pqai AS (
    SELECT f.lot_nbr, 1 AS pqai_flag
    FROM `cprtpr-dataplatform-sp1`.usviews.v_us_lot_fact f
    INNER JOIN cte ON f.lot_nbr = cte.lot_nbr
    WHERE (f.BU_hrchy_levl2 = 'Insurance' OR f.seller_parent_company = 'TFSS')
      AND f.inv_dt >= '2025-01-01'
      AND f.lot_type_cd IN ('V')
      AND f.cat_id = -1
      AND f.acv < 100000
      AND f.loss_type_cd = 'C'
),
cte3 AS (
    SELECT
        l.lot_nbr, inv_dt, acv, high_bid_amt,
        lot_type_cd, loss_type_desc, lot_make_cd,
        CASE
            WHEN l.proquote_amt_new > 0 THEN l.proquote_amt_new
            WHEN l.proquote_amt > 0 THEN l.proquote_amt
        END AS proquote_amt_cleansed,
        CAST(JSON_EXTRACT(cte.output_details_json,
            '$.vuequote_results.vpq_result.proquote_amount') AS NUMERIC) AS PQ_ai_amt,
        CAST(JSON_EXTRACT(cte.output_details_json,
            '$.vuequote_results.vpq_result.proquote_amount_low') AS NUMERIC) AS PQ_ai_amt_low,
        CAST(JSON_EXTRACT(cte.output_details_json,
            '$.vuequote_results.vpq_result.proquote_amount_high') AS NUMERIC) AS PQ_ai_amt_high,
        cte_pq.pq_flag,
        cte_pqai.pqai_flag
    FROM `cprtpr-dataplatform-sp1`.usviews.v_us_lot_fact l
        LEFT JOIN cte ON cte.lot_nbr = l.lot_nbr
        LEFT JOIN cte_pq ON cte_pq.lot_nbr = l.lot_nbr
        LEFT JOIN cte_pqai ON cte_pqai.lot_nbr = l.lot_nbr
    WHERE (BU_hrchy_levl2 = 'Insurance' OR seller_parent_company = 'TFSS')
      AND inv_dt >= '2025-01-01'
)
SELECT dp.period,
       CASE
           WHEN acv < 5000 THEN 'a. Less than 5k'
           WHEN acv >= 5000 AND acv < 10000 THEN 'b. 5-10k'
           WHEN acv >= 10000 AND acv < 15000 THEN 'c. 10-15k'
           WHEN acv >= 15000 AND acv < 20000 THEN 'd. 15-20k'
           WHEN acv >= 20000 AND acv < 30000 THEN 'e. 20-30k'
           WHEN acv >= 30000 AND acv < 40000 THEN 'f. 30-40k'
           WHEN acv >= 40000 AND acv < 50000 THEN 'g. 40-50k'
           ELSE 'h. 50k+'
       END AS ACV_Bucket,
       COUNT(DISTINCT lot_nbr)                                                                        AS `Units Sold`,
       COUNT(DISTINCT CASE WHEN pq_flag = 1 THEN lot_nbr END)                                        AS `PQ Cleansed Units Sold`,
       COUNT(DISTINCT CASE WHEN pqai_flag = 1 THEN lot_nbr END)                                      AS `PQ_ai Cleansed Units Sold`,
       ROUND(SAFE_DIVIDE(COUNT(DISTINCT CASE WHEN pq_flag = 1 THEN lot_nbr END),
                         COUNT(DISTINCT lot_nbr)), 4)                                                 AS `% Sold with ProQuote Cleansed`,
       ROUND(SAFE_DIVIDE(COUNT(DISTINCT CASE WHEN pqai_flag = 1 THEN lot_nbr END),
                         COUNT(DISTINCT lot_nbr)), 4)                                                 AS `% Sold with ProQuote_ai Cleansed`,
       -- PQ Cleansed metrics
       ROUND(AVG(CASE WHEN pq_flag = 1 THEN high_bid_amt END), 2)                                    AS `ASP - PQ Cleansed`,
       ROUND(AVG(CASE WHEN pq_flag = 1 THEN proquote_amt_cleansed END), 2)                           AS `Avg ProQuote - Cleansed`,
       ROUND(SAFE_DIVIDE(AVG(CASE WHEN pq_flag = 1 THEN proquote_amt_cleansed END),
                         AVG(CASE WHEN pq_flag = 1 THEN high_bid_amt END)) - 1, 4)                   AS `PQ Mean Error Pct - Cleansed`,
       ROUND(AVG(CASE WHEN pq_flag = 1 THEN ABS(proquote_amt_cleansed - high_bid_amt) END), 2)       AS `PQ MAE - Cleansed`,
       ROUND(AVG(CASE WHEN pq_flag = 1
           THEN ABS(proquote_amt_cleansed - high_bid_amt) / NULLIF(ABS(high_bid_amt), 0) END), 4)    AS `PQ MAPE - Cleansed`,
       -- PQAI Cleansed metrics
       ROUND(AVG(CASE WHEN pqai_flag = 1 THEN high_bid_amt END), 2)                                  AS `ASP - PQ_ai Cleansed`,
       ROUND(AVG(CASE WHEN pqai_flag = 1 THEN PQ_ai_amt END), 2)                                     AS `Avg PQ_ai - Cleansed`,
       ROUND(SAFE_DIVIDE(AVG(CASE WHEN pqai_flag = 1 THEN PQ_ai_amt END),
                         AVG(CASE WHEN pqai_flag = 1 THEN high_bid_amt END)) - 1, 4)                 AS `PQ_ai Mean Error Pct - Cleansed`,
       ROUND(AVG(CASE WHEN pqai_flag = 1 THEN ABS(PQ_ai_amt - high_bid_amt) END), 2)                 AS `PQ_ai MAE - Cleansed`,
       ROUND(AVG(CASE WHEN pqai_flag = 1
           THEN ABS(PQ_ai_amt - high_bid_amt) / NULLIF(ABS(high_bid_amt), 0) END), 4)                AS `PQ_ai MAPE - Cleansed`,
       -- PQAI Cleansed Low metrics
       ROUND(AVG(CASE WHEN pqai_flag = 1 THEN PQ_ai_amt_low END), 2)                                 AS `Avg PQ_ai Low - Cleansed`,
       ROUND(SAFE_DIVIDE(AVG(CASE WHEN pqai_flag = 1 THEN PQ_ai_amt_low END),
                         AVG(CASE WHEN pqai_flag = 1 THEN high_bid_amt END)) - 1, 4)                 AS `PQ_ai Low Mean Error Pct - Cleansed`,
       ROUND(AVG(CASE WHEN pqai_flag = 1 THEN ABS(PQ_ai_amt_low - high_bid_amt) END), 2)             AS `PQ_ai Low MAE - Cleansed`,
       ROUND(AVG(CASE WHEN pqai_flag = 1
           THEN ABS(PQ_ai_amt_low - high_bid_amt) / NULLIF(ABS(high_bid_amt), 0) END), 4)            AS `PQ_ai Low MAPE - Cleansed`,
       -- PQAI Cleansed High metrics
       ROUND(AVG(CASE WHEN pqai_flag = 1 THEN PQ_ai_amt_high END), 2)                                AS `Avg PQ_ai High - Cleansed`,
       ROUND(SAFE_DIVIDE(AVG(CASE WHEN pqai_flag = 1 THEN PQ_ai_amt_high END),
                         AVG(CASE WHEN pqai_flag = 1 THEN high_bid_amt END)) - 1, 4)                 AS `PQ_ai High Mean Error Pct - Cleansed`,
       ROUND(AVG(CASE WHEN pqai_flag = 1 THEN ABS(PQ_ai_amt_high - high_bid_amt) END), 2)            AS `PQ_ai High MAE - Cleansed`,
       ROUND(AVG(CASE WHEN pqai_flag = 1
           THEN ABS(PQ_ai_amt_high - high_bid_amt) / NULLIF(ABS(high_bid_amt), 0) END), 4)           AS `PQ_ai High MAPE - Cleansed`
FROM cte3
JOIN date_periods dp ON cte3.inv_dt BETWEEN dp.start_dt AND dp.end_dt
GROUP BY 1, 2
ORDER BY
    CASE dp.period WHEN 'Past Week' THEN 1 WHEN 'Past Month' THEN 2 WHEN 'Trailing 3 Months' THEN 3 END,
    ACV_Bucket;


-- PQ.ai Error Sale Price Bucket View - Insurance + TFSS
WITH date_periods AS (
    SELECT 'Past Week' AS period,
           DATE_SUB(DATE_TRUNC(CURRENT_DATE(), WEEK(MONDAY)), INTERVAL 1 WEEK) AS start_dt,
           DATE_SUB(DATE_TRUNC(CURRENT_DATE(), WEEK(MONDAY)), INTERVAL 1 DAY) AS end_dt
    UNION ALL
    SELECT 'Past Month',
           DATE_TRUNC(DATE_SUB(CURRENT_DATE(), INTERVAL 1 MONTH), MONTH),
           DATE_SUB(DATE_TRUNC(CURRENT_DATE(), MONTH), INTERVAL 1 DAY)
    UNION ALL
    SELECT 'Trailing 3 Months',
           DATE_SUB(DATE_TRUNC(CURRENT_DATE(), WEEK(MONDAY)), INTERVAL 3 MONTH),
           CURRENT_DATE()
),
cte AS (
    SELECT lot AS lot_nbr, crt_dt AS latest_pqai, output_details_json, lids_version
    FROM (
        SELECT v.lot, v.crt_dt, v.output_details_json, v.lids_version,
               ROW_NUMBER() OVER (PARTITION BY v.lot ORDER BY v.crt_dt DESC) AS rn
        FROM `cprtpr-dataplatform-sp1`.usviews.v_us_lot_image_damage_scores_fact v
        WHERE CAST(JSON_EXTRACT(v.output_details_json,
            '$.vuequote_results.vpq_result.proquote_amount') AS NUMERIC) IS NOT NULL
    )
    WHERE rn = 1
),
cte_pq AS (
    SELECT lot_nbr, 1 AS pq_flag
    FROM `cprtpr-dataplatform-sp1`.usviews.v_us_lot_fact
    WHERE (BU_hrchy_levl2 = 'Insurance' OR seller_parent_company = 'TFSS')
      AND inv_dt >= '2025-01-01'
      AND lot_type_cd IN ('V')
      AND cat_id = -1
      AND acv < 100000
      AND acv >= 1000.01
      AND repair_cost >= 1000.01
      AND acv <> repair_cost
      AND high_bid_amt > 0.5 * (acv - repair_cost)
      AND repair_cost / acv < 2
      AND proquote_amt_new IS NOT NULL
),
cte_pqai AS (
    SELECT f.lot_nbr, 1 AS pqai_flag
    FROM `cprtpr-dataplatform-sp1`.usviews.v_us_lot_fact f
    INNER JOIN cte ON f.lot_nbr = cte.lot_nbr
    WHERE (f.BU_hrchy_levl2 = 'Insurance' OR f.seller_parent_company = 'TFSS')
      AND f.inv_dt >= '2025-01-01'
      AND f.lot_type_cd IN ('V')
      AND f.cat_id = -1
      AND f.acv < 100000
      AND f.loss_type_cd = 'C'
),
cte3 AS (
    SELECT
        l.lot_nbr, inv_dt, acv, high_bid_amt,
        lot_type_cd, loss_type_desc, lot_make_cd,
        CASE
            WHEN l.proquote_amt_new > 0 THEN l.proquote_amt_new
            WHEN l.proquote_amt > 0 THEN l.proquote_amt
        END AS proquote_amt_cleansed,
        CAST(JSON_EXTRACT(cte.output_details_json,
            '$.vuequote_results.vpq_result.proquote_amount') AS NUMERIC) AS PQ_ai_amt,
        CAST(JSON_EXTRACT(cte.output_details_json,
            '$.vuequote_results.vpq_result.proquote_amount_low') AS NUMERIC) AS PQ_ai_amt_low,
        CAST(JSON_EXTRACT(cte.output_details_json,
            '$.vuequote_results.vpq_result.proquote_amount_high') AS NUMERIC) AS PQ_ai_amt_high,
        cte_pq.pq_flag,
        cte_pqai.pqai_flag
    FROM `cprtpr-dataplatform-sp1`.usviews.v_us_lot_fact l
        LEFT JOIN cte ON cte.lot_nbr = l.lot_nbr
        LEFT JOIN cte_pq ON cte_pq.lot_nbr = l.lot_nbr
        LEFT JOIN cte_pqai ON cte_pqai.lot_nbr = l.lot_nbr
    WHERE (BU_hrchy_levl2 = 'Insurance' OR seller_parent_company = 'TFSS')
      AND inv_dt >= '2025-01-01'
)
SELECT dp.period,
       CASE
           WHEN high_bid_amt < 500 THEN 'a. 0-500'
           WHEN high_bid_amt >= 500 AND high_bid_amt < 1000 THEN 'b. 500-1000'
           WHEN high_bid_amt >= 1000 AND high_bid_amt < 2500 THEN 'c. 1000-2500'
           WHEN high_bid_amt >= 2500 AND high_bid_amt < 5000 THEN 'd. 2500-5000'
           WHEN high_bid_amt >= 5000 AND high_bid_amt < 10000 THEN 'e. 5000-10000'
           WHEN high_bid_amt >= 10000 AND high_bid_amt < 20000 THEN 'f. 10000-20000'
           ELSE 'g. 20000+'
       END AS Sale_Price_Bucket,
       COUNT(DISTINCT lot_nbr)                                                                        AS `Units Sold`,
       COUNT(DISTINCT CASE WHEN pq_flag = 1 THEN lot_nbr END)                                        AS `PQ Cleansed Units Sold`,
       COUNT(DISTINCT CASE WHEN pqai_flag = 1 THEN lot_nbr END)                                      AS `PQ_ai Cleansed Units Sold`,
       ROUND(SAFE_DIVIDE(COUNT(DISTINCT CASE WHEN pq_flag = 1 THEN lot_nbr END),
                         COUNT(DISTINCT lot_nbr)), 4)                                                 AS `% Sold with ProQuote Cleansed`,
       ROUND(SAFE_DIVIDE(COUNT(DISTINCT CASE WHEN pqai_flag = 1 THEN lot_nbr END),
                         COUNT(DISTINCT lot_nbr)), 4)                                                 AS `% Sold with ProQuote_ai Cleansed`,
       -- PQ Cleansed metrics
       ROUND(AVG(CASE WHEN pq_flag = 1 THEN high_bid_amt END), 2)                                    AS `ASP - PQ Cleansed`,
       ROUND(AVG(CASE WHEN pq_flag = 1 THEN proquote_amt_cleansed END), 2)                           AS `Avg ProQuote - Cleansed`,
       ROUND(SAFE_DIVIDE(AVG(CASE WHEN pq_flag = 1 THEN proquote_amt_cleansed END),
                         AVG(CASE WHEN pq_flag = 1 THEN high_bid_amt END)) - 1, 4)                   AS `PQ Mean Error Pct - Cleansed`,
       ROUND(AVG(CASE WHEN pq_flag = 1 THEN ABS(proquote_amt_cleansed - high_bid_amt) END), 2)       AS `PQ MAE - Cleansed`,
       ROUND(AVG(CASE WHEN pq_flag = 1
           THEN ABS(proquote_amt_cleansed - high_bid_amt) / NULLIF(ABS(high_bid_amt), 0) END), 4)    AS `PQ MAPE - Cleansed`,
       -- PQAI Cleansed metrics
       ROUND(AVG(CASE WHEN pqai_flag = 1 THEN high_bid_amt END), 2)                                  AS `ASP - PQ_ai Cleansed`,
       ROUND(AVG(CASE WHEN pqai_flag = 1 THEN PQ_ai_amt END), 2)                                     AS `Avg PQ_ai - Cleansed`,
       ROUND(SAFE_DIVIDE(AVG(CASE WHEN pqai_flag = 1 THEN PQ_ai_amt END),
                         AVG(CASE WHEN pqai_flag = 1 THEN high_bid_amt END)) - 1, 4)                 AS `PQ_ai Mean Error Pct - Cleansed`,
       ROUND(AVG(CASE WHEN pqai_flag = 1 THEN ABS(PQ_ai_amt - high_bid_amt) END), 2)                 AS `PQ_ai MAE - Cleansed`,
       ROUND(AVG(CASE WHEN pqai_flag = 1
           THEN ABS(PQ_ai_amt - high_bid_amt) / NULLIF(ABS(high_bid_amt), 0) END), 4)                AS `PQ_ai MAPE - Cleansed`,
       -- PQAI Cleansed Low metrics
       ROUND(AVG(CASE WHEN pqai_flag = 1 THEN PQ_ai_amt_low END), 2)                                 AS `Avg PQ_ai Low - Cleansed`,
       ROUND(SAFE_DIVIDE(AVG(CASE WHEN pqai_flag = 1 THEN PQ_ai_amt_low END),
                         AVG(CASE WHEN pqai_flag = 1 THEN high_bid_amt END)) - 1, 4)                 AS `PQ_ai Low Mean Error Pct - Cleansed`,
       ROUND(AVG(CASE WHEN pqai_flag = 1 THEN ABS(PQ_ai_amt_low - high_bid_amt) END), 2)             AS `PQ_ai Low MAE - Cleansed`,
       ROUND(AVG(CASE WHEN pqai_flag = 1
           THEN ABS(PQ_ai_amt_low - high_bid_amt) / NULLIF(ABS(high_bid_amt), 0) END), 4)            AS `PQ_ai Low MAPE - Cleansed`,
       -- PQAI Cleansed High metrics
       ROUND(AVG(CASE WHEN pqai_flag = 1 THEN PQ_ai_amt_high END), 2)                                AS `Avg PQ_ai High - Cleansed`,
       ROUND(SAFE_DIVIDE(AVG(CASE WHEN pqai_flag = 1 THEN PQ_ai_amt_high END),
                         AVG(CASE WHEN pqai_flag = 1 THEN high_bid_amt END)) - 1, 4)                 AS `PQ_ai High Mean Error Pct - Cleansed`,
       ROUND(AVG(CASE WHEN pqai_flag = 1 THEN ABS(PQ_ai_amt_high - high_bid_amt) END), 2)            AS `PQ_ai High MAE - Cleansed`,
       ROUND(AVG(CASE WHEN pqai_flag = 1
           THEN ABS(PQ_ai_amt_high - high_bid_amt) / NULLIF(ABS(high_bid_amt), 0) END), 4)           AS `PQ_ai High MAPE - Cleansed`
FROM cte3
JOIN date_periods dp ON cte3.inv_dt BETWEEN dp.start_dt AND dp.end_dt
GROUP BY 1, 2
ORDER BY
    CASE dp.period WHEN 'Past Week' THEN 1 WHEN 'Past Month' THEN 2 WHEN 'Trailing 3 Months' THEN 3 END,
    Sale_Price_Bucket;


-- PQ.ai Error Loss Type - Insurance + TFSS
WITH date_periods AS (
    SELECT 'Past Week' AS period,
           DATE_SUB(DATE_TRUNC(CURRENT_DATE(), WEEK(MONDAY)), INTERVAL 1 WEEK) AS start_dt,
           DATE_SUB(DATE_TRUNC(CURRENT_DATE(), WEEK(MONDAY)), INTERVAL 1 DAY) AS end_dt
    UNION ALL
    SELECT 'Past Month',
           DATE_TRUNC(DATE_SUB(CURRENT_DATE(), INTERVAL 1 MONTH), MONTH),
           DATE_SUB(DATE_TRUNC(CURRENT_DATE(), MONTH), INTERVAL 1 DAY)
    UNION ALL
    SELECT 'Trailing 3 Months',
           DATE_SUB(DATE_TRUNC(CURRENT_DATE(), WEEK(MONDAY)), INTERVAL 3 MONTH),
           CURRENT_DATE()
),
cte AS (
    SELECT lot AS lot_nbr, crt_dt AS latest_pqai, output_details_json, lids_version
    FROM (
        SELECT v.lot, v.crt_dt, v.output_details_json, v.lids_version,
               ROW_NUMBER() OVER (PARTITION BY v.lot ORDER BY v.crt_dt DESC) AS rn
        FROM `cprtpr-dataplatform-sp1`.usviews.v_us_lot_image_damage_scores_fact v
        WHERE CAST(JSON_EXTRACT(v.output_details_json,
            '$.vuequote_results.vpq_result.proquote_amount') AS NUMERIC) IS NOT NULL
    )
    WHERE rn = 1
),
cte_pq AS (
    SELECT lot_nbr, 1 AS pq_flag
    FROM `cprtpr-dataplatform-sp1`.usviews.v_us_lot_fact
    WHERE (BU_hrchy_levl2 = 'Insurance' OR seller_parent_company = 'TFSS')
      AND inv_dt >= '2025-01-01'
      AND lot_type_cd IN ('V')
      AND cat_id = -1
      AND acv < 100000
      AND acv >= 1000.01
      AND repair_cost >= 1000.01
      AND acv <> repair_cost
      AND high_bid_amt > 0.5 * (acv - repair_cost)
      AND repair_cost / acv < 2
      AND proquote_amt_new IS NOT NULL
),
cte_pqai AS (
    SELECT f.lot_nbr, 1 AS pqai_flag
    FROM `cprtpr-dataplatform-sp1`.usviews.v_us_lot_fact f
    INNER JOIN cte ON f.lot_nbr = cte.lot_nbr
    WHERE (f.BU_hrchy_levl2 = 'Insurance' OR f.seller_parent_company = 'TFSS')
      AND f.inv_dt >= '2025-01-01'
      AND f.lot_type_cd IN ('V')
      AND f.cat_id = -1
      AND f.acv < 100000
      AND f.loss_type_cd = 'C'
),
cte3 AS (
    SELECT
        l.lot_nbr, inv_dt, acv, high_bid_amt,
        lot_type_cd, loss_type_desc, lot_make_cd,
        CASE
            WHEN l.proquote_amt_new > 0 THEN l.proquote_amt_new
            WHEN l.proquote_amt > 0 THEN l.proquote_amt
        END AS proquote_amt_cleansed,
        CAST(JSON_EXTRACT(cte.output_details_json,
            '$.vuequote_results.vpq_result.proquote_amount') AS NUMERIC) AS PQ_ai_amt,
        CAST(JSON_EXTRACT(cte.output_details_json,
            '$.vuequote_results.vpq_result.proquote_amount_low') AS NUMERIC) AS PQ_ai_amt_low,
        CAST(JSON_EXTRACT(cte.output_details_json,
            '$.vuequote_results.vpq_result.proquote_amount_high') AS NUMERIC) AS PQ_ai_amt_high,
        cte_pq.pq_flag,
        cte_pqai.pqai_flag
    FROM `cprtpr-dataplatform-sp1`.usviews.v_us_lot_fact l
        LEFT JOIN cte ON cte.lot_nbr = l.lot_nbr
        LEFT JOIN cte_pq ON cte_pq.lot_nbr = l.lot_nbr
        LEFT JOIN cte_pqai ON cte_pqai.lot_nbr = l.lot_nbr
    WHERE (BU_hrchy_levl2 = 'Insurance' OR seller_parent_company = 'TFSS')
      AND inv_dt >= '2025-01-01'
)
SELECT dp.period,
       loss_type_desc AS Loss_Type_Bucket,
       COUNT(DISTINCT lot_nbr)                                                                        AS `Units Sold`,
       COUNT(DISTINCT CASE WHEN pq_flag = 1 THEN lot_nbr END)                                        AS `PQ Cleansed Units Sold`,
       COUNT(DISTINCT CASE WHEN pqai_flag = 1 THEN lot_nbr END)                                      AS `PQ_ai Cleansed Units Sold`,
       ROUND(SAFE_DIVIDE(COUNT(DISTINCT CASE WHEN pq_flag = 1 THEN lot_nbr END),
                         COUNT(DISTINCT lot_nbr)), 4)                                                 AS `% Sold with ProQuote Cleansed`,
       ROUND(SAFE_DIVIDE(COUNT(DISTINCT CASE WHEN pqai_flag = 1 THEN lot_nbr END),
                         COUNT(DISTINCT lot_nbr)), 4)                                                 AS `% Sold with ProQuote_ai Cleansed`,
       -- PQ Cleansed metrics
       ROUND(AVG(CASE WHEN pq_flag = 1 THEN high_bid_amt END), 2)                                    AS `ASP - PQ Cleansed`,
       ROUND(AVG(CASE WHEN pq_flag = 1 THEN proquote_amt_cleansed END), 2)                           AS `Avg ProQuote - Cleansed`,
       ROUND(SAFE_DIVIDE(AVG(CASE WHEN pq_flag = 1 THEN proquote_amt_cleansed END),
                         AVG(CASE WHEN pq_flag = 1 THEN high_bid_amt END)) - 1, 4)                   AS `PQ Mean Error Pct - Cleansed`,
       ROUND(AVG(CASE WHEN pq_flag = 1 THEN ABS(proquote_amt_cleansed - high_bid_amt) END), 2)       AS `PQ MAE - Cleansed`,
       ROUND(AVG(CASE WHEN pq_flag = 1
           THEN ABS(proquote_amt_cleansed - high_bid_amt) / NULLIF(ABS(high_bid_amt), 0) END), 4)    AS `PQ MAPE - Cleansed`,
       -- PQAI Cleansed metrics
       ROUND(AVG(CASE WHEN pqai_flag = 1 THEN high_bid_amt END), 2)                                  AS `ASP - PQ_ai Cleansed`,
       ROUND(AVG(CASE WHEN pqai_flag = 1 THEN PQ_ai_amt END), 2)                                     AS `Avg PQ_ai - Cleansed`,
       ROUND(SAFE_DIVIDE(AVG(CASE WHEN pqai_flag = 1 THEN PQ_ai_amt END),
                         AVG(CASE WHEN pqai_flag = 1 THEN high_bid_amt END)) - 1, 4)                 AS `PQ_ai Mean Error Pct - Cleansed`,
       ROUND(AVG(CASE WHEN pqai_flag = 1 THEN ABS(PQ_ai_amt - high_bid_amt) END), 2)                 AS `PQ_ai MAE - Cleansed`,
       ROUND(AVG(CASE WHEN pqai_flag = 1
           THEN ABS(PQ_ai_amt - high_bid_amt) / NULLIF(ABS(high_bid_amt), 0) END), 4)                AS `PQ_ai MAPE - Cleansed`,
       -- PQAI Cleansed Low metrics
       ROUND(AVG(CASE WHEN pqai_flag = 1 THEN PQ_ai_amt_low END), 2)                                 AS `Avg PQ_ai Low - Cleansed`,
       ROUND(SAFE_DIVIDE(AVG(CASE WHEN pqai_flag = 1 THEN PQ_ai_amt_low END),
                         AVG(CASE WHEN pqai_flag = 1 THEN high_bid_amt END)) - 1, 4)                 AS `PQ_ai Low Mean Error Pct - Cleansed`,
       ROUND(AVG(CASE WHEN pqai_flag = 1 THEN ABS(PQ_ai_amt_low - high_bid_amt) END), 2)             AS `PQ_ai Low MAE - Cleansed`,
       ROUND(AVG(CASE WHEN pqai_flag = 1
           THEN ABS(PQ_ai_amt_low - high_bid_amt) / NULLIF(ABS(high_bid_amt), 0) END), 4)            AS `PQ_ai Low MAPE - Cleansed`,
       -- PQAI Cleansed High metrics
       ROUND(AVG(CASE WHEN pqai_flag = 1 THEN PQ_ai_amt_high END), 2)                                AS `Avg PQ_ai High - Cleansed`,
       ROUND(SAFE_DIVIDE(AVG(CASE WHEN pqai_flag = 1 THEN PQ_ai_amt_high END),
                         AVG(CASE WHEN pqai_flag = 1 THEN high_bid_amt END)) - 1, 4)                 AS `PQ_ai High Mean Error Pct - Cleansed`,
       ROUND(AVG(CASE WHEN pqai_flag = 1 THEN ABS(PQ_ai_amt_high - high_bid_amt) END), 2)            AS `PQ_ai High MAE - Cleansed`,
       ROUND(AVG(CASE WHEN pqai_flag = 1
           THEN ABS(PQ_ai_amt_high - high_bid_amt) / NULLIF(ABS(high_bid_amt), 0) END), 4)           AS `PQ_ai High MAPE - Cleansed`
FROM cte3
JOIN date_periods dp ON cte3.inv_dt BETWEEN dp.start_dt AND dp.end_dt
GROUP BY 1, 2
ORDER BY
    CASE dp.period WHEN 'Past Week' THEN 1 WHEN 'Past Month' THEN 2 WHEN 'Trailing 3 Months' THEN 3 END,
    Loss_Type_Bucket;


-- PQ.ai Error Lot Type - Insurance + TFSS
WITH date_periods AS (
    SELECT 'Past Week' AS period,
           DATE_SUB(DATE_TRUNC(CURRENT_DATE(), WEEK(MONDAY)), INTERVAL 1 WEEK) AS start_dt,
           DATE_SUB(DATE_TRUNC(CURRENT_DATE(), WEEK(MONDAY)), INTERVAL 1 DAY) AS end_dt
    UNION ALL
    SELECT 'Past Month',
           DATE_TRUNC(DATE_SUB(CURRENT_DATE(), INTERVAL 1 MONTH), MONTH),
           DATE_SUB(DATE_TRUNC(CURRENT_DATE(), MONTH), INTERVAL 1 DAY)
    UNION ALL
    SELECT 'Trailing 3 Months',
           DATE_SUB(DATE_TRUNC(CURRENT_DATE(), WEEK(MONDAY)), INTERVAL 3 MONTH),
           CURRENT_DATE()
),
cte AS (
    SELECT lot AS lot_nbr, crt_dt AS latest_pqai, output_details_json, lids_version
    FROM (
        SELECT v.lot, v.crt_dt, v.output_details_json, v.lids_version,
               ROW_NUMBER() OVER (PARTITION BY v.lot ORDER BY v.crt_dt DESC) AS rn
        FROM `cprtpr-dataplatform-sp1`.usviews.v_us_lot_image_damage_scores_fact v
        WHERE CAST(JSON_EXTRACT(v.output_details_json,
            '$.vuequote_results.vpq_result.proquote_amount') AS NUMERIC) IS NOT NULL
    )
    WHERE rn = 1
),
cte_pq AS (
    SELECT lot_nbr, 1 AS pq_flag
    FROM `cprtpr-dataplatform-sp1`.usviews.v_us_lot_fact
    WHERE (BU_hrchy_levl2 = 'Insurance' OR seller_parent_company = 'TFSS')
      AND inv_dt >= '2025-01-01'
      AND lot_type_cd IN ('V')
      AND cat_id = -1
      AND acv < 100000
      AND acv >= 1000.01
      AND repair_cost >= 1000.01
      AND acv <> repair_cost
      AND high_bid_amt > 0.5 * (acv - repair_cost)
      AND repair_cost / acv < 2
      AND proquote_amt_new IS NOT NULL
),
cte_pqai AS (
    SELECT f.lot_nbr, 1 AS pqai_flag
    FROM `cprtpr-dataplatform-sp1`.usviews.v_us_lot_fact f
    INNER JOIN cte ON f.lot_nbr = cte.lot_nbr
    WHERE (f.BU_hrchy_levl2 = 'Insurance' OR f.seller_parent_company = 'TFSS')
      AND f.inv_dt >= '2025-01-01'
      AND f.lot_type_cd IN ('V')
      AND f.cat_id = -1
      AND f.acv < 100000
      AND f.loss_type_cd = 'C'
),
cte3 AS (
    SELECT
        l.lot_nbr, inv_dt, acv, high_bid_amt,
        lot_type_cd, loss_type_desc, lot_make_cd,
        CASE
            WHEN l.proquote_amt_new > 0 THEN l.proquote_amt_new
            WHEN l.proquote_amt > 0 THEN l.proquote_amt
        END AS proquote_amt_cleansed,
        CAST(JSON_EXTRACT(cte.output_details_json,
            '$.vuequote_results.vpq_result.proquote_amount') AS NUMERIC) AS PQ_ai_amt,
        CAST(JSON_EXTRACT(cte.output_details_json,
            '$.vuequote_results.vpq_result.proquote_amount_low') AS NUMERIC) AS PQ_ai_amt_low,
        CAST(JSON_EXTRACT(cte.output_details_json,
            '$.vuequote_results.vpq_result.proquote_amount_high') AS NUMERIC) AS PQ_ai_amt_high,
        cte_pq.pq_flag,
        cte_pqai.pqai_flag
    FROM `cprtpr-dataplatform-sp1`.usviews.v_us_lot_fact l
        LEFT JOIN cte ON cte.lot_nbr = l.lot_nbr
        LEFT JOIN cte_pq ON cte_pq.lot_nbr = l.lot_nbr
        LEFT JOIN cte_pqai ON cte_pqai.lot_nbr = l.lot_nbr
    WHERE (BU_hrchy_levl2 = 'Insurance' OR seller_parent_company = 'TFSS')
      AND inv_dt >= '2025-01-01'
)
SELECT dp.period,
       lot_type_cd AS Lot_Type_Bucket,
       COUNT(DISTINCT lot_nbr)                                                                        AS `Units Sold`,
       COUNT(DISTINCT CASE WHEN pq_flag = 1 THEN lot_nbr END)                                        AS `PQ Cleansed Units Sold`,
       COUNT(DISTINCT CASE WHEN pqai_flag = 1 THEN lot_nbr END)                                      AS `PQ_ai Cleansed Units Sold`,
       ROUND(SAFE_DIVIDE(COUNT(DISTINCT CASE WHEN pq_flag = 1 THEN lot_nbr END),
                         COUNT(DISTINCT lot_nbr)), 4)                                                 AS `% Sold with ProQuote Cleansed`,
       ROUND(SAFE_DIVIDE(COUNT(DISTINCT CASE WHEN pqai_flag = 1 THEN lot_nbr END),
                         COUNT(DISTINCT lot_nbr)), 4)                                                 AS `% Sold with ProQuote_ai Cleansed`,
       -- PQ Cleansed metrics
       ROUND(AVG(CASE WHEN pq_flag = 1 THEN high_bid_amt END), 2)                                    AS `ASP - PQ Cleansed`,
       ROUND(AVG(CASE WHEN pq_flag = 1 THEN proquote_amt_cleansed END), 2)                           AS `Avg ProQuote - Cleansed`,
       ROUND(SAFE_DIVIDE(AVG(CASE WHEN pq_flag = 1 THEN proquote_amt_cleansed END),
                         AVG(CASE WHEN pq_flag = 1 THEN high_bid_amt END)) - 1, 4)                   AS `PQ Mean Error Pct - Cleansed`,
       ROUND(AVG(CASE WHEN pq_flag = 1 THEN ABS(proquote_amt_cleansed - high_bid_amt) END), 2)       AS `PQ MAE - Cleansed`,
       ROUND(AVG(CASE WHEN pq_flag = 1
           THEN ABS(proquote_amt_cleansed - high_bid_amt) / NULLIF(ABS(high_bid_amt), 0) END), 4)    AS `PQ MAPE - Cleansed`,
       -- PQAI Cleansed metrics
       ROUND(AVG(CASE WHEN pqai_flag = 1 THEN high_bid_amt END), 2)                                  AS `ASP - PQ_ai Cleansed`,
       ROUND(AVG(CASE WHEN pqai_flag = 1 THEN PQ_ai_amt END), 2)                                     AS `Avg PQ_ai - Cleansed`,
       ROUND(SAFE_DIVIDE(AVG(CASE WHEN pqai_flag = 1 THEN PQ_ai_amt END),
                         AVG(CASE WHEN pqai_flag = 1 THEN high_bid_amt END)) - 1, 4)                 AS `PQ_ai Mean Error Pct - Cleansed`,
       ROUND(AVG(CASE WHEN pqai_flag = 1 THEN ABS(PQ_ai_amt - high_bid_amt) END), 2)                 AS `PQ_ai MAE - Cleansed`,
       ROUND(AVG(CASE WHEN pqai_flag = 1
           THEN ABS(PQ_ai_amt - high_bid_amt) / NULLIF(ABS(high_bid_amt), 0) END), 4)                AS `PQ_ai MAPE - Cleansed`,
       -- PQAI Cleansed Low metrics
       ROUND(AVG(CASE WHEN pqai_flag = 1 THEN PQ_ai_amt_low END), 2)                                 AS `Avg PQ_ai Low - Cleansed`,
       ROUND(SAFE_DIVIDE(AVG(CASE WHEN pqai_flag = 1 THEN PQ_ai_amt_low END),
                         AVG(CASE WHEN pqai_flag = 1 THEN high_bid_amt END)) - 1, 4)                 AS `PQ_ai Low Mean Error Pct - Cleansed`,
       ROUND(AVG(CASE WHEN pqai_flag = 1 THEN ABS(PQ_ai_amt_low - high_bid_amt) END), 2)             AS `PQ_ai Low MAE - Cleansed`,
       ROUND(AVG(CASE WHEN pqai_flag = 1
           THEN ABS(PQ_ai_amt_low - high_bid_amt) / NULLIF(ABS(high_bid_amt), 0) END), 4)            AS `PQ_ai Low MAPE - Cleansed`,
       -- PQAI Cleansed High metrics
       ROUND(AVG(CASE WHEN pqai_flag = 1 THEN PQ_ai_amt_high END), 2)                                AS `Avg PQ_ai High - Cleansed`,
       ROUND(SAFE_DIVIDE(AVG(CASE WHEN pqai_flag = 1 THEN PQ_ai_amt_high END),
                         AVG(CASE WHEN pqai_flag = 1 THEN high_bid_amt END)) - 1, 4)                 AS `PQ_ai High Mean Error Pct - Cleansed`,
       ROUND(AVG(CASE WHEN pqai_flag = 1 THEN ABS(PQ_ai_amt_high - high_bid_amt) END), 2)            AS `PQ_ai High MAE - Cleansed`,
       ROUND(AVG(CASE WHEN pqai_flag = 1
           THEN ABS(PQ_ai_amt_high - high_bid_amt) / NULLIF(ABS(high_bid_amt), 0) END), 4)           AS `PQ_ai High MAPE - Cleansed`
FROM cte3
JOIN date_periods dp ON cte3.inv_dt BETWEEN dp.start_dt AND dp.end_dt
GROUP BY 1, 2
ORDER BY
    CASE dp.period WHEN 'Past Week' THEN 1 WHEN 'Past Month' THEN 2 WHEN 'Trailing 3 Months' THEN 3 END,
    Lot_Type_Bucket;


-- PQ.ai Error Make Bucket - Insurance + TFSS
WITH date_periods AS (
    SELECT 'Past Week' AS period,
           DATE_SUB(DATE_TRUNC(CURRENT_DATE(), WEEK(MONDAY)), INTERVAL 1 WEEK) AS start_dt,
           DATE_SUB(DATE_TRUNC(CURRENT_DATE(), WEEK(MONDAY)), INTERVAL 1 DAY) AS end_dt
    UNION ALL
    SELECT 'Past Month',
           DATE_TRUNC(DATE_SUB(CURRENT_DATE(), INTERVAL 1 MONTH), MONTH),
           DATE_SUB(DATE_TRUNC(CURRENT_DATE(), MONTH), INTERVAL 1 DAY)
    UNION ALL
    SELECT 'Trailing 3 Months',
           DATE_SUB(DATE_TRUNC(CURRENT_DATE(), WEEK(MONDAY)), INTERVAL 3 MONTH),
           CURRENT_DATE()
),
cte AS (
    SELECT lot AS lot_nbr, crt_dt AS latest_pqai, output_details_json, lids_version
    FROM (
        SELECT v.lot, v.crt_dt, v.output_details_json, v.lids_version,
               ROW_NUMBER() OVER (PARTITION BY v.lot ORDER BY v.crt_dt DESC) AS rn
        FROM `cprtpr-dataplatform-sp1`.usviews.v_us_lot_image_damage_scores_fact v
        WHERE CAST(JSON_EXTRACT(v.output_details_json,
            '$.vuequote_results.vpq_result.proquote_amount') AS NUMERIC) IS NOT NULL
    )
    WHERE rn = 1
),
cte_pq AS (
    SELECT lot_nbr, 1 AS pq_flag
    FROM `cprtpr-dataplatform-sp1`.usviews.v_us_lot_fact
    WHERE (BU_hrchy_levl2 = 'Insurance' OR seller_parent_company = 'TFSS')
      AND inv_dt >= '2025-01-01'
      AND lot_type_cd IN ('V')
      AND cat_id = -1
      AND acv < 100000
      AND acv >= 1000.01
      AND repair_cost >= 1000.01
      AND acv <> repair_cost
      AND high_bid_amt > 0.5 * (acv - repair_cost)
      AND repair_cost / acv < 2
      AND proquote_amt_new IS NOT NULL
),
cte_pqai AS (
    SELECT f.lot_nbr, 1 AS pqai_flag
    FROM `cprtpr-dataplatform-sp1`.usviews.v_us_lot_fact f
    INNER JOIN cte ON f.lot_nbr = cte.lot_nbr
    WHERE (f.BU_hrchy_levl2 = 'Insurance' OR f.seller_parent_company = 'TFSS')
      AND f.inv_dt >= '2025-01-01'
      AND f.lot_type_cd IN ('V')
      AND f.cat_id = -1
      AND f.acv < 100000
      AND f.loss_type_cd = 'C'
),
cte3 AS (
    SELECT
        l.lot_nbr, inv_dt, acv, high_bid_amt,
        lot_type_cd, loss_type_desc, lot_make_cd,
        CASE
            WHEN l.proquote_amt_new > 0 THEN l.proquote_amt_new
            WHEN l.proquote_amt > 0 THEN l.proquote_amt
        END AS proquote_amt_cleansed,
        CAST(JSON_EXTRACT(cte.output_details_json,
            '$.vuequote_results.vpq_result.proquote_amount') AS NUMERIC) AS PQ_ai_amt,
        CAST(JSON_EXTRACT(cte.output_details_json,
            '$.vuequote_results.vpq_result.proquote_amount_low') AS NUMERIC) AS PQ_ai_amt_low,
        CAST(JSON_EXTRACT(cte.output_details_json,
            '$.vuequote_results.vpq_result.proquote_amount_high') AS NUMERIC) AS PQ_ai_amt_high,
        cte_pq.pq_flag,
        cte_pqai.pqai_flag
    FROM `cprtpr-dataplatform-sp1`.usviews.v_us_lot_fact l
        LEFT JOIN cte ON cte.lot_nbr = l.lot_nbr
        LEFT JOIN cte_pq ON cte_pq.lot_nbr = l.lot_nbr
        LEFT JOIN cte_pqai ON cte_pqai.lot_nbr = l.lot_nbr
    WHERE (BU_hrchy_levl2 = 'Insurance' OR seller_parent_company = 'TFSS')
      AND inv_dt >= '2025-01-01'
)
SELECT dp.period,
       CASE
           WHEN lot_make_cd IN ('FIAT', 'MIN', 'MNNI', 'SAA', 'SMRT', 'VOLK') THEN 'European Standard'
           WHEN lot_make_cd IN ('HOND', 'HYUN', 'KIA', 'MAZD', 'MITS', 'NISS', 'OUTB', 'SUBA', 'SUZI', 'TOYT', '01BMW', '11BMW',
                                'DAEW', 'HONDA', 'ISU', 'ISUZ', 'KAWA', 'YAMA') THEN 'Asian Standard'
           WHEN lot_make_cd IN ('BUIC', 'CHEV', 'CHRY', 'DODG', 'FORD', 'GMC', 'HUMM', 'JEEP', 'JEP', 'MERC', 'OLDS', 'PrerunM',
                                'PONT', 'SATU', 'STRN', 'RAM', 'HARL') THEN 'Domestic Standard'
           WHEN lot_make_cd IN ('ALFA', 'AUDI', 'BENT', 'BMW', 'FERR', 'JAGU', 'LAMO', 'LAND', 'LNDR', 'MERZ', 'PORS', 'VOLV', 'MASE',
                                'BENS', 'BENZ', 'PLSR', 'POLE', 'ASTO', 'MCLA', 'LOTU') THEN 'European Luxury'
           WHEN lot_make_cd IN ('ACUR', 'INFI', 'LEXS', 'GENS') THEN 'Asian Luxury'
           WHEN lot_make_cd IN ('CADI', 'LINC', 'TESL', 'RIVA', 'LUCI') THEN 'Domestic Luxury'
           ELSE 'Other'
       END AS Make_Bucket,
       COUNT(DISTINCT lot_nbr)                                                                        AS `Units Sold`,
       COUNT(DISTINCT CASE WHEN pq_flag = 1 THEN lot_nbr END)                                        AS `PQ Cleansed Units Sold`,
       COUNT(DISTINCT CASE WHEN pqai_flag = 1 THEN lot_nbr END)                                      AS `PQ_ai Cleansed Units Sold`,
       ROUND(SAFE_DIVIDE(COUNT(DISTINCT CASE WHEN pq_flag = 1 THEN lot_nbr END),
                         COUNT(DISTINCT lot_nbr)), 4)                                                 AS `% Sold with ProQuote Cleansed`,
       ROUND(SAFE_DIVIDE(COUNT(DISTINCT CASE WHEN pqai_flag = 1 THEN lot_nbr END),
                         COUNT(DISTINCT lot_nbr)), 4)                                                 AS `% Sold with ProQuote_ai Cleansed`,
       -- PQ Cleansed metrics
       ROUND(AVG(CASE WHEN pq_flag = 1 THEN high_bid_amt END), 2)                                    AS `ASP - PQ Cleansed`,
       ROUND(AVG(CASE WHEN pq_flag = 1 THEN proquote_amt_cleansed END), 2)                           AS `Avg ProQuote - Cleansed`,
       ROUND(SAFE_DIVIDE(AVG(CASE WHEN pq_flag = 1 THEN proquote_amt_cleansed END),
                         AVG(CASE WHEN pq_flag = 1 THEN high_bid_amt END)) - 1, 4)                   AS `PQ Mean Error Pct - Cleansed`,
       ROUND(AVG(CASE WHEN pq_flag = 1 THEN ABS(proquote_amt_cleansed - high_bid_amt) END), 2)       AS `PQ MAE - Cleansed`,
       ROUND(AVG(CASE WHEN pq_flag = 1
           THEN ABS(proquote_amt_cleansed - high_bid_amt) / NULLIF(ABS(high_bid_amt), 0) END), 4)    AS `PQ MAPE - Cleansed`,
       -- PQAI Cleansed metrics
       ROUND(AVG(CASE WHEN pqai_flag = 1 THEN high_bid_amt END), 2)                                  AS `ASP - PQ_ai Cleansed`,
       ROUND(AVG(CASE WHEN pqai_flag = 1 THEN PQ_ai_amt END), 2)                                     AS `Avg PQ_ai - Cleansed`,
       ROUND(SAFE_DIVIDE(AVG(CASE WHEN pqai_flag = 1 THEN PQ_ai_amt END),
                         AVG(CASE WHEN pqai_flag = 1 THEN high_bid_amt END)) - 1, 4)                 AS `PQ_ai Mean Error Pct - Cleansed`,
       ROUND(AVG(CASE WHEN pqai_flag = 1 THEN ABS(PQ_ai_amt - high_bid_amt) END), 2)                 AS `PQ_ai MAE - Cleansed`,
       ROUND(AVG(CASE WHEN pqai_flag = 1
           THEN ABS(PQ_ai_amt - high_bid_amt) / NULLIF(ABS(high_bid_amt), 0) END), 4)                AS `PQ_ai MAPE - Cleansed`,
       -- PQAI Cleansed Low metrics
       ROUND(AVG(CASE WHEN pqai_flag = 1 THEN PQ_ai_amt_low END), 2)                                 AS `Avg PQ_ai Low - Cleansed`,
       ROUND(SAFE_DIVIDE(AVG(CASE WHEN pqai_flag = 1 THEN PQ_ai_amt_low END),
                         AVG(CASE WHEN pqai_flag = 1 THEN high_bid_amt END)) - 1, 4)                 AS `PQ_ai Low Mean Error Pct - Cleansed`,
       ROUND(AVG(CASE WHEN pqai_flag = 1 THEN ABS(PQ_ai_amt_low - high_bid_amt) END), 2)             AS `PQ_ai Low MAE - Cleansed`,
       ROUND(AVG(CASE WHEN pqai_flag = 1
           THEN ABS(PQ_ai_amt_low - high_bid_amt) / NULLIF(ABS(high_bid_amt), 0) END), 4)            AS `PQ_ai Low MAPE - Cleansed`,
       -- PQAI Cleansed High metrics
       ROUND(AVG(CASE WHEN pqai_flag = 1 THEN PQ_ai_amt_high END), 2)                                AS `Avg PQ_ai High - Cleansed`,
       ROUND(SAFE_DIVIDE(AVG(CASE WHEN pqai_flag = 1 THEN PQ_ai_amt_high END),
                         AVG(CASE WHEN pqai_flag = 1 THEN high_bid_amt END)) - 1, 4)                 AS `PQ_ai High Mean Error Pct - Cleansed`,
       ROUND(AVG(CASE WHEN pqai_flag = 1 THEN ABS(PQ_ai_amt_high - high_bid_amt) END), 2)            AS `PQ_ai High MAE - Cleansed`,
       ROUND(AVG(CASE WHEN pqai_flag = 1
           THEN ABS(PQ_ai_amt_high - high_bid_amt) / NULLIF(ABS(high_bid_amt), 0) END), 4)           AS `PQ_ai High MAPE - Cleansed`
FROM cte3
JOIN date_periods dp ON cte3.inv_dt BETWEEN dp.start_dt AND dp.end_dt
GROUP BY 1, 2
ORDER BY
    CASE dp.period WHEN 'Past Week' THEN 1 WHEN 'Past Month' THEN 2 WHEN 'Trailing 3 Months' THEN 3 END,
    Make_Bucket;


-- PQ.ai Error Title Type - Insurance + TFSS
WITH date_periods AS (
    SELECT 'Past Week' AS period,
           DATE_SUB(DATE_TRUNC(CURRENT_DATE(), WEEK(MONDAY)), INTERVAL 1 WEEK) AS start_dt,
           DATE_SUB(DATE_TRUNC(CURRENT_DATE(), WEEK(MONDAY)), INTERVAL 1 DAY) AS end_dt
    UNION ALL
    SELECT 'Past Month',
           DATE_TRUNC(DATE_SUB(CURRENT_DATE(), INTERVAL 1 MONTH), MONTH),
           DATE_SUB(DATE_TRUNC(CURRENT_DATE(), MONTH), INTERVAL 1 DAY)
    UNION ALL
    SELECT 'Trailing 3 Months',
           DATE_SUB(DATE_TRUNC(CURRENT_DATE(), WEEK(MONDAY)), INTERVAL 3 MONTH),
           CURRENT_DATE()
),
cte AS (
    SELECT lot AS lot_nbr, crt_dt AS latest_pqai, output_details_json, lids_version
    FROM (
        SELECT v.lot, v.crt_dt, v.output_details_json, v.lids_version,
               ROW_NUMBER() OVER (PARTITION BY v.lot ORDER BY v.crt_dt DESC) AS rn
        FROM `cprtpr-dataplatform-sp1`.usviews.v_us_lot_image_damage_scores_fact v
        WHERE CAST(JSON_EXTRACT(v.output_details_json,
            '$.vuequote_results.vpq_result.proquote_amount') AS NUMERIC) IS NOT NULL
    )
    WHERE rn = 1
),
cte_pq AS (
    SELECT lot_nbr, 1 AS pq_flag
    FROM `cprtpr-dataplatform-sp1`.usviews.v_us_lot_fact
    WHERE (BU_hrchy_levl2 = 'Insurance' OR seller_parent_company = 'TFSS')
      AND inv_dt >= '2025-01-01'
      AND lot_type_cd IN ('V')
      AND cat_id = -1
      AND acv < 100000
      AND acv >= 1000.01
      AND repair_cost >= 1000.01
      AND acv <> repair_cost
      AND high_bid_amt > 0.5 * (acv - repair_cost)
      AND repair_cost / acv < 2
      AND proquote_amt_new IS NOT NULL
),
cte_pqai AS (
    SELECT f.lot_nbr, 1 AS pqai_flag
    FROM `cprtpr-dataplatform-sp1`.usviews.v_us_lot_fact f
    INNER JOIN cte ON f.lot_nbr = cte.lot_nbr
    WHERE (f.BU_hrchy_levl2 = 'Insurance' OR f.seller_parent_company = 'TFSS')
      AND f.inv_dt >= '2025-01-01'
      AND f.lot_type_cd IN ('V')
      AND f.cat_id = -1
      AND f.acv < 100000
      AND f.loss_type_cd = 'C'
),
cte3 AS (
    SELECT
        l.lot_nbr, inv_dt, acv, high_bid_amt,
        lot_type_cd, loss_type_desc, lot_make_cd,
        l.sales_title_grp_long_desc,
        CASE
            WHEN l.proquote_amt_new > 0 THEN l.proquote_amt_new
            WHEN l.proquote_amt > 0 THEN l.proquote_amt
        END AS proquote_amt_cleansed,
        CAST(JSON_EXTRACT(cte.output_details_json,
            '$.vuequote_results.vpq_result.proquote_amount') AS NUMERIC) AS PQ_ai_amt,
        CAST(JSON_EXTRACT(cte.output_details_json,
            '$.vuequote_results.vpq_result.proquote_amount_low') AS NUMERIC) AS PQ_ai_amt_low,
        CAST(JSON_EXTRACT(cte.output_details_json,
            '$.vuequote_results.vpq_result.proquote_amount_high') AS NUMERIC) AS PQ_ai_amt_high,
        cte_pq.pq_flag,
        cte_pqai.pqai_flag
    FROM `cprtpr-dataplatform-sp1`.usviews.v_us_lot_fact l
        LEFT JOIN cte ON cte.lot_nbr = l.lot_nbr
        LEFT JOIN cte_pq ON cte_pq.lot_nbr = l.lot_nbr
        LEFT JOIN cte_pqai ON cte_pqai.lot_nbr = l.lot_nbr
    WHERE (BU_hrchy_levl2 = 'Insurance' OR seller_parent_company = 'TFSS')
      AND inv_dt >= '2025-01-01'
)
SELECT dp.period,
       sales_title_grp_long_desc AS Title_Type_Bucket,
       COUNT(DISTINCT lot_nbr)                                                                        AS `Units Sold`,
       COUNT(DISTINCT CASE WHEN pq_flag = 1 THEN lot_nbr END)                                        AS `PQ Cleansed Units Sold`,
       COUNT(DISTINCT CASE WHEN pqai_flag = 1 THEN lot_nbr END)                                      AS `PQ_ai Cleansed Units Sold`,
       ROUND(SAFE_DIVIDE(COUNT(DISTINCT CASE WHEN pq_flag = 1 THEN lot_nbr END),
                         COUNT(DISTINCT lot_nbr)), 4)                                                 AS `% Sold with ProQuote Cleansed`,
       ROUND(SAFE_DIVIDE(COUNT(DISTINCT CASE WHEN pqai_flag = 1 THEN lot_nbr END),
                         COUNT(DISTINCT lot_nbr)), 4)                                                 AS `% Sold with ProQuote_ai Cleansed`,
       -- PQ Cleansed metrics
       ROUND(AVG(CASE WHEN pq_flag = 1 THEN high_bid_amt END), 2)                                    AS `ASP - PQ Cleansed`,
       ROUND(AVG(CASE WHEN pq_flag = 1 THEN proquote_amt_cleansed END), 2)                           AS `Avg ProQuote - Cleansed`,
       ROUND(SAFE_DIVIDE(AVG(CASE WHEN pq_flag = 1 THEN proquote_amt_cleansed END),
                         AVG(CASE WHEN pq_flag = 1 THEN high_bid_amt END)) - 1, 4)                   AS `PQ Mean Error Pct - Cleansed`,
       ROUND(AVG(CASE WHEN pq_flag = 1 THEN ABS(proquote_amt_cleansed - high_bid_amt) END), 2)       AS `PQ MAE - Cleansed`,
       ROUND(AVG(CASE WHEN pq_flag = 1
           THEN ABS(proquote_amt_cleansed - high_bid_amt) / NULLIF(ABS(high_bid_amt), 0) END), 4)    AS `PQ MAPE - Cleansed`,
       -- PQAI Cleansed metrics
       ROUND(AVG(CASE WHEN pqai_flag = 1 THEN high_bid_amt END), 2)                                  AS `ASP - PQ_ai Cleansed`,
       ROUND(AVG(CASE WHEN pqai_flag = 1 THEN PQ_ai_amt END), 2)                                     AS `Avg PQ_ai - Cleansed`,
       ROUND(SAFE_DIVIDE(AVG(CASE WHEN pqai_flag = 1 THEN PQ_ai_amt END),
                         AVG(CASE WHEN pqai_flag = 1 THEN high_bid_amt END)) - 1, 4)                 AS `PQ_ai Mean Error Pct - Cleansed`,
       ROUND(AVG(CASE WHEN pqai_flag = 1 THEN ABS(PQ_ai_amt - high_bid_amt) END), 2)                 AS `PQ_ai MAE - Cleansed`,
       ROUND(AVG(CASE WHEN pqai_flag = 1
           THEN ABS(PQ_ai_amt - high_bid_amt) / NULLIF(ABS(high_bid_amt), 0) END), 4)                AS `PQ_ai MAPE - Cleansed`,
       -- PQAI Cleansed Low metrics
       ROUND(AVG(CASE WHEN pqai_flag = 1 THEN PQ_ai_amt_low END), 2)                                 AS `Avg PQ_ai Low - Cleansed`,
       ROUND(SAFE_DIVIDE(AVG(CASE WHEN pqai_flag = 1 THEN PQ_ai_amt_low END),
                         AVG(CASE WHEN pqai_flag = 1 THEN high_bid_amt END)) - 1, 4)                 AS `PQ_ai Low Mean Error Pct - Cleansed`,
       ROUND(AVG(CASE WHEN pqai_flag = 1 THEN ABS(PQ_ai_amt_low - high_bid_amt) END), 2)             AS `PQ_ai Low MAE - Cleansed`,
       ROUND(AVG(CASE WHEN pqai_flag = 1
           THEN ABS(PQ_ai_amt_low - high_bid_amt) / NULLIF(ABS(high_bid_amt), 0) END), 4)            AS `PQ_ai Low MAPE - Cleansed`,
       -- PQAI Cleansed High metrics
       ROUND(AVG(CASE WHEN pqai_flag = 1 THEN PQ_ai_amt_high END), 2)                                AS `Avg PQ_ai High - Cleansed`,
       ROUND(SAFE_DIVIDE(AVG(CASE WHEN pqai_flag = 1 THEN PQ_ai_amt_high END),
                         AVG(CASE WHEN pqai_flag = 1 THEN high_bid_amt END)) - 1, 4)                 AS `PQ_ai High Mean Error Pct - Cleansed`,
       ROUND(AVG(CASE WHEN pqai_flag = 1 THEN ABS(PQ_ai_amt_high - high_bid_amt) END), 2)            AS `PQ_ai High MAE - Cleansed`,
       ROUND(AVG(CASE WHEN pqai_flag = 1
           THEN ABS(PQ_ai_amt_high - high_bid_amt) / NULLIF(ABS(high_bid_amt), 0) END), 4)           AS `PQ_ai High MAPE - Cleansed`
FROM cte3
JOIN date_periods dp ON cte3.inv_dt BETWEEN dp.start_dt AND dp.end_dt
GROUP BY 1, 2
ORDER BY
    CASE dp.period WHEN 'Past Week' THEN 1 WHEN 'Past Month' THEN 2 WHEN 'Trailing 3 Months' THEN 3 END,
    Title_Type_Bucket;
