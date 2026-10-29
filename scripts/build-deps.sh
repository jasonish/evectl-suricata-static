#!/usr/bin/env bash
# Build the static libraries Suricata links against into $DEPS_PREFIX.
# Runs inside the build container.
#
# Each library is cached: it is rebuilt only when its pinned version or
# build function changes. The libraries do not link against each other.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=lib.sh
source "$ROOT/scripts/lib.sh"

P=$DEPS_PREFIX
build="$WORK/deps-build"
mkdir -p "$P" "$build"

export CFLAGS="-O2 -fPIC -fstack-protector-strong"
export CXXFLAGS="$CFLAGS"
export CPPFLAGS="-I$P/include"
export LDFLAGS="-L$P/lib"
export PKG_CONFIG_PATH="$P/lib/pkgconfig"
static_args=(--prefix="$P" --libdir="$P/lib" --disable-shared --enable-static)

build_zlib() {
    extract "$(fetch ZLIB "zlib-$ZLIB_VERSION.tar.gz")" "$build/zlib"
    cd "$build/zlib"
    ./configure --static --prefix="$P" --libdir="$P/lib"
    make -j"$JOBS"
    make install
}

build_lz4() {
    extract "$(fetch LZ4 "lz4-$LZ4_VERSION.tar.gz")" "$build/lz4"
    cd "$build/lz4"
    make -C lib -j"$JOBS" liblz4.a liblz4.pc PREFIX="$P" LIBDIR="$P/lib"
    make -C lib install PREFIX="$P" LIBDIR="$P/lib" BUILD_SHARED=no
}

build_pcre2() {
    extract "$(fetch PCRE2 "pcre2-$PCRE2_VERSION.tar.gz")" "$build/pcre2"
    cd "$build/pcre2"
    ./configure "${static_args[@]}" --enable-jit --disable-pcre2grep-libz \
        --disable-pcre2grep-libbz2 --disable-pcre2test-libreadline
    make -j"$JOBS"
    make install
}

build_jansson() {
    extract "$(fetch JANSSON "jansson-$JANSSON_VERSION.tar.gz")" "$build/jansson"
    cd "$build/jansson"
    ./configure "${static_args[@]}"
    make -j"$JOBS"
    make install
}

build_libyaml() {
    extract "$(fetch LIBYAML "yaml-$LIBYAML_VERSION.tar.gz")" "$build/libyaml"
    cd "$build/libyaml"
    ./configure "${static_args[@]}"
    make -j"$JOBS"
    make install
}

# Plain Linux packet capture only: no D-Bus, RDMA, Bluetooth, netlink or
# USB backends, which would drag in more shared libraries.
build_libpcap() {
    extract "$(fetch LIBPCAP "libpcap-$LIBPCAP_VERSION.tar.xz")" "$build/libpcap"
    cd "$build/libpcap"
    ./configure "${static_args[@]}" --enable-ipv6 --disable-dbus \
        --disable-rdma --disable-bluetooth --disable-usb --disable-netmap \
        --without-libnl --without-dpdk --without-dag --without-septel \
        --without-snf --without-turbocap
    make -j"$JOBS"
    make install
    # libpcap advertises an rpath to its (build-time) libdir, which would
    # end up in the suricata binary.
    sed -i 's/ -Wl,-rpath,[^ ]*//' "$P/lib/pkgconfig/libpcap.pc" "$P/bin/pcap-config"
    ! grep -q rpath "$P/lib/pkgconfig/libpcap.pc" "$P/bin/pcap-config" \
        || die "failed to remove rpath from libpcap's build flags"
}

# The compiled-in default database path points at the conventional system
# location instead of this build prefix. The package ships its own
# magic.mgc matching this libmagic version.
build_file() {
    extract "$(fetch FILE "file-$FILE_VERSION.tar.gz")" "$build/file"
    cd "$build/file"
    ./configure "${static_args[@]}" --disable-zlib --disable-bzlib \
        --disable-xzlib --disable-zstdlib --disable-lzlib --disable-libseccomp
    make -j"$JOBS" -C src MAGIC=/usr/share/misc/magic
    make -j"$JOBS"
    make install
}

build_libcap_ng() {
    extract "$(fetch LIBCAP_NG "libcap-ng-$LIBCAP_NG_VERSION.tar.gz")" "$build/libcap-ng"
    cd "$build/libcap-ng"
    ./autogen.sh
    ./configure "${static_args[@]}" --without-python --without-python3 \
        --disable-cap-audit
    make -j"$JOBS"
    make install
}

build_libmaxminddb() {
    extract "$(fetch LIBMAXMINDDB "libmaxminddb-$LIBMAXMINDDB_VERSION.tar.gz")" "$build/libmaxminddb"
    cd "$build/libmaxminddb"
    ./configure "${static_args[@]}" --disable-tests --disable-binaries
    make -j"$JOBS"
    make install
}

build_libnet() {
    extract "$(fetch LIBNET "libnet-$LIBNET_VERSION.tar.gz")" "$build/libnet"
    cd "$build/libnet"
    # glibc-only type; fixed upstream in 1.3, which Suricata 8.0 rejects.
    sed -i 's/__int64_t/int64_t/' include/libnet/libnet-structures.h
    ./configure "${static_args[@]}" --disable-doxygen-doc
    make -j"$JOBS"
    make install
}

