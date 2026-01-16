# Container Configuration Reference

*Last Updated: January 16, 2026*

This document describes the build-time and runtime configuration options for each container in this repository.

## Configuration Types

| Type | When Applied | How to Set |
|------|--------------|------------|
| **ARG** | Build time | `--build-arg NAME=value` or in `docker-compose.yaml` |
| **ENV** | Runtime | `-e NAME=value` or in `docker-compose.yaml` |

---

## ansible

Ansible automation container with Python virtual environment.

### Build Arguments

| Argument | Default | Description |
|----------|---------|-------------|
| `OS_VERSION` | `latest` | Base Debian version |
| `VERSION` | `latest` | Ansible version to install |

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `VIRTUAL_ENV` | `/opt/ansible-venv` | Python virtual environment path |

### Ports

None exposed.

### Usage

```bash
# Build with specific Ansible version
./make build ansible 13.2.0

# Run playbook
docker run --rm -v $(pwd):/ansible ghcr.io/oorabona/ansible:latest ansible-playbook playbook.yml
```

---

## debian

Base Debian image with user configuration and locales.

### Build Arguments

| Argument | Default | Description |
|----------|---------|-------------|
| `VERSION` | `latest` | Debian version tag |
| `LOCALES` | `en_US` | Locale(s) to generate |
| `USER` | `debian` | Non-root username |
| `GROUP` | `debian` | User's primary group |
| `HOME` | `/home/${USER}` | User's home directory |
| `SHELL` | `/bin/bash` | User's default shell |
| `PASSWORD` | `debian` | User's password |

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `LANG` | `en_US.UTF-8` | System locale |
| `LANGUAGE` | `en_US.UTF-8` | Language setting |
| `LC_ALL` | `en_US.UTF-8` | Locale override |

### Ports

None exposed.

### Usage

```bash
# Build with French locale
./make build debian latest --build-arg LOCALES="fr_FR"

# Run interactive shell
docker run -it ghcr.io/oorabona/debian:latest bash
```

---

## openresty

OpenResty (Nginx + LuaJIT) with customizable modules.

### Build Arguments

| Argument | Default | Description |
|----------|---------|-------------|
| `VERSION` | `latest` | OpenResty version |
| `RESTY_IMAGE_BASE` | `alpine` | Base image |
| `RESTY_IMAGE_TAG` | `latest` | Base image tag |
| `ENABLE_HTTP_PROXY_CONNECT` | `false` | Enable HTTP CONNECT proxy |
| `RESTY_OPENSSL_VERSION` | (auto) | OpenSSL version |
| `RESTY_PCRE_VERSION` | (auto) | PCRE version |
| `RESTY_J` | `4` | Parallel build jobs |
| `RESTY_CONFIG_OPTIONS` | (complex) | Nginx configure options |
| `RESTY_CONFIG_OPTIONS_MORE` | `-j${RESTY_J}` | Additional configure options |
| `RESTY_ADD_PACKAGE_BUILDDEPS` | `""` | Extra build dependencies |
| `RESTY_ADD_PACKAGE_RUNDEPS` | `""` | Extra runtime dependencies |
| `LUAROCKS_VERSION` | `3.3.1` | LuaRocks version |

### Ports

Default: 80, 443 (via nginx config)

### Usage

```bash
# Build with HTTP CONNECT proxy support
./make build openresty latest --build-arg ENABLE_HTTP_PROXY_CONNECT=true

# Run with custom config
docker run -v $(pwd)/nginx.conf:/usr/local/openresty/nginx/conf/nginx.conf ghcr.io/oorabona/openresty:latest
```

---

## openvpn

OpenVPN server with easy-rsa PKI management.

### Build Arguments

| Argument | Default | Description |
|----------|---------|-------------|
| `OS_VERSION` | `latest` | Base Debian version |
| `VERSION` | `latest` | OpenVPN version |
| `NPROC` | `1` | Build parallelism |

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `OS` | `other` | Client OS type |

### Ports

| Port | Protocol | Description |
|------|----------|-------------|
| 1194 | UDP/TCP | OpenVPN tunnel |

### Usage

```bash
# Run OpenVPN server
docker run -d --cap-add=NET_ADMIN \
  -v openvpn-data:/etc/openvpn \
  -p 1194:1194/udp \
  ghcr.io/oorabona/openvpn:latest
```

---

## php

PHP-FPM for production applications with Composer.

### Build Arguments

| Argument | Default | Description |
|----------|---------|-------------|
| `VERSION` | (required) | PHP version |
| `COMPOSER_AUTH` | `""` | Composer authentication JSON |

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `APP_ENV` | `prod` | Application environment |
| `APP_DEBUG` | `0` | Debug mode (0/1) |
| `APP_BASE_PATH` | `/var/www/app/` | Application root |
| `COMPOSER_AUTH` | `""` | Composer auth config |
| `COMPOSER_CACHE_DIR` | `/var/www/.composer/` | Composer cache location |

