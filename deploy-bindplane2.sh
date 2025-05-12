#!/bin/bash

# OpenTelemetry Demo - BindPlane Deployment Script

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}OpenTelemetry Demo - BindPlane Integration${NC}"
echo -e "${GREEN}===========================================${NC}"

# Check prerequisites
echo -e "\n${YELLOW}Checking prerequisites...${NC}"

if ! command -v docker &> /dev/null; then
    echo -e "${RED}Docker is not installed. Please install Docker first.${NC}"
    exit 1
fi

if ! command -v docker-compose &> /dev/null && ! docker compose version &> /dev/null; then
    echo -e "${RED}Docker Compose is not installed. Please install Docker Compose first.${NC}"
    exit 1
fi

# Check if we have docker compose v2
if docker compose version &> /dev/null; then
    COMPOSE_CMD="docker compose"
else
    COMPOSE_CMD="docker-compose"
fi

# Clone the demo repository if it doesn't exist
if [ ! -d "opentelemetry-demo" ]; then
    echo -e "\n${YELLOW}Cloning OpenTelemetry demo repository...${NC}"
    git clone https://github.com/open-telemetry/opentelemetry-demo.git
fi

cd opentelemetry-demo

# Create bindplane directory
echo -e "\n${YELLOW}Creating BindPlane configuration directory...${NC}"
mkdir -p bindplane

# Check if .env.bindplane exists and has a license key
if [ ! -f ".env.bindplane" ] || ! grep -q "BINDPLANE_LICENSE=" .env.bindplane || grep -q "BINDPLANE_LICENSE=YOUR_LICENSE_KEY_HERE" .env.bindplane; then
    echo -e "\n${RED}BindPlane license key not found.${NC}"
    echo -e "${YELLOW}Please enter your BindPlane license key (get one from https://bindplane.com/download):${NC}"
    read -p "License Key: " license_key
    
    # Generate sessions secret
    if command -v uuidgen &> /dev/null; then
        sessions_secret=$(uuidgen)
    else
        sessions_secret=$(openssl rand -hex 32)
    fi
    
    # Create .env.bindplane with the license key
    cat > .env.bindplane << EOF
# BindPlane Configuration
BINDPLANE_LICENSE=$license_key
BINDPLANE_USERNAME=admin
BINDPLANE_PASSWORD=admin
POSTGRES_PASSWORD=bindplane
SESSIONS_SECRET=$sessions_secret
EOF
    
    echo -e "${GREEN}Created .env.bindplane with your license key${NC}"
fi

# Create Docker Compose files
echo -e "\n${YELLOW}Creating Docker Compose configuration files...${NC}"

# Create docker-compose-bindplane.yml
cat > docker-compose-bindplane.yml << 'EOF'
version: '3.9'

