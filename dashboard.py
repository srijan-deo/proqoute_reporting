"""
PQ.ai Performance Dashboard — Flask app.

Reads the latest workbook uploaded to GCS by report.py/main_job.py
(gs://<bucket>/<reports_prefix>/*.xlsx) and serves an interactive dashboard:
KPI cards (from the Summary sheet) plus combo bar+line charts per bucket
table (ACV Bucket, Sale Price Bucket, etc.) from the two Detail sheets,
mirroring the exact layout report.py writes.

Usage:
    python dashboard.py
    -> open http://127.0.0.1:8080

Config (env vars):
    GCS_BUCKET_NAME     — required. Bucket the reports are uploaded to.
    GCS_REPORTS_PREFIX  — default "reports/pq_ai_weekly_report/"
    BQ_KEY_PATH         — optional. Local service-account JSON for GCS auth.
                          On Cloud Run, leave unset — Application Default
                          Credentials (the runtime service account) is used.

ASSUMPTIONS (verify / adjust to match your actual "Summary (Sheet 1)" query
columns — I only had report.py's formatting logic + your screenshot to infer
these, not the real column names):
    - Summary sheet has a "breakout" column with values matching the detail
      sheet labels ("BluCar ex-TFSS", "Insurance + TFSS") and a "period"
      column with values in {"Past Week", "Past Month", "Trailing 3 Months"}.
    - Summary sheet has columns: Units Sold, PQ Coverage, PQ_ai Coverage,
      PQ Error %, PQ_ai Error %, PQ MAE, PQ_ai MAE, PQ MAPE, PQ_ai MAPE.
    - If your actual column names differ, tweak KPI_CARD_SPECS below —
      the app does a case-insensitive substring match so minor differences
      ("PQai" vs "PQ_ai") are usually fine, but wildly different names won't be.
"""

import os
import tempfile
from flask import Flask, render_template_string, jsonify, request
from openpyxl import load_workbook

from gcs_utils import get_latest_blob_name, download_blob_to_file

pwd = os.path.dirname(os.path.abspath(__file__))

GCS_BUCKET = os.environ.get("GCS_BUCKET_NAME")
GCS_REPORTS_PREFIX = os.environ.get("GCS_REPORTS_PREFIX", "reports/pq_ai_weekly_report/")
KEY_PATH = os.environ.get("BQ_KEY_PATH")  # None on Cloud Run -> uses ADC

SUMMARY_SHEET = "PQ.ai Summary"
DETAIL_SHEETS = {
    "BluCar ex-TFSS": "BluCar ex-TFSS PQ.ai Detail",
    "Insurance + TFSS": "Insurance + TFSS PQ.ai Detail",
}
PERIODS = ["Past Week", "Past Month", "Trailing 3 Months"]

KPI_CARD_SPECS = [
    ("Units Sold", "units sold", None),
    ("PQ Coverage", "pq coverage", "pq"),
    ("PQ_ai Coverage", "pq_ai coverage", "pqai"),
    ("PQ Error %", "pq error", "pq"),
    ("PQ_ai Error %", "pq_ai error", "pqai"),
    ("PQ MAE", "pq mae", "pq"),
    ("PQ_ai MAE", "pq_ai mae", "pqai"),
    ("PQ MAPE", "pq mape", "pq"),
    ("PQ_ai MAPE", "pq_ai mape", "pqai"),
]

app = Flask(__name__)

# Simple in-memory cache: avoid re-downloading from GCS on every single
# request. Keyed on the blob's last-updated timestamp — if a newer report
# lands in GCS, the cache naturally invalidates on the next check.
_cache = {"blob_name": None, "updated": None, "local_path": None}


def _fetch_latest_workbook_path():
    if not GCS_BUCKET:
        raise RuntimeError(
            "GCS_BUCKET_NAME is not set. The dashboard needs to know which "
            "bucket to read reports from."
        )

    blob_name, updated = get_latest_blob_name(GCS_BUCKET, GCS_REPORTS_PREFIX, key_path=KEY_PATH)

    if _cache["blob_name"] == blob_name and _cache["updated"] == updated and _cache["local_path"]:
        return _cache["local_path"]

    # New/updated report — download fresh, replacing any previous temp file.
    if _cache["local_path"] and os.path.exists(_cache["local_path"]):
        os.remove(_cache["local_path"])

    tmp = tempfile.NamedTemporaryFile(suffix=".xlsx", delete=False)
    tmp.close()
    download_blob_to_file(GCS_BUCKET, blob_name, tmp.name, key_path=KEY_PATH)

    _cache.update({"blob_name": blob_name, "updated": updated, "local_path": tmp.name})
    return tmp.name


