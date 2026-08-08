# Smallest base image
ARG REMOTE_CR=ghcr.io/oorabona
ARG OS_VERSION
FROM ${REMOTE_CR}/library/alpine:${OS_VERSION}

ARG VERSION
ARG UPSTREAM_VERSION
ARG EASYRSA_VERSION
ARG EASYRSA_KEY_FPR
ARG OPENVPN_KEY_FPR
ARG OVPN_SHA256
ARG NPROC
# Declared only to refuse it. pkcs11-helper now comes from the Alpine repository
# (#957), so a caller who still pins a version here would get a different library
# than the one they asked for. BuildKit does warn that the argument was not
# consumed, and a warning in a build log is easy to miss, so stop instead.
ARG PKCS11_HELPER_VERSION

# Validate required build args
RUN : "${VERSION:?required}" "${EASYRSA_VERSION:?required}" "${EASYRSA_KEY_FPR:?required}" "${OPENVPN_KEY_FPR:?required}" "${OVPN_SHA256:?required}" "${NPROC:?required}" \
    && [ -z "${PKCS11_HELPER_VERSION:-}" ] || { \
        echo "PKCS11_HELPER_VERSION is no longer honoured: pkcs11-helper comes from the Alpine repository (#957)." >&2; \
        echo "Remove the build argument. Its version now follows OS_VERSION, and Alpine carries it from 3.24 only." >&2; \
        exit 1; \
    }

# EasyRSA release signing key (Eric F Crist, the EasyRSA maintainer; fingerprint
# 6F40 5682 1152 F03B 6B24 F2FC F848 9F83 9D73 67F3). Vendored as the trust
# anchor so the build can verify the fetched EasyRSA tarball's GPG signature
# (#918). Key rotation/expiry is monitored separately (#921).
COPY easyrsa-signing-key.asc /usr/local/share/easyrsa/easyrsa-signing-key.asc

# OpenVPN release signing key (OpenVPN - Security Mailing List
# <security@openvpn.net>; fingerprint F554 A368 7412 CFFE BDEF E0A3 12F5 F7B4
# 2F2B 01E7). Vendored as the trust anchor so the build can verify the fetched
# OpenVPN release tarball. Key rotation/expiry is monitored separately (#921).
COPY openvpn-signing-key.asc /usr/local/share/openvpn/openvpn-signing-key.asc

