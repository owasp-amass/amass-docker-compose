# Harden Docker Compose — Implementation Record

## Context

The compose.yaml had functional service orchestration but lacked production-grade security hardening. Several containers used no-op health checks, unpinned `:latest` images, ports bound to all interfaces, no capability restrictions, no log rotation, and a flat network where all services could reach each other. Nine categories of hardening were applied to `compose.yaml` in a single pass.

## Changes (all in `compose.yaml` unless noted)

### 1. Pin image versions

Replaced mutable `:latest` tags with specific versions:

| Service | Before | After |
|---------|--------|-------|
| config-init | `alpine:latest` | `alpine:3.21` |
| neo4j | `neo4j:latest` | `neo4j:2026.01.4` |
| postal | `ghcr.io/le0pard/postal_server:latest` | `ghcr.io/le0pard/postal_server:v0.3.1` |
| syslog | `lscr.io/linuxserver/syslog-ng:latest` | `lscr.io/linuxserver/syslog-ng:4.8.1` |

### 2. Replace no-op health checks

**neo4j** — replaced `exit 0` with a cypher-shell query:
```yaml
healthcheck:
  test: ["CMD-SHELL", "cypher-shell -u neo4j -p \"$${AMASS_PASSWORD}\" 'RETURN 1' || exit 1"]
  start_period: 30s
  interval: 10s
  timeout: 5s
  retries: 5
```

**syslog** — replaced `exit 0` with syslog-ng-ctl:
```yaml
healthcheck:
  test: ["CMD-SHELL", "syslog-ng-ctl healthcheck --timeout 5 -c /config/syslog-ng.ctl || exit 1"]
  start_period: 10s
  interval: 30s
  timeout: 10s
  retries: 3
```

### 3. Bind published ports to localhost

Prevents database ports from being accessible across the network:

```yaml
# assetdb
ports:
  - "127.0.0.1:55432:5432"

# neo4j
ports:
  - "127.0.0.1:7474:7474"
  - "127.0.0.1:7687:7687"
```

### 4. Mount config read-only on client services

Client services (enum, viz, subs, assoc, track) only read config after config-init has prepared it. Changed from `:rw` to `:ro`:

```yaml
volumes:
  - ./config:/.config/amass:ro
  - ./data/<svc>:/data:rw
```

Config-init retains `:rw` since it writes to config.yaml.

### 5. Capability dropping and no-new-privileges

Added a YAML anchor for services that need zero capabilities:

```yaml
x-security-hardened: &security-hardened
  cap_drop: [ALL]
  security_opt: [no-new-privileges:true]
```

Applied `*security-hardened` to 8 services: enum, viz, subs, assoc, track, config-init, engine, postal. The anchor includes `DAC_OVERRIDE` because multiple services (config-init reading secrets, client tools writing output directories) need it to access files/directories when all other capabilities are dropped.

Services that need additional capabilities for entrypoint user-switching (gosu/s6-overlay) were configured individually without `no-new-privileges`:

| Service | cap_add | no-new-privileges | Reason |
|---------|---------|-------------------|--------|
| assetdb | CHOWN, DAC_OVERRIDE, FOWNER, SETGID, SETUID | no | gosu user-switching in entrypoint |
| neo4j | CHOWN, DAC_OVERRIDE, FOWNER, SETGID, SETUID | no | Entrypoint chowns `/var/lib/neo4j` before dropping to neo4j user |
| syslog | CHOWN, DAC_OVERRIDE, FOWNER, SETGID, SETUID | no | s6-overlay user-switching in entrypoint |

### 6. Log rotation

Added a YAML anchor applied to all 11 services:

```yaml
x-logging: &default-logging
  driver: json-file
  options:
    max-size: "10m"
    max-file: "3"
```

### 7. Resource limits

Added hard `limits` alongside existing `reservations`. Services without prior resource config received both:

| Service | Memory Limit | CPU Limit | PIDs Limit |
|---------|-------------|-----------|------------|
| config-init | 64M | 0.5 | 50 |
| enum, viz, subs, assoc, track | 512M | 1.0 | 100 |
| engine | 2048M | 2.0 | 200 |
| assetdb | 1024M | 1.0 | 200 |
| neo4j | 6144M | 2.0 | 200 |
| postal | 2048M | 2.0 | 200 |
| syslog | 256M | 0.5 | 100 |

