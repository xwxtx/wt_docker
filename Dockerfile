# ==========================================
# Global build arguments (change these to build other versions)
# ==========================================

# * No Support For Encryption *

# You can change to different versions
ARG MONGO_MAJOR="6.0"
ARG MONGO_VERSION="6.0.29"
ARG WT_BRANCH="mongodb-${MONGO_MAJOR}"

FROM ubuntu:22.04 AS builder
# Bring ARGs into the builder stage scope
ARG MONGO_VERSION
ARG WT_BRANCH

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y \
    git cmake gcc g++ make ninja-build \
    ca-certificates pkg-config libssl-dev \
    python3 python3-dev swig wget \
    && rm -rf /var/lib/apt/lists/*

ENV PKG_CONFIG_PATH=/usr/local/lib/pkgconfig
ENV LD_LIBRARY_PATH=/usr/local/lib

# --- zlib ---
RUN git clone --depth 1 --branch v1.3.1 https://github.com/madler/zlib.git /src/zlib && \
    cd /src/zlib && ./configure --prefix=/usr/local && \
    make -j$(nproc) && make install && rm -rf /src/zlib

# --- snappy ---
RUN git clone --depth 1 --branch 1.1.10 https://github.com/google/snappy.git /src/snappy && \
    cd /src/snappy && git submodule update --init && \
    cmake -S . -B build \
        -DSNAPPY_BUILD_TESTS=OFF \
        -DSNAPPY_BUILD_BENCHMARKS=OFF \
        -DBUILD_SHARED_LIBS=ON \
        -DCMAKE_INSTALL_PREFIX=/usr/local && \
    cmake --build build -j$(nproc) && cmake --install build && \
    rm -rf /src/snappy

# --- lz4 ---
RUN git clone --depth 1 --branch v1.9.4 https://github.com/lz4/lz4.git /src/lz4 && \
    cd /src/lz4 && make -j$(nproc) PREFIX=/usr/local install && \
    rm -rf /src/lz4

# --- zstd ---
RUN git clone --depth 1 --branch v1.5.5 https://github.com/facebook/zstd.git /src/zstd && \
    cd /src/zstd && make -j$(nproc) PREFIX=/usr/local install && \
    rm -rf /src/zstd

RUN ldconfig

# --- WiredTiger ---
RUN git clone --depth 1 --branch ${WT_BRANCH} \
    https://github.com/wiredtiger/wiredtiger.git /src/wiredtiger

RUN cmake -S /src/wiredtiger -B /src/wiredtiger/build \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX=/usr/local \
        -DCMAKE_PREFIX_PATH=/usr/local \
        -DCMAKE_C_FLAGS="-Wno-maybe-uninitialized -Wno-unused-variable" \
        -DCMAKE_CXX_FLAGS="-Wno-maybe-uninitialized -Wno-unused-variable" \
        -DENABLE_SNAPPY=1 \
        -DENABLE_ZSTD=1 \
        -DENABLE_LZ4=1 \
        -DENABLE_ZLIB=1 \
        -DENABLE_PYTHON=0 && \
    cmake --build /src/wiredtiger/build -j$(nproc) && \
    cmake --install /src/wiredtiger/build

# --- Download MongoDB Official Binary ---
RUN cd /src && wget -q https://fastdl.mongodb.org/linux/mongodb-linux-x86_64-ubuntu2204-${MONGO_VERSION}.tgz && \
    tar -zxvf mongodb-linux-x86_64-ubuntu2204-${MONGO_VERSION}.tgz && \
    cp mongodb-linux-x86_64-ubuntu2204-${MONGO_VERSION}/bin/mongod /usr/local/bin/mongod

# --- Download MongoDB Shell (mongosh) - Hardcoded Version ---
RUN cd /src && wget -q https://downloads.mongodb.com/compass/mongosh-2.3.8-linux-x64.tgz && \
    tar -zxvf mongosh-2.3.8-linux-x64.tgz && \
    cp mongosh-2.3.8-linux-x64/bin/mongosh /usr/local/bin/mongosh

# --- Final slim image ---
FROM ubuntu:22.04

# mongod/mongosh require libcurl and openssl to run
RUN apt-get update && apt-get install -y \
    ca-certificates libssl3 libcurl4 \
    && rm -rf /var/lib/apt/lists/*

# Copy tools from builder
COPY --from=builder /usr/local/bin/wt /usr/local/bin/wt-bin
COPY --from=builder /usr/local/bin/mongod /usr/local/bin/mongod
COPY --from=builder /usr/local/bin/mongosh /usr/local/bin/mongosh
COPY --from=builder /usr/local/lib /usr/local/lib

RUN ldconfig

# Create a wrapper script that automatically passes the extensions
RUN echo '#!/bin/sh' > /usr/local/bin/wt && \
    echo 'exec /usr/local/bin/wt-bin -C "extensions=[/usr/local/lib/libwiredtiger_snappy.so,/usr/local/lib/libwiredtiger_zstd.so,/usr/local/lib/libwiredtiger_zlib.so,/usr/local/lib/libwiredtiger_lz4.so]" "$@"' >> /usr/local/bin/wt && \
    chmod +x /usr/local/bin/wt

ENTRYPOINT ["sleep"]
CMD ["infinity"]