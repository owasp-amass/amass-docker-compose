#!/bin/sh
set -eu

# Source credentials from Docker secret
. /run/secrets/user_env_file

cfg=/.config/amass/config.yaml

# Select database backend from COMPOSE_PROFILES.
# Wrap value in commas so each profile name is matched exactly
# (e.g. "mypostgres" does not match the "postgres" case).
# Profiles not related to the database (tor, mcp, …) are ignored.
case ",${COMPOSE_PROFILES:-}," in
  *,postgres,*)
    # Activate postgres, comment out neo4j
    sed \
      -e 's|^  database: "bolt://|  # database: "bolt://|' \
      -e 's|^  # database: "postgres://|  database: "postgres://|' \
      "$cfg" > /tmp/config.yaml && mv /tmp/config.yaml "$cfg"
    # Substitute credential placeholders
    sed \
      -e "s|\${AMASS_USER}|${AMASS_USER:-}|g" \
      -e "s|\${AMASS_PASSWORD}|${AMASS_PASSWORD:-}|g" \
      -e "s|\${AMASS_DB}|${AMASS_DB:-}|g" \
      "$cfg" > /tmp/config.yaml && mv /tmp/config.yaml "$cfg"
    ;;
  *,neo4j,*)
    # Activate neo4j, comment out postgres
    sed \
      -e 's|^  database: "postgres://|  # database: "postgres://|' \
      -e 's|^  # database: "bolt://|  database: "bolt://|' \
      "$cfg" > /tmp/config.yaml && mv /tmp/config.yaml "$cfg"
    # Substitute credential placeholders
    sed \
      -e "s|\${AMASS_USER}|${AMASS_USER:-}|g" \
      -e "s|\${AMASS_PASSWORD}|${AMASS_PASSWORD:-}|g" \
      -e "s|\${AMASS_DB}|${AMASS_DB:-}|g" \
      "$cfg" > /tmp/config.yaml && mv /tmp/config.yaml "$cfg"
    ;;
  *)
    # SQLite (default): comment out all network database lines.
    # session.go falls back to its built-in SQLite when GraphDBs is nil.
    sed \
      -e 's|^  database: "bolt://|  # database: "bolt://|' \
      -e 's|^  database: "postgres://|  # database: "postgres://|' \
      "$cfg" > /tmp/config.yaml && mv /tmp/config.yaml "$cfg"
    ;;
esac
