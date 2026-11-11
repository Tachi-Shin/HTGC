/* DOM objects and host calls used by generated C. */
#include <libxml/HTMLparser.h>
#include <libxml/tree.h>
#include <stdio.h>

typedef struct DomNode DomNode;
typedef struct DomObserver DomObserver;
typedef struct { double x, y, width, height; } DomRect;
typedef struct { const char *name, *value; } DomAttribute;
typedef struct {
    const char *tag, *text;
    const DomAttribute *attributes;
    size_t attribute_count;
    int parent;
} DomSpec;
struct DomNode {
    const char *tag, *text;
    DomNode *parent;
    GPtrArray *children;
    GHashTable *attributes, *properties, *style, *events;
    gpointer widget;
    DomRect rect;
    double canvas_width, canvas_height;
    JsValue canvas;
    bool upgraded;
};
struct DomObserver { JsValue callback; GPtrArray *nodes; bool resize; GHashTable *reported; };
typedef struct {
    JsHeap heap;
    DomNode *document;
    GHashTable *custom_elements;
    GPtrArray *observers;
    GArray *frames;
    GHashTable *storage;
    bool dark, reduced_motion;
    void (*storage_changed)(GHashTable *);
    void (*changed)(void);
} DomRuntime;
static DomRuntime *dom_runtime;

