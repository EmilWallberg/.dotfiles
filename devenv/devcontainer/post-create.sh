#!/usr/bin/env bash
set -Eeuo pipefail

# Print a helpful error message when something fails.
trap 'echo "[post-create][ERROR] Failed at line ${LINENO}" >&2' ERR

log_info() {
    printf '[post-create][INFO] %s\n' "$*"
}

log_warn() {
    printf '[post-create][WARN] %s\n' "$*" >&2
}

# Return the directory where this script lives.
get_script_dir() {
    local src="${BASH_SOURCE[0]}"
    while [ -h "$src" ]; do
        local dir
        dir="$(cd -P "$(dirname "$src")" && pwd)"
        src="$(readlink "$src")"
        [[ "$src" != /* ]] && src="$dir/$src"
    done
    cd -P "$(dirname "$src")" && pwd
}

# Sync a directory into a destination.
# Uses rsync if available, otherwise falls back to cp.
sync_dir() {
    local src="$1"
    local dst="$2"
    shift 2
    local excludes=("$@")

    mkdir -p "$dst"

    if command -v rsync >/dev/null 2>&1; then
        local rsync_args=(-a --delete)
        local exclude
        for exclude in "${excludes[@]}"; do
            rsync_args+=(--exclude "$exclude")
        done
        rsync "${rsync_args[@]}" "$src/" "$dst/"
    else
        # Fallback mode cannot easily preserve excludes with full fidelity.
        # If excludes are requested and rsync is unavailable, warn and do a full copy.
        if [[ "${#excludes[@]}" -gt 0 ]]; then
            log_warn "rsync is not available; exclude rules are ignored in fallback copy mode"
        fi
        rm -rf "$dst"
        mkdir -p "$dst"
        cp -a "$src/." "$dst/"
    fi
}

# Copy a file or directory into a destination path.
copy_path() {
    local src="$1"
    local dst="$2"

    mkdir -p "$(dirname "$dst")"
    rm -rf "$dst"
    cp -a "$src" "$dst"
}

main() {
    local script_dir
    script_dir="$(get_script_dir)"

    local snapshot_dir="${script_dir}/local-dotfiles"

    if [[ ! -d "$snapshot_dir" ]]; then
        log_info "No local dotfiles snapshot found at ${snapshot_dir}, skipping."
        exit 0
    fi

    sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended --keep-zshrc

    log_info "Installing local dotfiles snapshot from ${snapshot_dir}"
    log_info "Workspace home: ${HOME}"

    # Prepare common directories expected by tools.
    install -d -m 700 "$HOME/.ssh"
    install -d -m 755 "$HOME/.config"
    install -d -m 755 "$HOME/.local/bin"
    install -d -m 755 "$HOME/.cache"

    # Sync the entire ~/.config tree from the snapshot.
    # Add exclude patterns here for container-local config you do not want overwritten.
    if [[ -d "$snapshot_dir/.config" ]]; then
        log_info "Syncing entire ~/.config from snapshot"

        sync_dir \
            "$snapshot_dir/.config" \
            "$HOME/.config" \
            "opencode" \
            "Code" \
            "github-copilot"
    fi

    # Copy everything else from the snapshot root into $HOME, except .config.
    local entry
    shopt -s dotglob nullglob
    for entry in "$snapshot_dir"/*; do
        [[ "$(basename "$entry")" == ".config" ]] && continue

        local target="$HOME/$(basename "$entry")"
        log_info "Installing $(basename "$entry") into home"
        copy_path "$entry" "$target"
    done
    shopt -u dotglob nullglob

    # Fix SSH permissions if any files were copied.
    if [[ -d "$HOME/.ssh" ]]; then
        chmod 700 "$HOME/.ssh" || true

        local ssh_file
        shopt -s nullglob
        for ssh_file in "$HOME/.ssh"/*; do
            if [[ -f "$ssh_file" ]]; then
                chmod 600 "$ssh_file" || true
            fi
        done
        shopt -u nullglob
    fi

    log_info "Local dotfiles snapshot installed successfully."
}

main "$@"
