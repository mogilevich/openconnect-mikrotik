# ============================================
# Stage 1: Build openconnect without libproxy
# ============================================
FROM alpine:3.19 AS builder

RUN apk add --no-cache \
    build-base \
    autoconf \
    automake \
    libtool \
    pkgconf \
    git \
    openssl-dev \
    gnutls-dev \
    libxml2-dev \
    lz4-dev \
    linux-headers \
    gettext-dev

RUN git clone --depth 1 https://gitlab.com/openconnect/openconnect.git /src/openconnect

WORKDIR /src/openconnect

RUN ./autogen.sh && \
    ./configure \
        --prefix=/usr \
        --sysconfdir=/etc \
        --disable-nls \
        --without-libproxy \
        --without-libpskc \
        --without-stoken \
        --without-gssapi \
        --with-vpnc-script=/etc/vpnc/vpnc-script && \
    make -j$(nproc) && \
    make DESTDIR=/install install

# ============================================
# Stage 2: Minimal runtime image
# ============================================
FROM alpine:3.19

RUN apk add --no-cache --no-scripts \
    gnutls \
    libxml2 \
    lz4-libs \
    ca-certificates-bundle \
    iptables \
    dnsmasq \
    vpnc \
    #
    # === Remove unnecessary files ===
    #
    && rm -f /usr/sbin/vpnc /usr/sbin/vpnc-disconnect \
    && rm -rf /sbin/apk /lib/libapk* /lib/apk /etc/apk \
    # Unnecessary binaries
    && rm -f /usr/bin/p11-kit /usr/bin/trust \
    && rm -f /usr/bin/scanelf /usr/bin/getent /usr/bin/iconv \
    && rm -f /usr/bin/getconf /usr/bin/ldd \
    && rm -rf /usr/libexec/p11-kit \
    # OpenSSL modules
    && rm -rf /usr/lib/ossl-modules \
    # p11-kit modules
    && rm -rf /usr/lib/pkcs11 /usr/share/p11-kit \
    # Documentation and cache
    && rm -rf /var/cache/apk/* /usr/share/* /tmp/* /root/.cache \
    && rm -rf /etc/ssl/ct_log_list.cnf* /etc/ssl/openssl.cnf* /etc/ssl/misc

# Copy built openconnect
COPY --from=builder /install/usr/sbin/openconnect /usr/sbin/
COPY --from=builder /install/usr/lib/libopenconnect.so.5.9.0 /usr/lib/
RUN ln -s libopenconnect.so.5.9.0 /usr/lib/libopenconnect.so.5

COPY connect.sh /connect.sh
RUN chmod +x /connect.sh

EXPOSE 53/udp 53/tcp

ENTRYPOINT ["/bin/sh", "/connect.sh"]
