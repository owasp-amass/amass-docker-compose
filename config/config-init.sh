#!/bin/sh
set -eu

# Source credentials from Docker secret
. /run/secrets/user_env_file

# Guard against default credentials — fail fast before touching config files.
if [ "${AMASS_PASSWORD:-}" = "ChangeMe!" ]; then
    echo "ERROR: AMASS_PASSWORD must be changed from the default 'ChangeMe!'" >&2
    exit 1
fi
if [ "${POSTGRES_PASSWORD:-}" = "ChangeMe!" ]; then
    echo "ERROR: POSTGRES_PASSWORD must be changed from the default 'ChangeMe!'" >&2
    exit 1
fi

cfg=/.config/amass/config.yaml
tmpfile=$(mktemp)
trap 'rm -f "$tmpfile"' EXIT

# Escape special characters in a sed replacement string.
# Handles backslash (escape char), pipe (our delimiter), and ampersand (& = matched text).
escape_sed() {
    printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/|/\\|/g' -e 's/&/\\&/g'
}

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
      "$cfg" > "$tmpfile" && mv "$tmpfile" "$cfg"
    # Substitute credential placeholders (escape values to protect sed delimiters)
    user=$(escape_sed "${AMASS_USER:-}")
    pass=$(escape_sed "${AMASS_PASSWORD:-}")
    db=$(escape_sed "${AMASS_DB:-}")
    tmpfile=$(mktemp)
    sed \
      -e "s|\${AMASS_USER}|${user}|g" \
      -e "s|\${AMASS_PASSWORD}|${pass}|g" \
      -e "s|\${AMASS_DB}|${db}|g" \
      "$cfg" > "$tmpfile" && mv "$tmpfile" "$cfg"
    ;;
  *,neo4j,*)
    # Activate neo4j, comment out postgres
    sed \
      -e 's|^  database: "postgres://|  # database: "postgres://|' \
      -e 's|^  # database: "bolt://|  database: "bolt://|' \
      "$cfg" > "$tmpfile" && mv "$tmpfile" "$cfg"
    # Substitute credential placeholders (escape values to protect sed delimiters)
    user=$(escape_sed "${AMASS_USER:-}")
    pass=$(escape_sed "${AMASS_PASSWORD:-}")
    db=$(escape_sed "${AMASS_DB:-}")
    tmpfile=$(mktemp)
    sed \
      -e "s|\${AMASS_USER}|${user}|g" \
      -e "s|\${AMASS_PASSWORD}|${pass}|g" \
      -e "s|\${AMASS_DB}|${db}|g" \
      "$cfg" > "$tmpfile" && mv "$tmpfile" "$cfg"
    ;;
  *)
    # SQLite (default): comment out all network database lines.
    # session.go falls back to its built-in SQLite when GraphDBs is nil.
    sed \
      -e 's|^  database: "bolt://|  # database: "bolt://|' \
      -e 's|^  database: "postgres://|  # database: "postgres://|' \
      "$cfg" > "$tmpfile" && mv "$tmpfile" "$cfg"
    ;;
esac
