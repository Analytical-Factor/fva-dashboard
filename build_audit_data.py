from __future__ import annotations

import json
from collections import Counter
from datetime import datetime
from pathlib import Path

from openpyxl import load_workbook


ROOT = Path(__file__).resolve().parent
OUTPUT_PATH = ROOT / "audit-data.js"
SOURCE_COLORS = {
    "Volume-adjusted / scaled blend": "#0b7f82",
    "Mixed Forecast Source": "#2f6fed",
    "100% Hybrid Forecast": "#e49a3a",
    "100% Final Forecast": "#99a9b8",
    "No active blend weight": "#b55f62",
}

RECONCILED_STATUSES = {
    "Automatically Reconciled",
    "Accepted with user overrides",
    "Accepted with no user overrides",
}
EXCEPTION_STATUSES = {
    "Maintained in Exceptions with user overrides",
    "Maintained in Exceptions with no user overrides",
}


def find_row(rows: list[tuple], label: str) -> int:
    for index, row in enumerate(rows):
        if row and row[0] == label:
            return index
    raise ValueError(f"Missing KPI section or row: {label}")


def section(rows: list[tuple], start_label: str, end_label: str | None) -> list[tuple]:
    start = find_row(rows, start_label) + 1
    end = find_row(rows, end_label) if end_label else len(rows)
    return rows[start:end]


def keyed_rows(rows: list[tuple]) -> dict[str, tuple]:
    return {
        str(row[0]): row
        for row in rows
        if row and row[0] is not None and row[1] is not None
    }


def as_int(value: object) -> int:
    return int(value or 0)


def canonical_source(value: object) -> str:
    label = str(value)
    if label.lower() == "volume-adjusted / scaled blend":
        return "Volume-adjusted / scaled blend"
    return label


def load_workbook_data(path: Path) -> tuple[dict, list[list]]:
    workbook = load_workbook(path, read_only=True, data_only=True)
    try:
        kpi_rows = list(workbook["KPIs"].iter_rows(values_only=True))
        part_sheet = workbook["Part Level Breakdown"]

        overall = keyed_rows(
            section(kpi_rows, "1. Overall Status Summary", "2. Reconciliation Type")
        )
        reconciliation = keyed_rows(
            section(kpi_rows, "2. Reconciliation Type", "3. Planner Adjusted Forecast")
        )
        planner = keyed_rows(
            section(kpi_rows, "3. Planner Adjusted Forecast", "4. Forecast Source Distribution")
        )
        source_rows = keyed_rows(
            section(kpi_rows, "4. Forecast Source Distribution", "5. ABC Class Breakdown")
        )
        abc_rows = keyed_rows(section(kpi_rows, "5. ABC Class Breakdown", None))

        parts: list[list] = []
        target_months: set[str] = set()
        for row in part_sheet.iter_rows(min_row=2, values_only=True):
            if not row[0]:
                continue
            item, description, abc_class, target_month, status, source = row[:6]
            target_months.add(str(target_month))
            parts.append(
                [
                    str(item),
                    str(description or ""),
                    str(abc_class or "Unclassified"),
                    str(status),
                    canonical_source(source),
                    "with user overrides" in str(status).lower(),
                ]
            )

        if len(target_months) != 1:
            raise ValueError(f"{path.name}: expected one target month, found {target_months}")

        target_month_text = target_months.pop()
        target_month = datetime.strptime(target_month_text, "%b-%y")
        total = as_int(overall["Total Items"][1])
        reconciled = as_int(overall["Reconciled"][1])
        exceptions = as_int(overall["Exceptions"][1])
        automatic = as_int(reconciliation["Automatically Reconciled"][1])
        manual = as_int(reconciliation["Manually Reconciled"][1])

        planner_data = {
            "reconciled": {
                "withOverrides": as_int(planner["Reconciled"][1]),
                "withoutOverrides": as_int(planner["Reconciled"][2]),
            },
            "exceptions": {
                "withOverrides": as_int(planner["Exceptions"][1]),
                "withoutOverrides": as_int(planner["Exceptions"][2]),
            },
        }

        sources = []
        for label, row in source_rows.items():
            if label in {"Forecast Source", "Total"}:
                continue
            label = canonical_source(label)
            sources.append(
                {
                    "label": label,
                    "exceptions": as_int(row[1]),
                    "reconciled": as_int(row[2]),
                    "count": as_int(row[3]),
                    "color": SOURCE_COLORS.get(label, "#647985"),
                }
            )

        abc = []
        for label, row in abc_rows.items():
            if label == "emr_abc_class":
                continue
            abc.append(
                {
                    "label": label,
                    "total": as_int(row[1]),
                    "reconciled": as_int(row[2]),
                    "exceptions": as_int(row[3]),
                }
            )

        month = {
            "key": target_month.strftime("%Y-%m"),
            "label": target_month.strftime("%b"),
            "year": target_month.strftime("%Y"),
            "total": total,
            "reconciled": reconciled,
            "exceptions": exceptions,
            "automatic": automatic,
            "manual": manual,
            "planner": planner_data,
            "overrides": (
                planner_data["reconciled"]["withOverrides"]
                + planner_data["exceptions"]["withOverrides"]
            ),
            "sources": sources,
            "abc": abc,
        }

        validate_month(path.name, month, parts)
        return month, parts
    finally:
        workbook.close()


