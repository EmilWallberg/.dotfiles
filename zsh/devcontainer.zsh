dc() (
    set -Eeuo pipefail

    # Error handler with line number context.
    trap 'echo "[ERROR] dc failed at line ${LINENO}" >&2' ERR

    # Basic logging helpers.
    log_info() { printf '[INFO] %s\n' "$*"; }
    log_warn() { printf '[WARN] %s\n' "$*" >&2; }
    log_error() { printf '[ERROR] %s\n' "$*" >&2; return 1; }

    # Check whether a command exists.
    need_cmd() {
        command -v "$1" >/dev/null 2>&1 || log_error "Required command not found: $1"
    }

    # Copy a file only if it exists.
    copy_if_exists() {
        local src="$1"
        local dst="$2"
        if [[ -f "$src" ]]; then
            mkdir -p "$(dirname "$dst")"
            cp "$src" "$dst"
        fi
    }

    # Sync a directory only if it exists.
    sync_dir_if_exists() {
        local src="$1"
        local dst="$2"
        if [[ -d "$src" ]]; then
            mkdir -p "$dst"
            rsync -a --delete "$src/" "$dst/"
        fi
    }

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
    local snapshot_dir="$dc_dir/local-dotfiles"

    # Override this if your dotfiles repo lives elsewhere.
    local config_dir="${DEV_CONFIG_DIR:-$HOME/.config}"
    local devcontainer_dir="$config_dir/devenv/devcontainer"

    # Configuration knobs.
    local force="${DEVUP_FORCE:-0}"
    local remote_user="${DEV_REMOTE_USER:-vscode}"
    local docker_image="${DEV_LLAMACPP_IMAGE:-local/llama.cpp:server-cuda}"
    local docker_container_name="${DEV_LLAMACPP_CONTAINER:-llama-server}"
    local host_port="${DEV_LLAMACPP_HOST_PORT:-11434}"
    local container_port="${DEV_LLAMACPP_CONTAINER_PORT:-8080}"
    local model_root="${DEV_MODEL_ROOT:-$HOME/llms/models}"
    local model_path_in_container
    local model_file="${DEV_MODEL_FILE:-}"
    local gpu_layers="${DEV_GPU_LAYERS:-99}"
    local n_predict="${DEV_N_PREDICT:-512}"
    local threads="${DEV_THREADS:-8}"
    local health_url="http://127.0.0.1:${host_port}/health"

    # Default endpoint for a local OpenAI-compatible backend.
    # Override this if your environment needs a different hostname.
    local ollama_url="${DEV_OLLAMA_URL:-http://host.docker.internal:${host_port}/v1}"

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

    # If the devcontainer already exists and force is not enabled, keep it.
    if [[ -f "$dc_dir/devcontainer.json" && "$force" != "1" ]]; then
        log_info "Dev container already exists at: $dc_dir/devcontainer.json"
    else
        log_info "Initializing DevPod devcontainer in: $root"

        mkdir -p "$dc_dir"
        mkdir -p "$snapshot_dir/.config"

        # Copy useful terminal-centric config directories.
        sync_dir_if_exists "$HOME/.config/nvim" "$snapshot_dir/.config/nvim"
        sync_dir_if_exists "$HOME/.config/zsh" "$snapshot_dir/.config/zsh"
        sync_dir_if_exists "$HOME/.config/tmux" "$snapshot_dir/.config/tmux"

        # Mirror your install.sh behavior for home_files/.
        if [[ -d "$config_dir/home_files" ]]; then
            rsync -a "$config_dir/home_files/" "$snapshot_dir/"
        fi

        # Copy selected host-local files into the workspace home snapshot.
        copy_if_exists "$HOME/.gitconfig" "$snapshot_dir/.gitconfig"
        copy_if_exists "$HOME/.gitconfig_local" "$snapshot_dir/.gitconfig_local"
        copy_if_exists "$HOME/.zshrc" "$snapshot_dir/.zshrc"
        copy_if_exists "$HOME/.zsh_local" "$snapshot_dir/.zsh_local"

        copy_if_exists "$devcontainer_dir/Dockerfile" "$dc_dir/Dockerfile"

        if [[ -f "$devcontainer_dir/post-create.sh" ]]; then
            copy_if_exists "$devcontainer_dir/post-create.sh" "$dc_dir/post-create.sh"
            chmod +x "$dc_dir/post-create.sh"
        fi

        PROJECT_NAME="$project_name" \
        OLLAMA_URL="$ollama_url" \
        REMOTE_USER="$remote_user" \
        envsubst < "$devcontainer_dir/devcontainer.json.template" > "$dc_dir/devcontainer.json"

        log_info "DevPod devcontainer scaffold created."
    fi

    log_info "Project root: $root"
    log_info "Using backend URL for devcontainer: $ollama_url"

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

    # Handle an existing container.
    if docker ps -a --format '{{.Names}}' | grep -Fxq "$docker_container_name"; then
        if docker ps --format '{{.Names}}' | grep -Fxq "$docker_container_name"; then
            log_info "llama.cpp container already running: $docker_container_name"
        else
            log_warn "Removing stopped container: $docker_container_name"
            docker rm -f "$docker_container_name" >/dev/null
        fi
    fi

    # Start the server if it is not already running.
    if ! docker ps --format '{{.Names}}' | grep -Fxq "$docker_container_name"; then
        log_info "Launching llama.cpp server..."
        docker run -d --rm \
            --name "$docker_container_name" \
            --gpus all \
            -p "${host_port}:${container_port}" \
            -v "$model_root:/models:ro" \
            "$docker_image" \
            --model "$model_path_in_container" \
            --port "$container_port" \
            --host 0.0.0.0 \
            -n "$n_predict" \
            --threads "$threads" \
            --n-gpu-layers "$gpu_layers" >/dev/null
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
