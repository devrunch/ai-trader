# Everything needed only to INSTALL, never shipped: the C/C++ toolchain
# numpy/pandas' native extensions need to build, and curl (only used to
# fetch the nodesource setup script). Kept out of the runtime stage below --
# on a 2GB box, build-essential alone was a few hundred MB the image never
# needed to carry once the wheels were already built.
FROM python:3.13-slim AS deps
WORKDIR /app

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential curl \
    && curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/*

COPY requirements.txt ./
RUN pip install --no-cache-dir --prefix=/install -r requirements.txt

# The pine sandbox is a separate Node subproject (its own package.json,
# spawned as a subprocess by app/signals/pine/sandbox.py) -- installed here,
# in the stage that has npm, then copied into the runtime stage below.
COPY app/pine_sandbox/package.json app/pine_sandbox/package-lock.json ./app/pine_sandbox/
RUN cd app/pine_sandbox && npm ci --omit=dev

# Same pattern, same reason -- app/dukascopy_bridge wraps dukascopy-node
# (no Python equivalent), spawned as a one-shot subprocess by
# app/market/providers/dukascopy_bridge.py.
COPY app/dukascopy_bridge/package.json app/dukascopy_bridge/package-lock.json ./app/dukascopy_bridge/
RUN cd app/dukascopy_bridge && npm ci --omit=dev

# The actual runtime image. Node itself still ships (the sandbox spawns it
# at request time) -- only the compiler toolchain used to build things does
# not.
FROM python:3.13-slim AS base
WORKDIR /app
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    NUMBA_DISABLE_JIT=1

RUN apt-get update && apt-get install -y --no-install-recommends curl \
    && curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/*

COPY --from=deps /install /usr/local
COPY --from=deps /app/app/pine_sandbox/node_modules ./app/pine_sandbox/node_modules
COPY --from=deps /app/app/dukascopy_bridge/node_modules ./app/dukascopy_bridge/node_modules
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
