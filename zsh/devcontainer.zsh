dc() (
    set -Eeuo pipefail

    trap 'echo "[ERROR] dc failed at line ${LINENO}" >&2' ERR

    # Basic logging helpers.
    log_info() { printf '[INFO] %s\n' "$*"; }
    log_warn() { printf '[WARN] %s\n' "$*" >&2; }
    log_error() { printf '[ERROR] %s\n' "$*" >&2; return 1; }

    # Load project-local .env if it exists.
    if [[ -f ".env" ]]; then
        log_info "Loading environment variables from .env"
        set -a
        source .env
        set +a
    fi

    # Check whether a command exists.
    need_cmd() {
        command -v "$1" >/dev/null 2>&1 || log_error "Required command not found: $1"
    }

    # Return an absolute path for an existing file or directory.
    abs_path() {
        local target="$1"

        if [[ -d "$target" ]]; then
            (
                cd "$target" >/dev/null 2>&1
                pwd -P
            )
        else
            (
                cd "$(dirname "$target")" >/dev/null 2>&1
                printf '%s/%s\n' "$(pwd -P)" "$(basename "$target")"
            )
        fi
    }

    # Print usage help.
    print_usage() {
        cat <<'EOF'
Usage:
  dc up [model-query]
      Create/update the devcontainer if needed, ensure llama.cpp is running,
      and start the DevPod workspace. If model-query is provided, it becomes
      the selected model before startup.

  dc model list
      List all available .gguf files under DEV_MODEL_ROOT.

  dc model current
      Show the persisted and running model.

  dc model use <model-query-or-path> [-p|--profile <profile>]
      Persist a model selection and restart only the llama.cpp container.
      DevPod is not recreated.

  dc model profile <profile>
      Persist a model profile for the current model and restart only llama.cpp.
      DevPod is not recreated.

  dc yarn off
      Disable extended context flags.

  dc yarn on
      Enable extended context with the default 512k preset.

  dc yarn set <256k|512k|768k|1m>
      Enable extended context and set the requested context preset.

  dc turbo off
      Disable TurboQuant KV cache flags.

  dc turbo on
      Enable TurboQuant KV cache with the quality preset.

  dc turbo set <speed|long|quality|quality-asym|compression>
      Enable TurboQuant KV cache and select a preset.

  dc status
      Show current status for the model selection and llama.cpp server.

  dc logs
      Show llama.cpp container logs.

Notes:
  - model-query can be either:
      * a full path to a .gguf file
      * a case-insensitive substring matched against files under DEV_MODEL_ROOT
  - Model profiles are looked up next to the model as:
      <model-basename>.profile.<profile>.toml
  - The devcontainer continues to use the same LLAMACPP_URL and model alias.
    Only the underlying llama.cpp model/runtime configuration is swapped.
EOF
    }

    # Resolve the project root.
    local root
    root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

    local project_name
    project_name="$(basename "$root")"

    local dc_dir="$root/.devcontainer"
    local config_dir="${DEV_CONFIG_DIR:-$HOME/.config}"
    local devcontainer_dir="$config_dir/devenv/devcontainer"
    local state_file="$dc_dir/.llama-model.env"

    # Load persisted model selection if it exists.
    if [[ -f "$state_file" ]]; then
        log_info "Loading persisted model selection from $state_file"
        set -a
        source "$state_file"
        set +a
    fi

    # Configuration knobs.
    local force="${DEVUP_FORCE:-0}"
    local remote_user="${DEV_REMOTE_USER:-dev}"
    local docker_image="${DEV_LLAMACPP_IMAGE:-local/llama.cpp:server-cuda}"
    local docker_container_name="${DEV_LLAMACPP_CONTAINER:-llama-server}"
    local docker_network_name="${DEV_LLAMACPP_NETWORK:-llm-net}"
    local host_port="${DEV_LLAMACPP_HOST_PORT:-11434}"
    local container_port="${DEV_LLAMACPP_CONTAINER_PORT:-8080}"
    local model_root="${DEV_MODEL_ROOT:-$HOME/.llms/models}"
    local model_file="${DEV_MODEL_FILE:-}"
    local model_path_in_container=""

    # Persisted model profile state.
    : "${DEV_MODEL_PROFILE:=}"
    : "${DEV_MODEL_PROFILE_FILE:=}"

    # Persisted extended context / YaRN-style state.
    : "${DEV_YARN_ENABLE:=0}"
    : "${DEV_YARN_CTX_SIZE:=262144}"
    : "${DEV_YARN_ROPE_SCALE:=1.0}"

    # Persisted TurboQuant KV state.
    : "${DEV_TURBO_ENABLE:=0}"
    : "${DEV_TURBO_PRESET:=}"
    : "${DEV_TURBO_K:=}"
    : "${DEV_TURBO_V:=}"
    : "${DEV_TURBO_FA:=0}"

    # Keep the alias stable so DevPod/OpenCode does not need to change when the file changes.
    local model_alias="${DEV_LLAMACPP_MODEL_ALIAS:-qwen35-27b-local}"
    local opencode_provider_id="${OPENCODE_PROVIDER_ID:-llama-local}"
    local opencode_model="${OPENCODE_MODEL:-${opencode_provider_id}/${model_alias}}"
    local opencode_small_model="${OPENCODE_SMALL_MODEL:-$opencode_model}"

    # Recommended llama.cpp defaults.
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
    local llamacpp_url="${LLAMACPP_URL:-http://llama-server:8080/v1}"
    local llamacpp_api_key="${LLAMACPP_API_KEY:-llamacpp}"

    # Persist the selected model and llama.cpp runtime state so future dc calls reuse it.
    save_model_selection() {
        mkdir -p "$dc_dir"

        {
            echo "# Generated by dc. This file stores the selected llama.cpp model/runtime state."
            printf 'export DEV_MODEL_FILE=%q\n' "$model_file"
            printf 'export DEV_MODEL_PROFILE=%q\n' "$DEV_MODEL_PROFILE"
            printf 'export DEV_MODEL_PROFILE_FILE=%q\n' "$DEV_MODEL_PROFILE_FILE"
            printf 'export DEV_YARN_ENABLE=%q\n' "$DEV_YARN_ENABLE"
            printf 'export DEV_YARN_CTX_SIZE=%q\n' "$DEV_YARN_CTX_SIZE"
            printf 'export DEV_YARN_ROPE_SCALE=%q\n' "$DEV_YARN_ROPE_SCALE"
            printf 'export DEV_TURBO_ENABLE=%q\n' "$DEV_TURBO_ENABLE"
            printf 'export DEV_TURBO_PRESET=%q\n' "$DEV_TURBO_PRESET"
            printf 'export DEV_TURBO_K=%q\n' "$DEV_TURBO_K"
            printf 'export DEV_TURBO_V=%q\n' "$DEV_TURBO_V"
            printf 'export DEV_TURBO_FA=%q\n' "$DEV_TURBO_FA"
        } > "$state_file"
    }

    # Print all models under the model root.
    find_models() {
        local resolved_model_root

        mkdir -p "$model_root"
        resolved_model_root="$(abs_path "$model_root")"

        find "$resolved_model_root" -type f \( -iname '*.gguf' \) | sort
    }

    # Enumerate models under the model root.
    list_models() {
        local selected=""
        local found=0
        local resolved_model_root
        local model_entry
        local rel
        local prefix

        resolved_model_root="$(abs_path "$model_root")"

        if [[ -n "${DEV_MODEL_FILE:-}" && -f "${DEV_MODEL_FILE:-}" ]]; then
            selected="$(abs_path "$DEV_MODEL_FILE")"
        fi

        printf 'Available models under %s:\n' "$resolved_model_root"

        while IFS= read -r model_entry; do
            [[ -n "$model_entry" ]] || continue
            found=1
            rel="${model_entry#$resolved_model_root/}"
            prefix=" "
            if [[ -n "$selected" && "$model_entry" == "$selected" ]]; then
                prefix="*"
            fi
            printf ' %s %s\n' "$prefix" "$rel"
        done < <(find_models)

        if [[ "$found" == "0" ]]; then
            log_warn "No .gguf models found under: $resolved_model_root"
        fi
    }

    # Resolve the model file from either a path or a case-insensitive substring.
    resolve_model_file() {
        local query="${1:-}"
        local selected_path=""
        local resolved_model_root
        local model_entry
        local match_count=0
        local first_match=""
        local match_lines=""

        mkdir -p "$model_root"
        resolved_model_root="$(abs_path "$model_root")"

        if [[ -n "$query" ]]; then
            if [[ -f "$query" ]]; then
                selected_path="$(abs_path "$query")"
            else
                while IFS= read -r model_entry; do
                    [[ -n "$model_entry" ]] || continue

                    if printf '%s\n' "$model_entry" | grep -iF -- "$query" >/dev/null 2>&1; then
                        match_count=$((match_count + 1))

                        if [[ "$match_count" -eq 1 ]]; then
                            first_match="$model_entry"
                        fi

                        match_lines="${match_lines}  ${model_entry#$resolved_model_root/}"$'\n'
                    fi
                done < <(find_models)

                if [[ "$match_count" -eq 0 ]]; then
                    log_error "No model matched query: $query"
                    printf '\n' >&2
                    list_models >&2
                    return 1
                fi

                if [[ "$match_count" -gt 1 ]]; then
                    log_error "Model query is ambiguous: $query"
                    printf 'Matches:\n%b' "$match_lines" >&2
                    return 1
                fi

                selected_path="$first_match"
            fi
        elif [[ -n "$model_file" ]]; then
            selected_path="$(abs_path "$model_file")"
        else
            while IFS= read -r model_entry; do
                [[ -n "$model_entry" ]] || continue
                selected_path="$model_entry"
                break
            done < <(find_models)
        fi

        [[ -n "$selected_path" ]] || {
            log_error "No .gguf model found under: $resolved_model_root"
            printf 'Set DEV_MODEL_FILE or use: dc model use <query>\n' >&2
            return 1
        }

        [[ -f "$selected_path" ]] || {
            log_error "Selected model file does not exist: $selected_path"
            return 1
        }

        model_root="$resolved_model_root"
        model_file="$(abs_path "$selected_path")"

        if [[ "$model_file" != "$model_root/"* ]]; then
            log_error "Model file must live under model root."
            printf 'Model root: %s\n' "$model_root" >&2
            printf 'Model file: %s\n' "$model_file" >&2
            return 1
        fi

        model_path_in_container="/models/${model_file#$model_root/}"
    }

    # Resolve a profile file next to the selected model.
    resolve_profile_file() {
        local profile="${1:-}"

        DEV_MODEL_PROFILE=""
        DEV_MODEL_PROFILE_FILE=""

        [[ -z "$profile" ]] && return 0

        local profile_file="${model_file%.gguf}.profile.${profile}.toml"

        [[ -f "$profile_file" ]] || {
            log_error "Profile not found: $profile_file"
            return 1
        }

        DEV_MODEL_PROFILE="$profile"
        DEV_MODEL_PROFILE_FILE="$profile_file"
    }

    # Load a small TOML-like model profile.
    load_profile() {
        local profile_file="$1"

        unset PROFILE_TEMPERATURE PROFILE_TOP_P PROFILE_TOP_K PROFILE_MIN_P
        unset PROFILE_PRESENCE_PENALTY PROFILE_REPEAT_PENALTY CHAT_TEMPLATE_KWARGS

        while IFS='=' read -r key value; do
            key="$(printf '%s' "$key" | xargs)"
            value="$(printf '%s' "$value" | sed 's/^ *//; s/ *$//; s/^"//; s/"$//')"

            case "$key" in
                temperature) PROFILE_TEMPERATURE="$value" ;;
                top_p) PROFILE_TOP_P="$value" ;;
                top_k) PROFILE_TOP_K="$value" ;;
                min_p) PROFILE_MIN_P="$value" ;;
                presence_penalty) PROFILE_PRESENCE_PENALTY="$value" ;;
                repeat_penalty) PROFILE_REPEAT_PENALTY="$value" ;;
            esac
        done < <(grep -E '^[a-z_]+ *= *' "$profile_file" || true)

        local enable_thinking=""
        local preserve_thinking=""
        local -a kwargs_parts

        enable_thinking="$(grep -E 'enable_thinking *= *' "$profile_file" | awk -F= '{print $2}' | xargs 2>/dev/null || true)"
        preserve_thinking="$(grep -E 'preserve_thinking *= *' "$profile_file" | awk -F= '{print $2}' | xargs 2>/dev/null || true)"

        [[ -n "$enable_thinking" ]] && kwargs_parts+=("\"enable_thinking\":$enable_thinking")
        [[ -n "$preserve_thinking" ]] && kwargs_parts+=("\"preserve_thinking\":$preserve_thinking")

        if (( ${#kwargs_parts[@]} > 0 )); then
            CHAT_TEMPLATE_KWARGS="{${(j:,:)kwargs_parts}}"
        fi
    }

    # Ensure the template files exist and render devcontainer.json if needed.
    ensure_devcontainer_scaffold() {
        need_cmd envsubst || {
            log_error "envsubst is required. On Arch: sudo pacman -S gettext"
            exit 1
        }

        [[ -d "$devcontainer_dir" ]] || {
            log_error "Devcontainer template directory not found: $devcontainer_dir"
            exit 1
        }

        [[ -f "$devcontainer_dir/devcontainer.json.template" ]] || {
            log_error "Missing template: $devcontainer_dir/devcontainer.json.template"
            exit 1
        }

        if [[ -f "$dc_dir/devcontainer.json" && "$force" != "1" ]]; then
            log_info "Dev container already exists at: $dc_dir/devcontainer.json"
            return 0
        fi

        log_info "Initializing DevPod devcontainer in: $root"

        mkdir -p "$dc_dir"

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
    }

    # Ensure the docker network used by llama.cpp exists.
    ensure_llama_network() {
        if ! docker network inspect "$docker_network_name" >/dev/null 2>&1; then
            log_info "Creating docker network: $docker_network_name"
            docker network create "$docker_network_name" >/dev/null
        fi
    }

    # Print inspect output and logs for the llama.cpp container.
    show_llama_debug() {
        if docker ps -a --format '{{.Names}}' | grep -Fxq "$docker_container_name"; then
            printf '\n'
            printf 'Container state:\n'
            docker inspect -f '  status={{.State.Status}} exit={{.State.ExitCode}} error={{.State.Error}} started={{.State.StartedAt}} finished={{.State.FinishedAt}}' "$docker_container_name" 2>/dev/null || true

            printf '\n'
            printf 'Recent container logs:\n'
            docker logs --tail 200 "$docker_container_name" 2>&1 || true
        else
            log_warn "Container does not exist: $docker_container_name"
        fi
    }

    # Build a runtime key so llama.cpp is recreated when llama-related state changes.
    llama_runtime_key() {
        printf 'model=%s|profile=%s|profile_file=%s|yarn=%s|ctx=%s|rope=%s|turbo=%s|preset=%s|k=%s|v=%s|fa=%s\n' \
            "$model_file" \
            "${DEV_MODEL_PROFILE:-}" \
            "${DEV_MODEL_PROFILE_FILE:-}" \
            "$DEV_YARN_ENABLE" \
            "$DEV_YARN_CTX_SIZE" \
            "$DEV_YARN_ROPE_SCALE" \
            "$DEV_TURBO_ENABLE" \
            "$DEV_TURBO_PRESET" \
            "$DEV_TURBO_K" \
            "$DEV_TURBO_V" \
            "$DEV_TURBO_FA"
    }

    # Start or restart the llama.cpp server with the selected model.
    ensure_llama_running() {
        need_cmd docker || exit 1
        need_cmd curl || exit 1

        if ! docker image inspect "$docker_image" >/dev/null 2>&1; then
            log_error "Docker image not found: $docker_image"
            printf 'Build it first, for example:\n' >&2
            printf '  docker build -t %s --target server -f .devops/cuda.Dockerfile .\n' "$docker_image" >&2
            exit 1
        fi

        ensure_llama_network

        log_info "Selected model: $model_file"
        log_info "Container model path: $model_path_in_container"
        log_info "Using backend URL for devcontainer: $llamacpp_url"
        log_info "Using OpenCode model: $opencode_model"
        log_info "Using llama.cpp alias: $model_alias"

        local desired_runtime_key
        desired_runtime_key="$(llama_runtime_key)"

        local container_exists=0
        local container_running=0
        local running_model_file=""
        local running_runtime_key=""
        local container_id=""

        if docker ps -a --format '{{.Names}}' | grep -Fxq "$docker_container_name"; then
            container_exists=1
            running_model_file="$(docker inspect -f '{{ index .Config.Labels "dev.llamacpp.model_file" }}' "$docker_container_name" 2>/dev/null || true)"
            running_runtime_key="$(docker inspect -f '{{ index .Config.Labels "dev.llamacpp.runtime_key" }}' "$docker_container_name" 2>/dev/null || true)"

            if docker ps --format '{{.Names}}' | grep -Fxq "$docker_container_name"; then
                container_running=1
            fi
        fi

        if [[ "$container_exists" -eq 1 ]]; then
            if [[ "$container_running" -eq 1 && "$running_model_file" == "$model_file" && "$running_runtime_key" == "$desired_runtime_key" && "$force" != "1" ]]; then
                log_info "llama.cpp container already running with the selected runtime: $docker_container_name"
            else
                if [[ "$container_running" -eq 1 ]]; then
                    log_warn "Recreating llama.cpp container: $docker_container_name"
                else
                    log_warn "Removing stopped llama.cpp container: $docker_container_name"
                fi
                docker rm -f "$docker_container_name" >/dev/null || true
                container_running=0
            fi
        fi

        if [[ "$container_running" -eq 0 ]]; then
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
            )

            if [[ "$DEV_TURBO_ENABLE" == "1" ]]; then
                [[ -n "$DEV_TURBO_K" ]] && llama_args+=(-ctk "$DEV_TURBO_K")
                [[ -n "$DEV_TURBO_V" ]] && llama_args+=(-ctv "$DEV_TURBO_V")
                [[ "$DEV_TURBO_FA" == "1" ]] && llama_args+=(-fa on)
            else
                llama_args+=(--flash-attn "$flash_attn")
            fi

            if [[ "$DEV_YARN_ENABLE" == "1" ]]; then
                llama_args+=(
                    --ctx-size "$DEV_YARN_CTX_SIZE"
                    --rope-scaling yarn
                    --rope-scale "$DEV_YARN_ROPE_SCALE"
                )
            fi

            if [[ -n "$DEV_MODEL_PROFILE_FILE" ]]; then
                load_profile "$DEV_MODEL_PROFILE_FILE"

                [[ -n "${PROFILE_TEMPERATURE:-}" ]] && llama_args+=(--temp "$PROFILE_TEMPERATURE")
                [[ -n "${PROFILE_TOP_P:-}" ]] && llama_args+=(--top-p "$PROFILE_TOP_P")
                [[ -n "${PROFILE_TOP_K:-}" ]] && llama_args+=(--top-k "$PROFILE_TOP_K")
                [[ -n "${PROFILE_MIN_P:-}" ]] && llama_args+=(--min-p "$PROFILE_MIN_P")
                [[ -n "${PROFILE_PRESENCE_PENALTY:-}" ]] && llama_args+=(--presence_penalty "$PROFILE_PRESENCE_PENALTY")
                [[ -n "${PROFILE_REPEAT_PENALTY:-}" ]] && llama_args+=(--repeat-penalty "$PROFILE_REPEAT_PENALTY")
                [[ -n "${CHAT_TEMPLATE_KWARGS:-}" ]] && llama_args+=(--chat-template-kwargs "$CHAT_TEMPLATE_KWARGS")
            fi

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

            container_id="$(
                docker run -d \
                    --name "$docker_container_name" \
                    --label "dev.llamacpp.model_file=$model_file" \
                    --label "dev.llamacpp.model_alias=$model_alias" \
                    --label "dev.llamacpp.runtime_key=$desired_runtime_key" \
                    --network "$docker_network_name" \
                    --gpus all \
                    -p "${host_port}:${container_port}" \
                    -v "$model_root:/models:ro" \
                    "$docker_image" \
                    "${llama_args[@]}"
            )"

            [[ -n "$container_id" ]] || {
                log_error "docker run did not return a container id"
                exit 1
            }

            # Give the process a moment to fail fast so we can inspect it.
            sleep 2

            if ! docker ps --format '{{.Names}}' | grep -Fxq "$docker_container_name"; then
                log_error "llama.cpp container exited immediately after startup"
                show_llama_debug
                exit 1
            fi
        fi
    }

    # Show current model selection and running state.
    show_status() {
        need_cmd docker || exit 1
        need_cmd curl || exit 1

        printf 'Project root: %s\n' "$root"
        printf 'Model root: %s\n' "$(abs_path "$model_root")"
        printf 'Persisted model: %s\n' "${DEV_MODEL_FILE:-<none>}"
        printf 'Backend URL: %s\n' "$llamacpp_url"
        printf 'Model alias: %s\n' "$model_alias"
        printf 'Model profile: %s\n' "${DEV_MODEL_PROFILE:-<none>}"
        printf 'Profile file: %s\n' "${DEV_MODEL_PROFILE_FILE:-<none>}"
        printf 'YaRN enabled: %s\n' "$DEV_YARN_ENABLE"
        printf 'YaRN ctx-size: %s\n' "$DEV_YARN_CTX_SIZE"
        printf 'YaRN rope-scale: %s\n' "$DEV_YARN_ROPE_SCALE"
        printf 'Turbo enabled: %s\n' "$DEV_TURBO_ENABLE"
        printf 'Turbo preset: %s\n' "${DEV_TURBO_PRESET:-<none>}"
        printf 'Turbo K/V/FA: K=%s V=%s FA=%s\n' "${DEV_TURBO_K:-<none>}" "${DEV_TURBO_V:-<none>}" "$DEV_TURBO_FA"

        if docker ps -a --format '{{.Names}}' | grep -Fxq "$docker_container_name"; then
            local running_model_file
            local running_runtime_key
            running_model_file="$(docker inspect -f '{{ index .Config.Labels "dev.llamacpp.model_file" }}' "$docker_container_name" 2>/dev/null || true)"
            running_runtime_key="$(docker inspect -f '{{ index .Config.Labels "dev.llamacpp.runtime_key" }}' "$docker_container_name" 2>/dev/null || true)"

            if docker ps --format '{{.Names}}' | grep -Fxq "$docker_container_name"; then
                printf 'llama.cpp container: running (%s)\n' "$docker_container_name"
            else
                printf 'llama.cpp container: stopped (%s)\n' "$docker_container_name"
            fi

            printf 'Running model: %s\n' "${running_model_file:-<unknown>}"
            printf 'Running runtime key: %s\n' "${running_runtime_key:-<unknown>}"
            docker inspect -f 'State: status={{.State.Status}} exit={{.State.ExitCode}} error={{.State.Error}}' "$docker_container_name" 2>/dev/null || true
        else
            printf 'llama.cpp container: not created\n'
            printf 'Running model: <none>\n'
        fi

        if curl -fsS "$health_url" >/dev/null 2>&1; then
            printf 'Health: healthy (%s)\n' "$health_url"
        else
            printf 'Health: not ready (%s)\n' "$health_url"
        fi
    }

    # Show llama.cpp logs.
    show_logs() {
        need_cmd docker || exit 1

        if docker ps -a --format '{{.Names}}' | grep -Fxq "$docker_container_name"; then
            docker logs --tail 200 -f "$docker_container_name"
        else
            log_error "Container does not exist: $docker_container_name"
            exit 1
        fi
    }

    # Start the DevPod workspace.
    start_workspace() {
        need_cmd devpod-cli || exit 1

        log_info "Starting workspace with DevPod..."
        devpod-cli up "$root" --ide none

        printf '\n'
        printf 'Connect with:\n'
        printf '  ssh %s.devpod\n' "$project_name"
    }

    need_cmd git || exit 1

    local cmd="${1:-up}"
    shift || true

    case "$cmd" in
        up)
            local query="${1:-}"

            resolve_model_file "$query"
            resolve_profile_file "$DEV_MODEL_PROFILE"
            save_model_selection
            ensure_devcontainer_scaffold
            ensure_llama_running
            start_workspace
            ;;
        model)
            local subcmd="${1:-current}"
            shift || true

            case "$subcmd" in
                list)
                    list_models
                    ;;
                current)
                    show_status
                    ;;
                use)
                    local query=""
                    local profile=""

                    while [[ $# -gt 0 ]]; do
                        case "$1" in
                            -p|--profile)
                                profile="${2:-}"
                                [[ -n "$profile" ]] || {
                                    log_error "Usage: dc model use <model-query-or-path> -p <profile>"
                                    exit 1
                                }
                                shift 2
                                ;;
                            *)
                                query="$1"
                                shift
                                ;;
                        esac
                    done

                    [[ -n "$query" ]] || {
                        log_error "Usage: dc model use <model-query-or-path> [-p|--profile <profile>]"
                        exit 1
                    }

                    resolve_model_file "$query"
                    resolve_profile_file "$profile"
                    save_model_selection
                    ensure_llama_running

                    printf '\n'
                    printf 'Model switched successfully.\n'
                    printf 'Persisted model: %s\n' "$model_file"
                    printf 'Persisted profile: %s\n' "${DEV_MODEL_PROFILE:-<none>}"
                    ;;
                profile)
                    local profile="${1:-}"

                    [[ -n "$profile" ]] || {
                        log_error "Usage: dc model profile <profile>"
                        exit 1
                    }

                    resolve_model_file ""
                    resolve_profile_file "$profile"
                    save_model_selection
                    ensure_llama_running

                    printf '\n'
                    printf 'Model profile switched successfully.\n'
                    printf 'Persisted model: %s\n' "$model_file"
                    printf 'Persisted profile: %s\n' "$DEV_MODEL_PROFILE"
                    ;;
                *)
                    log_error "Unknown model subcommand: $subcmd"
                    print_usage
                    exit 1
                    ;;
            esac
            ;;
        yarn)
            local subcmd="${1:-}"
            shift || true

            case "$subcmd" in
                off)
                    DEV_YARN_ENABLE=0
                    DEV_YARN_CTX_SIZE=262144
                    DEV_YARN_ROPE_SCALE=1.0
                    ;;
                on)
                    DEV_YARN_ENABLE=1
                    DEV_YARN_CTX_SIZE=524288
                    DEV_YARN_ROPE_SCALE=2.0
                    ;;
                set)
                    DEV_YARN_ENABLE=1
                    case "${1:-}" in
                        256k) DEV_YARN_CTX_SIZE=262144; DEV_YARN_ROPE_SCALE=1.0 ;;
                        512k) DEV_YARN_CTX_SIZE=524288; DEV_YARN_ROPE_SCALE=2.0 ;;
                        768k) DEV_YARN_CTX_SIZE=786432; DEV_YARN_ROPE_SCALE=3.0 ;;
                        1m)   DEV_YARN_CTX_SIZE=1048576; DEV_YARN_ROPE_SCALE=4.0 ;;
                        *)
                            log_error "Usage: dc yarn set <256k|512k|768k|1m>"
                            exit 1
                            ;;
                    esac
                    ;;
                *)
                    log_error "Usage: dc yarn off|on|set <256k|512k|768k|1m>"
                    exit 1
                    ;;
            esac

            resolve_model_file ""
            resolve_profile_file "$DEV_MODEL_PROFILE"
            save_model_selection
            ensure_llama_running
            ;;
        turbo)
            local subcmd="${1:-}"
            shift || true

            case "$subcmd" in
                off)
                    DEV_TURBO_ENABLE=0
                    DEV_TURBO_PRESET=""
                    DEV_TURBO_K=""
                    DEV_TURBO_V=""
                    DEV_TURBO_FA=0
                    ;;
                on)
                    DEV_TURBO_ENABLE=1
                    DEV_TURBO_PRESET="quality"
                    DEV_TURBO_K="turbo4"
                    DEV_TURBO_V="turbo4"
                    DEV_TURBO_FA=1
                    ;;
                set)
                    DEV_TURBO_ENABLE=1
                    case "${1:-}" in
                        speed)
                            DEV_TURBO_PRESET="speed"
                            DEV_TURBO_K="turbo3"
                            DEV_TURBO_V="turbo3"
                            ;;
                        long)
                            DEV_TURBO_PRESET="long"
                            DEV_TURBO_K="turbo2"
                            DEV_TURBO_V="turbo2"
                            ;;
                        quality)
                            DEV_TURBO_PRESET="quality"
                            DEV_TURBO_K="turbo4"
                            DEV_TURBO_V="turbo4"
                            ;;
                        quality-asym)
                            DEV_TURBO_PRESET="quality-asym"
                            DEV_TURBO_K="turbo4"
                            DEV_TURBO_V="q8_0"
                            ;;
                        compression)
                            DEV_TURBO_PRESET="compression"
                            DEV_TURBO_K="turbo1.5"
                            DEV_TURBO_V="turbo1.5"
                            ;;
                        *)
                            log_error "Usage: dc turbo set <speed|long|quality|quality-asym|compression>"
                            exit 1
                            ;;
                    esac
                    DEV_TURBO_FA=1
                    ;;
                *)
                    log_error "Usage: dc turbo off|on|set <speed|long|quality|quality-asym|compression>"
                    exit 1
                    ;;
            esac

            resolve_model_file ""
            resolve_profile_file "$DEV_MODEL_PROFILE"
            save_model_selection
            ensure_llama_running
            ;;
        status)
            show_status
            ;;
        logs)
            show_logs
            ;;
        help|-h|--help)
            print_usage
            ;;
        *)
            log_error "Unknown command: $cmd"
            print_usage
            exit 1
            ;;
    esac
)

