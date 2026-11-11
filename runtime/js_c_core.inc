/* Operations used by generated C functions. JavaScript source is not evaluated. */
#include <glib.h>
#include <stdbool.h>
#include <math.h>
#include <string.h>
#include <stdlib.h>
#include <errno.h>

typedef struct JsValue JsValue;
typedef struct JsScope JsScope;
typedef struct { size_t count; const JsValue *items; } JsArgs;
typedef JsValue (*JsCode)(JsScope *, JsValue, JsArgs);
typedef struct { gpointer value; GDestroyNotify release; } JsAllocation;
typedef struct { GArray *allocations; char *error; } JsHeap;

typedef enum {
    JS_UNDEFINED, JS_NULL, JS_SHORT, JS_BOOL, JS_NUMBER, JS_STRING,
    JS_ARRAY, JS_OBJECT, JS_FUNCTION, JS_CLASS, JS_REGEX,
    JS_NODE, JS_DATASET, JS_STYLE, JS_CLASSLIST, JS_OBSERVER, JS_CANVAS
} JsKind;

typedef struct JsClosure JsClosure;
typedef struct { GHashTable *methods; } JsClass;
typedef struct { GRegex *regex; bool global; } JsRegex;
struct JsValue {
    JsKind kind;
    union {
        bool boolean;
        double number;
        const char *string;
        GArray *array;
        GHashTable *object;
        JsClosure *closure;
        JsClass *klass;
        JsRegex *regex;
        gpointer host;
    };
};
struct JsClosure { JsCode code; JsScope *scope; bool arrow; JsValue receiver; };
struct JsScope { JsScope *parent; GHashTable *names; };

static const JsValue js_undefined = { .kind = JS_UNDEFINED };
static const JsValue js_null = { .kind = JS_NULL };
static const JsValue js_short = { .kind = JS_SHORT };
static JsHeap *js_heap;

static void js_heap_init(JsHeap *heap)
{
    *heap = (JsHeap){ .allocations = g_array_new(FALSE, FALSE, sizeof(JsAllocation)) };
    js_heap = heap;
}

static void js_heap_clear(JsHeap *heap)
{
    for (guint index = heap->allocations->len; index > 0; index--) {
        JsAllocation allocation = g_array_index(heap->allocations, JsAllocation, index - 1);
        allocation.release(allocation.value);
    }
    g_array_unref(heap->allocations);
    g_free(heap->error);
    if (js_heap == heap) js_heap = NULL;
}

static gpointer js_own(gpointer value, GDestroyNotify release)
{
    JsAllocation allocation = { value, release };
    g_array_append_val(js_heap->allocations, allocation);
    return value;
}

static gpointer js_alloc(size_t size) { return js_own(g_malloc0(size), g_free); }
static JsValue js_error(const char *message)
{
    if (!js_heap->error) js_heap->error = g_strdup(message);
    return js_undefined;
}

static JsValue js_bool(bool value) { return (JsValue){ .kind = JS_BOOL, .boolean = value }; }
static JsValue js_number(double value) { return (JsValue){ .kind = JS_NUMBER, .number = value }; }
static JsValue js_string(const char *value) { return (JsValue){ .kind = JS_STRING, .string = value }; }
static JsValue js_owned_string(char *value) { return js_string(js_own(value, g_free)); }
static JsValue js_arg(JsArgs args, size_t index) { return index < args.count ? args.items[index] : js_undefined; }
static bool js_nullish(JsValue v) { return v.kind == JS_NULL || v.kind == JS_UNDEFINED; }
static JsValue js_end_chain(JsValue v) { return v.kind == JS_SHORT ? js_undefined : v; }
static bool js_truthy(JsValue v)
{
    switch (v.kind) {
        case JS_NULL: case JS_UNDEFINED: case JS_SHORT: return false;
        case JS_BOOL: return v.boolean;
        case JS_NUMBER: return v.number != 0 && !isnan(v.number);
        case JS_STRING: return v.string[0] != '\0';
        default: return true;
    }
}

