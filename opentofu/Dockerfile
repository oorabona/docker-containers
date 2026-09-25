# Multi-stage Dockerfile for modern OpenTofu with security and DevOps tools
# Supports multiple flavors: base, aws, azure, gcp, full
ARG VERSION=latest
ARG UPSTREAM_VERSION
ARG FLAVOR=full

# Build arguments for tool versions
ARG TFLINT_VERSION
ARG TRIVY_VERSION
ARG TERRAGRUNT_VERSION
ARG TERRAFORM_DOCS_VERSION
ARG INFRACOST_VERSION
ARG GITHUB_CLI_VERSION
ARG AWS_CLI_VERSION
ARG AZURE_CLI_VERSION
ARG GCP_CLI_VERSION

# Registry root for GHCR caching (CI sets this to avoid Docker Hub rate limits)
ARG REMOTE_CR=ghcr.io/oorabona

# Stage 1: Get the OpenTofu binary from its checksum-protected release tarball.
FROM ${REMOTE_CR}/library/alpine:latest AS tofu
ARG VERSION
ARG UPSTREAM_VERSION
ARG TARGETARCH
RUN apk add --no-cache curl tar ca-certificates && \
    V="${UPSTREAM_VERSION:-${VERSION}}"; V="${V%-alpine}"; \
    tarball="tofu_${V}_linux_${TARGETARCH}.tar.gz"; \
    sums="tofu_${V}_SHA256SUMS"; \
    release="https://github.com/opentofu/opentofu/releases/download/v${V}"; \
    curl -fsSL --retry 3 --retry-delay 2 --retry-all-errors --connect-timeout 30 "${release}/${tarball}" -o "${tarball}" && \
    curl -fsSL --retry 3 --retry-delay 2 --retry-all-errors --connect-timeout 30 "${release}/${sums}" -o "${sums}" && \
    sum_line=$(awk -v tarball="${tarball}" 'NF == 2 && $2 == tarball { print }' "${sums}") && \
    sum_count=$(printf '%s\n' "${sum_line}" | awk 'NF { count++ } END { print count + 0 }') && \
    if [ "${sum_count}" -ne 1 ]; then echo "Expected exactly one checksum for ${tarball}; found ${sum_count}" >&2; exit 1; fi && \
    printf '%s\n' "${sum_line}" | sha256sum -c - && \
    tar -xzf "${tarball}" tofu && chmod +x tofu

# Stage 2: Security tools (included in all flavors)
ARG REMOTE_CR
FROM ${REMOTE_CR}/library/alpine:latest AS security-tools
ARG TARGETARCH
ARG TFLINT_VERSION
ARG TRIVY_VERSION
RUN : "${TFLINT_VERSION:?required}" "${TRIVY_VERSION:?required}"
RUN apk add --no-cache curl unzip ca-certificates && \
    TRIVY_ARCH=$([ "${TARGETARCH}" = "arm64" ] && echo "ARM64" || echo "64bit") && \
    echo "Downloading TFLint v${TFLINT_VERSION} for ${TARGETARCH}" && \
    curl -fsSL --retry 3 --retry-delay 2 --retry-all-errors --connect-timeout 30 "https://github.com/terraform-linters/tflint/releases/download/v${TFLINT_VERSION}/tflint_linux_${TARGETARCH}.zip" -o tflint.zip && \
    unzip tflint.zip && chmod +x tflint && \
    echo "Downloading Trivy v${TRIVY_VERSION} for ${TRIVY_ARCH}" && \
    curl -fsSL --retry 3 --retry-delay 2 --retry-all-errors --connect-timeout 30 "https://github.com/aquasecurity/trivy/releases/download/v${TRIVY_VERSION}/trivy_${TRIVY_VERSION}_Linux-${TRIVY_ARCH}.tar.gz" -o trivy.tar.gz && \
    tar -xzf trivy.tar.gz trivy && \
    chmod +x trivy

