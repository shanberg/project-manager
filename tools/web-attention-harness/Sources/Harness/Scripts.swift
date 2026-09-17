enum Scripts {
    /// Main frame, its own content world, in both modes: what the page shows without notifying — the
    /// favicon, and whether it thinks it is visible. The title is watched natively.
    static let observe = """
    (function () {
      var post = function (kind, payload) {
        try { window.webkit.messageHandlers.harnessObserve.postMessage({ kind: kind, payload: payload }) } catch (e) {}
      }
      var hash = function (s) { var h = 0; for (var i = 0; i < s.length; i++) { h = (h * 31 + s.charCodeAt(i)) | 0 } return h }
      var last = null
      var report = function () {
        var links = document.querySelectorAll('link[rel~="icon"], link[rel="shortcut icon"], link[rel="apple-touch-icon"]')
        var hrefs = Array.prototype.map.call(links, function (l) {
          var h = l.href || ''
          return h.length > 160 ? h.slice(0, 60) + '…(' + h.length + ' chars, hash ' + hash(h) + ')' : h
        }).join(' , ')
        if (hrefs !== last) { last = hrefs; post('favicon', { hrefs: hrefs }) }
      }
      var start = function () {
        report()
        new MutationObserver(report).observe(document.head || document.documentElement,
          { subtree: true, childList: true, attributes: true, attributeFilter: ['href', 'rel'] })
      }
      if (document.head) start(); else document.addEventListener('DOMContentLoaded', start)
      document.addEventListener('visibilitychange', function () { post('visibility', { state: document.visibilityState }) })
    })()
    """

    /// Page world, every frame, at document start — the Ferdium / Tauri approach: stand in for
    /// `Notification`, say permission is granted, and record everything the page passes.
    static let shim = """
    (function () {
      if (window.__harnessShim) return
      window.__harnessShim = true
      var post = function (kind, payload) {
        try { window.webkit.messageHandlers.harness.postMessage({ kind: kind, payload: payload }) } catch (e) {}
      }
      var safe = function (v) {
        if (v === undefined) return null
        try { return JSON.parse(JSON.stringify(v)) } catch (e) { try { return String(v) } catch (e2) { return '<unserialisable>' } }
      }
      var describe = function (title, options, extra) {
        options = options || {}
        var record = {
          title: String(title), body: options.body, tag: options.tag, data: safe(options.data),
          icon: options.icon, badge: options.badge, image: options.image, silent: options.silent,
          requireInteraction: options.requireInteraction, renotify: options.renotify, lang: options.lang,
          dir: options.dir, actions: safe(options.actions), timestamp: options.timestamp,
          optionKeys: Object.keys(options), visibility: document.visibilityState, hasFocus: document.hasFocus(),
          href: location.href
        }
        for (var k in extra) record[k] = extra[k]
        return record
      }
      var made = {}
      var next = 1
      class HarnessNotification extends EventTarget {
        constructor(title, options) {
          super()
          options = options || {}
          this.title = String(title)
          this.body = options.body || ''
          this.tag = options.tag || ''
          this.data = options.data === undefined ? null : options.data
          this.icon = options.icon || ''
          this.silent = !!options.silent
          this.requireInteraction = !!options.requireInteraction
          this.lang = options.lang || ''
          this.dir = options.dir || 'auto'
          this.onclick = null; this.onclose = null; this.onerror = null; this.onshow = null
          this.__id = next++
          made[this.__id] = this
          post('notification', describe(title, options, { id: this.__id }))
          var self = this
          Promise.resolve().then(function () {
            var ev = new Event('show')
            self.dispatchEvent(ev)
            if (typeof self.onshow === 'function') self.onshow(ev)
          })
        }
        close() {
          post('notificationClosedByPage', { id: this.__id, tag: this.tag })
          var ev = new Event('close')
          this.dispatchEvent(ev)
          if (typeof this.onclose === 'function') this.onclose(ev)
        }
        static get permission() { return 'granted' }
        static get maxActions() { return 2 }
        static requestPermission(callback) {
          post('requestPermission', { href: location.href })
          if (typeof callback === 'function') callback('granted')
          return Promise.resolve('granted')
        }
      }
      window.Notification = HarnessNotification
      window.__harnessClick = function (id) {
        var n = made[id]
        if (!n) return 'no notification ' + id
        var ev = new Event('click', { cancelable: true })
        n.dispatchEvent(ev)
        if (typeof n.onclick === 'function') n.onclick.call(n, ev)
        return 'clicked ' + id + (typeof n.onclick === 'function' ? ' (onclick)' : ' (listeners only)')
      }
      if (navigator.permissions && navigator.permissions.query) {
        var query = navigator.permissions.query.bind(navigator.permissions)
        navigator.permissions.query = function (descriptor) {
          if (descriptor && (descriptor.name === 'notifications' || descriptor.name === 'push')) {
            post('permissionsQuery', { name: descriptor.name })
            return Promise.resolve({ name: descriptor.name, state: 'granted', status: 'granted', onchange: null,
              addEventListener: function () {}, removeEventListener: function () {} })
          }
          return query(descriptor)
        }
      }
      if (window.ServiceWorkerRegistration && ServiceWorkerRegistration.prototype.showNotification) {
        ServiceWorkerRegistration.prototype.showNotification = function (title, options) {
          post('serviceWorkerNotificationFromPage', describe(title, options, {}))
          return Promise.resolve()
        }
      }
      navigator.setAppBadge = function (count) { post('appBadge', { count: count === undefined ? null : count }); return Promise.resolve() }
      navigator.clearAppBadge = function () { post('appBadge', { count: 0 }); return Promise.resolve() }
    })()
    """
}
