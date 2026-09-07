# Quick Start: vLLM Monitoring with Prometheus + Grafana

This is a step-by-step guide to get your monitoring stack running for llm1 (10.75.9.21) and llm2 (10.75.9.22) with MIG support.

## Phase 1: Prepare Environment (5 minutes)

### 1.1 On the monitoring server (10.1.2.186):

```bash
cd /home/user/infra-work

# Copy and edit .env with actual passwords
cp .env.example .env
# Edit .env and change:
#   GRAFANA_ADMIN_PASSWORD=your-secure-password

chmod 600 .env
```

### 1.2 Verify docker-compose includes Prometheus & Grafana:

```bash
docker compose config | grep -A 5 "prometheus:\|grafana:"
# Should show both services defined
```

## Phase 2: Start Monitoring Stack (5 minutes)

### 2.1 Start services:

```bash
cd /home/user/infra-work

docker compose up -d prometheus grafana

# Wait for them to be healthy (check every 10 seconds)
watch -n 2 docker compose ps prometheus grafana
# Press Ctrl+C when both show "healthy"
```

### 2.2 Verify Prometheus is scraping:

```bash
docker logs prometheus --tail 50 | grep -i "scrape\|error"

# You'll likely see "connection refused" or "no such host" errors — this is expected
# if vLLM exporters aren't running yet. We'll fix that next.
```

### 2.3 Access Prometheus UI (via SSH tunnel):

```bash
# In a terminal on your local machine:
ssh -L 9090:127.0.0.1:9090 user@10.1.2.186

# In your browser:
# http://localhost:9090/targets
# You should see many "DOWN" targets — we'll bring them UP next
```

## Phase 3: Enable Metrics on vLLM Servers (10 minutes per server)

### 3.1 On llm1 (10.75.9.21) — NO MIG:

**SSH into llm1:**

```bash
ssh user@10.75.9.21

# Stop current vLLM if running
# pkill -f "python.*vllm" or docker stop <vllm-container>

# Start vLLM with Prometheus metrics enabled
python -m vllm.entrypoints.openai.api_server \
  --model gpt-oss-130b \
  --gpu-memory-utilization 0.9 \
  --tensor-parallel-size 1 \
  --port 8000 \
  --enable-prometheus-metrics
```

**In another terminal (or tmux/screen), verify metrics:**

```bash
ssh user@10.75.9.21

# Check every 5 seconds that metrics are being exported
watch -n 5 'curl -s http://localhost:8000/metrics | head -5'
# Should show "# HELP vllm_" lines
```

**Start NVIDIA DCGM exporter:**

```bash
ssh user@10.75.9.21

# Install DCGM if needed
sudo apt-get update && sudo apt-get install -y nvidia-dcgm

# Start DCGM daemon
sudo systemctl start nvidia-dcgm
sudo systemctl enable nvidia-dcgm

# Run the exporter (in background or tmux)
docker run -d \
  --name nvidia-dcgm-exporter \
  --restart unless-stopped \
  --gpus all \
  -p 9400:9400 \
  nvcr.io/nvidia/k8s/dcgm-exporter:3.1.7-3.1.4-ubuntu20.04

# Verify it's running
curl -s http://localhost:9400/metrics | grep nvidia_dcgm | head -3
```

### 3.2 On llm2 (10.75.9.22) — WITH MIG:

**SSH into llm2:**

```bash
ssh user@10.75.9.22

# Enable MIG mode (if not already enabled)
sudo nvidia-smi -mig 1

# Verify MIG is enabled and see available partitions
nvidia-smi -L
# Should show something like:
# GPU 0 MIG 1g.6gb: ID 1
# GPU 0 MIG 1g.6gb: ID 2
```

**Start vLLM instances (one per MIG partition):**

```bash
ssh user@10.75.9.22

# Terminal 1: Instance for partition 0
CUDA_VISIBLE_DEVICES=0 python -m vllm.entrypoints.openai.api_server \
  --model model-1 \
  --gpu-memory-utilization 0.95 \
  --tensor-parallel-size 1 \
  --port 8000 \
  --enable-prometheus-metrics

# Terminal 2 (new terminal): Instance for partition 1
ssh user@10.75.9.22
CUDA_VISIBLE_DEVICES=1 python -m vllm.entrypoints.openai.api_server \
  --model model-2 \
  --gpu-memory-utilization 0.95 \
  --tensor-parallel-size 1 \
  --port 8001 \
  --enable-prometheus-metrics
```

