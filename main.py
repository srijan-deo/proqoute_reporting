import os
os.environ["OMP_NUM_THREADS"] = "1"
os.environ["MKL_NUM_THREADS"] = "1"
os.environ["OPENBLAS_NUM_THREADS"] = "1"

import time
import shutil
import datetime

from report import run_report

pwd = os.path.dirname(os.path.abspath(__file__))


def log_time(step_name, start_time):
    duration = time.time() - start_time
    minutes = duration // 60
    seconds = duration % 60
    print(f"⏱️ {step_name} completed in {int(minutes)}m {seconds:.2f}s\n")


def main():
    print("🚀 Starting PQ.ai reporting pipeline...\n")
    overall_start = time.time()

    # ───────────────────────────────────────────────────────────────
    step = "STEP 1️⃣: Run PQ.ai BigQuery → Excel Report"
    print(f"\n{step}")
    start = time.time()

    key_path = "/Users/srdeo/Documents/secrets/stewardapp-prbq-key 1.json"  # <-- FILE, not folder
    if not os.path.isfile(key_path):
        raise RuntimeError(f"Service account JSON not found at {key_path}")

    job_name = "pq_ai_weekly_report"
    current_run_date = datetime.date.today().isoformat()

    output_path = run_report(
        job_name=job_name,
        current_run_date=current_run_date,
        key_path=key_path,
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


if __name__ == "__main__":
    main()