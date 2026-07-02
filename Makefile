.PHONY: help install dev-install test test-cov lint format clean build \
        configure build-ext install-ext dev-ext watch ci

# Default target
help:
	@echo "Available targets:"
	@echo "  install      Install hvloop"
	@echo "  dev-install  Install with development dependencies"
	@echo "  test         Run tests"
	@echo "  test-cov     Run tests with coverage"
	@echo "  lint         Run linting"
	@echo "  format       Format code"
	@echo "  clean        Clean build artifacts"
	@echo "  build        Build package"
	@echo "  configure    Configure CMake build (for incremental dev builds)"
	@echo "  build-ext    Build Cython extension via CMake (target: _core)"
	@echo "  install-ext  Install built extension into src/ for import"
	@echo "  dev-ext      Configure+Build+Install extension for local dev"
	@echo "  watch        Auto-rebuild on .pyx/.pxd/.pxi changes (needs entr)"

# Incremental CMake build settings (developer friendly)
CMAKE ?= cmake
BUILD_DIR ?= build
# Debug for faster builds; change to Release for perf validation
BUILD_TYPE ?= Debug

# Required by CMakeLists.txt which expects scikit-build variables
SKBUILD_PROJECT_NAME ?= hvloop
SKBUILD_PROJECT_VERSION ?= 0.2.0

# Install prefix so that LIBRARY DESTINATION hvloop installs to src/hvloop/
DEV_PREFIX ?= $(PWD)/src

# Install hvloop
install:
	uv pip install -e .

# Install with development dependencies
dev-install:
	uv pip install -e .[dev]
	pre-commit install

# Run tests
test:
	uv run pytest tests/ -v

# Run tests with coverage
test-cov:
	uv run pytest tests/ --cov=hvloop --cov-report=html --cov-report=term

# Run linting
lint:
	uv run ruff check .
	uv run mypy src/hvloop

# Format code
format:
	uv run black .
	uv run ruff check --fix .

# Clean build artifacts
clean:
	rm -rf build/
	rm -rf dist/
	rm -rf *.egg-info/
	rm -rf .pytest_cache/
	rm -rf htmlcov/
	find . -type d -name __pycache__ -exec rm -rf {} +
	find . -type f -name "*.pyc" -delete

# Build package
build: clean
	python -m build

# Configure CMake (run once, or when CMake cache is missing)
configure:
	$(CMAKE) -S . -B $(BUILD_DIR) \
		-DCMAKE_BUILD_TYPE=$(BUILD_TYPE) \
		-DSKBUILD_PROJECT_NAME=$(SKBUILD_PROJECT_NAME) \
		-DSKBUILD_PROJECT_VERSION=$(SKBUILD_PROJECT_VERSION)

# Build only the Cython extension target (_core)
build-ext:
	@if [ ! -f "$(BUILD_DIR)/CMakeCache.txt" ]; then \
		$(MAKE) configure; \
	fi
	$(CMAKE) --build $(BUILD_DIR) --config $(BUILD_TYPE) --target _core -j

# Install the built extension into src/hvloop/ for immediate import
install-ext:
	$(CMAKE) --install $(BUILD_DIR) --config $(BUILD_TYPE) \
		--component python_modules --prefix $(DEV_PREFIX)

# One-shot developer command: configure + build + install
dev-ext:
	@if [ ! -f "$(BUILD_DIR)/CMakeCache.txt" ]; then \
		$(MAKE) configure; \
	fi
	$(MAKE) build-ext
	$(MAKE) install-ext

# Auto-rebuild on Cython include changes (requires: brew install entr)
watch:
	@command -v entr >/dev/null 2>&1 || { echo "entr not found. Install via 'brew install entr'"; exit 1; }
	find src/hvloop -type f \( -name "*.pyx" -o -name "*.pxd" -o -name "*.pxi" \) | \
		dirname -z - | sort -zu | xargs -0 -I {} find {} -type f \( -name "*.pyx" -o -name "*.pxd" -o -name "*.pxi" \) | \
		entr -c sh -c '$(MAKE) dev-ext'

# Build and test in CI
ci: dev-install test lint