**Verify both instances:**

```bash
ssh user@10.75.9.22

# Check instance 1
curl -s http://localhost:8000/metrics | head -3

# Check instance 2
curl -s http://localhost:8001/metrics | head -3
# Both should show vllm metrics
```

**Start DCGM exporter on llm2:**

```bash
ssh user@10.75.9.22

# Install DCGM (if needed)
sudo apt-get update && sudo apt-get install -y nvidia-dcgm

# Start DCGM daemon
sudo systemctl start nvidia-dcgm
sudo systemctl enable nvidia-dcgm

# Run the exporter
docker run -d \
  --name nvidia-dcgm-exporter \
  --restart unless-stopped \
  --gpus all \
  -p 9400:9400 \
  nvcr.io/nvidia/k8s/dcgm-exporter:3.1.7-3.1.4-ubuntu20.04

# Verify MIG metrics are being exported
curl -s http://localhost:9400/metrics | grep mig | head -3
# Should show mig_profile, mig_uuid, etc.
```

## Phase 4: Verify Data is Flowing (5 minutes)

### 4.1 Run the health check script:

```bash
cd /home/user/infra-work

bash scripts/01_check_monitoring.sh all

# You should see all GREEN checkmarks now
# If any are RED, see troubleshooting section below
```

### 4.2 In Prometheus UI (http://localhost:9090/targets):

All targets should be GREEN:
- `vllm-llm1` — should show GREEN
- `vllm-llm2-main` — should show GREEN  
- `nvidia-dcgm-llm1` — should show GREEN
- `nvidia-dcgm-llm2` — should show GREEN
- (optional) `node-llm1`, `node-llm2` — GREEN if node-exporter is running

### 4.3 Verify Prometheus has metrics:

