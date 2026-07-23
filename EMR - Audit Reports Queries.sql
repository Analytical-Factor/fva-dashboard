/*
===============================================================================
EMR Forecast Review SQL Queries
===============================================================================

Contents:
1. Item status and user override classification
2. High-Level KPI Query
3. ABC Class Breakdown
4. Part Level Reports - Query 1: Total visible items

Backup parameter:
Set every target_month_start value to the first day of the month represented by
the database backup. For the current March 2026 backup, use DATE '2026-03-01'.
Only section separators were added to make the file easier to navigate.
===============================================================================
*/


/*
===============================================================================
1. Item status and user override classification
===============================================================================
*/

-- Item status and user override classification.
-- Set target_month_start to the cycle / End-of-History month being reviewed.
-- The query evaluates forecast data across the following 24-month window.
--
-- Status logic:
--   reconciled = 2
--     -> Automatically Reconciled
--
--   reconciled IN (1, 3)
--     -> Accepted / Reconciled
--     -> User override if:
--          1. Adjusted Forecast differs from AF Blended Forecast (expected_demand), OR
--          2. Hybrid / Final Forecast blend weights are overridden, OR
--          3. Hybrid Forecast method blend weights are overridden
--
--   reconciled = 0
--     -> Maintained in Exceptions
--     -> User override if:
--          1. Any Adjusted Forecast value exists, OR
--          2. Hybrid / Final Forecast blend weights are overridden, OR
--          3. Hybrid Forecast method blend weights are overridden
--
-- Forecast source classification:
--   Uses normalized active Hybrid / Final Forecast weights.
--   Items with volume_adjustment_required = true are classified separately.
--
-- All ds_matrix and ds_data logic is limited to demand_class_id = 0.