services:
  # BindPlane Collector (replacing the original OpenTelemetry collector)
  bindplane-collector:
    image: ghcr.io/observiq/bindplane-agent:latest
    container_name: bindplane-collector
    hostname: bindplane-collector
    deploy:
      resources:
        limits:
          memory: 512M
    restart: unless-stopped
    command: ["--config=/etc/bindplane/config.yaml"]
    volumes:
      - ./bindplane/collector-config.yaml:/etc/bindplane/config.yaml
    ports:
      - "10000:10000"                                 # Envoy Tracing port
      - "11000:11000"                                 # Envoy Health Check port
      - "4317:4317"                                   # OTLP over gRPC receiver
      - "4318:4318"                                   # OTLP over HTTP receiver
      - "55679:55679"                                 # ZPages port
      - "9464:9464"                                   # Prometheus receiver
      - "4319:4319"                                   # OTLP Prometheus exporter
      - "9411:9411"                                   # Zipkin receiver
    environment:
      - ENVOY_PORT=10000
      - FEATURE_FLAG_SERVICE_ADDR=featureflagservice:50053
      - KAFKA_SERVICE_ADDR=kafka:9092
    networks:
      - demo
    depends_on:
      - jaeger
      - kafka

  # BindPlane Server
  bindplane:
    image: ghcr.io/observiq/bindplane-ee:latest
    container_name: bindplane
    hostname: bindplane
    deploy:
      resources:
        limits:
          memory: 512M
    restart: unless-stopped
    ports:
      - "3001:3001"  # Web UI and API
    volumes:
      - ./bindplane/server-config.yaml:/etc/bindplane/config.yaml
      - bindplane-data:/var/lib/bindplane
    environment:
      - BINDPLANE_LICENSE=${BINDPLANE_LICENSE}
      - BINDPLANE_USERNAME=${BINDPLANE_USERNAME:-admin}
      - BINDPLANE_PASSWORD=${BINDPLANE_PASSWORD:-admin}
      - BINDPLANE_REMOTE_URL=http://bindplane:3001
      - POSTGRES_PASSWORD=${POSTGRES_PASSWORD:-bindplane}
      - SESSIONS_SECRET=${SESSIONS_SECRET}
    networks:
      - demo
    depends_on:
      - bindplane-postgres

  # PostgreSQL for BindPlane
  bindplane-postgres:
    image: postgres:15-alpine
    container_name: bindplane-postgres
    hostname: bindplane-postgres
    deploy:
      resources:
        limits:
          memory: 256M
    restart: unless-stopped
    environment:
      - POSTGRES_DB=bindplane
      - POSTGRES_USER=bindplane
      - POSTGRES_PASSWORD=${POSTGRES_PASSWORD:-bindplane}
    volumes:
      - postgres-data:/var/lib/postgresql/data
    networks:
      - demo

volumes:
  bindplane-data:
  postgres-data:

networks:
  demo:
    external: true
EOF

# Create BindPlane collector config
cat > bindplane/collector-config.yaml << 'EOF'
receivers:
  otlp:
    protocols:
      grpc:
        endpoint: 0.0.0.0:4317
      http:
        endpoint: 0.0.0.0:4318
        cors:
          allowed_origins:
            - "http://*"
            - "https://*"
  
  prometheus:
    config:
      scrape_configs:
        - job_name: 'featureflag'
          scrape_interval: 2s
          static_configs:
            - targets: ['${FEATURE_FLAG_SERVICE_ADDR}']
  
  zipkin:
    endpoint: 0.0.0.0:9411

processors:
  batch:
    timeout: 5s
    send_batch_size: 1024
  
  memory_limiter:
    check_interval: 1s
    limit_mib: 384
    spike_limit_mib: 128
  
  resource:
    attributes:
      - key: deployment.environment
        value: demo
        action: upsert
  
  spanmetrics:
    metrics_exporter: prometheus
    latency_histogram_buckets: [2ms, 6ms, 10ms, 25ms, 50ms, 100ms, 250ms, 500ms, 1000ms, 1400ms, 2000ms, 5s, 10s, 25s, 50s, 100s]
    dimensions:
      - name: http.method
        default: GET
      - name: http.status_code
      - name: http.route
    dimensions_cache_size: 1000
    aggregation_temporality: "AGGREGATION_TEMPORALITY_CUMULATIVE"
    metrics_flush_interval: 15s

exporters:
  # Export to the demo's Jaeger instance
  otlp/jaeger:
    endpoint: jaeger:4317
    tls:
      insecure: true
  
  # Export to the demo's Prometheus instance
  prometheus:
    endpoint: 0.0.0.0:9464
    const_labels:
      collector: bindplane
  
  # Export to Kafka (for async processing)
  kafka:
    brokers:
      - ${KAFKA_SERVICE_ADDR}
    topic: otel

  debug:
    verbosity: detailed

extensions:
  health_check:
    endpoint: 0.0.0.0:13133
    check_collector_pipeline:
      enabled: true
      interval: 5s
      exporter_failure_threshold: 5
  
  zpages:
    endpoint: 0.0.0.0:55679
  
  pprof:
    endpoint: 0.0.0.0:1999

service:
  extensions: [health_check, zpages, pprof]
  pipelines:
    traces:
      receivers: [otlp, zipkin]
      processors: [memory_limiter, batch, resource, spanmetrics]
      exporters: [otlp/jaeger, kafka, debug]
    
    metrics:
      receivers: [otlp, prometheus, spanmetrics]
      processors: [memory_limiter, batch, resource]
      exporters: [prometheus, debug]