Also reduced `shm_size` on assetdb from `4gb` to `256m` (sufficient for PostgreSQL shared buffers in this workload).

Client service resources use a shared anchor:

```yaml
x-client-deploy: &client-deploy
  resources:
    limits:
      cpus: '1.0'
      memory: 512M
      pids: 100
    reservations:
      memory: 256M
```

### 8. ~~Network segmentation~~ (reverted)

The original plan split the flat network into `amass-frontend` and `amass-backend` (internal). This was reverted back to a single `amass` network — see Deviations section.

### 9. README port binding documentation

Added a "Port Binding and Network Access" section to `README.md` after "Details about the Docker Environment" explaining:

- Database ports are bound to `127.0.0.1` and only accessible locally
- How to change bindings for remote access
- Security warning about exposing database ports

## YAML anchors summary

Three anchors reduce repetition across the file:

| Anchor | Purpose | Applied to |
|--------|---------|------------|
| `x-security-hardened` | `cap_drop: [ALL]` + `cap_add: [DAC_OVERRIDE]` + `no-new-privileges:true` | 8 services |
| `x-logging` | `json-file` driver, 10m/3 files | All 11 services |
| `x-client-deploy` | CPU/memory/PID limits + memory reservation | 5 client services |

## Files modified

| File | Action |
|------|--------|
| `compose.yaml` | All hardening changes — pins, healthchecks, ports, volumes, security, logging, resources, networks |
| `README.md` | Added port binding documentation section |

## Deviations from plan

**Syslog network placement**: The original plan placed syslog on `amass-backend` only. During implementation, it was discovered that all services reference `SYSLOG_HOST=syslog` in `config/logs/syslog.env` to send logs via UDP. Client services on `amass-frontend` need to resolve and reach the syslog hostname, which is impossible if syslog is only on the backend network. Syslog was therefore placed on **both** `amass-frontend` and `amass-backend` to maintain log connectivity for all services.

**DAC_OVERRIDE required throughout**: The plan dropped all capabilities without adding `DAC_OVERRIDE` back. Multiple services failed at runtime: config-init couldn't read Docker secrets, neo4j's entrypoint couldn't read directories before chowning, and client tools (viz, etc.) couldn't access output directories. `DAC_OVERRIDE` was added to the `x-security-hardened` anchor so all 8 services using it get the capability. Neo4j and assetdb already had it in their individual `cap_add` lists.

**Network segmentation reverted**: The plan split the single `amass` network into `amass-frontend` and `amass-backend` (with `internal: true`). During implementation, two issues emerged: (1) Docker cannot publish ports for containers exclusively on an internal network, forcing assetdb and neo4j onto both networks; (2) syslog needed both networks for log connectivity. With every backend service also on the frontend, the `internal: true` flag provided zero isolation benefit. Reverted to the original single `amass` bridged network. Config-init retains `network_mode: none`.

**Read-only config mounts reverted**: The plan changed client service config mounts from `:rw` to `:ro`, assuming they only read config after config-init prepares it. At runtime, the amass binary calls `chmod 0755` on `/.config/amass` during startup, which fails on a read-only filesystem. Reverted all client config mounts back to `:rw`.

**neo4j memory limit**: The plan set a 4096M container memory limit, but neo4j is configured with `NEO4J_server_memory_heap_max__size=4G`. The JVM heap alone consumes the entire limit, leaving no room for page cache, off-heap buffers, or JVM overhead. Neo4j rejected this at startup with "Invalid memory configuration - exceeds physical memory". Increased the container limit to 6144M to accommodate the 4G heap plus overhead.

## Verification

1. `docker compose config` — validated YAML parses correctly with all anchors resolved
2. Confirmed all 11 services have `cap_drop: [ALL]`
3. Confirmed 7 services have `no-new-privileges:true` (excluding assetdb, neo4j, syslog) plus config-init which has it with `DAC_OVERRIDE`
4. Confirmed network assignments: single `amass` network (10 services), `network_mode: none` (config-init)
