#!/bin/bash

apt update -y
apt install -y docker.io docker-compose git curl

systemctl enable docker
systemctl start docker
sudo usermod -aG docker $USER
newgrp docker

type -p curl >/dev/null || sudo apt install curl -y

curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | \
sudo dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg

sudo chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg

echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] \
https://cli.github.com/packages stable main" | \
sudo tee /etc/apt/sources.list.d/github-cli.list > /dev/null

sudo apt update

sudo apt install gh -y

# Install Tailscale
curl -fsSL https://tailscale.com/install.sh | sh

# Enable Tailscale
systemctl enable tailscaled
systemctl start tailscaled

# Authenticate Tailscale
tailscale up \
  --authkey=${tailscale_auth_key} \
  --hostname=statuspulse-server \
  --ssh

cd /opt

git clone https://github.com/vipin0102/statuspulse.git

cd statuspulse/app

gh auth token | docker login ghcr.io -u vipin0102 --password-stdin

docker compose up -d