In Prometheus UI (http://localhost:9090/graph):

1. Type in query box: `vllm_request_total`
2. Click "Execute"
3. Should show results from both llm1 and llm2
4. Switch to "Graph" tab to see time series

## Phase 5: View Grafana Dashboard (2 minutes)

### 5.1 Access Grafana (via SSH tunnel):

```bash
# In a terminal on your local machine:
ssh -L 3000:127.0.0.1:3000 user@10.1.2.186

# In your browser:
# http://localhost:3000
# Login: admin / your-password-from-.env
```

### 5.2 Open the vLLM dashboard:

1. Click "Dashboards" (left sidebar)
2. Search for "vLLM"
3. Click "vLLM Inference Monitoring"

### 5.3 Verify you see data:

All panels should show data:
- Request Throughput — line chart
- GPU Memory Usage — gauge
- Request Latency — line chart
- Token Generation Rate — line chart
- GPU Utilization — line chart
- Cache Hit Rate — line chart
- Error Rate — line chart (should be near zero)
- Active vLLM Servers — should show "2"
- p99 Latency — should show milliseconds

If panels are empty, see troubleshooting section.

## Troubleshooting

### Prometheus targets are all DOWN

**Symptom**: In Prometheus UI (http://localhost:9090/targets), all targets show "DOWN" with error messages.

**Cause**: Network connectivity or exporters not running.

**Fix**:

```bash
# 1. Check if services are actually running
ssh user@10.75.9.21 'ps aux | grep vllm'     # Should show vLLM process
ssh user@10.75.9.21 'curl -s localhost:8000/metrics | head -3'  # Should work

# 2. Check if monitoring server can reach them
nc -zv 10.75.9.21 8000      # Should succeed
nc -zv 10.75.9.22 8000      # Should succeed
nc -zv 10.75.9.22 8001      # Should succeed (if MIG instance 2 is running)

# 3. Check Prometheus logs for specific errors
docker logs prometheus | tail -30

# 4. If targets were DOWN, it takes 1-2 minutes to recover after services start
# Wait 2 minutes and refresh Prometheus UI
```

### Grafana dashboard shows "No Data"

**Symptom**: Dashboard opens but panels are empty (no data).

**Cause**: Prometheus has targets UP but no data yet (takes ~30 seconds), or data source not configured.

**Fix**:

```bash
# 1. Verify Prometheus data source in Grafana
# Grafana UI -> Configuration -> Data Sources -> Prometheus
# Test the connection (should say "Prometheus is running")

# 2. Wait 2-3 minutes for data to accumulate in Prometheus
# (each scrape interval is 15-30 seconds, need at least 2 scrapes)

# 3. Try a simple query in Prometheus UI
# Go to http://localhost:9090/graph
# Query: up{job="vllm-llm1"}
# Should show value of 1 (means llm1 is UP and being scraped)

# 4. If still no data, restart Grafana
docker compose restart grafana

# Wait 30 seconds for Grafana to restart and re-read data sources
```

### MIG metrics are missing on llm2

**Symptom**: Dashboard shows llm1 data fine, but llm2 GPU metrics are missing.

**Cause**: DCGM exporter not seeing MIG instances, or MIG mode not enabled.

**Fix**:

```bash
ssh user@10.75.9.22

# 1. Verify MIG mode is on
nvidia-smi -mig --query-gpu=index,mig.mode.current --format=csv

# If "Disabled", enable it:
sudo nvidia-smi -mig 1

# 2. Restart DCGM after enabling MIG
sudo systemctl restart nvidia-dcgm
docker restart nvidia-dcgm-exporter

# 3. Verify DCGM sees MIG instances
curl -s localhost:9400/metrics | grep mig_mode | head -3

# 4. In Prometheus (http://localhost:9090/targets),
#    look at nvidia-dcgm-llm2 target and click it
#    Check the "Labels" section — should show mig_profile, mig_uuid labels
```

### Second vLLM instance on llm2 (port 8001) not being scraped

**Symptom**: Port 8000 works, but port 8001 shows "DOWN" or "No Data".

**Cause**: Second instance either isn't running, or Prometheus config needs update.

**Fix**:

```bash
ssh user@10.75.9.22

# 1. Verify instance 2 is running
curl -s localhost:8001/metrics | head -3
# Should show vllm metrics, not "Connection refused"

# 2. If running, update Prometheus config
# Edit: prometheus/prometheus.yml
# Uncomment the "vllm-llm2-mig1" job (around line 56)
# Change port from 8001 if you used a different port

# 3. Reload Prometheus config without restart:
docker exec prometheus kill -HUP 1
# Or restart: docker compose restart prometheus

# 4. In Prometheus UI (http://localhost:9090/targets),
#    should now see vllm-llm2-mig1 in the list
```

### "Connection refused" or "no such host" in Prometheus logs

**Symptom**: Prometheus logs show errors like:
```
error="Get http://10.75.9.21:8000/metrics: dial tcp 10.75.9.21:8000: connect: connection refused"
```

**Causes**:
1. vLLM not running on that port
2. Firewall blocking traffic
3. Network configuration issue

**Fix**:

```bash
# From monitoring server (10.1.2.186), test each endpoint:
curl -v http://10.75.9.21:8000/metrics 2>&1 | head -20
curl -v http://10.75.9.22:8000/metrics 2>&1 | head -20

# If "Connection refused":
#   - SSH into llm1/llm2 and verify vLLM is running:
#     ps aux | grep vllm
#   - Check it's listening on port 8000:
#     netstat -tlnp | grep 8000 (or: ss -tlnp | grep 8000)

# If timeout:
#   - Check firewall rules:
#     sudo ufw status (if using ufw)
#     sudo iptables -L (if using iptables)
#   - May need to open port 8000, 8001, 9400, 9100 on llm1/llm2
```

## Next: Monitor and Maintain

### Daily checks:

```bash
# Run the health check weekly to catch issues early
bash scripts/01_check_monitoring.sh all

# Monitor Prometheus disk usage (30-day retention takes ~5-10 GB/server typically)
du -sh prometheus_data
docker system df  # See how much space containers use
```

### Set up alerts (optional, for production):

In Grafana:
1. Open a dashboard panel
2. Click the alert bell icon
3. Define thresholds (e.g., "if p99 latency > 5000ms for 5 minutes, alert")
4. Save and configure notification channels (Slack, email, etc.)

### Backup your data (optional, for production):

```bash
# Backup Prometheus data
docker compose exec prometheus tar -czf /tmp/prometheus-backup.tar.gz /prometheus

# Backup Grafana dashboards
docker compose exec grafana grafana-cli admin export-dashboard vllm-monitoring > vllm-monitoring-backup.json
```

## Success Criteria

Your monitoring stack is working when:

- ✅ All Prometheus targets are GREEN (http://localhost:9090/targets)
- ✅ Grafana dashboard shows data in all panels
- ✅ Dashboard shows "2" active vLLM servers
- ✅ You can filter by server (llm1/llm2) using the Server variable
- ✅ MIG instance metrics appear on llm2 panel
- ✅ Health check script shows all GREEN

**Congratulations! You now have production-grade vLLM monitoring.** 🎉
