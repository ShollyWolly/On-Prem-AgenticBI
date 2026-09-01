"""Align human Superset usernames with LDAP email addresses."""
from werkzeug.security import check_password_hash

from superset.app import create_app

# This local service account is not LDAP-managed and must keep its stable username.
SERVICE_ACCOUNTS = {"mcp_reader"}


def main() -> None:
    app = create_app()
    with app.app_context():
        import os

        from superset import db
        from superset.extensions import security_manager as sm

        renamed = skipped = 0
        for user in sm.get_all_users():
            if user.username in SERVICE_ACCOUNTS:
                print(f"RESULT username {user.username}: service account, left alone")
                continue
            if not user.email:
                print(f"RESULT username {user.username}: no e-mail, left alone")
                skipped += 1
                continue
            if user.username == user.email:
                continue

            print(f"RESULT username {user.username} -> {user.email}")
            user.username = user.email
            renamed += 1

        db.session.commit()
        print(f"RESULT usernames aligned to e-mail: {renamed} renamed, {skipped} skipped")

        admin_email = os.environ.get("SUPERSET_ADMIN_EMAIL")
        admin_pw = os.environ.get("SUPERSET_ADMIN_PASSWORD")
        if admin_email and admin_pw:
            admin = sm.find_user(email=admin_email)
            if admin is None:
                print(f"RESULT break-glass password: no user with e-mail {admin_email}")
            else:
                sm.reset_password(admin.id, admin_pw)
                db.session.commit()
                ok = check_password_hash(admin.password, admin_pw)
                print(f"RESULT break-glass password synced for {admin.username}: "
                      f"verified={ok}")
                if not ok:
                    raise SystemExit("password sync did not take effect")
        else:
            print("RESULT break-glass password: SUPERSET_ADMIN_EMAIL/PASSWORD unset")

        bad = [
            u.username
            for u in sm.get_all_users()
            if u.username not in SERVICE_ACCOUNTS and u.email and u.username != u.email
        ]
        print(f"RESULT usernames still mismatched: {bad if bad else 'none (correct)'}")


if __name__ == "__main__":
    main()
