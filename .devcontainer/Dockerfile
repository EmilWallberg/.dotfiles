FROM archlinux:base-devel

# 1. Install System Base & Hardware Loaders
# Only install official repo binary packages! (No paru/AUR at build)
RUN pacman -Syu --noconfirm && \
    pacman -S --noconfirm --needed \
      git \
      sudo \
      openssh \
      zsh \
      tmux \
      curl \
      level-zero-loader \
      intel-compute-runtime \
      nodejs \
      npm \
      ripgrep \
      fd \
      fzf \
      jq \
      less \
      unzip \
      xclip \
      bat && \
    pacman -Scc --noconfirm

# 2. Create a non-root user (Required for makepkg/paru)
RUN useradd -m -s /bin/bash dev && \
    echo "dev ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers && \
    mkdir -p /home/dev/.local && chown dev:dev /home/dev/.local

USER dev
WORKDIR /home/dev

# 3. Install Paru (AUR helper, for post-create use only)
RUN git clone https://aur.archlinux.org/paru.git && \
    cd paru && \
    makepkg -si --noconfirm && \
    cd .. && \
    rm -rf paru

# 5. Finalize Environment
RUN chsh -s /usr/bin/zsh dev || true

WORKDIR /workspaces
