#!/usr/bin/env bash

DOTFILES_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)

echo "🚀 Updating Dotfiles..."

# 1. Use Stow for the standard .config structures
# This handles: ~/.config/nvim, ~/.config/tmux, etc.
packages=(hypr nvim tmux wezterm)

for pkg in "${packages[@]}"; do
    if [ -d "$DOTFILES_DIR/$pkg" ]; then
        echo "📦 Stowing $pkg..."
        stow -v -R -t "$HOME" "$pkg"
    fi
done

# 2. Manual Symlinks (The "Non-Stow" files)

echo "🔗 Linking .zshrc..."
ln -sf "$DOTFILES_DIR/zsh/.zshrc" "$HOME/.zshrc"

echo "🔗 Linking .gitconfig..."
ln -sf "$DOTFILES_DIR/.gitconfig" "$HOME/.gitconfig"

echo "✨ Done! Restart your shell or run 'source ~/.zshrc'"
