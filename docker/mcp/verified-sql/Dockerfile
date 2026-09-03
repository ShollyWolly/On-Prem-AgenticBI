# This image runs the verified SQL MCP that audits a judge verdict before releasing rows.
FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1

WORKDIR /app

COPY docker/mcp/verified-sql/requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt

COPY docker/mcp/verified-sql/app.py ./
COPY docker/mcp/verified-sql/test_app.py ./

USER 65532:65532
EXPOSE 8000

CMD ["python", "app.py"]
