#!/bin/bash

apt update -y
apt install -y docker.io docker-compose git curl

systemctl enable docker
systemctl start docker
sudo usermod -aG docker $USER
newgrp docker

cd /opt

