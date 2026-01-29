# Multi-stage Dockerfile for modern Terraform with security and DevOps tools
# Supports multiple flavors: base, aws, azure, gcp, full
ARG VERSION=latest
ARG UPSTREAM_VERSION=""
ARG FLAVOR=full

# Build arguments for tool versions
ARG TFLINT_VERSION
ARG TRIVY_VERSION
ARG TERRAGRUNT_VERSION
ARG TERRAFORM_DOCS_VERSION
ARG GITHUB_CLI_VERSION
ARG AWS_CLI_VERSION
ARG AZURE_CLI_VERSION
ARG GCP_CLI_VERSION

# Stage 1: Get Terraform binary
# Use UPSTREAM_VERSION if provided (raw version without suffix), fallback to VERSION
FROM hashicorp/terraform:${UPSTREAM_VERSION:-${VERSION}} AS terraform

# Stage 2: Security tools (included in all flavors)
FROM alpine:latest AS security-tools
ARG TARGETARCH
ARG TFLINT_VERSION
ARG TRIVY_VERSION
# Map TARGETARCH to tool-specific naming conventions
RUN apk add --no-cache curl unzip ca-certificates && \
    # Determine Trivy arch name (64bit for amd64, ARM64 for arm64)
    TRIVY_ARCH=$([ "$TARGETARCH" = "arm64" ] && echo "ARM64" || echo "64bit") && \
    # TFLint - Terraform linter (supports amd64/arm64)
    echo "Downloading TFLint v${TFLINT_VERSION} for ${TARGETARCH}" && \
    curl -fsSL "https://github.com/terraform-linters/tflint/releases/download/v${TFLINT_VERSION}/tflint_linux_${TARGETARCH}.zip" -o tflint.zip && \
    unzip tflint.zip && chmod +x tflint && \
    # Trivy - Security scanner (supports 64bit/ARM64)
    echo "Downloading Trivy v${TRIVY_VERSION} for ${TRIVY_ARCH}" && \
    curl -fsSL "https://github.com/aquasecurity/trivy/releases/download/v${TRIVY_VERSION}/trivy_${TRIVY_VERSION}_Linux-${TRIVY_ARCH}.tar.gz" -o trivy.tar.gz && \
    tar -xzf trivy.tar.gz trivy && \
    chmod +x trivy

# Stage 3: DevOps tools (included in all flavors)
FROM alpine:latest AS devops-tools
ARG TARGETARCH
ARG TERRAGRUNT_VERSION
ARG TERRAFORM_DOCS_VERSION
ARG GITHUB_CLI_VERSION
RUN apk add --no-cache curl tar ca-certificates && \
    # Terragrunt - Terraform wrapper (supports amd64/arm64)
    curl -fsSL https://github.com/gruntwork-io/terragrunt/releases/download/v${TERRAGRUNT_VERSION}/terragrunt_linux_${TARGETARCH} -o terragrunt && \
    chmod +x terragrunt && \
    # Terraform-docs - Generate docs from modules (supports amd64/arm64)
    curl -fsSL https://github.com/terraform-docs/terraform-docs/releases/download/v${TERRAFORM_DOCS_VERSION}/terraform-docs-v${TERRAFORM_DOCS_VERSION}-linux-${TARGETARCH}.tar.gz -o terraform-docs.tar.gz && \
    tar -xzf terraform-docs.tar.gz terraform-docs && chmod +x terraform-docs && \
    # GitHub CLI (supports amd64/arm64)
    curl -fsSL https://github.com/cli/cli/releases/download/v${GITHUB_CLI_VERSION}/gh_${GITHUB_CLI_VERSION}_linux_${TARGETARCH}.tar.gz -o gh.tar.gz && \
    tar -xzf gh.tar.gz && \
    mv gh_${GITHUB_CLI_VERSION}_linux_${TARGETARCH}/bin/gh . && \
    chmod +x gh

# Stage 4: GCP CLI (only built when needed for gcp/full flavors)
# NOTE: GCP SDK installer always fetches latest version - version pinning not supported
# The GCP_CLI_VERSION in config.json is for reference/tracking only
FROM python:3.12-alpine AS cloud-tools-gcp
ARG FLAVOR
# Only install GCP SDK if flavor needs it
RUN if [ "${FLAVOR}" = "gcp" ] || [ "${FLAVOR}" = "full" ]; then \
        apk add --no-cache curl bash && \
        curl -fsSL https://sdk.cloud.google.com | bash -s -- --disable-prompts --install-dir=/opt && \
        # Create marker file
        touch /opt/.gcp-installed; \
    else \
        mkdir -p /opt && \
        touch /opt/.gcp-not-installed; \
    fi

