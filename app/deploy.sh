#!/bin/bash

set -e

make build
make up

echo "Waiting for application to become healthy..."

until curl -s http://localhost:8000/health > /dev/null; do
    sleep 2
done

docker compose ps

curl localhost:8000/health

make test