def _find_col(columns, needle):
    """Case-insensitive substring match; returns the matching column name or None."""
    needle = needle.lower()
    for c in columns:
        if needle in str(c).lower():
            return c
    return None


def _parse_summary(ws):
    """Row 1 = headers, rows 2+ = data (matches _update_summary in report.py)."""
    headers = []
    for cell in ws[1]:
        if cell.value is None:
            break
        headers.append(cell.value)

    rows = []
    for row in ws.iter_rows(min_row=2, max_col=len(headers)):
        if all(c.value is None for c in row):
            continue
        rows.append({headers[i]: row[i].value for i in range(len(headers))})
    return headers, rows


def _parse_detail_sheet(ws):
    """
    Reverse of _write_sub_table / _update_detail_sheet in report.py:
    each sub-table is: header row (col B = bucket name, col C.. = metric names),
    then for each period: a period row (col A only), then data rows
    (col B = bucket value, col C.. = metric values). A blank row separates tables.

    Returns: dict of { bucket_col_name: { period: [ {bucket, metric: val, ...}, ... ] } }
    """
    tables = {}
    max_row = ws.max_row
    max_col = ws.max_column
    row_idx = 3  # data starts at row 3 in detail sheets

    while row_idx <= max_row:
        col_a = ws.cell(row_idx, 1).value
        col_b = ws.cell(row_idx, 2).value

        if col_a is None and col_b is None:
            row_idx += 1
            continue

        # Header row for a new sub-table
        bucket_col = col_b
        metric_cols = []
        ci = 3
        while ci <= max_col:
            v = ws.cell(row_idx, ci).value
            if v is None:
                break
            metric_cols.append(v)
            ci += 1
        row_idx += 1

        table_data = {p: [] for p in PERIODS}
        current_period = None

        while row_idx <= max_row:
            col_a = ws.cell(row_idx, 1).value
            col_b = ws.cell(row_idx, 2).value

            if col_a is None and col_b is None:
                row_idx += 1
                break  # blank gap -> next sub-table

            if col_a is not None and col_b is None:
                current_period = col_a
                if current_period not in table_data:
                    table_data[current_period] = []
                row_idx += 1
                continue

            # data row
            entry = {"bucket": col_b}
            for mi, mc in enumerate(metric_cols):
                entry[mc] = ws.cell(row_idx, 3 + mi).value
            if current_period is not None:
                table_data[current_period].append(entry)
            row_idx += 1

        tables[bucket_col] = table_data

    return tables


def load_dashboard_data():
    path = _fetch_latest_workbook_path()
    wb = load_workbook(path, data_only=True)

    summary_headers, summary_rows = _parse_summary(wb[SUMMARY_SHEET])

    detail_data = {}
    for label, sheet_name in DETAIL_SHEETS.items():
        if sheet_name in wb.sheetnames:
            detail_data[label] = _parse_detail_sheet(wb[sheet_name])

    wb.close()
    return {
        "file": os.path.basename(_cache["blob_name"]) if _cache["blob_name"] else os.path.basename(path),
        "summary_headers": summary_headers,
        "summary_rows": summary_rows,
        "detail_data": detail_data,
    }


def get_kpis(summary_headers, summary_rows, breakout_label, period):
    breakout_col = _find_col(summary_headers, "breakout") or _find_col(summary_headers, "segment")
    period_col = _find_col(summary_headers, "period")

    match = None
    for row in summary_rows:
        b_ok = (breakout_col is None) or (
            str(row.get(breakout_col, "")).strip().lower() == breakout_label.strip().lower()
        )
        p_ok = (period_col is None) or (
            str(row.get(period_col, "")).strip().lower() == period.strip().lower()
        )
        if b_ok and p_ok:
            match = row
            break

    kpis = []
    for label, needle, group in KPI_CARD_SPECS:
        col = _find_col(summary_headers, needle)
        val = match.get(col) if (match and col) else None
        kpis.append({"label": label, "value": _fmt_value(label, val), "group": group})
    return kpis


def _fmt_value(label, val):
    if val is None:
        return "—"
    try:
        f = float(val)
    except (TypeError, ValueError):
        return str(val)

    lower = label.lower()
    if "%" in label or "coverage" in lower or "mape" in lower or "error" in lower:
        return f"{f * 100:.1f}%" if abs(f) <= 1.5 else f"{f:.1f}%"
    if "units" in lower:
        return f"{f:,.0f}"
    return f"${f:,.0f}"


@app.route("/")
def index():
    return render_template_string(PAGE_TEMPLATE, sheets=list(DETAIL_SHEETS.keys()), periods=PERIODS)


