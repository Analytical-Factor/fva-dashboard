# Demand Planning Audit Dashboard

This standalone dashboard reads the six monthly audit workbooks in this repository and presents their KPI and Part-Level data in one responsive page.

## Included Data

- January 2026
- February 2026
- March 2026
- April 2026
- May 2026
- June 2026 (from the workbook named `EMR - Audit Reports - June 2025.xlsx`)

The KPI view includes overall status, reconciliation type, planner adjustments, forecast-source distribution, and ABC-class breakdown.

The Part-Level view supports:

- One specific month, any combination of months, or all available months
- Selected monthly statuses and forecast sources in one table
- Search, status/source/ABC filters, pagination, and CSV export
- Per-item counts across the latest six available audit months for automatically reconciled, adjusted, and manually accepted periods

`Adjusted` counts Part-Level statuses containing `with user overrides`. The source workbooks do not expose an independent override flag for rows classified as `Automatically Reconciled`, so those rows cannot be attributed as item-level adjustments. The aggregate Planner Overrides KPI remains the exact value from the KPI sheet. `Manually accepted` counts both accepted statuses, with and without a user override, and excludes automatic reconciliation. The six-month metrics use all six available audit months.

## Open The Dashboard

Open `login.html` or `index.html` in a browser and sign in with the configured static credentials. The latest available month is selected by default.

Authentication is intentionally client-side and session-only. It does not provide secure access control because the credentials and validation logic are visible in the static files. Closing the browser tab or selecting Log out ends the session.

## Refresh The Data

After adding or replacing an `EMR - Audit Reports - *.xlsx` workbook, regenerate the browser data:

```powershell
python build_audit_data.py
```

The generator requires `openpyxl`. It validates workbook totals before replacing `audit-data.js` and stops with an error if KPI totals do not reconcile with the Part-Level rows.

Run the independent data and browser checks after refreshing the data:

```powershell
python validate_dashboard_data.py
node validate_dashboard_ui.js
```

## Files

- `index.html`: GitHub Pages entry point, dashboard layout, and interactions
- `login.html`: static sign-in page
- `shared.css`: dashboard styling
- `audit-data.js`: generated KPI and Part-Level browser data
- `build_audit_data.py`: workbook extraction and validation
- `validate_dashboard_data.py`: independent Excel-to-dashboard data validation
- `validate_dashboard_ui.js`: browser rendering, interaction, and export validation
- `EMR - Audit Reports - *.xlsx`: source audit workbooks
