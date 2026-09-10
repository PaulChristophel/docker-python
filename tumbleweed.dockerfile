ARG BASE=docker.io/opensuse/tumbleweed:latest@sha256:b4406fd5a038f199f1a017aa96f1a5758775fdc807f5bf6525bbb7e125c31c58

FROM ${BASE} AS python-builder
# Supply these from images.json; deliberately no independent version defaults.
ARG PYTHON_VERSION
ARG PYTHON_SHA256
ARG PYTHON_CFLAGS="-O2 -pipe -fstack-protector-strong -D_FORTIFY_SOURCE=3"
ARG CPU_CFLAGS=""
ARG PYTHON_LDFLAGS="-Wl,-z,relro,-z,now -Wl,--as-needed -Wl,-rpath,'\$\$ORIGIN' -Wl,-rpath,'\$\$ORIGIN/../lib'"

RUN test -n "${PYTHON_VERSION}" && test -n "${PYTHON_SHA256}" \
 && zypper --non-interactive --gpg-auto-import-keys install --no-recommends \
      gcc make gawk findutils pkg-config glibc-devel linux-glibc-devel \
      libopenssl-devel libffi-devel zlib-devel libbz2-devel xz-devel \
      readline-devel sqlite3-devel gdbm-devel ncurses-devel libuuid-devel \
      libzstd-devel libexpat-devel mpdecimal-devel systemtap-sdt-devel \
      ca-certificates wget bsdtar xz shadow \
 && wget -O /tmp/python.tar.xz "https://www.python.org/ftp/python/${PYTHON_VERSION}/Python-${PYTHON_VERSION}.tar.xz" \
 && echo "${PYTHON_SHA256}  /tmp/python.tar.xz" | sha256sum -c - \
 && mkdir /tmp/python-src /tmp/python-install \
 && bsdtar -xJf /tmp/python.tar.xz -C /tmp/python-src --strip-components=1 \
 && groupadd -r python-build \
 && useradd -r -g python-build -d /tmp/python-src python-build \
 && chown -R python-build:python-build /tmp/python-src /tmp/python-install

USER python-build
WORKDIR /tmp/python-src
RUN ./configure \
      CFLAGS="${PYTHON_CFLAGS} ${CPU_CFLAGS}" \
      LDFLAGS="${PYTHON_LDFLAGS}" \
      --enable-optimizations \
      --with-lto \
      --prefix=/usr/local \
      --with-ensurepip=install \
      --enable-ipv6 \
      --enable-shared \
      --without-static-libpython \
      --with-computed-gotos \
      --with-dbmliborder=gdbm:ndbm:bdb \
      --with-system-expat \
      --with-system-libmpdec \
      --enable-loadable-sqlite-extensions \
      --with-dtrace \
      --with-ssl-default-suites=openssl \
 && make -j"$(nproc)"

# test_readline's pseudo-terminal cases fail under ARM-hosted AMD64 emulation;
# the final stage verifies the readline module through its public API instead.
RUN LD_LIBRARY_PATH=/tmp/python-src \
    ./python -m test --verbose3 -j2 test_ssl test_hashlib test_sqlite3 test_ctypes \
      test_bz2 test_lzma test_zlib test_venv test_uuid test_dbm \
 && LD_LIBRARY_PATH=/tmp/python-src make install DESTDIR=/tmp/python-install \
 && ln -s python3 /tmp/python-install/usr/local/bin/python \
 && ln -s pip3 /tmp/python-install/usr/local/bin/pip

FROM ${BASE} AS runtime-builder
RUN mkdir -p /mnt/rootfs \
 && zypper --installroot /mnt/rootfs --non-interactive --gpg-auto-import-keys \
      install --no-recommends \
      bash ca-certificates ca-certificates-mozilla openSUSE-release timezone \
      libopenssl3 libffi8 libz1 libbz2-1 liblzma5 libreadline8 \
      libsqlite3-0 libgdbm6 libgdbm_compat4 libncurses6 libuuid1 libzstd1 \
      libexpat1 libmpdec4 zypper zypper-keys-plugin \
 && mkdir -p /mnt/rootfs/etc/zypp/repos.d \
 && cp -a /etc/zypp/repos.d/. /mnt/rootfs/etc/zypp/repos.d/ \
 && zypper --installroot /mnt/rootfs --non-interactive clean --all \
 && rm -rf /mnt/rootfs/var/cache/zypp

