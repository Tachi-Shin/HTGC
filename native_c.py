"""Build the native C representation shared by C renderers and DOM tests."""

from pathlib import Path
import re

from c_source import c_string
from js_c import compile_script
from native_events import emit_handler
from native_frontend import load_site


RUNTIME = Path(__file__).parent / "runtime"


def literal(value):
    return c_string(value) if value is not None else "NULL"


def emit_document(index, tree):
    nodes = []
    declarations = []

    def walk(spec, parent):
        current = len(nodes)
        if isinstance(spec, str):
            nodes.append(f"    {{NULL, {c_string(spec)}, NULL, 0, {parent}}},")
            return
        entries = list(spec["attributes"].items())
        attrs = "NULL"
        if entries:
            attrs = f"attributes_{index}_{current}"
            declarations.append(f"static const DomAttribute {attrs}[] = {{")
            declarations.extend(
                f"    {{{c_string(name)}, {c_string(value)}}},"
                for name, value in entries
            )
            declarations.append("};")
        nodes.append(
            f'    {{{c_string(spec["tag"])}, NULL, {attrs}, {len(entries)}, {parent}}},'
        )
        for child in spec["children"]:
            walk(child, current)

    walk(tree, -1)
    return "\n".join(
        [*declarations, f"static const DomSpec document_{index}[] = {{", *nodes, "};"]
    ), len(nodes)


def emit_styles(index, rules):
    definitions = []
    entries = []
    ordered = []
    for order, rule in enumerate(rules):
        if "selector" not in rule or "::" in rule["selector"]:
            continue
        if any(kind == "container" for kind, _ in rule["conditions"]):
            continue
        minimum, maximum, reduced = 0, 0, False
        for _, condition in rule["conditions"]:
            match = re.search(r"(min|max)-width:\s*([\d.]+)px", condition)
            if match and match[1] == "min":
                minimum = max(minimum, float(match[2]))
            if match and match[1] == "max":
                width = float(match[2])
                maximum = min(maximum, width) if maximum else width
            reduced |= "prefers-reduced-motion: reduce" in condition
        for important in (False, True):
            declarations = [
                (name, value)
                for name, (value, flag) in rule["declarations"].items()
                if flag == important
            ]
            if declarations:
                ordered.append(
                    (
                        (important, rule["specificity"], order),
                        rule["selector"],
                        declarations,
                        minimum,
                        maximum,
                        reduced,
                    )
                )
    for position, (_, selector, declarations, minimum, maximum, reduced) in enumerate(
        sorted(ordered)
    ):
        name = f"declarations_{index}_{position}"
        definitions.append(f"static const CssDeclaration {name}[] = {{")
        definitions.extend(
            f"    {{{c_string(key)}, {c_string(value)}}},"
            for key, value in declarations
        )
        definitions.append("};")
        entries.append(
            f"    {{{c_string(selector)}, {name}, {len(declarations)}, {minimum}, {maximum}, {str(reduced).lower()}}},"
        )
    if not entries:
        return "", "NULL", 0
    name = f"css_rules_{index}"
    return (
        "\n".join(
            [*definitions, f"static const CssRule {name}[] = {{", *entries, "};"]
        ),
        name,
        len(entries),
    )


