// Tests for the checkout script (written before the script). Plain node, no dependencies: `node --test tests/`.
// Rules served: payments SB-10.2, SB-10.4, SB-10.5, SB-10.6 (ratified Oct 9) and the www drafts WB-1..WB-15 (docs in the ops repo, not yet ratified).
// The resend page's email field is the owner's ratified single exception to "no form on www" (SB-10.6, revised Q9).
"use strict";
const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const root = path.join(__dirname, "..");
const FP = require(path.join(root, "checkout.js"));

const ON = { enabled: true, checkout: "https://aaaaaaaaaaaaaaaaaaaaaa.lambda-url.us-east-1.on.aws/", entitlement: "https://bbbbbbbbbbbbbbbbbbbbbb.lambda-url.us-east-1.on.aws/", resend: "https://cccccccccccccccccccccc.lambda-url.us-east-1.on.aws/" };
const OFF = { enabled: false, checkout: "", entitlement: "", resend: "" };
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;

function recorder(answer) {
  const calls = [];
  const fetch = async (url, init) => { calls.push({ url, init }); return typeof answer === "function" ? answer(url, init) : answer; };
  return { fetch, calls };
}
function resp(status, body) { return { status, ok: status >= 200 && status < 300, text: async () => (typeof body === "string" ? body : JSON.stringify(body)) }; }
function files(dir, ext, out = []) {
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    if (e.name.startsWith(".") || e.name === "node_modules") continue;
    const p = path.join(dir, e.name);
    if (e.isDirectory()) files(p, ext, out); else if (p.endsWith(ext)) out.push(p);
  }
  return out;
}

test("test_wb_1_flag_off_no_button_no_page_no_request", async () => {
  const r = recorder(resp(200, { url: "https://checkout.stripe.com/c/pay/x" }));
  assert.equal(FP.enabled(OFF), false);
  assert.equal(FP.enabled({ enabled: true, checkout: "", entitlement: "", resend: "" }), false, "on with no addresses is still off");
  assert.equal(FP.enabled({ ...ON, enabled: "yes" }), false, "only the boolean true turns it on");
  const out = await FP.startCheckout({ tier: "team", interval: "month" }, { config: OFF, fetch: r.fetch, attemptId: "x" });
  assert.equal(out.ok, false);
  assert.equal(r.calls.length, 0, "no request while off");
  const e = await FP.readEntitlement("cs_test_abc", { config: OFF, fetch: r.fetch });
  assert.equal(e.status, "closed");
  const s = await FP.sendResend("a@b.co", { config: OFF, fetch: r.fetch });
  assert.equal(s.ok, false);
  assert.equal(r.calls.length, 0);
  const cfg = fs.readFileSync(path.join(root, "checkout-config.js"), "utf8");
  assert.match(cfg, /enabled:\s*false/, "the shipped config is OFF");
  assert.doesNotMatch(cfg, /lambda-url/, "no address is committed before the owner's apply");
});

test("test_wb_2_request_has_only_the_three_fields", async () => {
  const r = recorder(resp(200, { url: "https://checkout.stripe.com/c/pay/x" }));
  const nav = [];
  const id = FP.newAttemptId({ getRandomValues: (a) => { for (let i = 0; i < a.length; i++) a[i] = (i * 37 + 11) & 255; return a; } });
  assert.match(id, UUID);
  const out = await FP.startCheckout({ tier: "business", interval: "year" }, { config: ON, fetch: r.fetch, attemptId: id, navigate: (u) => nav.push(u) });
  assert.equal(out.ok, true);
  assert.equal(r.calls.length, 1);
  const c = r.calls[0];
  assert.equal(c.url, ON.checkout + "v1/checkout-session");
  assert.equal(c.init.method, "POST");
  assert.deepEqual(JSON.parse(c.init.body), { product: "cache", tier: "business", interval: "year" });
  assert.deepEqual(Object.keys(c.init.headers).map((k) => k.toLowerCase()).sort(), ["content-type", "idempotency-key"]);
  assert.equal(c.init.headers["Idempotency-Key"], id);
  assert.equal(c.init.credentials, "omit", "no cookies");
  assert.equal(c.init.headers["Content-Type"], "application/json");
  assert.deepEqual(nav, ["https://checkout.stripe.com/c/pay/x"]);
});

