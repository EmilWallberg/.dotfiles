#!/usr/bin/env bash

DOTFILES_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
BLACKLIST=(".git" "LICENSE" "install.sh" "home_files" "home_dirs")

is_blacklisted() {
    local item="$1"
    for bl in "${BLACKLIST[@]}"; do
        [[ "$item" == "$bl" ]] && return 0
    done
    return 1
}

# Function to handle safe symlinking
confirm_and_link() {
    local src="$1"
    local dst="$2"

    if [ -d "$dst" ] && [ ! -L "$dst" ]; then
        echo "⚠️  Found existing directory at $dst"
        read -p "   Overwrite with symlink? [y/N] " confirm
        if [[ "$confirm" != [yY] ]]; then
            echo "   ⏭️  Skipping $dst"
            return
        fi
    fi

    mkdir -p "$(dirname "$dst")"
    rm -rf "$dst"
    ln -sf "$src" "$dst"
}

echo "🧹 Checking dependencies..."
if [ ! -d "$HOME/.oh-my-zsh" ]; then
    echo "🛠️ Oh My Zsh not found. Installing..."
    sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended --keep-zshrc
else
    echo "✅ Oh My Zsh is already installed."
fi

echo "🚀 Auto-deploying Dotfiles..."

# 1. Auto-Link folders to ~/.config/
for dir in "$DOTFILES_DIR"/*; do
    name=$(basename "$dir")
    if [ -d "$dir" ] && ! is_blacklisted "$name"; then
        echo "📦 Processing: $name"
        confirm_and_link "$dir" "$HOME/.config/$name"
    fi
done

# 2. Link files from home_files/ to ~/
if [ -d "$DOTFILES_DIR/home_files" ]; then
    echo "🏠 Linking home files..."
    find "$DOTFILES_DIR/home_files" -maxdepth 1 -type f | while read -r file; do
        filename=$(basename "$file")
        # For individual files, we usually just force link, 
        # but let's be safe here too.
        if [ -f "$HOME/$filename" ] && [ ! -L "$HOME/$filename" ]; then
             echo "🔗 Linking $filename to ~/"
             ln -sf -b "$file" "$HOME/$filename" # -b creates a backup (e.g. .zshrc~)
        else
             ln -sf "$file" "$HOME/$filename"
        fi
    done
fi

# 3. Link dirs from home_dirs/ to ~/
if [ -d "$DOTFILES_DIR/home_dirs" ]; then
    echo "🏠 Linking home directories..."
    for dir in "$DOTFILES_DIR/home_dirs"/*/; do
        name=$(basename "$dir")
        dst="$HOME/$name"
        if [ -d "$dst" ] && [ ! -L "$dst" ]; then
            echo "⚠️  Found existing directory at $dst"
            read -p "   Overwrite with symlink? [y/N] " confirm
            if [[ "$confirm" != [yY] ]]; then
                echo "   ⏭️  Skipping $dst"
                continue
            fi
        fi
        echo "🔗 Linking $name to ~/"
        rm -rf "$dst"
        ln -sf "$dir" "$dst"
    done
fi

# 4. THE MAGIC: Auto-Chmod all scripts
echo "🔧 Making scripts executable..."
find "$DOTFILES_DIR" -type f -name "*.sh" -exec chmod +x {} +

echo "✨ Done!"
