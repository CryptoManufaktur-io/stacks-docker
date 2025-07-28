#!/usr/bin/env bash

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"

# Default values (will be overridden by .env file)
NODE_RPC_PORT=20443
NODE_AUTH_TOKEN=""
SIGNER_PORT=30000
NETWORK="testnet"
CHECK_SIGNER_LOCAL=true  # Set to false if signer runs on different machine

# Load environment variables
if [[ -f "${ENV_FILE}" ]]; then
    source "${ENV_FILE}"
else
    echo -e "${YELLOW}Warning: .env file not found, using defaults${NC}"
fi

# Helper functions
print_header() {
    echo -e "\n${BLUE}=== $1 ===${NC}"
}

print_success() {
    echo -e "${GREEN}✓ $1${NC}"
}

print_error() {
    echo -e "${RED}✗ $1${NC}"
}

print_warning() {
    echo -e "${YELLOW}⚠ $1${NC}"
}

print_info() {
    echo -e "${BLUE}ℹ $1${NC}"
}

# Check if Docker containers are running
check_containers() {
    print_header "Docker Container Status"

    local containers=("node")
    if [[ "${CHECK_SIGNER_LOCAL}" == "true" ]]; then
        containers+=("signer")
    fi
    local all_running=true

    for container in "${containers[@]}"; do
        if docker compose ps --format "table {{.Service}}\t{{.Status}}" | grep -q "^${container}.*Up"; then
            print_success "${container} container is running"
        else
            print_error "${container} container is not running"
            all_running=false
        fi
    done

    if [[ "${CHECK_SIGNER_LOCAL}" == "false" ]]; then
        print_info "Signer check skipped (running on different machine)"
    fi

    if [[ "${all_running}" == "true" ]]; then
        print_success "All expected containers are running"
        return 0
    else
        return 1
    fi
}

# Check node health and sync status
check_node_health() {
    print_header "Stacks Node Health Check"

    local base_url="http://localhost:${NODE_RPC_PORT}"
    local auth_header=""

    if [[ -n "${NODE_AUTH_TOKEN}" && "${NODE_AUTH_TOKEN}" != "change-me" ]]; then
        auth_header="-H Authorization: Bearer ${NODE_AUTH_TOKEN}"
    fi

    # Check if RPC endpoint is accessible
    if ! curl -sf ${auth_header} "${base_url}/v2/info" >/dev/null 2>&1; then
        print_error "Cannot connect to node RPC endpoint at ${base_url}"
        print_info "Make sure the node is running and RPC port ${NODE_RPC_PORT} is accessible"
        return 1
    fi

    print_success "Node RPC endpoint is accessible"

    # Get node info
    local node_info
    node_info=$(curl -sf ${auth_header} "${base_url}/v2/info" 2>/dev/null)

    if [[ -z "${node_info}" ]]; then
        print_error "Failed to get node info"
        return 1
    fi

    # Parse key information
    local stacks_tip_height peer_version burn_block_height
    stacks_tip_height=$(echo "${node_info}" | jq -r '.stacks_tip_height // "unknown"')
    peer_version=$(echo "${node_info}" | jq -r '.peer_version // "unknown"')
    burn_block_height=$(echo "${node_info}" | jq -r '.burn_block_height // "unknown"')

    print_info "Node version: ${peer_version}"
    print_info "Stacks tip height: ${stacks_tip_height}"
    print_info "Bitcoin burn height: ${burn_block_height}"

    # Check sync status
    print_header "Node Sync Status"

    # Get the latest block height from a public API for comparison
    local public_api_url
    if [[ "${NETWORK}" == "mainnet" ]]; then
        public_api_url="https://api.hiro.so/v2/info"
    else
        public_api_url="https://api.testnet.hiro.so/v2/info"
    fi

    local public_height
    public_height=$(curl -sf "${public_api_url}" 2>/dev/null | jq -r '.stacks_tip_height // "unknown"') || {
        print_warning "Could not fetch reference height from public API"
        public_height="unknown"
    }

    if [[ "${public_height}" != "unknown" && "${stacks_tip_height}" != "unknown" ]]; then
        local height_diff=$((public_height - stacks_tip_height))

        if [[ ${height_diff} -le 5 ]]; then
            print_success "Node is in sync (height difference: ${height_diff} blocks)"
        elif [[ ${height_diff} -le 20 ]]; then
            print_warning "Node is slightly behind (height difference: ${height_diff} blocks)"
        elif [[ ${height_diff} -le 1000 ]]; then
            print_warning "Node is behind (height difference: ${height_diff} blocks)"
            print_info "This may take some time to catch up. Monitor progress with repeated checks."
        else
            print_error "Node is significantly behind (height difference: ${height_diff} blocks)"
            print_info "Consider checking if snapshot import completed successfully"
            print_info "Large sync gaps may indicate network issues or corrupted data"
        fi

        print_info "Local node height: ${stacks_tip_height}"
        print_info "Network height: ${public_height}"
    else
        print_warning "Cannot determine sync status - unable to compare heights"
    fi

    return 0
}

