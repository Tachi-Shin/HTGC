#!/usr/bin/env python3
"""Parse HTML/CSS files and lower them to the HTGC view tree."""

from dataclasses import dataclass, field
from html.parser import HTMLParser
from pathlib import Path
import re
from urllib.parse import unquote, urlsplit


class CompileError(ValueError):
    pass


BOX_TAGS = set("body main header footer nav section article div ul li aside figure figcaption address ol".split())
TEXT_TAGS = set("h1 h2 h3 h4 h5 h6 p span strong small label code b a".split())
META_TAGS = {"html", "head", "title", "style"}
VOID_TAGS = {"meta", "link"}
SOURCE_TAGS = {"include"}


@dataclass
class Element:
    tag: str
    attrs: dict[str, str | None]
    line: int
    source: Path
    children: list["Element | str"] = field(default_factory=list)
    preserve_space: bool = False


class Document(HTMLParser):
    def __init__(self, source, path):
        super().__init__(convert_charrefs=True)
        self.path = path
        self.root = Element("", {}, 1, path)
        self.stack = [self.root]
        self.feed(source)
        self.close()
        if len(self.stack) != 1:
            node = self.stack[-1]
            raise CompileError(f"{node.source}:{node.line}: <{node.tag}> が閉じていません")

    def handle_starttag(self, tag, attrs):
        line = self.getpos()[0]
        if tag not in BOX_TAGS | TEXT_TAGS | META_TAGS | VOID_TAGS | SOURCE_TAGS:
            raise CompileError(f"HTML {line}行目 <{tag}> は未対応です")
        attributes = dict(attrs)
        if any(name.startswith("on") for name in attributes):
            raise CompileError(f"HTML {line}行目 イベント属性は未対応です")
        node = Element(tag, attributes, line, self.path)
        self.stack[-1].children.append(node)
        if tag not in VOID_TAGS:
            self.stack.append(node)

    def handle_startendtag(self, tag, attrs):
        self.handle_starttag(tag, attrs)
        if tag not in VOID_TAGS:
            self.handle_endtag(tag)

    def handle_endtag(self, tag):
        if self.stack[-1].tag != tag or len(self.stack) == 1:
            raise CompileError(f"HTML {self.getpos()[0]}行目 予期しない </{tag}>")
        self.stack.pop()

    def handle_data(self, data):
        self.stack[-1].children.append(data)


PROPERTIES = {
    "display", "flex-direction", "justify-content", "align-items", "gap", "flex-grow",
    "padding", "margin", "width", "height", "background-color", "border-radius",
    "border-bottom", "color", "font-size", "font-weight", "text-align", "font-family",
}
IDENT = r"[a-zA-Z_][\w-]*"
COMPOUND = re.compile(rf"(?:{IDENT}|\*)?(?:[.#]{IDENT})*")
SELECTOR_TOKEN = re.compile(rf"[.#]?{IDENT}")


def parse_declarations(source):
    result = {}
    for entry in source.split(";"):
        if not entry.strip():
            continue
        name, colon, value = entry.partition(":")
        name, value = name.strip().lower(), value.strip().lower()
        if name == "background":
            name = "background-color"
        if not colon or name not in PROPERTIES or not value or "!" in value:
            raise CompileError(f"未対応または不正なCSS宣言 {entry.strip()!r}")
        validate_declaration(name, value)
        result[name] = value
    return result


def parse_rules(source):
    source = re.sub(r"/\*.*?\*/", "", source, flags=re.S)
    rules = []
    while source.strip():
        rule = re.match(r"\s*([^{}]+)\{([^{}]*)\}", source)
        if not rule:
            raise CompileError(f"未対応または不正なCSS {source.strip()[:80]!r}")
        source = source[rule.end():]
        declarations = parse_declarations(rule[2])
        for selector in rule[1].split(","):
            compounds = selector.split()
            if not compounds or not all(COMPOUND.fullmatch(part) for part in compounds):
                raise CompileError(f"未対応のCSSセレクタ {selector.strip()!r}")
            tokens = [SELECTOR_TOKEN.findall(part) for part in compounds]
            flat = [token for part in tokens for token in part]
            specificity = (
                sum(token.startswith("#") for token in flat),
                sum(token.startswith(".") for token in flat),
                sum(token[0] not in "#." for token in flat),
            )
            rules.append((specificity, tokens, declarations))
    return rules


