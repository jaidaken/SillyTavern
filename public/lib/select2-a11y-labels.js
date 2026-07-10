// Chrome's DevTools form audit judges a field at insertion and never clears the entry, so the
// async MutationObserver labeler is too late; wrap select2 (before any ES module) to stamp id/name/aria-label as it builds its search field.
(function () {
    'use strict';
    const jq = window.jQuery;
    if (!jq || !jq.fn || !jq.fn.select2 || jq.fn.select2.__a11yLabelled) return;

    let counter = 0;
    function labelSearchField(field) {
        if (!field.id) field.id = 'select2-search-' + (++counter);
        if (!field.getAttribute('name')) field.setAttribute('name', field.id);
        if (!field.getAttribute('aria-label')) field.setAttribute('aria-label', 'Search');
    }
    function labelSearchFieldsIn(root) {
        if (root) root.querySelectorAll('.select2-search__field').forEach(labelSearchField);
    }

    const original = jq.fn.select2;
    function wrapped() {
        const result = original.apply(this, arguments);
        try {
            this.each(function (_, el) {
                const data = jq(el).data('select2');
                if (data && data.$container) labelSearchFieldsIn(data.$container[0]);
            });
        } catch (e) { /* labeling must never break select2 init */ }
        return result;
    }
    for (const key in original) wrapped[key] = original[key];
    wrapped.__a11yLabelled = true;
    jq.fn.select2 = wrapped;

    // Single-select dropdown search fields are created on open, inside the open task.
    jq(document).on('select2:open', function () {
        document.querySelectorAll('.select2-container--open .select2-search__field, .select2-dropdown .select2-search__field').forEach(labelSearchField);
    });
})();
