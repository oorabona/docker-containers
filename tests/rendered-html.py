#!/usr/bin/env python3
"""Extract rendered HTML text, JSON-LD script bodies, element counts, or attributes.

The text command emits text outside comments and outside the contents of script,
style, template, and noscript elements. It collapses runs of whitespace to one
space and concatenates text nodes in document order without adding separators
between elements. It models neither CSS nor runtime JavaScript, so it still
reads text in an element hidden by a stylesheet or by script.
The count and attribute commands likewise inspect elements only outside those
skipped subtrees.
Duplicate attributes are rejected only on elements a command inspects; markup
inside a skipped subtree is not read and cannot fail a run. Crossing closes and
unterminated skipped subtrees remain parse failures.
A skipped subtree closes only at its matching closing tag. Orphan closing tags
cannot end one.
The self-closing flag is ignored on an HTML element and honoured inside svg and
math, as a browser does.
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
FOREIGN_CONTENT_ELEMENTS = {"svg", "math"}


class ForeignContentParser(HTMLParser):
    """Track foreign content while dispatching self-closing tags."""

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.foreign_content_depth = 0
        self.foreign_content_tags = []

    def handle_foreign_content_starttag(self, tag):
        if tag in FOREIGN_CONTENT_ELEMENTS:
            self.foreign_content_tags.append(tag)
            self.foreign_content_depth += 1

    def handle_foreign_content_endtag(self, tag):
        if (
            self.foreign_content_tags
            and tag == self.foreign_content_tags[-1]
        ):
            self.foreign_content_tags.pop()
            self.foreign_content_depth -= 1

    def handle_startendtag(self, tag, attrs):
        self.handle_starttag(tag, attrs)
        if tag.lower() in VOID_ELEMENTS or self.foreign_content_depth:
            self.handle_endtag(tag)


class SkippedSubtreeParser(ForeignContentParser):
    """Track skipped subtrees shared by visible-text and selector parsers."""

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.skipped_tags = []

    def handle_startendtag(self, tag, attrs):
        super().handle_startendtag(tag, attrs)

    def handle_skipped_starttag(self, tag):
        if tag in HIDDEN_ELEMENTS:
            self.skipped_tags.append(tag)

    def handle_skipped_endtag(self, tag):
        if tag not in HIDDEN_ELEMENTS:
            return
        if tag not in self.skipped_tags:
            return
        if self.skipped_tags[-1] != tag:
            open_tag = self.skipped_tags[-1]
            raise ValueError(
                f"closing skipped element </{tag}> crosses open <{open_tag}>"
            )
        self.skipped_tags.pop()

    @property
    def in_skipped_subtree(self):
        return bool(self.skipped_tags)

    def close(self):
        super().close()
        # An unfinished skipped subtree can otherwise hide arbitrary trailing markup.
        if self.skipped_tags:
            raise ValueError(f"unterminated skipped element <{self.skipped_tags[-1]}>")


class VisibleTextParser(SkippedSubtreeParser):
    """Collect text outside comments and skipped element contents."""

    def __init__(self, within_id=None):
        super().__init__(convert_charrefs=True)
        self.within_id = within_id
        self.match_tag = None
        self.match_tag_depth = 0
        self.match_active = False
        self.match_count = 0
        self.text_parts = []

    def handle_starttag(self, tag, attrs):
        tag = tag.lower()
        self.handle_foreign_content_starttag(tag)
        inspects_element = (
            not self.in_skipped_subtree and tag not in HIDDEN_ELEMENTS
        )
        matches_within_id = False
        if self.within_id is not None and inspects_element:
            reject_duplicate_attribute(attrs, "id", tag)
            attributes = {name.lower(): value for name, value in attrs}
            if attributes.get("id") == self.within_id:
                matches_within_id = True
                self.match_count += 1
                if self.match_count == 1:
                    self.match_tag = tag
                    self.match_tag_depth = 1
                    self.match_active = tag not in VOID_ELEMENTS
        if (
            not matches_within_id
            and self.match_active
            and not self.in_skipped_subtree
            and tag == self.match_tag
            and tag not in VOID_ELEMENTS
        ):
            self.match_tag_depth += 1
        self.handle_skipped_starttag(tag)

    def handle_endtag(self, tag):
        tag = tag.lower()
        if self.in_skipped_subtree:
            self.handle_skipped_endtag(tag)
            self.handle_foreign_content_endtag(tag)
            return
        if self.match_active and tag == self.match_tag:
            self.match_tag_depth -= 1
            if self.match_tag_depth == 0:
                self.match_active = False
        self.handle_skipped_endtag(tag)
        self.handle_foreign_content_endtag(tag)

    def handle_data(self, data):
        in_requested_subtree = (
            self.within_id is None
            or self.match_active
        )
        if not self.in_skipped_subtree and in_requested_subtree:
            self.text_parts.append(data)

    def handle_comment(self, data):
        pass


class JsonLdParser(ForeignContentParser):
    """Collect the raw body of every application/ld+json script element."""

    def __init__(self):
        super().__init__(convert_charrefs=False)
        self.in_jsonld_script = False
        self.current_script = []
        self.scripts = []

    def handle_starttag(self, tag, attrs):
        tag = tag.lower()
        self.handle_foreign_content_starttag(tag)
        if tag != "script":
            return
        reject_duplicate_attribute(attrs, "type", "script")
        attributes = {name.lower(): value for name, value in attrs}
        script_type = attributes.get("type") or ""
        if script_type.lower() == "application/ld+json":
            self.in_jsonld_script = True
            self.current_script = []

    def handle_endtag(self, tag):
        tag = tag.lower()
        if tag == "script" and self.in_jsonld_script:
            self.scripts.append("".join(self.current_script))
            self.current_script = []
            self.in_jsonld_script = False
        self.handle_foreign_content_endtag(tag)

    def handle_data(self, data):
        if self.in_jsonld_script:
            self.current_script.append(data)

    def close(self):
        super().close()
        if self.in_jsonld_script:
            raise ValueError("unterminated application/ld+json script element")


class SelectorCountParser(SkippedSubtreeParser):
    """Count elements whose id or class token matches a requested value."""

    def __init__(self, selector_kind, value):
        super().__init__(convert_charrefs=True)
        self.selector_kind = selector_kind
        self.value = value
        self.count = 0

    def handle_starttag(self, tag, attrs):
        tag = tag.lower()
        self.handle_foreign_content_starttag(tag)
        attribute = "id" if self.selector_kind == "id" else "class"
        inspects_element = (
            not self.in_skipped_subtree and tag not in HIDDEN_ELEMENTS
        )
        if inspects_element:
            reject_duplicate_attribute(attrs, attribute, tag)
            attributes = {name.lower(): value for name, value in attrs}
            if self.selector_kind == "id":
                if attributes.get("id") == self.value:
                    self.count += 1
            elif self.value in (attributes.get("class") or "").split():
                self.count += 1
        self.handle_skipped_starttag(tag)

    def handle_endtag(self, tag):
        tag = tag.lower()
        self.handle_skipped_endtag(tag)
        self.handle_foreign_content_endtag(tag)


class AttributeParser(SkippedSubtreeParser):
    """Read one attribute from the one element matched by a selector."""

    def __init__(self, selector_kind, selector_value, attribute):
        super().__init__(convert_charrefs=True)
        self.selector_kind = selector_kind
        self.selector_value = selector_value
        self.attribute = attribute.lower()
        self.matches = []

    def handle_starttag(self, tag, attrs):
        tag = tag.lower()
        self.handle_foreign_content_starttag(tag)
        selector_attribute = "id" if self.selector_kind == "id" else "class"
        inspects_element = (
            not self.in_skipped_subtree and tag not in HIDDEN_ELEMENTS
        )
        if inspects_element:
            reject_duplicate_attribute(attrs, selector_attribute, tag)
            attributes = {name.lower(): value for name, value in attrs}
            matches_selector = (
                attributes.get("id") == self.selector_value
                if self.selector_kind == "id"
                else self.selector_value in (attributes.get("class") or "").split()
            )
            if matches_selector:
                reject_duplicate_attribute(attrs, self.attribute, tag)
                self.matches.append(attributes.get(self.attribute))
        self.handle_skipped_starttag(tag)

    def handle_endtag(self, tag):
        tag = tag.lower()
        self.handle_skipped_endtag(tag)
        self.handle_foreign_content_endtag(tag)


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
        "       rendered-html.py attribute <attribute> (--id <value> | --class <token>) <html-file>\n"
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
    attribute_command = (
        len(argv) == 6
        and argv[1] == "attribute"
        and argv[3] in {"--id", "--class"}
    )
    if not (text_command or within_text_command or jsonld_command or count_command or attribute_command):
        usage()
        return 2

    command = argv[1]
    within_id = argv[3] if within_text_command else None
    path = argv[-1]
    if command == "text":
        parser = VisibleTextParser(within_id)
    elif command == "jsonld":
        parser = JsonLdParser()
    elif command == "attribute":
        parser = AttributeParser(argv[3][2:], argv[4], argv[2])
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
    elif command == "attribute":
        selector = f"{argv[3]} {argv[4]!r}"
        if len(parser.matches) == 0:
            print(f"rendered-html.py: no element matches {selector}", file=sys.stderr)
            return 1
        if len(parser.matches) > 1:
            print(f"rendered-html.py: more than one element matches {selector}", file=sys.stderr)
            return 1
        if parser.matches[0] is None:
            print(
                f"rendered-html.py: element matching {selector} has no {argv[2]} attribute",
                file=sys.stderr,
            )
            return 1
        print(parser.matches[0])
    else:
        print(parser.count)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
