dc() (
    set -Eeuo pipefail

    # Error handler with line number context.
    trap 'echo "[ERROR] dc failed at line ${LINENO}" >&2' ERR

    # Basic logging helpers.
    log_info() { printf '[INFO] %s\n' "$*"; }
    log_warn() { printf '[WARN] %s\n' "$*" >&2; }
    log_error() { printf '[ERROR] %s\n' "$*" >&2; return 1; }

    # Load project-local .env if it exists.
    if [[ -f ".env" ]]; then
        log_info "Loading environment variables from .env"
        # Export all variables defined in .env.
        set -a
        source .env
        set +a
    fi

    # Check whether a command exists.
    need_cmd() {
        command -v "$1" >/dev/null 2>&1 || log_error "Required command not found: $1"
    }

    # Copy a file only if it exists.


    # Sync a directory only if it exists.


    # Wait until a HTTP health endpoint responds.
    wait_for_http() {
        local url="$1"
        local retries="${2:-30}"
        local delay="${3:-2}"
        local i

        for ((i = 1; i <= retries; i++)); do
            if curl -fsS "$url" >/dev/null 2>&1; then
                return 0
            fi
            sleep "$delay"
        done

        return 1
    }

    # Resolve the project root. Prefer the git root when available.
    local root
    root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

    local project_name
    project_name="$(basename "$root")"

    local dc_dir="$root/.devcontainer"
    # snapshot_dir is kept for any future non-mounted configs.
    local snapshot_dir="$dc_dir/local-dotfiles"

    # Override this if your dotfiles repo lives elsewhere.
    local config_dir="${DEV_CONFIG_DIR:-$HOME/.config}"
    local devcontainer_dir="$config_dir/devenv/devcontainer"

    # Configuration knobs.
    local force="${DEVUP_FORCE:-0}"
    local remote_user="${DEV_REMOTE_USER:-dev}"
    local docker_image="${DEV_LLAMACPP_IMAGE:-local/llama.cpp:server-cuda}"
    local docker_container_name="${DEV_LLAMACPP_CONTAINER:-llama-server}"
    local host_port="${DEV_LLAMACPP_HOST_PORT:-11434}"
    local container_port="${DEV_LLAMACPP_CONTAINER_PORT:-8080}"
    local model_root="${DEV_MODEL_ROOT:-$HOME/llms/models}"
    local model_path_in_container
    local model_file="${DEV_MODEL_FILE:-}"

    # Stable model identity used across llama.cpp and OpenCode.
    local model_alias="${DEV_LLAMACPP_MODEL_ALIAS:-qwen35-27b-local}"
    local opencode_provider_id="${OPENCODE_PROVIDER_ID:-llama-local}"
    local opencode_model="${OPENCODE_MODEL:-${opencode_provider_id}/${model_alias}}"
    local opencode_small_model="${OPENCODE_SMALL_MODEL:-$opencode_model}"

    # Recommended llama.cpp defaults for a 16 GB GPU + 27B IQ3_XXS model.
    local gpu_layers="${DEV_GPU_LAYERS:-all}"
    local n_predict="${DEV_N_PREDICT:--1}"
    local parallel="${DEV_PARALLEL:-1}"
    local threads="${DEV_THREADS:-4}"
    local threads_batch="${DEV_THREADS_BATCH:-8}"
    local fit="${DEV_FIT:-on}"
    local fit_target="${DEV_FIT_TARGET:-1024}"
    local flash_attn="${DEV_FLASH_ATTN:-on}"
    local cont_batching="${DEV_CONT_BATCHING:-1}"
    local mlock="${DEV_MLOCK:-1}"
    local cache_reuse="${DEV_CACHE_REUSE:-0}"

    local health_url="http://127.0.0.1:${host_port}/health"

    # Default endpoint for a local OpenAI-compatible backend.
    # Override this if your environment needs a different hostname.
    local llamacpp_url="${LLAMACPP_URL:-http://llama-server:8080/v1}"
    local llamacpp_api_key="${LLAMACPP_API_KEY:-llamacpp}"

    # Dependency checks.
    need_cmd git || exit 1
    need_cmd docker || exit 1
    need_cmd devpod-cli || exit 1
    need_cmd rsync || exit 1
    need_cmd envsubst || {
        log_error "envsubst is required. On Arch: sudo pacman -S gettext"
        exit 1
    }
    need_cmd curl || exit 1

    # Validate template location.
    [[ -d "$devcontainer_dir" ]] || {
        log_error "Devcontainer template directory not found: $devcontainer_dir"
        exit 1
    }

    [[ -f "$devcontainer_dir/devcontainer.json.template" ]] || {
        log_error "Missing template: $devcontainer_dir/devcontainer.json.template"
        exit 1
    }

    log_info "Project root: $root"
    log_info "Using backend URL for devcontainer: $llamacpp_url"
    log_info "Using OpenCode model: $opencode_model"
    log_info "Using llama.cpp alias: $model_alias"

    # Validate that the llama.cpp image exists locally.
    if ! docker image inspect "$docker_image" >/dev/null 2>&1; then
        log_error "Docker image not found: $docker_image"
        printf 'Build it first, for example:\n'
        printf '  docker build -t %s --target server -f .devops/cuda.Dockerfile .\n' "$docker_image"
        exit 1
    fi

    # Ensure the model root exists before searching.
    mkdir -p "$model_root"

    # Resolve the model file.
    if [[ -n "$model_file" ]]; then
        [[ -f "$model_file" ]] || {
            log_error "Specified model file does not exist: $model_file"
            exit 1
        }
    else
        model_file="$(find "$model_root" -type f \( -name '*.gguf' -o -name '*.GGUF' \) | sort | head -n 1 || true)"
        [[ -n "$model_file" ]] || {
            log_error "No .gguf model found under: $model_root"
            printf 'Set DEV_MODEL_FILE explicitly, for example:\n'
            printf '  export DEV_MODEL_FILE="$HOME/llms/models/your-model.gguf"\n'
            exit 1
        }
    fi

    # The model must be mounted inside the container under /models.
    if [[ "$model_file" != "$model_root"* ]]; then
        log_error "Model file must live under model root."
        printf 'Model root: %s\n' "$model_root"
        printf 'Model file: %s\n' "$model_file"
        exit 1
    fi

    model_path_in_container="/models/${model_file#$model_root/}"

    log_info "Selected model: $model_file"
    log_info "Container model path: $model_path_in_container"

    # If the devcontainer already exists and force is not enabled, keep it.
    if [[ -f "$dc_dir/devcontainer.json" && "$force" != "1" ]]; then
        log_info "Dev container already exists at: $dc_dir/devcontainer.json"
    else
        log_info "Initializing DevPod devcontainer in: $root"

        mkdir -p "$dc_dir"
        # Config directories (nvim, zsh, tmux, opencode) are now bind-mounted live—see devcontainer.json.template






        # Copy Dockerfile and post-create.sh (if still desired, these could be mounted read-only as well)
        if [[ -f "$devcontainer_dir/Dockerfile" ]]; then
            cp "$devcontainer_dir/Dockerfile" "$dc_dir/Dockerfile"
        fi
        if [[ -f "$devcontainer_dir/post-create.sh" ]]; then
            cp "$devcontainer_dir/post-create.sh" "$dc_dir/post-create.sh"
            chmod +x "$dc_dir/post-create.sh"
        fi

        PROJECT_NAME="$project_name" \
        LLAMACPP_URL="$llamacpp_url" \
        LLAMACPP_API_KEY="$llamacpp_api_key" \
        LLAMACPP_MODEL_ALIAS="$model_alias" \
        OPENCODE_PROVIDER_ID="$opencode_provider_id" \
        OPENCODE_MODEL="$opencode_model" \
        OPENCODE_SMALL_MODEL="$opencode_small_model" \
        REMOTE_USER="$remote_user" \
        envsubst < "$devcontainer_dir/devcontainer.json.template" > "$dc_dir/devcontainer.json"

        log_info "DevPod devcontainer scaffold created."
    fi

    # Handle an existing container.
    if docker ps -a --format '{{.Names}}' | grep -Fxq "$docker_container_name"; then
        if docker ps --format '{{.Names}}' | grep -Fxq "$docker_container_name"; then
            if [[ "$force" == "1" ]]; then
                log_warn "Force enabled, recreating running container: $docker_container_name"
                docker rm -f "$docker_container_name" >/dev/null
            else
                log_info "llama.cpp container already running: $docker_container_name"
            fi
        else
            log_warn "Removing stopped container: $docker_container_name"
            docker rm -f "$docker_container_name" >/dev/null
        fi
    fi

    # Start the server if it is not already running.
    if ! docker ps --format '{{.Names}}' | grep -Fxq "$docker_container_name"; then
        log_info "Launching llama.cpp server..."

        local -a llama_args=(
            --model "$model_path_in_container"
            --alias "$model_alias"
            --port "$container_port"
            --host 0.0.0.0
            --parallel "$parallel"
            -n "$n_predict"
            --threads "$threads"
            --threads-batch "$threads_batch"
            --n-gpu-layers "$gpu_layers"
            --fit "$fit"
            --fit-target "$fit_target"
            --flash-attn "$flash_attn"
        )

        if [[ -n "$llamacpp_api_key" ]]; then
            llama_args+=(--api-key "$llamacpp_api_key")
        fi

        if [[ "$cont_batching" == "1" ]]; then
            llama_args+=(--cont-batching)
        fi

        if [[ "$mlock" == "1" ]]; then
            llama_args+=(--mlock)
        fi

        if [[ "$cache_reuse" != "0" ]]; then
            llama_args+=(--cache-reuse "$cache_reuse")
        fi

        docker run -d --rm \
            --name "$docker_container_name" \
            --network llm-net \
            --gpus all \
            -p "${host_port}:${container_port}" \
            -v "$model_root:/models:ro" \
            "$docker_image" \
            "${llama_args[@]}" >/dev/null
    fi

    log_info "Waiting for llama.cpp health endpoint: $health_url"
    if ! wait_for_http "$health_url" 30 2; then
        log_warn "llama.cpp health check did not become ready in time"
        log_warn "Recent container logs:"
        docker logs --tail 50 "$docker_container_name" || true
        exit 1
    fi

    log_info "llama.cpp server is healthy"

    # Start the DevPod workspace.
    log_info "Starting workspace with DevPod..."
    devpod-cli up "$root" --ide none

    printf '\n'
    printf 'Connect with:\n'
    printf '  ssh %s.devpod\n' "$project_name"
)
