# This image serves the read-only, admin-only verifier audit console.
FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1

WORKDIR /app

COPY docker/audit-console/requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt

COPY docker/audit-console/app.py ./
COPY docker/audit-console/templates ./templates
COPY docker/audit-console/static ./static

USER 65532:65532
EXPOSE 8090

CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8090"]
