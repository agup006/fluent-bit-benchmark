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

# Create ConfigMap with log generator source
create_log_generator_configmap() {
    log "Creating log generator source ConfigMap..."
    
    kubectl create configmap log-generator-source -n $NAMESPACE \
        --from-file=main.go=log-generator/main.go \
        --from-file=go.mod=log-generator/go.mod \
        --dry-run=client -o yaml | kubectl apply -f -
    
    success "Log generator source ConfigMap created"
}

# Main deployment function
main() {
    log "Starting Fluent Bit Benchmark deployment (no Docker build)"
    
    # Check if kubectl is available
    if ! command -v kubectl &> /dev/null; then
        error "kubectl is required but not found"
        exit 1
    fi
    
    warn "Skipping Docker build - using pre-built images only"
    
    # Create namespace
    log "Creating namespace..."
    kubectl apply -f manifests/namespace.yaml
    
    # Deploy components in order (skip log-generator for now)
    deploy_component "benchmark-server"
    deploy_component "fluent-bit"
    deploy_component "monitoring"
    
    # Create log generator source configmap
    create_log_generator_configmap
    
    # Wait for core components to be ready
    log "Waiting for components to be ready..."
    wait_for_deployment benchmark-server 300
    wait_for_deployment fluent-bit 300
    wait_for_deployment prometheus 300
    wait_for_deployment perses 300
    
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
    warn "Log generator needs Docker to build. For now, you can test manually:"
    echo "# Test Fluent Bit directly:"
    echo "curl -X POST http://localhost:9880 -H 'Content-Type: application/json' -d '{\"test\": \"message\"}'"
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