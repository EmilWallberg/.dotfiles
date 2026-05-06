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
    
    # Disabled: configs mounted live by devcontainer.json.template, no snapshot sync to ~/.config for opencode, nvim, zsh, tmux
    # if [[ -d "$snapshot_dir/.config" ]]; then
    #     log_info "Syncing entire ~/.config from snapshot"
    #     sync_dir \
    #         "$snapshot_dir/.config" \
    #         "$HOME/.config" \
    #         "opencode" \
    #         "Code" \
    #         "github-copilot"
    # fi
    paru -S --noconfirm --needed opencode-bin neovim-bin
    
    # Pre-install Neovim plugins if nvim was copied
    if command -v nvim >/dev/null 2>&1; then
        log_info "Syncing Neovim plugins..."
        nvim --headless "+Lazy! sync" +qa || true
    fi

    # Copy everything else from the snapshot root into $HOME, except .config.
    local entry
    shopt -s dotglob nullglob
    for entry in "$snapshot_dir"/*; do
        name="$(basename "$entry")"
        [[ "$name" == ".config" ]] && continue
        [[ "$name" == ".gitconfig" ]] && continue
        [[ "$name" == ".gitconfig_local" ]] && continue
        [[ "$name" == ".zshrc" ]] && continue
        [[ "$name" == ".zsh_local" ]] && continue
        [[ "$name" == "home_files" ]] && continue

        local target="$HOME/$name"
        log_info "Installing $name into home"
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
hs

# --- Hardware runtime install logic below ---
apt_update_if_needed() {
    if [[ ! -f /var/lib/apt/periodic/update-success-stamp ]] || \
       find /var/lib/apt/lists -type f | grep -q . || \
       ! apt-cache policy | grep -q "Installed:" ; then
        log_info "Running apt-get update ..."
        apt-get update
    fi
}

hardware_runtime_postcreate() {
    device_found=0
    # Intel NPU
    if [[ -e "/dev/accel/accel0" ]]; then
        log_info "Intel NPU detected in container."
        device_found=1
        if [[ -f "/etc/arch-release" ]]; then
            log_info "Arch Linux detected: attempting NPU driver install (paru, intel-npu-driver-bin preferred)"
            if command -v paru >/dev/null 2>&1; then
                if sudo -n true 2>/dev/null; then
                    if ! sudo paru -S --noconfirm --needed intel-npu-driver-bin; then
                        log_warn "intel-npu-driver-bin install failed, trying intel-npu-driver-git as fallback."
                        sudo paru -S --noconfirm --needed intel-npu-driver-git || log_warn "intel-npu-driver-git install failed too."
                    fi
                else
                    if ! paru -S --noconfirm --needed intel-npu-driver-bin; then
                        log_warn "intel-npu-driver-bin install failed, trying intel-npu-driver-git as fallback."
                        paru -S --noconfirm --needed intel-npu-driver-git || log_warn "intel-npu-driver-git install failed too."
                    fi
                fi
                log_info "intel-npu-driver Arch install (bin preferred) finished or skipped."
            else
                log_warn "paru not available, cannot install intel-npu-driver packages."
            fi
        elif [[ -f "/etc/debian_version" || -f "/etc/lsb-release" || -f "/etc/apt/sources.list" ]]; then
            if ! command -v benchmark_app &>/dev/null; then
                apt_update_if_needed
                apt-get install -y wget tar
                log_info "Downloading and installing OpenVINO toolkit..."
                wget -qO- https://github.com/openvinotoolkit/openvino/releases/download/2024.0.0/l_openvino_toolkit_runtime_ubuntu20_2024.0.0.30457.191.tar.gz | tar xz -C /opt || true
                log_info "OpenVINO toolkit installed (light). For full features, install manually."
            fi
        else
            log_warn "Unknown Linux distribution: Intel NPU present but no known runtime install strategy."
        fi
    fi
    # NVIDIA GPU
    if ls /dev | grep -Eq '^nvidia[0-9]+$'; then
        log_info "NVIDIA GPU detected in container."
        device_found=1
        if [[ -f "/etc/arch-release" ]]; then
            if ! command -v nvidia-smi &>/dev/null; then
                log_info "Trying nvidia (Arch repo) + nvidia-container-toolkit-bin (AUR)"
                if command -v paru >/dev/null 2>&1; then
                    if sudo -n true 2>/dev/null; then
                        sudo paru -S --noconfirm --needed nvidia nvidia-utils nvidia-container-toolkit-bin || log_warn "Some NVIDIA packages failed to install. (Arch, bin preferred)"
                    else
                        paru -S --noconfirm --needed nvidia nvidia-utils nvidia-container-toolkit-bin || log_warn "Some NVIDIA packages failed to install. (Arch, bin preferred)"
                    fi
                else
                    log_warn "paru not available for NVIDIA install on Arch."
                fi
            fi
            if command -v nvidia-smi &>/dev/null; then
                log_info "nvidia-smi output:"
                nvidia-smi || log_warn "Unable to run nvidia-smi, possible driver mismatch."
            else
                log_warn "NVIDIA install did not succeed: nvidia-smi not found."
            fi
        elif [[ -f "/etc/debian_version" || -f "/etc/lsb-release" || -f "/etc/apt/sources.list" ]]; then
            if ! command -v nvidia-smi &>/dev/null; then
                apt_update_if_needed
                if ! grep -q nvidia /etc/apt/sources.list /etc/apt/sources.list.d/* 2>/dev/null; then
                    distribution=$(. /etc/os-release;echo $ID$VERSION_ID)
                    curl -s -L https://nvidia.github.io/libnvidia-container/gpgkey | apt-key add -
                    curl -s -L https://nvidia.github.io/libnvidia-container/${distribution}/libnvidia-container.list | \
                        tee /etc/apt/sources.list.d/libnvidia-container.list
                    apt-get update
                fi
                apt-get install -y nvidia-container-toolkit nvidia-cuda-toolkit
                log_info "NVIDIA runtime/toolkit installed"
            fi
            if command -v nvidia-smi &>/dev/null; then
                log_info "nvidia-smi output:"
                nvidia-smi || log_warn "Unable to run nvidia-smi, possible driver mismatch."
            else
                log_warn "NVIDIA install did not succeed: nvidia-smi not found."
            fi
        fi
    fi
    # AMD GPU
    if compgen -G "/dev/dri/card*" >/dev/null; then
        log_info "AMD GPU detected in container."
        device_found=1
        if [[ -f "/etc/arch-release" ]]; then
            if command -v paru >/dev/null 2>&1; then
                if sudo -n true 2>/dev/null; then
                    sudo paru -S --noconfirm --needed opencl-mesa rocm-opencl-runtime || log_warn "opencl-mesa or rocm-opencl-runtime install failed (Arch)."
                else
                    paru -S --noconfirm --needed opencl-mesa rocm-opencl-runtime || log_warn "opencl-mesa or rocm-opencl-runtime install failed (Arch)."
                fi
            else
                log_warn "paru not available, cannot install AMD OpenCL runtimes."
            fi
        elif [[ -f "/etc/debian_version" || -f "/etc/lsb-release" || -f "/etc/apt/sources.list" ]]; then
            if ! dpkg -l | grep -qw rocm-opencl-runtime; then
                apt_update_if_needed
                apt-get install -y mesa-opencl-icd ocl-icd-libopencl1 libdrm-amdgpu1 || true
                if grep -q 'repo.radeon.com/rocm' /etc/apt/sources.list /etc/apt/sources.list.d/* 2>/dev/null; then
                    apt-get install -y rocm-opencl-runtime || true
                    log_info "ROCm OpenCL runtime installed"
                else
                    log_warn "ROCm repo missing; skipping rocm-opencl-runtime. See AMD docs for full ROCm install."
                fi
            fi
        fi
    fi
    if [[ "${device_found}" == 0 ]]; then
        log_info "No passthrough hardware detected on post-create.sh run."
    fi
    log_info "Hardware runtime post-create script finished."
}

main "$@"

hardware_runtime_postcreate