#compdef dc

# Complete model files from DEV_MODEL_ROOT.
_dc_models() {
    local model_root="${DEV_MODEL_ROOT:-$HOME/.llms/models}"
    local -a model_candidates
    local model_file
    local rel_path

    [[ -d "$model_root" ]] || return 1

    while IFS= read -r model_file; do
        [[ -n "$model_file" ]] || continue
        rel_path="${model_file#$model_root/}"
        model_candidates+=("$rel_path")
    done < <(command find "$model_root" -type f -iname '*.gguf' 2>/dev/null | command sort)

    (( ${#model_candidates[@]} > 0 )) || return 1

    _wanted models expl 'model' compadd -Q -a model_candidates
}

# Return the currently persisted model basename for profile completion.
_dc_current_model() {
    local state_file=".devcontainer/.llama-model.env"
    local line
    local model

    [[ -f "$state_file" ]] || return 1

    line="$(command grep '^export DEV_MODEL_FILE=' "$state_file" 2>/dev/null | tail -n 1)" || return 1
    model="${line#export DEV_MODEL_FILE=}"
    model="${model#\"}"
    model="${model%\"}"
    model="${model##*/}"

    [[ -n "$model" ]] || return 1
    printf '%s\n' "$model"
}

# Complete profile names for a given model.
_dc_profiles() {
    local model_root="${DEV_MODEL_ROOT:-$HOME/.llms/models}"
    local model="${1:-}"
    local -a profile_candidates
    local profile_file
    local profile_name
    local model_path

    [[ -z "$model" ]] && return 1
    [[ -d "$model_root" ]] || return 1

    if [[ "$model" != /* ]]; then
        model_path="$model_root/$model"
    else
        model_path="$model"
    fi

    model_path="${model_path%.gguf}"

    while IFS= read -r profile_file; do
        [[ -n "$profile_file" ]] || continue
        profile_name="${profile_file##*.profile.}"
        profile_name="${profile_name%.toml}"
        profile_candidates+=("$profile_name")
    done < <(command find "$model_root" -maxdepth 1 -type f -name "$(basename "$model_path").profile.*.toml" 2>/dev/null | command sort)

    (( ${#profile_candidates[@]} > 0 )) || return 1

    _wanted profiles expl 'profile' compadd -Q -a profile_candidates
}

_dc() {
    local -a commands
    local -a model_subcommands
    local -a yarn_subcommands
    local -a yarn_presets
    local -a turbo_subcommands
    local -a turbo_presets

    commands=(
        'up:start the workspace and ensure llama.cpp is running'
        'model:model management commands'
        'yarn:context window controls'
        'turbo:TurboQuant KV cache controls'
        'status:show current status'
        'logs:show llama.cpp logs'
        'help:show usage'
    )

    model_subcommands=(
        'list:list available models'
        'current:show the current model'
        'use:switch model'
        'profile:switch model profile'
    )

    yarn_subcommands=(
        'off:disable extended context'
        'on:enable extended context with 512k'
        'set:set extended context preset'
    )

    yarn_presets=(
        '256k:native 256k context'
        '512k:extended 512k context'
        '768k:extended 768k context'
        '1m:extended 1M context'
    )

    turbo_subcommands=(
        'off:disable TurboQuant KV'
        'on:enable TurboQuant KV quality preset'
        'set:set TurboQuant KV preset'
    )

    turbo_presets=(
        'speed:turbo3 K/V for short-context speed'
        'long:turbo2 K/V for long-context speed'
        'quality:turbo4 K/V for best quality'
        'quality-asym:turbo4 K and q8_0 V'
        'compression:turbo1.5 K/V for maximum compression'
    )

    if (( CURRENT == 2 )); then
        _describe -t commands 'dc command' commands
        return
    fi

    case "${words[2]}" in
        up)
            if (( CURRENT == 3 )); then
                _dc_models || _files -g '*.gguf'
                return
            fi
            ;;
        model)
            if (( CURRENT == 3 )); then
                _describe -t subcommands 'dc model command' model_subcommands
                return
            fi

            case "${words[3]}" in
                use)
                    if (( CURRENT == 4 )); then
                        _dc_models || _files -g '*.gguf'
                        return
                    fi

                    if (( CURRENT >= 5 )); then
                        case "${words[CURRENT-1]}" in
                            -p|--profile)
                                _dc_profiles "${words[4]}"
                                return
                                ;;
                        esac

                        compadd -Q -- -p --profile
                        return
                    fi
                    ;;
                profile)
                    if (( CURRENT == 4 )); then
                        local model
                        model="$(_dc_current_model)" || return
                        _dc_profiles "$model"
                        return
                    fi
                    ;;
            esac
            ;;
        yarn)
            if (( CURRENT == 3 )); then
                _describe -t subcommands 'dc yarn command' yarn_subcommands
                return
            fi

            if (( CURRENT == 4 )) && [[ "${words[3]}" == "set" ]]; then
                _describe -t presets 'dc yarn preset' yarn_presets
                return
            fi
            ;;
        turbo)
            if (( CURRENT == 3 )); then
                _describe -t subcommands 'dc turbo command' turbo_subcommands
                return
            fi

            if (( CURRENT == 4 )) && [[ "${words[3]}" == "set" ]]; then
                _describe -t presets 'dc turbo preset' turbo_presets
                return
            fi
            ;;
        status|logs|help)
            return
            ;;
    esac
}

compdef _dc dc