def matches_compound(node, tokens):
    for token in tokens:
        if token.startswith("."):
            if token[1:] not in (node.attrs.get("class") or "").split():
                return False
        elif token.startswith("#"):
            if token[1:] != node.attrs.get("id"):
                return False
        elif token.lower() != node.tag:
            return False
    return True


def matches(chain, selector):
    if not matches_compound(chain[-1], selector[-1]):
        return False
    ancestors = iter(reversed(chain[:-1]))
    return all(any(matches_compound(node, part) for node in ancestors)
               for part in reversed(selector[:-1]))


def px(value):
    if not re.fullmatch(r"(?:0|(?:[0-9]+(?:\.[0-9]+)?|\.[0-9]+)px)", value):
        raise CompileError(f"非負の px 値が必要です {value!r}")
    number = float(value.removesuffix("px"))
    if number > 1000000:
        raise CompileError(f"px 値が大きすぎます {value!r}")
    return str(number)


def color(value):
    named = {"black": "#000", "white": "#fff", "red": "#f00", "transparent": "#00000000"}
    value = named.get(value, value)
    if not re.fullmatch(r"#(?:[0-9a-f]{3,4}|[0-9a-f]{6}|[0-9a-f]{8})", value):
        raise CompileError(f"未対応の色 {value!r}")
    rgb = value[1:]
    if len(rgb) in {3, 4}:
        rgb = "".join(digit * 2 for digit in rgb)
    rgba = rgb if len(rgb) == 8 else rgb + "ff"
    return tuple(int(rgba[i:i + 2], 16) for i in range(0, 8, 2))


def insets(value):
    sides = list(map(px, value.split()))
    match sides:
        case [a]:
            return a, a, a, a
        case [v, h]:
            return v, h, v, h
        case [top, h, bottom]:
            return top, h, bottom, h
        case [top, right, bottom, left]:
            return top, right, bottom, left
        case _:
            raise CompileError(f"余白は1〜4個の px 値で指定してください {value!r}")


MAIN_ALIGN = {
    "start": "start", "flex-start": "start", "center": "center",
    "end": "end", "flex-end": "end", "space-between": "spaceBetween",
    "space-around": "spaceAround", "space-evenly": "spaceEvenly",
}
CROSS_ALIGN = {
    "start": "start", "flex-start": "start", "center": "center",
    "end": "end", "flex-end": "end", "stretch": "stretch",
}
TEXT_ALIGN = {"left", "right", "center", "start", "end"}


def weight(value):
    value = {"normal": "400", "bold": "700"}.get(value, value)
    if not re.fullmatch(r"[1-9]00", value):
        raise CompileError(f"未対応の font-weight {value!r}")
    return int(value)


def border(value):
    parts = value.split()
    if len(parts) != 3 or parts[1] != "solid":
        raise CompileError("border-bottom は「太さ solid 色」で指定してください")
    return px(parts[0]), color(parts[2])


def validate_declaration(name, value):
    options = {
        "display": {"block", "flex", "none"},
        "flex-direction": {"row", "column"},
        "justify-content": MAIN_ALIGN,
        "align-items": CROSS_ALIGN,
        "text-align": TEXT_ALIGN,
        "font-family": {"system-ui"},
    }
    if name in options and value not in options[name]:
        raise CompileError(f"未対応のCSS値 {name}: {value}")
    if name in {"width", "height", "gap", "border-radius", "font-size"}:
        px(value)
    if name in {"padding", "margin"}:
        insets(value)
    if name in {"color", "background-color"}:
        color(value)
    if name == "font-weight":
        weight(value)
    if name == "border-bottom":
        border(value)
    if name == "flex-grow" and not re.fullmatch(r"(?:0|[1-9][0-9]{0,5})", value):
        raise CompileError(f"flex-grow は0〜999999の整数で指定してください {value!r}")


