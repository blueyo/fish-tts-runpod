# ───── Stage 1: Build fish-speech.rs with CUDA ─────
# Use an official NVIDIA CUDA image that includes the toolkit and dev libraries for Ubuntu 22.04
# Using the -devel variant to include CUDA development tools needed for compilation
FROM nvidia/cuda:12.1.1-devel-ubuntu22.04 AS builder

# Install build dependencies and Rust via rustup
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    build-essential \
    pkg-config \
    libssl-dev \
    libsndfile1-dev \
    git \
    && \
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain 1.78 && \
    # Do NOT source env here; rely on ENV PATH below for subsequent steps
    rm -rf /var/lib/apt/lists/*

# Set ENV vars for subsequent steps. ENV ensures PATH is set correctly for new shell sessions (like subsequent RUN commands).
# Add Rust and CUDA bin directories to PATH
ENV PATH="/root/.cargo/bin:/usr/local/cuda/bin:${PATH}"
# Explicitly set CUDA lib path for dynamic linker
ENV LD_LIBRARY_PATH=/usr/local/cuda/lib64:${LD_LIBRARY_PATH}
# Explicitly set CUDA installation root for build scripts
ENV CUDA_HOME=/usr/local/cuda

# Verify CUDA and Rust installation (optional)
RUN nvidia-smi
RUN rustc --version
RUN cargo --version

WORKDIR /workspace

# Copy manifests first (allows caching if only manifests change)
COPY Cargo.toml Cargo.lock ./

# Copy the entire source code next, so cargo commands can see the full workspace
COPY . .

# Fetch dependencies (now aware of the full workspace structure)
RUN cargo fetch

# Build the server binary with CUDA support
# The CUDA toolkit should be available via ENV PATH set above.
RUN cargo build --release --features cuda --bin server

# ───── Stage 2: Slim Runtime ─────
FROM ubuntu:22.04
# Install runtime dependencies (libsndfile for audio handling)
# Note: CUDA runtime libraries are expected to be provided by the host environment (RunPod)
# via the NVIDIA Container Toolkit, so we don't install them here.
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    libsndfile1 \
    ca-certificates \
    curl \
    && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app
# Copy the compiled binary from the builder stage
COPY --from=builder /workspace/target/release/server /usr/local/bin/fish-speech
# Copy your voice directories from voices-template/ into /app/voices/ inside the container
COPY voices-template/ ./voices/

# Expose the port the server will listen on
EXPOSE 8000
# Define the command to run when the container starts
CMD ["fish-speech", "--port", "8000", "--voice-dir", "/app/voices"]

# Add a healthcheck to verify the server is running
HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
  CMD curl -f http://localhost:8000/health || exit 1