EOF

# Create BindPlane server config
cat > bindplane/server-config.yaml << 'EOF'
# BindPlane Server Configuration
port: 3001
host: 0.0.0.0

# Authentication configuration
auth:
  type: basic
  basic:
    username: ${BINDPLANE_USERNAME}
    password: ${BINDPLANE_PASSWORD}

# License key (required)
license: ${BINDPLANE_LICENSE}

# Backend storage configuration
store:
  type: postgres
  postgres:
    host: bindplane-postgres
    port: 5432
    database: bindplane
    username: bindplane
    password: ${POSTGRES_PASSWORD}
    sslmode: disable
    maxConnections: 20

# Remote URL for collectors to connect
remoteURL: http://bindplane:3001

# Session management
sessions:
  secret: ${SESSIONS_SECRET}

# Logging configuration
logging:
  level: info
  format: json
  output: stdout

# Telemetry configuration
telemetry:
  metrics:
    enabled: true
    port: 9090
    path: /metrics
EOF

# Create docker-compose.override.yml
cat > docker-compose.override.yml << 'EOF'
version: '3.9'

services:
  # Remove the original otel-collector service
  otel-collector:
    deploy:
      replicas: 0
    entrypoint: ["echo", "Replaced by bindplane-collector"]
    
  # Update all services to point to bindplane-collector
  accounting:
    environment:
      - OTEL_EXPORTER_OTLP_ENDPOINT=http://bindplane-collector:4317
      - COLLECTOR_SERVICE_ADDR=bindplane-collector:4317
  
  ad:
    environment:
      - OTEL_EXPORTER_OTLP_TRACES_ENDPOINT=http://bindplane-collector:4318/v1/traces
      - COLLECTOR_SERVICE_ADDR=bindplane-collector:4317
  
  cart:
    environment:
      - OTEL_EXPORTER_OTLP_ENDPOINT=bindplane-collector:4317
      - COLLECTOR_SERVICE_ADDR=bindplane-collector:4317
  
  checkout:
    environment:
      - OTEL_EXPORTER_OTLP_TRACES_ENDPOINT=http://bindplane-collector:4317
      - COLLECTOR_SERVICE_ADDR=bindplane-collector:4317
  
  currency:
    environment:
      - OTEL_EXPORTER_OTLP_TRACES_ENDPOINT=http://bindplane-collector:4317
      - OTEL_EXPORTER_OTLP_METRICS_ENDPOINT=http://bindplane-collector:4317
      - COLLECTOR_SERVICE_ADDR=bindplane-collector:4317
  
  email:
    environment:
      - OTEL_EXPORTER_OTLP_TRACES_ENDPOINT=http://bindplane-collector:4318/v1/traces
      - COLLECTOR_SERVICE_ADDR=bindplane-collector:4317
  
  fraud-detection:
    environment:
      - OTEL_EXPORTER_OTLP_ENDPOINT=http://bindplane-collector:4318
      - COLLECTOR_SERVICE_ADDR=bindplane-collector:4317
  
  frontend:
    environment:
      - OTEL_EXPORTER_OTLP_TRACES_ENDPOINT=http://bindplane-collector:4318/v1/traces
      - PUBLIC_OTEL_EXPORTER_OTLP_TRACES_ENDPOINT=http://localhost:8080/otlp-http/v1/traces
      - OTEL_EXPORTER_OTLP_METRICS_ENDPOINT=http://bindplane-collector:4318/v1/metrics
      - COLLECTOR_SERVICE_ADDR=bindplane-collector:4317
  
  frontend-proxy:
    environment:
      - OTEL_COLLECTOR_HOST=bindplane-collector
      - ENVOY_PORT=10000
      - OTEL_COLLECTOR_PORT_GRPC=4317
      - OTEL_COLLECTOR_PORT_HTTP=4318
      - HEALTH_CHECK_ROUTE=11000
  
  image-provider:
    environment:
      - OTEL_COLLECTOR_GRPC_URL=bindplane-collector:4317
      - COLLECTOR_SERVICE_ADDR=bindplane-collector:4317
  
  load-generator:
    environment:
      - OTEL_EXPORTER_OTLP_ENDPOINT=http://bindplane-collector:4317
      - OTEL_EXPORTER_OTLP_INSECURE=true
      - LOCUST_HOST=http://frontendproxy:${FRONTEND_PROXY_PORT}
      - LOCUST_WEB_HOST=0.0.0.0
      - LOCUST_WEB_PORT=${LOAD_GENERATOR_PORT}
      - LOCUST_AUTOSTART=true
      - LOCUST_HEADLESS=${LOCUST_HEADLESS}
      - LOCUST_USERS=${LOCUST_USERS}
      - PROTOCOL_BUFFERS_PYTHON_IMPLEMENTATION=python
      - COLLECTOR_SERVICE_ADDR=bindplane-collector:4317
  
  payment:
    environment:
      - OTEL_EXPORTER_OTLP_ENDPOINT=http://bindplane-collector:4317
      - COLLECTOR_SERVICE_ADDR=bindplane-collector:4317
  
  product-catalog:
    environment:
      - OTEL_EXPORTER_OTLP_ENDPOINT=http://bindplane-collector:4317
      - COLLECTOR_SERVICE_ADDR=bindplane-collector:4317
  
  quote:
    environment:
      - OTEL_EXPORTER_OTLP_TRACES_ENDPOINT=http://bindplane-collector:4318/v1/traces
      - COLLECTOR_SERVICE_ADDR=bindplane-collector:4317
  
  recommendation:
    environment:
      - OTEL_PYTHON_LOGGING_AUTO_INSTRUMENTATION_ENABLED=true
      - OTEL_EXPORTER_OTLP_ENDPOINT=http://bindplane-collector:4317
      - PROTOCOL_BUFFERS_PYTHON_IMPLEMENTATION=python
      - COLLECTOR_SERVICE_ADDR=bindplane-collector:4317
  
  shipping:
    environment:
      - OTEL_EXPORTER_OTLP_TRACES_ENDPOINT=http://bindplane-collector:4317
      - COLLECTOR_SERVICE_ADDR=bindplane-collector:4317
