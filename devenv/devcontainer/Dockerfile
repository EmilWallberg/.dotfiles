FROM archlinux:base-devel

# Install only the minimum needed to create a non-root user and build paru.
RUN pacman -Syu --noconfirm && \
    pacman -S --noconfirm --needed \
      nodejs \
      npm \
      git \
      sudo \
      openssh \
      zsh \
      tmux \
      curl \
      ripgrep \
      fd \
      fzf \
      jq \
      less \
      unzip \
      xclip \
      bat && \
    pacman -Scc --noconfirm

# Create a non-root user for the workspace.
RUN useradd -m -s /bin/bash dev && \
    echo "dev ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers

USER dev
WORKDIR /home/dev

# Install paru.
RUN git clone https://aur.archlinux.org/paru.git /home/dev/paru && \
    cd /home/dev/paru && \
    makepkg -si --noconfirm && \
    cd /home/dev && \
    rm -rf /home/dev/paru && \
    paru -Scc --noconfirm

# Example: install only explicit AUR binary packages with paru when needed.
RUN paru -S --noconfirm --needed opencode-bin neovim-git

# Use zsh by default for the workspace user.
RUN chsh -s /usr/bin/zsh dev || true

WORKDIR /workspaces