FROM scratch
ARG BASE
ARG PYTHON_VERSION
ARG IMAGE_DISTRIBUTION=tumbleweed
ARG IMAGE_DISTRIBUTION_VERSION=unknown
ARG IMAGE_REPOSITORY=docker.io/pcm0/python
ARG IMAGE_REVISION=unknown
ARG IMAGE_CREATED=1970-01-01T00:00:00Z
LABEL org.opencontainers.image.title="Python on openSUSE Tumbleweed" \
      org.opencontainers.image.description="CPython built from upstream source on openSUSE Tumbleweed." \
      org.opencontainers.image.authors="Paul Christophel <pmartin@gatech.edu>" \
      org.opencontainers.image.source="https://github.com/PaulChristophel/docker-python" \
      org.opencontainers.image.url="https://hub.docker.com/r/pcm0/python" \
      org.opencontainers.image.documentation="https://github.com/PaulChristophel/docker-python#readme" \
      org.opencontainers.image.licenses="AGPL-3.0-or-later" \
      org.opencontainers.image.version="${PYTHON_VERSION}" \
      org.opencontainers.image.component.python.version="${PYTHON_VERSION}" \
      org.opencontainers.image.base.name="${BASE}" \
      org.opencontainers.image.ref.name="${IMAGE_REPOSITORY}" \
      org.opencontainers.image.revision="${IMAGE_REVISION}" \
      org.opencontainers.image.created="${IMAGE_CREATED}" \
      edu.gatech.image.os.distribution="${IMAGE_DISTRIBUTION}" \
      edu.gatech.image.os.version="${IMAGE_DISTRIBUTION_VERSION}"
COPY --from=runtime-builder /mnt/rootfs/ /
COPY --from=python-builder /tmp/python-install/usr/local/ /usr/local/
ENV PATH=/usr/local/bin:/usr/bin:/bin \
    LANG=C.UTF-8
RUN python -c 'import bz2, ctypes, dbm.gnu, dbm.ndbm, hashlib, lzma, readline, sqlite3, ssl, uuid, zlib; import sys; assert sys.version.split()[0] == sys.argv[1]; assert ssl.create_default_context().get_ca_certs(); assert sqlite3.connect(":memory:").execute("select 1").fetchone() == (1,)' "${PYTHON_VERSION}" \
 && python -c 'import readline; readline.clear_history(); readline.add_history("history smoke test"); assert readline.get_current_history_length() == 1; assert readline.get_history_item(1) == "history smoke test"; readline.set_completer_delims(" \t$"); assert readline.get_completer_delims() == " \t$"' \
 && python -c 'import sys; exec("from compression import zstd; assert zstd.decompress(zstd.compress(b\"test\")) == b\"test\"") if sys.version_info >= (3, 14) else None' \
 && python -c 'import ctypes, os, sysconfig; assert sysconfig.get_config_var("Py_ENABLE_SHARED") == 1; ctypes.PyDLL(os.path.join(sysconfig.get_config_var("LIBDIR"), sysconfig.get_config_var("INSTSONAME")))' \
 && python -c 'import pyexpat, sqlite3; assert pyexpat.EXPAT_VERSION.startswith("expat_"); connection = sqlite3.connect(":memory:"); connection.enable_load_extension(True); connection.enable_load_extension(False)' \
 && test -x /usr/bin/zypper \
 && python -m pip --version \
 && python -m venv /tmp/python-smoke \
 && /tmp/python-smoke/bin/python -m pip --version \
 && python -c 'import shutil; shutil.rmtree("/tmp/python-smoke")'
CMD ["python3"]
