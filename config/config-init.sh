#!/bin/sh
set -eu

# Source credentials from Docker secret
. /run/secrets/user_env_file

cfg=/.config/amass/config.yaml

# Resolve DB_SERVER once; default to sqlite when unset or empty
DB_SERVER="${DB_SERVER:-sqlite}"

# Select database: comment out the inactive, uncomment the active
if [ "$DB_SERVER" = "sqlite" ]; then
  # SQLite: comment out all network databases; session.go defaults to SQLite when GraphDBs is nil
  sed \
    -e 's|^  database: "bolt://|  # database: "bolt://|' \
    -e 's|^  database: "postgres://|  # database: "postgres://|' \
    "$cfg" > /tmp/config.yaml && mv /tmp/config.yaml "$cfg"
elif [ "$DB_SERVER" = "neo4j" ]; then
  sed \
    -e 's|^  database: "postgres://|  # database: "postgres://|' \
    -e 's|^  # database: "bolt://|  database: "bolt://|' \
    "$cfg" > /tmp/config.yaml && mv /tmp/config.yaml "$cfg"
else
  # postgres
  sed \
    -e 's|^  database: "bolt://|  # database: "bolt://|' \
    -e 's|^  # database: "postgres://|  database: "postgres://|' \
    "$cfg" > /tmp/config.yaml && mv /tmp/config.yaml "$cfg"
fi

# Substitute credential placeholders — only needed for neo4j/postgres
if [ "$DB_SERVER" != "sqlite" ]; then
  sed \
    -e "s|\${AMASS_USER}|${AMASS_USER:-}|g" \
    -e "s|\${AMASS_PASSWORD}|${AMASS_PASSWORD:-}|g" \
    -e "s|\${AMASS_DB}|${AMASS_DB:-}|g" \
    "$cfg" > /tmp/config.yaml && mv /tmp/config.yaml "$cfg"
fi
