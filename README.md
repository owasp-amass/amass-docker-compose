# [![OWASP Logo](https://github.com/owasp-amass/amass/blob/master/images/owasp_logo.png) OWASP Amass](https://owasp.org/www-project-amass/)

<p align="center">
  <img src="https://github.com/owasp-amass/amass/blob/master/images/amass_video.gif">
</p>

[![OWASP Flagship](https://img.shields.io/badge/owasp-flagship%20project-48A646.svg)](https://owasp.org/projects/#sec-flagships)
[![License](https://img.shields.io/badge/license-apache%202-blue)](https://www.apache.org/licenses/LICENSE-2.0)
[![Follow on Twitter](https://img.shields.io/twitter/follow/owaspamass.svg?logo=twitter)](https://twitter.com/owaspamass)
[![Chat on Discord](https://img.shields.io/discord/433729817918308352.svg?logo=discord)](https://discord.gg/t7j6FeShKb)

**This repo is currently in a beta state. Use at your own risk**

The OWASP Amass Project performs network mapping of attack surfaces and external asset discovery using open source information gathering and active reconnaissance techniques.

## Docker Compose Setup Instructions

### Install the Compose Directory

1. Be sure you have an up-to-date version of Docker or Docker Desktop on your system.
2. Clone this repo: `git clone https://github.com/owasp-amass/amass-docker-compose.git`
3. Optional: you may want to rename the directory to something smaller (e.g. `amass`)
4. Make the local repo your current working directory: `cd amass-docker-compose`

### Configure the Compose Environment

1. Copy the template to create your environment file: `cp .env.template .env && chmod 0600 .env` — then edit `.env` and set a strong `POSTGRES_PASSWORD` and `AMASS_PASSWORD`. You may also change `AMASS_DB` and `AMASS_USER` if desired. **Credentials cannot be changed after the database has been created.**
2. PostgreSQL is the default database. To use Neo4j instead, set `DB_SERVER=neo4j` in `.env`. Database credentials and selection are handled automatically at container startup — no manual editing of `config/config.yaml` is needed.
3. Optional: update `config/datasources.yaml` by uncommenting data sources and adding account credentials.

### Build the Docker Images

1. Your Amass framework is now configured and ready to be built. Build and start all services with: `docker compose up -d`
2. If the build process times out, simply execute the command again to resume.

### Details about the Docker Environment

* All persistent data used exists on your host in the local repo root directory.
* The `assetdb` is a [PostgreSQL](https://github.com/postgres/postgres) database reachable from your localhost on port 5432.
* The `neo4j` is a [Neo4j](https://neo4j.com/) database reachable from your localhost on port 7474.
* Config files in the local repo are automatically mapped to where components expect to find them in the Docker environment.

### Usage: Amass Operations

Run Amass subcommands using `docker compose run --rm <service> [args]`. Each service is a one-shot container that connects to the running engine.

**enum** — Perform subdomain enumeration

```bash
docker compose run --rm enum -d example.com
docker compose run --rm enum -d example.com -active -brute
docker compose run --rm enum -alts -d example.com
```

**subs** — Query discovered subdomains and related data

```bash
docker compose run --rm subs -d example.com -show
docker compose run --rm subs -d example.com -names -ip
```

**assoc** — Walk association triples in the asset graph

```bash
docker compose run --rm assoc -t1 "example.com has_subdomain *"
```

**track** — List newly discovered assets

```bash
docker compose run --rm track -d example.com
docker compose run --rm track -d example.com -since "01/02 15:04:05 2006 MST"
```

**viz** — Generate graph visualizations (D3, DOT, GEXF)

```bash
docker compose run --rm viz -d example.com -d3 -o ./data/viz
docker compose run --rm viz -d example.com -dot -gexf -oA myresults
```

### Neo4j Browser

If you set `DB_SERVER=neo4j` in `.env`, you can browse the graph database at [http://127.0.0.1:7474](http://127.0.0.1:7474). Log in with username `neo4j` and the `AMASS_PASSWORD` value from your `.env` file.

### Tips

You can create a shell function to run Amass commands from any directory without typing the full `docker compose run --rm` prefix.

**Linux (Bash)**

Create a file (e.g. `~/.bashrc.d/amass`) with the following content:

```bash
function amass {
	docker compose -f <path to amass-docker-compose>/compose.yaml run --rm "$@"
}
```

Replace `<path to amass-docker-compose>` with the absolute path to your local repo.

Make it executable: `chmod +x ~/.bashrc.d/amass`

Reload your shell: `source ~/.bashrc.d/amass`

**macOS (Zsh)**

Add the following to your `~/.zshrc`:

```zsh
function amass {
	docker compose -f <path to amass-docker-compose>/compose.yaml run --rm "$@"
}
```

Replace `<path to amass-docker-compose>` with the absolute path to your local repo.

Reload your shell: `source ~/.zshrc`

**Windows (PowerShell)**

Add the following to your PowerShell profile (`$PROFILE`):

```powershell
function amass {
	docker compose -f "<path to amass-docker-compose>\compose.yaml" run --rm @args
}
```

Replace `<path to amass-docker-compose>` with the absolute path to your local repo.

Reload your profile: `. $PROFILE`

After reloading, you can run commands like:

```bash
amass enum -d owasp.org
amass subs -d owasp.org -names -ip
```

### Update Process for the Compose Environment

1. Make the local repo your current working directory: `cd amass-docker-compose`
2. Shutdown the Amass framework within the Docker environment: `docker compose down`
3. Backup the `assetdb`, `data`, and `logs` directories.
4. Update the compose local repo with the following command: `git pull origin main`

Your `.env` and `config/datasources.yaml` files are gitignored and will not be affected by `git pull`.

### Update Process for the Images

1. Make the local repo your current working directory: `cd amass-docker-compose`
2. Shutdown the Amass framework within the Docker environment: `docker compose down`
3. Update components from their GitHub repos: `docker compose build --pull --no-cache`
4. Your Amass framework is now up-to-date with the latest changes to the project.

## Corporate Supporters

[![ZeroFox Logo](https://github.com/owasp-amass/amass/blob/master/images/zerofox_logo.png)](https://www.zerofox.com/) [![WhoisXML API Logo](https://github.com/owasp-amass/amass/blob/master/images/whoisxmlapi_logo.png)](https://www.whoisxmlapi.com/)

## Testimonials

### [![Accenture Logo](https://github.com/owasp-amass/amass/blob/master/images/accenture_logo.png) Accenture](https://www.accenture.com/)

*"Accenture’s adversary simulation team has used Amass as our primary tool suite on a variety of external enumeration projects and attack surface assessments for clients. It’s been an absolutely invaluable basis for infrastructure enumeration, and we’re really grateful for all the hard work that’s gone into making and maintaining it – it’s made our job much easier!"*

\- Max Deighton, Accenture Cyber Defense Manager

### [![Visma Logo](https://github.com/owasp-amass/amass/blob/master/images/visma_logo.png) Visma](https://www.visma.com/)

*"For an internal red team, the organisational structure of Visma puts us against a unique challenge. Having sufficient, continuous visibility over our external attack surface is an integral part of being able to efficiently carry out our task. When dealing with hundreds of companies with different products and supporting infrastructure we need to always be on top of our game.*

*For years, OWASP Amass has been a staple in the asset reconnaissance field, and keeps proving its worth time after time. The tool keeps constantly evolving and improving to adapt to the new trends in this area."*

\- Joona Hoikkala ([@joohoi](https://github.com/joohoi)) & Alexis Fernández ([@six2dez](https://github.com/six2dez)), Visma Red Team

## Troubleshooting [![Chat on Discord](https://img.shields.io/discord/433729817918308352.svg?logo=discord)](https://discord.gg/t7j6FeShKb)

If you need help with installation and/or usage of the tool, please join our [Discord server](https://discord.gg/t7j6FeShKb) where community members can best help you.

:stop_sign:   **Please avoid opening GitHub issues for support requests or questions!**

## Licensing [![License](https://img.shields.io/badge/license-apache%202-blue)](https://www.apache.org/licenses/LICENSE-2.0)

This program is free software: you can redistribute it and/or modify it under the terms of the [Apache license](LICENSE). OWASP Amass and any contributions are Copyright © by Jeff Foley 2017-2025. Some subcomponents have separate licenses.

![Network graph](https://github.com/owasp-amass/amass/blob/master/images/network_06092018.png "Amass Network Mapping")
