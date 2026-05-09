#!/bin/bash

apt update -y
apt install -y docker.io docker-compose git curl

systemctl enable docker
systemctl start docker
sudo usermod -aG docker $USER
newgrp docker

cd /opt

git clone https://github.com/vipin0102/statuspulse.git

cd statuspulse/app

docker compose up -d