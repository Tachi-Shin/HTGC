"""Generate C11 source using GTK 4's native widget API."""

from c_source import c_string
from frontend import CROSS_ALIGN, MAIN_ALIGN, TEXT_TAGS, border, color, insets, px, weight


GTK_ALIGN = {
    "start": "GTK_ALIGN_START",
    "end": "GTK_ALIGN_END",
    "center": "GTK_ALIGN_CENTER",
    "stretch": "GTK_ALIGN_FILL",
}

GTK_JUSTIFY = {
    "left": "GTK_JUSTIFY_LEFT",
    "start": "GTK_JUSTIFY_LEFT",
    "center": "GTK_JUSTIFY_CENTER",
    "right": "GTK_JUSTIFY_RIGHT",
    "end": "GTK_JUSTIFY_RIGHT",
}


def gtk_rgba(rgba):
    red, green, blue, alpha = rgba
    return f"rgba({red}, {green}, {blue}, {alpha / 255:.8f})"


def css_declarations(style):
    declarations = []
    for prop in ("background-color", "color"):
        if prop in style:
            declarations.append(f"{prop}: {gtk_rgba(color(style[prop]))}")
    for prop in ("padding", "margin"):
        if prop in style:
            sides = " ".join(f"{value}px" for value in insets(style[prop]))
            declarations.append(f"{prop}: {sides}")
    for prop in ("width", "height"):
        if prop in style:
            declarations.append(f"min-{prop}: {px(style[prop])}px")
    for prop in ("border-radius", "font-size"):
        if prop in style:
            declarations.append(f"{prop}: {px(style[prop])}px")
    if "font-weight" in style:
        declarations.append(f"font-weight: {weight(style['font-weight'])}")
    if "border-bottom" in style:
        width, rgba = border(style["border-bottom"])
        declarations.append(f"border-bottom: {width}px solid {gtk_rgba(rgba)}")
    return declarations


class Generator:
    def __init__(self):
        self.lines = []
        self.rules = []
        self.warnings = {}
        self.index = 0
        self.targets = set()

    def warning(self, node, message):
        self.warnings[f"{node.source}:{node.line}: GTK: {message}"] = None

    def emit(self, node):
        self.index += 1
        name = f"widget_{self.index}"
        css_class = f"htgc-node-{self.index}"
        style = node.style
        is_flex = style.get("display") == "flex"
        row = is_flex and style.get("flex-direction", "row") == "row"
        if node.tag in TEXT_TAGS:
            label = name if node.target is None else f"{name}_label"
            self.lines.append(f"    GtkWidget *{label} = gtk_label_new({c_string(node.content)});")
            self.lines.append(f"    gtk_label_set_wrap(GTK_LABEL({label}), TRUE);")
            self.lines.append(f"    gtk_label_set_wrap_mode(GTK_LABEL({label}), PANGO_WRAP_WORD_CHAR);")
            align = style.get("text-align", "start")
            xalign = {"GTK_JUSTIFY_LEFT": "0.0f", "GTK_JUSTIFY_CENTER": "0.5f", "GTK_JUSTIFY_RIGHT": "1.0f"}
            justify = GTK_JUSTIFY[align]
            self.lines.append(f"    gtk_label_set_justify(GTK_LABEL({label}), {justify});")
            self.lines.append(f"    gtk_label_set_xalign(GTK_LABEL({label}), {xalign[justify]});")
            if node.target is not None:
                self.targets.add(node.target)
                self.lines.extend([
                    f"    GtkWidget *{name} = gtk_button_new();",
                    f"    gtk_button_set_child(GTK_BUTTON({name}), {label});",
                    f'    g_signal_connect({name}, "clicked", G_CALLBACK(navigate_{node.target}), stack);',
                ])
        else:
            gap = float(px(style.get("gap", "0"))) if is_flex else 0
            if gap != round(gap):
                self.warning(node, "gap の小数ピクセルを丸めます")
            direction = "HORIZONTAL" if row else "VERTICAL"
            self.lines.append(f"    GtkWidget *{name} = gtk_box_new(GTK_ORIENTATION_{direction}, {round(gap)});")
            self.emit_children(node, name, row, is_flex)

        declarations = css_declarations(style)
        if declarations:
            self.rules.append(f".{css_class} {{ " + "; ".join(declarations) + "; }\n")
            self.lines.append(f'    gtk_widget_add_css_class({name}, "{css_class}");')
        return name

    def emit_children(self, node, name, row, is_flex):
        style = node.style
        cross = CROSS_ALIGN[style.get("align-items", "stretch")] if is_flex else "stretch"
        cross_axis = "v" if row else "h"
        main_axis = "h" if row else "v"
        weights = {int(child.style.get("flex-grow", "0")) for child in node.children} - {0}
        justify = MAIN_ALIGN[style.get("justify-content", "start")] if is_flex else "start"
        if justify != "start":
            self.warning(node, "justify-content は start で配置します")
        if is_flex and len(weights) > 1:
            self.warning(node, "GtkBox では異なる flex-grow の比率を均等配分で近似します")

        for child in node.children:
            handle = self.emit(child)
            grows = int(child.style.get("flex-grow", "0")) > 0
            if grows and not is_flex:
                self.warning(child, "flex-grow には Flex の親要素が必要です")
            expands = "TRUE" if grows and is_flex else "FALSE"
            self.lines.append(f"    gtk_widget_set_{cross_axis}align({handle}, {GTK_ALIGN[cross]});")
            self.lines.append(f"    gtk_widget_set_{main_axis}expand({handle}, {expands});")
            self.lines.append(f"    gtk_box_append(GTK_BOX({name}), {handle});")


