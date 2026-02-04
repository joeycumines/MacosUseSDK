# Production Deployment Guide

This guide covers deploying MacosUseSDK MCP server in production environments with TLS, authentication, monitoring, and high availability considerations.

## Prerequisites

- macOS 12.0+ host with Accessibility permissions granted
- Go 1.21+ (for building from source)
- TLS certificates (self-signed for testing, CA-signed for production)
- (Optional) Prometheus/Grafana for monitoring

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                        Production Stack                         │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  ┌─────────────┐    ┌─────────────────┐    ┌────────────────┐  │
│  │   Clients   │───▶│  MCP Server     │───▶│ MacosUseServer │  │
│  │ (AI Agents) │    │  (Go/HTTP)      │    │ (Swift/gRPC)   │  │
│  └─────────────┘    └─────────────────┘    └────────────────┘  │
│         │                   │                      │            │
│         │ HTTPS/TLS         │ Metrics              │ AX APIs    │
│         │ + API Key         ▼                      ▼            │
│         │           ┌─────────────┐        ┌────────────┐       │
│         │           │ Prometheus  │        │  macOS UI  │       │
│         │           │  /Grafana   │        │            │       │
│         │           └─────────────┘        └────────────┘       │
│         │                                                       │
│         ▼                                                       │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │              Reverse Proxy (Optional)                    │   │
│  │              nginx / Caddy / HAProxy                     │   │
│  └─────────────────────────────────────────────────────────┘   │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

## Quick Start: Minimal Production Setup

```bash
# 1. Generate API key
export MCP_API_KEY=$(openssl rand -base64 32)
echo "API Key: $MCP_API_KEY"

# 2. Generate self-signed certificate (for testing)
openssl req -x509 -newkey rsa:4096 -nodes \
  -keyout server.key -out server.crt -days 365 \
  -subj "/CN=localhost"

# 3. Start MCP server with TLS and authentication
MCP_TRANSPORT=sse \
  MCP_HTTP_ADDRESS=:8443 \
  MCP_TLS_CERT_FILE=./server.crt \
  MCP_TLS_KEY_FILE=./server.key \
  MCP_API_KEY="$MCP_API_KEY" \
  MCP_RATE_LIMIT=100 \
  MCP_AUDIT_LOG_FILE=./audit.log \
  ./mcp-tool
```

## TLS Certificate Setup

### Option 1: Let's Encrypt (Recommended for Internet-Facing)

```bash
# Install certbot
brew install certbot

# Obtain certificate (requires domain and port 80 access)
sudo certbot certonly --standalone -d mcp.yourdomain.com

# Certificate paths
# /etc/letsencrypt/live/mcp.yourdomain.com/fullchain.pem
# /etc/letsencrypt/live/mcp.yourdomain.com/privkey.pem
```

```bash
# Start with Let's Encrypt certificates
MCP_TRANSPORT=sse \
  MCP_TLS_CERT_FILE=/etc/letsencrypt/live/mcp.yourdomain.com/fullchain.pem \
  MCP_TLS_KEY_FILE=/etc/letsencrypt/live/mcp.yourdomain.com/privkey.pem \
  MCP_API_KEY="$MCP_API_KEY" \
  ./mcp-tool
```

### Option 2: Self-Signed Certificate (Internal Use)

```bash
# Generate CA
openssl genrsa -out ca.key 4096
openssl req -new -x509 -days 3650 -key ca.key -out ca.crt \
  -subj "/CN=MacosUseSDK CA"

# Generate server key and CSR
openssl genrsa -out server.key 4096
openssl req -new -key server.key -out server.csr \
  -subj "/CN=mcp-server"

# Create extension file for SAN
cat > server.ext << EOF
authorityKeyIdentifier=keyid,issuer
basicConstraints=CA:FALSE
keyUsage = digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = @alt_names

[alt_names]
DNS.1 = localhost
DNS.2 = mcp-server
DNS.3 = mcp-server.local
IP.1 = 127.0.0.1
IP.2 = ::1
EOF

# Sign server certificate
openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key \
  -CAcreateserial -out server.crt -days 365 \
  -extfile server.ext

# Distribute ca.crt to clients for trust
```

### Option 3: Corporate PKI

Follow your organization's certificate request process. Ensure the certificate includes:
- Extended Key Usage: serverAuth
- Subject Alternative Names for all hostnames/IPs used

## Reverse Proxy Patterns

### nginx Configuration

