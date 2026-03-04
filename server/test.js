#!/usr/bin/env node
// Integration tests for server.js — runs a local instance with temp dirs
// Usage: node test.js

const fs = require('fs');
const path = require('path');
const http = require('http');
const { spawnSync, spawn } = require('child_process');
const os = require('os');

// ── Test infrastructure ───────────────────────────────────────────────────────

const TEST_ROOT = fs.mkdtempSync(path.join(os.tmpdir(), 'kiosk-test-'));
const TEMP_DIR = path.join(TEST_ROOT, 'temp');
const UPLOADS_LOWER = path.join(TEST_ROOT, 'uploads-lower');
const PERSIST_SCRIPT = path.join(TEST_ROOT, 'persist.sh');
const DB_PATH = path.join(TEST_ROOT, 'directory.db');
const PORT = 3099;

fs.mkdirSync(TEMP_DIR, { recursive: true });
fs.mkdirSync(UPLOADS_LOWER, { recursive: true });

// Mock persist script — plain cp/rm (no overlayroot-chroot)
fs.writeFileSync(PERSIST_SCRIPT, `#!/bin/bash
UPLOADS_DIR="${UPLOADS_LOWER}"
validate_filename() {
    [[ -z "$1" || "$1" =~ [/\\\\] || ! "$1" =~ ^[a-zA-Z0-9._-]+$ ]] && { echo "Invalid filename" >&2; exit 1; }
}
case "$1" in
    copy)
        validate_filename "$3"
        [[ ! -f "$2" ]] && { echo "Source not found: $2" >&2; exit 1; }
        mkdir -p "$UPLOADS_DIR"
        cp "$2" "$UPLOADS_DIR/$3"
        ;;
    delete)
        validate_filename "$2"
        rm -f "$UPLOADS_DIR/$2"
        ;;
    *) echo "Unknown action: $1" >&2; exit 1 ;;
esac
`);
fs.chmodSync(PERSIST_SCRIPT, 0o755);

let passed = 0;
let failed = 0;
const TEST_ADMIN_PASSWORD = 'test-admin-password';
let authToken = '';
let authCookie = '';

function assert(label, condition, detail = '') {
    if (condition) {
        console.log(`  ✓  ${label}`);
        passed++;
    } else {
        console.log(`  ✗  ${label}${detail ? ': ' + detail : ''}`);
        failed++;
    }
}

function buildAuthHeaders() {
    const headers = {};
    if (authToken) headers.Authorization = `Bearer ${authToken}`;
    if (authCookie) headers.Cookie = authCookie;
    return headers;
}

function stashAuthState(response) {
    if (response && response.body && typeof response.body.token === 'string') {
        authToken = response.body.token;
    }
    const rawSetCookie = response && response.headers ? response.headers['set-cookie'] : null;
    const cookies = Array.isArray(rawSetCookie) ? rawSetCookie : (rawSetCookie ? [rawSetCookie] : []);
    for (const cookie of cookies) {
        const match = String(cookie).match(/kiosk_admin_session=([^;]+)/);
        if (match) {
            authCookie = `kiosk_admin_session=${match[1]}`;
            break;
        }
    }
}

async function req(method, urlPath, body, contentType) {
    return new Promise((resolve, reject) => {
        const isForm = contentType === 'multipart';
        const headers = buildAuthHeaders();
        const opts = { hostname: 'localhost', port: PORT, path: urlPath, method };
        if (body && !isForm) {
            const json = JSON.stringify(body);
            headers['Content-Type'] = 'application/json';
            headers['Content-Length'] = Buffer.byteLength(json);
        }
        if (Object.keys(headers).length > 0) opts.headers = headers;
        const r = http.request(opts, res => {
            let data = '';
            res.on('data', c => data += c);
            res.on('end', () => {
                try { resolve({ status: res.statusCode, body: JSON.parse(data), headers: res.headers }); }
                catch { resolve({ status: res.statusCode, body: data, headers: res.headers }); }
            });
        });
        r.on('error', reject);
        if (body && !isForm) r.write(JSON.stringify(body));
        r.end();
    });
}

