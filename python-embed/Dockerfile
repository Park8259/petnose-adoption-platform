# ─── Python Embedding Service ────────────────────────────────────────────────
FROM python:3.11-slim

WORKDIR /app

ARG INSTALL_REAL_MODEL_DEPS=0
ARG INSTALL_ONNX_RUNTIME_DEPS=0

# 의존성 설치 (캐시 레이어 분리)
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY requirements-real.txt .
RUN if [ "$INSTALL_REAL_MODEL_DEPS" = "1" ]; then pip install --no-cache-dir -r requirements-real.txt; fi
COPY requirements-onnx.txt .
RUN if [ "$INSTALL_ONNX_RUNTIME_DEPS" = "1" ]; then pip install --no-cache-dir -r requirements-onnx.txt; fi

# 앱 소스 복사
COPY app ./app

EXPOSE 8000

# healthcheck: Python 내장 urllib 사용 (curl 불필요)
HEALTHCHECK --interval=10s --timeout=5s --start-period=20s --retries=5 \
    CMD python -c "import urllib.request; urllib.request.urlopen('http://localhost:8000/health', timeout=3)" \
    || exit 1

CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