test("test_wb_2_a_double_click_reuses_the_attempt_id", async () => {
  const ids = [];
  const r = recorder((u, init) => { ids.push(init.headers["Idempotency-Key"]); return resp(200, { url: "https://checkout.stripe.com/c/pay/x" }); });
  const attempt = FP.attemptHolder({ getRandomValues: (a) => { for (let i = 0; i < a.length; i++) a[i] = (i * 7 + 3) & 255; return a; } });
  const d = { config: ON, fetch: r.fetch, navigate: () => {} };
  await FP.startCheckout({ tier: "team", interval: "month" }, { ...d, attemptId: attempt.get("team", "month") });
  await FP.startCheckout({ tier: "team", interval: "month" }, { ...d, attemptId: attempt.get("team", "month") });
  assert.equal(ids[0], ids[1], "the same click sequence keeps one attempt id");
  assert.match(ids[0], UUID);
});

test("test_wb_3_compliance_year_only_and_nothing_else_is_sent", async () => {
  const r = recorder(resp(200, { url: "https://checkout.stripe.com/x" }));
  const d = { config: ON, fetch: r.fetch, attemptId: "x", navigate: () => {} };
  for (const bad of [{ tier: "compliance", interval: "month" }, { tier: "free", interval: "month" }, { tier: "team", interval: "week" }, { tier: "", interval: "year" }, {}, { tier: "team" }]) {
    const out = await FP.startCheckout(bad, d);
    assert.equal(out.ok, false, JSON.stringify(bad));
  }
  assert.equal(r.calls.length, 0);
});

test("test_wb_4_only_the_stripe_checkout_host_is_followed", async () => {
  for (const url of ["http://checkout.stripe.com/x", "https://evil.example/x", "https://checkout.stripe.com.evil.example/x", "javascript:alert(1)", "//checkout.stripe.com/x", "https://user@evil.example/", "https://checkout.stripe.com@evil.example/", 5, null, "", "https://checkout.stripe.com:8443/x"]) {
    const nav = [];
    const r = recorder(resp(200, { url }));
    const out = await FP.startCheckout({ tier: "team", interval: "month" }, { config: ON, fetch: r.fetch, attemptId: "x", navigate: (u) => nav.push(u) });
    assert.equal(out.ok, false, String(url));
    assert.deepEqual(nav, [], String(url));
  }
});

test("test_wb_5_every_failure_ends_on_fixed_text", async () => {
  const cases = [resp(400, { error: "bad_tier" }), resp(502, { error: "unavailable" }), resp(429, ""), resp(503, ""), resp(200, "not json"), resp(200, { nourl: 1 }), resp(200, { url: "https://checkout.stripe.com/x", extra: "SECRET-DETAIL" }) /* extra field: still fine, but never shown */];
  for (const c of cases.slice(0, 6)) {
    const nav = [];
    const r = recorder(c);
    const out = await FP.startCheckout({ tier: "team", interval: "month" }, { config: ON, fetch: r.fetch, attemptId: "x", navigate: (u) => nav.push(u) });
    assert.equal(out.ok, false);
    assert.equal(out.text, FP.TEXT.checkoutFailed);
    assert.deepEqual(nav, []);
  }
  const thrown = await FP.startCheckout({ tier: "team", interval: "month" }, { config: ON, fetch: async () => { throw new Error("net SECRET-DETAIL"); }, attemptId: "x", navigate: () => {} });
  assert.equal(thrown.text, FP.TEXT.checkoutFailed);
  assert.doesNotMatch(JSON.stringify(thrown), /SECRET-DETAIL/);
  const slow = await FP.startCheckout({ tier: "team", interval: "month" }, { config: ON, fetch: (u, init) => new Promise((_, rej) => init.signal.addEventListener("abort", () => rej(new Error("aborted")))), attemptId: "x", navigate: () => {}, timeoutMs: 20 });
  assert.equal(slow.text, FP.TEXT.checkoutFailed, "no answer in time ends on the fixed text");
});

