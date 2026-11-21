// =============================================================================
//                  SP BOUCHER | SOFTWARE & RESEARCH
//             ARTIFICIAL INTELLIGENCE • FINANCE • ENGINEERING
// =============================================================================
//
// PROJECT METADATA
// -----------------------------------------------------------------------------
// Project          : ORIX OS Automation
// File             : Packages/ORIXBrowserAutomation/Sources/ORIXBrowserAutomation/PageScripts.swift
// Description      : The JavaScript ORIX injects into its own content world:
//                    structured page reading, element inspection, filling,
//                    clicking and waiting. No fetch or XHR.
// Module           : ORIXBrowserAutomation
// Repository       : https://git.spboucher.ai/orix-automation
// Created          : 2026-11-21
// Last Modified    : 2026-11-21
//
// =============================================================================
// AUTHOR & PROFESSIONAL AFFILIATION
// =============================================================================
//
// Author           : Simon-Pierre Boucher
// Position         : Professor of Finance
// Institution      : Université du Québec en Outaouais (UQO)
// Department       : Département des sciences administratives
// Organization     : SP Boucher
//
// Website          : https://spboucher.ai
// Git              : https://git.spboucher.ai
//
// =============================================================================
// OFFICIAL CONTACT DIRECTORY
// =============================================================================
//
// General          : info@spboucher.ai
// Professional     : contact@spboucher.ai
// Direct           : simon@spboucher.ai
// Research         : research@spboucher.ai
// Development      : dev@spboucher.ai
// Support          : support@spboucher.ai
// Security/Admin   : admin@spboucher.ai
// Notifications    : notifications@spboucher.ai
//
// Preferred Contact: support@spboucher.ai
//
// =============================================================================
// COPYRIGHT & INTELLECTUAL PROPERTY
// =============================================================================
//
// Copyright (c) 2026
// Simon-Pierre Boucher
//
// All rights reserved where applicable.
//
// This file is governed by the applicable project license,
// copyright notices, institutional agreements and relevant law.
//
// Unless expressly authorized by the applicable license or
// rights holder, copying, redistribution, sublicensing,
// publication and commercial exploitation are not permitted.
//
// Existing third-party rights and notices remain unaffected.
//
// =============================================================================
// CONFIDENTIALITY & SECURITY
// =============================================================================
//
// Classification   : Public
// Distribution     : Public repository; use is governed by the project license
// Security Contact : admin@spboucher.ai
//
// Access to this source does not independently grant permission
// to redistribute or disclose confidential materials.
//
// Do not embed credentials, private keys, access tokens,
// certificates or confidential personal information.
//
// =============================================================================
// LICENSE & MAINTENANCE
// =============================================================================
//
// License          : Proprietary, all rights reserved (see license file)
// License File     : LICENSE
// Maintainer       : Simon-Pierre Boucher
// Technical Contact: dev@spboucher.ai
//
// =============================================================================
// END OF SP BOUCHER SOURCE HEADER
// =============================================================================

import Foundation

/// Function bodies for `WKWebView.callAsyncJavaScript`. They run in an isolated content world (page scripts cannot see
/// or replace these functions), receive their inputs as named arguments (never by string interpolation), return a JSON
/// string and never touch the network.
enum PageScripts {
    /// The value reported instead of a password or payment-card field's content.
    static let secureMarker = "«secure»"

