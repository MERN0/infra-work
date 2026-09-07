# vLLM + Prometheus + Grafana Monitoring Setup

This guide covers setting up Prometheus and Grafana for monitoring vLLM inference servers (llm1 and llm2), with special handling for MIG-enabled GPUs on llm2.

## Quick Start

### 1. On the Monitoring Server (10.1.2.186)

Update your `.env` file:
```bash
# Add these to your .env (and change the admin password!)
GRAFANA_ADMIN_USER=admin
GRAFANA_ADMIN_PASSWORD=your-secure-password-here
PROMETHEUS_HOST_PORT=127.0.0.1:9090
GRAFANA_HOST_PORT=127.0.0.1:3000
```

Start the monitoring stack:
```bash
docker compose up -d prometheus grafana
```

Verify they're healthy:
```bash
docker compose ps
docker logs prometheus --tail 20
docker logs grafana --tail 20
```

Access Grafana via SSH tunnel:
```bash
ssh -L 3000:127.0.0.1:3000 user@10.1.2.186
# Then open http://localhost:3000 in your browser
# Default credentials: admin / your-password-from-.env
```

### 2. On vLLM Servers (llm1 and llm2)

#### Enable vLLM Metrics Export

**On llm1 (10.75.9.21) — no MIG:**

Start vLLM with metrics enabled:
```bash
python -m vllm.entrypoints.openai.api_server \
  --model gpt-oss-130b \
  --gpu-memory-utilization 0.9 \
  --port 8000 \
  --enable-prometheus-metrics  # <-- Key flag
```

Verify metrics endpoint:
```bash
curl -s http://localhost:8000/metrics | head -20
```

**On llm2 (10.75.9.22) — with MIG enabled:**

After enabling MIG on your GPU, you'll have multiple compute instances. For each vLLM instance, ensure `--enable-prometheus-metrics` is set.

If running 2 MIG instances:
```bash
# Instance 1 (partition 0)
CUDA_VISIBLE_DEVICES=0 python -m vllm.entrypoints.openai.api_server \
  --model model-1 \
  --port 8000 \
  --enable-prometheus-metrics

# Instance 2 (partition 1, in another terminal or process manager)
CUDA_VISIBLE_DEVICES=1 python -m vllm.entrypoints.openai.api_server \
  --model model-2 \
  --port 8001 \
  --enable-prometheus-metrics
```

Verify both endpoints:
```bash
curl -s http://localhost:8000/metrics | head -10
curl -s http://localhost:8001/metrics | head -10
```

#### Enable NVIDIA DCGM Exporter (for GPU/MIG metrics)

This exports low-level GPU metrics including MIG instance stats.

**Installation:**

```bash
# Install NVIDIA DCGM (if not already installed)
sudo apt-get update
sudo apt-get install -y nvidia-dcgm

# Start DCGM daemon
sudo systemctl start nvidia-dcgm
sudo systemctl enable nvidia-dcgm

# Run the DCGM exporter (listens on port 9400)
docker run -d \
  --name nvidia-dcgm-exporter \
  --restart unless-stopped \
  --gpus all \
  -p 9400:9400 \
  nvcr.io/nvidia/k8s/dcgm-exporter:3.1.7-3.1.4-ubuntu20.04
```

Verify DCGM metrics:
```bash
curl -s http://localhost:9400/metrics | grep -i gpu | head -20
```

**For MIG-enabled systems**, DCGM automatically exposes MIG instance metrics with labels like `gpu_uuid` and `mig_profile`.

#### (Optional) Enable Node Exporter for System Metrics

For CPU, memory, disk monitoring:

```bash
docker run -d \
  --name node-exporter \
  --restart unless-stopped \
  -p 9100:9100 \
  -v /proc:/host/proc:ro \
  -v /sys:/host/sys:ro \
  -v /:/rootfs:ro \
  prom/node-exporter:latest \
  --path.procfs=/host/proc \
  --path.sysfs=/host/sys \
  --collector.filesystem.mount-points-exclude=^/(sys|proc|dev|host|etc)($$|/)
```

## Prometheus Configuration

The `prometheus/prometheus.yml` file includes scrape jobs for:

1. **vLLM servers** (llm1 and llm2) — port 8000 (and 8001 for MIG instance 2)
2. **NVIDIA DCGM Exporter** (both servers) — port 9400
3. **Node Exporter** (both servers) — port 9100 *(optional, commented out)*

### Troubleshooting: Prometheus Not Scraping Data

**Check connectivity first:**
```bash
# From monitoring server, test network connectivity
nc -zv 10.75.9.21 8000  # vLLM llm1
nc -zv 10.75.9.22 8000  # vLLM llm2 main
nc -zv 10.75.9.21 9400  # DCGM llm1
nc -zv 10.75.9.22 9400  # DCGM llm2
```

**Check Prometheus logs for scrape errors:**
```bash
docker logs prometheus | grep -i error
docker logs prometheus | grep -i llm
```

**Manually verify target health in Prometheus UI:**
- SSH tunnel to Prometheus: `ssh -L 9090:127.0.0.1:9090 user@10.1.2.186`
- Open http://localhost:9090/targets
- Look for red X marks — click them to see error details

### Common Issues on llm2 After MIG Enablement

**Problem: "Connection refused" on llm2 metrics endpoint**
- **Cause**: vLLM process crashed or wasn't restarted with MIG visibility
- **Fix**: Verify vLLM is running and can see MIG devices:
  ```bash
  nvidia-smi -L                    # Shows MIG instances
  CUDA_VISIBLE_DEVICES=0 python -c "import torch; print(torch.cuda.device_count())"
  ```

