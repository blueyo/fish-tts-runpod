# syntax=docker/dockerfile:1

########################
# 1️⃣  Builder stage
########################
FROM nvidia/cuda:11.8.0-cudnn8-devel-ubuntu22.04 AS builder

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        build-essential clang cmake git curl pkg-config \
        libssl-dev libsndfile1-dev ca-certificates && \
    rm -rf /var/lib/apt/lists/*

RUN curl -sSf https://sh.rustup.rs | bash -s -- -y --profile minimal
ENV PATH="/root/.cargo/bin:${PATH}"
ENV CANDLE_FLASH_ATTN_BUILD_DIR=/tmp/candle-kernels

WORKDIR /workspace

# 🚫  —— remove the 'smart' fetch layer that broke the build —— 🚫
# COPY Cargo.toml Cargo.lock ./
# RUN cargo fetch

# ✅  —— just copy everything and build —— ✅
COPY . .

RUN cargo build --release --features cuda,flash-attn --bin server

########################
# 2️⃣  Runtime stage
########################
FROM nvidia/cuda:11.8.0-cudnn8-runtime-ubuntu22.04

# Only the tiny libs we need at runtime
RUN apt-get update && apt-get install -y --no-install-recommends \
        libsndfile1 libssl3 curl && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app

# ---- Bring in the binary ----
COPY --from=builder /workspace/target/release/server /usr/local/bin/fish-speech

# ---- (optional) pre-bundle voices ----
COPY voices-template/ ./voices

EXPOSE 8000
HEALTHCHECK --interval=30s --timeout=10s --retries=3 \
  CMD curl -f http://localhost:8000/health || exit 1

CMD ["fish-speech","--port","8000","--voice-dir","/app/voices"]