    static let prelude = #"""
    const SECURE = '«secure»';
    if (!window.__orixSecret) { window.__orixSecret = new WeakSet(); }
    function clean(s, max) {
      s = (s == null ? '' : String(s)).replace(/\s+/g, ' ').trim();
      return max && s.length > max ? s.slice(0, max) + '…' : s;
    }
    function cssString(s) { return String(s).replace(/\\/g, '\\\\').replace(/"/g, '\\"'); }
    function unique(sel) { try { return document.querySelectorAll(sel).length === 1; } catch (e) { return false; } }
    function selectorFor(el) {
      if (el.id) { const s = '#' + CSS.escape(el.id); if (unique(s)) return s; }
      const tag = el.tagName.toLowerCase();
      const name = el.getAttribute('name');
      if (name) { const s = tag + '[name="' + cssString(name) + '"]'; if (unique(s)) return s; }
      const parts = [];
      let node = el;
      while (node && node.nodeType === 1 && node !== document.documentElement) {
        if (node.id) { const s = '#' + CSS.escape(node.id); if (unique(s)) { parts.unshift(s); return parts.join(' > '); } }
        let i = 1, sib = node;
        while ((sib = sib.previousElementSibling)) { if (sib.tagName === node.tagName) i++; }
        parts.unshift(node.tagName.toLowerCase() + ':nth-of-type(' + i + ')');
        node = node.parentElement;
      }
      parts.unshift('html');
      return parts.join(' > ');
    }
    function isVisible(el) {
      const st = getComputedStyle(el);
      if (st.display === 'none' || st.visibility === 'hidden' || st.visibility === 'collapse') return false;
      const r = el.getBoundingClientRect();
      return r.width > 0 && r.height > 0;
    }
    function isDisabled(el) {
      return !!el.disabled || el.getAttribute('aria-disabled') === 'true' || !!(el.closest && el.closest('fieldset[disabled]'));
    }
    function isSecure(el) {
      const tag = el.tagName.toLowerCase();
      if (tag !== 'input' && tag !== 'textarea' && tag !== 'select') return false;
      if (window.__orixSecret.has(el)) return true;
      const type = (el.getAttribute('type') || '').toLowerCase();
      const ac = (el.getAttribute('autocomplete') || '').toLowerCase().trim().split(/\s+/);
      const secure = type === 'password' ||
        ac.some(t => t.indexOf('cc-') === 0 || t === 'current-password' || t === 'new-password' || t === 'one-time-code');
      if (secure) window.__orixSecret.add(el);
      return secure;
    }
    function labelFor(el) {
      if (el.labels && el.labels.length) return clean(el.labels[0].innerText || el.labels[0].textContent, 200);
      const aria = el.getAttribute('aria-label');
      if (aria) return clean(aria, 200);
      const by = el.getAttribute('aria-labelledby');
      if (by) { const t = by.split(/\s+/).map(id => { const n = document.getElementById(id); return n ? n.textContent : ''; }).join(' '); if (clean(t)) return clean(t, 200); }
      return clean(el.getAttribute('title') || '', 200);
    }
    function find(selector) {
      try { return { el: document.querySelector(selector) }; }
      catch (e) { return { error: 'invalid_selector' }; }
    }
    function describe(el) {
      const tag = el.tagName.toLowerCase();
      return {
        tag: tag, type: (el.getAttribute('type') || (tag === 'select' ? 'select' : tag === 'textarea' ? 'textarea' : '')).toLowerCase(),
        secure: isSecure(el), disabled: isDisabled(el), readOnly: !!el.readOnly, visible: isVisible(el),
        editable: !!el.isContentEditable
      };
    }
    """#

    /// Arguments: maxTextChars, maxItems, maxTableRows, maxTableColumns.
    static let read = prelude + #"""
    const out = { title: clean(document.title, 500), url: location.href, truncated: false };
    const body = document.body;
    const fullText = body ? (body.innerText || '') : '';
    out.textLength = fullText.length;
    out.text = fullText.length > maxTextChars ? fullText.slice(0, maxTextChars) : fullText;
    if (fullText.length > maxTextChars) out.truncated = true;
    function take(nodes) { const a = Array.from(nodes); if (a.length > maxItems) out.truncated = true; return a.slice(0, maxItems); }

    out.headings = take(document.querySelectorAll('h1,h2,h3,h4,h5,h6')).map(h => ({ level: Number(h.tagName.slice(1)), text: clean(h.innerText || h.textContent, 300) }));
    out.links = take(document.querySelectorAll('a[href]')).map(a => ({
      text: clean(a.innerText || a.getAttribute('aria-label') || a.textContent, 200), href: a.href, selector: selectorFor(a), visible: isVisible(a)
    }));

    function field(el) {
      const d = describe(el);
      const f = { selector: selectorFor(el), tag: d.tag, type: d.type || 'text', name: el.getAttribute('name') || '', id: el.id || '',
                  label: labelFor(el), placeholder: clean(el.getAttribute('placeholder') || '', 200),
                  required: !!el.required, disabled: d.disabled, readOnly: d.readOnly, visible: d.visible, secure: d.secure };
      if (d.secure) { f.value = SECURE; }
      else if (d.tag === 'select') {
        const opts = Array.from(el.options);
        f.value = opts.filter(o => o.selected).map(o => o.value).join(',');
        f.options = opts.slice(0, 100).map(o => ({ value: o.value, text: clean(o.text, 200), selected: o.selected }));
        if (opts.length > 100) out.truncated = true;
        f.multiple = !!el.multiple;
      } else if (d.type === 'checkbox' || d.type === 'radio') { f.value = el.value; f.checked = !!el.checked; }
      else if (d.type === 'file') { f.value = ''; }
      else { f.value = String(el.value == null ? '' : el.value).slice(0, 2000); }
      return f;
    }
    const controlQuery = 'input:not([type=submit]):not([type=button]):not([type=reset]):not([type=image]),select,textarea';
    out.forms = take(document.forms).map(form => ({
      selector: selectorFor(form), id: form.id || '', name: form.getAttribute('name') || '',
      method: (form.getAttribute('method') || 'get').toLowerCase(), action: form.action || '',
      fields: take(form.querySelectorAll(controlQuery)).map(field)
    }));
    out.fields = take(Array.from(document.querySelectorAll(controlQuery)).filter(el => !el.form)).map(field);

    out.buttons = take(document.querySelectorAll('button,input[type=submit],input[type=button],input[type=reset],[role=button]')).map(b => ({
      text: clean(b.innerText || b.value || b.getAttribute('aria-label') || b.textContent, 200), selector: selectorFor(b),
      type: (b.getAttribute('type') || (b.tagName === 'BUTTON' ? 'submit' : 'button')).toLowerCase(),
      disabled: isDisabled(b), visible: isVisible(b)
    }));

    out.tables = take(document.querySelectorAll('table')).slice(0, 20).map(t => {
      const rows = Array.from(t.rows);
      const cells = r => Array.from(r.cells).slice(0, maxTableColumns).map(c => clean(c.innerText || c.textContent, 300));
      let headers = [];
      let bodyRows = rows;
      if (rows.length && Array.from(rows[0].cells).every(c => c.tagName === 'TH')) { headers = cells(rows[0]); bodyRows = rows.slice(1); }
      if (bodyRows.length > maxTableRows) out.truncated = true;
      return { selector: selectorFor(t), caption: t.caption ? clean(t.caption.innerText, 300) : '', headers: headers,
               rowCount: bodyRows.length, rows: bodyRows.slice(0, maxTableRows).map(cells) };
    });
    return JSON.stringify(out);
    """#

    /// Arguments: selector, value (string or null), checked (bool or null), secret (bool).
    static let fill = prelude + #"""
    const r = find(selector);
    if (r.error) return JSON.stringify({ ok: false, code: r.error });
    const el = r.el;
    if (!el) return JSON.stringify({ ok: false, code: 'not_found' });
    const d = describe(el);
    // A password or payment-card field only accepts a value that came from the secret store.
    if (d.secure && !secret) return JSON.stringify({ ok: false, code: 'secret_required', type: d.type });
    if (d.disabled || d.readOnly) return JSON.stringify({ ok: false, code: 'disabled' });
    function fire(name) { el.dispatchEvent(new Event(name, { bubbles: true, cancelable: false })); }
    let length = 0;
    if (d.tag === 'select') {
      const opts = Array.from(el.options);
      const wanted = String(value);
      const opt = opts.find(o => o.value === wanted) || opts.find(o => clean(o.text) === clean(wanted));
      if (!opt) return JSON.stringify({ ok: false, code: 'no_such_option' });
      if (el.multiple) { opt.selected = true; } else { el.value = opt.value; }
      length = opt.value.length;
      fire('input'); fire('change');
    } else if (d.type === 'checkbox' || d.type === 'radio') {
      const want = checked == null ? ['true', 'on', '1', 'yes'].indexOf(String(value).toLowerCase()) >= 0 : !!checked;
      if (d.type === 'radio' && !want) return JSON.stringify({ ok: false, code: 'radio_cannot_uncheck' });
      if (el.checked !== want) { el.click(); if (el.checked !== want) { el.checked = want; fire('input'); fire('change'); } }
    } else if (d.tag === 'input' || d.tag === 'textarea') {
      if (['file', 'submit', 'button', 'reset', 'image', 'hidden'].indexOf(d.type) >= 0) return JSON.stringify({ ok: false, code: 'not_fillable', type: d.type });
      const proto = d.tag === 'input' ? HTMLInputElement.prototype : HTMLTextAreaElement.prototype;
      const setter = Object.getOwnPropertyDescriptor(proto, 'value').set;
      el.focus();
      setter.call(el, String(value));
      length = String(el.value).length;
      fire('input'); fire('change');
    } else if (d.editable) {
      el.focus();
      el.textContent = String(value);
      length = String(value).length;
      fire('input');
    } else {
      return JSON.stringify({ ok: false, code: 'not_fillable', type: d.tag });
    }
    if (secret) window.__orixSecret.add(el);
    return JSON.stringify({ ok: true, tag: d.tag, type: d.type || 'text', secure: d.secure || !!secret, valueLength: length,
                            checked: (d.type === 'checkbox' || d.type === 'radio') ? !!el.checked : null });
    """#

    /// Arguments: selector. Clicks after checking existence, visibility and enabled state.
    static let click = prelude + #"""
    const r = find(selector);
    if (r.error) return JSON.stringify({ ok: false, code: r.error });
    const el = r.el;
    if (!el) return JSON.stringify({ ok: false, code: 'not_found' });
    el.scrollIntoView({ block: 'center', inline: 'center' });
    const d = describe(el);
    if (!d.visible) return JSON.stringify({ ok: false, code: 'not_visible' });
    if (d.disabled) return JSON.stringify({ ok: false, code: 'disabled' });
    const info = { ok: true, tag: d.tag, type: d.type, text: d.secure ? '' : clean(el.innerText || el.value || el.getAttribute('aria-label') || '', 200),
                   href: el.tagName === 'A' ? (el.href || '') : '' };
    el.click();
    return JSON.stringify(info);
    """#

    /// Arguments: selector (string or null), state (`present`, `visible`, `absent`), text (string or null), sliceMs.
    /// Resolves as soon as the conditions hold (MutationObserver plus a coarse poll for style-only changes), or with
    /// `matched: false` when the slice ends.
    static let wait = prelude + #"""
    function check() {
      if (selector != null) {
        let el = null;
        try { el = document.querySelector(selector); } catch (e) { return 'invalid_selector'; }
        if (state === 'absent') { if (el) return false; }
        else if (!el) return false;
        else if (state === 'visible' && !isVisible(el)) return false;
      }
      if (text != null) {
        const hay = document.body ? (document.body.innerText || '') : '';
        if (hay.indexOf(text) < 0) return false;
      }
      return true;
    }
    return await new Promise(resolve => {
      let done = false, observer = null, poll = null, timer = null;
      function finish(result) {
        if (done) return;
        done = true;
        if (observer) observer.disconnect();
        if (poll) clearInterval(poll);
        if (timer) clearTimeout(timer);
        resolve(JSON.stringify(result));
      }
      function probe() {
        const c = check();
        if (c === 'invalid_selector') finish({ matched: false, error: c });
        else if (c) finish({ matched: true });
      }
      probe();
      if (done) return;
      observer = new MutationObserver(probe);
      observer.observe(document.documentElement, { childList: true, subtree: true, attributes: true, characterData: true });
      poll = setInterval(probe, 100);
      timer = setTimeout(() => finish({ matched: false }), sliceMs);
    });
    """#
}