static const char *js_to_string(JsValue value)
{
    switch (value.kind) {
        case JS_STRING: return value.string;
        case JS_NUMBER: {
            char buffer[G_ASCII_DTOSTR_BUF_SIZE];
            if (isnan(value.number)) return "NaN";
            if (isinf(value.number)) return value.number > 0 ? "Infinity" : "-Infinity";
            return js_own(g_strdup(g_ascii_dtostr(buffer, sizeof(buffer), value.number)), g_free);
        }
        case JS_BOOL: return value.boolean ? "true" : "false";
        case JS_NULL: return "null";
        case JS_UNDEFINED: case JS_SHORT: return "undefined";
        default: return "[object Object]";
    }
}

static double js_to_number(JsValue value)
{
    switch (value.kind) {
        case JS_NUMBER: return value.number;
        case JS_BOOL: return value.boolean ? 1 : 0;
        case JS_NULL: return 0;
        case JS_STRING: {
            const char *start = value.string;
            while (g_ascii_isspace(*start)) start++;
            if (!*start) return 0;
            char *end;
            double number = g_ascii_strtod(start, &end);
            if (end == start) return NAN;
            while (g_ascii_isspace(*end)) end++;
            return *end ? NAN : number;
        }
        default: return NAN;
    }
}

static bool js_equal(JsValue a, JsValue b)
{
    if (a.kind != b.kind) return false;
    switch (a.kind) {
        case JS_UNDEFINED: case JS_NULL: case JS_SHORT: return true;
        case JS_BOOL: return a.boolean == b.boolean;
        case JS_NUMBER: return a.number == b.number;
        case JS_STRING: return strcmp(a.string, b.string) == 0;
        case JS_ARRAY: return a.array == b.array;
        case JS_OBJECT: return a.object == b.object;
        case JS_FUNCTION: return a.closure == b.closure;
        case JS_CLASS: return a.klass == b.klass;
        case JS_REGEX: return a.regex == b.regex;
        default: return a.host == b.host;
    }
}

static JsValue js_join(JsArgs values)
{
    GString *text = g_string_new(NULL);
    for (size_t i = 0; i < values.count; i++) g_string_append(text, js_to_string(values.items[i]));
    return js_owned_string(g_string_free(text, FALSE));
}

static JsValue js_binary(const char *op, JsValue a, JsValue b)
{
    if (!strcmp(op, "===")) return js_bool(js_equal(a, b));
    if (!strcmp(op, "!==")) return js_bool(!js_equal(a, b));
    if (!strcmp(op, "==") || !strcmp(op, "!=")) {
        bool same = js_equal(a, b) || (js_nullish(a) && js_nullish(b));
        if (!same && !js_nullish(a) && !js_nullish(b) &&
            (a.kind == JS_BOOL || b.kind == JS_BOOL || a.kind == JS_NUMBER || b.kind == JS_NUMBER)) {
            same = js_to_number(a) == js_to_number(b);
        }
        return js_bool(op[0] == '!' ? !same : same);
    }
    if (!strcmp(op, "+") && (a.kind == JS_STRING || b.kind == JS_STRING)) {
        return js_join((JsArgs){2, (JsValue[]){a, b}});
    }
    if (a.kind == JS_STRING && b.kind == JS_STRING && (*op == '<' || *op == '>')) {
        int comparison = strcmp(a.string, b.string);
        return js_bool(*op == '<' ? comparison < 0 || (op[1] == '=' && comparison == 0)
                                  : comparison > 0 || (op[1] == '=' && comparison == 0));
    }
    double x = js_to_number(a), y = js_to_number(b);
    if (!strcmp(op, "+")) return js_number(x + y);
    if (!strcmp(op, "-")) return js_number(x - y);
    if (!strcmp(op, "*")) return js_number(x * y);
    if (!strcmp(op, "/")) return js_number(x / y);
    if (!strcmp(op, "%")) return js_number(fmod(x, y));
    if (!strcmp(op, "**")) return js_number(pow(x, y));
    if (!strcmp(op, "<")) return js_bool(x < y);
    if (!strcmp(op, "<=")) return js_bool(x <= y);
    if (!strcmp(op, ">")) return js_bool(x > y);
    if (!strcmp(op, ">=")) return js_bool(x >= y);
    return js_error("Unsupported binary operator");
}

