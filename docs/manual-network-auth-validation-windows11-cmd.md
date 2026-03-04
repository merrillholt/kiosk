# Manual Network/Auth Validation (Windows 11 CMD)

Run these commands in Command Prompt (`cmd.exe`), not PowerShell.

## 0) Set server variable

```bat
set SERVER=http://192.168.1.80
```

## 1) From an allowlisted machine (example: 192.168.1.131)

### A. Kiosk location endpoint

```bat
curl -sS %SERVER%/api/kiosk-location
```

Expected:
- HTTP `200`
- JSON includes your real client IP (example: `"ip":"192.168.1.131"`)

### B. Read API should be allowed

```bat
curl -sS -o %TEMP%\companies.json -w "HTTP_STATUS:%%{http_code}\n" %SERVER%/api/companies
type %TEMP%\companies.json
```

Expected:
- Status line shows `HTTP_STATUS:200`
- File contains a JSON array

### C. Write API without login should be blocked

```bat
curl -sS -o %TEMP%\post-unauth.json -w "HTTP_STATUS:%%{http_code}\n" ^
  -X POST %SERVER%/api/companies ^
  -H "Content-Type: application/json" ^
  --data "{\"name\":\"Smoke Co\",\"building\":\"A\",\"suite\":\"100\"}"
type %TEMP%\post-unauth.json
```

Expected:
- Status line shows `HTTP_STATUS:401`
- Body: `{"error":"Unauthorized"}`

## 2) From a non-allowlisted machine (not in `KIOSK_ALLOWED_IPS`)

### A. Kiosk-read endpoint should be blocked

```bat
curl -sS -o %TEMP%\companies-forbidden.json -w "HTTP_STATUS:%%{http_code}\n" %SERVER%/api/companies
type %TEMP%\companies-forbidden.json
```

Expected:
- Status line shows `HTTP_STATUS:403`
- Body: `{"error":"Forbidden"}`

### B. Data version endpoint should also be blocked

```bat
curl -sS -o %TEMP%\version-forbidden.json -w "HTTP_STATUS:%%{http_code}\n" %SERVER%/api/data-version
type %TEMP%\version-forbidden.json
```

Expected:
- Status line shows `HTTP_STATUS:403`
- Body: `{"error":"Forbidden"}`

## 3) Optional admin login check (any machine with admin access)

Set password:

```bat
set ADMIN_PASSWORD=replace-with-real-password
```

Login:

```bat
curl -i -sS ^
  -X POST %SERVER%/api/auth/login ^
  -H "Content-Type: application/json" ^
  --data "{\"password\":\"%ADMIN_PASSWORD%\"}"
```

Expected:
- HTTP `200`
- Body contains `"success":true` and a `"token"`
- Headers include `Set-Cookie: kiosk_admin_session=...`

## Pass Criteria

- Allowlisted machine:
  - `GET /api/companies` => `200`
  - unauthenticated write => `401`
- Non-allowlisted machine:
  - `GET /api/companies` and `GET /api/data-version` => `403`
- `/api/kiosk-location` reports the real client IP for each test machine.
