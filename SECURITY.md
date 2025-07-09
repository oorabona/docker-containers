# Security Policy

## Reporting Security Vulnerabilities

We take security seriously. If you discover a security vulnerability, please report it to us privately.

### How to Report

1. **Email**: Send details to security@example.com
2. **GitHub**: Use the private security advisory feature
3. **Include**: Detailed description, reproduction steps, and potential impact

### What to Expect

- **Acknowledgment** within 24 hours
- **Initial assessment** within 72 hours
- **Regular updates** on progress
- **Credit** in security advisory (if desired)

## Security Measures

### Container Security

- **Non-root execution** by default
- **Minimal attack surface** using Alpine/distroless images
- **Regular vulnerability scanning**
- **Automated security updates**

### CI/CD Security

- **Secrets management** via GitHub Secrets
- **Branch protection** rules enforced
- **Signed commits** required
- **Security scanning** in all workflows

### Access Control

- **Principle of least privilege**
- **Regular access reviews**
- **Multi-factor authentication** required
- **Audit logging** enabled

## Supported Versions

| Version | Supported          |
| ------- | ------------------ |
| Latest  | ✅ Yes             |
| Previous| ✅ Yes (6 months)  |
| Older   | ❌ No              |

## Security Best Practices

### For Contributors

1. **Never commit secrets** or credentials
2. **Use signed commits** when possible
3. **Follow security coding practices**
4. **Scan dependencies** for vulnerabilities

### For Users

1. **Use specific version tags** instead of `latest`
2. **Regularly update** container images
3. **Scan images** before deployment
4. **Follow security hardening** guides

---

**Last Updated**: June 21, 2025