def generate(program):
    generator = Generator()
    navigation = []
    single_page_scroll = []
    if program.has_links:
        generator.lines.append("    GtkWidget *stack = gtk_stack_new();")
    for index, page in enumerate(program.pages):
        if page.body is None:
            root = f"empty_{index}" if program.has_links else "empty"
            generator.lines.append(f"    GtkWidget *{root} = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);")
        else:
            root = generator.emit(page.body)
        scroll = f"scroll_{index}" if program.has_links else "scroll"
        scroll_setup = generator.lines if program.has_links else single_page_scroll
        scroll_setup.extend([
            f"    GtkWidget *{scroll} = gtk_scrolled_window_new();",
            f"    gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW({scroll}), {root});",
        ])
        if program.has_links:
            generator.lines.append(f'    gtk_stack_add_named(GTK_STACK(stack), {scroll}, "page-{index}");')
    window_child = "stack" if program.has_links else "scroll"
    for target in sorted(generator.targets):
        navigation.extend([
            f"static void navigate_{target}(GtkButton *button, gpointer data)",
            "{",
            "    (void)button;",
            "    GtkWidget *stack = GTK_WIDGET(data);",
            f'    gtk_stack_set_visible_child_name(GTK_STACK(stack), "page-{target}");',
            f"    gtk_window_set_title(GTK_WINDOW(gtk_widget_get_root(stack)), {c_string(program.pages[target].title)});",
            "}",
            "",
        ])

    css_setup = []
    if generator.rules:
        css_setup = [
            "    GtkCssProvider *provider = gtk_css_provider_new();",
            "    GString *css = g_string_new(NULL);",
            *(f"    g_string_append(css, {c_string(rule)});" for rule in generator.rules),
            "#if GTK_CHECK_VERSION(4, 12, 0)",
            "    gtk_css_provider_load_from_string(provider, css->str);",
            "#else",
            "    gtk_css_provider_load_from_data(provider, css->str, -1);",
            "#endif",
            "    g_string_free(css, TRUE);",
            "    gtk_style_context_add_provider_for_display(",
            "        gtk_widget_get_display(window), GTK_STYLE_PROVIDER(provider),",
            "        GTK_STYLE_PROVIDER_PRIORITY_APPLICATION);",
            "    g_object_unref(provider);",
            "",
        ]

    code = [
        "/* Generated by HTGC for GTK 4. Edit the HTML/CSS source. */",
        "#include <gtk/gtk.h>",
        "",
        *navigation,
        "static void activate(GtkApplication *app, gpointer user_data)",
        "{",
        "    (void)user_data;",
        "    GtkWidget *window = gtk_application_window_new(app);",
        f"    gtk_window_set_title(GTK_WINDOW(window), {c_string(program.title)});",
        "    gtk_window_set_default_size(GTK_WINDOW(window), 480, 320);",
        "",
        *generator.lines,
        "",
        *css_setup,
        *single_page_scroll,
        f"    gtk_window_set_child(GTK_WINDOW(window), {window_child});",
        "    gtk_window_present(GTK_WINDOW(window));",
        "}",
        "",
        "int main(int argc, char **argv)",
        "{",
        "    GtkApplication *app = gtk_application_new(NULL, G_APPLICATION_NON_UNIQUE);",
        '    g_signal_connect(app, "activate", G_CALLBACK(activate), NULL);',
        "    int status = g_application_run(G_APPLICATION(app), argc, argv);",
        "    g_object_unref(app);",
        "    return status;",
        "}",
        "",
    ]
    return "\n".join(code), list(generator.warnings)
