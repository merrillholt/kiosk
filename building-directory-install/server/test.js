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

function assert(label, condition, detail = '') {
    if (condition) {
        console.log(`  ✓  ${label}`);
        passed++;
    } else {
        console.log(`  ✗  ${label}${detail ? ': ' + detail : ''}`);
        failed++;
    }
}

async function req(method, urlPath, body, contentType) {
    return new Promise((resolve, reject) => {
        const isForm = contentType === 'multipart';
        const opts = { hostname: 'localhost', port: PORT, path: urlPath, method };
        if (body && !isForm) {
            const json = JSON.stringify(body);
            opts.headers = { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(json) };
        }
        const r = http.request(opts, res => {
            let data = '';
            res.on('data', c => data += c);
            res.on('end', () => {
                try { resolve({ status: res.statusCode, body: JSON.parse(data) }); }
                catch { resolve({ status: res.statusCode, body: data }); }
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
            headers: { 'Content-Type': `multipart/form-data; boundary=${boundary}`, 'Content-Length': body.length }
        };
        const r = http.request(opts, res => {
            let data = '';
            res.on('data', c => data += c);
            res.on('end', () => {
                try { resolve({ status: res.statusCode, body: JSON.parse(data) }); }
                catch { resolve({ status: res.statusCode, body: data }); }
            });
        });
        r.on('error', reject);
        r.write(body);
        r.end();
    });
}

async function sleep(ms) { return new Promise(r => setTimeout(r, ms)); }

// ── Start server ──────────────────────────────────────────────────────────────

async function startServer() {
    return new Promise((resolve, reject) => {
        const env = {
            ...process.env,
            PORT: String(PORT),
            KIOSK_TEMP_DIR: TEMP_DIR,
            KIOSK_UPLOADS_LOWER: UPLOADS_LOWER,
            KIOSK_PERSIST_CMD: PERSIST_SCRIPT,
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
        // Clean up test DB created in server dir
        const testDb = path.join(__dirname, 'directory.db');
        if (fs.existsSync(testDb)) fs.unlinkSync(testDb);
        console.log(`\n────────────────────────────────────────`);
        console.log(`Results: ${passed} passed, ${failed} failed`);
        process.exit(failed > 0 ? 1 : 0);
    }
})();
