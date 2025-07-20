# Terraform DevOps## 🚀 Usage

### Jinja2 Templating
Add `.j2` extension to Terraform files (`.tf.j2`) for template processing. Templates are rendered using variables from `config.json` in your repository root.

### Security Scanning
```bash
# Scan Terraform configurations
trivy config .

# Scan for misconfigurations with detailed output  
trivy config --format table .
```

### Linting
```bash
# Validate Terraform syntax and best practices
tflint --init
tflint
```

## 📁 Configuration

**Environment Variables:**
- `CONFIGFILE` - Jinja2 configuration file (default: `config.json`)

**Container Volumes:**
- `/data` - Working directory for Terraform configurations (WORKDIR + VOLUME)

## 💡 Example

```yaml
# docker-compose.yml
services:
  terraform:
    image: oorabona/terraform
    volumes:
      - .:/data
    environment:
      - CONFIGFILE=config.json
```

Place this alongside your Terraform code with templated `.tf.j2` files and a `config.json` parameters file.
![Docker Image Version (latest semver)](https://img.shields.io/docker/v/oorabona/terraform?sort=semver)
![Docker Image Size AMD64 (latest semver)](https://img.shields.io/docker/image-size/oorabona/terraform?arch=amd64&sort=semver)
![Docker Image Size ARM64 (latest semver)](https://img.shields.io/docker/image-size/oorabona/terraform?arch=arm64&sort=semver)
![Docker Pulls](https://img.shields.io/docker/pulls/oorabona/terraform)
![Docker Stars](https://img.shields.io/docker/stars/oorabona/terraform)

Complete Terraform development environment with templating, linting, and security scanning capabilities.

## 🛠️ Tools Included

- **[Terraform](https://www.terraform.io)** - Infrastructure as code provisioning
- **[Jinja2](http://jinja.pocoo.org/)** - Template engine for `.tf.j2` files enabling DRY principles
- **[TFLint](https://github.com/terraform-linters/tflint)** - Terraform linter for best practices and error detection  
- **[Trivy](https://trivy.dev/)** - Comprehensive security scanner for misconfigurations and vulnerabilities
- **Git** - Version control for in-container repository operations

##  How to use

In your Terraform registry, you just have to add `.j2` to your `.tf` files.
All `.tf.j2` will be processed using a configuration file named `config.json`.

This configuration file must reside in the root directory of your Terraform repository.

## Parameters

* The environment variable `CONFIGFILE` (*default: `config.json`*) Jinja2 configuration file holding template parameters.

## Volumes

In the container, `/data` is the base directory of your Terraform configuration.
It is actually both a **WORKDIR** and a **VOLUME**.

For instance you can put the sample `docker-compose.yml` in the same repository of your Terraform code.

Alternatively, `git` has also been installed in the container, allowing for in-container cloning.