WITH params AS (
    SELECT DATE '2026-03-01' AS target_month_start
),
month_window AS (
    SELECT
        target_month_start,
        TO_CHAR(target_month_start, 'Mon-YY') AS target_month
    FROM params
),
visible_items AS (
    SELECT
        m.item_id,
        m.location_id,
        MAX(m.item) AS item,
        MAX(m.item_description) AS item_description,
        MAX(m.organization) AS organization,
        MAX(m.emr_abc_class) AS emr_class,
        MAX(m.reconciled) AS reconciled,
        MAX(COALESCE(m.rules, 0)) AS rules,

        BOOL_OR(
            COALESCE(
                (TO_JSONB(m) ->> 'volume_adjustment_required')::boolean,
                false
            )
        ) AS volume_adjustment_required,

        MAX(
            CASE
                WHEN m.ed_weight_override = TRUE
                THEN m.ed_forecast_2_weight_override / 100.0
                ELSE m.demand_forecast_weight
            END
        ) AS effective_hybrid_weight,

        MAX(
            CASE
                WHEN m.ed_weight_override = TRUE
                THEN m.ed_forecast_3_weight_override / 100.0
                ELSE m.final_forecast_weight
            END
        ) AS effective_final_weight,

        MAX(
            CASE
                WHEN m.ed_weight_override = TRUE
                  AND ROUND((m.demand_forecast_weight * 100)::numeric, 0)
                      <> ROUND(m.ed_forecast_2_weight_override::numeric, 0)
                  AND ROUND((m.final_forecast_weight * 100)::numeric, 0)
                      <> ROUND(m.ed_forecast_3_weight_override::numeric, 0)
                THEN 1
                ELSE 0
            END
        ) AS weight_user_override,

        MAX(
            CASE
                WHEN
                    COALESCE(m.demand_forecast_1_weight_override, 0)
                  + COALESCE(m.demand_forecast_2_weight_override, 0)
                  + COALESCE(m.demand_forecast_3_weight_override, 0)
                  + COALESCE(m.demand_forecast_4_weight_override, 0)
                  + COALESCE(m.demand_forecast_5_weight_override, 0)
                  + COALESCE(m.demand_forecast_6_weight_override, 0)
                  + COALESCE(m.demand_forecast_7_weight_override, 0)
                  + COALESCE(m.demand_forecast_8_weight_override, 0)
                  + COALESCE(m.demand_forecast_9_weight_override, 0) > 0
                THEN 1
                ELSE 0
            END
        ) AS method_weight_user_override
    FROM public.ds_matrix m
    WHERE m.demand_class_id = 0
      AND COALESCE(m.exclude, 0) IN (0, 1)
      AND m.item_id IS NOT NULL
      AND m.location_id IS NOT NULL
    GROUP BY
        m.item_id,
        m.location_id
),
monthly_adjusted_data AS (
    SELECT
        d.item_id,
        d.location_id,
        COUNT(*) FILTER (
            WHERE d.adjusted_forecast IS NOT NULL
        ) AS adjusted_forecast_rows,
        COUNT(*) FILTER (
            WHERE d.adjusted_forecast IS NOT NULL
              AND d.expected_demand IS NOT NULL
              AND ROUND(d.adjusted_forecast::numeric, 2)
                  IS DISTINCT FROM ROUND(d.expected_demand::numeric, 2)
        ) AS adjusted_rows_different_from_expected_demand
    FROM public.ds_data d
    CROSS JOIN month_window mw
    WHERE d.sales_date >= mw.target_month_start
      AND d.sales_date < (mw.target_month_start + INTERVAL '24 months')::date
      AND d.demand_class_id = 0
    GROUP BY
        d.item_id,
        d.location_id
),
classified_items AS (
    SELECT
        vi.*,
        COALESCE(vi.effective_hybrid_weight, 0)
        + COALESCE(vi.effective_final_weight, 0) AS active_weight_total,

        COALESCE(vi.effective_hybrid_weight, 0)
        / NULLIF(
            COALESCE(vi.effective_hybrid_weight, 0)
            + COALESCE(vi.effective_final_weight, 0),
            0
        ) AS normalized_hybrid_weight,

        COALESCE(vi.effective_final_weight, 0)
        / NULLIF(
            COALESCE(vi.effective_hybrid_weight, 0)
            + COALESCE(vi.effective_final_weight, 0),
            0
        ) AS normalized_final_weight
    FROM visible_items vi
)
SELECT
    vi.item,
    vi.item_description,
    vi.organization,
    vi.emr_class,
    mw.target_month,
    CASE
        WHEN vi.reconciled = 2 THEN 'Automatically Reconciled'

        WHEN vi.reconciled IN (1, 3)
             AND (
                 COALESCE(mad.adjusted_rows_different_from_expected_demand, 0) > 0
                 OR vi.weight_user_override = 1
                 OR vi.method_weight_user_override = 1
             )
            THEN 'Accepted with user overrides'

        WHEN vi.reconciled IN (1, 3)
            THEN 'Accepted with no user overrides'

        WHEN vi.reconciled = 0
             AND (
                 COALESCE(mad.adjusted_forecast_rows, 0) > 0
                 OR vi.weight_user_override = 1
                 OR vi.method_weight_user_override = 1
             )
            THEN 'Maintained in Exceptions with user overrides'

        WHEN vi.reconciled = 0
            THEN 'Maintained in Exceptions with no user overrides'

        ELSE 'Other'
    END AS month_status,
    CASE
        WHEN COALESCE(vi.volume_adjustment_required, false) = TRUE
            THEN 'Volume-adjusted / scaled blend'

        WHEN COALESCE(vi.active_weight_total, 0) = 0
            THEN 'No active blend weight'

        WHEN vi.normalized_hybrid_weight >= 0.999
            THEN '100% Hybrid Forecast'

        WHEN vi.normalized_final_weight >= 0.999
            THEN '100% Final Forecast'

        ELSE 'Mixed Forecast Source'
    END AS forecast_source_classification
FROM classified_items vi
CROSS JOIN month_window mw
LEFT JOIN monthly_adjusted_data mad
    ON mad.item_id = vi.item_id
   AND mad.location_id = vi.location_id
--WHERE vi.item = '1E944635252'
ORDER BY
    vi.item,
    vi.organization;


/*
===============================================================================
2. High-Level KPI Query
===============================================================================
*/

