# =============================================================================
# PPSA - Web UI Dockerfile
# =============================================================================
FROM python:3.12-slim

WORKDIR /app

RUN apt-get update -qq && \
    apt-get install -y -qq --no-install-recommends curl wireguard-tools && \
    rm -rf /var/lib/apt/lists/*

COPY app/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app/ .

EXPOSE 8080

CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8080"]
