# ES Kopf - Elasticsearch Management Interface

A lightweight containerized version of Kopf (now Cerebro), a web administration tool for Elasticsearch clusters. This container provides an easy-to-deploy management interface for monitoring and managing Elasticsearch.

## Features

- **Cluster Monitoring**: Real-time cluster health and statistics
- **Index Management**: Create, delete, and manage indices
- **Query Interface**: Execute queries directly from the web interface
- **Node Information**: Detailed node statistics and configuration
- **Nginx-Powered**: Lightweight nginx-based delivery

## Usage

### With Docker Compose

```yaml
version: '3.8'
services:
  es-kopf:
    build: .
    ports:
      - "8080:80"
    environment:
      - ELASTICSEARCH_URL=http://elasticsearch:9200
```

### Direct Docker Run

```bash
docker run -d \
  --name es-kopf \
  -p 8080:80 \
  -e ELASTICSEARCH_URL=http://elasticsearch:9200 \
  oorabona/es-kopf
```

### Access the Interface

Open your browser and navigate to:
- `http://localhost:8080` (when running locally)
- Connect to your Elasticsearch cluster using the web interface

## Configuration

### Environment Variables

- `ELASTICSEARCH_URL` - Elasticsearch cluster URL (default: http://localhost:9200)
- `NGINX_PORT` - Internal nginx port (default: 80)

## Features

### Cluster Overview
- Cluster health status
- Node information and statistics
- Shard allocation and distribution

### Index Management
- List all indices with statistics
- Create and delete indices
- Manage index settings and mappings

### Query Interface
- Execute search queries
- Browse and filter documents
- Query validation and formatting

## Building

```bash
cd es-kopf
docker build -t es-kopf .
```

## Version Management

This container tracks the ES Kopf/Cerebro project versions:

```bash
./version.sh          # Current version
./version.sh latest    # Latest available version
```

## Security Considerations

- The interface provides administrative access to Elasticsearch
- Consider using authentication/authorization in production
- Limit network access to trusted users only
- Use HTTPS in production environments

## Alternatives

For newer Elasticsearch versions, consider:
- **Kibana** - Official Elasticsearch management interface
- **Cerebro** - Successor to Kopf
- **Elasticsearch Head** - Another web interface option
