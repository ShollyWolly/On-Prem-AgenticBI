"""Create the read-only Superset MCP service account."""
from superset.app import create_app

ROLE_NAME = "McpReader"
USERNAME = "mcp_reader"

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
                missing.append(f"{perm_name} on {view_name}")
                continue
            if pv not in role.permissions:
                sm.add_permission_role(role, pv)
                granted += 1

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
            if role not in user.roles:
                user.roles.append(role)
            print(f"RESULT user {USERNAME} already exists")
        db.session.commit()

        sql_perm = sm.find_permission_view_menu("can_execute_sql_query", "SQLLab")
        has_sql = sql_perm is not None and sql_perm in role.permissions
        print(f"RESULT can_execute_sql_query granted: {has_sql} (must be False)")


if __name__ == "__main__":
    main()
