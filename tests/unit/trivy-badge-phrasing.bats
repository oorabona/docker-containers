#!/usr/bin/env bats

load "../test_helper"

setup() {
    template_pattern='^[[:space:]]*\{%- capture trivy_full_label -%\}\{\{ trivy_count \}\} \{\{ trivy_aria_label \}\} finding\(s\) · scanned \{\{ trivy_scan_date \}\} · advisory mode \(does not block builds\)\{%- endcapture -%\}$'
    template_definition_pattern='^[[:space:]]*\{%[-]?[[:space:]]*(capture|assign)[[:space:]]+trivy_full_label([[:space:]]|[-}]).*$'
    template_aria_sink_pattern='^[[:space:]]*aria-label="\{\{ trivy_full_label \| escape \}\}"$'
    template_title_sink_pattern='^[[:space:]]*title="\{\{ trivy_full_label \| escape \}\}">.*$'
    template_aria_attribute_pattern='^[[:space:]]*aria-label=.*$'
    template_title_attribute_pattern='^[[:space:]]*title=.*$'
    javascript_label="      const fullLabel = displayCount + ' ' + ariaSeverity + ' finding(s) · scanned ' + date + ' · advisory mode (does not block builds)';"
    javascript_definition_pattern='^[[:space:]]*(const|let|var) fullLabel = .*$'
    javascript_title_sink='      el.title = fullLabel;'
    javascript_aria_sink="      el.setAttribute('aria-label', fullLabel);"
    javascript_title_assignment_pattern='^[[:space:]]*el\.title = .*$'
    javascript_aria_assignment_pattern="^[[:space:]]*el\.setAttribute\('aria-label', .*$"
}

# This source-level guard checks the producers and their sinks; it cannot show
# whether a rendered page ultimately displays the value.
@test "badge producers define the finding(s) label exactly once and never mention CVEs" {
    for badge_file in \
        "$PROJECT_ROOT/docs/site/_includes/container-card.html" \
        "$PROJECT_ROOT/docs/site/_layouts/container-detail.html"; do
        run grep -cxE "$template_definition_pattern" "$badge_file"
        [ "$status" -eq 0 ]
        [ "$output" -eq 1 ]

        run grep -qxE "$template_pattern" "$badge_file"
        [ "$status" -eq 0 ]

        run grep -qxE "$template_aria_sink_pattern" "$badge_file"
        [ "$status" -eq 0 ]

        run grep -qxE "$template_title_sink_pattern" "$badge_file"
        [ "$status" -eq 0 ]

        run sed -n '/capture trivy_full_label/,/{%- else -%}/p' "$badge_file"
        [ "$status" -eq 0 ]
        trivy_sink_block=$output

        run grep -cxE "$template_aria_attribute_pattern" <<<"$trivy_sink_block"
        [ "$status" -eq 0 ]
        [ "$output" -eq 1 ]

        run grep -cxE "$template_title_attribute_pattern" <<<"$trivy_sink_block"
        [ "$status" -eq 0 ]
        [ "$output" -eq 1 ]

        run grep -qi 'CVE' "$badge_file"
        [ "$status" -ne 0 ]
    done

    run grep -cxE "$javascript_definition_pattern" "$PROJECT_ROOT/docs/site/assets/js/components/trust-strip.js"
    [ "$status" -eq 0 ]
    [ "$output" -eq 1 ]

    run grep -qFx "$javascript_label" "$PROJECT_ROOT/docs/site/assets/js/components/trust-strip.js"
    [ "$status" -eq 0 ]

    run grep -qFx "$javascript_title_sink" "$PROJECT_ROOT/docs/site/assets/js/components/trust-strip.js"
    [ "$status" -eq 0 ]

    run grep -qFx "$javascript_aria_sink" "$PROJECT_ROOT/docs/site/assets/js/components/trust-strip.js"
    [ "$status" -eq 0 ]

    run sed -n "/const fullLabel = /,/el.removeAttribute('aria-hidden');/p" "$PROJECT_ROOT/docs/site/assets/js/components/trust-strip.js"
    [ "$status" -eq 0 ]
    javascript_sink_block=$output

    run grep -cxE "$javascript_title_assignment_pattern" <<<"$javascript_sink_block"
    [ "$status" -eq 0 ]
    [ "$output" -eq 1 ]

    run grep -cxE "$javascript_aria_assignment_pattern" <<<"$javascript_sink_block"
    [ "$status" -eq 0 ]
    [ "$output" -eq 1 ]

    run grep -qi 'CVE' "$PROJECT_ROOT/docs/site/assets/js/components/trust-strip.js"
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
