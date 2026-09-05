#!/usr/bin/env bats

load "../test_helper"

setup() {
    template_pattern='^[[:space:]]*\{%- capture trivy_full_label -%\}\{\{ trivy_count \}\} \{\{ trivy_aria_label \}\} finding\(s\) · scanned \{\{ trivy_scan_date \}\} · advisory mode \(does not block builds\)\{%- endcapture -%\}$'
    template_definition_pattern='^[[:space:]]*\{%- capture trivy_full_label -%\}.*\{%- endcapture -%\}$'
    javascript_label="      const fullLabel = displayCount + ' ' + ariaSeverity + ' finding(s) · scanned ' + date + ' · advisory mode (does not block builds)';"
    javascript_definition_pattern='^[[:space:]]*(const|let|var) fullLabel = .*$'
    documentation_phrase='The badge shows the count of findings in its active severity bucket: CRITICAL when non-zero, otherwise HIGH. One CVE affecting multiple packages contributes multiple findings. Use the count as input to your image-acceptance policy, not as a blocking gate.'
    documentation_cve_count_pattern='(CVE(s)?|vulnerabilit(y|ies))[^.]*(count|number)|(count|number)[^.]*(CVE(s)?|vulnerabilit(y|ies))'
}

@test "badge producers define the finding(s) label exactly once and never mention CVEs" {
    for badge_file in \
        "$PROJECT_ROOT/docs/site/_includes/container-card.html" \
        "$PROJECT_ROOT/docs/site/_layouts/container-detail.html"; do
        run grep -cxE "$template_definition_pattern" "$badge_file"
        [ "$status" -eq 0 ]
        [ "$output" -eq 1 ]

        run grep -qxE "$template_pattern" "$badge_file"
        [ "$status" -eq 0 ]

        run grep -q 'CVE' "$badge_file"
        [ "$status" -ne 0 ]
    done

    run grep -cxE "$javascript_definition_pattern" "$PROJECT_ROOT/docs/site/assets/js/components/trust-strip.js"
    [ "$status" -eq 0 ]
    [ "$output" -eq 1 ]

    run grep -qFx "$javascript_label" "$PROJECT_ROOT/docs/site/assets/js/components/trust-strip.js"
    [ "$status" -eq 0 ]

    run grep -q 'CVE' "$PROJECT_ROOT/docs/site/assets/js/components/trust-strip.js"
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

@test "verification documentation describes findings in the active severity bucket" {
    for documentation_file in \
        "$PROJECT_ROOT/docs/site/verify-images.md" \
        "$PROJECT_ROOT/docs/site/_includes/components/verify-walkthrough.html" \
        "$PROJECT_ROOT/docs/site/_includes/jsonld-faq.html"; do
        run grep -qF "$documentation_phrase" "$documentation_file"
        [ "$status" -eq 0 ]

        run grep -qiE "$documentation_cve_count_pattern" "$documentation_file"
        [ "$status" -ne 0 ]
    done
}
