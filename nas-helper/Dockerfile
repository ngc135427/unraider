FROM python:3.12-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends ffmpeg \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY unraider_helper /app/unraider_helper

ENV PYTHONUNBUFFERED=1 \
    UNRAIDER_HELPER_HOST=0.0.0.0 \
    UNRAIDER_HELPER_PORT=9487 \
    UNRAIDER_STATE_DIR=/data

VOLUME ["/data"]
EXPOSE 9487
HEALTHCHECK --interval=30s --timeout=5s --retries=3 \
    CMD ["python", "-c", "import urllib.request; urllib.request.urlopen('http://127.0.0.1:9487/healthz', timeout=3)"]

CMD ["python", "-m", "unraider_helper"]
