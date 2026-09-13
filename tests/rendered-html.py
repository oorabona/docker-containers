#!/usr/bin/env python3
"""Extract rendered HTML text, JSON-LD script bodies, element counts, or attributes.

The document is parsed by a conforming HTML5 tree constructor. Foreign content,
breakout tags, integration points, and error recovery therefore follow the HTML
specification. The text command excludes comments and the contents of HTML
script, style, template, and noscript elements. It collapses runs of whitespace
to one space and concatenates text nodes in document order without adding
separators between elements.

This reports what the document contains, not what CSS paints: display,
visibility, hidden, and aria-hidden are not consulted. Runtime JavaScript is
also outside this extractor's model.
"""

import json
import sys
from pathlib import Path

try:
    import html5lib
except ImportError:
    html5lib = None


HIDDEN_ELEMENTS = {"script", "style", "template", "noscript"}
NO_MATCH_STATUS = 3


def is_hidden_element(element):
    """Return whether an HTML element's descendants are not rendered here."""
    return element.tag in HIDDEN_ELEMENTS


def visible_text(element):
    """Yield text and tails in document order, excluding hidden HTML subtrees."""
    if is_hidden_element(element):
        return
    if element.text:
        yield element.text
    for child in element:
        yield from visible_text(child)
        if child.tail:
            yield child.tail


def inspected_elements(tree):
    """Yield elements outside hidden HTML subtrees in document order."""
    def walk(element):
        if is_hidden_element(element):
            return
        yield element
        for child in element:
            yield from walk(child)

    return walk(tree)


def matches_selector(element, selector_kind, value):
    if selector_kind == "id":
        return element.get("id") == value
    return value in (element.get("class") or "").split()


def parse_html(path):
    try:
        with Path(path).open("rb") as handle:
            return html5lib.parse(
                handle,
                treebuilder="etree",
                namespaceHTMLElements=False,
            )
    except (OSError, UnicodeError) as error:
        raise RuntimeError(f"cannot read {path}: {error}") from error
    except Exception as error:
        raise RuntimeError(f"cannot parse {path}: {error}") from error


def usage():
    print(
        "usage: rendered-html.py text <html-file>\n"
        "       rendered-html.py text --within <element-id> <html-file>\n"
        "       rendered-html.py jsonld <html-file>\n"
        "       rendered-html.py count (--id <value> | --class <token>) <html-file>\n"
        "       rendered-html.py attribute <attribute> (--id <value> | --class <token>) <html-file>\n"
        "text reads text outside comments and HTML script, style, template, and noscript "
        "contents; it collapses whitespace and concatenates document-order text nodes without "
        "element separators. It reports document contents rather than CSS-painted output, so "
        "display, visibility, hidden, and aria-hidden are not consulted.",
        file=sys.stderr,
    )


def main(argv):
    text_command = len(argv) == 3 and argv[1] == "text" and argv[2] != "--within"
    within_text_command = (
        len(argv) == 5 and argv[1] == "text" and argv[2] == "--within"
    )
    jsonld_command = len(argv) == 3 and argv[1] == "jsonld"
    count_command = (
        len(argv) == 5
        and argv[1] == "count"
        and argv[2] in {"--id", "--class"}
    )
    attribute_command = (
        len(argv) == 6
        and argv[1] == "attribute"
        and argv[3] in {"--id", "--class"}
    )
    if not (text_command or within_text_command or jsonld_command or count_command or attribute_command):
        usage()
        return 2
    if html5lib is None:
        print(
            "rendered-html.py: html5lib module is required; install it with "
            "python3 -m pip install html5lib==1.1",
            file=sys.stderr,
        )
        return 1

    command = argv[1]
    within_id = argv[3] if within_text_command else None
    path = argv[-1]
    try:
        tree = parse_html(path)
    except RuntimeError as error:
        print(f"rendered-html.py: {error}", file=sys.stderr)
        return 1

    elements = list(inspected_elements(tree))
    if command == "text":
        root = tree
        if within_id is not None:
            matches = [element for element in elements if element.get("id") == within_id]
            if len(matches) == 0:
                print(f"rendered-html.py: no element has id={within_id!r}", file=sys.stderr)
                return NO_MATCH_STATUS
            if len(matches) > 1:
                print(
                    f"rendered-html.py: more than one element has id={within_id!r}",
                    file=sys.stderr,
                )
                return NO_MATCH_STATUS
            root = matches[0]
        print(" ".join("".join(visible_text(root)).split()))
    elif command == "jsonld":
        scripts = [
            element.text or ""
            for element in tree.iter("script")
            if (element.get("type") or "").lower() == "application/ld+json"
        ]
        print(json.dumps(scripts))
    elif command == "attribute":
        selector_kind = argv[3][2:]
        selector_value = argv[4]
        matches = [
            element
            for element in elements
            if matches_selector(element, selector_kind, selector_value)
        ]
        selector = f"{argv[3]} {selector_value!r}"
        if len(matches) == 0:
            print(f"rendered-html.py: no element matches {selector}", file=sys.stderr)
            return NO_MATCH_STATUS
        if len(matches) > 1:
            print(f"rendered-html.py: more than one element matches {selector}", file=sys.stderr)
            return NO_MATCH_STATUS
        value = matches[0].get(argv[2].lower())
        if value is None:
            print(
                f"rendered-html.py: element matching {selector} has no {argv[2]} attribute",
                file=sys.stderr,
            )
            return NO_MATCH_STATUS
        print(value)
    elif command == "count":
        selector_kind = argv[2][2:]
        print(sum(matches_selector(element, selector_kind, argv[3]) for element in elements))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