# Check signer health
check_signer_health() {
    print_header "Stacks Signer Health Check"

    if [[ "${CHECK_SIGNER_LOCAL}" == "false" ]]; then
        print_info "Signer running on different machine - local check skipped"
        print_info "To check remote signer, run this script on the signer machine"
        return 0
    fi

    # Check if signer container is running
    if ! docker compose ps --format "table {{.Service}}\t{{.Status}}" | grep -q "^signer.*Up"; then
        print_error "Signer container is not running"
        return 1
    fi

    # Check signer logs for recent activity (last 50 lines)
    print_info "Checking recent signer activity..."
    local recent_logs
    recent_logs=$(docker compose logs --tail=50 signer 2>/dev/null || echo "")

    if [[ -z "${recent_logs}" ]]; then
        print_warning "No recent signer logs found"
    else
        # Check for error patterns in logs
        if echo "${recent_logs}" | grep -qi "error\|failed\|panic"; then
            print_warning "Found potential errors in signer logs"
            print_info "Run 'docker compose logs signer' for detailed logs"
        else
            print_success "No obvious errors in recent signer logs"
        fi

        # Check for signing activity
        if echo "${recent_logs}" | grep -qi "signed\|signing\|signature"; then
            print_success "Signer shows recent signing activity"
        else
            print_info "No recent signing activity found (may be normal during low network activity)"
        fi
    fi

    return 0
}

# Check network connectivity
check_network_connectivity() {
    print_header "Network Connectivity Check"

    # Check Bitcoin network connectivity
    local btc_host="${BTC_HOST:-bitcoin.regtest.hiro.so}"
    local btc_port="${BTC_RPC_PORT:-443}"

    if timeout 5 bash -c "</dev/tcp/${btc_host}/${btc_port}" 2>/dev/null; then
        print_success "Bitcoin network connectivity OK (${btc_host}:${btc_port})"
    else
        print_error "Cannot connect to Bitcoin network (${btc_host}:${btc_port})"
    fi

    # Check if P2P port is accessible (basic check)
    local p2p_port="${NODE_P2P_PORT:-20444}"
    if ss -tuln 2>/dev/null | grep -q ":${p2p_port}"; then
        print_success "P2P port ${p2p_port} is listening"
    else
        print_warning "P2P port ${p2p_port} may not be accessible from outside"
    fi
}

# Check disk space
check_disk_space() {
    print_header "Disk Space Check"

    local docker_data_dir
    docker_data_dir=$(docker system info --format '{{.DockerRootDir}}' 2>/dev/null || echo "/var/lib/docker")

    # Get disk usage for the directory containing Docker data
    local usage
    usage=$(df -h "${docker_data_dir}" 2>/dev/null | awk 'NR==2 {print $5}' | sed 's/%//')

    if [[ -n "${usage}" ]]; then
        if [[ ${usage} -lt 80 ]]; then
            print_success "Disk space OK (${usage}% used)"
        elif [[ ${usage} -lt 90 ]]; then
            print_warning "Disk space getting low (${usage}% used)"
        else
            print_error "Disk space critically low (${usage}% used)"
        fi
    else
        print_warning "Could not check disk space"
    fi

    # Check Docker volume sizes
    print_info "Docker volume sizes:"
    docker volume ls --format "table {{.Name}}\t{{.Size}}" 2>/dev/null | grep -E "(stacks|signer)" || print_info "No volume size information available"
}

# Main function
main() {
    echo -e "${BLUE}Stacks Node and Signer Health Check${NC}"
    echo "========================================="
    echo "Network: ${NETWORK}"
    echo "Timestamp: $(date)"

    local exit_code=0

    # Run all checks
    check_containers || exit_code=1
    check_node_health || exit_code=1
    if [[ "${CHECK_SIGNER_LOCAL}" == "true" ]]; then
        check_signer_health || exit_code=1
    else
        check_signer_health  # Always run but don't fail on it
    fi
    check_network_connectivity || exit_code=1
    check_disk_space || exit_code=1

    # Summary
    print_header "Summary"
    if [[ ${exit_code} -eq 0 ]]; then
        print_success "All checks passed successfully!"
    else
        print_warning "Some checks failed or returned warnings. Review the output above."
    fi

    print_info "For detailed logs, run:"
    print_info "  Node logs: docker compose logs node"
    print_info "  Signer logs: docker compose logs signer"
    print_info "  All logs: docker compose logs"

    return ${exit_code}
}

# Check dependencies
if ! command -v jq >/dev/null 2>&1; then
    echo -e "${RED}Error: jq is required but not installed.${NC}"
    echo "Please install jq: brew install jq (on macOS)"
    exit 1
fi

if ! command -v curl >/dev/null 2>&1; then
    echo -e "${RED}Error: curl is required but not installed.${NC}"
    exit 1
fi

# Change to script directory
cd "${SCRIPT_DIR}"

# Run the main function
main "$@"