# Stage 3: DevOps tools (included in all flavors)
ARG REMOTE_CR
FROM ${REMOTE_CR}/library/alpine:latest AS devops-tools
ARG TARGETARCH
ARG TERRAGRUNT_VERSION
ARG TERRAFORM_DOCS_VERSION
ARG INFRACOST_VERSION
ARG GITHUB_CLI_VERSION
RUN : "${TERRAGRUNT_VERSION:?required}" "${TERRAFORM_DOCS_VERSION:?required}" "${INFRACOST_VERSION:?required}" "${GITHUB_CLI_VERSION:?required}"
RUN apk add --no-cache curl tar ca-certificates && \
    curl -fsSL --retry 3 --retry-delay 2 --retry-all-errors --connect-timeout 30 https://github.com/gruntwork-io/terragrunt/releases/download/v${TERRAGRUNT_VERSION}/terragrunt_linux_${TARGETARCH} -o terragrunt && \
    chmod +x terragrunt && \
    curl -fsSL --retry 3 --retry-delay 2 --retry-all-errors --connect-timeout 30 https://github.com/terraform-docs/terraform-docs/releases/download/v${TERRAFORM_DOCS_VERSION}/terraform-docs-v${TERRAFORM_DOCS_VERSION}-linux-${TARGETARCH}.tar.gz -o terraform-docs.tar.gz && \
    tar -xzf terraform-docs.tar.gz terraform-docs && chmod +x terraform-docs && \
    curl -fsSL --retry 3 --retry-delay 2 --retry-all-errors --connect-timeout 30 https://github.com/infracost/infracost/releases/download/v${INFRACOST_VERSION}/infracost-linux-${TARGETARCH}.tar.gz -o infracost.tar.gz && \
    tar -xzf infracost.tar.gz && chmod +x infracost-linux-${TARGETARCH} && \
    mv infracost-linux-${TARGETARCH} infracost && \
    curl -fsSL --retry 3 --retry-delay 2 --retry-all-errors --connect-timeout 30 https://github.com/cli/cli/releases/download/v${GITHUB_CLI_VERSION}/gh_${GITHUB_CLI_VERSION}_linux_${TARGETARCH}.tar.gz -o gh.tar.gz && \
    tar -xzf gh.tar.gz && \
    mv gh_${GITHUB_CLI_VERSION}_linux_${TARGETARCH}/bin/gh . && \
    chmod +x gh

# Stage 4: GCP CLI (only built when needed for gcp/full flavors)
# NOTE: GCP SDK installer always fetches latest version - version pinning not supported
ARG REMOTE_CR
FROM ${REMOTE_CR}/library/python:3.12-alpine AS cloud-tools-gcp
ARG FLAVOR
RUN if [ "${FLAVOR}" = "gcp" ] || [ "${FLAVOR}" = "full" ]; then \
        apk add --no-cache curl bash && \
        curl -fsSL https://sdk.cloud.google.com -o /tmp/gcloud-install.sh && \
        bash /tmp/gcloud-install.sh --disable-prompts --install-dir=/opt && \
        rm -f /tmp/gcloud-install.sh && \
        touch /opt/.gcp-installed; \
    else \
        mkdir -p /opt && \
        touch /opt/.gcp-not-installed; \
    fi

# Final stage: Assemble everything based on FLAVOR
ARG REMOTE_CR
FROM ${REMOTE_CR}/library/alpine:latest

ARG FLAVOR

ENV CONFIGFILE=config.json
ENV TOFU_FLAVOR=${FLAVOR}
ENV TG_TF_PATH=tofu

# Copy OpenTofu binary (always included)
COPY --from=tofu /tofu /usr/local/bin/tofu

# Copy security tools (always included)
COPY --from=security-tools /tflint /trivy /usr/local/bin/

# Copy DevOps tools (always included)
COPY --from=devops-tools /terragrunt /terraform-docs /infracost /gh /usr/local/bin/

# Install base runtime dependencies (always needed)
RUN apk --no-cache add \
    ca-certificates \
    curl \
    grep \
    bash \
    git \
    jq \
    yq \
    python3 \
    py3-pip \
    py3-jinja2 \
    py3-yaml

