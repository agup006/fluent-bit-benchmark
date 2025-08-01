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
    local timeout=${2:-300}
    
    log "Waiting for deployment $deployment to be ready..."
    kubectl wait deployment/$deployment -n $NAMESPACE --for=condition=Available --timeout=${timeout}s
    if [ $? -eq 0 ]; then
        success "Deployment $deployment is ready"
    else
        error "Deployment $deployment failed to become ready within ${timeout}s"
        return 1
    fi
}

# Function to build log generator image
build_log_generator() {
    log "Building log generator Docker image..."
    
    cd log-generator
    docker build -t fluent-bit-benchmark/log-generator:latest .
    cd ..
    
    success "Log generator image built successfully"
}

# Function to deploy components
deploy_component() {
    local component=$1
    local path="manifests/$component"
    
    log "Deploying $component..."
    
    if [ -d "$path" ]; then
        kubectl apply -f "$path/"
        success "$component deployed"
    else
        error "Component directory not found: $path"
        return 1
    fi
}

# Main deployment function
main() {
    log "Starting Fluent Bit Benchmark deployment"
    
    # Check if kubectl is available
    if ! command -v kubectl &> /dev/null; then
        error "kubectl is required but not found"
        exit 1
    fi
    
    # Check if docker is available
    if ! command -v docker &> /dev/null; then
        error "docker is required but not found"
        exit 1
    fi
    
    # Build log generator image
    build_log_generator
    
    # Create namespace
    log "Creating namespace..."
    kubectl apply -f manifests/namespace.yaml
    
    # Deploy components in order
    deploy_component "benchmark-server"
    deploy_component "fluent-bit"
    deploy_component "monitoring"
    deploy_component "log-generator"
    
    # Wait for core components to be ready
    log "Waiting for components to be ready..."
    wait_for_deployment benchmark-server 300
    wait_for_deployment fluent-bit 300
    wait_for_deployment prometheus 300
    wait_for_deployment perses 300
    
    # Scale down log generator (it's controlled by benchmark script)
    log "Scaling down log generator..."
    kubectl scale deployment log-generator -n $NAMESPACE --replicas=0
    
    # Get service information
    log "Getting service information..."
    kubectl get services -n $NAMESPACE
    
    # Show port forwarding commands
    success "Deployment completed successfully!"
    echo ""
    echo "To access the services, use these port forwarding commands:"
    echo ""
    echo "# Prometheus (metrics):"
    echo "kubectl port-forward -n $NAMESPACE svc/prometheus 9090:9090"
    echo ""
    echo "# Perses (dashboard):"
    echo "kubectl port-forward -n $NAMESPACE svc/perses 8080:8080"
    echo ""
    echo "# Fluent Bit (HTTP server):"
    echo "kubectl port-forward -n $NAMESPACE svc/fluent-bit 2020:2020"
    echo ""
    echo "# Benchmark Server (status):"
    echo "kubectl port-forward -n $NAMESPACE svc/benchmark-server 8080:8080"
    echo ""
    echo "To run benchmarks:"
    echo "./scripts/run-benchmark.sh"
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --namespace)
            NAMESPACE="$2"
            shift 2
            ;;
        --help)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --namespace NAMESPACE  Kubernetes namespace (default: fluent-bit-benchmark)"
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