# Testing: pamtester is only available in edge, not for now.
#
# UPSTREAM_VERSION is required, and the fallback to VERSION it used to claim is
# gone because it never worked: VERSION carries the base suffix — `v2.7.6-alpine`
# — and neither the codeload path nor the release assets have such a ref. Both
# spellings return 404, measured, on master as much as here. `build-container.sh`
# always supplies it when a container has a version.sh whose --upstream differs
# from the tag, which openvpn's does, so the fallback was unreachable as well as
# broken. Requiring it turns a 404 halfway through a build into a message at the
# top of it.
RUN set -ex \
    && DOWNLOAD_VERSION="${UPSTREAM_VERSION:?required — VERSION carries the base suffix and is not a release ref}" \
    # The git tag carries a leading v and the release assets do not:
    # `v2.7.6` tags a release whose files are `openvpn-2.7.6.tar.gz` inside a
    # `openvpn-2.7.6/` directory. `version.sh --upstream` returns the tag form,
    # measured, so strip it once here rather than at each of the four uses.
    # `strip_v: true` in config.yaml governs the version monitor's comparison,
    # not this build argument.
    && RELEASE_VERSION="${DOWNLOAD_VERSION#v}" \
    && apk add --update iptables bash ca-certificates curl linux-pam libselinux openssl nss gnutls gzip pkcs11-helper \
        google-authenticator libqrencode libcap-ng \
    && apk add --no-cache --virtual .build-deps \
        gcc \
        pkgconfig \
        build-base \
        coreutils \
        libconfig-dev \
        linux-headers \
        openssl-dev \
        linux-pam-dev \
        libselinux-dev \
        nss-dev \
        gnutls-dev \
        make \
        libcap-ng-dev \
        libcap-dev \
        pkcs11-helper-dev \
        gnupg \
    && cd /tmp \
    # Fetch the OpenVPN release artifact and its detached signature. The
    # throwaway keyring holds exactly the vendored primary key, so the signature
    # is checked before the archive is inspected, extracted, or compiled.
    && curl -fsSL --retry 3 --retry-delay 2 --retry-all-errors --connect-timeout 30 "https://github.com/OpenVPN/openvpn/releases/download/v${RELEASE_VERSION}/openvpn-${RELEASE_VERSION}.tar.gz" --output openvpn.tgz \
    && curl -fsSL --retry 3 --retry-delay 2 --retry-all-errors --connect-timeout 30 "https://github.com/OpenVPN/openvpn/releases/download/v${RELEASE_VERSION}/openvpn-${RELEASE_VERSION}.tar.gz.asc" --output openvpn.tgz.asc \
    && GNUPGHOME="$(mktemp -d)" && export GNUPGHOME \
    && gpg --batch --import /usr/local/share/openvpn/openvpn-signing-key.asc \
    # A second primary key in the vendored key file must not widen trust.
    && [ "$(gpg --batch --list-keys --with-colons | grep -c '^pub:')" = "1" ] \
    && [ "$(gpg --batch --list-keys --with-colons | awk -F: '/^fpr:/{print $10; exit}')" = "${OPENVPN_KEY_FPR}" ] \
    # `gpg --verify` exits 0 for a signature made by a REVOKED or EXPIRED key —
    # measured, v2.7.4's signature returns 0 with "Note: This key has expired!".
    # The exactly-one-primary assertion above bounds primaries, not the ten
    # signing subkeys hanging off this one, of which eight are expired and two
    # revoked. So read the machine-readable status instead of the exit code.
    #
    # REVKEYSIG is never accepted. EXPKEYSIG is, and that is a bounded residual
    # rather than a proof of anything: a signature's timestamp is chosen by
    # whoever made it, so this does not establish that the signature predates the
    # subkey's expiry. Refusing EXPKEYSIG is not available either — v2.7.4 is in
    # the retained window and is signed by a now-expired subkey, and the EasyRSA
    # block below has the same shape, its single signing subkey being expired too.
    #
    # And nothing here sees a revocation published after this vendored snapshot.
    # The key-lifecycle monitor verifies with this same file, so it cannot learn
    # of one either; refreshing the snapshot is a commit somebody makes. Tracked
    # as the residual it is, not covered by this check.
    && gpg --batch --status-fd 3 --verify openvpn.tgz.asc openvpn.tgz 3>/tmp/ovpn-gpg.status \
    && grep -qE '^\[GNUPG:\] (GOODSIG|EXPKEYSIG) ' /tmp/ovpn-gpg.status \
    && ! grep -qE '^\[GNUPG:\] (REVKEYSIG|BADSIG|ERRSIG|NO_PUBKEY) ' /tmp/ovpn-gpg.status \
    && rm -f /tmp/ovpn-gpg.status \
    && rm -rf "$GNUPGHOME" openvpn.tgz.asc \
    && unset GNUPGHOME \
    # The signed release archive must be the requested version, which blocks an
    # older signed release replayed from this version's release-asset URL.
    #
    # This reads the first member only, so it does not prove every path in the
    # archive shares that prefix. An archive with a conforming first entry and
    # divergent later ones would need OpenVPN's signing key to be accepted at
    # all, and an actor holding that key has no reason to bother.
    # `tar | head -1` alone reports success when tar later hits a truncated
    # archive, because head exits 0 having read its line. Listing to a file first
    # lets tar's own status decide, so a corrupt archive stops here rather than
    # after the archive has been extracted.
    && tar tzf openvpn.tgz > /tmp/ovpn-members.txt \
    && [ "$(head -1 /tmp/ovpn-members.txt)" = "openvpn-${RELEASE_VERSION}/" ] \
    && rm -f /tmp/ovpn-members.txt \
    && tar zxvf openvpn.tgz && cd "openvpn-${RELEASE_VERSION}" \
    # Opinionated but lzo and lz4 are not required for OpenVPN to work
    # and subject to security issues.
    && ./configure --disable-lzo --disable-lz4 --enable-pkcs11 --enable-iproute2 --enable-async-push --enable-selinux \
        --enable-plugin-auth-pam --enable-plugin-down-root --disable-debug --disable-systemd --enable-comp-stub \
    # Do not try to install documentation
    && echo "Building OpenVPN using ${NPROC} cores..." \
    && make -j${NPROC} \
    # Compile and install plugins (only in directories that have Makefiles)
    && make -C src/plugins -j${NPROC} \
    && make -C src/plugins install \
    && make install-exec \
    && cd /usr/local/bin \
    && curl -fsSL --retry 3 --retry-delay 2 --retry-all-errors --connect-timeout 30 https://raw.githubusercontent.com/oorabona/scripts/f596677ab2f15da3a88a7b5f1e81b83ba25bf458/openvpn/setup.sh --output ovpn \
    && printf '%s  %s\n' "${OVPN_SHA256}" ovpn | sha256sum -c - \
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
    # Same shape as the OpenVPN preflight above, and the same reason: tar's status
    # has to survive the pipe. Pre-existing; fixed here because it is the twin of
    # the line this change already had to correct.
    && tar tzf "/usr/local/share/easyrsa/EasyRSA-${EASYRSA_VERSION}.tgz" > /tmp/er-members.txt \
    && [ "$(head -1 /tmp/er-members.txt)" = "EasyRSA-${EASYRSA_VERSION}/" ] \
    && rm -f /tmp/er-members.txt \
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
    && apk del .build-deps \
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
