# vLLM Monitoring Stack: Prometheus + Grafana

This is a **separate, independent monitoring stack** for monitoring vLLM inference servers with Prometheus and Grafana.

## Quick Start

### 1. Prepare Environment

```bash
cd monitoring/
cp .env.example .env
chmod 600 .env
# Edit .env and change GRAFANA_ADMIN_PASSWORD
```

### 2. Start Services

```bash
docker compose up -d

# Wait for services to be healthy
watch -n 2 docker compose ps
```

### 3. Access Dashboards

From your local machine, set up SSH tunnels:

```bash
# Terminal 1: Prometheus tunnel
ssh -L 9090:127.0.0.1:9090 user@<monitoring-host>

# Terminal 2: Grafana tunnel
ssh -L 3000:127.0.0.1:3000 user@<monitoring-host>
```

Then open in browser:
- **Prometheus**: http://localhost:9090
- **Grafana**: http://localhost:3000 (login: admin / password-from-.env)

### 4. Configure vLLM Servers

See `../MONITORING_QUICKSTART.md` Phase 3 for detailed instructions to:
- Enable metrics export on llm1 (10.75.9.21)
- Enable metrics export on llm2 (10.75.9.22) with MIG support
- Start NVIDIA DCGM exporter on both servers

## Directory Structure

```
monitoring/
├── docker-compose.yml          # Independent monitoring stack
├── .env.example               # Monitoring-specific env vars
├── README.md                  # This file
├── prometheus/
│   └── prometheus.yml         # Prometheus scrape configuration
├── dashboards/
│   ├── vllm-monitoring.json   # Grafana dashboard (8 panels)
│   └── dashboard-provider.yml # Dashboard auto-provisioning
└── datasources/
    └── prometheus.yml         # Grafana datasource config
```

## Configuration

### Environment Variables (.env)

| Variable | Default | Description |
|----------|---------|-------------|
| `PROMETHEUS_IMAGE_TAG` | v3.2.0 | Prometheus Docker image version |
| `PROMETHEUS_HOST_PORT` | 127.0.0.1:9090 | Prometheus port (internal-only) |
| `GRAFANA_IMAGE_TAG` | 11.6.0 | Grafana Docker image version |
| `GRAFANA_ADMIN_USER` | admin | Grafana admin username |
| `GRAFANA_ADMIN_PASSWORD` | admin | Grafana admin password (**CHANGE THIS**) |
| `GRAFANA_HOST_PORT` | 127.0.0.1:3000 | Grafana port (internal-only) |

### Prometheus Configuration

Edit `prometheus/prometheus.yml` to:
- Add/remove vLLM server scrape targets
- Configure DCGM exporter targets
- Add optional Node Exporter targets
- Adjust scrape intervals and retention

Default configuration scrapes:
- vLLM (llm1): 10.75.9.21:8000
- vLLM (llm2): 10.75.9.22:8000 (main), 10.75.9.22:8001 (MIG partition)
- NVIDIA DCGM (llm1 & llm2): :9400

### Grafana Dashboard

The pre-built dashboard (`dashboards/vllm-monitoring.json`) includes:
- Request throughput
- GPU memory usage
- Request latency (p95/p99/mean)
- Token generation rate
- GPU utilization
- Cache hit rate
- Error rate
- Summary statistics

Dashboard is auto-provisioned and ready to use after startup.

## Running Monitoring Stack

### Start

```bash
docker compose up -d
```

### Stop

```bash
docker compose down
```

### View Logs

```bash
docker compose logs -f prometheus
docker compose logs -f grafana
```

### Health Check

```bash
docker compose ps
```

All services should show "healthy" after ~30 seconds.

## Data Persistence

- **Prometheus data**: `prometheus_data` volume (30-day retention by default)
- **Grafana data**: `grafana_data` volume (dashboards, users, alerts)

Volumes are stored in Docker's default location. To back up:

```bash
# Backup Prometheus
docker compose exec prometheus tar -czf /tmp/prometheus-backup.tar.gz /prometheus

# Backup Grafana
docker compose exec grafana grafana-cli admin export-dashboard vllm-monitoring > vllm-dashboard-backup.json
```

## Troubleshooting

### Services won't start

```bash
# Check logs
docker compose logs

# Verify .env is configured
cat .env

# Ensure ports are not in use
netstat -tlnp | grep -E '9090|3000'
```

### Prometheus targets are DOWN

1. Verify vLLM servers are running and exporting metrics:
   ```bash
   curl -s http://10.75.9.21:8000/metrics | head -3
   ```

2. Verify DCGM exporter is running:
   ```bash
   curl -s http://10.75.9.21:9400/metrics | head -3
   ```

3. Check network connectivity from monitoring server:
   ```bash
   nc -zv 10.75.9.21 8000
   nc -zv 10.75.9.21 9400
   ```

4. Check Prometheus logs:
   ```bash
   docker compose logs prometheus | grep error
   ```

### Grafana shows no data

1. Wait 2-3 minutes for Prometheus to scrape and store data
2. Check Prometheus has data source configured: Grafana UI → Configuration → Data Sources
3. Verify at least one scrape has completed: Check Prometheus UI → Targets
4. Restart Grafana if needed: `docker compose restart grafana`

## Network Configuration

By default, the monitoring stack:
- Listens only on `127.0.0.1` (localhost)
- Must be accessed via SSH tunnel
- Does NOT expose ports to the internet

For production deployments, consider:
- Running behind a reverse proxy (nginx, caddy)
- Using authentication (OAuth, LDAP)
- Enabling HTTPS
- Restricting access by IP

## Separate from Main Infrastructure

This monitoring stack is **completely independent** from the LiteLLM + Langfuse stack:
- Separate `docker-compose.yml` and `.env`
- Separate Docker network (`monitoring` instead of `llm-net`)
- Can run on a different host
- Can be scaled up/down independently
- No dependencies on LiteLLM services

## Documentation

- **Setup guide**: `../MONITORING_QUICKSTART.md`
- **Complete reference**: `../MONITORING.md`
- **Health check script**: `../scripts/01_check_monitoring.sh`

## Next Steps

1. Review `../MONITORING_QUICKSTART.md` for complete end-to-end setup
2. Enable metrics export on vLLM servers (Phase 3)
3. Run health check script to verify everything is working
4. Create alerts in Grafana for production use

---

For questions or issues, see `../MONITORING.md` troubleshooting section.
