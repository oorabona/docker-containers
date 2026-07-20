# Smallest base image
ARG REMOTE_CR=ghcr.io/oorabona
ARG OS_VERSION
FROM ${REMOTE_CR}/library/alpine:${OS_VERSION}

ARG VERSION
ARG UPSTREAM_VERSION
ARG PKCS11_HELPER_VERSION
ARG EASYRSA_VERSION
ARG EASYRSA_KEY_FPR
ARG NPROC

# Validate required build args
RUN : "${VERSION:?required}" "${PKCS11_HELPER_VERSION:?required}" "${EASYRSA_VERSION:?required}" "${EASYRSA_KEY_FPR:?required}" "${NPROC:?required}"

# EasyRSA release signing key (Eric F Crist, the EasyRSA maintainer; fingerprint
# 6F40 5682 1152 F03B 6B24 F2FC F848 9F83 9D73 67F3). Vendored as the trust
# anchor so the build can verify the fetched EasyRSA tarball's GPG signature
# (#918). Key rotation/expiry is monitored separately (#921).
COPY easyrsa-signing-key.asc /usr/local/share/easyrsa/easyrsa-signing-key.asc

# Testing: pamtester is only available in edge, not for now.
# Use UPSTREAM_VERSION for downloads if provided, otherwise fall back to VERSION
RUN set -ex \
    && DOWNLOAD_VERSION="${UPSTREAM_VERSION:-$VERSION}" \
    && apk add --update iptables bash ca-certificates curl linux-pam libselinux openssl nss gnutls gzip \
        google-authenticator libqrencode libcap-ng \
    && apk add --no-cache --virtual .build-deps \
        gcc \
        pkgconfig \
        build-base \
        coreutils \
        libconfig-dev \
        linux-headers \
        autoconf \
        libtool \
        openssl-dev \
        linux-pam-dev \
        libselinux-dev \
        nss-dev \
        gnutls-dev \
        automake \
        make \
        libcap-ng-dev \
        libcap-dev \
    && cd /tmp && curl -sSL --retry 3 --retry-delay 2 --retry-all-errors --connect-timeout 30 https://github.com/openvpn/openvpn/archive/$DOWNLOAD_VERSION.tar.gz --output openvpn.tgz \
    # Download pinned version of OpenSC pkcs11-helper
    && curl -sSL --retry 3 --retry-delay 2 --retry-all-errors --connect-timeout 30 https://github.com/opensc/pkcs11-helper/archive/pkcs11-helper-${PKCS11_HELPER_VERSION}.tar.gz --output pkcs11-helper.tgz \
    && tar zxvf pkcs11-helper.tgz \
    && cd pkcs11-helper-pkcs11-helper-${PKCS11_HELPER_VERSION} \
    && autoreconf -ivf \
    # Note: --enable-pedantic removed - modern NSS headers use C++ comments incompatible with strict C90
    && ./configure --enable-strict \
    && make -j$NPROC \
    && make install \
    && cd /tmp \
    && tar zxvf openvpn.tgz && cd openvpn* \
    # Opinionated but lzo and lz4 are not required for OpenVPN to work
    # and subject to security issues.
    && autoreconf -ivf \
    && ./configure --disable-lzo --disable-lz4 --enable-pkcs11 --enable-iproute2 --enable-async-push --enable-selinux \
        --enable-plugin-auth-pam --enable-plugin-down-root --disable-debug --disable-systemd --enable-comp-stub \
    # Do not try to install documentation
    && echo "Building OpenVPN using ${NPROC} cores..." \
    && make -j${NPROC} \
    # Compile and install plugins (only in directories that have Makefiles)
    && make -C src/plugins -j${NPROC} \
    && make -C src/plugins install \
    && make install-exec \
    && apk del .build-deps \
    && cd /usr/local/bin \
    && curl -fsSL --retry 3 --retry-delay 2 --retry-all-errors --connect-timeout 30 https://raw.githubusercontent.com/oorabona/scripts/8985382fb199cdb502783ba42585da40d481eead/openvpn/setup.sh --output ovpn \
    && chmod +x ovpn \
    # Bake EasyRSA at build time so first-run setup is hermetic (#918): fetch the
    # pinned tarball and its GPG signature and verify it against the vendored
    # EasyRSA maintainer key. The key is imported into a throwaway keyring holding
    # only it (asserted by fingerprint), so `gpg --verify` accepts only its
    # signatures. The archive is then checked to be the requested version with an
    # executable easyrsa, and the installer's one GitHub wget is rewritten to a cp
    # of the baked file. By design the image is pinned to its baked EASYRSA_VERSION:
    # a runtime override / "Update EasyRSA" to another version fails closed (baked
    # file absent) — update by rebuilding, not at runtime. Only the key is pinned
    # (the .sig is fetched per build); key rotation/expiry is watched in #921.
    && apk add --no-cache --virtual .gpg-deps gnupg \
    && curl -fsSL --retry 3 --retry-delay 2 --retry-all-errors --connect-timeout 30 \
        "https://github.com/OpenVPN/easy-rsa/releases/download/v${EASYRSA_VERSION}/EasyRSA-${EASYRSA_VERSION}.tgz" \
        --output "/usr/local/share/easyrsa/EasyRSA-${EASYRSA_VERSION}.tgz" \
    && curl -fsSL --retry 3 --retry-delay 2 --retry-all-errors --connect-timeout 30 \
        "https://github.com/OpenVPN/easy-rsa/releases/download/v${EASYRSA_VERSION}/EasyRSA-${EASYRSA_VERSION}.tgz.sig" \
        --output "/usr/local/share/easyrsa/EasyRSA-${EASYRSA_VERSION}.tgz.sig" \
    && GNUPGHOME="$(mktemp -d)" && export GNUPGHOME \
    && gpg --batch --import /usr/local/share/easyrsa/easyrsa-signing-key.asc \
    # The throwaway keyring must hold EXACTLY the one expected key, so
    # `gpg --verify` can only accept that key's signatures (a vendored file with a
    # second key would otherwise widen trust silently).
    && [ "$(gpg --batch --list-keys --with-colons | grep -c '^pub:')" = "1" ] \
    && [ "$(gpg --batch --list-keys --with-colons | awk -F: '/^fpr:/{print $10; exit}')" = "${EASYRSA_KEY_FPR}" ] \
    && gpg --batch --verify "/usr/local/share/easyrsa/EasyRSA-${EASYRSA_VERSION}.tgz.sig" "/usr/local/share/easyrsa/EasyRSA-${EASYRSA_VERSION}.tgz" \
    && rm -rf "$GNUPGHOME" "/usr/local/share/easyrsa/EasyRSA-${EASYRSA_VERSION}.tgz.sig" \
    && unset GNUPGHOME \
    && apk del .gpg-deps \
    # The signature covers the tarball bytes, so its top-level EasyRSA-<ver>/ dir is
    # authenticated: require it to equal the requested version (blocks a replayed
    # older signed release served from this version's URL). Then extract the way the
    # installer will (--strip-components=1) and require an executable easyrsa.
    && [ "$(tar tzf "/usr/local/share/easyrsa/EasyRSA-${EASYRSA_VERSION}.tgz" 2>/dev/null | head -1)" = "EasyRSA-${EASYRSA_VERSION}/" ] \
    && rm -rf /tmp/erverify && mkdir -p /tmp/erverify \
    && tar xzf "/usr/local/share/easyrsa/EasyRSA-${EASYRSA_VERSION}.tgz" --strip-components=1 -C /tmp/erverify \
    && test -x /tmp/erverify/easyrsa \
    && rm -rf /tmp/erverify \
    # Assert the pinned installer still resolves its EasyRSA version from
    # EASYRSA_VERSION, so the version-specific baked file matches what its cp asks
    # for (else a future installer bump could request an unbaked version).
    && grep -qF 'LATEST_EASYRSA_VERSION=$EASYRSA_VERSION' ovpn \
    && sed -i 's#wget -O ~/easy-rsa.tgz https://github.com/OpenVPN/easy-rsa/releases/download/.*EasyRSA-.*\.tgz#cp /usr/local/share/easyrsa/EasyRSA-${version}.tgz ~/easy-rsa.tgz#' ovpn \
    && grep -qF 'cp /usr/local/share/easyrsa/EasyRSA-${version}.tgz ~/easy-rsa.tgz' ovpn \
    && ! grep -qE 'releases/download/[^ ]*EasyRSA' ovpn \
    && rm -rf /tmp/* /var/tmp/* /var/cache/apk/* /var/cache/distfiles/*

LABEL org.opencontainers.image.title="OpenVPN" \
      org.opencontainers.image.description="OpenVPN server with PKCS11, PAM, and EasyRSA support" \
      org.opencontainers.image.source="https://github.com/oorabona/docker-containers" \
      org.opencontainers.image.vendor="oorabona" \
      org.opencontainers.image.licenses="MIT"

# Create a volume for the configuration
VOLUME ["/etc/openvpn"]

# Internally uses port 1194/udp, remap using `docker run -p 443:1194/tcp`
EXPOSE 1194/udp 1194/tcp

# Add healthcheck to verify OpenVPN is accessible
HEALTHCHECK --interval=30s --timeout=10s --start-period=30s --retries=3 \
    CMD openvpn --version || exit 1

# Environment variables
ENV OS=other \
    EASYRSA_VERSION=${EASYRSA_VERSION}

# Copy the PAM configuration for OTP
COPY openvpn-pam.conf /etc/pam.d/openvpn

# Run OpenVPN setup script
CMD ["ovpn"]