static JsValue js_unary(const char *op, JsValue value)
{
    if (!strcmp(op, "!")) return js_bool(!js_truthy(value));
    if (!strcmp(op, "-")) return js_number(-js_to_number(value));
    if (!strcmp(op, "+")) return js_number(js_to_number(value));
    if (!strcmp(op, "void")) return js_undefined;
    if (!strcmp(op, "typeof")) {
        const char *name = "object";
        if (value.kind == JS_UNDEFINED) name = "undefined";
        else if (value.kind == JS_BOOL) name = "boolean";
        else if (value.kind == JS_NUMBER) name = "number";
        else if (value.kind == JS_STRING) name = "string";
        else if (value.kind == JS_FUNCTION) name = "function";
        return js_string(name);
    }
    return js_error("Unsupported unary operator");
}

static GHashTable *js_map(void)
{
    return js_own(g_hash_table_new_full(g_str_hash, g_str_equal, g_free, g_free),
                  (GDestroyNotify)g_hash_table_unref);
}

static JsValue js_map_get(GHashTable *table, const char *name)
{
    JsValue *value = g_hash_table_lookup(table, name);
    return value ? *value : js_undefined;
}

static JsValue js_map_set(GHashTable *table, const char *name, JsValue value)
{
    JsValue *copy = g_new(JsValue, 1);
    *copy = value;
    g_hash_table_replace(table, g_strdup(name), copy);
    return value;
}

static JsScope *js_scope(JsScope *parent)
{
    JsScope *scope = js_alloc(sizeof(*scope));
    scope->parent = parent;
    scope->names = js_map();
    return scope;
}

static void js_define(JsScope *scope, const char *name, JsValue value) { js_map_set(scope->names, name, value); }
static JsValue js_get_name(JsScope *scope, const char *name)
{
    for (; scope; scope = scope->parent) {
        if (g_hash_table_contains(scope->names, name)) return js_map_get(scope->names, name);
    }
    if (!strcmp(name, "undefined")) return js_undefined;
    return js_error(js_own(g_strdup_printf("Unknown JavaScript binding: %s", name), g_free));
}

static JsValue js_assign(JsScope *scope, const char *name, JsValue value)
{
    for (; scope; scope = scope->parent) {
        if (g_hash_table_contains(scope->names, name)) return js_map_set(scope->names, name, value);
    }
    return js_error("Assignment to an undeclared binding");
}

