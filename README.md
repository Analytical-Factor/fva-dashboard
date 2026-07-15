# Demand Planning Audit Dashboard

This standalone dashboard reads the five monthly audit workbooks in this repository and presents their KPI and Part-Level data in one responsive page.

## Included Data

- January 2026
- February 2026
- March 2026
- April 2026
- May 2026

The KPI view includes overall status, reconciliation type, planner adjustments, forecast-source distribution, and ABC-class breakdown.

The Part-Level view supports:

- One specific month, any combination of months, or all available months
- Selected monthly statuses and forecast sources in one table
- Search, status/source/ABC filters, pagination, and CSV export
- Per-item counts across the latest six available audit months for automatically reconciled, adjusted, and manually accepted periods

`Adjusted` counts statuses containing `with user overrides`. `Manually accepted` counts both accepted statuses, with and without a user override, and excludes automatic reconciliation. This repository currently contains five audit months, so the six-month metrics use all five available months and will automatically expand to six when another workbook is added.

## Open The Dashboard

Open `index.html` in a browser. The latest available month is selected by default.

## Refresh The Data

After adding or replacing an `EMR - Audit Reports - *.xlsx` workbook, regenerate the browser data:

```powershell
python build_audit_data.py
```

The generator requires `openpyxl`. It validates workbook totals before replacing `audit-data.js` and stops with an error if KPI totals do not reconcile with the Part-Level rows.

## Files

- `index.html`: GitHub Pages entry point, dashboard layout, and interactions
- `shared.css`: dashboard styling
- `audit-data.js`: generated KPI and Part-Level browser data
- `build_audit_data.py`: workbook extraction and validation
- `EMR - Audit Reports - *.xlsx`: source audit workbooks
