# Security Policy

## Reporting Vulnerabilities

### Report Security Issues
Unless related to the current implementation of these containers, please forward upstream directly.

### Response Timeline
- **Acknowledgment**: 24 hours
- **Assessment**: 72 hours  
- **Updates**: Regular progress reports
- **Credit**: Recognition in advisory

## Security Implementation

### Container Security
- **Non-root users** by default
- **Minimal base images** (Alpine/distroless)
- **Automated vulnerability scanning** with [Trivy](https://github.com/aquasecurity/trivy)
- **Regular security updates**

### Vulnerability Scanning

All container builds are automatically scanned for CVE vulnerabilities using Trivy.

Trivy runs in advisory mode (`continue-on-error: true`) — no severity blocks builds or pushes. All findings are surfaced for transparency.

| Severity | Behavior |
|----------|----------|
| CRITICAL | Surfaced on dashboard with red emphasis; reported in GitHub Security tab |
| HIGH     | Surfaced on dashboard with warning emphasis; reported in GitHub Security tab |
| MEDIUM   | Surfaced on dashboard (advisory context); reported in GitHub Security tab |
| LOW      | Surfaced on dashboard (advisory context); reported in GitHub Security tab |
| UNKNOWN  | Bucketed into INFO column on the 5-cell dashboard grid |

**Features:**
- Scans OS packages and application dependencies
- SARIF reports uploaded to GitHub Security tab
- Ignores unfixed vulnerabilities
- PR builds show results without blocking

**Configuration:**
```yaml
# In workflow using build-container action
- uses: ./.github/actions/build-container
  with:
    container: mycontainer
    scan_vulnerabilities: 'true'                                  # Enable/disable scanning
    vulnerability_severity: 'UNKNOWN,LOW,MEDIUM,HIGH,CRITICAL'    # Severities surfaced (advisory)
```

### CI/CD Security
- **GitHub Secrets** for sensitive data
- **Branch protection** rules enforced
- **Workflow permissions** limited to minimum required
- **Security scanning** in all pipelines

### Access Control
- **Least privilege** principle
- **Regular access audits**
- **Multi-factor authentication** required
- **Comprehensive audit logging**

## Supported Versions

| Version | Support Status     |
| ------- | ------------------ |
| Latest  | ✅ Fully supported |
| Previous| ✅ 6 months        |
| Older   | ❌ Not supported   |

## Best Practices

### For Contributors
- Never commit secrets or credentials
- Use signed commits
- Follow secure coding practices
- Scan dependencies for vulnerabilities

### For Users  
- Use specific version tags (not `latest`)
- Update container images regularly
- Scan images before deployment
- Implement security hardening

---

**Last Updated**: January 2026
