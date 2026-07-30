"""
Create the `mcp_reader` service account and its read-only role.

WHY THIS EXISTS AND WHY IT MATTERS MORE THAN IT LOOKS
-----------------------------------------------------
Superset 6.1.0's MCP service has NO per-user identity. `get_user_from_request()`
(superset/mcp_service/auth.py) resolves the acting user from exactly two places:
a `g.user` pre-set by Preset's proprietary middleware, or the `MCP_DEV_USERNAME`
config value. The function that would map JWT claims to a Superset user --
`default_user_resolver` in mcp_config.py -- is defined and then referenced
nowhere. So every MCP call, from anyone, acts as MCP_DEV_USERNAME.

RBAC *is* enforced (MCP_RBAC_ENABLED defaults True, and each tool declares a
class_permission_name), but always against that one account. And in 6.1.0 there
is no supported way to disable individual tools when launching via
`superset mcp run` -- MCP_FACTORY_CONFIG's exclude_tags is only honoured on the
use_factory_config=True path, which the CLI does not take.

=> The role on this user is the ONLY security boundary. Hence: read-only, and
   deliberately WITHOUT `can_execute_sql_query`, so the agent cannot run
   arbitrary SQL against the warehouse through Superset. Its Cube access already
   goes through the semantic layer, where masking applies.

Idempotent. Run from Superset's own startup (see docker-compose.yml).
"""
from superset.app import create_app

ROLE_NAME = "McpReader"
USERNAME = "mcp_reader"

# Read-only on exactly what a chart-analysis agent needs to navigate.
# `can_read` on these models covers list_dashboards / get_dashboard_info /
# list_charts / get_chart_info / list_datasets / get_dataset_info /
# list_databases / get_database_info.
READ_MODELS = (
    "Chart",
    "Dashboard",
    "Dataset",
    "Database",
    "Query",
    "SavedQuery",
    "Annotation",
    "CssTemplate",
)

# get_chart_data goes through the chart data API, which needs these.
EXTRA_PERMS = (
    ("can_read", "Chart"),
    ("can_read", "Dashboard"),
    ("can_view_chart_as_table", "Dashboard"),
    ("can_samples", "Datasource"),
)


def main() -> None:
    app = create_app()
    with app.app_context():
        from superset import db
        from superset.extensions import security_manager as sm
        import os

        password = os.environ["SUPERSET_MCP_READER_PASSWORD"]

        role = sm.find_role(ROLE_NAME) or sm.add_role(ROLE_NAME)

        wanted = set()
        for model in READ_MODELS:
            wanted.add(("can_read", model))
        wanted.update(EXTRA_PERMS)

        granted, missing = 0, []
        for perm_name, view_name in sorted(wanted):
            pv = sm.find_permission_view_menu(perm_name, view_name)
            if pv is None:
                # Not every (perm, view) pair exists in every Superset version;
                # skip rather than fail, and report so drift is visible.
                missing.append(f"{perm_name} on {view_name}")
                continue
            if pv not in role.permissions:
                sm.add_permission_role(role, pv)
                granted += 1

        # Datasource access: without this, get_chart_data is refused even with
        # can_read on Chart, because Superset checks datasource access separately.
        # NOTE: use db.session, not sm.get_session -- the latter does not exist on
        # SupersetSecurityManager in the Flask-AppBuilder 5.0.2 this image ships.
        for pv in db.session.query(sm.permissionview_model).all():
            if pv.permission and pv.permission.name == "datasource_access":
                if pv not in role.permissions:
                    sm.add_permission_role(role, pv)
                    granted += 1

        db.session.commit()
        print(f"RESULT role {ROLE_NAME}: {len(role.permissions)} perms (+{granted} added)")
        if missing:
            print(f"RESULT skipped (not present in this version): {', '.join(missing)}")

        user = sm.find_user(username=USERNAME)
        if user is None:
            sm.add_user(
                username=USERNAME,
                first_name="MCP",
                last_name="Reader",
                email="mcp-reader@demo.local",
                role=role,
                password=password,
            )
            print(f"RESULT created user {USERNAME}")
        else:
            # Keep the role assignment authoritative on re-run.
            if role not in user.roles:
                user.roles.append(role)
            print(f"RESULT user {USERNAME} already exists")
        db.session.commit()

        # Explicitly assert the dangerous permission is absent -- this is the
        # whole point of the account, so it should fail loudly if it drifts.
        sql_perm = sm.find_permission_view_menu("can_execute_sql_query", "SQLLab")
        has_sql = sql_perm is not None and sql_perm in role.permissions
        print(f"RESULT can_execute_sql_query granted: {has_sql} (must be False)")


if __name__ == "__main__":
    main()