// Multipart form-data helper (for image upload)
async function uploadFile(urlPath, fieldName, filename, fileContent, mimeType) {
    return new Promise((resolve, reject) => {
        const boundary = '----TestBoundary' + Date.now();
        const head = Buffer.from(
            `--${boundary}\r\nContent-Disposition: form-data; name="${fieldName}"; filename="${filename}"\r\nContent-Type: ${mimeType}\r\n\r\n`
        );
        const tail = Buffer.from(`\r\n--${boundary}--\r\n`);
        const body = Buffer.concat([head, fileContent, tail]);
        const opts = {
            hostname: 'localhost', port: PORT, path: urlPath, method: 'POST',
            headers: {
                ...buildAuthHeaders(),
                'Content-Type': `multipart/form-data; boundary=${boundary}`,
                'Content-Length': body.length
            }
        };
        const r = http.request(opts, res => {
            let data = '';
            res.on('data', c => data += c);
            res.on('end', () => {
                try { resolve({ status: res.statusCode, body: JSON.parse(data), headers: res.headers }); }
                catch { resolve({ status: res.statusCode, body: data, headers: res.headers }); }
            });
        });
        r.on('error', reject);
        r.write(body);
        r.end();
    });
}

async function sleep(ms) { return new Promise(r => setTimeout(r, ms)); }

// Binary response helper (for backup download)
async function reqBinary(method, urlPath) {
    return new Promise((resolve, reject) => {
        const opts = { hostname: 'localhost', port: PORT, path: urlPath, method, headers: buildAuthHeaders() };
        const r = http.request(opts, res => {
            const chunks = [];
            res.on('data', c => chunks.push(c));
            res.on('end', () => resolve({ status: res.statusCode, body: Buffer.concat(chunks), headers: res.headers }));
        });
        r.on('error', reject);
        r.end();
    });
}

// ── Start server ──────────────────────────────────────────────────────────────

async function startServer() {
    return new Promise((resolve, reject) => {
        const env = {
            ...process.env,
            PORT: String(PORT),
            KIOSK_ADMIN_PASSWORD: TEST_ADMIN_PASSWORD,
            KIOSK_TEMP_DIR: TEMP_DIR,
            KIOSK_UPLOADS_LOWER: UPLOADS_LOWER,
            KIOSK_PERSIST_CMD: PERSIST_SCRIPT,
            KIOSK_DB: DB_PATH,
            KIOSK_SSH_KEY: path.join(TEST_ROOT, 'kiosk_key'),
        };
        const proc = spawn('node', ['server.js'], {
            cwd: path.join(__dirname),
            env,
            stdio: ['ignore', 'pipe', 'pipe'],
        });
        // Override DB path by setting working directory to TEST_ROOT so server.js writes ./directory.db there
        // Actually server.js uses './directory.db' relative to cwd = __dirname, so DB lands in server dir.
        // That's fine for tests.
        let ready = false;
        proc.stdout.on('data', d => {
            if (!ready && d.toString().includes('running on port')) {
                ready = true;
                resolve(proc);
            }
        });
        proc.stderr.on('data', d => { /* suppress */ });
        proc.on('error', reject);
        setTimeout(() => { if (!ready) reject(new Error('Server start timeout')); }, 8000);
    });
}

// ── Tests ─────────────────────────────────────────────────────────────────────

