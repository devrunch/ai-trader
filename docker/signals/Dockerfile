FROM python:3.13-slim AS base
WORKDIR /app
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    NUMBA_DISABLE_JIT=1

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential curl \
    && curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && npm install -g diascript@0.0.10 \
    && rm -rf /var/lib/apt/lists/*

COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt

COPY . .

RUN groupadd --system --gid 1001 appuser && \
    useradd --system --uid 1001 --gid appuser appuser && \
    chown -R appuser:appuser /app
USER appuser

# FastAPI server
FROM base AS api
EXPOSE 8001
# One worker, not two. The task is provisioned at "cpu": "512" — half a vCPU
# (deploy/fargate/signals-task.json) — so two uvicorn workers do not double
# throughput, they contend for the same half core and double the memory.
# The blocking vendor calls are offloaded to a thread pool that main.py bounds
# at 16 threads on the startup hook, which is where the concurrency for
# I/O-bound yfinance work now comes from. Raise the CPU allocation before
# raising the worker count.
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8001", "--workers", "1"]

# Celery worker
FROM base AS worker
CMD ["celery", "-A", "app.worker.celery_app.celery", "worker", "--loglevel=info", "--concurrency=2"]

# Celery beat scheduler
FROM base AS beat
CMD ["celery", "-A", "app.worker.celery_app.celery", "beat", "--loglevel=info"]
