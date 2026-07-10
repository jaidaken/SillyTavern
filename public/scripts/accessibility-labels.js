/**
 * Gives unlabeled form controls a programmatic accessible name by associating
 * them with an existing visible label, instead of duplicating label text.
 */
import { log } from './log.js';

const FIELD_SELECTOR = 'input, select, textarea';
const EXCLUDED_TYPES = new Set(['submit', 'button', 'reset', 'image', 'checkbox', 'radio', 'hidden', 'file']);
const SKIP_ROOT_SELECTOR = 'template, .template_element';
const MAX_CAPTION_TEXT_LENGTH = 150;
const MAX_CLIMB_DEPTH = 6;
const OBSERVER_DEBOUNCE_MS = 200;
// third-party page-size select from public/lib/pagination.js; no label markup of its own.
const PAGINATION_SIZE_SELECT = '.J-paginationjs-size-select';

let labelIdCounter = 0;

function isRelevantField(el) {
    if (!(el instanceof Element)) return false;
    if (!el.matches(FIELD_SELECTOR)) return false;
    if (el.closest(SKIP_ROOT_SELECTOR)) return false;
    if (el.hasAttribute('hidden')) return false;
    const type = (el.getAttribute('type') || '').toLowerCase();
    if (EXCLUDED_TYPES.has(type)) return false;
    return true;
}

function isElementHidden(el) {
    if (el.hidden || el.getAttribute('aria-hidden') === 'true') return true;
    const style = getComputedStyle(el);
    return style.display === 'none' || style.visibility === 'hidden';
}

// AT ignores hidden content and a nested field's own content (eg <option> text) when computing a name; mirror that here.
function visibleText(el, excludeFields) {
    if (isElementHidden(el)) return '';
    let text = '';
    for (const node of el.childNodes) {
        if (node.nodeType === Node.TEXT_NODE) text += node.textContent;
        else if (node.nodeType === Node.ELEMENT_NODE && !(excludeFields && node.matches(FIELD_SELECTOR))) text += visibleText(node, excludeFields);
    }
    return text;
}

function collapsedVisibleText(el, excludeFields) {
    return visibleText(el, excludeFields).trim().replace(/\s+/g, ' ');
}

// an empty label association (icon-only wrapper, or one that only wraps a bare control) names nothing, so it must not count as robust.
function resolveRobustNameSource(el) {
    if (el.getAttribute('aria-labelledby')) return { attr: 'aria-labelledby', value: el.getAttribute('aria-labelledby') };
    if (el.getAttribute('aria-label')) return { attr: 'aria-label', value: el.getAttribute('aria-label') };
    if (el.id) {
        const l = document.querySelector(`label[for="${CSS.escape(el.id)}"]`);
        if (l) {
            const text = collapsedVisibleText(l, true);
            if (text) return { attr: 'aria-label', value: text };
        }
    }
    const wrap = el.closest('label');
    if (wrap) {
        const text = collapsedVisibleText(wrap, true);
        if (text) return { attr: 'aria-label', value: text };
    }
    return null;
}

// title is a valid last-resort source, but labelPrimaryField always promotes it into aria-label so it is never the ONLY name (axe label-title-only).
function resolveAccessibleNameSource(el) {
    const robust = resolveRobustNameSource(el);
    if (robust) return robust;
    if (el.getAttribute('title')) return { attr: 'aria-label', value: el.getAttribute('title') };
    return null;
}

function hasAccessibleName(el) {
    return !!resolveRobustNameSource(el);
}

// only a still-unlabeled, non-excluded control creates genuine ambiguity about whose caption this is.
function containsBlockingControl(el) {
    const blocks = (c) => isRelevantField(c) && !hasAccessibleName(c);
    if (el.matches(FIELD_SELECTOR) && blocks(el)) return true;
    return [...el.querySelectorAll(FIELD_SELECTOR)].some(blocks);
}

function captionText(el) {
    // a control's own rendered content (eg <option> text) is never a caption for a sibling control.
    if (el.matches(FIELD_SELECTOR) || el.querySelector(FIELD_SELECTOR)) return null;
    if (isElementHidden(el)) return null;
    if (el.matches('label')) {
        // a label explicitly for="" a real control elsewhere is that control's own name, not up for reuse.
        const forId = el.getAttribute('for');
        if (forId && document.getElementById(forId)) return null;
    }
    const text = collapsedVisibleText(el, false);
    if (!text || text.length > MAX_CAPTION_TEXT_LENGTH) return null;
    // Icon/punctuation-only text (eg a drag-handle glyph) is not a caption.
    if (!/[\p{L}\p{N}]/u.test(text)) return null;
    return text;
}

// nearest preceding text-only sibling/ancestor-sibling; aborts past another still-unlabeled control to avoid misattributing its caption.
function findPrecedingCaption(el) {
    let node = el;
    for (let depth = 0; depth < MAX_CLIMB_DEPTH && node && node !== document.body; depth++) {
        let sib = node.previousElementSibling;
        while (sib) {
            if (containsBlockingControl(sib)) return null;
            const text = captionText(sib);
            if (text) return sib;
            sib = sib.previousElementSibling;
        }
        node = node.parentElement;
    }
    return null;
}

function ensureId(el, prefix) {
    if (el.id) return el.id;
    el.id = `${prefix}-${++labelIdCounter}`;
    return el.id;
}

function labelViaCaption(el) {
    const caption = findPrecedingCaption(el);
    if (!caption) return false;
    const captionId = ensureId(caption, 'a11y-lbl');
    el.setAttribute('aria-labelledby', captionId);
    return true;
}

