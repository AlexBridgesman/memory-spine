# Website source

This directory is the canonical source for `memory.bridges.community`.

- `index.html` — landing page with EN/UA client-side copy.
- `technical.html` — technical reference (`/technical`).
- `agents.md` and `llms.txt` — machine-readable reference.
- `assets/` — static images; the lower-page graph is an optimized lazy-loaded JPEG rather than embedded base64.
- `vercel.json` — clean URLs, legacy `/whitepaper` redirect, and security headers.

## Local preview

```bash
python3 -m http.server 8080 --directory website
```

Then open `http://127.0.0.1:8080/`. This plain server does not emulate Vercel clean URLs or redirects; use `/technical.html` in local preview.

Deployment is intentionally separate from source changes. Verify `tests/test-website.py` before approving a deployment.
