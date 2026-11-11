/* GTK 4 host for the compiled site and its C event handlers. */
#include <gtk/gtk.h>

typedef struct {
    GtkApplication *application;
    GtkWidget *window, *scroller;
    GtkCssProvider *provider;
    GHashTable *storage, *textures, *surfaces;
    char *asset_directory;
    GPtrArray *rendered_nodes;
    const SitePage *page;
    DomRuntime dom;
    bool initialized;
    double width, height;
    gint64 page_start;
    GString *stylesheet;
    guint css_id, pending_render;
} SiteApp;
static SiteApp app;

static const char *style_get(GHashTable *style, const char *key)
{
    return g_hash_table_lookup(style, key);
}
static bool style_is(GHashTable *style, const char *key, const char *value)
{
    return g_strcmp0(style_get(style, key), value) == 0;
}
static void style_put(GHashTable *style, const char *key, const char *value)
{
    g_hash_table_replace(style, g_strdup(key), g_strdup(value));
}
static GPtrArray *split_css(const char *text, char delimiter)
{
    GPtrArray *parts = g_ptr_array_new_with_free_func(g_free);
    if (!text) return parts;
    int depth = 0;
    char quote = 0;
    const char *start = text;
    for (const char *at = text;; at++) {
        char c = *at;
        if (!c || (!quote && !depth && (delimiter == ' ' ? g_ascii_isspace(c) : c == delimiter))) {
            char *part = g_strstrip(g_strndup(start, at - start));
            if (*part) g_ptr_array_add(parts, part);
            else g_free(part);
            start = at + 1;
            if (!c) break;
        } else if (quote) {
            if (c == quote && (at == text || at[-1] != '\\')) quote = 0;
        } else if (c == '\'' || c == '"') quote = c;
        else if (c == '(') depth++;
        else if (c == ')') depth--;
    }
    return parts;
}
static double css_length(const char *text, double basis, double font, double fallback)
{
    if (!text) return fallback;
    if (g_str_has_prefix(text, "min(") || g_str_has_prefix(text, "max(") || g_str_has_prefix(text, "clamp(")) {
        const char *start = strchr(text, '(') + 1;
        const char *end = strrchr(start, ')');
        if (!end) return fallback;
        char *args = g_strndup(start, end - start);
        GPtrArray *parts = split_css(args, ',');
        double result = fallback;
        if (parts->len == 2) {
            double a = css_length(parts->pdata[0], basis, font, fallback);
            double b = css_length(parts->pdata[1], basis, font, fallback);
            result = text[1] == 'i' ? fmin(a, b) : fmax(a, b);
        } else if (parts->len == 3 && text[0] == 'c') {
            double low = css_length(parts->pdata[0], basis, font, fallback);
            double mid = css_length(parts->pdata[1], basis, font, fallback);
            double high = css_length(parts->pdata[2], basis, font, fallback);
            result = fmax(low, fmin(mid, high));
        }
        g_ptr_array_unref(parts);
        g_free(args);
        return result;
    }
    char *end;
    double value = g_ascii_strtod(text, &end);
    if (end == text || !isfinite(value)) return fallback;
    if (!strcmp(end, "%")) return value * basis / 100;
    if (!strcmp(end, "em")) return value * font;
    if (!strcmp(end, "rem")) return value * 16;
    if (!strcmp(end, "vw")) return value * app.width / 100;
    if (!strcmp(end, "vh") || !strcmp(end, "svh")) return value * app.height / 100;
    if (!*end || !strcmp(end, "px")) return value;
    return fallback;
}
static char *resolve_variables(GHashTable *style, const char *input)
{
    char *text = g_strdup(input);
    for (int count = 0; count < 24; count++) {
        const char *start = strstr(text, "var(");
        if (!start) break;
        const char *end = strchr(start + 4, ')');
        if (!end) break;
        char *contents = g_strndup(start + 4, end - start - 4);
        char *fallback = strchr(contents, ',');
        if (fallback) *fallback++ = '\0';
        const char *value = style_get(style, g_strstrip(contents));
        if (!value) value = fallback ? g_strstrip(fallback) : "";
        GString *resolved = g_string_new_len(text, start - text);
        g_string_append(resolved, value);
        g_string_append(resolved, end + 1);
        g_free(text);
        g_free(contents);
        text = g_string_free(resolved, FALSE);
    }
    return text;
}
static void expand_box(GHashTable *style, const char *key, const char *value)
{
    GPtrArray *parts = split_css(value, ' ');
    if (parts->len) {
        const char *top = parts->pdata[0];
        const char *right = parts->len > 1 ? parts->pdata[1] : top;
        const char *bottom = parts->len > 2 ? parts->pdata[2] : top;
        const char *left = parts->len > 3 ? parts->pdata[3] : right;
        const char *sides[] = {"top", "right", "bottom", "left"};
        const char *values[] = {top, right, bottom, left};
        for (size_t i = 0; i < G_N_ELEMENTS(sides); i++) {
            char *name = !strcmp(key, "inset") ? g_strdup(sides[i]) : g_strconcat(key, "-", sides[i], NULL);
            style_put(style, name, values[i]);
            g_free(name);
        }
    }
    g_ptr_array_unref(parts);
}
static void style_declaration(GHashTable *style, const char *name, const char *value)
{
    if (!strcmp(name, "inline-size")) name = "width";
    if (!strcmp(name, "block-size")) name = "height";
    if (!strcmp(name, "min-block-size")) name = "min-height";
    if (!strcmp(name, "max-inline-size")) name = "max-width";
    if (!strcmp(name, "padding") || !strcmp(name, "margin") || !strcmp(name, "inset")) {
        expand_box(style, name, value);
    } else if (!strcmp(name, "margin-inline")) {
        style_put(style, "margin-left", value);
        style_put(style, "margin-right", value);
    } else {
        style_put(style, name, value);
    }
}
static GHashTable *style_for(DomNode *node, GHashTable *parent)
{
    GHashTable *style = g_hash_table_new_full(g_str_hash, g_str_equal, g_free, g_free);
    if (parent) {
        GHashTableIter iterator;
        gpointer key, value;
        g_hash_table_iter_init(&iterator, parent);
        while (g_hash_table_iter_next(&iterator, &key, &value)) {
            const char *name = key;
            if (g_str_has_prefix(name, "--") || !strcmp(name, "color") || !strcmp(name, "font-size") ||
                !strcmp(name, "font-weight") || !strcmp(name, "text-align") || !strcmp(name, "line-height")) {
                style_put(style, name, value);
            }
        }
    }
    if (!style_get(style, "font-size")) style_put(style, "font-size", "16px");
    if (node->tag && node->tag[0] == 'h' && strlen(node->tag) == 2 && node->tag[1] >= '1' && node->tag[1] <= '6') {
        const char *sizes[] = {"32px", "24px", "18.72px", "16px", "13.28px", "10.72px"};
        style_put(style, "font-size", sizes[node->tag[1] - '1']);
        style_put(style, "font-weight", "700");
        expand_box(style, "margin", ".67em 0");
    }
    if (g_strcmp0(node->tag, "p") == 0) expand_box(style, "margin", "1em 0");
    if (g_strcmp0(node->tag, "small") == 0) style_put(style, "font-size", "13.33px");
    if (g_strcmp0(node->tag, "button") == 0) {
        style_put(style, "background", "#efefef");
        style_put(style, "color", "#000000");
        style_put(style, "border", "2px solid #767676");
        style_put(style, "text-align", "center");
        expand_box(style, "padding", "2px 6px");
    }
    for (size_t i = 0; i < app.page->rule_count; i++) {
        const CssRule *rule = &app.page->rules[i];
        if (rule->min_width > app.width || (rule->max_width && rule->max_width < app.width) ||
            (rule->reduced && !app.dom.reduced_motion) || !dom_matches(node, rule->selector)) continue;
        for (size_t j = 0; j < rule->count; j++) {
            style_declaration(style, rule->declarations[j].name, rule->declarations[j].value);
        }
    }
    GHashTableIter iterator;
    gpointer key, value;
    g_hash_table_iter_init(&iterator, node->style);
    while (g_hash_table_iter_next(&iterator, &key, &value)) style_declaration(style, key, ((JsValue *)value)->string);
    g_hash_table_iter_init(&iterator, style);
    while (g_hash_table_iter_next(&iterator, &key, &value)) {
        if (!g_str_has_prefix(key, "--") && strstr(value, "var(")) {
            g_hash_table_iter_replace(&iterator, resolve_variables(style, value));
        }
    }
    return style;
}
static double style_font(GHashTable *style) { return css_length(style_get(style, "font-size"), 16, 16, 16); }
static double style_length(GHashTable *style, const char *key, double basis, double fallback)
{
    return css_length(style_get(style, key), basis, style_font(style), fallback);
}
static void apply_css(GtkWidget *widget, GHashTable *style, bool control, bool image)
{
    char *name = g_strdup_printf("htgc-%u", ++app.css_id);
    gtk_widget_add_css_class(widget, name);
    g_string_append_printf(app.stylesheet, ".%s { font-family: sans-serif; ", name);
    g_free(name);
    if (control) g_string_append(app.stylesheet, "min-width: 0; min-height: 0; padding: 0; background: transparent; border: none; box-shadow: none; ");
    if (GTK_IS_TEXT_VIEW(widget)) {
        g_string_append(app.stylesheet, "border: 1px solid currentColor; border-radius: 4px; ");
    }
    const char *properties[] = {"color", "font-weight", "border", "border-top", "border-right", "border-bottom", "border-left", "border-radius", "box-shadow", "outline"};
    for (size_t i = 0; i < G_N_ELEMENTS(properties); i++) {
        const char *value = style_get(style, properties[i]);
        if (value) g_string_append_printf(app.stylesheet, "%s: %s; ", properties[i], value);
    }
    const char *background = style_get(style, "background-color");
    if (!background) {
        GPtrArray *layers = split_css(style_get(style, "background"), ',');
        const char *last = layers->len ? layers->pdata[layers->len - 1] : NULL;
        if (last && (*last == '#' || !strcmp(last, "transparent") || g_str_has_prefix(last, "rgb"))) {
            g_string_append_printf(app.stylesheet, "background-color: %s; ", last);
        }
        g_ptr_array_unref(layers);
    } else if (!image) g_string_append_printf(app.stylesheet, "background-color: %s; ", background);
    g_string_append_printf(app.stylesheet, "font-size: %.4fpx; }\n", style_font(style));
    if (style_is(style, "overflow", "hidden")) gtk_widget_set_overflow(widget, GTK_OVERFLOW_HIDDEN);
    gtk_widget_set_opacity(widget, CLAMP(style_length(style, "opacity", 1, 1), 0, 1));
}
static GdkTexture *texture(const char *path)
{
    if (!path) return NULL;
    if (*path == '/') path++;
    GdkTexture *cached = g_hash_table_lookup(app.textures, path);
    if (cached) return cached;
    for (size_t i = 0; i < site_asset_count; i++) {
        if (strcmp(path, site_assets[i])) continue;
        char *filename = g_build_filename(app.asset_directory, path, NULL);
        GError *error = NULL;
        GdkPixbuf *pixbuf = gdk_pixbuf_new_from_file(filename, &error);
        if (!pixbuf) {
            g_warning("Image %s: %s", filename, error ? error->message : "empty image");
            g_clear_error(&error);
            g_free(filename);
            return NULL;
        }
        g_free(filename);
        GdkPixbuf *oriented = gdk_pixbuf_apply_embedded_orientation(pixbuf);
        GdkPixbuf *image = oriented ? oriented : pixbuf;
        GBytes *pixels = gdk_pixbuf_read_pixel_bytes(image);
        GdkMemoryFormat format = gdk_pixbuf_get_has_alpha(image)
            ? GDK_MEMORY_R8G8B8A8 : GDK_MEMORY_R8G8B8;
        GdkTexture *value = gdk_memory_texture_new(
            gdk_pixbuf_get_width(image), gdk_pixbuf_get_height(image),
            format, pixels, gdk_pixbuf_get_rowstride(image));
        g_bytes_unref(pixels);
        g_clear_object(&oriented);
        g_object_unref(pixbuf);
        g_hash_table_insert(app.textures, g_strdup(path), value);
        return value;
    }
    return NULL;
}
typedef struct {
    cairo_surface_t *surface;
    cairo_surface_t *raster;
    int raster_width, raster_height, raster_scale;
    GdkRGBA tint;
    bool masked, cover;
    double radius;
} PicturePaint;
static cairo_surface_t *picture_surface(GdkTexture *texture)
{
    cairo_surface_t *surface = g_hash_table_lookup(app.surfaces, texture);
    if (surface) return surface;
    int width = gdk_texture_get_width(texture), height = gdk_texture_get_height(texture);
    surface = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, width, height);
    gdk_texture_download(texture, cairo_image_surface_get_data(surface), cairo_image_surface_get_stride(surface));
    cairo_surface_mark_dirty(surface);
    g_hash_table_insert(app.surfaces, texture, surface);
    return surface;
}
static void paint_picture(PicturePaint *picture, cairo_t *cr, int width, int height)
{
    double source_width = cairo_image_surface_get_width(picture->surface);
    double source_height = cairo_image_surface_get_height(picture->surface);
    double scale = picture->cover ? fmax(width / source_width, height / source_height)
                                  : fmin(width / source_width, height / source_height);
    if (scale <= 0) return;
    double r = fmin(picture->radius, fmin(width, height) / 2);
    if (r > 0) {
        cairo_new_sub_path(cr);
        cairo_arc(cr, width - r, r, r, -G_PI_2, 0);
        cairo_arc(cr, width - r, height - r, r, 0, G_PI_2);
        cairo_arc(cr, r, height - r, r, G_PI_2, G_PI);
        cairo_arc(cr, r, r, r, G_PI, 3 * G_PI_2);
        cairo_close_path(cr);
        cairo_clip(cr);
    }
    cairo_translate(cr, (width - source_width * scale) / 2, (height - source_height * scale) / 2);
    cairo_scale(cr, scale, scale);
    if (picture->masked) {
        gdk_cairo_set_source_rgba(cr, &picture->tint);
        cairo_mask_surface(cr, picture->surface, 0, 0);
    } else {
        cairo_set_source_surface(cr, picture->surface, 0, 0);
        cairo_paint(cr);
    }
}

