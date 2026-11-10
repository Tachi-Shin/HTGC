"""Generate standalone Flutter widget source."""

import json

from frontend import CROSS_ALIGN, MAIN_ALIGN, TEXT_TAGS, CompileError, border, color, insets, px, weight


def widget(name, *arguments):
    if not arguments:
        return f"{name}()"
    lines = ["  " + argument.replace("\n", "\n  ") + "," for argument in arguments]
    return f"{name}(\n" + "\n".join(lines) + "\n)"


def dart_string(value):
    # Escape interpolation as well as quotes, slashes and control characters.
    return json.dumps(value, ensure_ascii=False).replace("$", "\\$")


def dart_rgba(rgba):
    red, green, blue, alpha = rgba
    return f"Color(0x{alpha:02X}{red:02X}{green:02X}{blue:02X})"


def dart_color(value):
    return dart_rgba(color(value))


def dart_insets(value):
    top, right, bottom, left = insets(value)
    return f"EdgeInsets.fromLTRB({left}, {top}, {right}, {bottom})"


def dart_border(value):
    width, rgba = border(value)
    if width == "0.0":
        return "Border()"
    return f"Border(bottom: BorderSide(width: {width}, color: {dart_rgba(rgba)}))"


def emit(view, *, bounded_width=True, bounded_height=False):
    style = view.style
    own_width = bounded_width or "width" in style
    own_height = bounded_height or "height" in style
    is_text = view.tag in TEXT_TAGS
    flex = style.get("display") == "flex"
    row = flex and style.get("flex-direction", "row") == "row"

    if is_text:
        text_style = []
        for key, name, convert in [
            ("color", "color", dart_color), ("font-size", "fontSize", px),
            ("font-weight", "fontWeight", lambda value: f"FontWeight.w{weight(value)}"),
        ]:
            if key in style:
                text_style.append(f"{name}: {convert(style[key])}")
        args = [dart_string(view.content), "style: " + widget("TextStyle", *text_style)]
        if "text-align" in style:
            args.append("textAlign: TextAlign." + style["text-align"])
        content = widget("Text", *args)
        if view.target is not None:
            content = widget(
                "TextButton",
                f'onPressed: () => Navigator.of(context).pushNamed("/htgc/{view.target}")',
                f"child: {content}",
            )
    else:
        main_bounded = own_width if row else own_height
        cross = CROSS_ALIGN[style.get("align-items", "stretch" if flex else "start")]
        cross_bounded = own_height if row else own_width
        if cross == "stretch" and not cross_bounded:
            cross = "start"
        children = []
        for child in view.children:
            grow = int(child.style.get("flex-grow", "0"))
            if grow and (not flex or not main_bounded):
                raise CompileError(f"{child.source}:{child.line}: flex-grow には主軸が有限のFlex親が必要です")
            if grow and ("width" if row else "height") in child.style:
                raise CompileError(f"{child.source}:{child.line}: flex-grow と主軸の固定寸法は併用できません")
            if children and flex and style.get("gap", "0") not in {"0", "0px"}:
                axis = "width" if row else "height"
                children.append(widget("SizedBox", f"{axis}: {px(style['gap'])}"))
            child_width = bool(grow) and own_width if row else own_width
            child_height = own_height if row else bool(grow) and own_height
            expression = emit(child, bounded_width=child_width, bounded_height=child_height)
            if grow:
                expression = widget("Expanded", f"flex: {grow}", f"child: {expression}")
            children.append(expression)
        children_arg = "children: [\n"
        children_arg += "".join("  " + child.replace("\n", "\n  ") + ",\n" for child in children)
        children_arg += "]"
        align = MAIN_ALIGN[style.get("justify-content", "start")] if flex else "start"
        size = "max" if main_bounded and (row or "height" in style or align != "start" or
                                         any(int(child.style.get("flex-grow", "0")) for child in view.children)) else "min"
        content = widget("Row" if row else "Column", "mainAxisSize: MainAxisSize." + size,
                         "mainAxisAlignment: MainAxisAlignment." + align,
                         "crossAxisAlignment: CrossAxisAlignment." + cross, children_arg)

    box = []
    if "width" in style:
        box.append("width: " + px(style["width"]))
    elif not is_text and bounded_width:
        box.append("width: double.infinity")
    if "height" in style:
        box.append("height: " + px(style["height"]))
    for key in ("margin", "padding"):
        if key in style:
            box.append(f"{key}: {dart_insets(style[key])}")
    decoration = []
    if "background-color" in style:
        decoration.append("color: " + dart_color(style["background-color"]))
    if "border-radius" in style:
        if "border-bottom" in style:
            raise CompileError(f"{view.source}:{view.line}: border-radius と border-bottom は併用できません")
        decoration.append(f"borderRadius: BorderRadius.circular({px(style['border-radius'])})")
    if "border-bottom" in style:
        decoration.append("border: " + dart_border(style["border-bottom"]))
    if decoration:
        box.append("decoration: " + widget("BoxDecoration", *decoration))
    return widget("Container", *box, f"child: {content}") if box else content


def emit_screen(page, index):
    view = page.body
    output = emit(view) if view is not None else "SizedBox.shrink()"
    page_color = dart_color(view.style["background-color"]) if view and "background-color" in view.style else None
    scaffold_args = [f"backgroundColor: {page_color}"] if page_color else []
    scaffold_args.append("body: " + widget("SafeArea", "child: " + widget("SingleChildScrollView", "child: " + output)))
    scaffold = widget("Scaffold", *scaffold_args)
    name = f"GeneratedScreen{index}" if index else "GeneratedScreen"
    return (
        f"class {name} extends StatelessWidget {{\n"
        f"  const {name}({{super.key}});\n\n"
        "  @override\n"
        "  Widget build(BuildContext context) {\n"
        "    return " + scaffold.replace("\n", "\n    ") + ";\n"
        "  }\n"
        "}\n"
    )


def generate(program):
    app_args = [
        "debugShowCheckedModeBanner: false",
        f"title: {dart_string(program.title)}",
        "home: GeneratedScreen()",
    ]
    screens = [emit_screen(page, index) for index, page in enumerate(program.pages)]
    if program.has_links:
        routes = ['  "/htgc/0": (_) => const GeneratedScreen(),']
        routes.extend(
            f'  "/htgc/{index}": (_) => const GeneratedScreen{index}(),'
            for index in range(1, len(screens))
        )
        app_args.append("routes: {\n" + "\n".join(routes) + "\n}")
    app = widget("MaterialApp", *app_args)
    constant = "const " if len(app_args) == 3 else ""
    return (
        "// Generated by HTGC. Edit the HTML/CSS source.\n"
        "import 'package:flutter/material.dart';\n\n"
        "void main() => runApp(" + constant + app + ");\n\n"
        + "\n".join(screens)
    )
