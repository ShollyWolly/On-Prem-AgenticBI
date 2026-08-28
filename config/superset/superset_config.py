"""Apache Superset configuration."""

import os
from typing import Any

SECRET_KEY = os.environ["SUPERSET_SECRET_KEY"]
SQLALCHEMY_DATABASE_URI = os.environ["SUPERSET_METADATA_URI"]
SQLALCHEMY_TRACK_MODIFICATIONS = False

ROW_LIMIT = 50_000
SAMPLES_ROW_LIMIT = 1_000
SUPERSET_WEBSERVER_TIMEOUT = 180
SQLLAB_TIMEOUT = 180

TALISMAN_ENABLED = False
WTF_CSRF_ENABLED = True
PUBLIC_ROLE_LIKE = None

_SIMPLE = {"CACHE_TYPE": "SimpleCache"}
CACHE_CONFIG = {**_SIMPLE, "CACHE_DEFAULT_TIMEOUT": 300}
DATA_CACHE_CONFIG = {**_SIMPLE, "CACHE_DEFAULT_TIMEOUT": 300}
FILTER_STATE_CACHE_CONFIG = {**_SIMPLE, "CACHE_DEFAULT_TIMEOUT": 86_400}
EXPLORE_FORM_DATA_CACHE_CONFIG = {**_SIMPLE, "CACHE_DEFAULT_TIMEOUT": 86_400}

FEATURE_FLAGS: dict[str, bool] = {
    "DRILL_TO_DETAIL": True,
    "DRILL_BY": True,
    "DASHBOARD_CROSS_FILTERS": True,
    "DASHBOARD_RBAC": False,
    "EMBEDDED_SUPERSET": False,
    "ALERT_REPORTS": False,
}

_AUTH_MODE = os.environ.get("SUPERSET_AUTH", "ldap").strip().lower()

if _AUTH_MODE == "ldap":
    from flask_appbuilder.security.manager import AUTH_LDAP

    AUTH_TYPE = AUTH_LDAP
    AUTH_LDAP_SERVER = os.environ.get("LDAP_URL", "ldap://openldap:389")
    AUTH_LDAP_USE_TLS = False

    AUTH_LDAP_BIND_USER = os.environ["LDAP_ADMIN_DN"]
    AUTH_LDAP_BIND_PASSWORD = os.environ["LDAP_ADMIN_PASSWORD"]

    AUTH_LDAP_SEARCH = f"ou=people,{os.environ['LDAP_BASE_DN']}"
    AUTH_LDAP_UID_FIELD = "mail"
    AUTH_LDAP_FIRSTNAME_FIELD = "givenName"
    AUTH_LDAP_LASTNAME_FIELD = "sn"
    AUTH_LDAP_EMAIL_FIELD = "mail"

    AUTH_USER_REGISTRATION = True
    AUTH_USER_REGISTRATION_ROLE = "Gamma"

    RECAPTCHA_PUBLIC_KEY = ""
    RECAPTCHA_PRIVATE_KEY = ""

    AUTH_LDAP_GROUP_FIELD = "memberOf"
    AUTH_ROLES_SYNC_AT_LOGIN = True
    AUTH_ROLES_MAPPING = {
        f"cn=admins,ou=groups,{os.environ['LDAP_BASE_DN']}": ["Admin"],
        f"cn=analysts,ou=groups,{os.environ['LDAP_BASE_DN']}": ["Alpha"],
    }

MCP_DEV_USERNAME = "mcp_reader"
MCP_RBAC_ENABLED = True

SUPERSET_WEBSERVER_ADDRESS = "http://abi-superset:8088"
WEBDRIVER_BASEURL = "http://abi-superset:8088/"

MCP_TOOL_SEARCH_CONFIG = {"enabled": False}


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

THEME_DARK = None

ENABLE_UI_THEME_ADMINISTRATION = False

EXTRA_CATEGORICAL_COLOR_SCHEMES = [
    {
        "id": "agenticBiDark",
        "label": "Agentic BI (dark)",
        "isDefault": True,
        "colors": [
            "#3987e5",
            "#d95926",
            "#199e70",
            "#c98500",
            "#d55181",
            "#008300",
            "#9085e9",
            "#e66767",
        ],
    }
]

EXTRA_SEQUENTIAL_COLOR_SCHEMES = [
    {
        "id": "agenticBiBlueDark",
        "label": "Agentic BI Blue (dark)",
        "isDefault": True,
        "isDiverging": False,
        "colors": ["#184f95", "#256abf", "#3987e5", "#6da7ec", "#9ec5f4", "#cde2fb"],
    }
]
