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

log_error() {
    printf '[post-create][ERROR] %s\n' "$*" >&2
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

# Copy a file or directory into a destination path.
copy_path() {
    local src="$1"
    local dst="$2"

    mkdir -p "$(dirname "$dst")"
    rm -rf "$dst"
    cp -a "$src" "$dst"
}

require_arch() {
    if [[ ! -f /etc/arch-release ]]; then
        log_error "This script is Arch-only, but /etc/arch-release was not found."
        exit 1
    fi
}

require_non_root() {
    if [[ "${EUID}" -eq 0 ]]; then
        log_error "post-create.sh is running as root."
        log_error "Set \"remoteUser\": \"dev\" and \"containerUser\": \"dev\" in devcontainer.json."
        exit 1
    fi
}

ensure_paru() {
    if ! command -v paru >/dev/null 2>&1; then
        log_error "paru is required but not installed."
        exit 1
    fi
}

install_oh_my_zsh_if_needed() {
    if [[ -d "$HOME/.oh-my-zsh" ]]; then
        log_info "Oh My Zsh already installed, skipping."
        return 0
    fi

    if ! command -v curl >/dev/null 2>&1; then
        log_error "curl is required but not installed."
        exit 1
    fi

    log_info "Installing Oh My Zsh..."
    RUNZSH=no CHSH=no KEEP_ZSHRC=yes sh -c \
        "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" \
        --unattended --keep-zshrc || log_warn "Oh My Zsh installation failed."
}

has_drm_vendor() {
    local wanted_vendor="$1"
    local vendor_file
    local found_vendor

    shopt -s nullglob
    for vendor_file in /sys/class/drm/card*/device/vendor; do
        if [[ -f "$vendor_file" ]]; then
            found_vendor="$(tr '[:upper:]' '[:lower:]' < "$vendor_file")"
            if [[ "$found_vendor" == "$wanted_vendor" ]]; then
                shopt -u nullglob
                return 0
            fi
        fi
    done
    shopt -u nullglob

    return 1
}

# Install optional runtime packages only when matching hardware is present.
# This assumes the script is running as a non-root user and paru is available.
hardware_runtime_postcreate() {
    local device_found=0

    # Intel NPU
    if [[ -e "/dev/accel/accel0" ]]; then
        log_info "Intel NPU detected in container."
        device_found=1

        log_info "Attempting Intel NPU driver install (intel-npu-driver-bin preferred)..."
        if ! paru -S --noconfirm --needed intel-npu-driver-bin; then
            log_warn "intel-npu-driver-bin install failed, trying intel-npu-driver-git as fallback."
            paru -S --noconfirm --needed intel-npu-driver-git || log_warn "intel-npu-driver-git install failed too."
        fi

        log_info "Intel NPU driver install finished or skipped."
    fi

    # NVIDIA GPU
    if ls /dev 2>/dev/null | grep -Eq '^nvidia[0-9]+$'; then
        log_info "NVIDIA GPU detected in container."
        device_found=1

        if ! command -v nvidia-smi >/dev/null 2>&1; then
            log_info "Installing NVIDIA userspace tooling..."
            paru -S --noconfirm --needed nvidia-utils nvidia-container-toolkit-bin || \
                log_warn "Some NVIDIA packages failed to install."
        fi

        if command -v nvidia-smi >/dev/null 2>&1; then
            log_info "nvidia-smi output:"
            nvidia-smi || log_warn "Unable to run nvidia-smi, possible host/container driver mismatch."
        else
            log_warn "NVIDIA install did not succeed: nvidia-smi not found."
        fi
    fi

    # AMD GPU
    if compgen -G "/dev/dri/card*" >/dev/null && has_drm_vendor "0x1002"; then
        log_info "AMD GPU detected in container."
        device_found=1

        paru -S --noconfirm --needed opencl-mesa rocm-opencl-runtime || \
            log_warn "opencl-mesa or rocm-opencl-runtime install failed."
    fi

    if [[ "${device_found}" == 0 ]]; then
        log_info "No passthrough hardware detected on post-create.sh run."
    fi

    log_info "Hardware runtime post-create script finished."
}

main() {
    local script_dir
    local snapshot_dir
    local entry
    local name
    local target
    local ssh_file

    require_arch
    require_non_root
    ensure_paru

    script_dir="$(get_script_dir)"
    snapshot_dir="${script_dir}/local-dotfiles"

    install_oh_my_zsh_if_needed

    if [[ -d "$snapshot_dir" ]]; then
        log_info "Installing local dotfiles snapshot from ${snapshot_dir}"
        log_info "Workspace home: ${HOME}"

        # Prepare common directories expected by tools.
        install -d -m 700 "$HOME/.ssh"
        install -d -m 755 "$HOME/.config"
        install -d -m 755 "$HOME/.local/bin"
        install -d -m 755 "$HOME/.cache"

        # Copy everything else from the snapshot root into $HOME, except .config and selected local overrides.
        shopt -s dotglob nullglob
        for entry in "$snapshot_dir"/*; do
            name="$(basename "$entry")"
            [[ "$name" == ".config" ]] && continue
            [[ "$name" == ".gitconfig" ]] && continue
            [[ "$name" == ".gitconfig_local" ]] && continue
            [[ "$name" == ".zshrc" ]] && continue
            [[ "$name" == ".zsh_local" ]] && continue
            [[ "$name" == "home_files" ]] && continue

            target="$HOME/$name"
            log_info "Installing $name into home"
            copy_path "$entry" "$target"
        done
        shopt -u dotglob nullglob

        # Fix SSH permissions if any files were copied.
        if [[ -d "$HOME/.ssh" ]]; then
            chmod 700 "$HOME/.ssh" || true
            shopt -s nullglob
            for ssh_file in "$HOME/.ssh"/*; do
                if [[ -f "$ssh_file" ]]; then
                    chmod 600 "$ssh_file" || true
                fi
            done
            shopt -u nullglob
        fi

        log_info "Local dotfiles snapshot installed successfully."
    else
        log_info "No local dotfiles snapshot found at ${snapshot_dir}, skipping dotfile restore."
    fi

    # Pre-install Neovim plugins if nvim exists.
    if command -v nvim >/dev/null 2>&1; then
        log_info "Syncing Neovim plugins..."
        nvim --headless "+Lazy! sync" +qa || true
    fi

    paru -S --noconfirm --needed opencode-bin

    hardware_runtime_postcreate
}

main "$@"