-- High-Level KPI Query.
-- Set target_month_start to the cycle / End-of-History month being reviewed.
--
-- Population:
--   demand_class_id = 0
--   exclude IN (0, 1)
--   One combination per item_id + location_id
--
-- Original exception workload:
--   Current exceptions (reconciled = 0)
--   plus manually reconciled items (reconciled IN (1, 3)).
--   Automatically reconciled items (reconciled = 2) are excluded.
--
-- User override logic:
--   Reconciled items:
--     1. Adjusted Forecast differs from AF Blended Forecast (expected_demand), OR
--     2. Hybrid / Final Forecast blend weights are overridden, OR
--     3. Hybrid Forecast method blend weights are overridden
--
--   Exception items:
--     1. Any Adjusted Forecast value exists, OR
--     2. Hybrid / Final Forecast blend weights are overridden, OR
--     3. Hybrid Forecast method blend weights are overridden
--
-- Reconciliation override audit:
--   Splits reconciled items by reconciliation method and user-override status.
--   Each method total equals its with-override and without-override counts.
--
-- Forecast source KPIs:
--   Use normalized active Hybrid / Final Forecast weights.
--   Items with volume_adjustment_required = true are counted separately.

WITH params AS (
    SELECT DATE '2026-03-01' AS target_month_start
),
base_items AS (
    SELECT
        m.item_id,
        m.location_id,
        MAX(m.item) AS item,
        MAX(m.emr_abc_class) AS emr_abc_class,
        MAX(m.reconciled) AS reconciled,
        MAX(m.sync_status) AS sync_status,
        MAX(m.emr_demantra_segment_id) AS emr_demantra_segment_id,
        BOOL_OR(
            COALESCE(
                (TO_JSONB(m) ->> 'volume_adjustment_required')::boolean,
                false
            )
        ) AS volume_adjustment_required,

        MAX(
            CASE
                WHEN m.ed_weight_override = TRUE
                  AND ROUND((m.demand_forecast_weight * 100)::numeric, 0)
                      <> ROUND(m.ed_forecast_2_weight_override::numeric, 0)
                  AND ROUND((m.final_forecast_weight * 100)::numeric, 0)
                      <> ROUND(m.ed_forecast_3_weight_override::numeric, 0)
                THEN 1
                ELSE 0
            END
        ) AS weight_user_override,

        MAX(
            CASE
                WHEN
                    COALESCE(m.demand_forecast_1_weight_override, 0)
                  + COALESCE(m.demand_forecast_2_weight_override, 0)
                  + COALESCE(m.demand_forecast_3_weight_override, 0)
                  + COALESCE(m.demand_forecast_4_weight_override, 0)
                  + COALESCE(m.demand_forecast_5_weight_override, 0)
                  + COALESCE(m.demand_forecast_6_weight_override, 0)
                  + COALESCE(m.demand_forecast_7_weight_override, 0)
                  + COALESCE(m.demand_forecast_8_weight_override, 0)
                  + COALESCE(m.demand_forecast_9_weight_override, 0) > 0
                THEN 1
                ELSE 0
            END
        ) AS method_weight_user_override,

        MAX(
            CASE
                WHEN m.ed_weight_override = TRUE
                THEN m.ed_forecast_2_weight_override / 100.0
                ELSE m.demand_forecast_weight
            END
        ) AS effective_hybrid_weight,

        MAX(
            CASE
                WHEN m.ed_weight_override = TRUE
                THEN m.ed_forecast_3_weight_override / 100.0
                ELSE m.final_forecast_weight
            END
        ) AS effective_final_weight

    FROM public.ds_matrix m
    WHERE m.demand_class_id = 0
      AND COALESCE(m.exclude, 0) IN (0, 1)
      AND m.item_id IS NOT NULL
      AND m.location_id IS NOT NULL
    GROUP BY
        m.item_id,
        m.location_id
),
adjusted_data AS (
    SELECT
        d.item_id,
        d.location_id,

        COUNT(*) FILTER (
            WHERE d.adjusted_forecast IS NOT NULL
        ) AS adjusted_forecast_rows,

        COUNT(*) FILTER (
            WHERE d.adjusted_forecast IS NOT NULL
              AND d.expected_demand IS NOT NULL
              AND ROUND(d.adjusted_forecast::numeric, 2)
                  IS DISTINCT FROM ROUND(d.expected_demand::numeric, 2)
        ) AS adjusted_rows_different_from_expected_demand

    FROM public.ds_data d
    CROSS JOIN params p
    WHERE d.sales_date >= p.target_month_start
      AND d.sales_date < (p.target_month_start + INTERVAL '24 months')::date
      AND d.demand_class_id = 0
    GROUP BY
        d.item_id,
        d.location_id
),
status_data AS (
    SELECT
        bi.*,

        COALESCE(bi.effective_hybrid_weight, 0)
        + COALESCE(bi.effective_final_weight, 0) AS active_weight_total,

        COALESCE(bi.effective_hybrid_weight, 0)
        / NULLIF(
            COALESCE(bi.effective_hybrid_weight, 0)
            + COALESCE(bi.effective_final_weight, 0),
            0
        ) AS normalized_hybrid_weight,

        COALESCE(bi.effective_final_weight, 0)
        / NULLIF(
            COALESCE(bi.effective_hybrid_weight, 0)
            + COALESCE(bi.effective_final_weight, 0),
            0
        ) AS normalized_final_weight,

        CASE
            WHEN bi.reconciled >= 1
             AND (
                 COALESCE(ad.adjusted_rows_different_from_expected_demand, 0) > 0
                 OR bi.weight_user_override = 1
                 OR bi.method_weight_user_override = 1
             )
            THEN 1

            WHEN bi.reconciled = 0
             AND (
                 COALESCE(ad.adjusted_forecast_rows, 0) > 0
                 OR bi.weight_user_override = 1
                 OR bi.method_weight_user_override = 1
             )
            THEN 1

            ELSE 0
        END AS has_user_override

    FROM base_items bi
    LEFT JOIN adjusted_data ad
        ON ad.item_id = bi.item_id
       AND ad.location_id = bi.location_id
),
scoped_status_data AS (
    SELECT
        'All ABC Classes'::text AS emr_abc_class_scope,
        sd.*
    FROM status_data sd

    UNION ALL

    SELECT
        COALESCE(sd.emr_abc_class, 'Unclassified') AS emr_abc_class_scope,
        sd.*
    FROM status_data sd
),
kpi_counts AS (
    SELECT
        emr_abc_class_scope,
        COUNT(*)::numeric AS total_items,
        COUNT(*) FILTER (WHERE reconciled = 0)::numeric AS exception_items,
        COUNT(*) FILTER (WHERE reconciled >= 1)::numeric AS reconciled_items,
        COUNT(*) FILTER (WHERE reconciled = 2)::numeric AS automatically_reconciled_items,
        COUNT(*) FILTER (WHERE reconciled IN (1, 3))::numeric AS manually_reconciled_items,
        COUNT(*) FILTER (WHERE reconciled IN (0, 1, 3))::numeric AS original_exception_items,
        COUNT(*) FILTER (
            WHERE reconciled >= 1
              AND has_user_override = 1
        )::numeric AS reconciled_with_override,
        COUNT(*) FILTER (
            WHERE reconciled >= 1
              AND has_user_override = 0
        )::numeric AS reconciled_without_override,
        COUNT(*) FILTER (
            WHERE reconciled = 2
              AND has_user_override = 1
        )::numeric AS automatically_reconciled_with_override,
        COUNT(*) FILTER (
            WHERE reconciled = 2
              AND has_user_override = 0
        )::numeric AS automatically_reconciled_without_override,
        COUNT(*) FILTER (
            WHERE reconciled IN (1, 3)
              AND has_user_override = 1
        )::numeric AS manually_reconciled_with_override,
        COUNT(*) FILTER (
            WHERE reconciled IN (1, 3)
              AND has_user_override = 0
        )::numeric AS manually_reconciled_without_override,
        COUNT(*) FILTER (
            WHERE reconciled = 0
              AND has_user_override = 1
        )::numeric AS exceptions_with_override,
        COUNT(*) FILTER (
            WHERE reconciled = 0
              AND has_user_override = 0
        )::numeric AS exceptions_without_override,
        COUNT(*) FILTER (
            WHERE reconciled = 0
              AND COALESCE(volume_adjustment_required, false) = false
              AND normalized_hybrid_weight >= 0.999
        )::numeric AS exceptions_hybrid,
        COUNT(*) FILTER (
            WHERE reconciled >= 1
              AND COALESCE(volume_adjustment_required, false) = false
              AND normalized_hybrid_weight >= 0.999
        )::numeric AS reconciled_hybrid,
        COUNT(*) FILTER (
            WHERE reconciled = 0
              AND COALESCE(volume_adjustment_required, false) = false
              AND normalized_final_weight >= 0.999
        )::numeric AS exceptions_final,
        COUNT(*) FILTER (
            WHERE reconciled >= 1
              AND COALESCE(volume_adjustment_required, false) = false
              AND normalized_final_weight >= 0.999
        )::numeric AS reconciled_final,
        COUNT(*) FILTER (
            WHERE reconciled = 0
              AND COALESCE(volume_adjustment_required, false) = false
              AND active_weight_total > 0
              AND normalized_hybrid_weight < 0.999
              AND normalized_final_weight < 0.999
        )::numeric AS exceptions_mixed,
        COUNT(*) FILTER (
            WHERE reconciled >= 1
              AND COALESCE(volume_adjustment_required, false) = false
              AND active_weight_total > 0
              AND normalized_hybrid_weight < 0.999
              AND normalized_final_weight < 0.999
        )::numeric AS reconciled_mixed,
        COUNT(*) FILTER (
            WHERE reconciled = 0
              AND COALESCE(volume_adjustment_required, false) = true
        )::numeric AS exceptions_scaled,
        COUNT(*) FILTER (
            WHERE reconciled >= 1
              AND COALESCE(volume_adjustment_required, false) = true
        )::numeric AS reconciled_scaled,
        COUNT(*) FILTER (
            WHERE reconciled = 0
              AND COALESCE(volume_adjustment_required, false) = false
              AND active_weight_total = 0
        )::numeric AS exceptions_no_weight,
        COUNT(*) FILTER (
            WHERE reconciled >= 1
              AND COALESCE(volume_adjustment_required, false) = false
              AND active_weight_total = 0
        )::numeric AS reconciled_no_weight
    FROM scoped_status_data
    GROUP BY
        emr_abc_class_scope
)
SELECT
    TO_CHAR(p.target_month_start, 'Mon-YY') AS target_month,
    kc.emr_abc_class_scope AS emr_abc_class,
    metric.number,
    metric.group_name AS "group",
    metric.count
