#!/bin/bash

set -e

echo "================================================"
echo "Arch Linux Desktop Container Builder"
echo "================================================"
echo ""

# Check if Docker is installed
if ! command -v docker &> /dev/null; then
    echo "Error: Docker is not installed. Please install Docker first."
    exit 1
fi

# Check if Dockerfile exists
if [ ! -f "Dockerfile" ]; then
    echo "Error: Dockerfile not found in current directory."
    echo "Please ensure you're in the directory containing the Dockerfile."
    exit 1
fi

echo "Building Arch Linux container with:"
echo "  - Cinnamon Desktop Environment"
echo "  - noVNC web interface"
echo ""

# Clean up any existing container
echo "Cleaning up any existing containers..."
docker rm -f arch-container 2>/dev/null || true

echo "Building with Docker..."
docker build -t arch-vnc .

echo ""
echo "Starting container..."

docker run -d \
  --name arch-container \
  --hostname archlab \
  -p 6080:6080 \
  -v arch-home:/home/archuser \
  --shm-size=512m \
  arch-vnc

echo ""
echo "================================================"
echo "Container started successfully!"
echo "================================================"
echo ""
echo "Waiting for services to initialize..."

# Wait and check logs
sleep 5
echo ""
echo "Service status:"
docker exec arch-container supervisorctl status || echo "Note: Services still starting up..."

echo ""
echo "================================================"
echo "Access Instructions"
echo "================================================"
echo ""
echo "Web Interface:"
echo "  → Open browser: http://localhost:6080"
echo ""
echo "Shell Access:"
echo "  → docker exec -it -u archuser arch-container bash"
echo ""
echo "View Logs:"
echo "  → docker logs -f arch-container"
echo ""
echo "Check Status:"
echo "  → docker exec arch-container supervisorctl status"
echo ""
echo "Stop Container:"
echo "  → docker stop arch-container"
echo ""
echo "Remove Container:"
echo "  → docker rm arch-container"
echo ""
echo "================================================"
echo "Troubleshooting"
echo "================================================"
echo ""
echo "If you see a black screen:"
echo "  1. Wait 30-60 seconds for services to fully start"
echo "  2. Refresh the browser page"
echo "  3. Check logs: docker logs arch-container"
echo ""
echo "If services fail to start:"
echo "  → docker exec arch-container supervisorctl restart all"
echo ""
echo "Default credentials:"
echo "  Username: archuser"
echo "  Password: archuser"
echo ""
echo "💡 Tip: The desktop needs time to initialize."
echo "    Give it a few seconds on first start."
echo ""
echo "Happy hacking! 🚀"
