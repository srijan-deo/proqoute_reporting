# Use lightweight Python base
FROM python:3.12-slim

# Prevent Python from writing .pyc files
ENV PYTHONDONTWRITEBYTECODE=1
ENV PYTHONUNBUFFERED=1
ENV PIP_REQUIRE_HASHES=0

# Set working directory
WORKDIR /app

# Install system deps (only if needed)
RUN apt-get update && apt-get install -y \
    gcc \
    && rm -rf /var/lib/apt/lists/*

# Copy and install Python deps first (cache-friendly)
COPY requirements.txt .
ENV PIP_REQUIRE_HASHES=0
RUN pip install --no-cache-dir -r requirements.txt

# Copy application code
COPY . .

# Cloud Run uses PORT env var
ENV PORT=8080

# Run your job
CMD ["python", "main_job.py"]