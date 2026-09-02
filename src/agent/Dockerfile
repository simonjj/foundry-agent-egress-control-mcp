FROM python:3.13-slim-bookworm

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY main.py .

RUN groupadd --gid 10001 agent \
    && useradd --uid 10001 --gid 10001 --no-create-home agent \
    && chown -R agent:agent /app

USER agent
EXPOSE 8088
RUN python -m compileall -q .
CMD ["python", "main.py"]