# Jinja2 templating CLI — used UNCONDITIONALLY by docker-entrypoint.sh to render
# *.tf.j2 files, so it must be present in every flavor (not just full).
ARG JINJA2_CLI_VERSION
RUN : "${JINJA2_CLI_VERSION:?required}" && \
    pip3 install --break-system-packages --no-cache-dir jinja2-cli==${JINJA2_CLI_VERSION}

# Cloud CLI installation based on FLAVOR
ARG AWS_CLI_VERSION
ARG AZURE_CLI_VERSION
ARG GCP_CLI_VERSION
RUN : "${AWS_CLI_VERSION:?required}" "${AZURE_CLI_VERSION:?required}" "${GCP_CLI_VERSION:?required}"
RUN --mount=type=cache,target=/root/.cache/pip \
    set -ex && \
    case "${FLAVOR}" in \
        base) echo "Base flavor: no cloud CLIs" ;; \
        aws) \
            echo "AWS flavor: installing AWS CLI" && \
            apk --no-cache add --virtual .build-deps gcc musl-dev libffi-dev python3-dev linux-headers && \
            pip3 install --break-system-packages awscli==${AWS_CLI_VERSION} && \
            apk del .build-deps ;; \
        azure) \
            echo "Azure flavor: installing Azure CLI" && \
            apk --no-cache add --virtual .build-deps gcc musl-dev libffi-dev python3-dev linux-headers && \
            pip3 install --break-system-packages azure-cli==${AZURE_CLI_VERSION} && \
            apk del .build-deps ;; \
        gcp) echo "GCP flavor: will copy Google Cloud SDK" ;; \
        full) \
            echo "Full flavor: installing AWS + Azure CLIs" && \
            apk --no-cache add --virtual .build-deps gcc musl-dev libffi-dev python3-dev linux-headers && \
            pip3 install --break-system-packages awscli==${AWS_CLI_VERSION} azure-cli==${AZURE_CLI_VERSION} && \
            apk del .build-deps ;; \
        *) echo "Unknown flavor: ${FLAVOR}" && exit 1 ;; \
    esac && \
    rm -rf /var/cache/apk/* /tmp/*

# Copy Google Cloud SDK only for gcp and full flavors
COPY --from=cloud-tools-gcp /opt /tmp/gcp-check
RUN if [ -f /tmp/gcp-check/.gcp-installed ]; then \
        mv /tmp/gcp-check/google-cloud-sdk /opt/google-cloud-sdk && \
        ln -sf /opt/google-cloud-sdk/bin/gcloud /usr/local/bin/gcloud && \
        ln -sf /opt/google-cloud-sdk/bin/gsutil /usr/local/bin/gsutil && \
        ln -sf /opt/google-cloud-sdk/bin/bq /usr/local/bin/bq; \
    fi && \
    rm -rf /tmp/gcp-check

# Create tofu user for non-root execution
RUN addgroup -g 1000 -S tofu \
    && adduser -S -D -H -u 1000 -h /data -s /sbin/nologin -G tofu -g tofu tofu \
    && mkdir -p /data /.terraform.d /.config \
    && chown -R tofu:tofu /data /.terraform.d /.config

VOLUME ["/data"]
WORKDIR /data

COPY --chown=tofu:tofu docker-entrypoint.sh /docker-entrypoint.sh

LABEL org.opencontainers.image.title="OpenTofu" \
      org.opencontainers.image.description="OpenTofu CLI with security, DevOps, and cloud tools" \
      org.opencontainers.image.source="https://github.com/oorabona/docker-containers" \
      org.opencontainers.image.vendor="oorabona" \
      org.opencontainers.image.licenses="MPL-2.0"

USER tofu

HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
    CMD tofu version && tflint --version && trivy --version || exit 1

ENTRYPOINT ["/docker-entrypoint.sh"]
CMD ["-help"]
