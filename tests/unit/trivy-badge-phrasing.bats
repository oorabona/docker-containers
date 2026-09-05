#!/usr/bin/env bats

load "../test_helper"

setup() {
    template_pattern='^[[:space:]]*\{%- capture trivy_full_label -%\}\{\{ trivy_count \}\} \{\{ trivy_aria_label \}\} finding\(s\) · scanned \{\{ trivy_scan_date \}\} · advisory mode \(does not block builds\)\{%- endcapture -%\}$'
    javascript_label="      const fullLabel = displayCount + ' ' + ariaSeverity + ' finding(s) · scanned ' + date + ' · advisory mode (does not block builds)';"
}

# This source-level guard proves the label lines say finding(s). It does not
# prove which line renders, nor what a sink ultimately displays.
@test "badge producers define matching finding(s) label lines" {
    for badge_file in \
        "$PROJECT_ROOT/docs/site/_includes/container-card.html" \
        "$PROJECT_ROOT/docs/site/_layouts/container-detail.html"; do
        run grep -qxE "$template_pattern" "$badge_file"
        [ "$status" -eq 0 ]
    done

    run grep -qFx "$javascript_label" "$PROJECT_ROOT/docs/site/assets/js/components/trust-strip.js"
    [ "$status" -eq 0 ]
}
