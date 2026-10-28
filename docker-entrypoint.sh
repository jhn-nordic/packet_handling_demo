#!/bin/sh
set -e
cd /pb

# Apply migrations first so the superuser can be created on a fresh volume.
./pocketbase migrate up --dir=/pb/pb_data --migrationsDir=/pb/pb_migrations >/dev/null

# Create/update the admin account from env, so nobody has to claim the
# one-time install link printed on first start.
if [ -n "$PB_ADMIN_EMAIL" ] && [ -n "$PB_ADMIN_PASSWORD" ]; then
  ./pocketbase superuser upsert "$PB_ADMIN_EMAIL" "$PB_ADMIN_PASSWORD" --dir=/pb/pb_data >/dev/null
  echo "Superuser $PB_ADMIN_EMAIL ready — admin UI at /_/"
fi

exec ./pocketbase "$@" \
  --dir=/pb/pb_data \
  --hooksDir=/pb/pb_hooks \
  --migrationsDir=/pb/pb_migrations \
  --publicDir=/pb/pb_public