static JsValue js_function(JsCode code, JsScope *scope, bool arrow, JsValue receiver)
{
    JsClosure *closure = js_alloc(sizeof(*closure));
    *closure = (JsClosure){code, scope, arrow, receiver};
    return (JsValue){ .kind = JS_FUNCTION, .closure = closure };
}
static JsValue js_native(JsCode code) { return js_function(code, NULL, false, js_undefined); }
static JsValue js_call(JsValue fn, JsValue receiver, JsArgs args)
{
    if (fn.kind != JS_FUNCTION) return js_error("Value is not callable");
    JsClosure *closure = fn.closure;
    return closure->code(closure->scope, closure->arrow ? closure->receiver : receiver, args);
}
static JsValue js_new(JsValue constructor, JsArgs args) { return js_call(constructor, js_undefined, args); }
static JsValue js_class(JsValue base)
{
    JsClass *klass = js_alloc(sizeof(*klass));
    klass->methods = js_map();
    if (base.kind == JS_CLASS) {
        GHashTableIter it;
        gpointer key, value;
        g_hash_table_iter_init(&it, base.klass->methods);
        while (g_hash_table_iter_next(&it, &key, &value)) js_map_set(klass->methods, key, *(JsValue *)value);
    }
    return (JsValue){ .kind = JS_CLASS, .klass = klass };
}
static JsValue js_object(void) { return (JsValue){ .kind = JS_OBJECT, .object = js_map() }; }
static JsValue js_array(JsArgs values)
{
    GArray *array = js_own(g_array_sized_new(FALSE, FALSE, sizeof(JsValue), values.count),
                            (GDestroyNotify)g_array_unref);
    if (values.count) g_array_append_vals(array, values.items, values.count);
    return (JsValue){ .kind = JS_ARRAY, .array = array };
}
static size_t js_length(JsValue value)
{
    if (value.kind == JS_ARRAY) return value.array->len;
    if (value.kind == JS_STRING) return g_utf8_strlen(value.string, -1);
    return 0;
}
static JsValue js_index(JsValue value, size_t index)
{
    if (index >= js_length(value)) return js_undefined;
    if (value.kind == JS_ARRAY) return g_array_index(value.array, JsValue, index);
    const char *start = g_utf8_offset_to_pointer(value.string, index);
    return js_owned_string(g_strndup(start, g_utf8_next_char(start) - start));
}
static JsValue js_regex(const char *pattern, const char *flags)
{
    GError *error = NULL;
    GRegexCompileFlags options = 0;
    if (strchr(flags, 'i')) options |= G_REGEX_CASELESS;
    if (strchr(flags, 'm')) options |= G_REGEX_MULTILINE;
    if (strchr(flags, 's')) options |= G_REGEX_DOTALL;
    GRegex *regex = g_regex_new(pattern, options, 0, &error);
    if (!regex) {
        JsValue result = js_error(error->message);
        g_clear_error(&error);
        return result;
    }
    JsRegex *value = js_alloc(sizeof(*value));
    value->regex = js_own(regex, (GDestroyNotify)g_regex_unref);
    value->global = strchr(flags, 'g') != NULL;
    return (JsValue){ .kind = JS_REGEX, .regex = value };
}

static JsValue js_host_get(JsValue object, const char *key);
static JsValue js_host_set(JsValue object, const char *key, JsValue value);
static JsValue js_get(JsValue object, const char *key);
static JsValue js_set(JsValue object, const char *key, JsValue value)
{
    if (object.kind == JS_OBJECT) return js_map_set(object.object, key, value);
    if (object.kind == JS_CLASS) return js_map_set(object.klass->methods, key, value);
    if (object.kind == JS_ARRAY && g_ascii_isdigit(*key)) {
        char *end;
        guint64 index = g_ascii_strtoull(key, &end, 10);
        if (!*end && index < G_MAXUINT) {
            while (object.array->len <= index) g_array_append_val(object.array, js_undefined);
            g_array_index(object.array, JsValue, index) = value;
            return value;
        }
    }
    if (object.kind >= JS_NODE) return js_host_set(object, key, value);
    return js_error("Property cannot be assigned");
}

#define JS_METHOD(name) static JsValue name(JsScope *scope G_GNUC_UNUSED, JsValue receiver G_GNUC_UNUSED, JsArgs args G_GNUC_UNUSED)