def generate(entry, *, graphics=True, includes=()):
    site = load_site(entry, script_compiler=compile_script, includes=includes)
    chunks = ["/* Generated C11. Edit the HTML/CSS/JavaScript inputs. */"]
    for name in ("js_c_core.inc", "dom_c.inc"):
        chunks.append((RUNTIME / name).read_text(encoding="utf-8"))
    chunks.extend(site.scripts)
    chunks.append(
        """
typedef void (*SiteScript)(JsScope *);
typedef struct { const char *name, *value; } CssDeclaration;
typedef struct {
    const char *selector;
    const CssDeclaration *declarations;
    size_t count;
    double min_width, max_width;
    bool reduced;
} CssRule;
typedef struct {
    const char *path, *title;
    const DomSpec *nodes;
    size_t node_count;
    const SiteScript *scripts;
    size_t script_count;
    const CssRule *rules;
    size_t rule_count;
} SitePage;
"""
    )
    pages = []
    for index, (path, page) in enumerate(site.pages.items()):
        document, count = emit_document(index, page["tree"])
        chunks.append(document)
        scripts = page["scripts"]
        ref = "NULL"
        if scripts:
            ref = f"scripts_{index}"
            functions = ", ".join(f"htgcScript{number}" for number in scripts)
            chunks.append(f"static const SiteScript {ref}[] = {{{functions}}};")
        css, css_name, rule_count = emit_styles(index, page["styles"])
        chunks.append(css)
        pages.append(
            f'    {{{c_string(path)}, {c_string(page["title"])}, document_{index}, {count}, {ref}, {len(scripts)}, {css_name}, {rule_count}}},'
        )
    chunks.append("\n".join(["static const SitePage site_pages[] = {", *pages, "};"]))
    chunks.append(f"static const char *site_entry = {c_string(site.entry)};")
    chunks.append(
        """
static const SitePage *site_page(const char *path)
{
    for (size_t index = 0; index < G_N_ELEMENTS(site_pages); index++) {
        if (!strcmp(site_pages[index].path, path)) return &site_pages[index];
    }
    return NULL;
}
static bool site_load(DomRuntime *runtime, const SitePage *page)
{
    JsScope *globals = dom_load(runtime, page->nodes, page->node_count);
    for (size_t index = 0; index < page->script_count; index++) {
        page->scripts[index](js_scope(globals));
        if (runtime->heap.error) return false;
    }
    return true;
}
"""
    )
    if graphics:
        handler_source = repr(site.handlers)
        event_id, text_parameter = "htgc_event_id", "htgc_event_text"
        while event_id in handler_source:
            event_id += "_"
        while text_parameter in handler_source:
            text_parameter += "_"
        calls = []
        for index, handler in enumerate(site.handlers):
            expression = emit_handler(handler, dart=False, text_parameter=text_parameter)
            calls.extend([
                f'    if (strcmp({event_id}, "{index}") == 0) {{',
                f"        (void){expression};",
                "        return;",
                "    }",
            ])
        chunks.append("\n".join([
            *(['#include "htgc_handlers.h"'] if site.handlers else []),
            f"static void htgc_invoke(const char *{event_id}, const char *{text_parameter})",
            "{",
            f"    if (!{event_id}) return;",
            f"    (void){text_parameter};",
            *calls,
            "}",
        ]))
        animations = {}
        for page in site.pages.values():
            for rule in page["styles"]:
                if "keyframes" in rule:
                    frames = rule["frames"]
                    start = frames.get("from", frames.get("0%", {})).get("transform")
                    end = frames.get("to", frames.get("100%", {})).get("transform")
                    if start and end:
                        animations[rule["keyframes"]] = start[0], end[0]
        chunks.append("typedef struct { const char *name, *from, *to; } SiteAnimation;")
        chunks.append(f"static const size_t site_animation_count = {len(animations)};")
        chunks.append("static const SiteAnimation site_animations[] = {")
        for name, (start, end) in animations.items():
            chunks.append(
                f"    {{{c_string(name)}, {c_string(start)}, {c_string(end)}}},"
            )
        if not animations:
            chunks.append("    {NULL, NULL, NULL},")
        chunks.append("};")
        chunks.append("typedef struct { const char *path, *data; } SiteAsset;")
        chunks.append(f"static const size_t site_asset_count = {len(site.assets)};")
        chunks.append("static const SiteAsset site_assets[] = {")
        for name, data in site.assets.items():
            chunks.append(f"    {{{c_string(name)},")
            chunks.extend(
                f"        {c_string(data[i:i+960])}" for i in range(0, len(data), 960)
            )
            chunks.append("    },")
        if not site.assets:
            chunks.append("    {NULL, NULL},")
        chunks.append("};")
        chunks.append((RUNTIME / "gtk_site.inc").read_text(encoding="utf-8"))
    return "\n\n".join(chunks) + "\n", site
