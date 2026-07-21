import os
os.environ["OMP_NUM_THREADS"] = "1"
os.environ["MKL_NUM_THREADS"] = "1"
os.environ["OPENBLAS_NUM_THREADS"] = "1"

import time
import shutil
import datetime
import smtplib
import openpyxl
from os.path import basename
from email.mime.multipart import MIMEMultipart
from email.mime.text import MIMEText
from email.mime.application import MIMEApplication
from email.utils import COMMASPACE, formatdate

from report import run_report

pwd = os.path.dirname(os.path.abspath(__file__))

# ── ALERT EMAIL CONFIG ──────────────────────────────────────────────────────
SUMMARY_SHEET = "PQ.ai Summary"
ALERT_METRIC_COLUMNS = ["PQ Mean Error Pct - Cleansed", "PQ_ai Mean Error Pct - Cleansed"]
ALERT_THRESHOLD = 0.03  # ±3%
ALERT_PERIOD = "Past Month"

ALERT_FROM = "srijan.deo@copart.com"        # TODO: confirm sender mailbox
ALERT_TO = ["srijan.deo@copart.com"]        # TODO: confirm recipient list
ALERT_SMTP_SERVER = "smtp.copart.com"


def resolve_key_path():
    """
    On Cloud Run (per cloud-run.yaml's --set-secrets flag), the service
    account JSON is mounted at /secrets/reco-test-v2. Locally, it's a file
    on disk. Prefer an explicit BQ_KEY_PATH env var if set, then the Cloud
    Run mount, then fall back to the local dev path.
    """
    env_override = os.environ.get("BQ_KEY_PATH")
    if env_override:
        return env_override

    cloud_run_secret_path = "/secrets/reco-test-v2"
    if os.path.isfile(cloud_run_secret_path):
        return cloud_run_secret_path

    return "/Users/srdeo/Documents/secrets/stewardapp-prbq-key 1.json"


def log_time(step_name, start_time):
    duration = time.time() - start_time
    minutes = duration // 60
    seconds = duration % 60
    print(f"⏱️ {step_name} completed in {int(minutes)}m {seconds:.2f}s\n")


def check_error_threshold_breach(output_path):
    """
    Reads the 'PQ.ai Summary' sheet and checks, for 'Past Month' rows,
    whether either error-pct metric column exceeds +/-3%.
    Returns (breached: bool, breaches: list[dict]).
    """
    wb = openpyxl.load_workbook(output_path, data_only=True)
    ws = wb[SUMMARY_SHEET]

    headers = [cell.value for cell in ws[1]]
    needed_cols = ["breakout", "period"] + ALERT_METRIC_COLUMNS
    col_idx = {name: headers.index(name) for name in needed_cols if name in headers}

    breaches = []
    for row in ws.iter_rows(min_row=2):
        if "period" not in col_idx or row[col_idx["period"]].value != ALERT_PERIOD:
            continue
        breakout_val = row[col_idx["breakout"]].value if "breakout" in col_idx else None
        for metric in ALERT_METRIC_COLUMNS:
            if metric not in col_idx:
                continue
            val = row[col_idx[metric]].value
            if val is not None and abs(val) > ALERT_THRESHOLD:
                breaches.append({"breakout": breakout_val, "metric": metric, "value": val})

    wb.close()
    return (len(breaches) > 0), breaches


def send_alert_email(breaches, output_path, current_run_date):
    msg = MIMEMultipart()
    msg["From"] = ALERT_FROM
    msg["To"] = COMMASPACE.join(ALERT_TO)
    msg["Date"] = formatdate(localtime=True)
    msg["Subject"] = f"⚠️ PQ.ai Error Threshold Breach — {current_run_date}"

    lines = [f"PQ.ai Mean Error Pct breached the {ALERT_THRESHOLD:.0%} threshold "
              f"for the {ALERT_PERIOD} period ({current_run_date}):\n"]
    for b in breaches:
        lines.append(f"  - {b['breakout']} | {b['metric']}: {b['value']:.1%}")
    msg.attach(MIMEText("\n".join(lines), "plain"))

    with open(output_path, "rb") as f:
        part = MIMEApplication(f.read(), Name=basename(output_path))
    part["Content-Disposition"] = f'attachment; filename="{basename(output_path)}"'
    msg.attach(part)

    smtp = smtplib.SMTP(ALERT_SMTP_SERVER, 587)
    smtp.sendmail(ALERT_FROM, ALERT_TO, msg.as_string())
    smtp.close()
    print(f"📧 Alert email sent to {ALERT_TO}")


def main():
    """
    Job entrypoint — runs the BigQuery → Excel report and uploads it to GCS,
    then exits. This is what the Cloud Run Job runs (triggered on a schedule
    via Cloud Scheduler). No Flask/dashboard here — a Job is expected to
    run to completion and stop, not stay listening.
    """
    print("🚀 Starting PQ.ai reporting job...\n")
    overall_start = time.time()

    # ───────────────────────────────────────────────────────────────
    step = "STEP 1️⃣: Run PQ.ai BigQuery → Excel Report"
    print(f"\n{step}")
    start = time.time()

    key_path = resolve_key_path()
    if not os.path.isfile(key_path):
        raise RuntimeError(f"Service account JSON not found at {key_path}")
    print(f"🔑 Using service account key: {key_path}")

    job_name = "pq_ai_weekly_report"
    current_run_date = datetime.date.today().isoformat()

    # GCS bucket where the template lives and finished reports get uploaded.
    # Template is currently sitting at the bucket root (not under a #check
    # "templates/" prefix), so gcs_template_blob points straight at it.
    gcs_bucket = "cprtqa-pqai-reporting"
    gcs_template_blob = "PQ_ai_Reporting_Reference_Outputs.xlsx"

    output_path = run_report(
        job_name=job_name,
        current_run_date=current_run_date,
        key_path=key_path,
        gcs_bucket=gcs_bucket,
        gcs_template_blob=gcs_template_blob,
    )
    log_time(step, start)

    # ───────────────────────────────────────────────────────────────
    step = "STEP 2️⃣: Save Final Output to project's /data folder"
    print(f"\n{step}")
    start = time.time()

    os.makedirs(os.path.join(pwd, "data"), exist_ok=True)
    final_path = os.path.join(pwd, "data", os.path.basename(output_path))
    shutil.copy2(output_path, final_path)
    print(f"📄 Final report saved to: {final_path}")
    log_time(step, start)

    # ───────────────────────────────────────────────────────────────
    step = "STEP 3️⃣: Check Error Threshold & Send Alert Email"
    print(f"\n{step}")
    start = time.time()

    breached, breaches = check_error_threshold_breach(output_path)
    if breached:
        print(f"⚠️ Threshold breach detected ({len(breaches)} rows over {ALERT_THRESHOLD:.0%})")
        try:
            send_alert_email(breaches, output_path, current_run_date)
        except Exception as e:
            print(f"❌ Alert email failed to send: {e}")
    else:
        print("✅ No threshold breach — no alert email sent.")
    log_time(step, start)

    print("🏁 ALL STEPS COMPLETED")
    log_time("TOTAL PIPELINE", overall_start)
    # No Step 4 here — the Job process exits now. The dashboard is served
    # separately by the Cloud Run Service running dashboard.py, which reads
    # the report this job just uploaded to GCS.


if __name__ == "__main__":
    main()