```nginx
# /etc/nginx/sites-available/mcp-server
upstream mcp_backend {
    server 127.0.0.1:8080;
    keepalive 32;
}

server {
    listen 443 ssl http2;
    server_name mcp.yourdomain.com;

    ssl_certificate /etc/letsencrypt/live/mcp.yourdomain.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/mcp.yourdomain.com/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256;
    ssl_prefer_server_ciphers off;

    # Security headers
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
    add_header X-Content-Type-Options nosniff always;
    add_header X-Frame-Options DENY always;

    # API endpoint
    location /message {
        proxy_pass http://mcp_backend;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        
        # Timeouts for long operations
        proxy_read_timeout 300s;
        proxy_send_timeout 300s;
    }

    # SSE endpoint (requires special handling)
    location /events {
        proxy_pass http://mcp_backend;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header Connection '';
        proxy_buffering off;
        proxy_cache off;
        chunked_transfer_encoding off;
        
        # SSE needs long timeout
        proxy_read_timeout 3600s;
    }

    # Health check (no auth required)
    location /health {
        proxy_pass http://mcp_backend;
    }

    # Metrics (restrict to internal networks)
    location /metrics {
        allow 10.0.0.0/8;
        allow 172.16.0.0/12;
        allow 192.168.0.0/16;
        allow 127.0.0.1;
        deny all;
        proxy_pass http://mcp_backend;
    }
}

# Redirect HTTP to HTTPS
server {
    listen 80;
    server_name mcp.yourdomain.com;
    return 301 https://$server_name$request_uri;
}
```

### Caddy Configuration

```caddyfile
# Caddyfile
mcp.yourdomain.com {
    # Automatic HTTPS with Let's Encrypt
    
    # API and SSE endpoints
    reverse_proxy /message localhost:8080
    reverse_proxy /events localhost:8080 {
        # SSE requires disabling buffering
        flush_interval -1
    }
    
    # Health check
    reverse_proxy /health localhost:8080
    
    # Metrics - restrict to local
    @metrics {
        path /metrics
        remote_ip 127.0.0.1 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16
    }
    reverse_proxy @metrics localhost:8080
    
    # Block metrics from external
    @metrics_external {
        path /metrics
        not remote_ip 127.0.0.1 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16
    }
    respond @metrics_external 403
    
    # Security headers
    header {
        Strict-Transport-Security "max-age=31536000; includeSubDomains"
        X-Content-Type-Options nosniff
        X-Frame-Options DENY
    }
}
```

## Monitoring and Observability

### Prometheus Integration

The MCP server exposes metrics at `/metrics` in Prometheus text format.

**prometheus.yml:**
```yaml
global:
  scrape_interval: 15s

scrape_configs:
  - job_name: 'macos-use-mcp'
    static_configs:
      - targets: ['localhost:8080']
    metrics_path: '/metrics'
    scheme: 'https'
    tls_config:
      insecure_skip_verify: true  # For self-signed certs
    # If using API key auth, metrics endpoint is exempt
```

### Key Metrics to Monitor

| Metric | Alert Threshold | Description |
|--------|-----------------|-------------|
| `rate(mcp_requests_total{status="error"}[5m])` | > 10/min | Error rate spike |
| `histogram_quantile(0.99, rate(mcp_request_duration_seconds_bucket[5m]))` | > 5s | High latency |
| `mcp_sse_connections_active` | > 100 | Connection overload |
| `rate(mcp_sse_events_sent_total[5m])` | < 1/min | Connection stale |

### Grafana Dashboard

Create a dashboard with panels for:
1. Request rate by tool (stacked area chart)
2. Error rate percentage (gauge)
3. Latency percentiles (heatmap)
4. Active SSE connections (time series)

### Audit Log Analysis

Process audit logs with standard JSON tools:

```bash
# Recent errors
jq 'select(.status == "error")' audit.log | tail -10

# Slowest operations
jq -s 'sort_by(.duration_seconds) | reverse | .[0:10]' audit.log

# Request count by tool
jq -s 'group_by(.tool) | map({tool: .[0].tool, count: length})' audit.log
```

## Systemd Service Configuration

```ini
# /etc/systemd/system/macos-use-mcp.service
[Unit]
Description=MacosUseSDK MCP Server
After=network.target

[Service]
Type=simple
User=mcp
Group=mcp
WorkingDirectory=/opt/macos-use-sdk

# Environment
Environment=MCP_TRANSPORT=sse
Environment=MCP_HTTP_ADDRESS=:8080
Environment=MCP_TLS_CERT_FILE=/etc/ssl/certs/mcp-server.crt
Environment=MCP_TLS_KEY_FILE=/etc/ssl/private/mcp-server.key
Environment=MCP_RATE_LIMIT=100
Environment=MCP_AUDIT_LOG_FILE=/var/log/mcp/audit.log
EnvironmentFile=/etc/macos-use-sdk/env  # Contains MCP_API_KEY

ExecStart=/opt/macos-use-sdk/mcp-tool
Restart=always
RestartSec=5

# Security hardening
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/var/log/mcp

[Install]
WantedBy=multi-user.target
```

