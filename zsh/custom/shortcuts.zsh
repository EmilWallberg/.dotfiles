nv() {
  if [ -z "$1" ]; then
    nvim .
  else
    nvim -c "cd $1" "$1"
  fi
}

alias nvc='nv ~/.config/nvim'