static char *page_relative_path(const char *reference)
{
    char *escaped = g_strndup(reference, strcspn(reference, "?#"));
    char *path = g_uri_unescape_string(escaped, NULL);
    g_free(escaped);
    if (!path || !*path) return path;
    char *directory = g_path_get_dirname(app.page->path);
    char *base = g_build_filename(G_DIR_SEPARATOR_S, directory, NULL);
    char *absolute = g_canonicalize_filename(path, base);
    char *relative = g_strdup(absolute + 1);
    g_free(absolute);
    g_free(base);
    g_free(directory);
    g_free(path);
    return relative;
}

static void picture_paint_free(gpointer data)
{
    PicturePaint *picture = data;
    if (picture->raster) cairo_surface_destroy(picture->raster);
    g_free(picture);
}
static void draw_picture(GtkDrawingArea *area, cairo_t *cr, int width, int height, gpointer data)
{
    PicturePaint *picture = data;
    if (width <= 0 || height <= 0) return;
    int scale = gtk_widget_get_scale_factor(GTK_WIDGET(area));
    if (width > G_MAXINT / scale || height > G_MAXINT / scale) return;
    if (!picture->raster || width != picture->raster_width ||
        height != picture->raster_height || scale != picture->raster_scale) {
        if (picture->raster) cairo_surface_destroy(picture->raster);
        picture->raster = cairo_image_surface_create(
            CAIRO_FORMAT_ARGB32, width * scale, height * scale);
        picture->raster_width = width;
        picture->raster_height = height;
        picture->raster_scale = scale;
        cairo_surface_set_device_scale(picture->raster, scale, scale);
        cairo_t *raster = cairo_create(picture->raster);
        paint_picture(picture, raster, width, height);
        cairo_destroy(raster);
    }
    cairo_set_source_surface(cr, picture->raster, 0, 0);
    cairo_paint(cr);
}
static GtkWidget *picture(DomNode *node, GHashTable *style, double available, double height)
{
    const char *reference = dom_attr(node, "src");
    const char *mask = style_get(style, "mask-image");
    char *mask_path = NULL;
    if (mask && g_str_has_prefix(mask, "url(\"")) {
        const char *end = strrchr(mask + 5, '"');
        if (end) mask_path = g_strndup(mask + 5, end - mask - 5);
        reference = mask_path;
    }
    char *local_path = !mask_path && reference ? page_relative_path(reference) : NULL;
    if (local_path) reference = local_path;
    GdkTexture *asset = texture(reference);
    g_free(local_path);
    g_free(mask_path);
    GtkWidget *widget = gtk_drawing_area_new();
    if (asset) {
        double width = style_length(style, "width", available, -1);
        double ratio = (double)gdk_texture_get_width(asset) / gdk_texture_get_height(asset);
        if (height < 0) height = width < 0 ? gdk_texture_get_height(asset) : width / ratio;
        if (width < 0) width = height * ratio;
        PicturePaint *paint = g_new0(PicturePaint, 1);
        paint->surface = picture_surface(asset);
        paint->cover = style_is(style, "object-fit", "cover");
        paint->masked = mask != NULL;
        paint->radius = style_length(style, "border-radius", width, 0);
        const char *color = style_get(style, "background-color");
        gdk_rgba_parse(&paint->tint, color ? color : "black");
        gtk_drawing_area_set_content_width(GTK_DRAWING_AREA(widget), ceil(width));
        gtk_drawing_area_set_content_height(GTK_DRAWING_AREA(widget), ceil(height));
        gtk_drawing_area_set_draw_func(GTK_DRAWING_AREA(widget), draw_picture, paint, picture_paint_free);
        gtk_widget_set_halign(widget, GTK_ALIGN_START);
    }
    return widget;
}
static const SitePage *page_for_link(const char *href)
{
    char *path = page_relative_path(href);
    const SitePage *page = !path ? NULL : *path ? site_page(path) : app.page;
    g_free(path);
    return page;
}
static void render_page(void);
static bool load_page(const SitePage *page)
{
    if (app.initialized) {
        g_ptr_array_set_size(app.rendered_nodes, 0);
        gtk_window_set_child(GTK_WINDOW(app.window), NULL);
        js_heap_clear(&app.dom.heap);
    }
    gboolean animations = TRUE;
    g_object_get(gtk_settings_get_default(), "gtk-enable-animations", &animations, NULL);
    app.dom = (DomRuntime){ .storage = app.storage, .reduced_motion = !animations };
    app.page = page;
    app.page_start = g_get_monotonic_time();
    app.initialized = true;
    if (!site_load(&app.dom, page)) {
        g_warning("JavaScript in %s: %s", page->path, app.dom.heap.error);
        return false;
    }
    render_page();
    return true;
}
static gboolean rebuild(gpointer unused G_GNUC_UNUSED)
{
    app.pending_render = 0;
    render_page();
    return G_SOURCE_REMOVE;
}
static void queue_render(void)
{
    if (!app.pending_render) app.pending_render = g_idle_add(rebuild, NULL);
}
typedef struct { const SitePage *page; char *fragment; } Navigation;
static gboolean navigate_idle(gpointer data)
{
    Navigation *navigation = data;
    if (load_page(navigation->page) && navigation->fragment) {
        char *selector = g_strconcat("#", navigation->fragment, NULL);
        DomNode *node = dom_find(app.dom.document, selector);
        g_free(selector);
        if (node && node->widget) gtk_widget_grab_focus(node->widget);
    }
    g_free(navigation->fragment);
    g_free(navigation);
    return G_SOURCE_REMOVE;
}
static void follow_link(const char *href)
{
    if (g_str_has_prefix(href, "https://") || g_str_has_prefix(href, "http://") || g_str_has_prefix(href, "mailto:")) {
#if GTK_CHECK_VERSION(4, 10, 0)
        GtkUriLauncher *launcher = gtk_uri_launcher_new(href);
        gtk_uri_launcher_launch(launcher, GTK_WINDOW(app.window), NULL, NULL, NULL);
        g_object_unref(launcher);
#else
        gtk_show_uri(GTK_WINDOW(app.window), href, GDK_CURRENT_TIME);
#endif
        return;
    }
    const SitePage *page = page_for_link(href);
    if (!page) return;
    Navigation *navigation = g_new0(Navigation, 1);
    navigation->page = page;
    const char *hash = strchr(href, '#');
    navigation->fragment = hash ? g_uri_unescape_string(hash + 1, NULL) : NULL;
    g_idle_add(navigate_idle, navigation);
}
static void clicked(GtkButton *button G_GNUC_UNUSED, gpointer data)
{
    DomNode *node = data;
    bool has_script_listener = js_map_get(node->events, "click").kind == JS_ARRAY;
    htgc_invoke(dom_attr(node, "onclick"), "");
    dom_dispatch(node, "click");
    if (app.dom.heap.error) g_warning("JavaScript event: %s", app.dom.heap.error);
    if (g_strcmp0(node->tag, "a") == 0 && dom_attr(node, "href")) follow_link(dom_attr(node, "href"));
    else if (g_strcmp0(dom_attr(node, "type"), "submit") == 0) {
        GPtrArray *inputs = g_ptr_array_new();
        dom_query(app.dom.document, "[required]", inputs);
        for (guint i = 0; i < inputs->len; i++) {
            DomNode *input = inputs->pdata[i];
            const char *value = input->widget && GTK_IS_EDITABLE(input->widget)
                ? gtk_editable_get_text(GTK_EDITABLE(input->widget)) : dom_attr(input, "value");
            bool valid = value && *value;
            if (valid && g_strcmp0(dom_attr(input, "type"), "email") == 0) valid = strchr(value, '@') != NULL;
            if (!valid && input->widget) {
                gtk_widget_grab_focus(input->widget);
                gtk_widget_add_css_class(input->widget, "error");
                break;
            }
        }
        g_ptr_array_unref(inputs);
    } else if (has_script_listener) queue_render();
}
static void input_changed(DomNode *node, const char *value)
{
    dom_set_attr(node, "value", value);
    htgc_invoke(dom_attr(node, "oninput"), value);
    dom_dispatch(node, "input");
}
static void edit_changed(GtkEditable *editable, gpointer data)
{
    input_changed(data, js_own(g_strdup(gtk_editable_get_text(editable)), g_free));
}
static void text_changed(GtkTextBuffer *buffer, gpointer data)
{
    GtkTextIter start, end;
    gtk_text_buffer_get_bounds(buffer, &start, &end);
    input_changed(data, js_own(gtk_text_buffer_get_text(buffer, &start, &end, FALSE), g_free));
}
static bool is_inline(DomNode *node)
{
    if (!node->tag) return true;
    return !strcmp(node->tag, "span") || !strcmp(node->tag, "strong") || !strcmp(node->tag, "b") ||
        !strcmp(node->tag, "em") || !strcmp(node->tag, "small") || !strcmp(node->tag, "br");
}
static void inline_markup(DomNode *node, GString *text)
{
    if (dom_has_class(node, "visually-hidden", 15)) return;
    if (!node->tag) {
        char *escaped = g_markup_escape_text(node->text ? node->text : "", -1);
        bool was_space = text->len && g_ascii_isspace(text->str[text->len - 1]);
        for (const char *at = escaped; *at; at++) {
            bool space = g_ascii_isspace(*at);
            if (!space || !was_space) g_string_append_c(text, space ? ' ' : *at);
            was_space = space;
        }
        g_free(escaped);
        return;
    }
    if (!strcmp(node->tag, "br")) { g_string_append_c(text, '\n'); return; }
    bool bold = !strcmp(node->tag, "b") || !strcmp(node->tag, "strong");
    if (bold) g_string_append(text, "<b>");
    for (guint i = 0; i < node->children->len; i++) inline_markup(node->children->pdata[i], text);
    if (bold) g_string_append(text, "</b>");
}
static GtkWidget *label_for(DomNode *node, GHashTable *style)
{
    GString *text = g_string_new(NULL);
    inline_markup(node, text);
    GtkWidget *label = gtk_label_new(NULL);
    gtk_label_set_markup(GTK_LABEL(label), g_strstrip(text->str));
    g_string_free(text, TRUE);
    gtk_label_set_xalign(GTK_LABEL(label), style_is(style, "text-align", "center") ? .5f : 0.0f);
    gtk_label_set_wrap(GTK_LABEL(label), TRUE);
    gtk_label_set_wrap_mode(GTK_LABEL(label), PANGO_WRAP_WORD_CHAR);
    return label;
}
static GtkWidget *render_node(DomNode *node, GHashTable *parent, double available, double height_basis, bool shrink);
static GtkWidget *render_flow(DomNode *node, GHashTable *style, GPtrArray *children, double width, double height)
{
    const char *tag = node->tag;
    if (tag && (!strcmp(tag, "img") || style_get(style, "mask-image"))) return picture(node, style, width, height);
    if (tag && !strcmp(tag, "input")) {
        GtkWidget *entry = gtk_entry_new();
        const char *value = dom_attr(node, "value");
        if (value) gtk_editable_set_text(GTK_EDITABLE(entry), value);
        g_signal_connect(entry, "changed", G_CALLBACK(edit_changed), node);
        return entry;
    }
    if (tag && !strcmp(tag, "textarea")) {
        GtkWidget *field = gtk_text_view_new();
        GtkTextBuffer *buffer = gtk_text_view_get_buffer(GTK_TEXT_VIEW(field));
        const char *value = dom_attr(node, "value");
        char *initial = value ? NULL : dom_text(node);
        gtk_text_buffer_set_text(buffer, value ? value : initial, -1);
        g_free(initial);
        if (g_strcmp0(dom_attr(node, "wrap"), "off") != 0)
            gtk_text_view_set_wrap_mode(GTK_TEXT_VIEW(field), GTK_WRAP_WORD_CHAR);
        g_signal_connect(buffer, "changed", G_CALLBACK(text_changed), node);
        return field;
    }
    if (tag && !strcmp(tag, "meter")) {
        GtkWidget *meter = gtk_progress_bar_new();
        const char *value = dom_attr(node, "value");
        gtk_progress_bar_set_fraction(GTK_PROGRESS_BAR(meter), value ? CLAMP(g_ascii_strtod(value, NULL), 0, 1) : 0);
        return meter;
    }
    if (tag && !strcmp(tag, "canvas")) return gtk_drawing_area_new();
    bool row = (style_is(style, "display", "flex") || style_is(style, "display", "inline-flex")) && !style_is(style, "flex-direction", "column");
    bool inline_group = children->len > 1;
    for (guint i = 0; inline_group && i < children->len; i++) {
        GHashTable *child_style = style_for(children->pdata[i], style);
        inline_group = style_is(child_style, "display", "inline-flex") || style_is(child_style, "display", "inline-block");
        g_hash_table_unref(child_style);
    }
    row |= inline_group;
    const char *columns = style_get(style, "grid-template-columns");
    int gap = round(style_length(style, "gap", width, 0));
    bool text_only = children->len != 0;
    for (guint i = 0; i < children->len; i++) {
        DomNode *child = children->pdata[i];
        if (!is_inline(child) || dom_has_class(child, "logo", 4)) text_only = false;
    }
    if (!node->tag || (text_only && !row && !columns)) return label_for(node, style);
    if (columns) {
        GtkWidget *grid = gtk_grid_new();
        gtk_grid_set_column_spacing(GTK_GRID(grid), gap);
        gtk_grid_set_row_spacing(GTK_GRID(grid), gap);
        GPtrArray *tracks = split_css(columns, ' ');
        double equal = 0;
        guint count = tracks->len;
        if (g_str_has_prefix(columns, "repeat(")) {
            const char *minimum = strstr(columns, "minmax(");
            double min_width = minimum ? g_ascii_strtod(minimum + 7, NULL) : 1;
            count = MAX(1, (int)((width + gap) / (MAX(1, min_width) + gap)));
            if (strstr(columns, "auto-fit")) count = MIN(count, MAX(1, children->len));
            equal = (width - gap * (count - 1)) / count;
        }
        double fixed = 0, shares = 0;
        if (!equal) for (guint i = 0; i < tracks->len; i++) {
            const char *track = tracks->pdata[i];
            if (g_str_has_suffix(track, "fr")) shares += g_ascii_strtod(track, NULL);
            else fixed += css_length(track, width, style_font(style), 0);
        }
        for (guint i = 0; count && i < children->len; i++) {
            guint column = i % count;
            double item_width = equal;
            if (!equal) {
                const char *track = tracks->pdata[column];
                item_width = g_str_has_suffix(track, "fr") && shares > 0
                    ? fmax(0, width - fixed - gap * (count - 1)) * g_ascii_strtod(track, NULL) / shares
                    : css_length(track, width, style_font(style), 0);
            }
            GtkWidget *item = render_node(children->pdata[i], style, item_width, height, false);
            gtk_grid_attach(GTK_GRID(grid), item, column, i / count, 1, 1);
        }
        g_ptr_array_unref(tracks);
        return grid;
    }
    GtkWidget *box = gtk_box_new(row ? GTK_ORIENTATION_HORIZONTAL : GTK_ORIENTATION_VERTICAL, gap);
    if (inline_group && style_is(style, "text-align", "center")) gtk_widget_set_halign(box, GTK_ALIGN_CENTER);
    for (guint i = 0; i < children->len; i++) {
        if (i && row && style_is(style, "justify-content", "space-between")) {
            GtkWidget *spacer = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0);
            gtk_widget_set_hexpand(spacer, TRUE);
            gtk_box_append(GTK_BOX(box), spacer);
        }
        DomNode *child_node = children->pdata[i];
        GtkWidget *child = render_node(child_node, style, width, height, row);
        if (row && style_is(style, "align-items", "center")) gtk_widget_set_valign(child, GTK_ALIGN_CENTER);
        if (!row && (style_is(style, "place-items", "center") ||
            (is_inline(child_node) && style_is(style, "text-align", "center")))) {
            gtk_widget_set_halign(child, GTK_ALIGN_CENTER);
        }
        gtk_box_append(GTK_BOX(box), child);
    }
    return box;
}
static double translate(const char *value, char axis, double basis)
{
    if (!value) return 0;
    char marker[] = "translateX(";
    marker[9] = axis;
    const char *start = strstr(value, marker);
    if (!start) return 0;
    start += strlen(marker);
    const char *end = strchr(start, ')');
    if (!end) return 0;
    char *length = g_strndup(start, end - start);
    double result = css_length(length, basis, 16, 0);
    g_free(length);
    return result;
}
typedef struct {
    GtkWidget parent;
    double x, y;
} HtgcAnimatedLayer;
typedef GtkWidgetClass HtgcAnimatedLayerClass;

