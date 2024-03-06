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

### Configure and Build Images

1. Be sure you have an up-to-date version of Docker or Docker Desktop on your system.
2. Clone this repo: `git clone https://github.com/owasp-amass/amass-docker-compose.git`
3. Optional: you may want to rename the directory to something smaller (e.g. `amass`)
4. Make the local repo your current working directory: `cd amass-docker-compose`
5. Recommended: open the `config/assetdb.env` file and assign a new POSTGRES_PASSWORD and AMASS_PASSWORD. Save. **This cannot be performed after you start the Docker Compose and the database has been created.**
6. Make desired changes to the `config.yaml` file, being sure to replace the password field of the `database` value with the password you assigned as your AMASS_PASSWORD. Save.
7. Optional: update your `datasources.yaml` file by uncommenting data sources and adding account credentials.
8. Your Amass framework is now configured and ready to be built. Docker Compose will build the required images and start them correctly when you perform your first `amass` command execution.
9. Type the following to get started: `docker compose run --rm amass enum -d owasp.org`

### Update the Images from GitHub Repositories

1. Be sure you have an up-to-date version of Docker or Docker Desktop on your system.
2. Make the local repo your current working directory: `cd amass-docker-compose`
3. Shutdown the Amass framework within the Docker environment: `docker compose down`
4. Update components from their GitHub repos: `docker compose build --pull --no-cache`
5. Your Amass framework is now up-to-date with the latest changes to the project.

### Details about the Docker Environment

* All persistent data used exists on your host in the local repo root directory.
* The `assetdb` is a [PostgreSQL](https://github.com/postgres/postgres) database reachable from your localhost on port 5432.
* Config files in the local repo are automatically mapped to where components expect to find them in the Docker environment.
* Interact with the framework using the client program: `docker compose run --rm amass enum -d owasp.org`
* You can obtain information about your asset discoveries by accessing the web UI at the following URL: `http://127.0.0.1:3000`

### Utilize the IP2Location database

* Download the `IP2LOCATION-LITE-DB11.CSV` and `IP2LOCATION-LITE-DB11.IPV6.CSV` files into the compose directory.
* While the Amass Docker Compose is up, execute the `upload_ip2loc_data.sh` script to insert the data into the database.

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

This program is free software: you can redistribute it and/or modify it under the terms of the [Apache license](LICENSE). OWASP Amass and any contributions are Copyright © by Jeff Foley 2017-2024. Some subcomponents have separate licenses.

![Network graph](https://github.com/owasp-amass/amass/blob/master/images/network_06092018.png "Amass Network Mapping")
