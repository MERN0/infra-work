#!/bin/bash
#
# Monitoring stack health check script
# Verifies Prometheus, Grafana, vLLM metrics, NVIDIA DCGM, and network connectivity
#
# Usage: ./scripts/01_check_monitoring.sh [llm1 | llm2 | all]
#

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

check_target=${1:-all}

echo -e "${BLUE}=== vLLM Monitoring Health Check ===${NC}\n"

# Test a URL and report status
test_endpoint() {
    local name=$1
    local url=$2
    local expected_pattern=$3

    if command -v curl &> /dev/null; then
        if response=$(curl -s -m 5 "$url" 2>/dev/null); then
            if [ -n "$expected_pattern" ]; then
                if echo "$response" | grep -q "$expected_pattern"; then
                    echo -e "${GREEN}✓${NC} $name"
                    return 0
                else
                    echo -e "${RED}✗${NC} $name (response missing expected pattern: $expected_pattern)"
                    return 1
                fi
            else
                echo -e "${GREEN}✓${NC} $name"
                return 0
            fi
        else
            echo -e "${RED}✗${NC} $name (connection failed)"
            return 1
        fi
    else
        echo -e "${YELLOW}⚠${NC} $name (curl not installed, skipping)"
        return 0
    fi
}

# Test network connectivity using nc
test_connectivity() {
    local name=$1
    local host=$2
    local port=$3

    if command -v nc &> /dev/null; then
        if nc -z -w 3 "$host" "$port" 2>/dev/null; then
            echo -e "${GREEN}✓${NC} $name (reachable)"
            return 0
        else
            echo -e "${RED}✗${NC} $name (unreachable at $host:$port)"
            return 1
        fi
    else
        echo -e "${YELLOW}⚠${NC} $name (nc not installed, skipping)"
        return 0
    fi
}

# ===== Local Docker Services =====
echo -e "${BLUE}Local Docker Services:${NC}"

if command -v docker &> /dev/null; then
    if docker ps --filter name=prometheus --quiet &> /dev/null; then
        container_id=$(docker ps --filter name=prometheus -q)
        if [ -n "$container_id" ]; then
            echo -e "${GREEN}✓${NC} Prometheus container running"
        else
            echo -e "${RED}✗${NC} Prometheus container not running"
        fi
    else
        echo -e "${RED}✗${NC} Prometheus container not found"
    fi

    if docker ps --filter name=grafana --quiet &> /dev/null; then
        container_id=$(docker ps --filter name=grafana -q)
        if [ -n "$container_id" ]; then
            echo -e "${GREEN}✓${NC} Grafana container running"
        else
            echo -e "${RED}✗${NC} Grafana container not running"
        fi
    else
        echo -e "${RED}✗${NC} Grafana container not found"
    fi
else
    echo -e "${YELLOW}⚠${NC} Docker not available (skipping container checks)"
fi

echo ""

# ===== Network Connectivity =====
echo -e "${BLUE}Network Connectivity:${NC}"

if [ "$check_target" = "llm1" ] || [ "$check_target" = "all" ]; then
    test_connectivity "llm1 - vLLM API" "10.75.9.21" 8000
    test_connectivity "llm1 - NVIDIA DCGM Exporter" "10.75.9.21" 9400
    test_connectivity "llm1 - Node Exporter" "10.75.9.21" 9100
fi

if [ "$check_target" = "llm2" ] || [ "$check_target" = "all" ]; then
    test_connectivity "llm2 - vLLM API (main)" "10.75.9.22" 8000
    test_connectivity "llm2 - vLLM API (MIG partition 1)" "10.75.9.22" 8001
    test_connectivity "llm2 - NVIDIA DCGM Exporter" "10.75.9.22" 9400
    test_connectivity "llm2 - Node Exporter" "10.75.9.22" 9100
fi

echo ""

# ===== Remote Metrics Endpoints =====
echo -e "${BLUE}Remote Metrics Endpoints:${NC}"

if [ "$check_target" = "llm1" ] || [ "$check_target" = "all" ]; then
    echo -e "\n${YELLOW}llm1 (10.75.9.21):${NC}"
    test_endpoint "vLLM metrics" "http://10.75.9.21:8000/metrics" "vllm_"
    test_endpoint "DCGM exporter" "http://10.75.9.21:9400/metrics" "nvidia_dcgm"
    test_endpoint "Node exporter" "http://10.75.9.21:9100/metrics" "node_"
