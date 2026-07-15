#!/usr/bin/env bash
set -euo pipefail

WORKSPACE_DIR="/workspace"
VENV_DIR="$WORKSPACE_DIR/.venv"

sudo chown -R rosuser:rosuser "$WORKSPACE_DIR"
sudo apt-get update
sudo apt-get install -y python3-pip python3-venv

rm -rf "$VENV_DIR"
python3 -m venv "$VENV_DIR"

"$VENV_DIR/bin/pip" install --upgrade pip
"$VENV_DIR/bin/pip" install rosbags

cat >> "$HOME/.bashrc" <<'EOF'

# Workspace Python virtual environment
if [ -d "$WORKSPACE_DIR/.venv" ]; then
  source "$WORKSPACE_DIR/.venv/bin/activate"
fi
EOF
