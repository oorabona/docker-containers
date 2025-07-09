#!/bin/bash

echo "🗑️  Repository Cleanup Script"
echo "============================"
echo ""

# Files and directories to remove (revised list)
items_to_remove=(
    ".env"                         # Local env file (use .env.example as template)
    "debian/debian-sid.tar.gz"
    "debian/installed-packages.txt"
    "nginx-rancher-rp/"
    "ssh-audit/"
    "ansible/LAST_REBUILD.md"
    "terraform/LAST_REBUILD.md"
    "celebrate-completion.sh"      # One-time celebration script
    "test-version-scripts.sh"      # Redundant with validate-version-scripts.sh
)

echo "📋 Files/directories to be removed:"
for item in "${items_to_remove[@]}"; do
    if [[ -e "$item" ]]; then
        echo "  ✅ $item (exists)"
    else
        echo "  ❌ $item (not found)"
    fi
done

echo ""
read -p "🤔 Do you want to proceed with removal? (y/N): " -r
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "❌ Cleanup cancelled."
    exit 0
fi

echo ""
echo "🗑️  Removing files and directories..."

removed_count=0
for item in "${items_to_remove[@]}"; do
    if [[ -e "$item" ]]; then
        rm -rf "$item"
        echo "  ✅ Removed: $item"
        removed_count=$((removed_count + 1))
    else
        echo "  ⚠️  Not found: $item"
    fi
done

echo ""
echo "📊 Cleanup Summary:"
echo "  - Items removed: $removed_count"
echo "  - Repository size reduced"
echo "  - .gitignore updated"
echo "  - .dockerignore created"

echo ""
echo "🎯 Next steps:"
echo "  1. Copy .env.example to .env and customize: cp .env.example .env"
echo "  2. Review git status: git status"
echo "  3. Commit changes: git add . && git commit -m 'cleanup: remove dev artifacts and redundant scripts'"
echo "  4. Run audit: ./audit-containers.sh"

echo ""
echo "✅ Repository cleanup complete!"
echo "   Your repo is now production-ready and clutter-free! 🎉"
