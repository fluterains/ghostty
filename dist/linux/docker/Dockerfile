FROM ubuntu:24.04 AS toolchain

ARG DEBIAN_FRONTEND=noninteractive
ARG ZIG_VERSION=0.15.2

# BuildKit forwards these values into RUN steps. They are supplied by the
# caller and are never persisted in the resulting package.
ARG HTTP_PROXY
ARG HTTPS_PROXY
ARG ALL_PROXY
ARG NO_PROXY
ENV HTTP_PROXY=${HTTP_PROXY} \
    HTTPS_PROXY=${HTTPS_PROXY} \
    ALL_PROXY=${ALL_PROXY} \
    NO_PROXY=${NO_PROXY}

RUN sed -i \
        -e 's|http://archive.ubuntu.com/ubuntu/|http://mirror.nju.edu.cn/ubuntu/|g' \
        -e 's|http://security.ubuntu.com/ubuntu/|http://mirror.nju.edu.cn/ubuntu/|g' \
        /etc/apt/sources.list.d/ubuntu.sources && \
    apt-get update && \
    apt-get install -y --no-install-recommends \
        build-essential \
        ca-certificates \
        curl \
        dpkg-dev \
        gettext \
        gir1.2-adw-1 \
        gir1.2-gtk-4.0 \
        gobject-introspection \
        libadwaita-1-dev \
        libbz2-dev \
        libexpat1-dev \
        libfontconfig-dev \
        libfreetype-dev \
        libglib2.0-dev \
        libgl-dev \
        libgstreamer-plugins-base1.0-dev \
        libgstreamer1.0-dev \
        libgtk-4-dev \
        libharfbuzz-dev \
        libonig-dev \
        libpng-dev \
        libwayland-dev \
        libx11-dev \
        libxcursor-dev \
        libxi-dev \
        libxkbcommon-dev \
        libxml2-dev \
        libxml2-utils \
        libxrandr-dev \
        patchelf \
        pkg-config \
        python3-gi \
        python3-venv \
        wayland-protocols \
        xz-utils \
        zlib1g-dev && \
    rm -rf /var/lib/apt/lists/*

RUN curl --fail --location --retry 3 \
        --output /tmp/zig.tar.xz \
        "https://ziglang.org/download/${ZIG_VERSION}/zig-x86_64-linux-${ZIG_VERSION}.tar.xz" && \
    tar -xJf /tmp/zig.tar.xz -C /opt && \
    ln -s "/opt/zig-x86_64-linux-${ZIG_VERSION}/zig" /usr/local/bin/zig && \
    rm /tmp/zig.tar.xz && \
    zig version

# Ubuntu 24.04 packages an older Blueprint compiler. This Git checkout builds
# its generated resources from source, so install a compatible compiler in an
# isolated environment while reusing Ubuntu's PyGObject runtime.
RUN python3 -m venv --system-site-packages /opt/blueprint && \
    /opt/blueprint/bin/pip install \
        --disable-pip-version-check \
        --no-cache-dir \
        --no-deps \
        blueprint-compiler==0.22.2 && \
    /opt/blueprint/bin/blueprint-compiler --version
ENV PATH=/opt/blueprint/bin:${PATH}

FROM toolchain AS builder

ARG GHOSTTY_VERSION=1.3.1-patched.3

WORKDIR /src
COPY . /src

RUN --mount=type=cache,id=ghostty-zig-global-v3,target=/var/cache/zig \
    --mount=type=cache,id=ghostty-zig-local-v4,target=/src/.zig-cache \
    unset HTTP_PROXY HTTPS_PROXY ALL_PROXY http_proxy https_proxy all_proxy && \
    DESTDIR=/out ZIG_GLOBAL_CACHE_DIR=/var/cache/zig \
    zig build \
        --prefix /usr \
        -Doptimize=ReleaseFast \
        -Dcpu=baseline \
        -Dversion-string="${GHOSTTY_VERSION}" \
        -Demit-docs=false \
        -fno-sys=gtk4-layer-shell

# The bundled gtk4-layer-shell library is installed below /usr/lib. Use an
# origin-relative RUNPATH so the package never contains a build-machine path.
RUN patchelf --set-rpath '$ORIGIN/../lib' /out/usr/bin/ghostty && \
    install -Dm644 LICENSE /out/usr/share/doc/ghostty/LICENSE && \
    install -Dm644 PATCH1.md /out/usr/share/doc/ghostty/PATCH1.md && \
    install -Dm644 PATCH2.md /out/usr/share/doc/ghostty/PATCH2.md && \
    install -Dm644 PATCH3.md /out/usr/share/doc/ghostty/PATCH3.md

COPY dist/linux/docker/control.in /tmp/control.in
COPY dist/linux/docker/postinst /tmp/debian-postinst
COPY dist/linux/docker/prerm /tmp/debian-prerm
COPY dist/linux/docker/postrm /tmp/debian-postrm

RUN mkdir -p /out/DEBIAN && \
    sed "s|@VERSION@|${GHOSTTY_VERSION}|g" /tmp/control.in > /out/DEBIAN/control && \
    install -m0755 /tmp/debian-postinst /out/DEBIAN/postinst && \
    install -m0755 /tmp/debian-prerm /out/DEBIAN/prerm && \
    install -m0755 /tmp/debian-postrm /out/DEBIAN/postrm && \
    mkdir -p /artifacts && \
    dpkg-deb --root-owner-group --build /out \
        "/artifacts/ghostty_${GHOSTTY_VERSION}_amd64.deb"

FROM builder AS test

ARG GHOSTTY_VERSION=1.3.1-patched.3
ARG GHOSTTY_TEST_FILTER=

RUN --mount=type=cache,id=ghostty-zig-global-v3,target=/var/cache/zig \
    --mount=type=cache,id=ghostty-zig-local-v4,target=/src/.zig-cache \
    unset HTTP_PROXY HTTPS_PROXY ALL_PROXY http_proxy https_proxy all_proxy && \
    zig fmt --check . && \
    ZIG_GLOBAL_CACHE_DIR=/var/cache/zig \
    zig build test \
        -Dversion-string="${GHOSTTY_VERSION}" \
        -Dtest-filter="${GHOSTTY_TEST_FILTER}" \
        -fno-sys=gtk4-layer-shell

FROM scratch AS package
COPY --from=builder /artifacts/ /

FROM scratch AS rootfs
COPY --from=builder /out/ /

