# Fluent Bit Benchmark Suite

A comprehensive benchmarking suite for Fluent Bit performance testing on K3s clusters.

## Architecture

- **Log Generator**: HTTP-based synthetic log generator with configurable throughput
- **Fluent Bit**: HTTP input → HTTP output with full metrics collection
- **Benchmark Server**: [Calyptia HTTPS Benchmark Server](https://github.com/chronosphereio/calyptia-https-benchmark-server)
- **Monitoring**: Prometheus + Perses for metrics visualization
- **Orchestration**: Automated benchmark runner for multiple throughput levels

## Throughput Levels

- 1k messages/second
- 3k messages/second  
- 5k messages/second
- 10k messages/second
- 15k messages/second

## Quick Start

```bash
# Deploy benchmark server
kubectl apply -f manifests/benchmark-server/

# Deploy Fluent Bit
kubectl apply -f manifests/fluent-bit/

# Deploy monitoring stack
kubectl apply -f manifests/monitoring/

# Run benchmarks
./scripts/run-benchmark.sh
```

## Components

- `benchmark-server/` - Calyptia HTTPS benchmark server (submodule)
- `log-generator/` - Synthetic log generation service
- `manifests/` - K3s deployment manifests
- `configs/` - Fluent Bit configurations
- `dashboards/` - Perses dashboard definitions
- `scripts/` - Benchmark orchestration scripts