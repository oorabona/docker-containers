# Multi-stage Dockerfile for modern Terraform with security and DevOps tools
ARG VERSION=latest
ARG UPSTREAM_VERSION=""

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

# Stage 2: Security tools
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

# Stage 3: DevOps tools
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

# Stage 4: Cloud tools - GCP CLI only (AWS/Azure in final stage)  
FROM python:3.12-alpine AS cloud-tools
ARG GCP_CLI_VERSION
RUN apk add --no-cache curl bash && \
    # Install Google Cloud CLI via official installer
    curl -fsSL https://sdk.cloud.google.com | bash -s -- --disable-prompts --install-dir=/opt

# Final stage: Assemble everything
FROM alpine:latest

# Environment variables
ENV CONFIGFILE=config.json

# Copy terraform binary
COPY --from=terraform /bin/terraform /bin/

# Copy security tools
COPY --from=security-tools /tflint /trivy /usr/local/bin/

# Copy DevOps tools  
COPY --from=devops-tools /terragrunt /terraform-docs /gh /usr/local/bin/

# Copy Google Cloud SDK
COPY --from=cloud-tools /opt/google-cloud-sdk /opt/google-cloud-sdk

# Install runtime dependencies and cloud CLIs
ARG AWS_CLI_VERSION
ARG AZURE_CLI_VERSION
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
    && apk --no-cache add --virtual .build-deps \
        gcc \
        musl-dev \
        libffi-dev \
        python3-dev \
        linux-headers \
    && pip3 install --break-system-packages --no-cache-dir \
        awscli==${AWS_CLI_VERSION} \
        azure-cli==${AZURE_CLI_VERSION} \
        j2cli \
    && ln -sf /opt/google-cloud-sdk/bin/gcloud /usr/local/bin/gcloud \
    && ln -sf /opt/google-cloud-sdk/bin/gsutil /usr/local/bin/gsutil \
    && ln -sf /opt/google-cloud-sdk/bin/bq /usr/local/bin/bq \
    && apk del .build-deps \
    && rm -rf /var/cache/apk/* /tmp/* /root/.cache

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

# Add healthcheck to verify terraform and tools are working
HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
    CMD terraform version && tflint --version && trivy --version || exit 1

# Main command
ENTRYPOINT ["/docker-entrypoint.sh"]

# Default flags for the main command
CMD ["-help"]
