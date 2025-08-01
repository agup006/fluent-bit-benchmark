#!/bin/bash

set -e

# Configuration
NAMESPACE="fluent-bit-benchmark"
THROUGHPUT_LEVELS=(1000 3000 5000 10000 15000)
TEST_DURATION="60s"
RESULTS_DIR="results/$(date +%Y%m%d_%H%M%S)"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log() {
    echo -e "${BLUE}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1"
}

success() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1"
}

error() {
    echo -e "${RED}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1"
}

# Function to wait for deployment to be ready
wait_for_deployment() {
    local deployment=$1
    local timeout=${2:-300}
    
    log "Waiting for deployment $deployment to be ready..."
    kubectl wait deployment/$deployment -n $NAMESPACE --for=condition=Available --timeout=${timeout}s
    if [ $? -eq 0 ]; then
        success "Deployment $deployment is ready"
    else
        error "Deployment $deployment failed to become ready within ${timeout}s"
        exit 1
    fi
}

# Function to collect metrics from Prometheus
collect_metrics() {
    local test_name=$1
    local start_time=$2
    local end_time=$3
    local output_file="$RESULTS_DIR/${test_name}_metrics.json"
    
    log "Collecting metrics for test: $test_name"
    
    # Get Prometheus pod
    PROMETHEUS_POD=$(kubectl get pods -n $NAMESPACE -l app=prometheus -o jsonpath='{.items[0].metadata.name}')
    
    if [ -z "$PROMETHEUS_POD" ]; then
        error "Prometheus pod not found"
        return 1
    fi
    
    # Queries to collect key metrics
    local queries=(
        "fluentbit_input_records_total"
        "fluentbit_output_records_total"
        "fluentbit_output_errors_total"
        "fluentbit_input_buffer_usage_bytes"
        "rate(container_cpu_usage_seconds_total{pod=~\"fluent-bit.*\"}[1m])"
        "container_memory_working_set_bytes{pod=~\"fluent-bit.*\"}"
        "rate(container_network_receive_bytes_total{pod=~\"fluent-bit.*\"}[1m])"
        "rate(container_network_transmit_bytes_total{pod=~\"fluent-bit.*\"}[1m])"
    )
    
    mkdir -p "$(dirname "$output_file")"
    echo "{}"> "$output_file"
    
    for query in "${queries[@]}"; do
        log "Collecting metric: $query"
        
        # URL encode the query
        encoded_query=$(printf '%s\n' "$query" | jq -sRr @uri)
        
        # Execute query against Prometheus
        kubectl exec -n $NAMESPACE $PROMETHEUS_POD -- wget -qO- \
            "http://localhost:9090/api/v1/query_range?query=${encoded_query}&start=${start_time}&end=${end_time}&step=15s" \
            | jq --arg query "$query" '.data.result as $result | {($query): $result}' \
            | jq -s add >> "$output_file.tmp"
    done
    
    # Merge all metrics into single JSON file
    jq -s add "$output_file.tmp" > "$output_file"
    rm "$output_file.tmp"
    
    success "Metrics collected: $output_file"
}

# Function to run a single benchmark test
run_test() {
    local throughput=$1
    local test_name="test_${throughput}msgs_per_sec"
    
    log "Starting benchmark test: $throughput messages/sec"
    
    # Record start time
    local start_time=$(date -u +%s)
    
    # Update log generator deployment with new throughput
    kubectl patch deployment log-generator -n $NAMESPACE -p "{
        \"spec\": {
            \"replicas\": 1,
            \"template\": {
                \"spec\": {
                    \"containers\": [{
                        \"name\": \"log-generator\",
                        \"args\": [
                            \"-url=http://fluent-bit:9880\",
                            \"-rate=${throughput}\",
                            \"-duration=${TEST_DURATION}\",
                            \"-workers=10\"
                        ]
                    }]
                }
            }
        }
    }"
    
    # Wait for deployment to be ready
    wait_for_deployment log-generator 60
    
    # Wait for test to complete (duration + buffer)
    local duration_seconds=$(echo $TEST_DURATION | sed 's/s$//')
    local total_wait=$((duration_seconds + 30))
    
    log "Running test for ${TEST_DURATION} (waiting ${total_wait}s total)..."
    sleep $total_wait
    
    # Record end time
    local end_time=$(date -u +%s)
    
    # Scale down log generator
    kubectl scale deployment log-generator -n $NAMESPACE --replicas=0
    
    # Collect metrics
    collect_metrics "$test_name" "$start_time" "$end_time"
    
    # Wait a bit before next test
    log "Cooling down for 30 seconds..."
    sleep 30
    
    success "Completed test: $throughput messages/sec"
}

