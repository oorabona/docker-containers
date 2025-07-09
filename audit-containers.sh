#!/bin/bash

echo "🔍 Container Audit Report"
echo "========================="
echo ""

total_containers=0
outdated_containers=()
missing_version_scripts=()
missing_readmes=()

for dir in */; do
    if [[ -f "$dir/Dockerfile" && -d "$dir" ]]; then
        container=$(basename "$dir")
        total_containers=$((total_containers + 1))
        echo "📦 $container"
        
        # Check base image
        base_image=$(grep -m1 "^FROM" "$dir/Dockerfile" | awk '{print $2}')
        echo "  📋 Base: $base_image"
        
        # Check age indicators
        if echo "$base_image" | grep -q "jessie\|stretch\|ubuntu:14\|ubuntu:16\|ubuntu:18\|debian:8\|debian:9"; then
            echo "  ⚠️  OUTDATED base image"
            outdated_containers+=("$container")
        elif echo "$base_image" | grep -q "ubuntu:20\|ubuntu:22\|ubuntu:24\|bookworm\|bullseye"; then
            echo "  ✅ Modern base image"
        else
            echo "  ❓ Check base image age"
        fi
        
        # Check for version script
        if [[ -f "$dir/version.sh" ]]; then
            echo "  ✅ Has version script"
            # Test if executable
            if [[ -x "$dir/version.sh" ]]; then
                echo "  ✅ Version script is executable"
            else
                echo "  ⚠️  Version script not executable"
            fi
        else
            echo "  ❌ Missing version script"
            missing_version_scripts+=("$container")
        fi
        
        # Check for documentation
        if [[ -f "$dir/README.md" ]]; then
            echo "  ✅ Has README"
        else
            echo "  ❌ Missing README"
            missing_readmes+=("$container")
        fi
        
        # Check for compose file
        if [[ -f "$dir/docker-compose.yml" ]]; then
            echo "  ✅ Has docker-compose"
        elif [[ -f "$dir/compose.yml" ]]; then
            echo "  ✅ Has compose.yml"
        else
            echo "  ❓ No compose file"
        fi
        
        # Check for healthcheck
        if grep -q "HEALTHCHECK" "$dir/Dockerfile"; then
            echo "  ✅ Has healthcheck"
        else
            echo "  ⚠️  Missing healthcheck"
        fi
        
        echo ""
    fi
done

echo "📊 Summary"
echo "=========="
echo "Total containers: $total_containers"
echo "Outdated base images: ${#outdated_containers[@]}"
echo "Missing version scripts: ${#missing_version_scripts[@]}"
echo "Missing READMEs: ${#missing_readmes[@]}"
echo ""

if [[ ${#outdated_containers[@]} -gt 0 ]]; then
    echo "⚠️  Containers with outdated base images:"
    printf '  - %s\n' "${outdated_containers[@]}"
    echo ""
fi

if [[ ${#missing_version_scripts[@]} -gt 0 ]]; then
    echo "❌ Containers missing version scripts:"
    printf '  - %s\n' "${missing_version_scripts[@]}"
    echo ""
fi

if [[ ${#missing_readmes[@]} -gt 0 ]]; then
    echo "❌ Containers missing READMEs:"
    printf '  - %s\n' "${missing_readmes[@]}"
    echo ""
fi

echo "🎯 Next Steps:"
echo "1. Update outdated base images"
echo "2. Create missing version scripts"
echo "3. Add missing READMEs"
echo "4. Add healthchecks to Dockerfiles"