test("test_wb_7_the_success_page_makes_one_call_and_shows_only_the_three_states", async () => {
  const sid = "cs_test_a1B2c3";
  for (const [body, want] of [[{ status: "key", key: "FS-KEY-123" }, "key"], [{ status: "processing" }, "processing"], [{ status: "none" }, "none"]]) {
    const r = recorder(resp(200, body));
    const out = await FP.readEntitlement(sid, { config: ON, fetch: r.fetch });
    assert.equal(out.status, want);
    assert.equal(r.calls.length, 1);
    assert.equal(r.calls[0].url, ON.entitlement + "v1/entitlement?s=" + sid);
    assert.equal(r.calls[0].init.method, "GET");
    assert.equal(r.calls[0].init.credentials, "omit");
    if (want === "key") assert.equal(out.key, "FS-KEY-123"); else assert.equal(out.key, undefined);
  }
  for (const body of [{ status: "key" }, { status: "key", key: 5 }, { status: "key", key: "" }, { status: "other" }, {}, "x"]) {
    const out = await FP.readEntitlement(sid, { config: ON, fetch: recorder(resp(200, body)).fetch });
    assert.equal(out.status, "error", JSON.stringify(body));
  }
  for (const c of [resp(400, { error: "bad_request" }), resp(503, { error: "unavailable" }), resp(429, "")]) {
    const out = await FP.readEntitlement(sid, { config: ON, fetch: recorder(c).fetch });
    assert.equal(out.status, "error");
  }
  const r = recorder(resp(200, { status: "none" }));
  for (const bad of ["", "abc", "cs_test_", "cs_test_a&b=1", "cs_test_a b", "cs_live_x", "cs_test_a%20b", null, undefined]) {
    const out = await FP.readEntitlement(bad, { config: ON, fetch: r.fetch });
    assert.equal(out.status, "none", "no usable session id: the fixed nothing text, and no call: " + bad);
  }
  assert.equal(r.calls.length, 0);
});

test("test_wb_7_session_id_comes_from_the_address_only_when_it_is_exactly_s", () => {
  assert.equal(FP.sessionFromSearch("?s=cs_test_abc123"), "cs_test_abc123");
  for (const bad of ["", "?", "?s=", "?x=cs_test_a", "?s=cs_test_a&t=1", "?s=cs_live_a", "?s=cs_test_a%2F", "?s=cs_test_a&s=cs_test_b"]) assert.equal(FP.sessionFromSearch(bad), "", bad);
});

function fakeEl() {
  return { textContent: "", hidden: false, attrs: {}, children: [], setAttribute(k, v) { this.attrs[k] = v; }, appendChild(c) { this.children.push(c); }, addEventListener() {} };
}