G_DEFINE_TYPE(HtgcAnimatedLayer, htgc_animated_layer, GTK_TYPE_WIDGET)

static void htgc_animated_layer_snapshot(GtkWidget *widget, GtkSnapshot *snapshot)
{
    HtgcAnimatedLayer *layer = (HtgcAnimatedLayer *)widget;
    GtkWidget *child = gtk_widget_get_first_child(widget);
    if (!child) return;
    gtk_snapshot_save(snapshot);
    gtk_snapshot_translate(snapshot, &GRAPHENE_POINT_INIT(layer->x, layer->y));
    gtk_widget_snapshot_child(widget, child, snapshot);
    gtk_snapshot_restore(snapshot);
}
static void htgc_animated_layer_dispose(GObject *object)
{
    GtkWidget *child = gtk_widget_get_first_child(GTK_WIDGET(object));
    if (child) gtk_widget_unparent(child);
    G_OBJECT_CLASS(htgc_animated_layer_parent_class)->dispose(object);
}
static void htgc_animated_layer_class_init(HtgcAnimatedLayerClass *klass)
{
    G_OBJECT_CLASS(klass)->dispose = htgc_animated_layer_dispose;
    klass->snapshot = htgc_animated_layer_snapshot;
    gtk_widget_class_set_layout_manager_type(klass, GTK_TYPE_BIN_LAYOUT);
}
static void htgc_animated_layer_init(HtgcAnimatedLayer *layer)
{
    gtk_widget_set_can_target(GTK_WIDGET(layer), FALSE);
}

