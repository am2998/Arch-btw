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
echo "  - Ghostty terminal emulator"
echo "  - noVNC web interface"
echo ""
echo "⚠️  Note: This build will take 10-20 minutes depending on your system."
echo ""

# Clean up any existing container
echo "Cleaning up any existing containers..."
docker rm -f arch 2>/dev/null || true

echo "Building with Docker..."
docker build -t arch .

echo ""
echo "Starting container..."

# Try with GPU access first, fall back if it fails
if docker run -d \
  --name arch\
  -p 6080:6080 \
  --device /dev/dri:/dev/dri \
  -v arch-home:/home/archuser \
  --shm-size=512m \
  arch 2>/dev/null; then
    echo "Container started with GPU acceleration"
else
    echo "GPU not available, starting with software rendering..."
    docker run -d \
      --name archtest\
      -p 6080:6080 \
      -v arch-home:/home/archuser \
      --shm-size=512m \
      arch
fi

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
docker exec archsupervisorctl status || echo "Note: Services still starting up..."

echo ""
echo "================================================"
echo "Access Instructions"
echo "================================================"
echo ""
echo "Web Interface:"
echo "  → Open browser: http://localhost:6080"
echo ""
echo "Shell Access:"
echo "  → docker exec -it -u archuser archbash"
echo ""
echo "View Logs:"
echo "  → docker logs -f arch-term"
echo "  → docker exec archtail -f /var/log/supervisor/wayland.err.log"
echo "  → docker exec archtail -f /var/log/supervisor/novnc.err.log"
echo ""
echo "Check Status:"
echo "  → docker exec archsupervisorctl status"
echo ""
echo "Stop Container:"
echo "  → docker stop arch-term"
echo ""
echo "Remove Container:"
echo "  → docker rm arch-term"
echo ""
echo "================================================"
echo "Troubleshooting"
echo "================================================"
echo ""
echo "If you see a black screen:"
echo "  1. Wait 30-60 seconds for services to fully start"
echo "  2. Refresh the browser page"
echo "  3. Check logs: docker logs arch-term"
echo ""
echo "If services fail to start:"
echo "  → docker exec archsupervisorctl restart all"
echo ""
echo "Default credentials:"
echo "  Username: archuser"
echo "  Password: archuser"
echo ""
echo "💡 Tip: The X server needs time to initialize."
echo "    Give it 1-2 minutes on first start."
echo ""
echo "Happy hacking! 🚀"
