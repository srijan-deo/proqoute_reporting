import os
os.environ["OMP_NUM_THREADS"] = "1"
os.environ["MKL_NUM_THREADS"] = "1"
os.environ["OPENBLAS_NUM_THREADS"] = "1"

import time
import shutil
import datetime

from report import run_report

pwd = os.path.dirname(os.path.abspath(__file__))


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
    # Template is currently sitting at the bucket root (not under a
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

    print("🏁 ALL STEPS COMPLETED")
    log_time("TOTAL PIPELINE", overall_start)
    # No Step 3 here — the Job process exits now. The dashboard is served
    # separately by the Cloud Run Service running dashboard.py, which reads
    # the report this job just uploaded to GCS.


if __name__ == "__main__":
    main()