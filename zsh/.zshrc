# Auto-start tmux if installed and not already in a session
if command -v tmux &>/dev/null && [ -z "$TMUX" ]; then
    if [[ -n "$CMD" ]]; then
        echo "DEBUG: CMD=$CMD" >> /tmp/cmd_debug.log
        # CMD is set: always create a new session with CMD
        session="session_$(date +%s)"
        exec tmux new-session -s "$session" "$CMD"
    else
        # No CMD: attach to detached session or create a new one
        session=$(tmux list-sessions -F "#{session_name}:#{session_attached}" 2>/dev/null | awk -F: '$2==0 {print $1; exit}')
        if [ -z "$session" ]; then
            session="session_$(date +%s)"
            exec tmux new-session -s "$session"
        else
            exec tmux attach-session -t "$session"
        fi
    fi
fi

# Path to your Oh My Zsh installation.
export ZSH="$HOME/.oh-my-zsh"
export PATH="$HOME/bin:$PATH"

ZSH_THEME="robbyrussell"

HYPHEN_INSENSITIVE="true"

zstyle ':omz:update' mode auto      # update automatically without asking

# Uncomment the following line if pasting URLs and other text is messed up.
# DISABLE_MAGIC_FUNCTIONS="true"

ENABLE_CORRECTION="true"

ZSH_CUSTOM=~/.dotfiles/zsh/custom

plugins=(git)

source $ZSH/oh-my-zsh.sh

export PATH="$PATH:$(go env GOPATH)/bin"
[ -f /opt/miniforge/etc/profile.d/conda.sh ] && source /opt/miniforge/etc/profile.d/conda.sh