JS_METHOD(js_method_trim) { return js_owned_string(g_strstrip(g_strdup(receiver.string))); }
JS_METHOD(js_method_split)
{
    JsValue separator = js_arg(args, 0);
    gchar **parts = separator.kind == JS_REGEX
        ? g_regex_split(separator.regex->regex, receiver.string, 0)
        : g_strsplit(receiver.string, js_to_string(separator), -1);
    JsValue result = js_array((JsArgs){0, NULL});
    if (parts) {
        for (size_t i = 0; parts[i]; i++) {
            JsValue part = js_owned_string(g_strdup(parts[i]));
            g_array_append_val(result.array, part);
        }
        g_strfreev(parts);
    }
    return result;
}
JS_METHOD(js_method_match)
{
    JsValue pattern = js_arg(args, 0);
    if (pattern.kind != JS_REGEX) pattern = js_regex(js_to_string(pattern), "");
    if (pattern.kind != JS_REGEX) return js_null;
    GMatchInfo *match = NULL;
    gboolean found = g_regex_match(pattern.regex->regex, receiver.string, 0, &match);
    JsValue result = js_null;
    if (found) {
        result = js_array((JsArgs){0, NULL});
        for (int i = 0; i < g_match_info_get_match_count(match); i++) {
            char *group = g_match_info_fetch(match, i);
            JsValue value = group ? js_owned_string(group) : js_undefined;
            g_array_append_val(result.array, value);
        }
    }
    g_match_info_free(match);
    return result;
}
JS_METHOD(js_method_replace)
{
    JsValue pattern = js_arg(args, 0);
    const char *replacement = js_to_string(js_arg(args, 1));
    if (pattern.kind != JS_REGEX) {
        char *escaped = g_regex_escape_string(js_to_string(pattern), -1);
        pattern = js_regex(escaped, "");
        g_free(escaped);
    }
    if (pattern.kind != JS_REGEX) return receiver;
    if (pattern.regex->global) {
        char *text = g_regex_replace_literal(pattern.regex->regex, receiver.string, -1, 0, replacement, 0, NULL);
        return text ? js_owned_string(text) : receiver;
    }
    GMatchInfo *match = NULL;
    bool found = g_regex_match(pattern.regex->regex, receiver.string, 0, &match);
    int start, end;
    if (found && g_match_info_fetch_pos(match, 0, &start, &end)) {
        GString *text = g_string_new_len(receiver.string, start);
        g_string_append(text, replacement);
        g_string_append(text, receiver.string + end);
        receiver = js_owned_string(g_string_free(text, FALSE));
    }
    g_match_info_free(match);
    return receiver;
}
JS_METHOD(js_method_regex_test) { return js_bool(g_regex_match(receiver.regex->regex, js_to_string(js_arg(args, 0)), 0, NULL)); }
JS_METHOD(js_method_map)
{
    JsValue result = js_array((JsArgs){0, NULL});
    for (guint i = 0; i < receiver.array->len; i++) {
        JsValue value = js_call(js_arg(args, 0), js_undefined,
            (JsArgs){3, (JsValue[]){js_index(receiver, i), js_number(i), receiver}});
        g_array_append_val(result.array, value);
    }
    return result;
}
JS_METHOD(js_method_filter)
{
    JsValue result = js_array((JsArgs){0, NULL});
    for (guint i = 0; i < receiver.array->len; i++) {
        JsValue item = js_index(receiver, i);
        JsValue include = js_call(js_arg(args, 0), js_undefined,
            (JsArgs){3, (JsValue[]){item, js_number(i), receiver}});
        if (js_truthy(include)) g_array_append_val(result.array, item);
    }
    return result;
}
JS_METHOD(js_method_foreach)
{
    for (guint i = 0; i < receiver.array->len; i++) {
        js_call(js_arg(args, 0), js_undefined,
                (JsArgs){3, (JsValue[]){js_index(receiver, i), js_number(i), receiver}});
    }
    return js_undefined;
}

static int js_compare_values(const JsValue *a, const JsValue *b, JsValue compare)
{
    if (compare.kind == JS_UNDEFINED) return strcmp(js_to_string(*a), js_to_string(*b));
    double result = js_to_number(js_call(compare, js_undefined, (JsArgs){2, (JsValue[]){*a, *b}}));
    return (result > 0) - (result < 0);
}
JS_METHOD(js_method_sort)
{
    /* Stable insertion sort keeps the input order when the comparison is zero. */
    for (guint i = 1; i < receiver.array->len; i++) {
        JsValue value = js_index(receiver, i);
        guint position = i;
        while (position > 0) {
            JsValue previous = js_index(receiver, position - 1);
            if (js_compare_values(&previous, &value, js_arg(args, 0)) <= 0) break;
            g_array_index(receiver.array, JsValue, position--) = previous;
        }
        g_array_index(receiver.array, JsValue, position) = value;
    }
    return receiver;
}