static GPtrArray *dom_vector(void) { return js_own(g_ptr_array_new(), (GDestroyNotify)g_ptr_array_unref); }
static JsValue dom_value(DomNode *node) { return node ? (JsValue){ .kind = JS_NODE, .host = node } : js_null; }
static DomNode *dom_node(const char *tag, const char *text)
{
    DomNode *node = js_alloc(sizeof(*node));
    node->tag = tag;
    node->text = text;
    node->children = dom_vector();
    node->attributes = js_map();
    node->properties = js_map();
    node->style = js_map();
    node->events = js_map();
    node->canvas_width = 300;
    node->canvas_height = 150;
    return node;
}
static void dom_append(DomNode *parent, DomNode *child)
{
    if (child->parent) g_ptr_array_remove(child->parent->children, child);
    g_ptr_array_add(parent->children, child);
    child->parent = parent;
}
static void dom_remove_children(DomNode *parent)
{
    for (guint i = 0; i < parent->children->len; i++) {
        ((DomNode *)parent->children->pdata[i])->parent = NULL;
    }
    g_ptr_array_set_size(parent->children, 0);
}
static const char *dom_attr(const DomNode *node, const char *name)
{
    JsValue value = js_map_get(node->attributes, name);
    return value.kind == JS_STRING ? value.string : NULL;
}
static void dom_set_attr(DomNode *node, const char *name, const char *value)
{
    js_map_set(node->attributes, name, js_string(value));
}
static bool dom_has_class(const DomNode *node, const char *name, size_t length)
{
    const char *classes = dom_attr(node, "class");
    if (!classes) return false;
    while (*classes) {
        while (g_ascii_isspace(*classes)) classes++;
        const char *end = classes;
        while (*end && !g_ascii_isspace(*end)) end++;
        if ((size_t)(end - classes) == length && !strncmp(classes, name, length)) return true;
        classes = end;
    }
    return false;
}
static bool dom_identifier(char c) { return g_ascii_isalnum(c) || c == '_' || c == '-'; }
static bool dom_part_matches(const DomNode *node, const char *part, const char *end)
{
    if (!node || !node->tag || *node->tag == '#') return false;
    const char *cursor = part;
    if (cursor < end && *cursor == '*') cursor++;
    else if (cursor < end && dom_identifier(*cursor)) {
        while (cursor < end && dom_identifier(*cursor)) cursor++;
        if (strlen(node->tag) != (size_t)(cursor - part) || strncmp(node->tag, part, cursor - part)) return false;
    }
    while (cursor < end) {
        const char kind = *cursor++;
        if (kind == '[') {
            const char *close = memchr(cursor, ']', end - cursor);
            if (!close) return false;
            const char *equals = memchr(cursor, '=', close - cursor);
            char *name = g_strndup(cursor, (equals ? equals : close) - cursor);
            const char *actual = dom_attr(node, g_strstrip(name));
            g_free(name);
            if (!actual) return false;
            if (equals) {
                const char *start = equals + 1;
                while (start < close && g_ascii_isspace(*start)) start++;
                const char *last = close;
                while (last > start && g_ascii_isspace(last[-1])) last--;
                if (last - start >= 2 && (*start == '"' || *start == '\'') && last[-1] == *start) { start++; last--; }
                if (strlen(actual) != (size_t)(last - start) || strncmp(actual, start, last - start)) return false;
            }
            cursor = close + 1;
            continue;
        }
        const char *start = cursor;
        while (cursor < end && dom_identifier(*cursor)) cursor++;
        size_t length = cursor - start;
        if (!length) return false;
        if (kind == '.') {
            if (!dom_has_class(node, start, length)) return false;
        } else if (kind == '#') {
            const char *id = dom_attr(node, "id");
            if (!id || strlen(id) != length || strncmp(id, start, length)) return false;
        } else if (kind == ':') {
            if (length == 4 && !strncmp(start, "root", length)) {
                if (strcmp(node->tag, "html")) return false;
            } else if (length == 5 && !strncmp(start, "hover", length)) {
                if (!dom_attr(node, "data-htgc-hover")) return false;
            } else if ((length == 5 && !strncmp(start, "focus", length)) ||
                       (length == 13 && !strncmp(start, "focus-visible", length))) {
                if (!dom_attr(node, "data-htgc-focus")) return false;
            } else return false;
        } else return false;
    }
    return true;
}
static bool dom_matches(const DomNode *node, const char *selector)
{
    /* Separate descendant selectors outside attribute brackets. */
    const char *last = selector + strlen(selector);
    while (last > selector && g_ascii_isspace(last[-1])) last--;
    bool first = true;
    while (last > selector) {
        const char *start = last;
        int brackets = 0;
        while (start > selector) {
            char c = start[-1];
            if (c == ']') brackets++;
            if (c == '[') brackets--;
            if (!brackets && g_ascii_isspace(c)) break;
            start--;
        }
        if (!first) {
            while (node && !dom_part_matches(node, start, last)) node = node->parent;
        }
        if (!dom_part_matches(node, start, last)) return false;
        node = node->parent;
        last = start;
        while (last > selector && g_ascii_isspace(last[-1])) last--;
        first = false;
    }
    return !first;
}
static void dom_query(DomNode *root, const char *selector, GPtrArray *matches)
{
    for (guint i = 0; i < root->children->len; i++) {
        DomNode *child = root->children->pdata[i];
        if (dom_matches(child, selector)) g_ptr_array_add(matches, child);
        dom_query(child, selector, matches);
    }
}
static DomNode *dom_find(DomNode *root, const char *selector)
{
    for (guint i = 0; i < root->children->len; i++) {
        DomNode *child = root->children->pdata[i];
        if (dom_matches(child, selector)) return child;
        DomNode *found = dom_find(child, selector);
        if (found) return found;
    }
    return NULL;
}
static void dom_collect_text(DomNode *node, GString *text)
{
    if (node->text) g_string_append(text, node->text);
    for (guint i = 0; i < node->children->len; i++) dom_collect_text(node->children->pdata[i], text);
}
static char *dom_text(DomNode *node)
{
    GString *text = g_string_new(NULL);
    dom_collect_text(node, text);
    return g_string_free(text, FALSE);
}
static void dom_import_xml(DomNode *parent, xmlNodePtr source)
{
    for (; source; source = source->next) {
        if (source->type == XML_TEXT_NODE) {
            if (source->content) dom_append(parent, dom_node(NULL, js_own(g_strdup((char *)source->content), g_free)));
            continue;
        }
        if (source->type != XML_ELEMENT_NODE) continue;
        DomNode *child = dom_node(js_own(g_strdup((char *)source->name), g_free), NULL);
        for (xmlAttrPtr attr = source->properties; attr; attr = attr->next) {
            xmlChar *value = xmlNodeListGetString(source->doc, attr->children, 1);
            dom_set_attr(child, (char *)attr->name, js_own(g_strdup(value ? (char *)value : ""), g_free));
            xmlFree(value);
        }
        dom_append(parent, child);
        dom_import_xml(child, source->children);
    }
}
static void dom_upgrade(DomNode *node)
{
    if (node->tag && !node->upgraded) {
        JsValue cls = js_map_get(dom_runtime->custom_elements, node->tag);
        if (cls.kind == JS_CLASS) {
            node->upgraded = true;
            JsValue callback = js_map_get(cls.klass->methods, "connectedCallback");
            if (callback.kind == JS_FUNCTION) js_call(callback, dom_value(node), (JsArgs){0, NULL});
        }
    }
    for (guint i = 0; i < node->children->len; i++) dom_upgrade(node->children->pdata[i]);
}
static void dom_set_html(DomNode *node, const char *text)
{
    char *wrapped = g_strconcat("<div>", text, "</div>", NULL);
    htmlDocPtr fragment = htmlReadMemory(wrapped, strlen(wrapped), NULL, "UTF-8",
        HTML_PARSE_NONET | HTML_PARSE_NOIMPLIED | HTML_PARSE_NODEFDTD | HTML_PARSE_NOERROR | HTML_PARSE_NOWARNING);
    g_free(wrapped);
    if (!fragment) { js_error("Invalid innerHTML fragment"); return; }
    xmlNodePtr root = xmlDocGetRootElement(fragment);
    dom_remove_children(node);
    if (root) dom_import_xml(node, root->children);
    xmlFreeDoc(fragment);
    dom_upgrade(node);
}
static void dom_changed(void) { if (dom_runtime->changed) dom_runtime->changed(); }
static char *dom_dataset_name(const char *key)
{
    GString *name = g_string_new("data-");
    for (; *key; key++) {
        if (g_ascii_isupper(*key)) g_string_append_c(name, '-');
        g_string_append_c(name, g_ascii_tolower(*key));
    }
    return g_string_free(name, FALSE);
}