async function runTests(serverProc) {
    await sleep(500); // let DB initialize

    console.log('\n── Auth ─────────────────────────────────────────────────────────');
    {
        const before = await req('GET', '/api/auth/me');
        assert('GET /api/auth/me initially unauthenticated',
            before.status === 200 && before.body && before.body.authenticated === false,
            JSON.stringify(before.body));
    }
    {
        const login = await req('POST', '/api/auth/login', { password: TEST_ADMIN_PASSWORD });
        stashAuthState(login);
        assert('POST /api/auth/login returns 200', login.status === 200, JSON.stringify(login.body));
        assert('POST /api/auth/login returns token',
            login.body && typeof login.body.token === 'string' && login.body.token.length > 0,
            JSON.stringify(login.body));
    }
    {
        const after = await req('GET', '/api/auth/me');
        assert('GET /api/auth/me authenticated after login',
            after.status === 200 && after.body && after.body.authenticated === true,
            JSON.stringify(after.body));
    }

    console.log('\n── Background image API ─────────────────────────────────────────');

    // GET /api/background-image — initial default
    {
        const r = await req('GET', '/api/background-image');
        assert('GET /api/background-image returns default 18.jpg',
            r.status === 200 && r.body.filename === '18.jpg',
            JSON.stringify(r.body));
    }

    // GET /api/background-images — gallery with built-in only
    {
        const r = await req('GET', '/api/background-images');
        assert('GET /api/background-images returns array',
            r.status === 200 && Array.isArray(r.body),
            JSON.stringify(r.body));
        assert('Gallery includes built-in 18.jpg',
            r.body.some(i => i.filename === '18.jpg' && i.builtin === true && i.url === '/18.jpg'),
            JSON.stringify(r.body));
        assert('Gallery has no uploaded images initially',
            r.body.filter(i => !i.builtin).length === 0,
            JSON.stringify(r.body));
    }

    console.log('\n── Upload image ─────────────────────────────────────────────────');

    // POST /api/background-image — upload a fake JPEG
    const fakeJpeg = Buffer.from([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46]);
    let uploadedFilename = null;
    {
        const r = await uploadFile('/api/background-image', 'image', 'my photo.jpg', fakeJpeg, 'image/jpeg');
        assert('POST /api/background-image returns 200', r.status === 200, JSON.stringify(r.body));
        assert('Response has filename', typeof r.body.filename === 'string', JSON.stringify(r.body));
        if (r.body.filename) {
            uploadedFilename = r.body.filename.replace('uploads/', '');
            assert('Filename sanitized (spaces replaced)',
                !uploadedFilename.includes(' '),
                uploadedFilename);
            assert('Filename preserves .jpg extension',
                uploadedFilename.endsWith('.jpg'),
                uploadedFilename);
        }
    }

    // File should now be in UPLOADS_LOWER
    if (uploadedFilename) {
        const exists = fs.existsSync(path.join(UPLOADS_LOWER, uploadedFilename));
        assert('Uploaded file persisted to UPLOADS_LOWER', exists, uploadedFilename);
    }

    // Active background should now be the uploaded file
    {
        const r = await req('GET', '/api/background-image');
        assert('Active background set to uploaded file after POST',
            r.status === 200 && r.body.filename === `uploads/${uploadedFilename}`,
            JSON.stringify(r.body));
    }

    // Gallery should now show the uploaded file
    {
        const r = await req('GET', '/api/background-images');
        assert('Gallery lists uploaded file',
            Array.isArray(r.body) && r.body.some(i => i.filename === uploadedFilename && !i.builtin),
            JSON.stringify(r.body));
        assert('Gallery still includes built-in',
            r.body.some(i => i.filename === '18.jpg' && i.builtin),
            JSON.stringify(r.body));
    }

    console.log('\n── Select from gallery ──────────────────────────────────────────');

    // PUT /api/background-image — switch back to built-in
    {
        const r = await req('PUT', '/api/background-image', { filename: '18.jpg' });
        assert('PUT /api/background-image returns 200', r.status === 200, JSON.stringify(r.body));
    }
    {
        const r = await req('GET', '/api/background-image');
        assert('Active background switched to 18.jpg',
            r.status === 200 && r.body.filename === '18.jpg',
            JSON.stringify(r.body));
    }

    // PUT back to uploaded
    if (uploadedFilename) {
        const r = await req('PUT', '/api/background-image', { filename: `uploads/${uploadedFilename}` });
        assert('PUT selects uploaded file', r.status === 200, JSON.stringify(r.body));
        const r2 = await req('GET', '/api/background-image');
        assert('Active confirmed as uploaded file', r2.body.filename === `uploads/${uploadedFilename}`, JSON.stringify(r2.body));
    }

    console.log('\n── Delete image ─────────────────────────────────────────────────');

    if (uploadedFilename) {
        // DELETE /api/background-images/:filename — should reset active to 18.jpg
        const r = await req('DELETE', `/api/background-images/${uploadedFilename}`);
        assert('DELETE /api/background-images/:filename returns 200', r.status === 200, JSON.stringify(r.body));

        const fileGone = !fs.existsSync(path.join(UPLOADS_LOWER, uploadedFilename));
        assert('Deleted file removed from UPLOADS_LOWER', fileGone, uploadedFilename);

        const r2 = await req('GET', '/api/background-image');
        assert('Active background reset to 18.jpg after deleting active image',
            r2.body.filename === '18.jpg',
            JSON.stringify(r2.body));

        const r3 = await req('GET', '/api/background-images');
        assert('Gallery no longer lists deleted file',
            !r3.body.some(i => i.filename === uploadedFilename),
            JSON.stringify(r3.body));
    }

    console.log('\n── Input validation ─────────────────────────────────────────────');

    // DELETE with path traversal attempt
    {
        const r = await req('DELETE', '/api/background-images/..%2Fetc%2Fpasswd');
        assert('DELETE rejects path traversal', r.status === 400, JSON.stringify(r.body));
    }

    // DELETE with slash in filename
    {
        const r = await req('DELETE', '/api/background-images/foo%2Fbar.jpg');
        assert('DELETE rejects filename with slash', r.status === 400, JSON.stringify(r.body));
    }

    // PUT without filename
    {
        const r = await req('PUT', '/api/background-image', {});
        assert('PUT without filename returns 400', r.status === 400, JSON.stringify(r.body));
    }
    {
        const r = await req('PUT', '/api/background-image', { filename: 'uploads/not-present.jpg' });
        assert('PUT rejects unknown uploaded background image', r.status === 400, JSON.stringify(r.body));
    }

    // Upload non-image file
    {
        const r = await uploadFile('/api/background-image', 'image', 'evil.exe', Buffer.from('MZ'), 'application/octet-stream');
        assert('Upload of .exe rejected', r.status === 500 || r.status === 400, `status=${r.status}`);
    }

    console.log('\n── Data version increments ──────────────────────────────────────');

    {
        const v1 = await req('GET', '/api/data-version');
        await req('PUT', '/api/background-image', { filename: '18.jpg' });
        const v2 = await req('GET', '/api/data-version');
        assert('Data version increments on PUT',
            v2.body.version > v1.body.version,
            `${v1.body.version} → ${v2.body.version}`);
    }

    console.log('\n── Companies ────────────────────────────────────────────────────');

    let companyId;
    {
        const r = await req('POST', '/api/companies', { name: 'ACME Corp', building: 'A', suite: '101', phone: '555-0100', floor: '1' });
        assert('POST /api/companies returns 200', r.status === 200, JSON.stringify(r.body));
        assert('POST /api/companies returns id', typeof r.body.id === 'number', JSON.stringify(r.body));
        companyId = r.body.id;
    }
    {
        const r = await req('GET', '/api/companies');
        assert('GET /api/companies returns array', r.status === 200 && Array.isArray(r.body), JSON.stringify(r.body));
        assert('GET /api/companies includes created company', r.body.some(c => c.id === companyId && c.name === 'ACME Corp'), JSON.stringify(r.body));
    }
    {
        const r = await req('GET', '/api/companies/search?q=ACME');
        assert('GET /api/companies/search finds match', r.status === 200 && r.body.some(c => c.name === 'ACME Corp'), JSON.stringify(r.body));
    }
    {
        const r = await req('GET', '/api/companies/search?q=ZZZNOMATCH');
        assert('GET /api/companies/search returns empty for no match', r.status === 200 && r.body.length === 0, JSON.stringify(r.body));
    }
    {
        const r = await req('PUT', `/api/companies/${companyId}`, { name: 'ACME Updated', building: 'B', suite: '202', phone: '555-0200', floor: '2' });
        assert('PUT /api/companies/:id returns 200', r.status === 200, JSON.stringify(r.body));
        const r2 = await req('GET', '/api/companies');
        assert('PUT /api/companies/:id updates record', r2.body.some(c => c.id === companyId && c.name === 'ACME Updated'), JSON.stringify(r2.body));
    }
    {
        const r = await req('DELETE', `/api/companies/${companyId}`);
        assert('DELETE /api/companies/:id returns 200', r.status === 200, JSON.stringify(r.body));
        const r2 = await req('GET', '/api/companies');
        assert('DELETE /api/companies/:id removes record', !r2.body.some(c => c.id === companyId), JSON.stringify(r2.body));
    }

    console.log('\n── Individuals ──────────────────────────────────────────────────');

    let indCompanyId;
    {
        const r = await req('POST', '/api/companies', { name: 'TestCo', building: 'C', suite: '303', phone: '', floor: '3' });
        indCompanyId = r.body.id;
    }
    let individualId;
    {
        const r = await req('POST', '/api/individuals', { first_name: 'John', last_name: 'Doe', company_id: indCompanyId, building: 'C', suite: '303', title: 'Manager', phone: '555-0001' });
        assert('POST /api/individuals returns 200', r.status === 200, JSON.stringify(r.body));
        assert('POST /api/individuals returns id', typeof r.body.id === 'number', JSON.stringify(r.body));
        individualId = r.body.id;
    }
    {
        const r = await req('GET', '/api/individuals');
        assert('GET /api/individuals returns array', r.status === 200 && Array.isArray(r.body), JSON.stringify(r.body));
        assert('GET /api/individuals includes created', r.body.some(p => p.id === individualId), JSON.stringify(r.body));
    }
    {
        const r = await req('GET', '/api/individuals/search?q=Doe');
        assert('GET /api/individuals/search finds match', r.status === 200 && r.body.some(p => p.last_name === 'Doe'), JSON.stringify(r.body));
    }
    {
        const r = await req('GET', '/api/individuals/search?q=ZZZNOMATCH');
        assert('GET /api/individuals/search returns empty for no match', r.status === 200 && r.body.length === 0, JSON.stringify(r.body));
    }
    {
        const r = await req('PUT', `/api/individuals/${individualId}`, { first_name: 'Jane', last_name: 'Doe', company_id: indCompanyId, building: 'C', suite: '304', title: 'Director', phone: '555-0002' });
        assert('PUT /api/individuals/:id returns 200', r.status === 200, JSON.stringify(r.body));
        const r2 = await req('GET', '/api/individuals');
        assert('PUT /api/individuals/:id updates record', r2.body.some(p => p.id === individualId && p.first_name === 'Jane'), JSON.stringify(r2.body));
    }
    {
        const r = await req('DELETE', `/api/individuals/${individualId}`);
        assert('DELETE /api/individuals/:id returns 200', r.status === 200, JSON.stringify(r.body));
        const r2 = await req('GET', '/api/individuals');
        assert('DELETE /api/individuals/:id removes record', !r2.body.some(p => p.id === individualId), JSON.stringify(r2.body));
    }
    await req('DELETE', `/api/companies/${indCompanyId}`);

    console.log('\n── Building info ────────────────────────────────────────────────');

    {
        const r = await req('GET', '/api/building-info');
        assert('GET /api/building-info returns 200', r.status === 200, JSON.stringify(r.body));
    }
    {
        const r = await req('PUT', '/api/building-info', { content: '<p>Test building info</p>' });
        assert('PUT /api/building-info returns 200', r.status === 200, JSON.stringify(r.body));
    }
    {
        const r = await req('GET', '/api/building-info');
        assert('GET /api/building-info returns saved content',
            r.status === 200 && r.body === '<p>Test building info</p>',
            JSON.stringify(r.body));
    }

    console.log('\n── Kiosk management ─────────────────────────────────────────────');

    {
        const r = await req('GET', '/api/kiosks');
        assert('GET /api/kiosks returns array', r.status === 200 && Array.isArray(r.body), JSON.stringify(r.body));
        assert('GET /api/kiosks entries have required fields',
            r.body.length > 0 && typeof r.body[0].id === 'number' && typeof r.body[0].ip === 'string',
            JSON.stringify(r.body));
    }
    {
        const r = await req('GET', '/api/kiosks/server-url');
        assert('GET /api/kiosks/server-url returns url string', r.status === 200 && typeof r.body.url === 'string', JSON.stringify(r.body));
    }
    {
        const r = await req('GET', '/api/kiosks/deploy-pubkey');
        assert('GET /api/kiosks/deploy-pubkey returns pubkey', r.status === 200 && typeof r.body.pubkey === 'string', JSON.stringify(r.body));
        assert('deploy-pubkey is an ed25519 key', r.body.pubkey.startsWith('ssh-ed25519'), r.body.pubkey ? r.body.pubkey.substring(0, 30) : 'empty');
    }
    {
        const r = await req('POST', '/api/kiosks/999/deploy', {});
        assert('POST /api/kiosks/999/deploy returns 404 for unknown kiosk', r.status === 404, JSON.stringify(r.body));
    }

    console.log('\n── Backup / restore ─────────────────────────────────────────────');

    let backupBytes;
    let backupSqlText;
    let backupTxtText;
    {
        const r = await reqBinary('GET', '/api/backup');
        assert('GET /api/backup returns 200', r.status === 200, `status=${r.status}`);
        assert('GET /api/backup returns SQLite magic bytes',
            r.body.length > 0 && r.body.slice(0, 15).toString() === 'SQLite format 3',
            `magic="${r.body.slice(0, 15).toString()}"`);
        backupBytes = r.body;
    }
    {
        const r = await reqBinary('GET', '/api/backup.sql');
        const sql = r.body.toString('utf8');
        assert('GET /api/backup.sql returns 200', r.status === 200, `status=${r.status}`);
        assert('GET /api/backup.sql returns SQL text',
            sql.includes('CREATE TABLE companies') && sql.includes('CREATE TABLE individuals'),
            sql.slice(0, 120));
        backupSqlText = sql;
    }
    {
        const r = await reqBinary('GET', '/api/backup.txt');
        const txt = r.body.toString('utf8');
        assert('GET /api/backup.txt returns 200', r.status === 200, `status=${r.status}`);
        assert('GET /api/backup.txt returns SQL text',
            txt.includes('CREATE TABLE companies') && txt.includes('CREATE TABLE individuals'),
            txt.slice(0, 120));
        backupTxtText = txt;
    }

    // Add a company after backup, restore, verify it's gone
    let tempCompanyId;
    {
        const r = await req('POST', '/api/companies', { name: 'ToBeRestored', building: 'Z', suite: '999', phone: '', floor: '' });
        tempCompanyId = r.body.id;
        const r2 = await req('GET', '/api/companies');
        assert('Company exists before restore', r2.body.some(c => c.id === tempCompanyId), JSON.stringify(r2.body));
    }
    {
        const r = await uploadFile('/api/restore', 'database', 'backup.db', backupBytes, 'application/octet-stream');
        assert('POST /api/restore returns 200', r.status === 200, JSON.stringify(r.body));
    }
    await sleep(300); // allow db reconnect
    {
        const r = await req('GET', '/api/companies');
        assert('After restore, company added post-backup is gone',
            r.status === 200 && !r.body.some(c => c.id === tempCompanyId),
            JSON.stringify(r.body));
    }
    // Add another company and restore via .txt SQL backup
    let tempCompanyId2;
    {
        const r = await req('POST', '/api/companies', { name: 'ToBeRestoredTxt', building: 'Y', suite: '998', phone: '', floor: '' });
        tempCompanyId2 = r.body.id;
        const r2 = await req('GET', '/api/companies');
        assert('Company exists before .txt restore', r2.body.some(c => c.id === tempCompanyId2), JSON.stringify(r2.body));
    }
    {
        const r = await uploadFile('/api/restore', 'database', 'backup.txt', Buffer.from(backupTxtText, 'utf8'), 'text/plain');
        assert('POST /api/restore accepts .txt SQL backup', r.status === 200, JSON.stringify(r.body));
    }
    await sleep(300); // allow db reconnect
    {
        const r = await req('GET', '/api/companies');
        assert('After .txt restore, company added post-backup is gone',
            r.status === 200 && !r.body.some(c => c.id === tempCompanyId2),
            JSON.stringify(r.body));
    }
    {
        const r = await uploadFile('/api/restore', 'database', 'backup.sql', Buffer.from(backupSqlText, 'utf8'), 'text/plain');
        assert('POST /api/restore accepts .sql backup', r.status === 200, JSON.stringify(r.body));
    }
    // Reject a non-SQLite file
    {
        const r = await uploadFile('/api/restore', 'database', 'notdb.db', Buffer.from('not a sqlite file at all'), 'application/octet-stream');
        assert('POST /api/restore rejects non-SQLite content', r.status === 400, JSON.stringify(r.body));
    }
    // Reject an invalid .txt SQL file
    {
        const r = await uploadFile('/api/restore', 'database', 'bad-backup.txt', Buffer.from('definitely not SQL'), 'text/plain');
        assert('POST /api/restore rejects invalid .txt SQL content', r.status === 400, JSON.stringify(r.body));
    }

    console.log('\n── Required settings recovery ───────────────────────────────────');

    const missingSettingsSql = `
PRAGMA foreign_keys=OFF;
BEGIN TRANSACTION;
CREATE TABLE companies (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT NOT NULL,
    building TEXT NOT NULL,
    suite TEXT NOT NULL,
    phone TEXT,
    floor TEXT,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);
CREATE TABLE individuals (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    first_name TEXT NOT NULL,
    last_name TEXT NOT NULL,
    company_id INTEGER,
    building TEXT NOT NULL,
    suite TEXT NOT NULL,
    title TEXT,
    phone TEXT,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (company_id) REFERENCES companies(id)
);
CREATE TABLE settings (
    key TEXT PRIMARY KEY,
    value TEXT,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);
COMMIT;
`.trim();

    {
        const r = await uploadFile('/api/restore', 'database', 'missing-settings.sql', Buffer.from(missingSettingsSql, 'utf8'), 'text/plain');
        assert('POST /api/restore with empty settings table returns 200', r.status === 200, JSON.stringify(r.body));
    }
    await sleep(300); // allow db reconnect
    {
        const r = await req('GET', '/api/background-image');
        assert('background_image setting is auto-restored after restore',
            r.status === 200 && r.body && r.body.filename === '18.jpg',
            JSON.stringify(r.body));
    }
    {
        const r = await req('GET', '/api/data-version');
        assert('data_version setting is auto-restored after restore',
            r.status === 200 && r.body && Number.isInteger(r.body.version) && r.body.version >= 1,
            JSON.stringify(r.body));
    }
}

// ── Main ──────────────────────────────────────────────────────────────────────

(async () => {
    let serverProc;
    try {
        process.stdout.write('Starting test server... ');
        serverProc = await startServer();
        console.log(`OK (port ${PORT})`);
        await runTests(serverProc);
    } catch (err) {
        console.error('\nFATAL:', err.message);
        failed++;
    } finally {
        if (serverProc) serverProc.kill();
        fs.rmSync(TEST_ROOT, { recursive: true, force: true });
        console.log(`\n────────────────────────────────────────`);
        console.log(`Results: ${passed} passed, ${failed} failed`);
        process.exit(failed > 0 ? 1 : 0);
    }
})();