EOF

# Merge environment files
echo -e "\n${YELLOW}Merging environment files...${NC}"
if [ -f ".env" ]; then
    cp .env .env.original
    cat .env.original .env.bindplane > .env
else
    cp .env.bindplane .env
fi

# Create the network if it doesn't exist
echo -e "\n${YELLOW}Creating Docker network...${NC}"
docker network create demo 2>/dev/null || true

# Start the services
echo -e "\n${YELLOW}Starting services...${NC}"
${COMPOSE_CMD} -f docker-compose.yml \
               -f docker-compose-bindplane.yml \
               -f docker-compose.override.yml \
               up -d

# Wait for services to be ready
echo -e "\n${YELLOW}Waiting for services to start...${NC}"
sleep 10

# Check service status
echo -e "\n${GREEN}Checking service status...${NC}"
${COMPOSE_CMD} ps

echo -e "\n${GREEN}Deployment complete!${NC}"
echo -e "\n${YELLOW}Access the services:${NC}"
echo -e "  ${GREEN}OpenTelemetry Demo:${NC} http://localhost:8080"
echo -e "  ${GREEN}BindPlane UI:${NC}      http://localhost:3001 (admin/admin)"
echo -e "  ${GREEN}Jaeger UI:${NC}         http://localhost:16686"
echo -e "  ${GREEN}Grafana:${NC}           http://localhost:3000"
echo -e "  ${GREEN}Prometheus:${NC}        http://localhost:9090"

echo -e "\n${YELLOW}Next steps:${NC}"
echo -e "1. Access BindPlane UI at http://localhost:3001"
echo -e "2. Log in with username: admin, password: admin"
echo -e "3. Create a new configuration in BindPlane"
echo -e "4. Apply the configuration to your collector"

echo -e "\n${YELLOW}To stop the services:${NC}"
echo -e "${COMPOSE_CMD} -f docker-compose.yml -f docker-compose-bindplane.yml -f docker-compose.override.yml down"

echo -e "\n${YELLOW}To view logs:${NC}"
echo -e "docker logs bindplane"
echo -e "docker logs bindplane-collector"
