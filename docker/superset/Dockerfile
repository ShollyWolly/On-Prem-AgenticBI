# syntax=docker/dockerfile:1
FROM apache/superset:6.1.0

USER root
RUN uv pip install --python /app/.venv/bin/python "psycopg2-binary==2.9.9"

RUN apt-get update \
 && apt-get install -y --no-install-recommends curl \
 && rm -rf /var/lib/apt/lists/*

RUN uv pip install --python /app/.venv/bin/python "fastmcp>=3.1.0,<4.0"

USER root
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      gcc libldap2-dev libsasl2-dev libssl-dev \
 && uv pip install --python /app/.venv/bin/python "python-ldap==3.4.4" \
 && apt-get purge -y --auto-remove gcc libldap2-dev libsasl2-dev libssl-dev \
 && rm -rf /var/lib/apt/lists/* \
 && /app/.venv/bin/python -c "import ldap; print('python-ldap', ldap.__version__)"

USER superset
