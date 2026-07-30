"""
Apache Superset 6.1.0 configuration.

The theme API churned hard in 6.0 and most guides online are now wrong:
THEME_OVERRIDES was removed and THEME_DEFAULT_MODE never existed, so both are
silent no-ops. See docs/TRAPS.md.
"""

import os
from typing import Any

# ---------------------------------------------------------------- core
# No default: regenerating SECRET_KEY makes every stored DB credential
# undecryptable and is not self-healing, so a missing value must fail loudly
# rather than fall back to the upstream placeholder.
SECRET_KEY = os.environ["SUPERSET_SECRET_KEY"]
SQLALCHEMY_DATABASE_URI = os.environ["SUPERSET_METADATA_URI"]
SQLALCHEMY_TRACK_MODIFICATIONS = False

ROW_LIMIT = 50_000
SAMPLES_ROW_LIMIT = 1_000
SUPERSET_WEBSERVER_TIMEOUT = 180
SQLLAB_TIMEOUT = 180

# No TLS in the PoC; Talisman's HSTS + CSP break plain http://localhost.
TALISMAN_ENABLED = False
WTF_CSRF_ENABLED = True
PUBLIC_ROLE_LIKE = None

# ---------------------------------------------------------------- caches
# SimpleCache is coherent only because run-server.sh defaults to --workers 1.
# Raising SERVER_WORKER_AMOUNT without switching to RedisCache first breaks
# dashboard filter and Explore form state non-deterministically across processes.
_SIMPLE = {"CACHE_TYPE": "SimpleCache"}
CACHE_CONFIG = {**_SIMPLE, "CACHE_DEFAULT_TIMEOUT": 300}
DATA_CACHE_CONFIG = {**_SIMPLE, "CACHE_DEFAULT_TIMEOUT": 300}
FILTER_STATE_CACHE_CONFIG = {**_SIMPLE, "CACHE_DEFAULT_TIMEOUT": 86_400}
EXPLORE_FORM_DATA_CACHE_CONFIG = {**_SIMPLE, "CACHE_DEFAULT_TIMEOUT": 86_400}

# ---------------------------------------------------------------- feature flags
FEATURE_FLAGS: dict[str, bool] = {
    "DRILL_TO_DETAIL": True,
    "DRILL_BY": True,
    "DASHBOARD_CROSS_FILTERS": True,
    # Off deliberately: Superset holds ONE Cube SQL credential, so every Superset
    # user shares one security context. Gating dashboards by Superset role would
    # imply per-user masking this path cannot deliver.
    "DASHBOARD_RBAC": False,
    "EMBEDDED_SUPERSET": False,
    "ALERT_REPORTS": False,   # needs Celery beat + worker, both dropped
}

# ------------------------------------------------------------------- identity
# Superset and LibreChat share one userstore (OpenLDAP). That unifies LOGIN only:
# authorization still comes from Cube, and Superset's single Cube credential means
# every Superset user sees the same masked data whoever they signed in as.
#
# SUPERSET_AUTH=db is the break-glass path -- with AUTH_LDAP, FAB authenticates
# only against the directory, so an unreachable slapd locks everyone out of the
# dashboard including the local admin.
_AUTH_MODE = os.environ.get("SUPERSET_AUTH", "ldap").strip().lower()

if _AUTH_MODE == "ldap":
    from flask_appbuilder.security.manager import AUTH_LDAP

    AUTH_TYPE = AUTH_LDAP
    AUTH_LDAP_SERVER = os.environ.get("LDAP_URL", "ldap://openldap:389")
    AUTH_LDAP_USE_TLS = False

    # Bind as directory admin to search, then re-bind as the user. Anonymous search
    # is refused by osixia's ACLs in a way that surfaces as "user not found".
    AUTH_LDAP_BIND_USER = os.environ["LDAP_ADMIN_DN"]
    AUTH_LDAP_BIND_PASSWORD = os.environ["LDAP_ADMIN_PASSWORD"]

    AUTH_LDAP_SEARCH = f"ou=people,{os.environ['LDAP_BASE_DN']}"
    # The full e-mail, not the bare uid: it is already the canonical key everywhere
    # else (CUBE_USER_ROLE_MAP, agent provisioning), and FAB supports only one UID
    # field. Changing it orphans existing records in BOTH stores; see docs/TRAPS.md.
    AUTH_LDAP_UID_FIELD = "mail"
    AUTH_LDAP_FIRSTNAME_FIELD = "givenName"
    AUTH_LDAP_LASTNAME_FIELD = "sn"
    AUTH_LDAP_EMAIL_FIELD = "mail"

    # A fresh stack needs this so the analyst's first LDAP login creates their
    # local record.
    AUTH_USER_REGISTRATION = True
    AUTH_USER_REGISTRATION_ROLE = "Gamma"

    # Mandatory whenever AUTH_USER_REGISTRATION is true on a non-OAuth auth type:
    # 6.1.0 reads RECAPTCHA_PUBLIC_KEY, a key it never defines, so GET /login/
    # raises KeyError and returns 500 while /health stays 200 and the JSON API
    # keeps working -- no human can sign in, and API-only checks see nothing wrong.
    # Do not "fix" this by disabling registration.
    RECAPTCHA_PUBLIC_KEY = ""
    RECAPTCHA_PRIVATE_KEY = ""

    # SYNC_AT_LOGIN keeps LDAP authoritative: change a group and the next login
    # reflects it, instead of the first login's roles sticking forever.
    AUTH_LDAP_GROUP_FIELD = "memberOf"
    AUTH_ROLES_SYNC_AT_LOGIN = True
    AUTH_ROLES_MAPPING = {
        f"cn=admins,ou=groups,{os.environ['LDAP_BASE_DN']}": ["Admin"],
        f"cn=analysts,ou=groups,{os.environ['LDAP_BASE_DN']}": ["Alpha"],
    }

