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

    // ---- json-prune ---------------------------------------------------------------------------
    // Streaming sites stitch their ads into the video server-side, so no request can be refused and
    // no element hidden. What can be done is to edit the playback data before the player reads it:
    // delete the ad-stitched manifest and the player falls back to the clean one. Paths are dotted,
    // with "*" or "[]" standing for every key or element at that level. "[-]" is uBO's array form:
    // `a.[-].b` takes out the elements of `a` that have `b`, rather than deleting `b` from each.
    var pruneRules = [];

    function pathsOf(list) {
        return String(list || "").split(/\s+/).filter(Boolean).map(function (p) { return p.split("."); });
    }

    // Visit every value `parts` names below `node`; `leaf(owner, key, splice)` is handed each one
    // found, with `splice` set when it is an array element "[-]" picked out to be removed whole.
    function walk(node, parts, index, leaf) {
        if (node === null || typeof node !== "object") return;
        var key = parts[index];
        if (key === "[-]") {
            if (!Array.isArray(node)) return;
            var rest = parts.slice(index + 1);
            // Back to front, so removing one leaves the indices still to visit where they were.
            for (var n = node.length - 1; n >= 0; n--) {
                if (rest.length === 0 || has(node[n], rest)) leaf(node, n, true);
            }
            return;
        }
        var keys = key === "*" || key === "[]" ? Object.keys(node) : [key];
        for (var i = 0; i < keys.length; i++) {
            if (!Object.prototype.hasOwnProperty.call(node, keys[i])) continue;
            if (index === parts.length - 1) leaf(node, keys[i]);
            else walk(node[keys[i]], parts, index + 1, leaf);
        }
    }

    function has(node, parts) {
        var found = false;
        walk(node, parts, 0, function () { found = true; });
        return found;
    }

    function prune(value) {
        if (value === null || typeof value !== "object") return;
        try {
            for (var i = 0; i < pruneRules.length; i++) {
                var rule = pruneRules[i];
                if (!rule.required.every(function (p) { return has(value, p); })) continue;
                for (var j = 0; j < rule.remove.length; j++) {
                    walk(value, rule.remove[j], 0, function (owner, key, splice) {
                        if (splice) owner.splice(key, 1);
                        else delete owner[key];
                    });
                }
            }
        } catch (e) {}   // never let a rule break the page's own parse
    }

    function installPrune() {
        if (pruneRules.length === 0) return;
        var parse = JSON.parse;
        JSON.parse = function () {
            var value = parse.apply(this, arguments);
            prune(value);
            return value;
        };
        if (window.Response && Response.prototype.json) {
            var json = Response.prototype.json;
            Response.prototype.json = function () {
                return json.apply(this, arguments).then(function (value) {
                    prune(value);
                    return value;
                });
            };
        }
    }

    // ---- no-xhr-if ----------------------------------------------------------------------------
    // Answer matching XHRs with an empty 200 instead of sending them. Refusing them outright is what
    // a content blocker does, and ad code tends to treat that as an error worth retrying or stalling
    // on; an empty success is what it has no answer to.
    var xhrPatterns = [];

    function patternOf(text) {
        if (text.length > 1 && text.charAt(0) === "/" && text.charAt(text.length - 1) === "/") {
            try { return new RegExp(text.slice(1, -1)); } catch (e) { return null; }
        }
        return { test: function (s) { return s.indexOf(text) !== -1; } };
    }

    function installXHR() {
        if (xhrPatterns.length === 0 || !window.XMLHttpRequest) return;
        var proto = XMLHttpRequest.prototype;
        var open = proto.open;
        var send = proto.send;
        proto.open = function (method, url) {
            var target = String(url);
            this.__pmSilenced = xhrPatterns.some(function (p) { return p.test(target); });
            this.__pmURL = target;
            return open.apply(this, arguments);
        };
        proto.send = function () {
            if (!this.__pmSilenced) return send.apply(this, arguments);
            var xhr = this;
            var empty = xhr.responseType === "json" ? null
                : xhr.responseType === "" || xhr.responseType === "text" ? "" : null;
            try {
                Object.defineProperties(xhr, {
                    readyState: { value: 4 }, status: { value: 200 }, statusText: { value: "OK" },
                    response: { value: empty }, responseText: { value: "" },
                    responseURL: { value: xhr.__pmURL },
                });
            } catch (e) {}
            setTimeout(function () {
                ["readystatechange", "load", "loadend"].forEach(function (type) {
                    try { xhr.dispatchEvent(new Event(type)); } catch (e) {}
                });
            }, 0);
        };
    }

    // ---- xml-prune ----------------------------------------------------------------------------
    // The same idea as json-prune, for players whose ads are stitched into the DASH manifest
    // itself: take the ad Periods out of the .mpd before the player reads it. A rule names what to
    // remove — a CSS selector, or `xpath(...)`, which can also pick out attributes — an optional
    // selector the document must carry first, and the URLs it applies to.
    var xmlRules = [];

    // The rules whose URL pattern `url` matches, or none.
    function xmlRulesFor(url) {
        var target = String(url || "");
        return xmlRules.filter(function (rule) { return rule.url.test(target); });
    }

    // `text` with every rule in `matched` applied, or `text` itself when none of them removed
    // anything — so a manifest no rule touches reaches the player byte for byte as it was sent.
    function pruneXML(text, matched) {
        if (matched.length === 0 || typeof text !== "string" || text.trim().charAt(0) !== "<") return text;
        try {
            var doc = new DOMParser().parseFromString(text, "text/xml");
            if (doc.getElementsByTagName("parsererror").length > 0) return text;
            var removed = 0;
            for (var i = 0; i < matched.length; i++) {
                var rule = matched[i];
                if (rule.required && !doc.querySelector(rule.required)) continue;
                var nodes = [];
                if (rule.xpath) {
                    var found = doc.evaluate(rule.xpath, doc, null, XPathResult.ORDERED_NODE_SNAPSHOT_TYPE, null);
                    for (var j = 0; j < found.snapshotLength; j++) nodes.push(found.snapshotItem(j));
                } else {
                    nodes = Array.prototype.slice.call(doc.querySelectorAll(rule.selector));
                }
                // All found before any is removed: one expression can name a Period and an
                // attribute of the same Period, and the second must not be looked for in a hole.
                for (var k = 0; k < nodes.length; k++) {
                    var node = nodes[k];
                    if (node.nodeType === 2) {
                        if (node.ownerElement) node.ownerElement.removeAttributeNode(node);
                    } else if (node.parentNode) {
                        node.parentNode.removeChild(node);
                    }
                    removed++;
                }
            }
            return removed > 0 ? new XMLSerializer().serializeToString(doc) : text;
        } catch (e) {
            return text;                        // never let a rule break the player's manifest
        }
    }

    function installXMLPrune() {
        if (xmlRules.length === 0) return;

        if (window.fetch && window.Response) {
            var fetch = window.fetch;
            window.fetch = function (input) {
                var requested = input instanceof Request ? input.url : String(input);
                var matched = xmlRulesFor(requested);
                var pending = fetch.apply(this, arguments);
                if (matched.length === 0) return pending;
                return pending.then(function (response) {
                    return response.clone().text().then(function (text) {
                        var pruned = pruneXML(text, matched);
                        if (pruned === text) return response;
                        var edited = new Response(pruned, {
                            status: response.status, statusText: response.statusText,
                            headers: response.headers,
                        });
                        // A new Response has no URL of its own, and a DASH player resolves the
                        // manifest's relative BaseURLs against it.
                        try {
                            Object.defineProperties(edited, {
                                url: { value: response.url }, type: { value: response.type },
                                redirected: { value: response.redirected },
                            });
                        } catch (e) {}
                        return edited;
                    }, function () { return response; });
                });
            };
        }

        if (window.XMLHttpRequest) {
            var proto = XMLHttpRequest.prototype;
            var open = proto.open;
            var textOf = Object.getOwnPropertyDescriptor(proto, "responseText").get;
            var responseOf = Object.getOwnPropertyDescriptor(proto, "response").get;
            proto.open = function (method, url) {
                var matched = xmlRulesFor(url);
                // An XHR can be opened again for another URL; what was set up for the last one
                // must not outlive it.
                try {
                    delete this.responseText;
                    delete this.response;
                } catch (e) {}                  // no-xhr-if's answer is fixed; nothing to undo
                if (matched.length > 0) {
                    // Getters on the instance rather than a listener: the player's own listener
                    // may well be registered first, and a getter is read whenever it reads.
                    var text = null;
                    var buffer = null;
                    var prunedText = function (xhr) {
                        if (text === null) text = pruneXML(textOf.call(xhr), matched);
                        return text;
                    };
                    // Players that parse manifests themselves often ask for bytes, not text.
                    var prunedBuffer = function (xhr) {
                        if (buffer !== null) return buffer;
                        var raw = responseOf.call(xhr);
                        buffer = raw;
                        if (!(raw instanceof ArrayBuffer) || !window.TextDecoder) return buffer;
                        var decoded = new TextDecoder().decode(raw);
                        var pruned = pruneXML(decoded, matched);
                        if (pruned !== decoded) buffer = new TextEncoder().encode(pruned).buffer;
                        return buffer;
                    };
                    try {
                        Object.defineProperty(this, "responseText", {
                            configurable: true,
                            get: function () {
                                return this.readyState === 4 ? prunedText(this) : textOf.call(this);
                            },
                        });
                        Object.defineProperty(this, "response", {
                            configurable: true,
                            get: function () {
                                if (this.readyState !== 4) return responseOf.call(this);
                                var type = this.responseType;
                                if (type === "" || type === "text") return prunedText(this);
                                if (type === "arraybuffer") return prunedBuffer(this);
                                return responseOf.call(this);
                            },
                        });
                    } catch (e) {}
                }
                return open.apply(this, arguments);
            };
        }
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
        case "jp":
            pruneRules.push({ remove: pathsOf(rule[1]), required: pathsOf(rule[2]) });
            break;
        case "xhr":
            var xhrPattern = patternOf(rule[1]);
            if (xhrPattern) xhrPatterns.push(xhrPattern);
            break;
        case "xp":
            var match = rule[1];
            var xpath = /^xpath\(([\s\S]*)\)$/.exec(match);
            var urlPattern = patternOf(rule[3] || "");
            if (urlPattern) {
                xmlRules.push({ xpath: xpath ? xpath[1] : null, selector: xpath ? null : match,
                                required: rule[2] || "", url: urlPattern });
            }
            break;
        }
    }

    // Before anything else: these have to be in place before the page's first script runs.
    installPrune();
    installXHR();
    installXMLPrune();

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
