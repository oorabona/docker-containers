#!/usr/bin/env python3
"""Extract rendered HTML text or JSON-LD script bodies.

The text command emits everything outside comments and outside the contents of
script, style, and template elements. It evaluates neither CSS nor runtime
JavaScript, so text in an element hidden by a stylesheet or script is included.
"""

import json
import sys
from html.parser import HTMLParser
from pathlib import Path


HIDDEN_ELEMENTS = {"script", "style", "template"}
VOID_ELEMENTS = {
    "area", "base", "br", "col", "embed", "hr", "img", "input", "link",
    "meta", "param", "source", "track", "wbr",
}


class VisibleTextParser(HTMLParser):
    """Collect text outside comments and hidden element contents."""

    def __init__(self, within_id=None):
        super().__init__(convert_charrefs=True)
        self.within_id = within_id
        self.hidden_depth = 0
        self.element_depth = 0
        self.match_depth = None
        self.match_active = False
        self.match_count = 0
        self.text_parts = []

    def handle_starttag(self, tag, attrs):
        tag = tag.lower()
        if tag == "script":
            reject_duplicate_script_type(attrs)
        attributes = {name.lower(): value for name, value in attrs}
        if self.within_id is not None and attributes.get("id") == self.within_id:
            self.match_count += 1
            if self.match_count == 1:
                self.match_depth = self.element_depth
                self.match_active = tag not in VOID_ELEMENTS
        if tag in HIDDEN_ELEMENTS:
            self.hidden_depth += 1
        if tag not in VOID_ELEMENTS:
            self.element_depth += 1

    def handle_endtag(self, tag):
        tag = tag.lower()
        if tag not in VOID_ELEMENTS:
            self.element_depth -= 1
        if self.match_active and self.element_depth == self.match_depth:
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
        reject_duplicate_script_type(attrs)
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


def reject_duplicate_script_type(attrs):
    """Reject script type attributes browsers and this parser could interpret differently."""
    if sum(name.lower() == "type" for name, _value in attrs) > 1:
        raise ValueError("script element has more than one type attribute")


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


def main(argv):
    if (
        len(argv) not in {3, 5}
        or argv[1] not in {"text", "jsonld"}
        or (len(argv) == 5 and (argv[1] != "text" or argv[2] != "--within"))
    ):
        print(
            "usage: rendered-html.py text [--within <element-id>] <html-file>\n"
            "       rendered-html.py jsonld <html-file>",
            file=sys.stderr,
        )
        return 2

    command = argv[1]
    within_id = argv[3] if len(argv) == 5 else None
    path = argv[-1]
    parser = VisibleTextParser(within_id) if command == "text" else JsonLdParser()
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
    else:
        print(json.dumps(parser.scripts))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