**Problem: Duplicate metrics or inconsistent server labels**
- **Cause**: Multiple vLLM instances without proper CUDA_VISIBLE_DEVICES isolation
- **Fix**: Ensure each vLLM process is bound to exactly one MIG partition, set via `CUDA_VISIBLE_DEVICES`

**Problem: DCGM exporter shows no MIG metrics**
- **Cause**: DCGM daemon not running or MIG mode not properly enabled
- **Fix**: Verify MIG mode:
  ```bash
  sudo nvidia-smi -mig 1  # Enable MIG mode
  sudo nvidia-smi -mig --query-gpu=index,mig.mode.current --format=csv
  # Restart DCGM after enabling MIG:
  sudo systemctl restart nvidia-dcgm
  docker restart nvidia-dcgm-exporter
  ```

## Grafana Dashboard

The pre-configured dashboard (`grafana/provisioning/dashboards/vllm-monitoring.json`) includes:

1. **Request Throughput** — req/sec by server
2. **GPU Memory Usage** — percentage by server
3. **Request Latency** — p95/p99/mean by server
4. **Token Generation Rate** — prompt + completion tokens/sec
5. **GPU Utilization** — percentage by server
6. **Cache Hit Rate** — percentage by server
7. **Error Rate** — errors/sec by server and type
8. **Summary stats** — active servers, p99 latency

### Customizing the Dashboard

The dashboard is auto-provisioned and read-only by default. To edit it:

1. Grafana UI → Dashboards → vLLM Inference Monitoring
2. Click pencil icon → Edit
3. Customize panels, thresholds, colors, etc.
4. Click Save (saves to Grafana's database, not the JSON file)

To export updated dashboard for version control:
- Dashboard menu (top-right) → Share → Export → Download JSON
- Save to `grafana/provisioning/dashboards/vllm-monitoring.json` and commit

### Dashboard Tips

- **Filter by server**: Use the "Server" variable at top-left to focus on llm1 or llm2
- **Set alerts**: Click a panel's alert icon to trigger on thresholds (e.g., p99 latency > 5s)
- **Inspect metrics**: Click a panel → "Inspect" → "Data" to see raw metric values

## Metric Reference

### vLLM Metrics (from `--enable-prometheus-metrics`)

| Metric | Type | Description |
|--------|------|-------------|
| `vllm_request_total` | Counter | Total requests received |
| `vllm_request_duration_seconds` | Histogram | Request latency distribution |
| `vllm_prompt_tokens_total` | Counter | Total prompt tokens processed |
| `vllm_completion_tokens_total` | Counter | Total completion tokens generated |
| `vllm_cache_hit_total` | Counter | Cache hits |
| `vllm_cache_miss_total` | Counter | Cache misses |

### NVIDIA DCGM Metrics (from dcgm-exporter)

| Metric | Description |
|--------|-------------|
| `nvidia_dcgm_gpu_utilization` | GPU utilization (%) |
| `nvidia_dcgm_fb_free` | Free GPU memory (bytes) |
| `nvidia_dcgm_fb_used` | Used GPU memory (bytes) |
| `nvidia_dcgm_sm_clock` | SM (Streaming Multiprocessor) clock (MHz) |
| `nvidia_dcgm_power_usage` | GPU power consumption (W) |
| `nvidia_dcgm_gpu_temp` | GPU temperature (°C) |

For MIG instances, metrics include `mig_*` labels indicating which MIG partition.

### Node Exporter Metrics (optional)

| Metric | Description |
|--------|-------------|
| `node_cpu_seconds_total` | CPU time (counter) |
| `node_memory_MemAvailable_bytes` | Available memory |
| `node_disk_io_reads_total` | Disk read operations |

## Data Retention & Cleanup

Prometheus is configured to keep 30 days of metrics by default:
```yaml
--storage.tsdb.retention.time=30d
```

To change, update `docker-compose.yml` or scale back to 7 days:
```bash
docker compose exec prometheus sed -i 's/30d/7d/' /etc/prometheus/prometheus.yml
docker compose restart prometheus
```

## Advanced: Multi-Cluster Monitoring

To monitor multiple Prometheus instances from a central Grafana, use Prometheus federation. Add to central Prometheus config:

```yaml
scrape_configs:
  - job_name: federate
    scrape_interval: 15s
    honor_labels: true
    metrics_path: /federate
    params:
      match[]: ['{job=~".*"}']
    static_configs:
      - targets: [10.1.2.186:9090]  # Your local prometheus
```

## Troubleshooting Checklist

- [ ] Prometheus container is running: `docker compose ps prometheus`
- [ ] Prometheus metrics endpoint reachable: `curl http://prometheus:9090/metrics`
- [ ] Prometheus can reach vLLM: `nc -zv 10.75.9.21 8000`
- [ ] Prometheus can reach DCGM: `nc -zv 10.75.9.21 9400`
- [ ] Grafana container is running: `docker compose ps grafana`
- [ ] Grafana data source configured: Grafana UI → Configuration → Data Sources → Prometheus
- [ ] Dashboard exists: Grafana UI → Dashboards → search "vLLM"
- [ ] Recent data in Prometheus: http://localhost:9090/graph → try `up` query
- [ ] vLLM metrics exported: `curl http://10.75.9.21:8000/metrics`
- [ ] DCGM exporter running: `curl http://10.75.9.21:9400/metrics | grep gpu_utilization`

## Next Steps

1. **Set up alerting**: Define thresholds in Prometheus alerts, send to Slack/PagerDuty
2. **Long-term storage**: Consider Prometheus remote write to S3 or Thanos for retention > 30 days
3. **SLO tracking**: Create dashboards for service level objectives (latency, availability, throughput)
4. **Cost analysis**: Correlate token generation with inference latency for cost/perf analysis
