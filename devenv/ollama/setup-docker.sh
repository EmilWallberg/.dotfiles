#!/usr/bin/env bash
set -e

# ─────────────────────────────────────────────────────────────────────────────
# Colors and helpers
# ─────────────────────────────────────────────────────────────────────────────

CLR_INFO='\033[36m'    # Cyan
CLR_OK='\033[32m'      # Green
CLR_WARN='\033[33m'    # Yellow
CLR_ERR='\033[31m'     # Red
CLR_BOLD='\033[1m'
CLR_RESET='\033[0m'

log_info()  { echo -e "${CLR_INFO}[INFO]${CLR_RESET} $*"; }
log_ok()    { echo -e "${CLR_OK}[OK]${CLR_RESET} $*"; }
log_warn()  { echo -e "${CLR_WARN}[WARN]${CLR_RESET} $*"; }
log_error() { echo -e "${CLR_ERR}[ERROR]${CLR_RESET} $*"; exit 1; }

# ─────────────────────────────────────────────────────────────────────────────
# Step 1: Preconditions
# ─────────────────────────────────────────────────────────────────────────────

info "Checking Docker installation..."
command -v docker >/dev/null || error "Docker not found"
command -v docker-compose >/dev/null || warn "Using docker compose plugin"
success "Docker available"

info "Checking NVIDIA container support..."
docker run --rm --gpus all nvidia/cuda:12.8.0-base-ubuntu24.04 nvidia-smi >/dev/null \
  || error "NVIDIA Container Toolkit not working"
success "GPU available to Docker"

# ─────────────────────────────────────────────────────────────────────────────
# Step 2: Detect GPU architecture
# ─────────────────────────────────────────────────────────────────────────────

GPU_NAME=$(nvidia-smi --query-gpu=name --format=csv,noheader | head -1)
COMPUTE_CAP=$(nvidia-smi --query-gpu=compute_cap --format=csv,noheader | tr -d '.')

info "Detected GPU: $GPU_NAME (sm_${COMPUTE_CAP})"

if [[ -z "$COMPUTE_CAP" ]]; then
  error "Could not detect compute capability"
fi

# Blackwell guard
if [[ "$COMPUTE_CAP" -ge 120 ]]; then
  CUDA_VERSION="12.8.0"
else
  CUDA_VERSION="12.4.0"
fi

success "Using CUDA ${CUDA_VERSION}"

# ─────────────────────────────────────────────────────────────────────────────
# Step 3: Prepare directories
# ─────────────────────────────────────────────────────────────────────────────

MODEL_DIR="$HOME/llama/models"
mkdir -p "$MODEL_DIR"

info "Model directory: $MODEL_DIR"
echo "Place GGUF models here."

# ─────────────────────────────────────────────────────────────────────────────
# Step 4: Generate docker-compose.yml
# ─────────────────────────────────────────────────────────────────────────────

info "Generating docker-compose.yml..."

cat > docker-compose.yml <<EOF
version: "3.9"
services:
  llama:
    build:
      context: .
      target: server
      args:
        CUDA_VERSION: "${CUDA_VERSION}"
        CUDA_DOCKER_ARCH: "${COMPUTE_CAP}"
    image: turbo3-cuda:server
    container_name: turbo3-cuda
    restart: unless-stopped
    deploy:
      resources:
        reservations:
          devices:
            - capabilities: [gpu]
    volumes:
      - ${MODEL_DIR}:/models:ro
    ports:
      - "11434:8080"
    command:
      [
        "--model", "/models/YOUR_MODEL.gguf",
        "--ctx-size", "32768",
        "--gpu-layers", "99",
        "--threads", "16",
        "--host", "0.0.0.0",
        "--port", "8080"
      ]
EOF

success "docker-compose.yml written"

# ─────────────────────────────────────────────────────────────────────────────
# Step 5: Build image
# ─────────────────────────────────────────────────────────────────────────────

info "Building TurboQuant CUDA image (this takes time)..."
docker compose build

success "Build complete"

# ─────────────────────────────────────────────────────────────────────────────
# Step 6: Final instructions
# ─────────────────────────────────────────────────────────────────────────────

echo ""
echo -e "${BOLD}=========================================${NC}"
echo -e "${BOLD} Docker TurboQuant Setup Complete${NC}"
echo -e "${BOLD}=========================================${NC}"
echo ""
echo "Next steps:"
echo "  1. Copy a GGUF model into: $MODEL_DIR"
echo "  2. Edit docker-compose.yml and set --model"
echo "  3. Run: docker compose up"
echo ""
