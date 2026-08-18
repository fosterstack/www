// Cloudflare Pages Function: POST /api/waitlist
// Stores signups in the WAITLIST KV namespace (binding must be configured in the
// Pages project settings). No third-party service touches the addresses.

const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/;

export async function onRequestPost({ request, env }) {
  let body;
  try {
    body = await request.json();
  } catch {
    return json({ ok: false, error: 'Invalid request.' }, 400);
  }

  // Honeypot: real users never fill the hidden "website" field.
  if (body.website) {
    return json({ ok: true }); // pretend success to bots
  }

  const email = String(body.email || '').trim().toLowerCase();
  if (!EMAIL_RE.test(email) || email.length > 254) {
    return json({ ok: false, error: 'Please enter a valid email address.' }, 400);
  }

  if (!env.WAITLIST) {
    return json({ ok: false, error: 'Waitlist storage not configured.' }, 500);
  }

  const key = `email:${email}`;
  const existing = await env.WAITLIST.get(key);
  if (!existing) {
    await env.WAITLIST.put(
      key,
      JSON.stringify({
        email,
        ts: new Date().toISOString(),
        country: request.headers.get('cf-ipcountry') || null,
      })
    );
  }
  // Idempotent: re-signup is a success, not an error (and leaks nothing).
  return json({ ok: true });
}

function json(obj, status = 200) {
  return new Response(JSON.stringify(obj), {
    status,
    headers: { 'Content-Type': 'application/json' },
  });
}
