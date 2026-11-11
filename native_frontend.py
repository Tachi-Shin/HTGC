"""HTML5/CSS parsing for the native Dart runtime, independent of browser engines."""

from dataclasses import dataclass
from pathlib import Path
import re
from urllib.parse import unquote, urlsplit

from frontend import CompileError
from js_dart import compile_script
from native_events import parse_handler

SUPPORTED_PROPERTIES = set(
    """
-webkit-font-smoothing -webkit-mask-image -webkit-mask-position -webkit-mask-repeat -webkit-mask-size
align-items animation backdrop-filter background background-color block-size border border-bottom
border-color border-left border-radius border-right border-top bottom box-shadow box-sizing clip
color content cursor display flex-direction flex-wrap font font-family font-size font-style font-weight gap
grid-template-columns grid-template-rows height inline-size inset justify-content left letter-spacing
line-height list-style margin margin-block margin-bottom margin-inline margin-left margin-right margin-top
mask-image mask-position mask-repeat mask-size max-inline-size max-width min-block-size min-height
object-fit opacity outline overflow padding padding-block padding-bottom padding-inline padding-left
padding-right padding-top place-items pointer-events position right text-align text-decoration text-rendering
top transform transition white-space width will-change z-index
""".split()
)
PAGE_SUFFIXES = {".html", ".htm"}
IMAGE_SUFFIXES = {".png", ".jpg", ".jpeg", ".gif", ".webp", ".svg", ".bmp"}


@dataclass
class NativeSite:
    entry: str
    pages: dict
    assets: dict[str, Path]
    scripts: list[str]
    inputs: set[Path]
    handlers: list[tuple]