test("test_wb_8_values_are_inserted_as_text_not_markup", () => {
  const evil = '<img src=x onerror=alert(1)><script>alert(2)</script>';
  const box = fakeEl(), note = fakeEl();
  const doc = { getElementById: (id) => ({ "fp-key": box, "fp-note": note })[id] || fakeEl() };
  FP.renderEntitlement({ status: "key", key: evil }, doc);
  assert.equal(box.textContent, evil, "set as text");
  assert.equal(box.innerHTML, undefined, "never touched as markup");
  const src = fs.readFileSync(path.join(root, "checkout.js"), "utf8");
  assert.doesNotMatch(src, /innerHTML|outerHTML|insertAdjacentHTML|document\.write|\beval\(|new Function/);
});

test("test_wb_9_nothing_stored_and_the_session_id_leaves_the_address_bar", () => {
  const src = fs.readFileSync(path.join(root, "checkout.js"), "utf8");
  assert.doesNotMatch(src, /localStorage|sessionStorage|document\.cookie|indexedDB|console\./);
  const calls = [];
  FP.scrubAddress({ pathname: "/checkout/success/", search: "?s=cs_test_abc", hash: "" }, { replaceState: (...a) => calls.push(a), state: null });
  assert.equal(calls.length, 1);
  assert.equal(calls[0][2], "/checkout/success/", "the address is rewritten without the id");
  assert.equal(JSON.stringify(calls[0][0]), "null");
});

test("test_wb_10_resend_posts_only_the_email_in_the_body_and_shows_fixed_text", async () => {
  const r = recorder(resp(202, { status: "ok" }));
  const out = await FP.sendResend("buyer@example.com", { config: ON, fetch: r.fetch });
  assert.equal(out.ok, true);
  assert.equal(out.text, FP.TEXT.resendSent);
  const c = r.calls[0];
  assert.equal(c.url, ON.resend + "v1/resend");
  assert.equal(c.init.method, "POST");
  assert.deepEqual(JSON.parse(c.init.body), { email: "buyer@example.com" });
  assert.equal(c.url.includes("buyer"), false, "never in the address");
  assert.deepEqual(Object.keys(c.init.headers).map((k) => k.toLowerCase()), ["content-type"]);
  assert.equal(c.init.credentials, "omit");
  assert.match(FP.TEXT.resendSent, /if this address has a purchase, we sent the key/i);
  assert.equal(FP.TEXT.resendPromise, "We never store the address you type. It is used once to send your key and then discarded. Amazon's email service may keep an address that bounces.");
  const bad = await FP.sendResend("not an address", { config: ON, fetch: r.fetch });
  assert.equal(bad.ok, false);
  assert.equal(r.calls.length, 1, "an invalid address makes no call");
});

test("test_wb_12_resend_failure_is_fixed_text_and_claims_nothing", async () => {
  for (const c of [resp(400, { error: "bad_request" }), resp(503, { error: "unavailable" }), resp(200, { status: "ok" }), resp(202, { status: "no" }), resp(202, "x"), resp(429, "")]) {
    const out = await FP.sendResend("buyer@example.com", { config: ON, fetch: recorder(c).fetch });
    assert.equal(out.ok, false);
    assert.equal(out.text, FP.TEXT.resendFailed);
    assert.doesNotMatch(out.text, /sent/i, "no claim about an email");
  }
  const t = await FP.sendResend("buyer@example.com", { config: ON, fetch: async () => { throw new Error("x"); } });
  assert.equal(t.text, FP.TEXT.resendFailed);
});

test("test_wb_11_resend_is_the_only_page_with_an_email_field", () => {
  const pages = files(root, ".html").filter((p) => !p.includes(`${path.sep}.claude${path.sep}`));
  const withField = pages.filter((p) => /<(input|textarea|form|select)\b/i.test(fs.readFileSync(p, "utf8"))).map((p) => path.relative(root, p));
  assert.deepEqual(withField, [path.join("resend-key", "index.html")]);
  const js = fs.readFileSync(path.join(root, "checkout.js"), "utf8");
  assert.match(js, /ratified exception/i, "the code says why the one field exists");
});

test("test_sb_10_4_cancel_page_static", () => {
  const html = fs.readFileSync(path.join(root, "checkout", "cancel", "index.html"), "utf8");
  assert.match(html, /No charge was made\./);
  assert.match(html, /href="\/#pricing"|href="\/buy\/"/);
  assert.doesNotMatch(html, /<script/i, "needs nothing from the backend");
});

test("test_wb_14_no_secret_no_price_logic_no_stripe_js", () => {
  for (const f of ["checkout.js", "checkout-config.js"]) {
    const s = fs.readFileSync(path.join(root, f), "utf8");
    assert.doesNotMatch(s, /\b(sk|rk|pk)_(test|live)_|\bwhsec_|price_[A-Za-z0-9]|\bamount\b|unit_amount|js\.stripe\.com/, f);
  }
  for (const p of ["buy", "checkout/success", "checkout/cancel", "resend-key"]) {
    const h = fs.readFileSync(path.join(root, p, "index.html"), "utf8");
    assert.doesNotMatch(h, /js\.stripe\.com|stripe\.js/i, p);
  }
});

test("test_wb_15_no_cookie_no_analytics_no_third_party_load", () => {
  for (const p of ["buy", "checkout/success", "checkout/cancel", "resend-key"]) {
    const h = fs.readFileSync(path.join(root, p, "index.html"), "utf8");
    assert.doesNotMatch(h, /<(script|img|iframe)\b[^>]*\bsrc="(https?:)?\/\//i, p);
    assert.doesNotMatch(h, /<link\b[^>]*rel="stylesheet"[^>]*href="https?:/i, p);
    assert.match(h, /<meta name="robots" content="noindex">/, p + " is unlisted");
  }
});

test("test_wb_6_the_new_pages_are_unlisted_and_carry_the_draft_marks", () => {
  const sm = fs.readFileSync(path.join(root, "sitemap.xml"), "utf8");
  const llms = fs.readFileSync(path.join(root, "llms.txt"), "utf8");
  for (const p of ["/buy/", "/checkout/success/", "/checkout/cancel/", "/resend-key/"]) {
    assert.equal(sm.includes(p), false, p + " not in the sitemap");
    assert.equal(llms.includes(p), false, p + " not in llms.txt");
  }
  const buy = fs.readFileSync(path.join(root, "buy", "index.html"), "utf8");
  assert.match(buy, /TODO-COPY/, "customer-visible copy that is not the owner's yet is marked");
});

test("test_wb_16_every_page_loads_the_config_before_the_script_and_off_means_not_open", () => {
  for (const p of ["buy", "checkout/success", "resend-key"]) {
    const h = fs.readFileSync(path.join(root, p, "index.html"), "utf8");
    const a = h.indexOf('src="/checkout-config.js"'), b = h.indexOf('src="/checkout.js"');
    assert.ok(a > 0 && b > a, p + ": config first, then script, both same-origin files");
    assert.doesNotMatch(h.replace(/<script[^>]*src=[^>]*><\/script>/g, ""), /<script/i, p + ": no inline script");
    assert.match(h, /id="fp-closed"/, p + " has the not-open-yet text");
  }
});

// Wiring through boot() with a small hand-made document.
function page(ids, buttons) {
  const els = {};
  for (const id of ids) els[id] = { id, hidden: false, textContent: "", value: "", disabled: false, handlers: {}, addEventListener(t, f) { this.handlers[t] = f; } };
  const btns = (buttons || []).map((b) => ({ ...b, disabled: false, handlers: {}, getAttribute(k) { return this[k]; }, addEventListener(t, f) { this.handlers[t] = f; } }));
  return { els, btns, doc: { getElementById: (id) => els[id] || null, querySelectorAll: () => btns } };
}
const tick = () => new Promise((r) => setImmediate(r));

test("test_wb_1_boot_with_the_flag_off_shows_not_open_and_wires_nothing", async () => {
  const p = page(["fp-closed", "fp-open", "fp-status"], [{ "data-buy-tier": "team", "data-buy-interval": "month" }]);
  const calls = [];
  FP.boot({ FOSTERPAY_CONFIG: OFF, fetch: async (...a) => { calls.push(a); } }, p.doc);
  assert.equal(p.els["fp-closed"].hidden, false);
  assert.equal(p.els["fp-open"].hidden, true);
  assert.deepEqual(p.btns[0].handlers, {}, "no click handler while off");
  assert.equal(calls.length, 0);
});

test("test_wb_7_boot_success_page_one_read_one_more_only_on_check_again_and_scrubs_the_address", async () => {
  const p = page(["fp-closed", "fp-open", "fp-key-box", "fp-key", "fp-note", "fp-again"]);
  const urls = [], replaced = [];
  const answers = [{ status: "processing" }, { status: "key", key: "KEY-1" }];
  const win = { FOSTERPAY_CONFIG: ON, location: { search: "?s=cs_test_zz9", pathname: "/checkout/success/" }, history: { replaceState: (...a) => replaced.push(a) }, fetch: async (u) => { urls.push(u); return resp(200, answers.shift()); } };
  FP.boot(win, p.doc);
  await tick(); await tick(); await tick();
  assert.equal(urls.length, 1, "one call per page load");
  assert.equal(replaced.length, 1);
  assert.equal(p.els["fp-again"].hidden, false);
  await p.els["fp-again"].handlers.click(); await tick(); await tick(); await tick();
  assert.equal(urls.length, 2, "one more call at most, only on the button");
  assert.equal(p.els["fp-key"].textContent, "KEY-1");
  assert.equal(p.els["fp-again"].hidden, true);
  p.els["fp-again"].handlers.click(); await tick();
  assert.equal(urls.length, 2, "never a third call");
});

test("test_wb_2_boot_buy_click_calls_once_and_failure_shows_fixed_text", async () => {
  const p = page(["fp-closed", "fp-open", "fp-status"], [{ "data-buy-tier": "team", "data-buy-interval": "year" }]);
  const seen = [];
  const win = { FOSTERPAY_CONFIG: ON, crypto: { getRandomValues: (a) => { for (let i = 0; i < a.length; i++) a[i] = i; return a; } }, fetch: async (u, i) => { seen.push(i.headers["Idempotency-Key"]); return resp(502, { error: "unavailable" }); } };
  FP.boot(win, p.doc);
  await p.btns[0].handlers.click();
  assert.equal(p.els["fp-status"].textContent, FP.TEXT.checkoutFailed);
  assert.equal(p.btns[0].disabled, false, "works again afterwards");
  await p.btns[0].handlers.click();
  assert.equal(seen[0], seen[1], "a retry of the same choice reuses the attempt id");
});

test("test_wb_10_boot_resend_clears_the_field_after_a_send", async () => {
  const p = page(["fp-closed", "fp-open", "fp-email", "fp-send", "fp-result"]);
  p.els["fp-email"].value = "buyer@example.com";
  FP.boot({ FOSTERPAY_CONFIG: ON, fetch: async () => resp(202, { status: "ok" }) }, p.doc);
  await p.els["fp-send"].handlers.click();
  assert.equal(p.els["fp-result"].textContent, FP.TEXT.resendSent);
  assert.equal(p.els["fp-email"].value, "");
});
