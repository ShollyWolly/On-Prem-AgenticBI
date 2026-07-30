"""
Make every human Superset account's `username` equal its e-mail address.

WHY THIS IS NECESSARY, NOT COSMETIC
-----------------------------------
With AUTH_TYPE = AUTH_LDAP and AUTH_LDAP_UID_FIELD = "mail", the string a person
types is their e-mail, and Flask-AppBuilder then looks the LOCAL record up by
`username == <that string>`. Our accounts were created by `superset fab
create-admin --username admin`, so the record's username is `admin` while the
login identifier is `admin@demo.local`. FAB finds nothing, decides this is a
first-time LDAP login, and tries to REGISTER a new user -- which dies on the
unique e-mail constraint:

    Error adding new user to database. (psycopg2.errors.UniqueViolation)
    duplicate key value violates unique constraint "ab_user_email_key"
    DETAIL:  Key (email)=(analyst@demo.local) already exists.

The API answers a bare 401, so it reads as a wrong password. It is not: the
password never gets checked.

This is the same shape of bug as LibreChat's (see
scripts/migrate-librechat-ldap.sh): changing the login identifier orphans the
existing user records that were keyed on the old one. Both stores need the same
kind of realignment, for the same reason.

Renaming rather than deleting-and-recreating is deliberate: the admin account owns
the dashboard and all nine charts, and Superset tracks that by user id.

`mcp_reader` is deliberately EXCLUDED. It is a service account that never logs in
-- the MCP service resolves it by `MCP_DEV_USERNAME = "mcp_reader"`, so renaming it
would break every MCP tool call with "No authenticated user found".

Idempotent. Runs from Superset's own startup (see docker-compose.yml).
"""
from werkzeug.security import check_password_hash

from superset.app import create_app

# Never rename these: they are resolved BY USERNAME elsewhere in the stack.
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

            # A collision would mean two accounts share an e-mail, which the unique
            # index already forbids -- so this cannot silently merge two people.
            print(f"RESULT username {user.username} -> {user.email}")
            user.username = user.email
            renamed += 1

        db.session.commit()
        print(f"RESULT usernames aligned to e-mail: {renamed} renamed, {skipped} skipped")

        # ---- keep the break-glass password in sync -------------------------
        # This lives HERE, after the rename, and not as a `superset fab
        # reset-password` step earlier in provisioning. That is an ordering
        # requirement, not a preference:
        #
        #   `fab reset-password --username X` resolves by USERNAME. Before the
        #   rename above the admin's username is `admin`; after it, it is
        #   `admin@demo.local`. A step that hardcodes either one works on exactly
        #   one of {fresh stack, existing stack} and silently does nothing on the
        #   other -- which is what happened: the reset ran against `admin`, found
        #   nobody on an already-aligned stack, and the failure was swallowed.
        #
        # Resolving by E-MAIL is stable across the rename, so do it after.
        #
        # Why sync at all: SUPERSET_ADMIN_PASSWORD is now the same value as
        # DEMO_ADMIN_PASSWORD (one identity, one password), but `fab create-admin`
        # never updates an existing account's hash. Without this, a stack created
        # before that change keeps its old hash and the documented
        # SUPERSET_AUTH=db recovery path wants a password nobody has.
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

        # Assert the postcondition, because a half-aligned store fails as a 401 on
        # exactly the accounts that were missed.
        bad = [
            u.username
            for u in sm.get_all_users()
            if u.username not in SERVICE_ACCOUNTS and u.email and u.username != u.email
        ]
        print(f"RESULT usernames still mismatched: {bad if bad else 'none (correct)'}")


if __name__ == "__main__":
    main()