def validate_month(filename: str, month: dict, parts: list[list]) -> None:
    status_counts = Counter(part[3] for part in parts)
    unknown_statuses = set(status_counts) - RECONCILED_STATUSES - EXCEPTION_STATUSES
    if unknown_statuses:
        raise ValueError(f"{filename}: unknown statuses: {sorted(unknown_statuses)}")

    reconciled_count = sum(status_counts[status] for status in RECONCILED_STATUSES)
    exception_count = sum(status_counts[status] for status in EXCEPTION_STATUSES)
    automatic_count = status_counts["Automatically Reconciled"]
    manual_count = reconciled_count - automatic_count
    source_counts = Counter(part[4] for part in parts)
    abc_total_counts = Counter(part[2] for part in parts)
    abc_reconciled_counts = Counter(
        part[2] for part in parts if part[3] in RECONCILED_STATUSES
    )

    checks = {
        "part rows": (len(parts), month["total"]),
        "reconciled rows": (reconciled_count, month["reconciled"]),
        "exception rows": (exception_count, month["exceptions"]),
        "automatic rows": (automatic_count, month["automatic"]),
        "manual rows": (manual_count, month["manual"]),
        "reconciled planner total": (
            month["planner"]["reconciled"]["withOverrides"]
            + month["planner"]["reconciled"]["withoutOverrides"],
            month["reconciled"],
        ),
        "exception planner total": (
            month["planner"]["exceptions"]["withOverrides"]
            + month["planner"]["exceptions"]["withoutOverrides"],
            month["exceptions"],
        ),
    }

    for source in month["sources"]:
        checks[f"source {source['label']}"] = (
            source_counts[source["label"]],
            source["count"],
        )

    for row in month["abc"]:
        checks[f"ABC {row['label']} total"] = (
            abc_total_counts[row["label"]],
            row["total"],
        )
        checks[f"ABC {row['label']} reconciled"] = (
            abc_reconciled_counts[row["label"]],
            row["reconciled"],
        )

    failures = [
        f"{name}: actual={actual}, KPI={expected}"
        for name, (actual, expected) in checks.items()
        if actual != expected
    ]
    if failures:
        raise ValueError(f"{filename} validation failed: " + "; ".join(failures))


def main() -> None:
    workbook_paths = sorted(ROOT.glob("EMR - Audit Reports - *.xlsx"))
    if not workbook_paths:
        raise SystemExit("No audit report workbooks found.")

    months = []
    parts_by_month = {}
    for workbook_path in workbook_paths:
        month, parts = load_workbook_data(workbook_path)
        months.append(month)
        parts_by_month[month["key"]] = parts

    months.sort(key=lambda month: month["key"])
    data = {
        "months": months,
        "partsByMonth": {month["key"]: parts_by_month[month["key"]] for month in months},
    }

    payload = json.dumps(data, ensure_ascii=True, separators=(",", ":"))
    OUTPUT_PATH.write_text(
        "// Generated from the audit workbooks by build_audit_data.py.\n"
        f"window.auditDashboardData={payload};\n",
        encoding="utf-8",
    )

    print(f"Generated {OUTPUT_PATH.name} from {len(months)} workbooks.")
    for month in months:
        print(
            f"{month['label']} {month['year']}: "
            f"{month['total']:,} items, {month['reconciled']:,} reconciled, "
            f"{len(parts_by_month[month['key']]):,} part rows"
        )


if __name__ == "__main__":
    main()