FROM kpi_counts kc
CROSS JOIN params p
CROSS JOIN LATERAL (
    VALUES
        (1, 'Total Items Count', kc.total_items),
        (2, 'Total Items in Exceptions', kc.exception_items),
        (3, 'Total Combinations in Reconciled', kc.reconciled_items),
        (
            4,
            'Exception Rate (%)',
            ROUND(100.0 * kc.exception_items / NULLIF(kc.total_items, 0), 2)
        ),
        (
            5,
            'Reconciliation Rate (%)',
            ROUND(100.0 * kc.reconciled_items / NULLIF(kc.total_items, 0), 2)
        ),
        (6, 'Automatically Reconciled Items Count', kc.automatically_reconciled_items),
        (7, 'Manually Reconciled Items Count', kc.manually_reconciled_items),
        (
            8,
            'Auto Reconciliation Share (%)',
            ROUND(
                100.0 * kc.automatically_reconciled_items
                / NULLIF(kc.reconciled_items, 0),
                2
            )
        ),
        (
            9,
            'Manual Reconciliation Share (%)',
            ROUND(
                100.0 * kc.manually_reconciled_items
                / NULLIF(kc.reconciled_items, 0),
                2
            )
        ),
        (10, 'Reconciled Items With Planner Adjusted Forecast', kc.reconciled_with_override),
        (11, 'Reconciled Items Without Planner Adjusted Forecast', kc.reconciled_without_override),
        (12, 'Exception Items With Planner Adjusted Forecast', kc.exceptions_with_override),
        (13, 'Exception Items Without Planner Adjusted Forecast', kc.exceptions_without_override),
        (14, 'Exceptions Items Driven 100% by Hybrid Forecast', kc.exceptions_hybrid),
        (15, 'Reconciled Items Driven 100% by Hybrid Forecast', kc.reconciled_hybrid),
        (16, 'Exceptions Items Driven 100% by Final Forecast', kc.exceptions_final),
        (17, 'Reconciled Items With 100% Final Forecast', kc.reconciled_final),
        (18, 'Exceptions Items With Mixed Forecast Source', kc.exceptions_mixed),
        (19, 'Reconciled Items With Mixed Forecast Source', kc.reconciled_mixed),
        (20, 'Exceptions Items With Volume-Adjusted / Scaled Blend', kc.exceptions_scaled),
        (21, 'Reconciled Items With Volume-Adjusted / Scaled Blend', kc.reconciled_scaled),
        (22, 'Exceptions Items With No Active Blend Weight', kc.exceptions_no_weight),
        (23, 'Reconciled Items With No Active Blend Weight', kc.reconciled_no_weight),
        (24, 'Original Exception Items Count', kc.original_exception_items),
        (
            25,
            'Automatically Reconciled Items With User Overrides',
            kc.automatically_reconciled_with_override
        ),
        (
            26,
            'Automatically Reconciled Items Without User Overrides',
            kc.automatically_reconciled_without_override
        ),
        (
            27,
            'Manually Reconciled Items With User Overrides',
            kc.manually_reconciled_with_override
        ),
        (
            28,
            'Manually Reconciled Items Without User Overrides',
            kc.manually_reconciled_without_override
        )
) AS metric(number, group_name, count)
ORDER BY
    CASE
        WHEN kc.emr_abc_class_scope = 'All ABC Classes' THEN 0
        ELSE 1
    END,
    kc.emr_abc_class_scope,
    metric.number;