```bash
# Enable and start
sudo systemctl daemon-reload
sudo systemctl enable macos-use-mcp
sudo systemctl start macos-use-mcp

# Check status
sudo systemctl status macos-use-mcp
sudo journalctl -u macos-use-mcp -f
```

## launchd Configuration (macOS Native)

```xml
<!-- ~/Library/LaunchAgents/com.macos-use-sdk.mcp.plist -->
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.macos-use-sdk.mcp</string>
    
    <key>ProgramArguments</key>
    <array>
        <string>/opt/macos-use-sdk/mcp-tool</string>
    </array>
    
    <key>EnvironmentVariables</key>
    <dict>
        <key>MCP_TRANSPORT</key>
        <string>sse</string>
        <key>MCP_HTTP_ADDRESS</key>
        <string>:8443</string>
        <key>MCP_TLS_CERT_FILE</key>
        <string>/opt/macos-use-sdk/certs/server.crt</string>
        <key>MCP_TLS_KEY_FILE</key>
        <string>/opt/macos-use-sdk/certs/server.key</string>
        <key>MCP_API_KEY</key>
        <string>your-secret-key-here</string>
        <key>MCP_RATE_LIMIT</key>
        <string>100</string>
    </dict>
    
    <key>RunAtLoad</key>
    <true/>
    
    <key>KeepAlive</key>
    <true/>
    
    <key>StandardOutPath</key>
    <string>/var/log/mcp/stdout.log</string>
    
    <key>StandardErrorPath</key>
    <string>/var/log/mcp/stderr.log</string>
</dict>
</plist>
```

```bash
# Load the service
launchctl load ~/Library/LaunchAgents/com.macos-use-sdk.mcp.plist

# Check status
launchctl list | grep macos-use-sdk

# Unload
launchctl unload ~/Library/LaunchAgents/com.macos-use-sdk.mcp.plist
```

## Health Checks

### Basic Health Check

```bash
curl -s https://localhost:8443/health
# Expected: {"status":"ok"}
```

### Load Balancer Health Check Configuration

For AWS ALB/NLB or similar:
- Protocol: HTTPS (or HTTP if behind proxy)
- Path: `/health`
- Success codes: 200
- Interval: 30 seconds
- Timeout: 5 seconds
- Unhealthy threshold: 2

## Troubleshooting

### Common Issues

**Certificate errors:**
```bash
# Verify certificate
openssl x509 -in server.crt -text -noout

# Test TLS connection
openssl s_client -connect localhost:8443 -CAfile ca.crt
```

**Permission errors:**
```bash
# Grant Accessibility permissions
# System Preferences → Security & Privacy → Privacy → Accessibility
# Add Terminal.app or the mcp-tool binary
```

**Connection refused:**
```bash
# Check if server is listening
lsof -i :8443

# Check firewall
sudo pfctl -sr
```

**Rate limiting triggered:**
```bash
# Check current rate
curl -v https://localhost:8443/message ...
# Look for: HTTP/1.1 429 Too Many Requests
# Header: Retry-After: 1
```

## Environment Variable Reference

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `MCP_TRANSPORT` | No | `stdio` | Transport: `stdio` or `sse` |
| `MCP_HTTP_ADDRESS` | No | `:8080` | HTTP listen address |
| `MCP_HTTP_SOCKET` | No | _(none)_ | Unix socket path |
| `MCP_TLS_CERT_FILE` | No | _(none)_ | TLS certificate path |
| `MCP_TLS_KEY_FILE` | No | _(none)_ | TLS private key path |
| `MCP_API_KEY` | No | _(none)_ | API key for Bearer auth |
| `MCP_RATE_LIMIT` | No | `0` | Requests/second limit |
| `MCP_AUDIT_LOG_FILE` | No | _(none)_ | Audit log file path |
| `MCP_CORS_ORIGIN` | No | `*` | CORS allowed origin |
| `MCP_HEARTBEAT_INTERVAL` | No | `30s` | SSE heartbeat interval |
| `MACOS_USE_SERVER_ADDR` | No | `localhost:50051` | Backend gRPC address |
| `MACOS_USE_DEBUG` | No | `false` | Enable debug logging |
