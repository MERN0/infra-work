# DCGM Exporter: enabling GPU utilization metrics (incl. under MIG)

## Status: root cause found, fix deliberately NOT applied (2026-09-07)

Investigated on llm2 down to the actual blocker:

```
cat /proc/driver/nvidia/params | grep RmProfilingAdminOnly
RmProfilingAdminOnly: 1
```

This is a **kernel-module-load-time** parameter that restricts DCGM's profiling API
(`DCGM_FI_PROF_*`, including `GR_ENGINE_ACTIVE`) to admin-only access, enforced by the
NVIDIA driver itself — `--cap-add SYS_ADMIN` on the container was not sufficient, because
the restriction lives below the container capability layer. `dcgmi modules --list` could
not even be queried at the time (host-engine connection error), so this was confirmed via
the raw params file rather than DCGM's own tooling.

Fixing it requires `options nvidia RmProfilingAdminOnly=0` in a modprobe config, then a
kernel module reload or full reboot — which means **stopping every process holding the
GPU first**. On llm2 that's all 4 live vLLM containers (`gemma-3-27b`, `bge-m3`,
`bge-reranker`, the nemotron model) plus `dcgm-exporter`.

**Decision: not pursuing this now.** The downtime cost on a host serving 4 live models
wasn't worth true device-level utilization, given a workable alternative exists (below).
If this gets revisited later — e.g. during an already-planned maintenance window — the
fix is exactly the "Procedure" steps below, this time following through to step 3.

The `dcgm-exporter` container was rolled back to its original config (no `SYS_ADMIN`, no
merged PROF counters file) since that capability serves no purpose while the driver still
blocks it — no reason to carry the extra privilege for nothing.

### What we use instead

Two vLLM metrics, already scraped per model/partition in `prometheus.yml`, give genuine
per-MIG-partition load visibility that DCGM cannot — DCGM only reports at the physical-GPU
level, but each MIG partition runs its own vLLM process with its own counters:

- `vllm:num_requests_running` — active request count per model
- `vllm:kv_cache_usage_perc` — KV cache saturation per model (0–1 ratio; ×100 for %)

Both are on the dashboard's "Per-Model Load (vLLM)" row. `DCGM_FI_DEV_POWER_USAGE` and
`DCGM_FI_DEV_SM_CLOCK` remain as physical-GPU-level (both-partitions-combined) fallback
signals.

---


This is run **on the GPU hosts** (llm1 `10.75.9.21`, llm2 `10.75.9.22`), not on the
monitoring host. Prometheus scrapes port `9400` on each.

## Why this is needed

`DCGM_FI_DEV_GPU_UTIL` — the classic "GPU utilization %" field — is **not emitted on a
GPU in MIG mode**. Verified rather than assumed:

- Both hosts ship an identical `/etc/dcgm-exporter/default-counters.csv` that lists the
  field, yet only llm1 (non-MIG) reports values for it. So the driver is withholding it;
  it is not an exporter config gap.
- `nvidia-smi` likewise cannot report utilization for MIG compute instances.

The replacement is `DCGM_FI_PROF_GR_ENGINE_ACTIVE` — a *profiling API* field giving the
ratio (0–1) of time the compute engine was active. It survives MIG mode. Two things gate
it, and the exporter says so itself on startup:

```
Warning #2: dcgm-exporter doesn't have sufficient privileges to expose profiling metrics.
To get profiling metrics with dcgm-exporter use --cap-add SYS_ADMIN
```

1. The container needs `--cap-add SYS_ADMIN`.
2. The counters file must include the `DCGM_FI_PROF_*` fields (the default one does not).

> **Security note:** `SYS_ADMIN` is a broad Linux capability. It is NVIDIA's documented
> requirement for profiling counters, not a workaround, but it does widen what this
> container could do if compromised. Decide deliberately whether that trade is worth
> utilization metrics in your environment.

## Procedure (repeat on each GPU host)

### 1. Record the current container config, for rollback

```bash
sudo docker inspect dcgm-exporter --format 'Image:      {{.Config.Image}}
Cmd:        {{.Config.Cmd}}
Network:    {{.HostConfig.NetworkMode}}
Restart:    {{.HostConfig.RestartPolicy.Name}}
CapAdd:     {{.HostConfig.CapAdd}}
Privileged: {{.HostConfig.Privileged}}
Binds:      {{.HostConfig.Binds}}'
```

