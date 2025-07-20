# Multi-stage Dockerfile for modern Terraform with security and DevOps tools
ARG VERSION=latest

# Build arguments for tool versions
ARG TFLINT_VERSION
ARG TFSEC_VERSION
ARG TERRAGRUNT_VERSION
ARG TERRAFORM_DOCS_VERSION
ARG GITHUB_CLI_VERSION
ARG AWS_CLI_VERSION
ARG AZURE_CLI_VERSION
ARG GCP_CLI_VERSION

# Stage 1: Get Terraform binary
FROM hashicorp/terraform:${VERSION} AS terraform

# Stage 2: Security tools
FROM alpine:latest AS security-tools
ARG TFLINT_VERSION
ARG TFSEC_VERSION
RUN apk add --no-cache curl unzip ca-certificates && \
    # TFLint - Terraform linter
    curl -fsSL https://github.com/terraform-linters/tflint/releases/download/v${TFLINT_VERSION}/tflint_linux_amd64.zip -o tflint.zip && \
    unzip tflint.zip && chmod +x tflint && \
    # TFSec - Terraform security scanner  
    curl -fsSL https://github.com/aquasecurity/tfsec/releases/download/v${TFSEC_VERSION}/tfsec-linux-amd64 -o tfsec && \
    chmod +x tfsec

# Stage 3: DevOps tools
FROM alpine:latest AS devops-tools
ARG TERRAGRUNT_VERSION
ARG TERRAFORM_DOCS_VERSION
ARG GITHUB_CLI_VERSION
RUN apk add --no-cache curl tar ca-certificates && \
    # Terragrunt - Terraform wrapper
    curl -fsSL https://github.com/gruntwork-io/terragrunt/releases/download/v${TERRAGRUNT_VERSION}/terragrunt_linux_amd64 -o terragrunt && \
    chmod +x terragrunt && \
    # Terraform-docs - Generate docs from modules
    curl -fsSL https://github.com/terraform-docs/terraform-docs/releases/download/v${TERRAFORM_DOCS_VERSION}/terraform-docs-v${TERRAFORM_DOCS_VERSION}-linux-amd64.tar.gz -o terraform-docs.tar.gz && \
    tar -xzf terraform-docs.tar.gz terraform-docs && chmod +x terraform-docs && \
    # GitHub CLI
    curl -fsSL https://github.com/cli/cli/releases/download/v${GITHUB_CLI_VERSION}/gh_${GITHUB_CLI_VERSION}_linux_amd64.tar.gz -o gh.tar.gz && \
    tar -xzf gh.tar.gz && \
    mv gh_${GITHUB_CLI_VERSION}_linux_amd64/bin/gh . && \
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
COPY --from=security-tools /tflint /tfsec /usr/local/bin/

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
    && ln -sf /opt/google-cloud-sdk/bin/gcloud /usr/local/bin/gcloud \
    && ln -sf /opt/google-cloud-sdk/bin/gsutil /usr/local/bin/gsutil \
    && ln -sf /opt/google-cloud-sdk/bin/bq /usr/local/bin/bq \
    && apk del .build-deps \
    && rm -rf /var/cache/apk/* /tmp/* /root/.cache

# Volumes and workdir configuration
VOLUME ["/data"]
WORKDIR /data

# Entrypoint to enable live customization
COPY docker-entrypoint.sh /docker-entrypoint.sh

# Add healthcheck to verify terraform and tools are working
HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
    CMD terraform version && tflint --version && tfsec --version || exit 1

# Main command
ENTRYPOINT ["/docker-entrypoint.sh"]

# Default flags for the main command
CMD ["-help"]
