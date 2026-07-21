"""
Small shared helper for reading/writing files in Google Cloud Storage.

Used by report.py (download template, upload finished workbook) and
dashboard.py (find + download the latest workbook to serve).

Auth:
    - Locally: pass key_path (the same service-account JSON you already use
      for BigQuery) and it'll be used for GCS too.
    - On Cloud Run / GCE / GKE: leave key_path=None and it'll fall back to
      Application Default Credentials (the runtime service account) —
      no code changes needed when you deploy.
"""

from google.cloud import storage


def _get_client(key_path=None):
    if key_path:
        return storage.Client.from_service_account_json(key_path)
    return storage.Client()  # uses Application Default Credentials


def download_blob_to_file(bucket_name, blob_name, destination_path, key_path=None):
    """Download a GCS blob to a local path. Raises if the blob doesn't exist."""
    client = _get_client(key_path)
    bucket = client.bucket(bucket_name)
    blob = bucket.blob(blob_name)
    if not blob.exists():
        raise FileNotFoundError(f"gs://{bucket_name}/{blob_name} not found")
    blob.download_to_filename(destination_path)
    print(f"Downloaded gs://{bucket_name}/{blob_name} → {destination_path}")
    return destination_path


def upload_file_to_blob(bucket_name, blob_name, source_path, key_path=None):
    """Upload a local file to GCS, returning the gs:// URI."""
    client = _get_client(key_path)
    bucket = client.bucket(bucket_name)
    blob = bucket.blob(blob_name)
    blob.upload_from_filename(source_path)
    uri = f"gs://{bucket_name}/{blob_name}"
    print(f"Uploaded {source_path} → {uri}")
    return uri


def get_latest_blob_name(bucket_name, prefix, key_path=None, suffix=".xlsx"):
    """Return the blob name (under `prefix`) with the most recent update time."""
    client = _get_client(key_path)
    blobs = list(client.list_blobs(bucket_name, prefix=prefix))
    blobs = [b for b in blobs if b.name.endswith(suffix)]
    if not blobs:
        raise FileNotFoundError(f"No {suffix} files under gs://{bucket_name}/{prefix}")
    latest = max(blobs, key=lambda b: b.updated)
    return latest.name, latest.updated