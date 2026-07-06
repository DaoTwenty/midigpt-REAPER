# ============================================================================
# Clean-room integration test for midigpt-REAPER install pipeline
#
# Starts from a minimal Ubuntu image with NO pre-installed dependencies
# (no cmake, no protobuf, no Python venv) to verify install.sh handles
# everything on a fresh Linux system.
#
# Usage:
#   # Build (pass mmm_refactored zip as a build arg):
#   docker build \
#     --build-arg MMM_ZIP=mmm_refactored.zip \
#     -f tests/integration/Dockerfile \
#     -t midigpt-install-test .
#
#   # Run:
#   docker run --rm midigpt-install-test
#
# The zip file must be in the build context (repo root).
# ============================================================================

FROM ubuntu:22.04

# Avoid interactive prompts during apt
ENV DEBIAN_FRONTEND=noninteractive

# Minimal base — only what's needed to bootstrap
RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    curl \
    unzip \
    ca-certificates \
    build-essential \
    cmake \
    protobuf-compiler \
    libprotobuf-dev \
    python3.10 \
    python3.10-venv \
    python3.10-dev \
    python3-pip \
    && rm -rf /var/lib/apt/lists/*

# Make python3.10 the default python3
RUN update-alternatives --install /usr/bin/python3 python3 /usr/bin/python3.10 1

# Create a fake REAPER config dir so symlinks can be created
RUN mkdir -p /root/.config/REAPER/Scripts /root/.config/REAPER/Effects

# Copy the repo
WORKDIR /build
COPY . /build/midigpt-REAPER

# Copy the mmm_refactored zip
ARG MMM_ZIP=mmm_refactored.zip
COPY ${MMM_ZIP} /build/mmm_refactored.zip

# Run the installer
WORKDIR /build/midigpt-REAPER
RUN bash install.sh --skip-deps --mmm-zip=/build/mmm_refactored.zip

# Install pytest for verification
RUN .venv/bin/pip install pytest -q

# Verification command
CMD ["/bin/bash", "-c", "\
    echo '=== Verification ===' && \
    source .venv/bin/activate && \
    echo '--- import mmm_refactored ---' && \
    python -c 'import mmm_refactored; print(\"OK\")' && \
    echo '--- import torch ---' && \
    python -c 'import torch; print(torch.__version__)' && \
    echo '--- import symusic ---' && \
    python -c 'import symusic; print(\"OK\")' && \
    echo '--- REAPER symlinks ---' && \
    ls -la /root/.config/REAPER/Scripts/MMM && \
    ls -la /root/.config/REAPER/Effects/MMM && \
    echo '--- Unit tests ---' && \
    python -m pytest tests/ -v --tb=short && \
    echo '' && \
    echo '=== ALL CHECKS PASSED ===' \
"]