@dataclass
class View:
    tag: str
    style: dict[str, str]
    content: str
    children: list["View"]
    line: int
    source: Path
    target: int | None = None


INHERITED = {"color", "font-size", "font-weight", "text-align", "font-family"}


def lower(node, ancestors, rules, inherited, route_for):
    chain = [*ancestors, node]
    style = dict(inherited)
    if node.tag in {"strong", "b"}:
        style["font-weight"] = "bold"
    for _, selector, declarations in rules:
        if matches(chain, selector):
            style.update(declarations)
    try:
        style.update(parse_declarations(node.attrs.get("style") or ""))
    except CompileError as error:
        raise CompileError(f"{node.source}:{node.line}: {error}") from error
    if style.get("display") == "none":
        return None

    content = re.sub(r"[\t\n\r\f ]+", " ", "".join(
        child for child in node.children if isinstance(child, str)
    ))
    if not node.preserve_space:
        content = content.strip(" ")
    elements = [child for child in node.children if isinstance(child, Element)]
    # Keep links inside paragraphs and headings clickable as separate widgets.
    inline_links = node.tag in TEXT_TAGS - {"a"} and any(child.tag == "a" for child in elements)
    if inline_links:
        elements = [
            child if isinstance(child, Element) else
            Element("span", {}, node.line, node.source, [child], preserve_space=True)
            for child in node.children if isinstance(child, Element) or child.strip()
        ]
        style.setdefault("display", "flex")
        style.setdefault("align-items", "center")
    if node.tag in TEXT_TAGS and not inline_links and (elements or style.get("display") == "flex"):
        raise CompileError(f"{node.source}:{node.line}: <{node.tag}> にはプレーンテキストを指定してください")
    if node.tag in BOX_TAGS and content:
        if elements:
            raise CompileError(f"{node.source}:{node.line}: 文字と要素が混在する場合は文字を <span> などで囲んでください")
        elements.append(Element("span", {}, node.line, node.source, [content]))
    if any(child.tag not in BOX_TAGS | TEXT_TAGS for child in elements):
        raise CompileError(f"{node.source}:{node.line}: 表示領域にメタデータ要素があります")

    text_style = {key: style[key] for key in INHERITED if key in style}
    children = []
    for child in elements:
        view = lower(child, chain, rules, text_style, route_for)
        if view is not None:
            children.append(view)
    target = route_for(node) if node.tag == "a" and "href" in node.attrs else None
    return View("div" if inline_links else node.tag, style, content, children, node.line, node.source, target)


@dataclass
class Page:
    title: str
    body: View | None


@dataclass
class Program(Page):
    inputs: set[Path]
    pages: list[Page]
    has_links: bool


def local_path(node, attribute):
    value = node.attrs.get(attribute)
    if not value:
        raise CompileError(f"{node.source}:{node.line}: {attribute} が必要です")
    url = urlsplit(value)
    path = unquote(url.path)
    if (url.scheme or url.netloc or url.query or url.fragment or not path
            or path.startswith("/") or "\\" in path or "\x00" in path):
        raise CompileError(f"{node.source}:{node.line}: ローカルの相対パスが必要です {value!r}")
    return (node.source.parent / path).resolve()


def only_element(node, tag):
    elements = [child for child in node.children if isinstance(child, Element) and child.tag == tag]
    if len(elements) > 1:
        raise CompileError(f"{node.source}:{elements[1].line}: <{tag}> が重複しています")
    return elements[0] if elements else None


def plain_text(node):
    if any(isinstance(child, Element) for child in node.children):
        raise CompileError(f"{node.source}:{node.line}: <{node.tag}> には文字だけを指定してください")
    return "".join(node.children)


