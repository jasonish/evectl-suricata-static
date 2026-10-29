# Build environment for the "gnu" variant: manylinux_2_28 (AlmaLinux 8,
# glibc 2.28) with gcc-toolset, plus the tools needed to build the static
# dependencies and Suricata.
ARG BASE_IMAGE
FROM ${BASE_IMAGE}

RUN dnf -y --enablerepo=powertools install \
        boost-devel \
        bison \
        file \
        flex \
        patch \
        which \
        xz \
    && dnf clean all

# Ragel 6 for Vectorscan (EPEL only has the incompatible Ragel 7).
ARG RAGEL_URL
ARG RAGEL_SHA256
RUN set -eux; \
    curl -sSfL -o /tmp/ragel.tar.gz "$RAGEL_URL"; \
    echo "$RAGEL_SHA256  /tmp/ragel.tar.gz" | sha256sum -c -; \
    mkdir /tmp/ragel; \
    tar xzf /tmp/ragel.tar.gz -C /tmp/ragel --strip-components=1; \
    cd /tmp/ragel; \
    ./configure --prefix=/usr/local --disable-manual CXXFLAGS="-O2 -std=gnu++98"; \
    make -j"$(nproc)"; \
    make install; \
    cd /; \
    rm -rf /tmp/ragel /tmp/ragel.tar.gz; \
    ragel --version

ARG RUST_VERSION
ENV RUSTUP_HOME=/opt/rustup \
    CARGO_HOME=/opt/cargo \
    PATH=/opt/cargo/bin:$PATH
RUN set -eux; \
    curl -sSf https://sh.rustup.rs | sh -s -- -y --no-modify-path \
        --profile minimal --default-toolchain "$RUST_VERSION"; \
    chmod -R a+rX /opt/rustup /opt/cargo; \
    rustc --version
