#!/usr/bin/env python3
"""Extract reader-visible text or JSON-LD script bodies from rendered HTML."""

import json
import sys
from html.parser import HTMLParser
from pathlib import Path


HIDDEN_ELEMENTS = {"script", "style", "template"}


class VisibleTextParser(HTMLParser):
    """Collect text a reader can see while ignoring hidden element contents."""

    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.hidden_depth = 0
        self.text_parts = []

    def handle_starttag(self, tag, attrs):
        if tag.lower() in HIDDEN_ELEMENTS:
            self.hidden_depth += 1

    def handle_endtag(self, tag):
        if tag.lower() in HIDDEN_ELEMENTS and self.hidden_depth:
            self.hidden_depth -= 1

    def handle_data(self, data):
        if not self.hidden_depth:
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
    if len(argv) != 3 or argv[1] not in {"text", "jsonld"}:
        print("usage: rendered-html.py {text|jsonld} <html-file>", file=sys.stderr)
        return 2

    command, path = argv[1:]
    parser = VisibleTextParser() if command == "text" else JsonLdParser()
    try:
        parse_html(path, parser)
    except RuntimeError as error:
        print(f"rendered-html.py: {error}", file=sys.stderr)
        return 1

    if command == "text":
        print("".join(parser.text_parts))
    else:
        print(json.dumps(parser.scripts))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