class SourceLoader:
    def __init__(self):
        self.inputs = set()
        self.rules = []

    def read(self, path):
        self.inputs.add(path)
        try:
            return path.read_text(encoding="utf-8-sig")
        except (OSError, UnicodeError) as error:
            raise CompileError(f"{path}: {error}") from error

    def add_stylesheet(self, source, location):
        try:
            self.rules.extend(parse_rules(source))
        except CompileError as error:
            raise CompileError(f"{location}: {error}") from error

    def styles(self, node):
        if node.tag in {"style", "link"} and (node.attrs.get("media") or "all").lower() != "all":
            raise CompileError(f"{node.source}:{node.line}: CSS の media 属性は未対応です")
        if node.tag == "style":
            self.add_stylesheet(plain_text(node), f"{node.source}:{node.line}")
        elif node.tag == "link":
            rel = (node.attrs.get("rel") or "").lower().split()
            if "stylesheet" in rel:
                path = local_path(node, "href")
                self.add_stylesheet(self.read(path), path)
        else:
            return False
        return True

    def expand(self, children, chain):
        result = []
        for child in children:
            if isinstance(child, str):
                result.append(child)
            elif child.tag == "include":
                if plain_text(child).strip():
                    raise CompileError(f"{child.source}:{child.line}: <include> は空にしてください")
                path = local_path(child, "src")
                try:
                    _, body, _, fragment = self.load(path, chain)
                except CompileError as error:
                    raise CompileError(f"{child.source}:{child.line}: include: {error}") from error
                result.extend(body.children if body else fragment)
            elif not self.styles(child):
                child.children = self.expand(child.children, chain)
                result.append(child)
        return result

    def load(self, path, chain=()):
        if path in chain:
            raise CompileError("循環 include: " + " → ".join(map(str, (*chain, path))))
        try:
            root = Document(self.read(path), path).root
        except CompileError as error:
            raise CompileError(f"{path}: {error}") from error
        html = only_element(root, "html")
        container = html or root
        head = only_element(container, "head")
        body = only_element(container, "body")
        if html and not body:
            raise CompileError(f"{path}: <html> には <body> が必要です")
        title = None
        if head:
            for item in head.children:
                if isinstance(item, Element):
                    if item.tag == "title":
                        title = plain_text(item).strip()
                    elif not self.styles(item) and item.tag != "meta":
                        raise CompileError(f"{item.source}:{item.line}: <head> 内の未対応要素 <{item.tag}>")
        chain = (*chain, path)
        if body:
            for item in container.children:
                if not isinstance(item, Element):
                    continue
                if item is body:
                    body.children = self.expand(body.children, chain)
                elif item is not head:
                    if not self.styles(item) and item.tag != "meta":
                        raise CompileError(f"{item.source}:{item.line}: <{item.tag}> は <body> 内に配置してください")
            return html, body, title, []
        fragment = [item for item in container.children if item is not head]
        return None, None, title, self.expand(fragment, chain)


def load_page(path, loader, route_for):
    html, body, title, _ = loader.load(path)
    if body is None:
        raise CompileError(f"{path}: ページには <body> が必要です")
    rules = sorted(loader.rules, key=lambda rule: rule[0])
    inherited = {}
    if html:
        for _, selector, declarations in rules:
            if matches([html], selector):
                inherited.update({key: value for key, value in declarations.items() if key in INHERITED})
        inherited.update({
            key: value for key, value in parse_declarations(html.attrs.get("style") or "").items()
            if key in INHERITED
        })
    return Page(title or path.stem, lower(body, [html] if html else [], rules, inherited, route_for))


def load_program(path):
    entry = path.resolve()
    pending = [(entry, None)]
    route_ids = {entry: 0}
    pages = []
    inputs = set()

    has_links = False

    def route_for(link):
        nonlocal has_links
        has_links = True
        destination = local_path(link, "href")
        if destination not in route_ids:
            route_ids[destination] = len(pending)
            pending.append((destination, link))
        return route_ids[destination]

    for source, link in pending:
        loader = SourceLoader()
        try:
            pages.append(load_page(source, loader, route_for))
        except CompileError as error:
            if link is None:
                raise
            raise CompileError(f"{link.source}:{link.line}: href: {error}") from error
        inputs.update(loader.inputs)

    return Program(pages[0].title, pages[0].body, inputs, pages, has_links)