# Function to generate summary report
generate_report() {
    local report_file="$RESULTS_DIR/benchmark_report.md"
    
    log "Generating benchmark report..."
    
    cat > "$report_file" << EOF
# Fluent Bit Benchmark Report

**Test Date:** $(date)
**Test Duration:** $TEST_DURATION per test
**Throughput Levels:** ${THROUGHPUT_LEVELS[*]} messages/sec

## Test Configuration

- **Fluent Bit Version:** $(kubectl get deployment fluent-bit -n $NAMESPACE -o jsonpath='{.spec.template.spec.containers[0].image}')
- **Input:** HTTP (port 9880)
- **Output:** HTTP to benchmark-server
- **Buffer Settings:** 1MB max, 64KB chunks
- **Workers:** 4 output workers

## Results

EOF
    
    for throughput in "${THROUGHPUT_LEVELS[@]}"; do
        local test_name="test_${throughput}msgs_per_sec"
        local metrics_file="$RESULTS_DIR/${test_name}_metrics.json"
        
        if [ -f "$metrics_file" ]; then
            echo "### $throughput Messages/Second" >> "$report_file"
            echo "" >> "$report_file"
            echo "- Metrics file: \`${test_name}_metrics.json\`" >> "$report_file"
            echo "- Test completed successfully" >> "$report_file"
            echo "" >> "$report_file"
        else
            echo "### $throughput Messages/Second" >> "$report_file"
            echo "" >> "$report_file"
            echo "- **FAILED** - No metrics collected" >> "$report_file"
            echo "" >> "$report_file"
        fi
    done
    
    cat >> "$report_file" << EOF

## Analysis

Use the collected metrics files with your preferred analysis tools to generate insights about:

- Throughput vs. Resource Usage
- Memory consumption patterns
- CPU utilization trends
- Error rates at different load levels
- Network I/O characteristics

## Files Generated

EOF
    
    find "$RESULTS_DIR" -type f -name "*.json" | while read file; do
        echo "- \`$(basename "$file")\`" >> "$report_file"
    done
    
    success "Report generated: $report_file"
}

# Main execution
main() {
    log "Starting Fluent Bit Benchmark Suite"
    
    # Check if kubectl is available
    if ! command -v kubectl &> /dev/null; then
        error "kubectl is required but not found"
        exit 1
    fi
    
    # Check if namespace exists
    if ! kubectl get namespace $NAMESPACE &> /dev/null; then
        error "Namespace $NAMESPACE not found. Please deploy the benchmark infrastructure first."
        exit 1
    fi
    
    # Check if required deployments exist
    for deployment in fluent-bit benchmark-server prometheus; do
        if ! kubectl get deployment $deployment -n $NAMESPACE &> /dev/null; then
            error "Deployment $deployment not found in namespace $NAMESPACE"
            exit 1
        fi
    done
    
    # Wait for infrastructure to be ready
    log "Checking infrastructure readiness..."
    wait_for_deployment fluent-bit 300
    wait_for_deployment benchmark-server 300
    wait_for_deployment prometheus 300
    
    # Create results directory
    mkdir -p "$RESULTS_DIR"
    log "Results will be saved to: $RESULTS_DIR"
    
    # Run benchmark tests
    for throughput in "${THROUGHPUT_LEVELS[@]}"; do
        run_test $throughput
    done
    
    # Generate report
    generate_report
    
    success "Benchmark suite completed successfully!"
    success "Results saved to: $RESULTS_DIR"
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --duration)
            TEST_DURATION="$2"
            shift 2
            ;;
        --namespace)
            NAMESPACE="$2"
            shift 2
            ;;
        --throughput)
            IFS=',' read -ra THROUGHPUT_LEVELS <<< "$2"
            shift 2
            ;;
        --help)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --duration DURATION    Test duration (default: 60s)"
            echo "  --namespace NAMESPACE  Kubernetes namespace (default: fluent-bit-benchmark)"
            echo "  --throughput LIST      Comma-separated throughput levels (default: 1000,3000,5000,10000,15000)"
            echo "  --help                 Show this help message"
            exit 0
            ;;
        *)
            error "Unknown option: $1"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

# Run main function
main