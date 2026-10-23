// FosterStack checkout script: one same-origin file, no dependencies, no inline script anywhere (payments SB-10.2, SB-10.4, SB-10.5, SB-10.6).
// It holds no secret, no price and no Stripe code (SB-10.3). It sends only: the buy click to the checkout address, one read to the entitlement
// address from the success page, and the resend page's address to the resend address. It stores nothing: no cookie, no browser storage.
// The resend page's email field is the owner's ratified exception to "no form on www" (SB-10.6, revised Q9); no other page may have one.
(function (root, factory) {
  "use strict";
  var api = factory();
  if (typeof module === "object" && module.exports) module.exports = api;
  else { root.FosterPay = api; if (typeof document !== "undefined") api.boot(root, document); }
})(typeof window !== "undefined" ? window : this, function () {
  "use strict";

  var TEXT = {
    // TODO-COPY: every line below is a placeholder for the owner's wording (checkout wording draft, items 2 to 4); the lines marked ratified are exact.
    closed: "TODO-COPY: Checkout is not open yet.",
    checkoutFailed: "TODO-COPY: We could not start checkout just now. Please try again in a minute.",
    resendSent: "If this address has a purchase, we sent the key.",
    resendFailed: "TODO-COPY: We are busy. Please try again in a minute.",
    resendBadAddress: "TODO-COPY: Please type the address you bought with.",
    resendPromise: "We never store the address you type. It is used once to send your key and then discarded. Amazon's email service may keep an address that bounces.",
    processing: "TODO-COPY: Your payment is still being confirmed. Check again in a minute.",
    none: "TODO-COPY: There is no key to show on this page. A key is shown only once, right after payment. If you already saw yours and lost it, you can have it sent again.",
    error: "TODO-COPY: We could not read your order just now. Please try again in a minute."
  };

  var STRIPE_HOST = "checkout.stripe.com";
  var TIERS = { team: 1, business: 1, compliance: 1 };
  var INTERVALS = { month: 1, year: 1 };
  var SESSION = /^cs_test_[A-Za-z0-9_]{1,200}$/; // test mode only: a live id is never sent from this build

  function enabled(cfg) {
    if (!cfg || cfg.enabled !== true) return false;
    return ["checkout", "entitlement", "resend"].every(function (k) { return typeof cfg[k] === "string" && /^https:\/\/[a-z0-9.-]+\/$/.test(cfg[k]); });
  }

  function newAttemptId(c) {
    var b = new Uint8Array(16);
    c.getRandomValues(b);
    b[6] = (b[6] & 0x0f) | 0x40;
    b[8] = (b[8] & 0x3f) | 0x80;
    var h = Array.prototype.map.call(b, function (x) { return (x + 256).toString(16).slice(1); }).join("");
    return h.slice(0, 8) + "-" + h.slice(8, 12) + "-" + h.slice(12, 16) + "-" + h.slice(16, 20) + "-" + h.slice(20);
  }

  // One attempt id per choice, kept in memory only: a double click repeats it (one session at the backend), a changed choice makes a new one.
  function attemptHolder(c) {
    var key = "", id = "";
    return { get: function (tier, interval) { var k = tier + "|" + interval; if (k !== key) { key = k; id = newAttemptId(c); } return id; } };
  }

  function stripeUrlOk(u) {
    if (typeof u !== "string") return false;
    try {
      var p = new URL(u);
      return p.protocol === "https:" && p.hostname === STRIPE_HOST && p.port === "" && p.username === "" && p.password === "";
    } catch (e) { return false; }
  }

  // fetch with a time limit; any failure becomes null, so no detail from the network or the backend ever reaches the page
  async function call(d, url, init) {
    var ctl = typeof AbortController === "function" ? new AbortController() : null;
    var timer = null;
    if (ctl) { init.signal = ctl.signal; timer = setTimeout(function () { ctl.abort(); }, d.timeoutMs || 15000); }
    try {
      var r = await d.fetch(url, init);
      var body = null;
      try { body = JSON.parse(await r.text()); } catch (e) { body = null; }
      return { status: r.status, body: body };
    } catch (e) { return null; } finally { if (timer) clearTimeout(timer); }
  }

  async function startCheckout(choice, d) {
    var fail = { ok: false, text: TEXT.checkoutFailed };
    if (!enabled(d.config)) return { ok: false, text: TEXT.closed };
    if (!choice || !TIERS[choice.tier] || !INTERVALS[choice.interval] || (choice.tier === "compliance" && choice.interval !== "year")) return fail;
    var res = await call(d, d.config.checkout + "v1/checkout-session", {
      method: "POST", credentials: "omit",
      headers: { "Content-Type": "application/json", "Idempotency-Key": d.attemptId },
      body: JSON.stringify({ product: "cache", tier: choice.tier, interval: choice.interval })
    });
    if (!res || res.status !== 200 || !res.body || !stripeUrlOk(res.body.url)) return fail;
    (d.navigate || function (u) { window.location.assign(u); })(res.body.url);
    return { ok: true };
  }

  function sessionFromSearch(search) {
    if (typeof search !== "string" || search.charAt(0) !== "?") return "";
    var rest = search.slice(1);
    if (rest.indexOf("&") !== -1 || rest.slice(0, 2) !== "s=") return "";
    var v = rest.slice(2);
    return SESSION.test(v) ? v : "";
  }

  async function readEntitlement(sid, d) {
    if (!enabled(d.config)) return { status: "closed" };
    if (typeof sid !== "string" || !SESSION.test(sid)) return { status: "none" };
    var res = await call(d, d.config.entitlement + "v1/entitlement?s=" + sid, { method: "GET", credentials: "omit" });
    if (!res || res.status !== 200 || !res.body) return { status: "error" };
    var s = res.body.status;
    if (s === "key") return typeof res.body.key === "string" && res.body.key !== "" ? { status: "key", key: res.body.key } : { status: "error" };
    if (s === "processing" || s === "none") return { status: s };
    return { status: "error" };
  }

  var ADDRESS = /^[^\s@]{1,64}@[^\s@]{1,190}\.[^\s@]{1,63}$/;

  async function sendResend(email, d) {
    if (!enabled(d.config)) return { ok: false, text: TEXT.closed };
    if (typeof email !== "string" || email.length > 254 || !ADDRESS.test(email)) return { ok: false, text: TEXT.resendBadAddress };
    var res = await call(d, d.config.resend + "v1/resend", { method: "POST", credentials: "omit", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ email: email }) });
    if (!res || res.status !== 202 || !res.body || res.body.status !== "ok") return { ok: false, text: TEXT.resendFailed };
    return { ok: true, text: TEXT.resendSent };
  }

  function scrubAddress(loc, hist) { hist.replaceState(null, "", loc.pathname); }

  // Everything below puts values on the page as text, never as markup.
  function renderEntitlement(out, doc) {
    var box = doc.getElementById("fp-key-box"), key = doc.getElementById("fp-key"), note = doc.getElementById("fp-note"), again = doc.getElementById("fp-again");
    if (box) box.hidden = out.status !== "key";
    if (key) key.textContent = out.status === "key" ? out.key : "";
    if (note) note.textContent = out.status === "key" ? "" : (TEXT[out.status] || TEXT.error);
    if (again) again.hidden = out.status !== "processing";
  }

  function show(doc, id, on) { var e = doc.getElementById(id); if (e) e.hidden = !on; }

  function boot(win, doc) {
    var cfg = win.FOSTERPAY_CONFIG;
    var on = enabled(cfg);
    show(doc, "fp-closed", !on);
    show(doc, "fp-open", on);
    if (!on) return;
    var d = { config: cfg, fetch: function (u, i) { return win.fetch(u, i); } };
    var buttons = doc.querySelectorAll("[data-buy-tier]");
    if (buttons.length) {
      var holder = attemptHolder(win.crypto);
      var status = doc.getElementById("fp-status");
      Array.prototype.forEach.call(buttons, function (b) {
        b.addEventListener("click", async function () {
          var tier = b.getAttribute("data-buy-tier"), interval = b.getAttribute("data-buy-interval");
          b.disabled = true;
          var out = await startCheckout({ tier: tier, interval: interval }, Object.assign({ attemptId: holder.get(tier, interval) }, d));
          if (!out.ok) { b.disabled = false; if (status) status.textContent = out.text; }
        });
      });
    }
    if (doc.getElementById("fp-key-box")) {
      var sid = sessionFromSearch(win.location.search);
      scrubAddress(win.location, win.history);
      var reads = 0;
      var run = async function () { reads += 1; renderEntitlement(await readEntitlement(sid, d), doc); if (reads >= 2) show(doc, "fp-again", false); };
      run();
      var again = doc.getElementById("fp-again");
      if (again) again.addEventListener("click", function () { if (reads < 2) run(); });
    }
    var send = doc.getElementById("fp-send");
    if (send) {
      var field = doc.getElementById("fp-email"), result = doc.getElementById("fp-result");
      send.addEventListener("click", async function () {
        send.disabled = true;
        var out = await sendResend(field.value, d);
        if (result) result.textContent = out.text;
        if (out.ok) field.value = "";
        send.disabled = false;
      });
    }
  }

  return { TEXT: TEXT, enabled: enabled, newAttemptId: newAttemptId, attemptHolder: attemptHolder, startCheckout: startCheckout, sessionFromSearch: sessionFromSearch, readEntitlement: readEntitlement, sendResend: sendResend, scrubAddress: scrubAddress, renderEntitlement: renderEntitlement, boot: boot };
});
