# Build environment for the "musl" variant: Alpine, producing a fully
# static binary.
ARG BASE_IMAGE
FROM ${BASE_IMAGE}

RUN apk add --no-cache \
        autoconf \
        automake \
        bash \
        bison \
        boost-dev \
        build-base \
        cmake \
        curl \
        file \
        flex \
        libtool \
        linux-headers \
        patch \
        perl \
        pkgconf \
        python3 \
        ragel \
        tar \
        xz

ARG RUST_VERSION
ENV RUSTUP_HOME=/opt/rustup \
    CARGO_HOME=/opt/cargo \
    PATH=/opt/cargo/bin:$PATH
RUN set -eux; \
    curl -sSf https://sh.rustup.rs | sh -s -- -y --no-modify-path \
        --profile minimal --default-toolchain "$RUST_VERSION"; \
    chmod -R a+rX /opt/rustup /opt/cargo; \
    rustc --version