fi

if [ "$check_target" = "llm2" ] || [ "$check_target" = "all" ]; then
    echo -e "\n${YELLOW}llm2 (10.75.9.22):${NC}"
    test_endpoint "vLLM metrics (main)" "http://10.75.9.22:8000/metrics" "vllm_"
    test_endpoint "vLLM metrics (MIG 1)" "http://10.75.9.22:8001/metrics" "vllm_" || true
    test_endpoint "DCGM exporter" "http://10.75.9.22:9400/metrics" "nvidia_dcgm"
    test_endpoint "Node exporter" "http://10.75.9.22:9100/metrics" "node_"
fi

echo ""

# ===== Prometheus Targets =====
echo -e "${BLUE}Prometheus Targets:${NC}"

test_endpoint "Prometheus API" "http://localhost:9090/-/healthy"

if command -v curl &> /dev/null; then
    echo -e "\nTarget status (from Prometheus):"
    targets=$(curl -s "http://localhost:9090/api/v1/targets" 2>/dev/null | grep -o '"job":"[^"]*"' | head -20 || true)
    if [ -z "$targets" ]; then
        echo -e "${YELLOW}⚠${NC} Could not fetch targets (Prometheus not reachable or not ready)"
    else
        echo "$targets" | sed 's/"job":"\([^"]*\)"/  - \1/'
    fi
fi

echo ""

# ===== Grafana =====
echo -e "${BLUE}Grafana:${NC}"

test_endpoint "Grafana health" "http://localhost:3000/api/health"

if command -v curl &> /dev/null; then
    echo -e "\nGrafana datasources:"
    datasources=$(curl -s -u admin:admin "http://localhost:3000/api/datasources" 2>/dev/null | grep -o '"name":"[^"]*"' || true)
    if [ -z "$datasources" ]; then
        echo -e "${YELLOW}⚠${NC} Could not fetch datasources (authentication may have failed)"
    else
        echo "$datasources" | sed 's/"name":"\([^"]*\)"/  - \1/'
    fi
fi

echo ""

# ===== Prometheus Database =====
echo -e "${BLUE}Prometheus Time Series Database:${NC}"

if command -v curl &> /dev/null; then
    metric_count=$(curl -s "http://localhost:9090/api/v1/query" --data-urlencode 'query=count(count by (__name__)({__name__=~".+"}))' 2>/dev/null | grep -o '"value":\[\("[^"]*",[^]]*\)' | tail -1 || echo "")

    if [ -z "$metric_count" ]; then
        echo -e "${YELLOW}⚠${NC} Could not determine metric count (Prometheus may not have data yet)"
    else
        count=$(echo "$metric_count" | grep -oE '[0-9]+' | head -1)
        if [ "$count" -gt 0 ]; then
            echo -e "${GREEN}✓${NC} Prometheus has ~$count unique metrics"
        else
            echo -e "${YELLOW}⚠${NC} Prometheus has no data yet (targets may not be scraping)"
        fi
    fi
fi

echo ""

# ===== MIG-Specific Checks =====
if [ "$check_target" = "llm2" ] || [ "$check_target" = "all" ]; then
    echo -e "${BLUE}MIG-Specific (llm2):${NC}"

    if command -v curl &> /dev/null; then
        mig_metrics=$(curl -s "http://10.75.9.22:9400/metrics" 2>/dev/null | grep "mig_" | head -3 || true)
        if [ -n "$mig_metrics" ]; then
            echo -e "${GREEN}✓${NC} MIG metrics detected from DCGM exporter"
            echo "$mig_metrics" | head -1
        else
            echo -e "${YELLOW}⚠${NC} No MIG metrics found (MIG may not be enabled on llm2)"
        fi
    fi
fi

echo ""
echo -e "${BLUE}=== Summary ===${NC}"
echo -e "${YELLOW}For detailed troubleshooting, see MONITORING.md${NC}"
echo -e "Prometheus: http://localhost:9090 (via SSH tunnel: ssh -L 9090:127.0.0.1:9090 user@10.1.2.186)"
echo -e "Grafana:    http://localhost:3000 (via SSH tunnel: ssh -L 3000:127.0.0.1:3000 user@10.1.2.186)"
