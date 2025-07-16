#!/bin/bash

# Update CHANGELOG.md with proper section management
# Usage: update-changelog.sh <container> <old_version> <new_version> <change_type>

set -euo pipefail

CONTAINER="$1"
OLD_VERSION="$2"
NEW_VERSION="$3"
CHANGE_TYPE="$4"
CHANGELOG_FILE="CHANGELOG.md"

# Get current date in YYYY-MM-DD format
CURRENT_DATE=$(date -u +"%Y-%m-%d")

# Determine the section based on change type
if [[ "$CHANGE_TYPE" == "major" ]]; then
    SECTION_NAME="PR Review Required (Major Updates)"
    ICON="📝"
else
    SECTION_NAME="Auto-Built (Minor/Patch Updates)"
    ICON="🚀"
fi

# Create the entry line
ENTRY_LINE="- ${ICON} **${CONTAINER}**: \`${OLD_VERSION}\` → \`${NEW_VERSION}\` ($(date -u '+%H:%M UTC'))"

# Function to update or create date section
update_changelog() {
    local temp_file
    temp_file=$(mktemp)
    
    # Check if the date section exists
    if grep -q "^## ${CURRENT_DATE}$" "$CHANGELOG_FILE"; then
        # Date section exists, check if our subsection exists
        if sed -n "/^## ${CURRENT_DATE}$/,/^## /p" "$CHANGELOG_FILE" | grep -q "^### ${SECTION_NAME}$"; then
            # Both date and subsection exist, add entry under the subsection
            awk -v date="$CURRENT_DATE" -v section="$SECTION_NAME" -v entry="$ENTRY_LINE" '
            BEGIN { found_date = 0; found_section = 0; added = 0 }
            
            # Found the date section
            /^## / {
                if ($0 == "## " date) {
                    found_date = 1
                    print $0
                    next
                } else if (found_date && !added) {
                    # We hit another date section, add our entry before it
                    print ""
                    print $0
                    next
                } else {
                    found_date = 0
                }
                print $0
                next
            }
            
            # Found our subsection within the date
            found_date && /^### / {
                if ($0 == "### " section) {
                    found_section = 1
                    print $0
                    next
                } else if (found_section && !added) {
                    # Hit another subsection, add entry before it
                    print entry
                    print ""
                    added = 1
                    found_section = 0
                    print $0
                    next
                } else {
                    found_section = 0
                }
                print $0
                next
            }
            
            # Add entry after "_No builds yet_" or at end of section
            found_section && /_No builds yet_/ {
                print entry
                added = 1
                found_section = 0
                next
            }
            
            # Add entry before horizontal rule or end of section
            found_section && /^---$/ {
                if (!added) {
                    print entry
                    print ""
                    added = 1
                }
                found_section = 0
                print $0
                next
            }
            
            # Regular line
            { print $0 }
            
            END {
                if (found_section && !added) {
                    print entry
                }
            }
            ' "$CHANGELOG_FILE" > "$temp_file"
        else
            # Date section exists but not our subsection, add it
            awk -v date="$CURRENT_DATE" -v section="$SECTION_NAME" -v entry="$ENTRY_LINE" '
            BEGIN { found_date = 0; added = 0 }
            
            /^## / {
                if ($0 == "## " date) {
                    found_date = 1
                    print $0
                    print ""
                    print "### " section
                    print entry
                    print ""
                    added = 1
                    next
                } else if (found_date) {
                    # Hit another date section
                    found_date = 0
                }
                print $0
                next
            }
            
            # Add before horizontal rule if we found date but no other sections
            found_date && /^---$/ {
                if (!added) {
                    print "### " section
                    print entry
                    print ""
                    added = 1
                }
                found_date = 0
                print $0
                next
            }
            
            { print $0 }
            ' "$CHANGELOG_FILE" > "$temp_file"
        fi
    else
        # Date section doesn't exist, create it at the top
        awk -v date="$CURRENT_DATE" -v section="$SECTION_NAME" -v entry="$ENTRY_LINE" '
        BEGIN { added = 0 }
        
        # Insert after the header but before first existing date section
        /^## [0-9]{4}-[0-9]{2}-[0-9]{2}$/ && !added {
            print "## " date
            print ""
            print "### " section
            print entry
            print ""
            print "### " (section == "Auto-Built (Minor/Patch Updates)" ? "PR Review Required (Major Updates)" : "Auto-Built (Minor/Patch Updates)")
            print "_No builds yet_"
            print ""
            print $0
            added = 1
            next
        }
        
        # If no date sections found, add after initial description
        /^---$/ && !added {
            print "## " date
            print ""
            print "### " section
            print entry
            print ""
            print "### " (section == "Auto-Built (Minor/Patch Updates)" ? "PR Review Required (Major Updates)" : "Auto-Built (Minor/Patch Updates)")
            print "_No builds yet_"
            print ""
            print $0
            added = 1
            next
        }
        
        { print $0 }
        ' "$CHANGELOG_FILE" > "$temp_file"
    fi
    
    # Replace original file with updated content
    mv "$temp_file" "$CHANGELOG_FILE"
}

# Validate inputs
if [[ -z "$CONTAINER" || -z "$OLD_VERSION" || -z "$NEW_VERSION" || -z "$CHANGE_TYPE" ]]; then
    echo "Error: Missing required arguments"
    echo "Usage: $0 <container> <old_version> <new_version> <change_type>"
    exit 1
fi

if [[ ! -f "$CHANGELOG_FILE" ]]; then
    echo "Error: CHANGELOG.md not found"
    exit 1
fi

# Validate change type
if [[ "$CHANGE_TYPE" != "major" && "$CHANGE_TYPE" != "minor" && "$CHANGE_TYPE" != "patch" ]]; then
    echo "Error: change_type must be 'major', 'minor', or 'patch'"
    exit 1
fi

# Update the changelog
echo "Updating CHANGELOG.md: $CONTAINER $OLD_VERSION -> $NEW_VERSION ($CHANGE_TYPE)"
update_changelog

echo "CHANGELOG.md updated successfully"
