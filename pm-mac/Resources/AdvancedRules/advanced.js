// Scriptlets and extended CSS, for the rules a content blocker cannot express.
//
// A content blocker can block a request and hide a selector. It cannot set a cookie a site reads to
// decide whether to nag you, and it cannot select "the div that says Advertisement". Filter lists
// carry both. This applies the subset PM ships — see scripts/pack-advanced.py for which and why.
//
// Injected at document start, in the page's own world, which is where scriptlets are meant to run:
// setting a cookie is only useful if it happens before the page's own scripts read it. Everything is
// inside one IIFE and defines no globals.
(function () {
    "use strict";
    var TABLE = __PM_RULES__;

    // uBO domain scoping: a rule for example.com applies to www.example.com too, so walk the labels
    // up. Split on dots so "ample.com" can never match "example.com".
    function rulesFor(host) {
        var rules = TABLE["*"] ? TABLE["*"].slice() : [];
        var labels = String(host || "").toLowerCase().split(".");
        for (var i = 0; i + 1 < labels.length; i++) {
            var candidate = labels.slice(i).join(".");
            if (TABLE[candidate]) rules = rules.concat(TABLE[candidate]);
        }
        return rules;
    }

    var rules = rulesFor(location.hostname);
    if (rules.length === 0) return;

    // ---- values -------------------------------------------------------------------------------
    // The handful of placeholders the lists use. Anything else is taken literally.
    function expand(value) {
        if (value === "$now$") return String(Date.now());
        if (value === "$currentDate$") return new Date().toUTCString();
        if (value === "$currentISODate$") return new Date().toISOString();
        return value;
    }

    // ---- scriptlets ---------------------------------------------------------------------------
    function setCookie(name, value) {
        // A value carrying a separator would let a rule write attributes it did not declare.
        if (/[;\r\n]/.test(name) || /[;\r\n]/.test(value)) return;
        try {
            var already = document.cookie.split("; ").indexOf(name + "=" + value) !== -1;
            if (already) return;
            document.cookie = name + "=" + value + "; path=/";
        } catch (e) {}
    }

    function setStorage(store, key, value) {
        try {
            var area = store === "l" ? window.localStorage : window.sessionStorage;
            if (!area) return;
            if (value === "$remove$") area.removeItem(key);
            else area.setItem(key, value);
        } catch (e) {}   // Safari throws on storage access in some third-party frames.
    }

    // ---- stylesheet ---------------------------------------------------------------------------
    var pending = "";
    function addStyle(text) { pending += text + "\n"; }

    function flushStyle() {
        if (!pending) return;
        var root = document.head || document.documentElement;
        if (!root) return;
        var style = document.createElement("style");
        style.textContent = pending;
        pending = "";
        root.appendChild(style);
    }

    // ---- :has-text ----------------------------------------------------------------------------
    // The one extended selector the lists actually lean on: match the selector, then keep only the
    // elements whose text contains the phrase.
    var textRules = [];

    function applyTextRules() {
        for (var i = 0; i < textRules.length; i++) {
            var rule = textRules[i];
            var found;
            try {
                found = document.querySelectorAll(rule.selector);
            } catch (e) {
                continue;                       // a selector WebKit will not parse
            }
            for (var j = 0; j < found.length; j++) {
                var element = found[j];
                if (element.__pmHidden) continue;
                var text = element.textContent || "";
                var matches = rule.pattern ? rule.pattern.test(text) : text.indexOf(rule.text) !== -1;
                if (!matches) continue;
                element.__pmHidden = true;
                element.style.setProperty("display", "none", "important");
            }
        }
    }

    function watchForTextRules() {
        if (textRules.length === 0) return;
        applyTextRules();
        // Pages that matter here build themselves after load, so one pass is not enough — but a pass
        // per mutation would be, on a busy page, thousands. Coalesce onto the next frame.
        var queued = false;
        var observer = new MutationObserver(function () {
            if (queued) return;
            queued = true;
            requestAnimationFrame(function () {
                queued = false;
                applyTextRules();
            });
        });
        function start() {
            if (!document.documentElement) return;
            observer.observe(document.documentElement, { childList: true, subtree: true });
            applyTextRules();
        }
        if (document.readyState === "loading") {
            document.addEventListener("DOMContentLoaded", start, { once: true });
        } else {
            start();
        }
    }

    // ---- apply --------------------------------------------------------------------------------
    for (var i = 0; i < rules.length; i++) {
        var rule = rules[i];
        switch (rule[0]) {
        case "c":
            setCookie(rule[1], expand(rule[2]));
            break;
        case "l":
        case "s":
            setStorage(rule[0], rule[1], expand(rule[2]));
            break;
        case "css":
            addStyle(rule[1]);
            break;
        case "ht":
            var text = rule[2];
            var pattern = null;
            if (text.length > 1 && text.charAt(0) === "/" && text.charAt(text.length - 1) === "/") {
                try { pattern = new RegExp(text.slice(1, -1)); } catch (e) { pattern = null; }
            }
            textRules.push({ selector: rule[1], text: text, pattern: pattern });
            break;
        }
    }

    if (document.head || document.documentElement) {
        flushStyle();
    } else {
        document.addEventListener("readystatechange", flushStyle, { once: true });
    }
    watchForTextRules();

    // So the app can confirm this ran, the same way the rule lists are confirmed.
    try {
        document.documentElement.setAttribute("data-pm-advanced", String(rules.length));
    } catch (e) {}
})();
