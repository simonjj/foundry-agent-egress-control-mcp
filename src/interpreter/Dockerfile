FROM python:3.12-slim-bookworm

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    MCP_HOST=0.0.0.0 \
    MCP_PORT=8080

RUN groupadd --gid 10001 interpreter \
    && useradd --uid 10001 --gid 10001 --create-home interpreter

WORKDIR /app
COPY requirements.txt .
ARG PIP_INDEX_URL
RUN pip install --no-cache-dir -r requirements.txt

COPY executor.py server.py ./
RUN python -m compileall -q . \
    && mkdir -p /workspace \
    && chown -R interpreter:interpreter /app /workspace

USER 10001:10001
WORKDIR /workspace
EXPOSE 8080

HEALTHCHECK --interval=15s --timeout=3s --start-period=10s --retries=5 \
    CMD python -c "import os,urllib.request; urllib.request.urlopen('http://127.0.0.1:' + os.getenv('MCP_PORT', '8080') + '/health', timeout=2)"

CMD ["python", "/app/server.py"]