# gnu: fat runtime, dispatching at load time (via glibc ifunc) to the best
# implementation for the running CPU. The SIMDe fallback for x86 CPUs
# without SSE4.2 is left out (its sources are a git submodule that is not
# in the release archive); Suricata falls back to its own matchers there.
# musl: musl has no ifunc, so a single baseline implementation is built:
# x86-64-v2 (SSE4.2) or ARMv8-A NEON.
build_vectorscan() {
    extract "$(fetch VECTORSCAN "vectorscan-$VECTORSCAN_VERSION.tar.gz")" "$build/vectorscan"
    # Vectorscan always builds with -Werror, which trips over new GCC
    # warnings in older Boost headers (AlmaLinux 8 ships Boost 1.66).
    sed -i 's/ -Werror"/"/' "$build/vectorscan/cmake/cflags-generic.cmake"
    grep -q -- '-Werror"' "$build/vectorscan/cmake/cflags-generic.cmake" \
        && die "failed to drop -Werror from Vectorscan"
    local args=(
        -DCMAKE_BUILD_TYPE=Release
        -DCMAKE_INSTALL_PREFIX="$P"
        -DCMAKE_INSTALL_LIBDIR=lib
        -DCMAKE_POSITION_INDEPENDENT_CODE=ON
        # The fat runtime's per-CPU objects ignore the PIC property, and
        # the gnu variant links suricata as PIE.
        -DCMAKE_C_FLAGS=-fPIC
        -DCMAKE_CXX_FLAGS=-fPIC
        -DBUILD_STATIC_LIBS=ON
        -DBUILD_SHARED_LIBS=OFF
        -DUSE_CPU_NATIVE=OFF
        -DBUILD_UNIT=OFF
        -DBUILD_TOOLS=OFF
        -DBUILD_EXAMPLES=OFF
        -DBUILD_BENCHMARKS=OFF
        -DBUILD_DOC=OFF
        -Wno-dev
    )
    case "$VARIANT-$ARCH" in
        gnu-x86_64)
            args+=(-DFAT_RUNTIME=ON -DNO_SIMDE_IN_FAT=ON -DBUILD_AVX2=ON
                   -DBUILD_AVX512=ON -DBUILD_AVX512VBMI=ON) ;;
        gnu-aarch64)
            args+=(-DFAT_RUNTIME=ON -DBUILD_SVE=ON -DBUILD_SVE2=ON
                   -DBUILD_SVE2_BITPERM=ON) ;;
        musl-x86_64)
            args+=(-DFAT_RUNTIME=OFF -DGNUCC_ARCH=x86-64-v2) ;;
        musl-aarch64)
            args+=(-DFAT_RUNTIME=OFF) ;;
        *) die "unsupported variant/arch $VARIANT-$ARCH" ;;
    esac
    # Environment CFLAGS would be mixed into Vectorscan's own per-target
    # -march flags; keep them out.
    unset CFLAGS CXXFLAGS CPPFLAGS LDFLAGS
    cmake -S "$build/vectorscan" -B "$build/vectorscan/build" "${args[@]}"
    cmake --build "$build/vectorscan/build" -j"$JOBS"
    cmake --install "$build/vectorscan/build"

    # libhs.pc does not declare Vectorscan's C++ runtime dependency, so
    # consumers fail to link it statically. Add it as a private library.
    # gnu: name the static archive directly so the linker cannot pick the
    # shared libstdc++ (which would add a dependency newer than glibc).
    local cxxlibs
    case "$VARIANT" in
        gnu) cxxlibs="$(g++ -print-file-name=libstdc++.a) -lm" ;;
        musl) cxxlibs="-lstdc++ -lm" ;;
    esac
    sed -i '/^Libs.private:/d' "$P/lib/pkgconfig/libhs.pc"
    echo "Libs.private: $cxxlibs" >> "$P/lib/pkgconfig/libhs.pc"
}

# name:VERSION_VAR pairs, in build order.
steps=(
    zlib:ZLIB_VERSION
    lz4:LZ4_VERSION
    pcre2:PCRE2_VERSION
    jansson:JANSSON_VERSION
    libyaml:LIBYAML_VERSION
    libpcap:LIBPCAP_VERSION
    file:FILE_VERSION
    libcap_ng:LIBCAP_NG_VERSION
    libmaxminddb:LIBMAXMINDDB_VERSION
    libnet:LIBNET_VERSION
    vectorscan:VECTORSCAN_VERSION
)

for step in "${steps[@]}"; do
    name=${step%%:*}
    version_var=${step#*:}
    version=${!version_var}
    # The stamp covers this step's version, build function and the shared
    # flags.
    want=$(printf '%s\n%s\n%s\n' "$version" \
        "$(declare -f "build_$name")" "$CFLAGS ${static_args[*]}" \
        | sha256sum | cut -d' ' -f1)
    stamp="$P/.stamp-$name"
    if [[ -f "$stamp" && $(cat "$stamp") == "$want" ]]; then
        echo "$name $version: up to date"
        continue
    fi
    log "$name $version"
    rm -f "$stamp"
    ( "build_$name" )
    rm -rf "${build:?}/${name//_/-}"
    echo "$want" > "$stamp"
done

# Static only: a stray shared library here would be picked up by the linker
# ahead of the archive.
if find "$P" -name '*.so*' | grep -q .; then
    find "$P" -name '*.so*' >&2
    die "shared libraries found in $P"
fi
log "Static dependencies installed in $DEPS_PREFIX"
