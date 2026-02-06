# ZFS Assistant - Makefile
# Source workflow (no AppImage pipeline in this repository state)

.PHONY: all build release install install-system clean help test lint format

all: help

# Build Python distribution artifacts (sdist/wheel)
release build:
	@echo "Building Python distribution artifacts..."
	@python3 -m build

# Install for local development
install:
	@echo "Installing in editable mode..."
	@python3 -m pip install -e .

# Install system-wide (requires sudo)
install-system:
	@echo "Installing package system-wide..."
	@sudo python3 -m pip install .

# Remove local build artifacts
clean:
	@echo "Cleaning build artifacts..."
	@rm -rf build dist *.egg-info
	@find src -type d -name '__pycache__' -exec rm -rf {} + 2>/dev/null || true

# Minimal smoke tests (no dedicated tests/ directory yet)
test:
	@echo "Running syntax smoke test..."
	@python3 -m py_compile $$(find src -name '*.py' -type f)

# Lint the code (optional tools)
lint:
	@echo "Linting code..."
	@python3 -m flake8 src || echo "flake8 not installed"
	@python3 -m pylint src || echo "pylint not installed"

# Format the code (optional tools)
format:
	@echo "Formatting code..."
	@python3 -m black src || echo "black not installed"
	@python3 -m isort src || echo "isort not installed"

help:
	@echo "ZFS Assistant - Source Build Workflow"
	@echo "====================================="
	@echo ""
	@echo "Available targets:"
	@echo "  install         Install editable package for development"
	@echo "  install-system  Install package system-wide"
	@echo "  release         Build wheel/sdist (python -m build)"
	@echo "  test            Run python syntax smoke tests"
	@echo "  lint            Run linting (if tools are installed)"
	@echo "  format          Run formatting (if tools are installed)"
	@echo "  clean           Remove build artifacts"
