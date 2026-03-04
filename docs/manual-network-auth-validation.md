# Manual Network/Auth Validation (192.168.1.80)

Use this checklist from a second computer to validate IP allowlist and API auth behavior.

## Variables

```bash
SERVER="http://192.168.1.80"
```

## 1) From an allowlisted machine (example: 192.168.1.131)

### A. Kiosk location endpoint

```bash
curl -sS "$SERVER/api/kiosk-location"
```

Expected:
- HTTP `200`
- JSON contains your real client IP (example: `"ip":"192.168.1.131"`)

### B. Read API should be allowed

```bash
curl -sS -o /tmp/companies.json -w "%{http_code}\n" "$SERVER/api/companies"
```

Expected:
- Status code: `200`
- `/tmp/companies.json` contains a JSON array

### C. Write API without login should be blocked

```bash
curl -sS -o /tmp/post-unauth.json -w "%{http_code}\n" \
  -X POST "$SERVER/api/companies" \
  -H "Content-Type: application/json" \
  --data '{"name":"Smoke Co","building":"A","suite":"100"}'
cat /tmp/post-unauth.json
```

Expected:
- Status code: `401`
- Body: `{"error":"Unauthorized"}`

## 2) From a non-allowlisted machine (not in KIOSK_ALLOWED_IPS)

### A. Kiosk-read endpoint should be blocked

```bash
curl -sS -o /tmp/companies-forbidden.json -w "%{http_code}\n" "$SERVER/api/companies"
cat /tmp/companies-forbidden.json
```

Expected:
- Status code: `403`
- Body: `{"error":"Forbidden"}`

### B. Data version endpoint should also be blocked

```bash
curl -sS -o /tmp/version-forbidden.json -w "%{http_code}\n" "$SERVER/api/data-version"
cat /tmp/version-forbidden.json
```

Expected:
- Status code: `403`
- Body: `{"error":"Forbidden"}`

## 3) Optional admin login check (any machine with admin access)

Set password first:

```bash
ADMIN_PASSWORD="replace-with-real-password"
```

Login:

```bash
curl -i -sS \
  -X POST "$SERVER/api/auth/login" \
  -H "Content-Type: application/json" \
  --data "{\"password\":\"$ADMIN_PASSWORD\"}"
```

Expected:
- HTTP `200`
- Response body contains `"success":true` and a `"token"`
- `Set-Cookie` includes `kiosk_admin_session=...`

## Pass Criteria

- Allowlisted machine:
  - `GET /api/companies` returns `200`
  - unauthenticated write returns `401`
- Non-allowlisted machine:
  - `GET /api/companies` and `GET /api/data-version` return `403`
- `/api/kiosk-location` reports the real client IP for each test machine.
