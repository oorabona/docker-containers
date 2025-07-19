# Docker Containers Repository - AI Agent Instructions

## 🎯 Repository Overview

This is an **automated Docker container management system** with intelligent upstream monitoring, version classification, and CI/CD pipelines. The repository maintains multiple containerized applications with sophisticated automation for version detection, building, and deployment.

### Core Architecture
- **📦 Container-Centric**: Each directory represents a self-contained Docker application
- **🔄 Automated Monitoring**: Twice-daily upstream version checks with intelligent PR creation
- **🚀 Hybrid Build System**: PR-centric approach balancing automation speed with safety
- **🛡️ Branch Protection Compatible**: All changes flow through PRs for audit trails
- **📋 Timeline Tracking**: Complete build history in `CHANGELOG.md`

## 🧠 Understanding the Project Structure

### Key Directories & Files
```
docker-containers/
├── .github/
│   ├── workflows/
│   │   ├── upstream-monitor.yaml    # ⭐ Core automation workflow
│   │   ├── auto-build.yaml         # ⭐ Container build & push system
│   │   └── validate-version-scripts.yaml
│   ├── actions/                    # Reusable GitHub Actions
│   └── scripts/
│       ├── classify-version-change.sh  # ⭐ Version classification logic
│       └── close-duplicate-prs.sh
├── make                           # ⭐ Universal build script
├── CHANGELOG.md                   # ⭐ Timeline-based build history
├── [container-name]/             # Individual container directories
│   ├── Dockerfile                # Container definition
│   ├── version.sh               # ⭐ Version detection script
│   ├── docker-compose.yml       # Optional: compose configuration
│   ├── LAST_REBUILD.md          # Rebuild trigger marker (PR-only)
│   └── README.md               # Container documentation
└── helpers/                    # Shared version detection utilities
```

### Critical Components You Must Understand

1. **`make` Script** (Universal Build System)
   - Single entry point for all container operations
   - Handles building, pushing, running, and version checking
   - Integrates with both local development and CI/CD
   - **Usage**: `./make build wordpress`, `./make version ansible`

2. **`version.sh` Scripts** (Version Detection)
   - **Two modes**: `./version.sh` (current) and `./version.sh latest` (upstream)
   - **Multiple strategies**: Hardcoded versions, API calls, Docker Hub checks
   - **Examples**: 
     - Hardcoded: `echo "6.1.1"` (wordpress)
     - Dynamic: Docker Hub API calls (terraform)
     - PyPI integration: Python package versions (ansible)

3. **Version Classification System** (`.github/scripts/classify-version-change.sh`)
   - Determines **major** vs **minor** version changes
   - Supports multiple versioning schemes: semver, date-based, PHP-style
   - **Major changes**: Require manual PR review
   - **Minor changes**: Eligible for auto-build + auto-merge

## 🔄 The Hybrid Automation Workflow

### PR-Centric Approach Overview
The system uses a sophisticated **PR-centric approach** to balance automation speed with safety:

```mermaid
graph TD
    A[Upstream Monitor] --> B{Version Change?}
    B -->|Yes| C[Classify Change]
    C -->|Minor| D[Auto-Build Test]
    C -->|Major| E[Create PR for Review]
    D -->|Success| F[Create PR + Auto-Merge]
    D -->|Failure| G[Create PR for Debug]
    E --> H[Manual Review Required]
    F --> I[Auto-Build Workflow]
    G --> H
    H --> I
```

### Key Automation Flows

1. **Minor/Patch Updates (Fast Path)**:
   - Auto-build test to validate changes
   - If successful: Create PR + enable auto-merge
   - If failed: Create PR for manual debugging
   - **Result**: Fast automation for safe changes

2. **Major Updates (Safe Path)**:
   - Skip auto-build, directly create PR
   - Require manual review and approval
   - **Result**: Human oversight for potentially breaking changes

3. **Branch Protection Compatibility**:
   - ALL changes flow through PRs (no direct pushes)
   - Auto-merge respects branch protection rules
   - Complete audit trail for compliance

## 🛠️ Development Workflows

### Adding a New Container

1. **Create Directory Structure**:
   ```bash
   mkdir my-app
   cd my-app
   ```

2. **Create `Dockerfile`** (follow existing patterns):
   ```dockerfile
   FROM alpine:latest
   # Application setup...
   HEALTHCHECK --interval=30s CMD curl -f http://localhost:8080/health || exit 1
   CMD ["my-app"]
   ```

3. **Create `version.sh`** (choose appropriate strategy):
   ```bash
   #!/bin/bash
   # Choose one of these patterns:
   
   # Pattern 1: Hardcoded version
   echo "1.0.0"
   
   # Pattern 2: GitHub releases API
   case "${1:-current}" in
       latest)
           curl -s "https://api.github.com/repos/owner/repo/releases/latest" | \
             jq -r '.tag_name' | sed 's/^v//'
           ;;
       current|*)
           echo "1.0.0"  # Current version
           ;;
   esac
   
   # Pattern 3: Use helper utilities
   source "../helpers/docker-tags"
   if [ "$1" == "latest" ]; then
       latest-docker-tag owner/image "^[0-9]+\.[0-9]+\.[0-9]+$"
   else
       check-docker-tag owner/image "^${1}$"
   fi
   ```