static JsValue js_get(JsValue object, const char *key)
{
    if (js_nullish(object)) return js_error("Cannot read property of null or undefined");
    if (object.kind == JS_OBJECT) return js_map_get(object.object, key);
    if (object.kind == JS_CLASS) return js_map_get(object.klass->methods, key);
    if (object.kind == JS_STRING || object.kind == JS_ARRAY) {
        if (!strcmp(key, "length")) return js_number(js_length(object));
        if (g_ascii_isdigit(*key)) {
            char *end;
            guint64 index = g_ascii_strtoull(key, &end, 10);
            if (!*end) return js_index(object, index);
        }
    }
    if (object.kind == JS_STRING) {
        if (!strcmp(key, "trim")) return js_native(js_method_trim);
        if (!strcmp(key, "split")) return js_native(js_method_split);
        if (!strcmp(key, "match")) return js_native(js_method_match);
        if (!strcmp(key, "replace")) return js_native(js_method_replace);
    }
    if (object.kind == JS_ARRAY) {
        if (!strcmp(key, "map")) return js_native(js_method_map);
        if (!strcmp(key, "filter")) return js_native(js_method_filter);
        if (!strcmp(key, "forEach")) return js_native(js_method_foreach);
        if (!strcmp(key, "sort")) return js_native(js_method_sort);
    }
    if (object.kind == JS_REGEX && !strcmp(key, "test")) return js_native(js_method_regex_test);
    if (object.kind >= JS_NODE) return js_host_get(object, key);
    return js_undefined;
}

JS_METHOD(js_boolean) { return js_bool(js_truthy(js_arg(args, 0))); }
JS_METHOD(js_get_year)
{
    GDateTime *now = g_date_time_new_now_local();
    JsValue year = js_number(g_date_time_get_year(now));
    g_date_time_unref(now);
    return year;
}
JS_METHOD(js_date)
{
    JsValue date = js_object();
    js_set(date, "getFullYear", js_native(js_get_year));
    return date;
}
JS_METHOD(js_array_from)
{
    JsValue source = js_arg(args, 0);
    JsValue result = js_array((JsArgs){0, NULL});
    double length = js_to_number(js_get(source, "length"));
    if (!isfinite(length) || length < 0 || length > 1000000) return js_error("Array length out of range");
    for (size_t i = 0; i < (size_t)length; i++) {
        JsValue item = js_index(source, i);
        JsValue mapper = js_arg(args, 1);
        if (mapper.kind == JS_FUNCTION) item = js_call(mapper, js_undefined, (JsArgs){2, (JsValue[]){item, js_number(i)}});
        g_array_append_val(result.array, item);
    }
    return result;
}
JS_METHOD(js_floor) { return js_number(floor(js_to_number(js_arg(args, 0)))); }
JS_METHOD(js_random) { return js_number(g_random_double()); }
JS_METHOD(js_hypot) { return js_number(hypot(js_to_number(js_arg(args, 0)), js_to_number(js_arg(args, 1)))); }
JS_METHOD(js_min)
{
    double result = INFINITY;
    for (size_t i = 0; i < args.count; i++) result = fmin(result, js_to_number(args.items[i]));
    return js_number(result);
}
JS_METHOD(js_max)
{
    double result = -INFINITY;
    for (size_t i = 0; i < args.count; i++) result = fmax(result, js_to_number(args.items[i]));
    return js_number(result);
}

static void js_builtins(JsScope *scope)
{
    js_define(scope, "Boolean", js_native(js_boolean));
    js_define(scope, "Date", js_native(js_date));
    JsValue array = js_object(), math = js_object();
    js_set(array, "from", js_native(js_array_from));
    js_set(math, "PI", js_number(3.141592653589793));
    js_set(math, "min", js_native(js_min));
    js_set(math, "max", js_native(js_max));
    js_set(math, "floor", js_native(js_floor));
    js_set(math, "random", js_native(js_random));
    js_set(math, "hypot", js_native(js_hypot));
    js_define(scope, "Array", array);
    js_define(scope, "Math", math);
}