/*
===============================================================================
3. ABC Class Breakdown
===============================================================================
*/

-- ABC Class Breakdown.
-- Population:
--   demand_class_id = 0
--   exclude IN (0, 1)
--   One combination per item_id + location_id
--
-- Reconciled:
--   reconciled >= 1
--
-- Exceptions:
--   reconciled = 0
--
-- Reconciliation Rate:
--   Reconciled Items / Total Items * 100

WITH base_items AS (
    SELECT
        m.item_id,
        m.location_id,
        MAX(m.emr_abc_class) AS emr_abc_class,
        MAX(m.reconciled) AS reconciled
    FROM public.ds_matrix m
    WHERE m.demand_class_id = 0
      AND COALESCE(m.exclude, 0) IN (0, 1)
      AND m.item_id IS NOT NULL
      AND m.location_id IS NOT NULL
    GROUP BY
        m.item_id,
        m.location_id
)
SELECT
    COALESCE(emr_abc_class, 'NULL') AS emr_abc_class,
    COUNT(*) AS number_of_items,
    COUNT(*) FILTER (
        WHERE reconciled >= 1
    ) AS number_of_reconciled_items,
    COUNT(*) FILTER (
        WHERE reconciled = 0
    ) AS number_of_exception_items,
    ROUND(
        100.0 * COUNT(*) FILTER (
            WHERE reconciled >= 1
        )
        / NULLIF(COUNT(*), 0),
        2
    ) AS reconciliation_rate
FROM base_items
GROUP BY
    emr_abc_class
ORDER BY
    emr_abc_class;

/*
===============================================================================
4. Part Level Reports - Total visible items
===============================================================================
*/

----------------------
-- Part Level Reports
----------------------
-- Total visible items.
SELECT
    COUNT(DISTINCT item_id) AS total_items,
    COUNT(DISTINCT (item_id, location_id)) AS total_item_location_combinations
FROM public.ds_matrix
WHERE demand_class_id = 0
  AND COALESCE(exclude, 0) IN (0, 1)
  AND item_id IS NOT NULL
  AND location_id IS NOT NULL;