4. **Test the Container**:
   ```bash
   chmod +x version.sh
   ./version.sh          # Should return current version
   ./version.sh latest   # Should return latest upstream
   cd ..
   ./make build my-app   # Test build process
   ```

### Working with Version Scripts

**Critical Patterns to Follow**:

1. **Error Handling**: Always handle API failures gracefully
2. **Timeout**: Use timeouts for network requests
3. **Validation**: Validate version format before returning
4. **Documentation**: Comment the version source clearly

**Helper Utilities Available**:
- `helpers/docker-tags`: Docker Hub API integration
- `helpers/git-tags`: GitHub releases integration  
- `helpers/python-tags`: PyPI package integration

### Testing and Validation

1. **Version Script Testing**:
   ```bash
   ./validate-version-scripts.sh  # Test all version.sh scripts
   ./test-version-scripts.sh      # Basic validation
   ```

2. **Build Testing**:
   ```bash
   ./make build WANTED=container-name     # Build specific container
   ./make version WANTED=container-name   # Check version
   ```

3. **Workflow Testing**:
   ```bash
   ./test-github-actions.sh  # Validate GitHub Actions syntax
   ```

## 📝 Code Standards & Patterns

### Version Script Patterns
```bash
#!/bin/bash
# Standard header with description

# Helper function for error handling
get_latest_version() {
    local version
    version=$(curl -s --fail --max-time 30 "https://api.example.com/version" | jq -r '.version' 2>/dev/null)
    if [[ -n "$version" && "$version" != "null" ]]; then
        echo "$version"
    else
        echo "unknown"
        exit 1
    fi
}

# Main switch statement
case "${1:-current}" in
    latest)
        get_latest_version
        ;;
    current|*)
        echo "1.0.0"  # Current hardcoded version
        ;;
esac
```

### Dockerfile Best Practices
- Use specific base image versions when possible
- Include `HEALTHCHECK` instructions
- Follow multi-stage builds for optimization
- Add labels for metadata
- Use non-root users where applicable

### GitHub Actions Patterns
- Always use specific action versions (`uses: actions/checkout@v4`)
- Include proper error handling and continue-on-error where appropriate
- Use step summaries for user-friendly output
- Set proper permissions (contents, packages, pull-requests)

## 🔧 Troubleshooting Guide

### Common Issues & Solutions

1. **Version Script Failures**:
   - Check network connectivity and API rate limits
   - Validate JSON parsing with `jq`
   - Test timeout handling
   - **Debug**: `DEBUG=1 ./container/version.sh latest`

2. **Build Failures**:
   - Check Dockerfile syntax
   - Verify base image availability
   - Review dependency installation steps
   - **Debug**: `./make build container-name` with verbose output

3. **Workflow Issues**:
   - Validate YAML syntax with yamllint
   - Check permissions in workflow files
   - Review action inputs/outputs
   - **Debug**: Enable debug mode in workflow dispatch

4. **PR Creation Problems**:
   - Verify GitHub token permissions
   - Check for existing duplicate PRs
   - Review branch protection settings
   - **Debug**: Manual workflow dispatch with debug enabled

### Log Analysis
- **Build logs**: Available in GitHub Actions workflow runs
- **Test logs**: Stored in `test-logs/` directory
- **Version validation**: Use `validate-version-scripts.sh` output

## 🎯 AI Agent Guidelines

### When Working on This Repository:

1. **Always Test Version Scripts**: After any changes to `version.sh`, run validation
2. **Follow the PR-Centric Approach**: Never bypass the automation system
3. **Understand Version Classification**: Know the difference between major/minor changes
4. **Use the Make Script**: It's the universal interface for all operations
5. **Maintain Documentation**: Update README.md for significant changes

### Key Files to Monitor:
- `make` - Core build system
- `.github/workflows/upstream-monitor.yaml` - Main automation
- `.github/scripts/classify-version-change.sh` - Version logic
- `CHANGELOG.md` - Build history tracking
- Individual `*/version.sh` files - Version detection

### Integration Points:
- **GitHub Actions**: Workflows trigger on schedule and PR events
- **Docker Hub & GHCR**: Multi-registry publishing
- **Branch Protection**: All changes via PRs with optional auto-merge
- **Version Detection**: Multiple strategies for different software types

### Success Criteria:
- Version scripts work reliably with proper error handling
- Containers build successfully with the `make` script
- Automation workflows complete without manual intervention
- Branch protection rules are respected via PR-centric approach

---

**🎯 Remember**: This is a **production automation system**. Always test changes thoroughly and understand the impact on the automated workflows. The hybrid PR-centric approach ensures both speed and safety - respect this balance when making modifications.
