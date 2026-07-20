FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PYTHONPATH=/app/services/api

WORKDIR /app

COPY services/api/requirements.lock /tmp/requirements.lock
ARG PIP_INDEX_URL=https://mirrors.cloud.tencent.com/pypi/simple
RUN pip install --no-cache-dir --index-url "$PIP_INDEX_URL" -r /tmp/requirements.lock

COPY alembic.ini /app/alembic.ini
COPY infra/migrations /app/infra/migrations
COPY packages/prompts /app/packages/prompts
COPY services/api /app/services/api

EXPOSE 8000

CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000", "--proxy-headers"]
