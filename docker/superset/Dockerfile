# syntax=docker/dockerfile:1
FROM apache/superset:6.1.0

# Lean build: zero DB drivers. Without psycopg2 Superset cannot reach its own
# metadata DB and fails at startup, not query time. Pinned to match Superset's
# own pyproject.toml [postgres] extra rather than floating.
USER root
RUN uv pip install --python /app/.venv/bin/python "psycopg2-binary==2.9.9"

# The inherited HEALTHCHECK is `curl -f`, and the base image ships no curl --
# every `condition: service_healthy` on this service would deadlock forever.
RUN apt-get update \
 && apt-get install -y --no-install-recommends curl \
 && rm -rf /var/lib/apt/lists/*

# Superset's own MCP server (SIP-187) already ships in this image, gated only on
# fastmcp being importable. Install the LEAF package, not the [fastmcp] extra --
# apache-superset is an editable install pointing at /app, and the extra form
# would have the resolver fetch a PyPI copy over it.
RUN uv pip install --python /app/.venv/bin/python "fastmcp>=3.1.0,<4.0"

# python-ldap is a C extension with no wheel here, so it needs gcc + OpenLDAP/SASL
# headers to build. Installed, used and purged in one layer so they do not ship.
# Pinned to what Flask-AppBuilder 5.0.2 is tested against.
USER root
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      gcc libldap2-dev libsasl2-dev libssl-dev \
 && uv pip install --python /app/.venv/bin/python "python-ldap==3.4.4" \
 && apt-get purge -y --auto-remove gcc libldap2-dev libsasl2-dev libssl-dev \
 && rm -rf /var/lib/apt/lists/* \
 && /app/.venv/bin/python -c "import ldap; print('python-ldap', ldap.__version__)"

USER superset
