#!/bin/bash

set -e

# Configuration
NAMESPACE="fluent-bit-benchmark"

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
    local timeout=${2:-180}
    
    log "Waiting for deployment $deployment to be ready..."
    if kubectl wait deployment/$deployment -n $NAMESPACE --for=condition=Available --timeout=${timeout}s 2>/dev/null; then
        success "Deployment $deployment is ready"
        return 0
    else
        warn "Deployment $deployment not ready within ${timeout}s, continuing..."
        return 1
    fi
}

# Clean up existing deployment
cleanup() {
    log "Cleaning up existing deployment..."
    kubectl delete namespace $NAMESPACE --ignore-not-found=true
    
    # Wait for namespace to be fully deleted
    while kubectl get namespace $NAMESPACE 2>/dev/null; do
        log "Waiting for namespace deletion..."
        sleep 2
    done
    
    success "Cleanup completed"
}

# Create namespace
create_namespace() {
    log "Creating namespace $NAMESPACE..."
    kubectl create namespace $NAMESPACE
    success "Namespace created"
}

# Deploy Fluent Bit
deploy_fluent_bit() {
    log "Deploying Fluent Bit..."
    
    # Create ConfigMap
    kubectl create configmap fluent-bit-config -n $NAMESPACE \
        --from-literal=fluent-bit.conf='[SERVICE]
    Flush         1
    Log_Level     info
    Daemon        off
    HTTP_Server   On
    HTTP_Listen   0.0.0.0
    HTTP_Port     2020
    Health_Check  On

[INPUT]
    Name              http
    Listen            0.0.0.0
    Port              9880
    Buffer_Max_Size   1MB
    Buffer_Chunk_Size 64KB

[OUTPUT]
    Name  http
    Match *
    Host  benchmark-server
    Port  8080
    URI   /logs
    Format json
    Retry_Limit 3
    Workers 4

[OUTPUT]
    Name  prometheus_exporter
    Match *
    Host  0.0.0.0
    Port  2021' \
        --from-literal=parsers.conf='[PARSER]
    Name        json
    Format      json
    Time_Key    timestamp
    Time_Format %Y-%m-%dT%H:%M:%S.%L
    Time_Keep   On'

    # Create Deployment
    kubectl create deployment fluent-bit -n $NAMESPACE --image=fluent/fluent-bit:latest
    
    # Patch deployment with proper config
    kubectl patch deployment fluent-bit -n $NAMESPACE -p '{
        "spec": {
            "template": {
                "metadata": {
                    "annotations": {
                        "prometheus.io/scrape": "true",
                        "prometheus.io/port": "2021"
                    }
                },
                "spec": {
                    "containers": [{
                        "name": "fluent-bit",
                        "image": "fluent/fluent-bit:latest",
                        "ports": [
                            {"containerPort": 9880, "name": "http-input"},
                            {"containerPort": 2020, "name": "http-server"},
                            {"containerPort": 2021, "name": "metrics"}
                        ],
                        "volumeMounts": [{
                            "name": "config",
                            "mountPath": "/fluent-bit/etc/"
                        }],
                        "resources": {
                            "requests": {
                                "memory": "256Mi",
                                "cpu": "200m"
                            }
                        }
                    }],
                    "volumes": [{
                        "name": "config",
                        "configMap": {
                            "name": "fluent-bit-config"
                        }
                    }]
                }
            }
        }
    }'
    
    # Expose service
    kubectl expose deployment fluent-bit -n $NAMESPACE \
        --port=9880 --target-port=9880 --name=fluent-bit-input
    kubectl expose deployment fluent-bit -n $NAMESPACE \
        --port=2020 --target-port=2020 --name=fluent-bit-server
    kubectl expose deployment fluent-bit -n $NAMESPACE \
        --port=2021 --target-port=2021 --name=fluent-bit-metrics
    
    success "Fluent Bit deployed"
}

# Deploy benchmark server (simple HTTP receiver)
deploy_benchmark_server() {
    log "Deploying benchmark server..."
    
    kubectl create deployment benchmark-server -n $NAMESPACE --image=nginx:alpine
    kubectl expose deployment benchmark-server -n $NAMESPACE --port=8080 --target-port=80
    
    success "Benchmark server deployed"
}