JS_METHOD(dom_query_one) { return dom_value(dom_find(receiver.host, js_to_string(js_arg(args, 0)))); }
JS_METHOD(dom_query_all)
{
    GPtrArray *matches = g_ptr_array_new();
    dom_query(receiver.host, js_to_string(js_arg(args, 0)), matches);
    JsValue values = js_array((JsArgs){0, NULL});
    for (guint i = 0; i < matches->len; i++) {
        JsValue item = dom_value(matches->pdata[i]);
        g_array_append_val(values.array, item);
    }
    g_ptr_array_unref(matches);
    return values;
}
JS_METHOD(dom_element_by_id)
{
    char *query = g_strconcat("#", js_to_string(js_arg(args, 0)), NULL);
    DomNode *result = dom_find(receiver.host, query);
    g_free(query);
    return dom_value(result);
}
JS_METHOD(dom_create_element) { return dom_value(dom_node(js_to_string(js_arg(args, 0)), NULL)); }
JS_METHOD(dom_fragment) { return dom_value(dom_node("#fragment", NULL)); }
JS_METHOD(dom_get_attribute)
{
    const char *value = dom_attr(receiver.host, js_to_string(js_arg(args, 0)));
    return value ? js_string(value) : js_null;
}
JS_METHOD(dom_set_attribute)
{
    dom_set_attr(receiver.host, js_to_string(js_arg(args, 0)), js_to_string(js_arg(args, 1)));
    dom_changed();
    return js_undefined;
}
JS_METHOD(dom_append_child)
{
    JsValue item = js_arg(args, 0);
    if (item.kind != JS_NODE) return js_error("appendChild expects a node");
    DomNode *child = item.host;
    for (DomNode *ancestor = receiver.host; ancestor; ancestor = ancestor->parent) {
        if (ancestor == child) return js_error("Cannot append an ancestor");
    }
    if (child->tag && !strcmp(child->tag, "#fragment")) {
        while (child->children->len) {
            DomNode *part = child->children->pdata[0];
            dom_append(receiver.host, part);
            dom_upgrade(part);
        }
    } else {
        dom_append(receiver.host, child);
        dom_upgrade(child);
    }
    dom_changed();
    return item;
}
JS_METHOD(dom_add_listener)
{
    DomNode *node = receiver.host;
    const char *type = js_to_string(js_arg(args, 0));
    JsValue listeners = js_map_get(node->events, type);
    if (listeners.kind != JS_ARRAY) listeners = js_map_set(node->events, type, js_array((JsArgs){0, NULL}));
    JsValue callback = js_arg(args, 1);
    g_array_append_val(listeners.array, callback);
    return js_undefined;
}
static void dom_dispatch(DomNode *node, const char *name)
{
    JsValue listeners = js_map_get(node->events, name);
    if (listeners.kind != JS_ARRAY) return;
    JsValue event = js_object();
    js_set(event, "type", js_string(name));
    js_set(event, "target", dom_value(node));
    js_set(event, "currentTarget", dom_value(node));
    for (guint i = 0; i < listeners.array->len; i++) {
        js_call(js_index(listeners, i), dom_value(node), (JsArgs){1, &event});
    }
}
JS_METHOD(dom_class_add)
{
    DomNode *node = receiver.host;
    const char *name = js_to_string(js_arg(args, 0));
    const char *classes = dom_attr(node, "class");
    if (!dom_has_class(node, name, strlen(name))) {
        dom_set_attr(node, "class", classes && *classes ? js_own(g_strconcat(classes, " ", name, NULL), g_free) : name);
        dom_changed();
    }
    return js_undefined;
}
JS_METHOD(dom_style_set)
{
    DomNode *node = receiver.host;
    js_map_set(node->style, js_to_string(js_arg(args, 0)), js_string(js_to_string(js_arg(args, 1))));
    dom_changed();
    return js_undefined;
}
JS_METHOD(dom_bounds)
{
    DomRect rect = ((DomNode *)receiver.host)->rect;
    JsValue value = js_object();
    js_set(value, "x", js_number(rect.x));
    js_set(value, "y", js_number(rect.y));
    js_set(value, "width", js_number(rect.width));
    js_set(value, "height", js_number(rect.height));
    return value;
}
JS_METHOD(dom_observe)
{
    DomObserver *observer = receiver.host;
    JsValue item = js_arg(args, 0);
    if (item.kind != JS_NODE) return js_error("observe expects a node");
    if (!g_ptr_array_find(observer->nodes, item.host, NULL)) g_ptr_array_add(observer->nodes, item.host);
    return js_undefined;
}
JS_METHOD(dom_unobserve)
{
    DomObserver *observer = receiver.host;
    JsValue item = js_arg(args, 0);
    if (item.kind == JS_NODE) g_ptr_array_remove(observer->nodes, item.host);
    return js_undefined;
}
static JsValue dom_observer(JsValue callback, bool resize)
{
    DomObserver *observer = js_alloc(sizeof(*observer));
    observer->callback = callback;
    observer->resize = resize;
    observer->nodes = dom_vector();
    observer->reported = js_own(g_hash_table_new_full(g_direct_hash, g_direct_equal, NULL, g_free), (GDestroyNotify)g_hash_table_unref);
    g_ptr_array_add(dom_runtime->observers, observer);
    return (JsValue){ .kind = JS_OBSERVER, .host = observer };
}
JS_METHOD(dom_intersection) { return dom_observer(js_arg(args, 0), false); }
JS_METHOD(dom_resize) { return dom_observer(js_arg(args, 0), true); }
JS_METHOD(dom_frame)
{
    JsValue callback = js_arg(args, 0);
    g_array_append_val(dom_runtime->frames, callback);
    return js_number(dom_runtime->frames->len);
}
JS_METHOD(dom_define_element)
{
    JsValue cls = js_arg(args, 1);
    if (cls.kind != JS_CLASS) return js_error("Custom element definition must be a class");
    js_map_set(dom_runtime->custom_elements, js_to_string(js_arg(args, 0)), cls);
    dom_upgrade(dom_runtime->document);
    return js_undefined;
}
JS_METHOD(dom_media)
{
    const char *query = js_to_string(js_arg(args, 0));
    bool matches = (strstr(query, "prefers-color-scheme: dark") && dom_runtime->dark) ||
        (strstr(query, "prefers-reduced-motion: reduce") && dom_runtime->reduced_motion);
    JsValue result = js_object();
    js_set(result, "matches", js_bool(matches));
    return result;
}
JS_METHOD(dom_storage_get)
{
    const char *value = g_hash_table_lookup(dom_runtime->storage, js_to_string(js_arg(args, 0)));
    return value ? js_owned_string(g_strdup(value)) : js_null;
}
JS_METHOD(dom_storage_set)
{
    g_hash_table_replace(dom_runtime->storage, g_strdup(js_to_string(js_arg(args, 0))), g_strdup(js_to_string(js_arg(args, 1))));
    if (dom_runtime->storage_changed) dom_runtime->storage_changed(dom_runtime->storage);
    return js_undefined;
}