@app.route("/healthz")
def healthz():
    """Basic liveness check for Cloud Run."""
    return jsonify({"status": "ok"})


@app.route("/api/data")
def api_data():
    sheet_label = request.args.get("sheet", list(DETAIL_SHEETS.keys())[0])
    period = request.args.get("period", PERIODS[1])

    try:
        data = load_dashboard_data()
    except FileNotFoundError as e:
        return jsonify({"error": str(e)}), 404

    kpis = get_kpis(data["summary_headers"], data["summary_rows"], sheet_label, period)

    charts = {}
    detail = data["detail_data"].get(sheet_label, {})
    for bucket_col, by_period in detail.items():
        rows = by_period.get(period, [])
        if not rows:
            continue
        metric_names = [k for k in rows[0].keys() if k != "bucket"]
        units_col = _find_col(metric_names, "units sold") or _find_col(metric_names, "volume")
        pq_mae_col = next((m for m in metric_names if m.lower() == "pq mae"), None) or _find_col(
            [m for m in metric_names if "pq_ai" not in m.lower()], "mae"
        )
        pqai_mae_col = _find_col(metric_names, "pq_ai mae") or _find_col(metric_names, "pqai mae")
        pq_err_col = next((m for m in metric_names if m.lower() == "pq error %"), None) or _find_col(
            [m for m in metric_names if "pq_ai" not in m.lower()], "error"
        )
        pqai_err_col = _find_col(metric_names, "pq_ai error") or _find_col(metric_names, "pqai error")

        charts[bucket_col] = {
            "labels": [r["bucket"] for r in rows],
            "units": [r.get(units_col) for r in rows] if units_col else [],
            "pq_mae": [r.get(pq_mae_col) for r in rows] if pq_mae_col else [],
            "pqai_mae": [r.get(pqai_mae_col) for r in rows] if pqai_mae_col else [],
            "pq_error": [
                (r.get(pq_err_col) or 0) * 100 if abs(r.get(pq_err_col) or 0) <= 1.5 else r.get(pq_err_col)
                for r in rows
            ] if pq_err_col else [],
            "pqai_error": [
                (r.get(pqai_err_col) or 0) * 100 if abs(r.get(pqai_err_col) or 0) <= 1.5 else r.get(pqai_err_col)
                for r in rows
            ] if pqai_err_col else [],
        }

    return jsonify({"file": data["file"], "kpis": kpis, "charts": charts})