typedef struct { GtkFixed *plane; double x, y, dx, dy, duration; } AnimatedTrack;
static gboolean move_track(GtkWidget *widget, GdkFrameClock *clock, gpointer data)
{
    AnimatedTrack *track = data;
    double time = fmax(0, gdk_frame_clock_get_frame_time(clock) - app.page_start);
    double progress = fmod(time, track->duration) / track->duration;
    double x = track->x + track->dx * progress;
    double y = track->y + track->dy * progress;
    if (track->plane) {
        gtk_fixed_move(track->plane, widget, x, y);
    } else {
        HtgcAnimatedLayer *layer = (HtgcAnimatedLayer *)widget;
        layer->x = x;
        layer->y = y;
        gtk_widget_queue_draw(widget);
    }
    return G_SOURCE_CONTINUE;
}
static void place_track(GtkFixed *plane, GtkWidget *widget, GHashTable *style,
                        double left, double top, double width, double height, bool decorative)
{
    const char *transform = style_get(style, "transform");
    double x = translate(transform, 'X', width);
    double y = translate(transform, 'Y', height);
    AnimatedTrack *track = NULL;
    GPtrArray *parts = split_css(app.dom.reduced_motion ? NULL : style_get(style, "animation"), ' ');
    if (parts->len == 4 && !strcmp(parts->pdata[2], "linear") && !strcmp(parts->pdata[3], "infinite")) {
        char *unit;
        double duration = g_ascii_strtod(parts->pdata[1], &unit);
        if (!strcmp(unit, "s")) duration *= G_USEC_PER_SEC;
        else if (!strcmp(unit, "ms")) duration *= 1000;
        else duration = 0;
        for (size_t i = 0; duration > 0 && i < site_animation_count; i++) {
            const SiteAnimation *animation = &site_animations[i];
            if (strcmp(animation->name, parts->pdata[0])) continue;
            x = translate(animation->from, 'X', width);
            y = translate(animation->from, 'Y', height);
            track = g_new(AnimatedTrack, 1);
            *track = (AnimatedTrack){plane, x, y,
                translate(animation->to, 'X', width) - x,
                translate(animation->to, 'Y', height) - y, duration};
            break;
        }
    }
    g_ptr_array_unref(parts);
    if (track && decorative) {
        HtgcAnimatedLayer *layer = g_object_new(htgc_animated_layer_get_type(), NULL);
        layer->x = x;
        layer->y = y;
        gtk_widget_set_parent(widget, GTK_WIDGET(layer));
        track->plane = NULL;
        widget = GTK_WIDGET(layer);
        gtk_fixed_put(plane, widget, left, top);
    } else {
        gtk_fixed_put(plane, widget, left + x, top + y);
        if (track) {
            track->x += left;
            track->y += top;
        }
    }
    if (track) gtk_widget_add_tick_callback(widget, move_track, track, g_free);
}
static GtkWidget *render_node(DomNode *node, GHashTable *parent, double available, double height_basis, bool shrink)
{
    GHashTable *style = style_for(node, parent);
    double width = style_length(style, "width", available, available);
    width = fmin(width, style_length(style, "max-width", available, width));
    double height = style_length(style, "height", height_basis, -1);
    double minimum = style_length(style, "min-height", height_basis, 0);
    if (g_strcmp0(node->tag, "textarea") == 0) {
        if (height < 0) {
            const char *rows = dom_attr(node, "rows");
            char *end = NULL;
            gint64 count = rows ? g_ascii_strtoll(rows, &end, 10) : 0;
            if (count <= 0 || *end) count = 2;
            height = MIN((double)G_MAXINT, count * fmax(1, style_font(style)) * 1.6);
        }
        height = fmax(height, minimum);
    }
    double padding[4];
    const char *edges[] = {"top", "right", "bottom", "left"};
    for (size_t i = 0; i < 4; i++) {
        char *name = g_strconcat("padding-", edges[i], NULL);
        padding[i] = style_length(style, name, width, 0);
        g_free(name);
    }
    double inner_width = fmax(0, width - padding[1] - padding[3]);
    GPtrArray *children = g_ptr_array_new(), *positioned = g_ptr_array_new();
    for (guint i = 0; i < node->children->len; i++) {
        DomNode *child = node->children->pdata[i];
        if (!child->tag && child->text && strspn(child->text, " \t\r\n") == strlen(child->text)) continue;
        if (g_strcmp0(dom_attr(child, "type"), "hidden") == 0) continue;
        GHashTable *child_style = style_for(child, style);
        if (!style_is(child_style, "display", "none")) {
            g_ptr_array_add(style_is(child_style, "position", "absolute") ? positioned : children, child);
        }
        g_hash_table_unref(child_style);
    }
    GtkWidget *content = render_flow(node, style, children, inner_width, height < 0 ? height_basis : height);
    g_ptr_array_unref(children);
    gtk_widget_set_margin_top(content, MAX(0, round(padding[0])));
    gtk_widget_set_margin_end(content, MAX(0, round(padding[1])));
    gtk_widget_set_margin_bottom(content, MAX(0, round(padding[2])));
    gtk_widget_set_margin_start(content, MAX(0, round(padding[3])));
    if (positioned->len) {
        GtkWidget *overlay = gtk_overlay_new(), *underlay = gtk_fixed_new();
        GtkWidget *base = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
        double layer_height = height >= 0 ? height : minimum > 0 ? minimum : height_basis;
        gtk_widget_set_size_request(base, ceil(width), ceil(layer_height));
        gtk_overlay_set_child(GTK_OVERLAY(overlay), base);
        gtk_overlay_add_overlay(GTK_OVERLAY(overlay), underlay);
        for (guint i = 0; i < positioned->len; i++) {
            DomNode *child = positioned->pdata[i];
            GHashTable *child_style = style_for(child, style);
            double left = style_length(child_style, "left", width, 0);
            double top = style_length(child_style, "top", layer_height, 0);
            double right = style_length(child_style, "right", width, -1);
            double bottom = style_length(child_style, "bottom", layer_height, -1);
            double child_width = right >= 0 ? width - left - right : width;
            double child_height = bottom >= 0 ? layer_height - top - bottom : layer_height;
            GtkWidget *item = render_node(child, style, child_width, child_height, right < 0);
            if (bottom >= 0 && !style_get(child_style, "height")) gtk_widget_set_size_request(item, -1, ceil(child_height));
            int natural_width, natural_height;
            gtk_widget_measure(item, GTK_ORIENTATION_HORIZONTAL, -1, NULL, &natural_width, NULL, NULL);
            gtk_widget_measure(item, GTK_ORIENTATION_VERTICAL, natural_width, NULL, &natural_height, NULL, NULL);
            if (bottom >= 0 && !style_get(child_style, "top")) top = layer_height - bottom - natural_height;
            bool decorative = style_is(child_style, "pointer-events", "none") ||
                (style_is(style, "pointer-events", "none") && !style_get(child_style, "pointer-events"));
            place_track(GTK_FIXED(underlay), item, child_style, left, top, natural_width, natural_height, decorative);
            if (decorative) gtk_widget_set_can_target(item, FALSE);
            g_hash_table_unref(child_style);
        }
        if (style_is(style, "place-items", "center")) gtk_widget_set_valign(content, GTK_ALIGN_CENTER);
        gtk_overlay_add_overlay(GTK_OVERLAY(overlay), content);
        gtk_overlay_set_measure_overlay(GTK_OVERLAY(overlay), content, TRUE);
        content = overlay;
    }
    g_ptr_array_unref(positioned);
    bool action = g_strcmp0(node->tag, "a") == 0 || g_strcmp0(node->tag, "button") == 0;
    bool control = action || g_strcmp0(node->tag, "input") == 0 || g_strcmp0(node->tag, "textarea") == 0;
    GtkWidget *widget;
    if (action) {
        widget = gtk_button_new();
        gtk_button_set_child(GTK_BUTTON(widget), content);
        g_signal_connect(widget, "clicked", G_CALLBACK(clicked), node);
    } else if (control) widget = content;
    else {
        widget = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
        gtk_box_append(GTK_BOX(widget), content);
    }
    bool image = g_strcmp0(node->tag, "img") == 0 || style_get(style, "mask-image") != NULL;
    if (!image) gtk_widget_set_size_request(widget,
        shrink && !style_get(style, "width") ? -1 : ceil(width),
        height >= 0 ? ceil(height) : minimum > 0 ? ceil(minimum) : -1);
    if (style_is(style, "margin-left", "auto") && style_is(style, "margin-right", "auto")) gtk_widget_set_halign(widget, GTK_ALIGN_CENTER);
    if (style_get(style, "max-width")) gtk_widget_set_halign(widget, GTK_ALIGN_START);
    gtk_widget_set_margin_top(widget, MAX(0, round(style_length(style, "margin-top", width, 0))));
    gtk_widget_set_margin_bottom(widget, MAX(0, round(style_length(style, "margin-bottom", width, 0))));
    if (dom_attr(node, "id")) gtk_widget_set_focusable(widget, TRUE);
    apply_css(widget, style, control, image);
    node->widget = widget;
    g_ptr_array_add(app.rendered_nodes, node);
    g_hash_table_unref(style);
    return widget;
}
static bool contains_sticky(DomNode *node, GHashTable *parent)
{
    GHashTable *style = style_for(node, parent);
    bool sticky = style_is(style, "position", "sticky");
    for (guint i = 0; !sticky && i < node->children->len; i++) sticky = contains_sticky(node->children->pdata[i], style);
    g_hash_table_unref(style);
    return sticky;
}
static void render_page(void)
{
    if (!app.initialized) return;
    DomNode *html = dom_find(app.dom.document, "html"), *body = dom_find(app.dom.document, "body");
    if (!html || !body) return;
    for (guint i = 0; i < app.rendered_nodes->len; i++) {
        DomNode *node = app.rendered_nodes->pdata[i];
        node->widget = NULL;
    }
    g_ptr_array_set_size(app.rendered_nodes, 0);
    GHashTable *root_style = style_for(html, NULL), *body_style = style_for(body, root_style);
    if (app.provider) {
        gtk_style_context_remove_provider_for_display(gtk_widget_get_display(app.window), GTK_STYLE_PROVIDER(app.provider));
        g_clear_object(&app.provider);
    }
    app.stylesheet = g_string_new("textview text { background-color: transparent; }\n");
    app.css_id = 0;
    GtkWidget *root = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
    GtkWidget *scroll = gtk_scrolled_window_new();
    GtkWidget *flow = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
    gtk_scrolled_window_set_policy(GTK_SCROLLED_WINDOW(scroll), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC);
    gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(scroll), flow);
    gtk_widget_set_vexpand(scroll, TRUE);
    for (guint i = 0; i < body->children->len; i++) {
        DomNode *node = body->children->pdata[i];
        if (!node->tag && (!node->text || strspn(node->text, " \t\r\n") == strlen(node->text))) continue;
        GtkWidget *widget = render_node(node, body_style, app.width, app.height, false);
        gtk_box_append(GTK_BOX(contains_sticky(node, body_style) ? root : flow), widget);
    }
    gtk_box_append(GTK_BOX(root), scroll);
    apply_css(root, body_style, false, false);
    app.provider = gtk_css_provider_new();
