#!/usr/bin/env bats

load "../test_helper"

setup() {
    template_pattern='^[[:space:]]*\{%- capture trivy_full_label -%\}\{\{ trivy_count \}\} \{\{ trivy_aria_label \}\} finding\(s\) · scanned \{\{ trivy_scan_date \}\} · advisory mode \(does not block builds\)\{%- endcapture -%\}$'
    javascript_label="      const fullLabel = displayCount + ' ' + ariaSeverity + ' finding(s) · scanned ' + date + ' · advisory mode (does not block builds)';"
}

@test "card badge source label calls severity results findings, not CVEs" {
    run grep -qxE "$template_pattern" "$PROJECT_ROOT/docs/site/_includes/container-card.html"
    [ "$status" -eq 0 ]

    run grep -q 'CVE' "$PROJECT_ROOT/docs/site/_includes/container-card.html"
    [ "$status" -ne 0 ]
}

@test "all three badge producers use the same finding(s) wording" {
    run grep -qxE "$template_pattern" "$PROJECT_ROOT/docs/site/_includes/container-card.html"
    [ "$status" -eq 0 ]

    run grep -qxE "$template_pattern" "$PROJECT_ROOT/docs/site/_layouts/container-detail.html"
    [ "$status" -eq 0 ]

    run grep -qFx "$javascript_label" "$PROJECT_ROOT/docs/site/assets/js/components/trust-strip.js"
    [ "$status" -eq 0 ]
}