### Ports

| Port | Protocol | Description |
|------|----------|-------------|
| 9000 | TCP | PHP-FPM FastCGI |

### Usage

```bash
# Build PHP 8.3
./make build php 8.3

# Run with app mounted
docker run -d \
  -v $(pwd)/app:/var/www/app \
  -e APP_ENV=dev \
  ghcr.io/oorabona/php:8.3
```

---

## postgres

PostgreSQL with locale support.

### Build Arguments

| Argument | Default | Description |
|----------|---------|-------------|
| `VERSION` | `latest` | PostgreSQL version |
| `LOCALES` | `""` | Additional locales to generate |

### Ports

Default: 5432 (standard PostgreSQL)

### Usage

```bash
# Build PostgreSQL 16
./make build postgres 16

# Run with persistent data
docker run -d \
  -v pgdata:/var/lib/postgresql/data \
  -e POSTGRES_PASSWORD=secret \
  ghcr.io/oorabona/postgres:16
```

---

## sslh

SSL/SSH multiplexer for port sharing.

### Build Arguments

| Argument | Default | Description |
|----------|---------|-------------|
| `OS_IMAGE_BASE` | `alpine` | Base image |
| `OS_IMAGE_TAG` | `latest` | Base image tag |
| `VERSION` | `latest` | sslh version |
| `NPROC` | `1` | Build parallelism |
| `USELIBCAP` | `1` | Enable libcap support |

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `USE_CONFIG` | `/etc/sslh.cfg` | Config file path |
| `USE_SSLH_FLAVOR` | `sslh-ev` | sslh binary variant |
| `LISTEN_IP` | `0.0.0.0` | Listen address |
| `LISTEN_PORT` | `443` | Listen port |
| `SSH_HOST` | `localhost` | SSH backend host |
| `SSH_PORT` | `22` | SSH backend port |
| `OPENVPN_HOST` | `localhost` | OpenVPN backend host |
| `OPENVPN_PORT` | `1194` | OpenVPN backend port |
| `HTTPS_HOST` | `localhost` | HTTPS backend host |
| `HTTPS_PORT` | `8443` | HTTPS backend port |

### Ports

| Port | Protocol | Description |
|------|----------|-------------|
| 443 | TCP | Multiplexed SSL/SSH/OpenVPN |

### Usage

```bash
# Run sslh multiplexer
docker run -d \
  -p 443:443 \
  -e SSH_HOST=192.168.1.10 \
  -e HTTPS_HOST=192.168.1.20 \
  ghcr.io/oorabona/sslh:latest
```

---

## terraform

Terraform with cloud CLIs and linting tools.

### Build Arguments

| Argument | Default | Description |
|----------|---------|-------------|
| `VERSION` | `latest` | Terraform version |
| `TFLINT_VERSION` | (auto) | TFLint version |
| `TRIVY_VERSION` | (auto) | Trivy version |
| `TERRAGRUNT_VERSION` | (auto) | Terragrunt version |
| `TERRAFORM_DOCS_VERSION` | (auto) | terraform-docs version |
| `GITHUB_CLI_VERSION` | (auto) | GitHub CLI version |
| `AWS_CLI_VERSION` | (auto) | AWS CLI version |
| `AZURE_CLI_VERSION` | (auto) | Azure CLI version |
| `GCP_CLI_VERSION` | (auto) | Google Cloud CLI version |

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `CONFIGFILE` | `config.json` | Tool configuration file |

### Ports

None exposed.

### Usage

```bash
# Build with specific Terraform version
./make build terraform 1.7.0

# Run terraform commands
docker run --rm -v $(pwd):/workspace -w /workspace \
  ghcr.io/oorabona/terraform:latest terraform plan
```

---

## wordpress

WordPress optimized for production with PHP-FPM.

### Build Arguments

| Argument | Default | Description |
|----------|---------|-------------|
| `PHP_VERSION` | `fpm` | PHP base image variant |

### Ports

| Port | Protocol | Description |
|------|----------|-------------|
| 9000 | TCP | PHP-FPM FastCGI |

### Usage

```bash
# Run WordPress with nginx
docker run -d \
  -v wp-content:/var/www/html/wp-content \
  -e WORDPRESS_DB_HOST=db \
  -e WORDPRESS_DB_USER=wp \
  -e WORDPRESS_DB_PASSWORD=secret \
  ghcr.io/oorabona/wordpress:latest
```

---

## Global Build Options

These options apply to all containers via the `./make` script:

| Variable | Default | Description |
|----------|---------|-------------|
| `NPROC` | (auto) | Parallel build jobs |
| `CUSTOM_BUILD_ARGS` | `""` | Additional Docker build arguments |
| `DOCKEROPTS` | `""` | Additional Docker options |

### Example

```bash
# Build with extra parallelism
NPROC=8 ./make build openresty latest

# Build with custom args
CUSTOM_BUILD_ARGS="--no-cache" ./make build php 8.3
```