#if GTK_CHECK_VERSION(4, 12, 0)
    gtk_css_provider_load_from_string(app.provider, app.stylesheet->str);
#else
    gtk_css_provider_load_from_data(app.provider, app.stylesheet->str, -1);
#endif
    g_string_free(app.stylesheet, TRUE);
    gtk_style_context_add_provider_for_display(gtk_widget_get_display(app.window), GTK_STYLE_PROVIDER(app.provider), GTK_STYLE_PROVIDER_PRIORITY_APPLICATION);
    gtk_window_set_child(GTK_WINDOW(app.window), root);
    gtk_window_set_title(GTK_WINDOW(app.window), app.page->title);
    app.scroller = scroll;
    g_hash_table_unref(body_style);
    g_hash_table_unref(root_style);
}
static gboolean frame(GtkWidget *window, GdkFrameClock *clock G_GNUC_UNUSED, gpointer unused G_GNUC_UNUSED)
{
    double width = gtk_widget_get_width(window), height = gtk_widget_get_height(window);
    if (width > 0 && height > 0 && (width != app.width || height != app.height)) {
        app.width = width;
        app.height = height;
        queue_render();
    }
    for (guint i = 0; i < app.dom.observers->len; i++) {
        DomObserver *observer = app.dom.observers->pdata[i];
        if (observer->resize) continue;
        GArray *entries = NULL;
        for (guint j = 0; j < observer->nodes->len; j++) {
            DomNode *node = observer->nodes->pdata[j];
            graphene_rect_t bounds;
            if (!node->widget || !gtk_widget_compute_bounds(node->widget, window, &bounds)) continue;
            bool visible = bounds.origin.y < height && bounds.origin.y + bounds.size.height > 0;
            if (!visible || g_hash_table_contains(observer->reported, node)) continue;
            g_hash_table_insert(observer->reported, node, g_new0(DomRect, 1));
            if (!entries) entries = js_array((JsArgs){0, NULL}).array;
            JsValue entry = js_object();
            js_set(entry, "target", dom_value(node));
            js_set(entry, "isIntersecting", js_bool(true));
            g_array_append_val(entries, entry);
        }
        if (entries) {
            JsValue value = { .kind = JS_ARRAY, .array = entries };
            js_call(observer->callback, js_undefined, (JsArgs){1, &value});
            queue_render();
        }
    }
    return G_SOURCE_CONTINUE;
}
static void activate(GtkApplication *application, gpointer user_data)
{
    app.application = application;
    app.window = gtk_application_window_new(application);
    app.width = 1280;
    app.height = 720;
    gtk_window_set_default_size(GTK_WINDOW(app.window), app.width, app.height);
    if (!load_page(user_data)) { g_application_quit(G_APPLICATION(application)); return; }
    gtk_widget_add_tick_callback(app.window, frame, NULL, NULL);
    gtk_window_present(GTK_WINDOW(app.window));
}
int main(int argc, char **argv)
{
    const SitePage *page = site_page(site_entry);
    if (!page) { fprintf(stderr, "Embedded entry page is missing\\n"); return 2; }
    char *executable = NULL;
#ifdef __linux__
    executable = g_file_read_link("/proc/self/exe", NULL);
#endif
    if (!executable) executable = g_find_program_in_path(argv[0]);
    char *directory = g_path_get_dirname(executable ? executable : argv[0]);
    app.asset_directory = g_build_filename(directory, site_asset_directory, NULL);
    g_free(directory);
    g_free(executable);
    app.rendered_nodes = g_ptr_array_new();
    app.storage = g_hash_table_new_full(g_str_hash, g_str_equal, g_free, g_free);
    app.textures = g_hash_table_new_full(g_str_hash, g_str_equal, g_free, g_object_unref);
    app.surfaces = g_hash_table_new_full(g_direct_hash, g_direct_equal, NULL, (GDestroyNotify)cairo_surface_destroy);
    if (argc > 1 && (!strcmp(argv[1], "light") || !strcmp(argv[1], "dark") || !strcmp(argv[1], "auto"))) {
        g_hash_table_insert(app.storage, g_strdup("theme"), g_strdup(argv[1]));
    }
    GtkApplication *application = gtk_application_new(NULL, G_APPLICATION_NON_UNIQUE);
    g_signal_connect(application, "activate", G_CALLBACK(activate), (gpointer)page);
    int result = g_application_run(G_APPLICATION(application), 1, argv);
    g_object_unref(application);
    if (app.pending_render) g_source_remove(app.pending_render);
    if (app.initialized) {
        if (app.dom.heap.error) result = 1;
        js_heap_clear(&app.dom.heap);
    }
    g_clear_object(&app.provider);
    g_ptr_array_unref(app.rendered_nodes);
    g_hash_table_unref(app.storage);
    g_hash_table_unref(app.surfaces);
    g_hash_table_unref(app.textures);
    g_free(app.asset_directory);
    return result;
}
