"""Generate C11 source using IUP's native widget API."""

from c_source import c_string
from frontend import CROSS_ALIGN, MAIN_ALIGN, TEXT_TAGS, color, insets, px, weight


class Generator:
    def __init__(self):
        self.lines = []
        self.warnings = {}
        self.index = 0

    def warning(self, node, message):
        self.warnings[f"{node.source}:{node.line}: IUP: {message}"] = None

    def handle(self, expression):
        self.index += 1
        name = f"widget_{self.index}"
        self.lines.append(f"    Ihandle *{name} = {expression};")
        return name

    def attribute(self, handle, name, value):
        self.lines.append(f'    IupSetStrAttribute({handle}, "{name}", {c_string(value)});')

    def box(self, row, children):
        function = "IupHboxv" if row else "IupVboxv"
        if not children:
            return self.handle("IupHbox(NULL)" if row else "IupVbox(NULL)")
        items = ", ".join([*children, "NULL"])
        return self.handle(f"{function}((Ihandle *[]){{{items}}})")

    def integer_px(self, view, number, prop):
        value = float(number)
        if not value.is_integer():
            self.warning(view, f"{prop} の小数ピクセルを丸めます")
        return round(value)

    def spacing(self, node, handle, prop, attribute="NMARGIN"):
        top, right, bottom, left = insets(node.style[prop])
        if top != bottom or left != right:
            self.warning(node, f"{prop} の非対称な余白は上下・左右それぞれの最大値で近似します")
        width = self.integer_px(node, max(right, left, key=float), prop)
        height = self.integer_px(node, max(top, bottom, key=float), prop)
        if width or height:
            self.attribute(handle, attribute, f"{width}x{height}")

    def rgb(self, node, value, prop):
        red, green, blue, alpha = color(value)
        if alpha != 255:
            self.warning(node, f"{prop} のアルファ値は無視します")
        return f"{red} {green} {blue}"

    def emit(self, node, parent_axis=None):
        style = node.style
        is_text = node.tag in TEXT_TAGS
        is_flex = style.get("display") == "flex"
        row = is_flex and style.get("flex-direction", "row") == "row"
        if is_text:
            label = c_string(node.content.replace("&", "&&"))
            handle = self.handle(f"IupLabel({label})")
            if "color" in style:
                self.attribute(handle, "FGCOLOR", self.rgb(node, style["color"], "color"))
            if "font-size" in style:
                size = self.integer_px(node, px(style["font-size"]), "font-size")
                if size == 0:
                    self.warning(node, "0px の font-size は既定サイズになります")
                else:
                    self.attribute(handle, "FONTSIZE", str(-size))
            if "font-weight" in style:
                css_weight = weight(style["font-weight"])
                if css_weight not in {400, 700}:
                    self.warning(node, "font-weight を normal または bold で近似します")
                if css_weight >= 600:
                    self.attribute(handle, "FONTSTYLE", "Bold")
            if "text-align" in style:
                horizontal = {"left": "ALEFT", "start": "ALEFT", "center": "ACENTER",
                              "right": "ARIGHT", "end": "ARIGHT"}
                self.attribute(handle, "ALIGNMENT", horizontal[style["text-align"]] + ":ACENTER")
        else:
            axis = ("HORIZONTAL" if row else "VERTICAL") if is_flex else None
            children = [self.emit(child, axis) for child in node.children]
            handle = self.box(row, children)
            if is_flex:
                cross = CROSS_ALIGN[style.get("align-items", "stretch")]
                if cross == "stretch":
                    self.attribute(handle, "EXPANDCHILDREN", "YES")
                else:
                    align = ("ATOP", "ACENTER", "ABOTTOM") if row else ("ALEFT", "ACENTER", "ARIGHT")
                    self.attribute(handle, "ALIGNMENT", align[("start", "center", "end").index(cross)])
                if "gap" in style:
                    gap = self.integer_px(node, px(style["gap"]), "gap")
                    self.attribute(handle, "NGAP", str(gap))
                if MAIN_ALIGN[style.get("justify-content", "start")] != "start":
                    self.warning(node, "justify-content は start で配置します")

        if "padding" in style:
            self.spacing(node, handle, "padding", "PADDING" if is_text else "NMARGIN")

        background = style.get("background-color")
        if background is not None and color(background)[3] == 0:
            background = None
        sized = "width" in style or "height" in style
        if background is not None or (sized and not is_text):
            handle = self.handle(f"IupBackgroundBox({handle})")
            if background is not None:
                self.attribute(handle, "BGCOLOR", self.rgb(node, background, "background-color"))
        if sized:
            sizes = []
            for dimension in ("width", "height"):
                size = self.integer_px(node, px(style.get(dimension, "0")), dimension)
                if dimension in style and not size:
                    self.warning(node, f"0px の {dimension} は自然サイズになります")
                sizes.append(str(size))
            self.attribute(handle, "RASTERSIZE", "x".join(sizes))
        if "margin" in style:
            handle = self.box(False, [handle])
            self.spacing(node, handle, "margin")
        for unsupported in ("border-radius", "border-bottom"):
            if unsupported in style and px(style[unsupported].split()[0]) != "0.0":
                self.warning(node, f"{unsupported} は省略します")
        grow = int(style.get("flex-grow", "0"))
        if grow and parent_axis:
            self.attribute(handle, "EXPAND", parent_axis)
            self.attribute(handle, "EXPANDWEIGHT", str(grow))
        elif grow:
            self.warning(node, "flex-grow には Flex の親要素が必要です")
        return handle


def generate(program):
    generator = Generator()
    root = generator.emit(program.body) if program.body else generator.box(False, [])
    dialog = generator.handle(f"IupDialog({root})")
    generator.attribute(dialog, "TITLE", program.title)
    code = [
        "/* Generated by HTGC. Edit the HTML/CSS source. */",
        "#include <stddef.h>",
        "#include <iup.h>",
        "",
        "int main(int argc, char **argv)",
        "{",
        "    if (IupOpen(&argc, &argv) != IUP_NOERROR) {",
        "        return 1;",
        "    }",
        '    IupSetGlobal("UTF8MODE", "YES");',
        "",
        *generator.lines,
        f"    if (IupShow({dialog}) != IUP_NOERROR) {{",
        f"        IupDestroy({dialog});",
        "        IupClose();",
        "        return 1;",
        "    }",
        "    IupMainLoop();",
        f"    IupDestroy({dialog});",
        "    IupClose();",
        "    return 0;",
        "}",
        "",
    ]
    return "\n".join(code), list(generator.warnings)