# Final stage: Assemble everything based on FLAVOR
FROM alpine:latest

ARG FLAVOR

# Environment variables
ENV CONFIGFILE=config.json
ENV TERRAFORM_FLAVOR=${FLAVOR}

# Copy terraform binary (always included)
COPY --from=terraform /bin/terraform /bin/

# Copy security tools (always included)
COPY --from=security-tools /tflint /trivy /usr/local/bin/

# Copy DevOps tools (always included)
COPY --from=devops-tools /terragrunt /terraform-docs /gh /usr/local/bin/

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
    py3-pip

# Cloud CLI installation based on FLAVOR
ARG AWS_CLI_VERSION
ARG AZURE_CLI_VERSION
ARG GCP_CLI_VERSION

# Install cloud CLIs based on flavor
RUN set -ex && \
    case "${FLAVOR}" in \
        base) \
            echo "Base flavor: no cloud CLIs" \
            ;; \
        aws) \
            echo "AWS flavor: installing AWS CLI" && \
            apk --no-cache add --virtual .build-deps gcc musl-dev libffi-dev python3-dev linux-headers && \
            pip3 install --break-system-packages --no-cache-dir awscli==${AWS_CLI_VERSION} && \
            apk del .build-deps \
            ;; \
        azure) \
            echo "Azure flavor: installing Azure CLI" && \
            apk --no-cache add --virtual .build-deps gcc musl-dev libffi-dev python3-dev linux-headers && \
            pip3 install --break-system-packages --no-cache-dir azure-cli==${AZURE_CLI_VERSION} && \
            apk del .build-deps \
            ;; \
        gcp) \
            echo "GCP flavor: will copy Google Cloud SDK" \
            ;; \
        full) \
            echo "Full flavor: installing AWS + Azure CLIs" && \
            apk --no-cache add --virtual .build-deps gcc musl-dev libffi-dev python3-dev linux-headers && \
            pip3 install --break-system-packages --no-cache-dir \
                awscli==${AWS_CLI_VERSION} \
                azure-cli==${AZURE_CLI_VERSION} \
                j2cli && \
            apk del .build-deps \
            ;; \
        *) \
            echo "Unknown flavor: ${FLAVOR}" && exit 1 \
            ;; \
    esac && \
    rm -rf /var/cache/apk/* /tmp/* /root/.cache

# Copy Google Cloud SDK only for gcp and full flavors
# The conditional is handled in the cloud-tools-gcp stage
COPY --from=cloud-tools-gcp /opt /tmp/gcp-check

# Setup GCP SDK symlinks if present
RUN if [ -f /tmp/gcp-check/.gcp-installed ]; then \
        mv /tmp/gcp-check/google-cloud-sdk /opt/google-cloud-sdk && \
        ln -sf /opt/google-cloud-sdk/bin/gcloud /usr/local/bin/gcloud && \
        ln -sf /opt/google-cloud-sdk/bin/gsutil /usr/local/bin/gsutil && \
        ln -sf /opt/google-cloud-sdk/bin/bq /usr/local/bin/bq; \
    fi && \
    rm -rf /tmp/gcp-check

# Create terraform user for non-root execution
RUN addgroup -g 1000 -S terraform \
    && adduser -S -D -H -u 1000 -h /data -s /sbin/nologin -G terraform -g terraform terraform \
    && mkdir -p /data /.terraform.d /.config \
    && chown -R terraform:terraform /data /.terraform.d /.config

# Volumes and workdir configuration
VOLUME ["/data"]
WORKDIR /data

# Entrypoint to enable live customization
COPY --chown=terraform:terraform docker-entrypoint.sh /docker-entrypoint.sh

# Run as non-root user
USER terraform

# Add healthcheck - verify core tools are working
HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
    CMD terraform version && tflint --version && trivy --version || exit 1

# Main command
ENTRYPOINT ["/docker-entrypoint.sh"]

# Default flags for the main command
CMD ["-help"]