def load_site(entry, *, script_compiler=compile_script, includes=()):
    try:
        import html5lib
        import tinycss2
        from cssselect2.parser import parse as parse_selector
    except ImportError as error:
        raise CompileError(
            "拡張変換には pip install -r requirements-native.txt が必要です"
        ) from error
    entry = Path(entry).resolve(strict=True)
    root = entry.parent
    inputs = set()
    pages = {}
    compiled_scripts = []
    script_ids = {}
    assets = {}
    handlers = []
    handler_ids = {}

    def local(reference, owner):
        url = urlsplit(reference)
        if url.scheme or url.netloc:
            raise CompileError(f"{owner}: ローカル入力が必要です: {reference}")
        path = (
            root / unquote(url.path).lstrip("/")
            if url.path.startswith("/")
            else owner.parent / unquote(url.path)
        ).resolve()
        if not path.is_relative_to(root):
            raise CompileError(f"{owner}: 入力ルート外の参照: {reference}")
        return path

    def read(path):
        if not path.resolve().is_relative_to(root):
            raise CompileError(f"{path}: 入力ルート外のファイルは読み込めません")
        inputs.add(path.resolve())
        return path.read_text(encoding="utf-8")

    def add_asset(path):
        key = path.relative_to(root).as_posix()
        if not path.is_file():
            raise CompileError(f"{path}: 画像ファイルがありません")
        assets[key] = path
        inputs.add(path)
        return key

    def declarations(tokens, owner):
        result = {}
        for d in tinycss2.parse_declaration_list(
            tokens, skip_comments=True, skip_whitespace=True
        ):
            if d.type != "declaration":
                raise CompileError(f"{owner}:{d.source_line}: 不正なCSS宣言")
            name = d.name if d.name.startswith("--") else d.lower_name
            if name not in SUPPORTED_PROPERTIES and not name.startswith("--"):
                raise CompileError(
                    f"{owner}:{d.source_line}: 拡張変換では未対応のCSSプロパティ {name}"
                )
            if name in result and result[name][1] and not d.important:
                continue
            value = tinycss2.serialize(d.value).strip()

            def url_replace(m):
                ref = m[1].strip().strip("\"'")
                if urlsplit(ref).scheme or ref.startswith(("#", "//")):
                    return m[0]
                path = local(ref, owner)
                if not path.is_file():
                    raise CompileError(f"{owner}: CSSリソースがありません: {ref}")
                key = add_asset(path)
                return f'url("{key}")'

            value = re.sub(r"url\(([^)]+)\)", url_replace, value)
            result[name] = [value, d.important]
        return result

    def css(source, owner, conditions=None):
        result = []
        for rule in tinycss2.parse_stylesheet(
            source, skip_comments=True, skip_whitespace=True
        ):
            if rule.type == "error":
                raise CompileError(f"{owner}:{rule.source_line}: {rule.message}")
            if rule.type == "at-rule":
                label = rule.lower_at_keyword
                condition = tinycss2.serialize(rule.prelude).strip()
                if label in ("media", "container") and rule.content is not None:
                    result.extend(
                        css(
                            tinycss2.serialize(rule.content),
                            owner,
                            (conditions or []) + [[label, condition]],
                        )
                    )
                elif label == "keyframes" and rule.content is not None:
                    frames = {}
                    for frame in tinycss2.parse_rule_list(
                        rule.content, skip_comments=True, skip_whitespace=True
                    ):
                        frames[tinycss2.serialize(frame.prelude).strip()] = (
                            declarations(frame.content, owner)
                        )
                    result.append({"keyframes": condition, "frames": frames})
                else:
                    raise CompileError(
                        f"{owner}:{rule.source_line}: 未対応のCSS @{label}"
                    )
                continue
            selector_text = tinycss2.serialize(rule.prelude).strip()
            try:
                selectors = list(parse_selector(selector_text))
            except Exception as error:
                raise CompileError(
                    f"{owner}: CSSセレクタ {selector_text}: {error}"
                ) from error
            # Preserve the original spelling; cssselect2 computes specificity only.
            groups = []
            start = 0
            depth = 0
            for i, ch in enumerate(selector_text):
                if ch in "([":
                    depth += 1
                if ch in ")]":
                    depth -= 1
                if ch == "," and depth == 0:
                    groups.append(selector_text[start:i].strip())
                    start = i + 1
            groups.append(selector_text[start:].strip())
            decls = declarations(rule.content, owner)
            for text, selector in zip(groups, selectors):
                result.append(
                    {
                        "selector": text,
                        "specificity": list(selector.specificity),
                        "declarations": decls,
                        "conditions": conditions or [],
                    }
                )
        return result

    def node_spec(element):
        if not isinstance(element.tag, str):
            return None
        if element.tag in ("head", "script", "style", "noscript"):
            return None
        children = []
        if element.text:
            children.append(element.text)
        for child in element:
            spec = node_spec(child)
            if spec is not None:
                children.append(spec)
            if child.tail:
                children.append(child.tail)
        return {"tag": element.tag, "attributes": element.attrib, "children": children}

    paths = [entry]
    scheduled = {entry}

    def add_page(path):
        if path not in scheduled:
            scheduled.add(path)
            paths.append(path)

    for include in includes:
        path = (root / include).resolve()
        if not path.is_relative_to(root) or not path.is_file():
            raise CompileError(f"--include: 入力ルート内のファイルを指定してください: {include}")
        if path.suffix.lower() in PAGE_SUFFIXES:
            add_page(path)
        elif path.suffix.lower() in IMAGE_SUFFIXES:
            add_asset(path)
        else:
            raise CompileError(f"--include: HTMLまたは画像を指定してください: {include}")

    for path in paths:
        tree = html5lib.parse(read(path), namespaceHTMLElements=False)
        styles = []
        scripts = []
        for el in tree.iter():
            if el.tag in ("include", "iframe", "object", "embed", "video", "audio"):
                raise CompileError(f"{path}: 拡張変換では未対応の要素 <{el.tag}>")
            for attribute in list(el.attrib):
                if not attribute.startswith("on"):
                    continue
                if not (
                    (attribute == "onclick" and el.tag in {"button", "a"})
                    or (attribute == "oninput" and el.tag in {"input", "textarea"})
                ):
                    raise CompileError(f"{path}: <{el.tag}> の {attribute} は未対応のイベント呼び出しです")
                key = (attribute, el.attrib[attribute])
                if key not in handler_ids:
                    handler_ids[key] = len(handlers)
                    handlers.append(parse_handler(key[1], path, attribute))
                el.attrib[attribute] = str(handler_ids[key])
            reference = None
            if el.tag in {"a", "area"}:
                reference = el.attrib.get("href")
            elif el.tag == "img":
                reference = el.attrib.get("src")
            elif el.tag == "link" and "icon" in el.attrib.get("rel", "").lower().split():
                reference = el.attrib.get("href")
            if reference:
                url = urlsplit(reference)
                if not url.scheme and not url.netloc and url.path:
                    if el.tag in {"a", "area"}:
                        if Path(unquote(url.path)).suffix.lower() in PAGE_SUFFIXES:
                            add_page(local(reference, path))
                    else:
                        add_asset(local(reference, path))
            if el.tag == "link" and el.attrib.get("rel") == "stylesheet":
                source = local(el.attrib["href"], path)
                styles.extend(css(read(source), source))
            if el.tag == "style":
                styles.extend(css(el.text or "", path))
            if el.tag == "script" and el.attrib.get("type", "") in (
                "",
                "module",
                "text/javascript",
                "application/javascript",
            ):
                source = local(el.attrib["src"], path) if "src" in el.attrib else path
                code = read(source) if source != path else el.text or ""
                key = (str(source), code)
                if key not in script_ids:
                    i = len(compiled_scripts)
                    script_ids[key] = i
                    compiled_scripts.append(
                        script_compiler(
                            code, source.relative_to(root), name=f"htgcScript{i}"
                        )
                    )
                scripts.append(script_ids[key])
        title = next((el.text for el in tree.iter("title")), None) or path.stem
        pages[path.relative_to(root).as_posix()] = {
            "title": title,
            "tree": node_spec(tree),
            "styles": styles,
            "scripts": scripts,
        }
    return NativeSite(
        entry.relative_to(root).as_posix(), pages, assets, compiled_scripts, inputs, handlers
    )
