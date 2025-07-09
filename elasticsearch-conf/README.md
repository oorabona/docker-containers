# Elasticsearch Configuration Container

A lightweight container for managing Elasticsearch configuration using [confd](https://github.com/kelseyhightower/confd) and [Elasticsearch Curator](https://github.com/elastic/curator).

## Features

- **Configuration Management**: Uses confd to dynamically generate Elasticsearch configuration
- **Index Management**: Includes Elasticsearch Curator for index lifecycle management
- **Rancher Integration**: Designed to work with Rancher metadata service
- **Modern Base**: Built on Debian Bookworm for security and compatibility

## Usage

### With Docker Compose

```yaml
version: '3.8'
services:
  es-config:
    build: .
    volumes:
      - es-config:/usr/share/elasticsearch/config
      - ./conf.d:/data/confd
    environment:
      - ELASTICSEARCH_URL=http://elasticsearch:9200
```

### Direct Docker Run

```bash
docker run -d \
  --name es-config \
  -v es-config:/usr/share/elasticsearch/config \
  -v ./conf.d:/data/confd \
  -e ELASTICSEARCH_URL=http://elasticsearch:9200 \
  oorabona/elasticsearch-conf
```

## Configuration

The container expects configuration templates in `/etc/confd/conf.d` and `/etc/confd/templates`. 

### Environment Variables

- `ELASTICSEARCH_URL` - Elasticsearch cluster URL (default: http://localhost:9200)
- `CONFD_BACKEND` - Backend for confd (default: rancher)
- `CONFD_PREFIX` - Metadata prefix (default: /2015-07-25)

## Volumes

- `/data/confd` - Custom confd configuration
- `/opt/rancher/bin` - Rancher binaries
- `/usr/share/elasticsearch/config` - Generated Elasticsearch configuration

## Health Check

The container includes a health check that verifies confd is responding correctly.

## Building

```bash
cd elasticsearch-conf
docker build -t elasticsearch-conf .
```

## Version Management

This container uses automated version detection. Check the current version:

```bash
./version.sh          # Current version
./version.sh latest    # Latest available version
```
