#!/bin/bash
# Run real application tests inside Docker (safe, isolated)
set -e
cd "$(dirname "$0")"

echo "=== Building zephwm ==="
zig build 2>&1 | head -5

echo "=== Building Docker test image ==="
sudo docker build -f Dockerfile.test -t zephwm-test . 2>&1 | tail -3

echo "=== Running tests in Docker (2GB mem limit) ==="
sudo docker run --rm --memory=2g --memory-swap=2g --cpus=2 \
    zephwm-test bash test_in_docker.sh

echo "=== Docker test complete ==="
