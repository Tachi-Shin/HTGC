static void dump_html(DomNode *node)
{
    if (node->tag && node->tag[0] != '#') {
        printf("<%s", node->tag);
        GHashTableIter iterator;
        gpointer key, item;
        g_hash_table_iter_init(&iterator, node->attributes);
        while (g_hash_table_iter_next(&iterator, &key, &item)) {
            char *escaped = g_markup_escape_text(((JsValue *)item)->string, -1);
            printf(" %s=\"%s\"", (char *)key, escaped);
            g_free(escaped);
        }
        putchar('>');
    }
    if (node->text) {
        char *escaped = g_markup_escape_text(node->text, -1);
        fputs(escaped, stdout);
        g_free(escaped);
    }
    for (guint i = 0; i < node->children->len; i++) dump_html(node->children->pdata[i]);
    if (node->tag && node->tag[0] != '#') printf("</%s>", node->tag);
}
int main(int argc, char **argv)
{
    const SitePage *page = site_page(argc > 1 ? argv[1] : site_entry);
    if (!page) return 2;
    GHashTable *storage = g_hash_table_new_full(g_str_hash, g_str_equal, g_free, g_free);
    if (argc > 2) g_hash_table_insert(storage, g_strdup("theme"), g_strdup(argv[2]));
    DomRuntime runtime = { .storage = storage, .reduced_motion = true };
    bool loaded = site_load(&runtime, page);
    if (loaded) {
        DomNode *button = dom_find(runtime.document, "#themeToggle");
        if (button && argc > 3) {
            int clicks = atoi(argv[3]);
            for (int i = 0; i < clicks; i++) dom_dispatch(button, "click");
        }
        if (runtime.heap.error) loaded = false;
    }
    if (loaded) dump_html(runtime.document);
    else fprintf(stderr, "%s\n", runtime.heap.error);
    js_heap_clear(&runtime.heap);
    g_hash_table_unref(storage);
    return loaded ? 0 : 1;
}