// data-i18n="[attr]text" targets a specific attribute's translation; read that real attribute, not the raw directive string.
function resolveI18nHint(el) {
    const i18n = el.getAttribute('data-i18n');
    if (!i18n) return null;
    const attrMatch = i18n.match(/^\[(\w+)\]/);
    return attrMatch ? el.getAttribute(attrMatch[1]) : i18n;
}

function labelViaTextHint(el) {
    let hint = el.getAttribute('placeholder') || resolveI18nHint(el) || el.getAttribute('title');
    if (!hint) {
        const parent = el.parentElement;
        const isOnlyField = parent && parent.querySelectorAll(FIELD_SELECTOR).length === 1;
        if (isOnlyField && parent.getAttribute('title')) hint = parent.getAttribute('title');
    }
    if (!hint) return false;
    const cleanHint = hint.trim();
    if (!cleanHint) return false;
    el.setAttribute('aria-label', cleanHint);
    return true;
}

function humanize(identifier) {
    return identifier.replace(/[_-]+/g, ' ').replace(/\b\w/g, (c) => c.toUpperCase());
}

// last resort for fields with a declared identity but no visible caption to associate with (eg internal state holders).
function labelViaIdentifierFallback(el) {
    const identifier = el.getAttribute('name') || el.id;
    if (!identifier) return false;
    el.setAttribute('aria-label', humanize(identifier));
    return true;
}

function labelPrimaryField(el) {
    if (hasAccessibleName(el)) return;
    if (labelViaCaption(el)) return;
    if (labelViaTextHint(el)) return;
    labelViaIdentifierFallback(el);
}

// counters (range-block / neo-range number inputs) inherit their slider's resolved label via data-for.
function labelCounterField(el) {
    if (hasAccessibleName(el)) return;
    const targetId = el.getAttribute('data-for');
    const target = targetId && document.getElementById(targetId);
    if (!target) return;
    if (!hasAccessibleName(target)) labelPrimaryField(target);
    const source = resolveAccessibleNameSource(target);
    if (source) el.setAttribute(source.attr, source.value);
}

// resolves the name of the original <select> a select2 container replaced, labeling it first if needed.
function resolveSelect2ComboboxText(container) {
    const combobox = container?.previousElementSibling;
    if (!combobox || !combobox.matches('select')) return null;
    if (!hasAccessibleName(combobox)) labelPrimaryField(combobox);
    const source = resolveAccessibleNameSource(combobox);
    return source?.attr === 'aria-labelledby' ? document.getElementById(source.value)?.textContent?.trim() : source?.value;
}

// select2's search input is library-owned and gets recreated on state changes, so it gets a copied aria-label, not a stable id.
function labelSelect2SearchField(el) {
    if (el.getAttribute('aria-label')) return;
    const text = resolveSelect2ComboboxText(el.closest('.select2-container'));
    if (text) el.setAttribute('aria-label', text);
}

// the visible combobox widget (role=combobox) is a separate element from the search input; both need the name.
function labelSelect2Selection(container) {
    const selection = container.querySelector('.select2-selection');
    if (!selection || selection.getAttribute('aria-label')) return;
    const text = resolveSelect2ComboboxText(container);
    if (text) selection.setAttribute('aria-label', text);
}

function findElements(root, selector) {
    return root.matches?.(selector) ? [root, ...root.querySelectorAll(selector)] : [...root.querySelectorAll(selector)];
}

function labelFieldsIn(root) {
    try {
        const counters = [];
        for (const el of findElements(root, FIELD_SELECTOR)) {
            if (!isRelevantField(el)) continue;
            if (el.hasAttribute('data-for')) {
                counters.push(el);
                continue;
            }
            labelPrimaryField(el);
        }
        for (const el of counters) labelCounterField(el);

        for (const el of findElements(root, '.select2-search__field')) labelSelect2SearchField(el);
        for (const el of findElements(root, '.select2-container')) labelSelect2Selection(el);

        for (const el of findElements(root, PAGINATION_SIZE_SELECT)) {
            if (!el.getAttribute('aria-label')) el.setAttribute('aria-label', 'Items per page');
        }
    } catch (error) {
        log.ui.error('Error applying accessibility labels to element:', root, error);
    }
}

const OBSERVER_MAX_WAIT_MS = 1000;

let debounceTimer = null;
let maxWaitTimer = null;
function runObserverPass(nodes) {
    clearTimeout(debounceTimer);
    clearTimeout(maxWaitTimer);
    debounceTimer = null;
    maxWaitTimer = null;
    for (const node of nodes) labelFieldsIn(node);
    nodes.length = 0;
}

// plain debounce lets continuous churn (rapid successive mutations) defer the pass forever; maxWait guarantees it still runs.
function scheduleObserverPass(nodes) {
    clearTimeout(debounceTimer);
    debounceTimer = setTimeout(() => runObserverPass(nodes), OBSERVER_DEBOUNCE_MS);
    if (!maxWaitTimer) maxWaitTimer = setTimeout(() => runObserverPass(nodes), OBSERVER_MAX_WAIT_MS);
}

function setLabelObserver() {
    labelFieldsIn(document.body);

    const pendingNodes = [];
    const observer = new MutationObserver((mutationsList) => {
        for (const mutation of mutationsList) {
            if (mutation.type !== 'childList') continue;
            for (const addedNode of mutation.addedNodes) {
                if (addedNode.nodeType === Node.ELEMENT_NODE) pendingNodes.push(addedNode);
            }
        }
        if (pendingNodes.length) scheduleObserverPass(pendingNodes);
    });

    observer.observe(document.body, {
        childList: true,
        subtree: true,
    });
}

export function initAccessibilityLabels() {
    setLabelObserver();
}