PAGE_TEMPLATE = """
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<title>PQ.ai Performance Dashboard</title>
<script src="https://cdnjs.cloudflare.com/ajax/libs/Chart.js/4.4.1/chart.umd.min.js"></script>
<style>
  * { box-sizing: border-box; }
  body { font-family: -apple-system, Segoe UI, Roboto, Arial, sans-serif; margin: 0; background: #f4f6f8; color: #1a1a2e; }
  header { background: #16213e; color: #fff; padding: 20px 32px; }
  header h1 { margin: 0; font-size: 22px; }
  header p { margin: 4px 0 0; color: #b8c1d9; font-size: 13px; }
  .controls { display: flex; gap: 16px; padding: 16px 32px; background: #fff; border-bottom: 1px solid #e2e6ea; align-items: center; }
  .controls label { font-weight: 600; font-size: 13px; margin-right: 6px; }
  select { padding: 6px 10px; border-radius: 6px; border: 1px solid #ccc; font-size: 13px; }
  .kpis { display: grid; grid-template-columns: repeat(auto-fit, minmax(180px, 1fr)); gap: 14px; padding: 20px 32px; }
  .kpi-card { background: #fff; border-radius: 8px; padding: 14px 16px; box-shadow: 0 1px 3px rgba(0,0,0,.08); border-top: 4px solid #d8dde3; }
  .kpi-card.pq { border-top-color: #4472C4; }
  .kpi-card.pqai { border-top-color: #70AD47; }
  .kpi-label { font-size: 11px; letter-spacing: .04em; color: #6b7280; text-transform: uppercase; font-weight: 700; }
  .kpi-value { font-size: 24px; font-weight: 700; margin-top: 4px; }
  .charts { display: grid; grid-template-columns: repeat(auto-fit, minmax(420px, 1fr)); gap: 20px; padding: 0 32px 32px; }
  .chart-card { background: #fff; border-radius: 8px; padding: 16px; box-shadow: 0 1px 3px rgba(0,0,0,.08); }
  .chart-card h3 { margin: 0 0 10px; font-size: 15px; }
  .meta { padding: 0 32px; font-size: 12px; color: #6b7280; }
  .error { padding: 24px 32px; color: #b91c1c; }
</style>
</head>
<body>
<header>
  <h1>PQ.ai Performance Dashboard</h1>
  <p id="subtitle">Loading...</p>
</header>
<div class="controls">
  <div>
    <label for="sheetSelect">Segment:</label>
    <select id="sheetSelect">
      {% for s in sheets %}<option value="{{ s }}">{{ s }}</option>{% endfor %}
    </select>
  </div>
  <div>
    <label for="periodSelect">Period:</label>
    <select id="periodSelect">
      {% for p in periods %}<option value="{{ p }}" {% if p == "Past Month" %}selected{% endif %}>{{ p }}</option>{% endfor %}
    </select>
  </div>
</div>
<div id="errorBanner" class="error" style="display:none;"></div>
<div class="kpis" id="kpiContainer"></div>
<div class="charts" id="chartContainer"></div>
<div class="meta" id="fileMeta"></div>

<script>
const chartInstances = {};

async function loadData() {
  const sheet = document.getElementById('sheetSelect').value;
  const period = document.getElementById('periodSelect').value;
  const res = await fetch(`/api/data?sheet=${encodeURIComponent(sheet)}&period=${encodeURIComponent(period)}`);
  const data = await res.json();

  const errorBanner = document.getElementById('errorBanner');
  if (data.error) {
    errorBanner.style.display = 'block';
    errorBanner.textContent = 'No report found yet: ' + data.error;
    document.getElementById('kpiContainer').innerHTML = '';
    document.getElementById('chartContainer').innerHTML = '';
    return;
  }
  errorBanner.style.display = 'none';

  document.getElementById('subtitle').textContent = `${sheet} | ${period}`;
  document.getElementById('fileMeta').textContent = `Source: ${data.file}`;

  const kpiContainer = document.getElementById('kpiContainer');
  kpiContainer.innerHTML = '';
  data.kpis.forEach(k => {
    const div = document.createElement('div');
    div.className = 'kpi-card' + (k.group ? ' ' + k.group : '');
    div.innerHTML = `<div class="kpi-label">${k.label}</div><div class="kpi-value">${k.value}</div>`;
    kpiContainer.appendChild(div);
  });

  const chartContainer = document.getElementById('chartContainer');
  chartContainer.innerHTML = '';
  Object.entries(data.charts).forEach(([bucketName, c]) => {
    const cardId = 'chart_' + bucketName.replace(/[^a-zA-Z0-9]/g, '_');
    const card = document.createElement('div');
    card.className = 'chart-card';
    card.innerHTML = `<h3>${bucketName}</h3><canvas id="${cardId}"></canvas>`;
    chartContainer.appendChild(card);

    const ctx = document.getElementById(cardId).getContext('2d');
    if (chartInstances[cardId]) chartInstances[cardId].destroy();
    chartInstances[cardId] = new Chart(ctx, {
      data: {
        labels: c.labels,
        datasets: [
          { type: 'bar', label: 'Units Sold', data: c.units, backgroundColor: '#d9d9d9', yAxisID: 'y', order: 3 },
          { type: 'bar', label: 'PQ MAE', data: c.pq_mae, backgroundColor: '#4472C4', yAxisID: 'y', order: 2 },
          { type: 'bar', label: 'PQ_ai MAE', data: c.pqai_mae, backgroundColor: '#70AD47', yAxisID: 'y', order: 2 },
          { type: 'line', label: 'PQ Error %', data: c.pq_error, borderColor: '#4472C4', borderDash: [5,3], yAxisID: 'y1', order: 1, tension: 0.2 },
          { type: 'line', label: 'PQ_ai Error %', data: c.pqai_error, borderColor: '#70AD47', borderDash: [5,3], yAxisID: 'y1', order: 1, tension: 0.2 },
        ]
      },
      options: {
        responsive: true,
        interaction: { mode: 'index', intersect: false },
        scales: {
          y: { position: 'left', title: { display: true, text: '$ (MAE) / Units' } },
          y1: { position: 'right', title: { display: true, text: 'Error %' }, grid: { drawOnChartArea: false } },
        }
      }
    });
  });
}

document.getElementById('sheetSelect').addEventListener('change', loadData);
document.getElementById('periodSelect').addEventListener('change', loadData);
loadData();
</script>
</body>
</html>
"""

if __name__ == "__main__":
    port = int(os.environ.get("PORT", 8080))
    # Cloud Run sets PORT/K_SERVICE automatically on deploy — use that as the
    # signal to run in production mode (debug off). Locally, neither is set,
    # so debug=True (auto-reload, interactive debugger) is used by default.
    is_cloud_run = "K_SERVICE" in os.environ
    app.run(host="0.0.0.0", port=port, debug=not is_cloud_run)