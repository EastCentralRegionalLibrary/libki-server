#!/bin/sh
# Container start-up: migrate the database, make sure the instance and the
# admin user exist, then run the server. Safe to run on every start.
set -e
cd /app

./installer/update_db.pl

# Default (empty) instance is seeded by update_db.pl; named instances are not.
if [ -n "$LIBKI_INSTANCE" ]; then
    ./script/administration/create_instance.pl -i "$LIBKI_INSTANCE"
fi

# Creates the superadmin, or resets its password to the value in the environment.
if [ -n "$LIBKI_ADMIN_USERNAME" ] && [ -n "$LIBKI_ADMIN_PASSWORD" ]; then
    ./script/administration/create_user.pl -u "$LIBKI_ADMIN_USERNAME" -p "$LIBKI_ADMIN_PASSWORD" -s
else
    echo "NOTE: LIBKI_ADMIN_USERNAME / LIBKI_ADMIN_PASSWORD not set; no admin user created or updated." >&2
fi

exec plackup -s Gazelle --port "${LIBKI_SERVER_PORT:-3000}" --max-reqs-per-child 50000 \
    --max-workers "${LIBKI_MAX_WORKERS:-4}" -E production -a /app/libki.psgi