# Deploy Prometheus
deploy_prometheus() {
    log "Deploying Prometheus..."
    
    # Create ServiceAccount and RBAC
    kubectl create serviceaccount prometheus -n $NAMESPACE
    
    kubectl create clusterrole prometheus --verb=get,list,watch --resource=nodes,services,endpoints,pods
    
    kubectl create clusterrolebinding prometheus \
        --clusterrole=prometheus \
        --serviceaccount=$NAMESPACE:prometheus
    
    # Create ConfigMap
    kubectl create configmap prometheus-config -n $NAMESPACE \
        --from-literal=prometheus.yml='global:
  scrape_interval: 15s

scrape_configs:
- job_name: "fluent-bit"
  static_configs:
  - targets: ["fluent-bit-metrics:2021"]

- job_name: "benchmark-server"  
  static_configs:
  - targets: ["benchmark-server:8080"]

- job_name: "kubernetes-pods"
  kubernetes_sd_configs:
  - role: pod
    namespaces:
      names: ["'$NAMESPACE'"]
  relabel_configs:
  - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_scrape]
    action: keep
    regex: true'

    # Create Deployment
    kubectl create deployment prometheus -n $NAMESPACE --image=prom/prometheus:v2.45.0
    
    # Patch deployment
    kubectl patch deployment prometheus -n $NAMESPACE -p '{
        "spec": {
            "template": {
                "spec": {
                    "serviceAccountName": "prometheus",
                    "containers": [{
                        "name": "prometheus",
                        "image": "prom/prometheus:v2.45.0",
                        "args": [
                            "--config.file=/etc/prometheus/prometheus.yml",
                            "--storage.tsdb.path=/prometheus/",
                            "--web.console.libraries=/etc/prometheus/console_libraries",
                            "--web.console.templates=/etc/prometheus/consoles",
                            "--storage.tsdb.retention.time=24h",
                            "--web.enable-lifecycle"
                        ],
                        "ports": [{"containerPort": 9090, "name": "web"}],
                        "volumeMounts": [{
                            "name": "config",
                            "mountPath": "/etc/prometheus/"
                        }]
                    }],
                    "volumes": [{
                        "name": "config",
                        "configMap": {"name": "prometheus-config"}
                    }]
                }
            }
        }
    }'
    
    # Expose service
    kubectl expose deployment prometheus -n $NAMESPACE --port=9090 --target-port=9090
    
    success "Prometheus deployed"
}

# Create log generator job template
create_log_generator() {
    log "Creating log generator job template..."
    
    kubectl create configmap log-generator-script -n $NAMESPACE \
        --from-literal=generate-logs.sh='#!/bin/sh
RATE=${RATE:-1000}
DURATION=${DURATION:-60}
TARGET_URL=${TARGET_URL:-http://fluent-bit-input:9880}

echo "Starting log generation: $RATE msgs/sec for ${DURATION}s to $TARGET_URL"

end_time=$(($(date +%s) + DURATION))
counter=0

while [ $(date +%s) -lt $end_time ]; do
    timestamp=$(date -Iseconds)
    counter=$((counter + 1))
    
    curl -s -X POST "$TARGET_URL" \
        -H "Content-Type: application/json" \
        -d "{\"timestamp\":\"$timestamp\",\"level\":\"INFO\",\"service\":\"load-test\",\"message\":\"Test message $counter\",\"counter\":$counter}" \
        > /dev/null
    
    # Sleep to maintain rate (rough approximation)
    sleep_time=$(echo "scale=3; 1/$RATE" | bc -l 2>/dev/null || echo "0.001")
    sleep $sleep_time || sleep 0.001
done

echo "Generated $counter messages in ${DURATION}s"'

    success "Log generator template created"
}

# Main deployment function
main() {
    log "Starting complete Fluent Bit Benchmark deployment"
    
    # Check prerequisites
    if ! command -v kubectl &> /dev/null; then
        error "kubectl is required but not found"
        exit 1
    fi
    
    # Clean up and deploy everything
    cleanup
    create_namespace
    deploy_benchmark_server
    deploy_fluent_bit
    deploy_prometheus
    create_log_generator
    
    # Wait for deployments
    log "Waiting for all deployments to be ready..."
    wait_for_deployment benchmark-server 120
    wait_for_deployment fluent-bit 120
    wait_for_deployment prometheus 120
    
    # Show status
    log "Final deployment status:"
    kubectl get pods -n $NAMESPACE
    echo ""
    kubectl get services -n $NAMESPACE
    
    success "🎉 Deployment completed successfully!"
    echo ""
    echo "📊 Access your services:"
    echo "   Prometheus:  kubectl port-forward -n $NAMESPACE svc/prometheus 9090:9090"
    echo "   Fluent Bit:  kubectl port-forward -n $NAMESPACE svc/fluent-bit-server 2020:2020"
    echo ""
    echo "🧪 Test the setup:"
    echo "   kubectl port-forward -n $NAMESPACE svc/fluent-bit-input 9880:9880 &"
    echo "   curl -X POST http://localhost:9880 -H 'Content-Type: application/json' -d '{}' "
    echo ""
    echo "📈 Run load test (example - 100 msgs/sec for 30s):"
    echo "   kubectl run load-test -n $NAMESPACE --rm -i --restart=Never \\"
    echo "     --image=alpine/curl --env RATE=100 --env DURATION=30 \\"
    echo "     --overrides='{\"spec\":{\"containers\":[{\"name\":\"load-test\",\"image\":\"alpine/curl\",\"command\":[\"/bin/sh\"],\"args\":[\"/scripts/generate-logs.sh\"],\"env\":[{\"name\":\"RATE\",\"value\":\"100\"},{\"name\":\"DURATION\",\"value\":\"30\"}],\"volumeMounts\":[{\"name\":\"script\",\"mountPath\":\"/scripts\"}]}],\"volumes\":[{\"name\":\"script\",\"configMap\":{\"name\":\"log-generator-script\",\"defaultMode\":493}}]}}'"
}

# Run main function
main "$@"