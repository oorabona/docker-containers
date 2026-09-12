#!/usr/bin/env python3
"""Extract rendered HTML text, JSON-LD script bodies, or element counts.

The text command emits text outside comments and outside the contents of script,
style, template, and noscript elements. It collapses runs of whitespace to one
space and concatenates text nodes in document order without adding separators
between elements. It models neither CSS nor runtime JavaScript, so it still
reads text in an element hidden by a stylesheet or by script.
The count command likewise counts elements only outside those skipped subtrees.
"""

import json
import sys
from html.parser import HTMLParser
from pathlib import Path


HIDDEN_ELEMENTS = {"script", "style", "template", "noscript"}
VOID_ELEMENTS = {
    "area", "base", "br", "col", "embed", "hr", "img", "input", "link",
    "meta", "param", "source", "track", "wbr",
}


class VisibleTextParser(HTMLParser):
    """Collect text outside comments and skipped element contents."""

    def __init__(self, within_id=None):
        super().__init__(convert_charrefs=True)
        self.within_id = within_id
        self.hidden_depth = 0
        self.match_tag = None
        self.match_tag_depth = 0
        self.match_active = False
        self.match_count = 0
        self.text_parts = []

    def handle_starttag(self, tag, attrs):
        tag = tag.lower()
        reject_duplicate_attribute(attrs, "id", tag)
        attributes = {name.lower(): value for name, value in attrs}
        if self.within_id is not None and attributes.get("id") == self.within_id:
            self.match_count += 1
            if self.match_count == 1:
                self.match_tag = tag
                self.match_tag_depth = 1
                self.match_active = tag not in VOID_ELEMENTS
        elif self.match_active and tag == self.match_tag and tag not in VOID_ELEMENTS:
            self.match_tag_depth += 1
        if tag in HIDDEN_ELEMENTS:
            self.hidden_depth += 1

    def handle_endtag(self, tag):
        tag = tag.lower()
        if self.match_active and tag == self.match_tag:
            self.match_tag_depth -= 1
            if self.match_tag_depth == 0:
                self.match_active = False
        if tag in HIDDEN_ELEMENTS and self.hidden_depth:
            self.hidden_depth -= 1

    def handle_data(self, data):
        in_requested_subtree = (
            self.within_id is None
            or self.match_active
        )
        if not self.hidden_depth and in_requested_subtree:
            self.text_parts.append(data)

    def handle_comment(self, data):
        pass


class JsonLdParser(HTMLParser):
    """Collect the raw body of every application/ld+json script element."""

    def __init__(self):
        super().__init__(convert_charrefs=False)
        self.in_jsonld_script = False
        self.current_script = []
        self.scripts = []

    def handle_starttag(self, tag, attrs):
        if tag.lower() != "script":
            return
        reject_duplicate_attribute(attrs, "type", "script")
        attributes = {name.lower(): value for name, value in attrs}
        script_type = attributes.get("type") or ""
        if script_type.lower() == "application/ld+json":
            self.in_jsonld_script = True
            self.current_script = []

    def handle_endtag(self, tag):
        if tag.lower() == "script" and self.in_jsonld_script:
            self.scripts.append("".join(self.current_script))
            self.current_script = []
            self.in_jsonld_script = False

    def handle_data(self, data):
        if self.in_jsonld_script:
            self.current_script.append(data)

    def close(self):
        super().close()
        if self.in_jsonld_script:
            raise ValueError("unterminated application/ld+json script element")


class SelectorCountParser(HTMLParser):
    """Count elements whose id or class token matches a requested value."""

    def __init__(self, selector_kind, value):
        super().__init__(convert_charrefs=True)
        self.selector_kind = selector_kind
        self.value = value
        self.count = 0
        self.hidden_depth = 0

    def handle_starttag(self, tag, attrs):
        tag = tag.lower()
        attribute = "id" if self.selector_kind == "id" else "class"
        reject_duplicate_attribute(attrs, attribute, tag)
        attributes = {name.lower(): value for name, value in attrs}
        if not self.hidden_depth and tag not in HIDDEN_ELEMENTS and self.selector_kind == "id":
            if attributes.get("id") == self.value:
                self.count += 1
        elif (
            not self.hidden_depth
            and tag not in HIDDEN_ELEMENTS
            and self.value in (attributes.get("class") or "").split()
        ):
            self.count += 1
        if tag in HIDDEN_ELEMENTS:
            self.hidden_depth += 1

    def handle_endtag(self, tag):
        if tag.lower() in HIDDEN_ELEMENTS and self.hidden_depth:
            self.hidden_depth -= 1


def reject_duplicate_attribute(attrs, attribute, tag):
    """Reject attributes this parser reads for a decision when repeated."""
    if sum(name.lower() == attribute for name, _value in attrs) > 1:
        raise ValueError(f"{tag} element has more than one {attribute} attribute")


def parse_html(path, parser):
    try:
        markup = Path(path).read_text(encoding="utf-8")
    except (OSError, UnicodeError) as error:
        raise RuntimeError(f"cannot read {path}: {error}") from error

    try:
        parser.feed(markup)
        parser.close()
    except Exception as error:  # HTMLParser exposes parsing failures as exceptions.
        raise RuntimeError(f"cannot parse {path}: {error}") from error


def usage():
    print(
        "usage: rendered-html.py text <html-file>\n"
        "       rendered-html.py text --within <element-id> <html-file>\n"
        "       rendered-html.py jsonld <html-file>\n"
        "       rendered-html.py count (--id <value> | --class <token>) <html-file>\n"
        "text reads text outside comments and script, style, template, and noscript contents; "
        "it collapses whitespace and concatenates document-order text nodes without element "
        "separators. It models neither CSS nor runtime JavaScript, so it reads elements hidden "
        "by a stylesheet or by script.",
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
    if not (text_command or within_text_command or jsonld_command or count_command):
        usage()
        return 2

    command = argv[1]
    within_id = argv[3] if within_text_command else None
    path = argv[-1]
    if command == "text":
        parser = VisibleTextParser(within_id)
    elif command == "jsonld":
        parser = JsonLdParser()
    else:
        parser = SelectorCountParser(argv[2][2:], argv[3])
    try:
        parse_html(path, parser)
    except RuntimeError as error:
        print(f"rendered-html.py: {error}", file=sys.stderr)
        return 1

    if command == "text":
        if within_id is not None:
            if parser.match_count == 0:
                print(f"rendered-html.py: no element has id={within_id!r}", file=sys.stderr)
                return 1
            if parser.match_count > 1:
                print(
                    f"rendered-html.py: more than one element has id={within_id!r}",
                    file=sys.stderr,
                )
                return 1
        print(" ".join("".join(parser.text_parts).split()))
    elif command == "jsonld":
        print(json.dumps(parser.scripts))
    else:
        print(parser.count)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