Save the output before continuing.

### 2. Build a merged counters file

Switching `-f` to the shipped `dcp-metrics-included.csv` would *replace* the field list and
could drop the `DCGM_FI_DEV_*` fields the dashboard already uses (`FB_USED`, `GPU_TEMP`,
`POWER_USAGE`, `SM_CLOCK`, `XID_ERRORS`). Merge instead of swapping. Generating it from the
files already inside the image avoids transcription errors:

```bash
sudo mkdir -p /etc/dcgm-custom
sudo docker exec dcgm-exporter cat /etc/dcgm-exporter/default-counters.csv \
  | sudo tee /etc/dcgm-custom/counters.csv > /dev/null
sudo docker exec dcgm-exporter cat /etc/dcgm-exporter/dcp-metrics-included.csv \
  | grep '^DCGM_FI_PROF' | sudo tee -a /etc/dcgm-custom/counters.csv > /dev/null

grep PROF /etc/dcgm-custom/counters.csv   # sanity check
```

### 3. Recreate the exporter

```bash
sudo docker rm -f dcgm-exporter

sudo docker run -d --name dcgm-exporter \
  --restart unless-stopped \
  --gpus all \
  --cap-add SYS_ADMIN \
  --network host \
  -v /etc/dcgm-custom/counters.csv:/etc/dcgm-custom/counters.csv:ro \
  nvcr.io/nvidia/k8s/dcgm-exporter:3.3.5-3.4.0-ubuntu22.04 \
  -f /etc/dcgm-custom/counters.csv
```

Note `--network host`: the exporter binds the host's `9400` directly, which is why
`docker port dcgm-exporter` prints nothing on these hosts.

### 4. Verify

```bash
sleep 25
sudo docker logs dcgm-exporter 2>&1 | tail -20
curl -s http://localhost:9400/metrics | grep '^DCGM_FI_PROF_GR_ENGINE_ACTIVE'
curl -s http://localhost:9400/metrics | grep -c '^DCGM_FI_DEV_'   # existing fields still present
```

On llm2, check the **labels**: `GPU_I_ID="1"` and `GPU_I_ID="2"` mean utilization resolves
per MIG partition. A single unlabeled series means profiling works only for the whole
physical GPU — still a true activity ratio, just not split per slice.

## Rollback

```bash
sudo docker rm -f dcgm-exporter
sudo docker run -d --name dcgm-exporter --restart unless-stopped \
  --gpus all --network host \
  nvcr.io/nvidia/k8s/dcgm-exporter:3.3.5-3.4.0-ubuntu22.04
```

Adjust to match whatever step 1 recorded.

## Known failure modes

| Symptom | Cause |
|---|---|
| `Warning #2: ... doesn't have sufficient privileges to expose profiling metrics` | `--cap-add SYS_ADMIN` missing. |
| `CacheManager Init Failed. Error: -17` / `Error starting nv-hostengine` | Seen when a second exporter is started alongside the running one — each embeds its own `nv-hostengine` and they collide on host networking. Reconfigure the single production container rather than running a test one in parallel. (Exact meaning of code -17 not confirmed.) |
| Container starts but nothing on `:9401` | The listen-port flag is `--address` / `-a` (e.g. `-a :9401`). `-p` is the device-selection flag, not the port. |
| `DCGM_FI_DEV_MEMORY_TEMP` reads 0 | No memory-die temp sensor on this hardware — `nvidia-smi -q -d TEMPERATURE` shows N/A. DCGM emits a placeholder 0. Deliberately not charted. |

## Metrics this unlocks

| Metric | Meaning |
|---|---|
| `DCGM_FI_PROF_GR_ENGINE_ACTIVE` | Ratio (0–1) of time the compute engine was active — the MIG-compatible utilization metric. Multiply by 100 for a percentage. |
| `DCGM_FI_PROF_PIPE_TENSOR_ACTIVE` | Ratio of cycles the tensor (HMMA) pipe was active. Sharpest signal of real LLM compute. |
| `DCGM_FI_PROF_DRAM_ACTIVE` | Ratio of cycles the memory interface was busy. LLM decode is typically bandwidth-bound, so this runs high during token generation. |
| `DCGM_FI_PROF_PCIE_TX_BYTES` / `_RX_BYTES` | PCIe throughput. |