static JsValue js_host_get(JsValue object, const char *key)
{
    if (object.kind == JS_OBSERVER) {
        if (!strcmp(key, "observe")) return js_native(dom_observe);
        if (!strcmp(key, "unobserve")) return js_native(dom_unobserve);
        return js_undefined;
    }
    DomNode *node = object.host;
    if (object.kind == JS_DATASET) {
        char *name = dom_dataset_name(key);
        JsValue value = js_map_get(node->attributes, name);
        g_free(name);
        return value;
    }
    if (object.kind == JS_STYLE) {
        if (!strcmp(key, "setProperty")) return js_native(dom_style_set);
        return js_map_get(node->style, key);
    }
    if (object.kind == JS_CLASSLIST) return !strcmp(key, "add") ? js_native(dom_class_add) : js_undefined;
    if (object.kind != JS_NODE) return js_undefined;
    if (!strcmp(key, "documentElement")) return dom_value(dom_find(node, "html"));
    if (!strcmp(key, "body")) return dom_value(dom_find(node, "body"));
    if (!strcmp(key, "className")) { const char *name = dom_attr(node, "class"); return js_string(name ? name : ""); }
    if (!strcmp(key, "textContent")) return js_owned_string(dom_text(node));
    if (!strcmp(key, "dataset")) return (JsValue){ .kind = JS_DATASET, .host = node };
    if (!strcmp(key, "classList")) return (JsValue){ .kind = JS_CLASSLIST, .host = node };
    if (!strcmp(key, "style")) return (JsValue){ .kind = JS_STYLE, .host = node };
    if (!strcmp(key, "width")) return js_number(node->canvas_width);
    if (!strcmp(key, "height")) return js_number(node->canvas_height);
    if (!strcmp(key, "querySelector")) return js_native(dom_query_one);
    if (!strcmp(key, "querySelectorAll")) return js_native(dom_query_all);
    if (!strcmp(key, "getElementById")) return js_native(dom_element_by_id);
    if (!strcmp(key, "createElement")) return js_native(dom_create_element);
    if (!strcmp(key, "createDocumentFragment")) return js_native(dom_fragment);
    if (!strcmp(key, "getAttribute")) return js_native(dom_get_attribute);
    if (!strcmp(key, "setAttribute")) return js_native(dom_set_attribute);
    if (!strcmp(key, "appendChild")) return js_native(dom_append_child);
    if (!strcmp(key, "addEventListener")) return js_native(dom_add_listener);
    if (!strcmp(key, "getBoundingClientRect")) return js_native(dom_bounds);
    return js_map_get(node->properties, key);
}
static JsValue js_host_set(JsValue object, const char *key, JsValue value)
{
    if (object.kind == JS_OBSERVER) return js_error("Unsupported observer property");
    DomNode *node = object.host;
    if (object.kind == JS_DATASET) {
        char *name = dom_dataset_name(key);
        dom_set_attr(node, name, js_to_string(value));
        g_free(name);
    } else if (object.kind == JS_STYLE) {
        js_map_set(node->style, key, js_string(js_to_string(value)));
    } else if (object.kind == JS_NODE) {
        if (!strcmp(key, "className")) dom_set_attr(node, "class", js_to_string(value));
        else if (!strcmp(key, "innerHTML")) dom_set_html(node, js_to_string(value));
        else if (!strcmp(key, "textContent")) {
            dom_remove_children(node);
            dom_append(node, dom_node(NULL, js_to_string(value)));
        } else if (!strcmp(key, "width")) node->canvas_width = js_to_number(value);
        else if (!strcmp(key, "height")) node->canvas_height = js_to_number(value);
        else js_map_set(node->properties, key, value);
    } else return js_error("Unsupported host property");
    dom_changed();
    return value;
}
static JsScope *dom_load(DomRuntime *runtime, const DomSpec *spec, size_t count)
{
    dom_runtime = runtime;
    js_heap_init(&runtime->heap);
    runtime->document = dom_node("#document", NULL);
    runtime->custom_elements = js_map();
    runtime->observers = dom_vector();
    runtime->frames = js_own(g_array_new(FALSE, FALSE, sizeof(JsValue)), (GDestroyNotify)g_array_unref);
    DomNode **nodes = g_new(DomNode *, count);
    for (size_t i = 0; i < count; i++) {
        nodes[i] = dom_node(spec[i].tag, spec[i].text);
        for (size_t j = 0; j < spec[i].attribute_count; j++) dom_set_attr(nodes[i], spec[i].attributes[j].name, spec[i].attributes[j].value);
        dom_append(spec[i].parent < 0 ? runtime->document : nodes[spec[i].parent], nodes[i]);
    }
    g_free(nodes);
    JsScope *scope = js_scope(NULL);
    js_builtins(scope);
    JsValue window = js_object(), storage = js_object(), custom = js_object();
    js_set(window, "matchMedia", js_native(dom_media));
    js_set(window, "devicePixelRatio", js_number(1));
    js_set(storage, "getItem", js_native(dom_storage_get));
    js_set(storage, "setItem", js_native(dom_storage_set));
    js_set(custom, "define", js_native(dom_define_element));
    js_define(scope, "document", dom_value(runtime->document));
    js_define(scope, "window", window);
    js_define(scope, "customElements", custom);
    js_define(scope, "localStorage", storage);
    js_define(scope, "IntersectionObserver", js_native(dom_intersection));
    js_define(scope, "ResizeObserver", js_native(dom_resize));
    js_define(scope, "requestAnimationFrame", js_native(dom_frame));
    js_define(scope, "HTMLElement", js_class(js_undefined));
    return scope;
}