# ---------------------------------------------------------------- MCP service
# 6.1.0 ships its own MCP server (SIP-187), started as a separate process by
# `superset mcp run` -- it is not mounted into this Flask app.
#
# It has no per-user identity: every call acts as MCP_DEV_USERNAME, so the ROLE on
# that account is the entire security boundary. create_mcp_reader.py builds it
# read-only and deliberately without can_execute_sql_query.
MCP_DEV_USERNAME = "mcp_reader"
MCP_RBAC_ENABLED = True

# The MCP process builds deep links from this; the default localhost:9001 is wrong
# inside any container deployment.
SUPERSET_WEBSERVER_ADDRESS = "http://abi-superset:8088"
WEBDRIVER_BASEURL = "http://abi-superset:8088/"

# Expose all 24 tools directly. The BM25 search_tools proxy saves context but
# reliably confuses smaller agent models.
MCP_TOOL_SEARCH_CONFIG = {"enabled": False}

# get_chart_preview / update_chart_preview need Selenium and there is no browser in
# this image. 6.1.0 cannot disable individual tools via the CLI path, so the agent
# instructions tell it not to call them.

# ---------------------------------------------------------------- theme
# colorBgBase / colorBgLayout / colorBgContainer are the three AntD v5 tokens that
# actually move the dark surfaces; setting colorPrimary alone leaves a light app
# with a blue button. The brand* tokens are re-declared because assigning
# THEME_DEFAULT replaces the upstream dict wholesale.
_DARK_TOKENS: dict[str, Any] = {
    "brandAppName": "Agentic BI",
    "brandLogoAlt": "Agentic BI",
    "brandLogoHref": "/",
    "brandLogoMargin": "18px 0",
    "brandLogoHeight": "24px",

    "colorBgBase": "#0b0f14",
    "colorBgLayout": "#0b0f14",
    "colorBgContainer": "#131922",
    "colorBgElevated": "#1a222e",
    "colorBorder": "#232c3a",
    "colorBorderSecondary": "#1b2330",

    "colorTextBase": "#e6edf6",
    "colorTextSecondary": "#a9b6c8",
    "colorTextTertiary": "#7b8798",

    "colorPrimary": "#3987e5",
    "colorLink": "#3987e5",
    "colorInfo": "#3987e5",
    "colorSuccess": "#199e70",
    "colorWarning": "#c98500",
    "colorError": "#e66767",

    "fontFamily": "Inter, system-ui, -apple-system, 'Segoe UI', sans-serif",
    "fontFamilyCode": "'IBM Plex Mono', 'Courier New', monospace",
    "colorEditorSelection": "#5c4d1a",
}

THEME_DEFAULT: dict[str, Any] = {"token": _DARK_TOKENS, "algorithm": "dark"}

# Forces one theme on everyone and removes the light/dark switcher.
THEME_DARK = None

ENABLE_UI_THEME_ADMINISTRATION = False

# ---------------------------------------------------------------- chart colours
# Separate mechanism from the theme tokens. Validated against surface #131922:
# worst adjacent CVD deltaE 8.4 (protan), all eight >= 3:1 contrast.
#
# Do not re-order: the slot ORDER is the CVD-safety mechanism, since adjacent slots
# are the pairs most likely to share a chart.
EXTRA_CATEGORICAL_COLOR_SCHEMES = [
    {
        "id": "agenticBiDark",
        "label": "Agentic BI (dark)",
        "isDefault": True,
        "colors": [
            "#3987e5",  # 1 blue
            "#d95926",  # 2 orange
            "#199e70",  # 3 aqua
            "#c98500",  # 4 yellow
            "#d55181",  # 5 magenta
            "#008300",  # 6 green
            "#9085e9",  # 7 violet
            "#e66767",  # 8 red
        ],
    }
]

# Single hue, dark -> bright, so "more" reads as brighter. Never a rainbow ramp for
# magnitude: hue carries no ordering information.
EXTRA_SEQUENTIAL_COLOR_SCHEMES = [
    {
        "id": "agenticBiBlueDark",
        "label": "Agentic BI Blue (dark)",
        "isDefault": True,
        "isDiverging": False,
        "colors": ["#184f95", "#256abf", "#3987e5", "#6da7ec", "#9ec5f4", "#cde2fb"],
    }
]
