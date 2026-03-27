const express = require('express');
const sqlite3 = require('sqlite3').verbose();
const path = require('path');
const multer = require('multer');
const fs = require('fs');
const os = require('os');
const crypto = require('crypto');
const { spawn, spawnSync } = require('child_process');

const app = express();
const PORT = process.env.PORT || 3000;
const HOST = process.env.HOST || '127.0.0.1';
const PROJECT_ROOT = path.join(__dirname, '..');
const REVISION_FILE = process.env.KIOSK_REVISION_FILE || path.join(PROJECT_ROOT, 'REVISION');
const PACKAGE_JSON_FILE = path.join(__dirname, 'package.json');
// Trust loopback reverse proxy (nginx on same host) for accurate req.ip.
app.set('trust proxy', 'loopback');

// Temp dir for multer uploads (lost on reboot — persist script copies to lower layer)
const TEMP_DIR = process.env.KIOSK_TEMP_DIR || '/tmp/kiosk-uploads';
// Persistent uploads dir. Prefer explicit env override; otherwise use the
// overlayroot lower path when present, and fall back to local server/uploads
// for maintenance mode (overlayroot=disabled).
const OVERLAY_UPLOADS_LOWER = `/media/root-ro/home/${os.userInfo().username}/building-directory/server/uploads`;
const LOCAL_UPLOADS_DIR = path.join(__dirname, 'uploads');
const UPLOADS_LOWER = process.env.KIOSK_UPLOADS_LOWER ||
    (fs.existsSync(OVERLAY_UPLOADS_LOWER) ? OVERLAY_UPLOADS_LOWER : LOCAL_UPLOADS_DIR);
// Persist command: space-separated argv[0..n], e.g. "/tmp/mock-persist.sh" for tests
const PERSIST_ARGV = process.env.KIOSK_PERSIST_CMD
    ? process.env.KIOSK_PERSIST_CMD.split(' ')
    : ['sudo', '/usr/local/bin/persist-upload.sh'];
// Database file path (overridable via KIOSK_DB for testing)
const DB_FILE = process.env.KIOSK_DB || path.join(__dirname, 'directory.db');

// --- Kiosk display client configuration ---
// List the 3 kiosk display machines. Update IPs when machines are provisioned.
const KIOSK_CLIENTS = process.env.KIOSK_CLIENTS
    ? JSON.parse(process.env.KIOSK_CLIENTS)
    : [
        { id: 1, name: 'Kiosk 1', ip: '192.168.1.80',  user: 'kiosk' },
        { id: 2, name: 'Kiosk 2', ip: '192.168.1.81',  user: 'kiosk' },
        { id: 3, name: 'Kiosk 3', ip: '192.168.1.82',  user: 'kiosk' },
    ];
// Kiosk read APIs are restricted to these client IPs (comma-separated list).
const KIOSK_ALLOWED_IPS = new Set(
    (process.env.KIOSK_ALLOWED_IPS || '192.168.1.80,192.168.1.81,192.168.1.82,192.168.1.131')
        .split(',')
        .map(ip => ip.trim())
        .filter(Boolean)
);
const KIOSK_READ_PATHS = new Set([
    '/companies',
    '/individuals',
    '/building-info',
    '/background-image',
    '/data-version',
    '/kiosk-location',
    '/revision'
]);
const ADMIN_PASSWORD = process.env.KIOSK_ADMIN_PASSWORD || 'kiosk';
const SESSION_COOKIE = 'kiosk_admin_session';
const SESSION_TTL_MS = 8 * 60 * 60 * 1000; // 8 hours
const adminSessions = new Map();
const LOGIN_WINDOW_MS = Number.parseInt(process.env.KIOSK_LOGIN_WINDOW_MS || '', 10) || (15 * 60 * 1000);
const LOGIN_MAX_ATTEMPTS = Number.parseInt(process.env.KIOSK_LOGIN_MAX_ATTEMPTS || '', 10) || 10;
const LOGIN_BLOCK_MS = Number.parseInt(process.env.KIOSK_LOGIN_BLOCK_MS || '', 10) || (15 * 60 * 1000);
const loginAttempts = new Map();
// SSH private key used to connect to kiosk machines for deployment
const KIOSK_SSH_KEY = process.env.KIOSK_SSH_KEY ||
    path.join(os.homedir(), '.ssh', 'kiosk_deploy_key');
// Authoritative URLs kiosk machines use to reach the primary and standby servers.
const KIOSK_SERVER_URL = process.env.KIOSK_SERVER_URL || 'http://192.168.1.80';
// Warm-standby URL kiosk machines will switch to if primary is unavailable.
const KIOSK_SERVER_URL_STANDBY = process.env.KIOSK_SERVER_URL_STANDBY || 'http://192.168.1.81';
const KIOSK_DEPLOY_SCRIPT = path.join(PROJECT_ROOT, 'tools', 'deploy-ssh.sh');
const KIOSK_KNOWN_HOSTS_FILE = process.env.KIOSK_KNOWN_HOSTS_FILE || '/tmp/kiosk_deploy_known_hosts';
const STANDBY_DB_FILE = process.env.KIOSK_STANDBY_DB || '/home/kiosk/building-directory/server/directory.db';
const STANDBY_UPLOADS_DIR = process.env.KIOSK_STANDBY_UPLOADS || '/home/kiosk/building-directory/server/uploads';
const KIOSK_STANDBY_SYNC_ENABLED = !['0', 'false', 'no'].includes(String(process.env.KIOSK_STANDBY_SYNC_ENABLED || '1').toLowerCase());
const KIOSK_STANDBY_SYNC_DELAY_MS = Number.parseInt(process.env.KIOSK_STANDBY_SYNC_DELAY_MS || '', 10) || (5 * 60 * 1000);
const KIOSK_STANDBY_SYNC_CHECK_MS = Number.parseInt(process.env.KIOSK_STANDBY_SYNC_CHECK_MS || '', 10) || (15 * 60 * 1000);
const KIOSK_STANDBY_SYNC_TIMEOUT_MS = Number.parseInt(process.env.KIOSK_STANDBY_SYNC_TIMEOUT_MS || '', 10) || (2 * 60 * 1000);
let SERVER_PACKAGE_VERSION = 'unknown';
try {
    const pkg = JSON.parse(fs.readFileSync(PACKAGE_JSON_FILE, 'utf8'));
    if (pkg && typeof pkg.version === 'string' && pkg.version.trim()) {
        SERVER_PACKAGE_VERSION = pkg.version.trim();
    }
} catch (err) {
    console.warn('Could not read server package version:', err.message);
}
let REVISION_SOURCE = 'fallback';
function getGitRevision() {
    try {
        if (!fs.existsSync(path.join(PROJECT_ROOT, '.git'))) return '';
        const git = spawnSync('git', [
            '-C', PROJECT_ROOT,
            'log', '-1',
            '--date=format:%Y.%m.%d',
            '--format=%cd.%h'
        ], { encoding: 'utf8' });
        if (git.status === 0) {
            return (git.stdout || '').trim();
        }
    } catch (err) {
        console.warn('Could not read git revision:', err.message);
    }
    return '';
}
const DEPLOY_REVISION = (() => {
    const envRevision = (process.env.KIOSK_REVISION || '').trim();
    if (envRevision) {
        REVISION_SOURCE = 'env';
        return envRevision;
    }
    const gitRevision = getGitRevision();
    if (gitRevision) {
        REVISION_SOURCE = 'git';
        return gitRevision;
    }
    try {
        const fileRevision = fs.readFileSync(REVISION_FILE, 'utf8').trim();
        if (fileRevision) {
            REVISION_SOURCE = 'file';
            return fileRevision;
        }
    } catch (err) {
        console.warn('Could not read revision file:', err.message);
    }
    return `v${SERVER_PACKAGE_VERSION}`;
})();
const DEFAULT_BUILDING_INFO_HTML = `
<div class="building-info-panel">
    <div class="building-info-column">
        <h2>Managed by:</h2>
        <p>Mike Lam - Property Manager</p>
        <p>Embarcadero Realty Services LP</p>
        <p>925-227-8655</p>
        <p>Owned by Spieker Keech Hacienda, LLC</p>
    </div>
    <div class="building-info-column">
        <h2>Leased by:</h2>
        <div class="leasing-logo-wrap">
            <img class="leasing-logo" src="cushman-wakefield-logo.png" alt="Cushman & Wakefield">
        </div>
        <p>Brian Lagomarsino</p>
        <p>Chad Arnold</p>
        <p>Cushman &amp; Wakefield</p>
        <p>925-621-3858</p>
    </div>
</div>
`.trim();
fs.mkdirSync(TEMP_DIR, { recursive: true });
fs.mkdirSync(UPLOADS_LOWER, { recursive: true });

// Middleware
app.use(express.json());
app.use(express.static(path.join(__dirname, '../kiosk')));
app.use('/uploads', express.static(UPLOADS_LOWER));
app.use('/admin', express.static(path.join(__dirname, 'admin')));
app.use('/api', (req, res, next) => {
    if (req.method !== 'GET' || !KIOSK_READ_PATHS.has(req.path)) return next();
    const clientIp = getClientIp(req);
    if (clientIp === '127.0.0.1' || clientIp === '::1' || KIOSK_ALLOWED_IPS.has(clientIp)) return next();
    return res.status(403).json({ error: 'Forbidden' });
});
app.use('/api', (req, res, next) => {
    // Public auth endpoints.
    if (req.path === '/auth/login' || req.path === '/auth/logout' || req.path === '/auth/me') return next();
    // Kiosk read APIs stay unauthenticated but are IP-restricted by middleware above.
    if (req.method === 'GET' && KIOSK_READ_PATHS.has(req.path)) return next();
    const sessionId = getSessionId(req);
    if (isValidAdminSession(sessionId)) return next();
    return res.status(401).json({ error: 'Unauthorized' });
});

// Basic CSRF guard: for mutating API calls, enforce same-origin when browser sends Origin/Referer.
app.use('/api', (req, res, next) => {
    if (!['POST', 'PUT', 'PATCH', 'DELETE'].includes(req.method)) return next();
    if (req.path === '/auth/login' || req.path === '/auth/logout') return next();

    const host = req.headers.host || '';
    const origin = req.headers.origin;
    const referer = req.headers.referer;

    if (!origin && !referer) return next();

    try {
        if (origin && new URL(origin).host !== host) {
            return res.status(403).json({ error: 'Cross-origin request blocked' });
        }
        if (!origin && referer && new URL(referer).host !== host) {
            return res.status(403).json({ error: 'Cross-origin request blocked' });
        }
    } catch (e) {
        return res.status(403).json({ error: 'Invalid Origin/Referer header' });
    }
    return next();
});

if (ADMIN_PASSWORD === 'kiosk') {
    console.warn('WARNING: Default admin password "kiosk" is active.');
}

function parseCookies(req) {
    const header = req.headers.cookie || '';
    const out = {};
    for (const pair of header.split(';')) {
        const idx = pair.indexOf('=');
        if (idx === -1) continue;
        const k = pair.slice(0, idx).trim();
        const v = pair.slice(idx + 1).trim();
        if (k) out[k] = decodeURIComponent(v);
    }
    return out;
}

function getClientIp(req) {
    const rawIp = req.ip || req.socket.remoteAddress || '';
    return rawIp.startsWith('::ffff:') ? rawIp.slice(7) : rawIp;
}

function getBearerToken(req) {
    const auth = req.headers.authorization || '';
    if (!auth.startsWith('Bearer ')) return '';
    return auth.slice('Bearer '.length).trim();
}

function getSessionId(req) {
    return parseCookies(req)[SESSION_COOKIE] || getBearerToken(req);
}

function timingSafeEqualStr(a, b) {
    const ab = Buffer.from(String(a));
    const bb = Buffer.from(String(b));
    if (ab.length !== bb.length) return false;
    return crypto.timingSafeEqual(ab, bb);
}

function getLoginState(clientIp) {
    const now = Date.now();
    const state = loginAttempts.get(clientIp) || { windowStart: now, count: 0, blockedUntil: 0 };
    if (state.blockedUntil && now < state.blockedUntil) return state;
    if (now - state.windowStart > LOGIN_WINDOW_MS) {
        state.windowStart = now;
        state.count = 0;
    }
    if (state.blockedUntil && now >= state.blockedUntil) state.blockedUntil = 0;
    return state;
}

function canAttemptLogin(clientIp) {
    const now = Date.now();
    const state = getLoginState(clientIp);
    loginAttempts.set(clientIp, state);
    if (state.blockedUntil && now < state.blockedUntil) {
        return { allowed: false, retryAfterSec: Math.ceil((state.blockedUntil - now) / 1000) };
    }
    return { allowed: true, retryAfterSec: 0 };
}

function recordLoginFailure(clientIp) {
    const now = Date.now();
    const state = getLoginState(clientIp);
    state.count += 1;
    if (state.count >= LOGIN_MAX_ATTEMPTS) {
        state.blockedUntil = now + LOGIN_BLOCK_MS;
        state.count = 0;
        state.windowStart = now;
    }
    loginAttempts.set(clientIp, state);
}

function clearLoginFailures(clientIp) {
    loginAttempts.delete(clientIp);
}

function createAdminSession() {
    const sessionId = crypto.randomBytes(32).toString('hex');
    adminSessions.set(sessionId, Date.now() + SESSION_TTL_MS);
    return sessionId;
}

function isValidAdminSession(sessionId) {
    if (!sessionId) return false;
    const expiresAt = adminSessions.get(sessionId);
    if (!expiresAt) return false;
    if (expiresAt < Date.now()) {
        adminSessions.delete(sessionId);
        return false;
    }
    // Rolling expiration.
    adminSessions.set(sessionId, Date.now() + SESSION_TTL_MS);
    return true;
}

function clearAdminSession(sessionId) {
    if (sessionId) adminSessions.delete(sessionId);
}

function sessionCookieHeader(value, maxAgeSeconds) {
    const secure = process.env.NODE_ENV === 'production' ? '; Secure' : '';
    return `${SESSION_COOKIE}=${value}; Path=/; HttpOnly; SameSite=Strict; Max-Age=${maxAgeSeconds}${secure}`;
}

// Auth endpoints for admin UI.
app.post('/api/auth/login', (req, res) => {
    const clientIp = getClientIp(req);
    const gate = canAttemptLogin(clientIp);
    if (!gate.allowed) {
        res.setHeader('Retry-After', String(gate.retryAfterSec));
        return res.status(429).json({ error: 'Too many login attempts. Try again later.' });
    }

    const { password } = req.body || {};
    if (!timingSafeEqualStr(password || '', ADMIN_PASSWORD)) {
        recordLoginFailure(clientIp);
        return res.status(401).json({ error: 'Invalid credentials' });
    }
    clearLoginFailures(clientIp);
    const sessionId = createAdminSession();
    res.setHeader('Set-Cookie', sessionCookieHeader(sessionId, Math.floor(SESSION_TTL_MS / 1000)));
    return res.json({ success: true, token: sessionId });
});

app.post('/api/auth/logout', (req, res) => {
    const sessionId = getSessionId(req);
    clearAdminSession(sessionId);
    res.setHeader('Set-Cookie', sessionCookieHeader('', 0));
    return res.json({ success: true });
});

app.get('/api/auth/me', (req, res) => {
    const sessionId = getSessionId(req);
    return res.json({ authenticated: isValidAdminSession(sessionId) });
});

// Multer storage — saves uploaded image to TEMP_DIR with sanitized original filename
const bgStorage = multer.diskStorage({
    destination: TEMP_DIR,
    filename: (req, file, cb) => {
        const ext = path.extname(file.originalname).toLowerCase();
        const base = path.basename(file.originalname, path.extname(file.originalname))
            .replace(/[^a-zA-Z0-9._-]/g, '_')
            .substring(0, 64);
        cb(null, base + ext);
    }
});
const bgUpload = multer({
    storage: bgStorage,
    limits: { fileSize: 20 * 1024 * 1024 },
    fileFilter: (req, file, cb) => {
        const allowed = ['.jpg', '.jpeg', '.png', '.gif', '.webp'];
        if (allowed.includes(path.extname(file.originalname).toLowerCase())) cb(null, true);
        else cb(new Error('Only image files are allowed'));
    }
});

// Multer storage — accepts SQLite backup files for database restore
const dbUpload = multer({
    storage: multer.diskStorage({
        destination: os.tmpdir(),
        filename: (req, file, cb) => cb(null, `restore-${Date.now()}.sqlite`)
    }),
    limits: { fileSize: 100 * 1024 * 1024 },
    fileFilter: (req, file, cb) => {
        const ext = path.extname(file.originalname).toLowerCase();
        if (ext === '.db' || ext === '.sqlite' || ext === '.sql' || ext === '.txt') cb(null, true);
        else cb(new Error('Only .txt, .sql, .sqlite, or .db files allowed'));
    }
});

// Multer storage — accepts .csv files for companies/individuals import
const csvUpload = multer({
    storage: multer.diskStorage({
        destination: os.tmpdir(),
        filename: (req, file, cb) => cb(null, `import-${Date.now()}.csv`)
    }),
    limits: { fileSize: 10 * 1024 * 1024 },
    fileFilter: (req, file, cb) => {
        if (path.extname(file.originalname).toLowerCase() === '.csv') cb(null, true);
        else cb(new Error('Only .csv files allowed'));
    }
});

function csvEscape(value) {
    const text = value == null ? '' : String(value);
    if (/[",\r\n]/.test(text)) return `"${text.replace(/"/g, '""')}"`;
    return text;
}

function parseCsvText(rawText) {
    const text = String(rawText || '').replace(/^\uFEFF/, '');
    const rows = [];
    let row = [];
    let field = '';
    let inQuotes = false;

    for (let i = 0; i < text.length; i++) {
        const ch = text[i];
        const next = text[i + 1];

        if (inQuotes) {
            if (ch === '"' && next === '"') {
                field += '"';
                i++;
            } else if (ch === '"') {
                inQuotes = false;
            } else {
                field += ch;
            }
            continue;
        }

        if (ch === '"') {
            inQuotes = true;
        } else if (ch === ',') {
            row.push(field);
            field = '';
        } else if (ch === '\n') {
            row.push(field);
            rows.push(row);
            row = [];
            field = '';
        } else if (ch === '\r') {
            // ignore CR
        } else {
            field += ch;
        }
    }

    row.push(field);
    rows.push(row);

    const nonBlank = rows.filter(r => r.some(c => String(c).trim() !== ''));
    if (nonBlank.length === 0) return { headers: [], records: [] };

    const headers = nonBlank[0].map(h => String(h || '').trim());
    const records = nonBlank.slice(1);
    return { headers, records };
}

function headerIndexMap(headers) {
    const map = new Map();
    headers.forEach((h, i) => map.set(String(h || '').trim().toLowerCase(), i));
    return map;
}

function cell(row, indexMap, name) {
    const idx = indexMap.get(name.toLowerCase());
    if (idx == null || idx < 0 || idx >= row.length) return '';
    return String(row[idx] || '').trim();
}

// Database setup
let db = new sqlite3.Database(DB_FILE, (err) => {
    if (err) {
        console.error('Database connection error:', err);
    } else {
        console.log('Connected to SQLite database');
        initializeDatabase();
    }
});

// Initialize database tables
function initializeDatabase() {
    db.serialize(() => {
        db.run(`CREATE TABLE IF NOT EXISTS companies (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL,
            building TEXT NOT NULL,
            suite TEXT NOT NULL,
            phone TEXT,
            floor TEXT,
            created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        )`);

        db.run(`CREATE TABLE IF NOT EXISTS individuals (
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
        )`);

        db.run(`CREATE TABLE IF NOT EXISTS building_info (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            title TEXT NOT NULL,
            content TEXT NOT NULL,
            display_order INTEGER DEFAULT 0,
            updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        )`);

        db.run(`CREATE TABLE IF NOT EXISTS settings (
            key TEXT PRIMARY KEY,
            value TEXT,
            updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        )`);
        ensureRequiredSettings((settingsErr) => {
            if (settingsErr) {
                console.error('Failed to ensure required settings:', settingsErr.message);
            }
            console.log('Database initialized');
        });
    });
}

function ensureRequiredSettings(callback) {
    db.serialize(() => {
        db.run(`INSERT OR IGNORE INTO settings (key, value) VALUES ('data_version', '1')`, (vErr) => {
            if (vErr) return callback(vErr);
            db.run(`INSERT OR IGNORE INTO settings (key, value) VALUES ('background_image', '18.jpg')`, (bgErr) => {
                if (bgErr) return callback(bgErr);
                return callback(null);
            });
        });
    });
}

// API Routes

// Companies
app.get('/api/companies', (req, res) => {
    db.all('SELECT * FROM companies ORDER BY name', [], (err, rows) => {
        if (err) {
            res.status(500).json({ error: err.message });
        } else {
            res.json(rows);
        }
    });
});

app.get('/api/companies/search', (req, res) => {
    const query = `%${req.query.q}%`;
    db.all(
        `SELECT * FROM companies
         WHERE name LIKE ? OR building LIKE ? OR suite LIKE ?
         ORDER BY name`,
        [query, query, query],
        (err, rows) => {
            if (err) {
                res.status(500).json({ error: err.message });
            } else {
                res.json(rows);
            }
        }
    );
});

// Companies CSV export
app.get('/api/companies/csv', (req, res) => {
    db.all('SELECT name, building, suite, phone, floor FROM companies ORDER BY name', [], (err, rows) => {
        const safeRows = Array.isArray(rows) ? rows : [];
        const lines = ['name,building,suite,phone,floor'];
        for (const r of safeRows) {
            lines.push([
                csvEscape(r.name),
                csvEscape(r.building),
                csvEscape(r.suite),
                csvEscape(r.phone),
                csvEscape(r.floor)
            ].join(','));
        }

        res.setHeader('Content-Type', 'text/csv; charset=utf-8');
        res.setHeader('Content-Disposition', 'attachment; filename="companies.csv"');
        res.setHeader('X-CSV-Status', err ? 'warning' : 'ok');
        res.setHeader('X-CSV-Exported-Rows', String(safeRows.length));
        res.setHeader('X-DB-Companies-Count', String(safeRows.length));
        if (err) res.setHeader('X-CSV-Warning', 'export-generated-with-empty-data');
        return res.send(lines.join('\n'));
    });
});

// Companies CSV import (replaces all companies)
app.post('/api/companies/csv', (req, res) => {
    csvUpload.single('file')(req, res, (uploadErr) => {
        if (uploadErr) return res.status(400).json({ error: uploadErr.message });
        if (!req.file) return res.status(400).json({ error: 'No file uploaded' });

        fs.readFile(req.file.path, 'utf8', (readErr, data) => {
            fs.unlink(req.file.path, () => {});
            if (readErr) return res.status(400).json({ error: 'Could not read uploaded CSV file' });

            const { headers, records } = parseCsvText(data);
            const map = headerIndexMap(headers);
            const required = ['name', 'building', 'suite'];
            const missing = required.filter(h => !map.has(h));
            if (missing.length) {
                return res.status(400).json({ error: `Missing required CSV column(s): ${missing.join(', ')}` });
            }

            const parsed = [];
            for (let i = 0; i < records.length; i++) {
                const row = records[i];
                const rec = {
                    name: cell(row, map, 'name'),
                    building: cell(row, map, 'building'),
                    suite: cell(row, map, 'suite'),
                    phone: cell(row, map, 'phone'),
                    floor: cell(row, map, 'floor')
                };
                if (!rec.name || !rec.building || !rec.suite) {
                    return res.status(400).json({ error: `Row ${i + 2}: name, building, and suite are required` });
                }
                parsed.push(rec);
            }

            db.serialize(() => {
                db.run('BEGIN TRANSACTION');
                db.run('DELETE FROM companies', (delErr) => {
                    if (delErr) {
                        db.run('ROLLBACK');
                        return res.status(500).json({ error: delErr.message });
                    }

                    const stmt = db.prepare('INSERT INTO companies (name, building, suite, phone, floor) VALUES (?, ?, ?, ?, ?)');
                    let rowErr = null;
                    for (const rec of parsed) {
                        stmt.run([rec.name, rec.building, rec.suite, rec.phone || null, rec.floor || null], (e) => {
                            if (!rowErr && e) rowErr = e;
                        });
                    }
                    stmt.finalize((finalizeErr) => {
                        if (rowErr || finalizeErr) {
                            db.run('ROLLBACK');
                            return res.status(500).json({ error: (rowErr || finalizeErr).message });
                        }
                        db.run('COMMIT', (commitErr) => {
                            if (commitErr) return res.status(500).json({ error: commitErr.message });
                            incrementDataVersion();
                            return db.get('SELECT COUNT(*) AS count FROM companies', [], (countErr, countRow) => {
                                if (countErr) return res.status(500).json({ error: countErr.message });
                                return res.json({
                                    success: true,
                                    imported: parsed.length,
                                    db_counts: { companies: countRow ? countRow.count : 0 }
                                });
                            });
                        });
                    });
                });
            });
        });
    });
});

app.post('/api/companies', (req, res) => {
    const { name, building, suite, phone, floor } = req.body;
    db.run(
        `INSERT INTO companies (name, building, suite, phone, floor) VALUES (?, ?, ?, ?, ?)`,
        [name, building, suite, phone, floor],
        function(err) {
            if (err) {
                res.status(500).json({ error: err.message });
            } else {
                incrementDataVersion();
                res.json({ id: this.lastID });
            }
        }
    );
});

app.put('/api/companies/:id', (req, res) => {
    const { name, building, suite, phone, floor } = req.body;
    db.run(
        `UPDATE companies
         SET name = ?, building = ?, suite = ?, phone = ?, floor = ?, updated_at = CURRENT_TIMESTAMP
         WHERE id = ?`,
        [name, building, suite, phone, floor, req.params.id],
        (err) => {
            if (err) {
                res.status(500).json({ error: err.message });
            } else {
                incrementDataVersion();
                res.json({ success: true });
            }
        }
    );
});

app.delete('/api/companies/:id', (req, res) => {
    const companyId = req.params.id;
    db.serialize(() => {
        db.run('BEGIN TRANSACTION');
        db.run('UPDATE individuals SET company_id = NULL, updated_at = CURRENT_TIMESTAMP WHERE company_id = ?', [companyId], (updateErr) => {
            if (updateErr) {
                db.run('ROLLBACK');
                return res.status(500).json({ error: updateErr.message });
            }

            db.run('DELETE FROM companies WHERE id = ?', [companyId], (deleteErr) => {
                if (deleteErr) {
                    db.run('ROLLBACK');
                    return res.status(500).json({ error: deleteErr.message });
                }

                db.run('COMMIT', (commitErr) => {
                    if (commitErr) {
                        db.run('ROLLBACK');
                        return res.status(500).json({ error: commitErr.message });
                    }
                    incrementDataVersion();
                    return res.json({ success: true });
                });
            });
        });
    });
});

// Individuals
app.get('/api/individuals', (req, res) => {
    db.all('SELECT * FROM individuals ORDER BY last_name, first_name', [], (err, rows) => {
        if (err) {
            res.status(500).json({ error: err.message });
        } else {
            res.json(rows);
        }
    });
});

app.get('/api/individuals/search', (req, res) => {
    const query = `%${req.query.q}%`;
    db.all(
        `SELECT * FROM individuals
         WHERE first_name LIKE ? OR last_name LIKE ? OR building LIKE ? OR suite LIKE ?
         ORDER BY last_name, first_name`,
        [query, query, query, query],
        (err, rows) => {
            if (err) {
                res.status(500).json({ error: err.message });
            } else {
                res.json(rows);
            }
        }
    );
});

// Individuals CSV export
app.get('/api/individuals/csv', (req, res) => {
    db.all(
        `SELECT i.first_name, i.last_name, i.company_id, c.name AS company_name,
                i.building, i.suite, i.title, i.phone
         FROM individuals i
         LEFT JOIN companies c ON c.id = i.company_id
        ORDER BY i.last_name, i.first_name`,
        [],
        (err, rows) => {
            const safeRows = Array.isArray(rows) ? rows : [];
            const lines = ['first_name,last_name,company_id,company_name,building,suite,title,phone'];
            for (const r of safeRows) {
                lines.push([
                    csvEscape(r.first_name),
                    csvEscape(r.last_name),
                    csvEscape(r.company_id),
                    csvEscape(r.company_name),
                    csvEscape(r.building),
                    csvEscape(r.suite),
                    csvEscape(r.title),
                    csvEscape(r.phone)
                ].join(','));
            }

            res.setHeader('Content-Type', 'text/csv; charset=utf-8');
            res.setHeader('Content-Disposition', 'attachment; filename="individuals.csv"');
            res.setHeader('X-CSV-Status', err ? 'warning' : 'ok');
            res.setHeader('X-CSV-Exported-Rows', String(safeRows.length));
            res.setHeader('X-DB-Individuals-Count', String(safeRows.length));
            if (err) res.setHeader('X-CSV-Warning', 'export-generated-with-empty-data');
            return res.send(lines.join('\n'));
        }
    );
});

// Individuals CSV import (replaces all individuals)
app.post('/api/individuals/csv', (req, res) => {
    const sendIndividualsImportError = (httpStatus, error, stage, meta = {}) => {
        db.get('SELECT COUNT(*) AS count FROM individuals', [], (countErr, countRow) => {
            return res.status(httpStatus).json({
                success: false,
                error,
                status: {
                    upload: stage === 'upload' ? 'failed' : 'ok',
                    parse: stage === 'parse' ? 'failed' : (stage === 'upload' ? 'not_run' : 'ok'),
                    db: stage === 'db' ? 'failed' : (stage === 'upload' || stage === 'parse' ? 'not_run' : 'ok')
                },
                uploaded_rows: typeof meta.uploaded_rows === 'number' ? meta.uploaded_rows : 0,
                parsed_rows: typeof meta.parsed_rows === 'number' ? meta.parsed_rows : 0,
                db_counts: { individuals: countErr ? null : (countRow ? countRow.count : 0) }
            });
        });
    };

    csvUpload.single('file')(req, res, (uploadErr) => {
        if (uploadErr) return sendIndividualsImportError(400, uploadErr.message, 'upload');
        if (!req.file) return sendIndividualsImportError(400, 'No file uploaded', 'upload');

        fs.readFile(req.file.path, 'utf8', (readErr, data) => {
            fs.unlink(req.file.path, () => {});
            if (readErr) return sendIndividualsImportError(400, 'Could not read uploaded CSV file', 'upload');

            const { headers, records } = parseCsvText(data);
            const map = headerIndexMap(headers);
            const required = ['first_name', 'last_name', 'building', 'suite'];
            const missing = required.filter(h => !map.has(h));
            if (missing.length) {
                return sendIndividualsImportError(
                    400,
                    `Missing required CSV column(s): ${missing.join(', ')}`,
                    'parse',
                    { uploaded_rows: records.length, parsed_rows: 0 }
                );
            }

            db.all('SELECT id, name FROM companies', [], (companiesErr, companyRows) => {
                if (companiesErr) {
                    return sendIndividualsImportError(
                        500,
                        companiesErr.message,
                        'db',
                        { uploaded_rows: records.length, parsed_rows: 0 }
                    );
                }
                const companyByName = new Map(companyRows.map(c => [String(c.name || '').trim().toLowerCase(), c.id]));
                const parsed = [];
                for (let i = 0; i < records.length; i++) {
                    const row = records[i];
                    const first_name = cell(row, map, 'first_name');
                    const last_name = cell(row, map, 'last_name');
                    const building = cell(row, map, 'building');
                    const suite = cell(row, map, 'suite');
                    const title = cell(row, map, 'title');
                    const phone = cell(row, map, 'phone');
                    const companyIdText = cell(row, map, 'company_id');
                    const companyNameText = cell(row, map, 'company_name').toLowerCase();

                    if (!first_name || !last_name || !building || !suite) {
                        return sendIndividualsImportError(
                            400,
                            `Row ${i + 2}: first_name, last_name, building, and suite are required`,
                            'parse',
                            { uploaded_rows: records.length, parsed_rows: parsed.length }
                        );
                    }

                    let company_id = null;
                    if (companyIdText) {
                        const parsedId = Number.parseInt(companyIdText, 10);
                        if (!Number.isInteger(parsedId) || parsedId <= 0) {
                            return sendIndividualsImportError(
                                400,
                                `Row ${i + 2}: invalid company_id "${companyIdText}"`,
                                'parse',
                                { uploaded_rows: records.length, parsed_rows: parsed.length }
                            );
                        }
                        company_id = parsedId;
                    } else if (companyNameText) {
                        const resolved = companyByName.get(companyNameText);
                        if (!resolved) {
                            return sendIndividualsImportError(
                                400,
                                `Row ${i + 2}: unknown company_name "${cell(row, map, 'company_name')}"`,
                                'parse',
                                { uploaded_rows: records.length, parsed_rows: parsed.length }
                            );
                        }
                        company_id = resolved;
                    }

                    parsed.push({ first_name, last_name, company_id, building, suite, title, phone });
                }

                db.serialize(() => {
                    db.run('BEGIN TRANSACTION');
                    db.run('DELETE FROM individuals', (delErr) => {
                        if (delErr) {
                            db.run('ROLLBACK');
                            return sendIndividualsImportError(
                                500,
                                delErr.message,
                                'db',
                                { uploaded_rows: records.length, parsed_rows: parsed.length }
                            );
                        }

                        const stmt = db.prepare(
                            'INSERT INTO individuals (first_name, last_name, company_id, building, suite, title, phone) VALUES (?, ?, ?, ?, ?, ?, ?)'
                        );
                        let rowErr = null;
                        for (const rec of parsed) {
                            stmt.run(
                                [rec.first_name, rec.last_name, rec.company_id, rec.building, rec.suite, rec.title || null, rec.phone || null],
                                (e) => { if (!rowErr && e) rowErr = e; }
                            );
                        }
                        stmt.finalize((finalizeErr) => {
                            if (rowErr || finalizeErr) {
                                db.run('ROLLBACK');
                                return sendIndividualsImportError(
                                    500,
                                    (rowErr || finalizeErr).message,
                                    'db',
                                    { uploaded_rows: records.length, parsed_rows: parsed.length }
                                );
                            }
                            db.run('COMMIT', (commitErr) => {
                                if (commitErr) {
                                    return sendIndividualsImportError(
                                        500,
                                        commitErr.message,
                                        'db',
                                        { uploaded_rows: records.length, parsed_rows: parsed.length }
                                    );
                                }
                                incrementDataVersion();
                                return db.get('SELECT COUNT(*) AS count FROM individuals', [], (countErr, countRow) => {
                                    if (countErr) {
                                        return sendIndividualsImportError(
                                            500,
                                            countErr.message,
                                            'db',
                                            { uploaded_rows: records.length, parsed_rows: parsed.length }
                                        );
                                    }
                                    return res.json({
                                        success: true,
                                        imported: parsed.length,
                                        status: { upload: 'ok', parse: 'ok', db: 'ok' },
                                        uploaded_rows: records.length,
                                        parsed_rows: parsed.length,
                                        db_counts: { individuals: countRow ? countRow.count : 0 }
                                    });
                                });
                            });
                        });
                    });
                });
            });
        });
    });
});

app.post('/api/individuals', (req, res) => {
    const { first_name, last_name, company_id, building, suite, title, phone } = req.body;
    db.run(
        `INSERT INTO individuals (first_name, last_name, company_id, building, suite, title, phone)
         VALUES (?, ?, ?, ?, ?, ?, ?)`,
        [first_name, last_name, company_id, building, suite, title, phone],
        function(err) {
            if (err) {
                res.status(500).json({ error: err.message });
            } else {
                incrementDataVersion();
                res.json({ id: this.lastID });
            }
        }
    );
});

app.put('/api/individuals/:id', (req, res) => {
    const { first_name, last_name, company_id, building, suite, title, phone } = req.body;
    db.run(
        `UPDATE individuals
         SET first_name = ?, last_name = ?, company_id = ?, building = ?, suite = ?, title = ?, phone = ?, updated_at = CURRENT_TIMESTAMP
         WHERE id = ?`,
        [first_name, last_name, company_id, building, suite, title, phone, req.params.id],
        (err) => {
            if (err) {
                res.status(500).json({ error: err.message });
            } else {
                incrementDataVersion();
                res.json({ success: true });
            }
        }
    );
});

app.delete('/api/individuals/:id', (req, res) => {
    db.run('DELETE FROM individuals WHERE id = ?', [req.params.id], (err) => {
        if (err) {
            res.status(500).json({ error: err.message });
        } else {
            incrementDataVersion();
            res.json({ success: true });
        }
    });
});

// Building Info
app.get('/api/building-info', (req, res) => {
    db.get('SELECT content FROM building_info ORDER BY display_order LIMIT 1', [], (err, row) => {
        if (err) {
            res.status(500).json({ error: err.message });
        } else {
            const content = row && typeof row.content === 'string' ? row.content : '';
            res.json(content || DEFAULT_BUILDING_INFO_HTML);
        }
    });
});

app.put('/api/building-info', (req, res) => {
    const { content } = req.body;
    db.run(
        `INSERT OR REPLACE INTO building_info (id, title, content, display_order, updated_at)
         VALUES (1, 'Building Information', ?, 0, CURRENT_TIMESTAMP)`,
        [content],
        (err) => {
            if (err) {
                res.status(500).json({ error: err.message });
            } else {
                incrementDataVersion();
                res.json({ success: true });
            }
        }
    );
});

// Database backup — VACUUM INTO a temp file then stream it to the client
app.get('/api/backup', (req, res) => {
    const backupPath = path.join(os.tmpdir(), `directory-backup-${Date.now()}.sqlite`);
    const escaped = backupPath.replace(/'/g, "''");
    db.run(`VACUUM INTO '${escaped}'`, (err) => {
        if (err) return res.status(500).json({ error: err.message });
        res.download(backupPath, 'directory-backup.sqlite', () => {
            fs.unlink(backupPath, () => {});
        });
    });
});

// SQL text backup — sqlite3 .dump
app.get('/api/backup.sql', (req, res) => {
    const dump = spawnSync('sqlite3', [DB_FILE, '.dump'], { encoding: 'utf8', maxBuffer: 100 * 1024 * 1024 });
    if (dump.error) return res.status(500).json({ error: `sqlite3 failed: ${dump.error.message}` });
    if (dump.status !== 0) {
        return res.status(500).json({ error: `sqlite3 dump failed: ${(dump.stderr || '').trim() || 'unknown error'}` });
    }
    res.setHeader('Content-Type', 'text/plain; charset=utf-8');
    res.setHeader('Content-Disposition', 'attachment; filename="directory-backup.sql"');
    res.send(dump.stdout || '');
});

// SQL text backup in .txt format (most permissive for browser download policies)
app.get('/api/backup.txt', (req, res) => {
    const dump = spawnSync('sqlite3', [DB_FILE, '.dump'], { encoding: 'utf8', maxBuffer: 100 * 1024 * 1024 });
    if (dump.error) return res.status(500).json({ error: `sqlite3 failed: ${dump.error.message}` });
    if (dump.status !== 0) {
        return res.status(500).json({ error: `sqlite3 dump failed: ${(dump.stderr || '').trim() || 'unknown error'}` });
    }
    res.setHeader('Content-Type', 'text/plain; charset=utf-8');
    res.setHeader('Content-Disposition', 'attachment; filename="directory-backup.txt"');
    res.send(dump.stdout || '');
});

function reopenDbAndRespond(res) {
    db = new sqlite3.Database(DB_FILE, (openErr) => {
        if (openErr) return res.status(500).json({ error: 'Failed to reopen database: ' + openErr.message });
        ensureRequiredSettings((settingsErr) => {
            if (settingsErr) return res.status(500).json({ error: 'Restore succeeded but required settings setup failed: ' + settingsErr.message });
            db.get(
                'SELECT (SELECT COUNT(*) FROM companies) AS companies, (SELECT COUNT(*) FROM individuals) AS individuals',
                [],
                (countErr, row) => {
                    if (countErr) return res.status(500).json({ error: 'Restore succeeded but count query failed: ' + countErr.message });
                    incrementDataVersion();
                    res.json({
                        success: true,
                        db_counts: {
                            companies: row ? row.companies : 0,
                            individuals: row ? row.individuals : 0
                        }
                    });
                }
            );
        });
    });
}

function replaceDatabaseFile(uploadPath, res) {
    db.close((closeErr) => {
        if (closeErr) return res.status(500).json({ error: 'Failed to close database: ' + closeErr.message });
        try {
            fs.copyFileSync(uploadPath, DB_FILE);
        } catch (e) {
            return res.status(500).json({ error: 'Failed to replace database: ' + e.message });
        } finally {
            fs.unlink(uploadPath, () => {});
        }
        return reopenDbAndRespond(res);
    });
}

function restoreFromSqlDump(uploadPath, res) {
    let sqlText = '';
    try {
        sqlText = fs.readFileSync(uploadPath, 'utf8');
    } catch (e) {
        return res.status(400).json({ error: 'Could not read uploaded SQL file' });
    } finally {
        fs.unlink(uploadPath, () => {});
    }
    if (!sqlText.trim()) {
        return res.status(400).json({ error: 'Uploaded SQL file is empty' });
    }

    const tempDbPath = path.join(os.tmpdir(), `restore-import-${Date.now()}.sqlite`);
    const importResult = spawnSync('sqlite3', [tempDbPath], { input: sqlText, encoding: 'utf8', maxBuffer: 100 * 1024 * 1024 });
    if (importResult.error) {
        fs.unlink(tempDbPath, () => {});
        return res.status(500).json({ error: `sqlite3 import failed: ${importResult.error.message}` });
    }
    if (importResult.status !== 0) {
        const detail = (importResult.stderr || '').trim() || 'unknown error';
        fs.unlink(tempDbPath, () => {});
        return res.status(400).json({ error: `Invalid SQL backup: ${detail}` });
    }

    const verify = spawnSync(
        'sqlite3',
        [tempDbPath, "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name IN ('companies','individuals','settings');"],
        { encoding: 'utf8' }
    );
    const tableCount = Number.parseInt((verify.stdout || '').trim(), 10);
    if (verify.status !== 0 || Number.isNaN(tableCount) || tableCount < 3) {
        fs.unlink(tempDbPath, () => {});
        return res.status(400).json({ error: 'Invalid SQL backup: missing required tables' });
    }

    db.close((closeErr) => {
        if (closeErr) {
            fs.unlink(tempDbPath, () => {});
            return res.status(500).json({ error: 'Failed to close database: ' + closeErr.message });
        }
        try {
            fs.copyFileSync(tempDbPath, DB_FILE);
        } catch (e) {
            fs.unlink(tempDbPath, () => {});
            return res.status(500).json({ error: 'Failed to replace database: ' + e.message });
        }
        fs.unlink(tempDbPath, () => {});
        return reopenDbAndRespond(res);
    });
}

// Database restore — accepts SQL dumps and SQLite database files
app.post('/api/restore', (req, res) => {
    dbUpload.single('database')(req, res, (uploadErr) => {
        if (uploadErr) return res.status(400).json({ error: uploadErr.message });
        if (!req.file) return res.status(400).json({ error: 'No file uploaded' });

        const ext = path.extname(req.file.originalname).toLowerCase();
        if (ext === '.sql' || ext === '.txt') {
            return restoreFromSqlDump(req.file.path, res);
        }

        // Validate SQLite magic bytes ("SQLite format 3\000")
        const magic = Buffer.alloc(15);
        try {
            const fd = fs.openSync(req.file.path, 'r');
            fs.readSync(fd, magic, 0, 15, 0);
            fs.closeSync(fd);
        } catch (e) {
            fs.unlink(req.file.path, () => {});
            return res.status(400).json({ error: 'Could not read uploaded file' });
        }
        if (!magic.equals(Buffer.from('SQLite format 3'))) {
            fs.unlink(req.file.path, () => {});
            return res.status(400).json({ error: 'Not a valid SQLite database file' });
        }

        return replaceDatabaseFile(req.file.path, res);
    });
});

// Background image — get active
app.get('/api/background-image', (req, res) => {
    db.get('SELECT value FROM settings WHERE key = "background_image"', [], (err, row) => {
        if (err) {
            res.status(500).json({ error: err.message });
        } else {
            res.json({ filename: row ? row.value : null });
        }
    });
});

// Background image — upload new (multer → TEMP_DIR → persist script → UPLOADS_LOWER)
app.post('/api/background-image', bgUpload.single('image'), (req, res) => {
    if (!req.file) {
        return res.status(400).json({ error: 'No file uploaded' });
    }
    const cleanupUpload = () => fs.unlink(req.file.path, () => {});
    const filename = req.file.filename;
    const result = spawnSync(PERSIST_ARGV[0], [...PERSIST_ARGV.slice(1), 'copy', req.file.path, filename]);
    if (result.status !== 0) {
        cleanupUpload();
        return res.status(500).json({ error: 'Failed to persist file: ' + (result.stderr ? result.stderr.toString().trim() : 'unknown error') });
    }
    const dbKey = `uploads/${filename}`;
    db.run(
        `INSERT OR REPLACE INTO settings (key, value, updated_at) VALUES ('background_image', ?, CURRENT_TIMESTAMP)`,
        [dbKey],
        (err) => {
            cleanupUpload();
            if (err) return res.status(500).json({ error: err.message });
            incrementDataVersion();
            return res.json({ success: true, filename: dbKey });
        }
    );
});

// Background image — set active from gallery
app.put('/api/background-image', (req, res) => {
    const { filename } = req.body;
    if (!filename) return res.status(400).json({ error: 'filename required' });

    if (filename === '18.jpg') {
        db.run(
            `INSERT OR REPLACE INTO settings (key, value, updated_at) VALUES ('background_image', ?, CURRENT_TIMESTAMP)`,
            [filename],
            (err) => {
                if (err) return res.status(500).json({ error: err.message });
                incrementDataVersion();
                return res.json({ success: true });
            }
        );
        return;
    }

    const m = String(filename).match(/^uploads\/([a-zA-Z0-9._-]+)$/);
    if (!m) return res.status(400).json({ error: 'Invalid filename' });

    const uploadedName = m[1];
    const imageExts = new Set(['.jpg', '.jpeg', '.png', '.gif', '.webp']);
    if (!imageExts.has(path.extname(uploadedName).toLowerCase())) {
        return res.status(400).json({ error: 'Invalid filename' });
    }

    const absPath = path.join(UPLOADS_LOWER, uploadedName);
    fs.access(absPath, fs.constants.R_OK, (accessErr) => {
        if (accessErr) return res.status(400).json({ error: 'Unknown background image' });
        db.run(
            `INSERT OR REPLACE INTO settings (key, value, updated_at) VALUES ('background_image', ?, CURRENT_TIMESTAMP)`,
            [filename],
            (err) => {
                if (err) return res.status(500).json({ error: err.message });
                incrementDataVersion();
                return res.json({ success: true });
            }
        );
    });
});

// Background images — list gallery (built-in + uploaded)
app.get('/api/background-images', (req, res) => {
    const images = [{ filename: '18.jpg', url: '/18.jpg', builtin: true }];
    const imageExts = ['.jpg', '.jpeg', '.png', '.gif', '.webp'];
    fs.readdir(UPLOADS_LOWER, (err, files) => {
        if (!err && files) {
            files
                .filter(f => imageExts.includes(path.extname(f).toLowerCase()))
                .forEach(f => images.push({ filename: f, url: `/uploads/${f}`, builtin: false }));
        }
        res.json(images);
    });
});

// Background images — delete uploaded image
app.delete('/api/background-images/:filename', (req, res) => {
    const filename = req.params.filename;
    if (!/^[a-zA-Z0-9._-]+$/.test(filename)) {
        return res.status(400).json({ error: 'Invalid filename' });
    }
    const result = spawnSync(PERSIST_ARGV[0], [...PERSIST_ARGV.slice(1), 'delete', filename]);
    if (result.status !== 0) {
        return res.status(500).json({ error: 'Failed to delete file' });
    }
    // If the deleted file was active, reset to built-in default
    db.get('SELECT value FROM settings WHERE key = "background_image"', [], (err, row) => {
        if (!err && row && row.value === `uploads/${filename}`) {
            db.run(
                `UPDATE settings SET value = '18.jpg', updated_at = CURRENT_TIMESTAMP WHERE key = 'background_image'`,
                () => incrementDataVersion()
            );
        }
        res.json({ success: true });
    });
});

// Data version (for cache busting)
app.get('/api/data-version', (req, res) => {
    db.get('SELECT value FROM settings WHERE key = "data_version"', [], (err, row) => {
        if (err) {
            res.status(500).json({ error: err.message });
        } else {
            const version = Number.parseInt(row && row.value ? row.value : '1', 10);
            res.json({ version: Number.isNaN(version) ? 1 : version });
        }
    });
});

app.get('/api/revision', (req, res) => {
    res.json({
        revision: DEPLOY_REVISION,
        serverVersion: SERVER_PACKAGE_VERSION,
        source: REVISION_SOURCE
    });
});

function mapKioskBuildingSuffix(ip) {
    switch (ip) {
        case '192.168.1.80':
            return '9';
        case '192.168.1.81':
            return '5';
        case '192.168.1.82':
            return '1';
        default:
            return 'x';
    }
}

function resolveServerLanIpFromUrl() {
    try {
        const u = new URL(KIOSK_SERVER_URL);
        const host = u.hostname || '';
        if (/^\d{1,3}(\.\d{1,3}){3}$/.test(host)) return host;
    } catch (e) {
        // Ignore malformed URL; fall back to interface scan.
    }
    return '';
}

function extractHostFromUrl(rawUrl) {
    try {
        return new URL(rawUrl).hostname || '';
    } catch (e) {
        return '';
    }
}

function getKioskServerRole(ip) {
    const primaryHost = extractHostFromUrl(KIOSK_SERVER_URL);
    const standbyHost = extractHostFromUrl(KIOSK_SERVER_URL_STANDBY);
    if (primaryHost && ip === primaryHost) return 'active';
    if (standbyHost && ip === standbyHost) return 'standby';
    return 'client';
}

function getLocalIpv4Set() {
    const out = new Set(['127.0.0.1']);
    try {
        const interfaces = os.networkInterfaces() || {};
        for (const iface of Object.values(interfaces)) {
            if (!Array.isArray(iface)) continue;
            for (const addr of iface) {
                if (addr && addr.family === 'IPv4' && addr.address) out.add(addr.address);
            }
        }
    } catch (e) {
        // Ignore and return best-effort set.
    }
    return out;
}

function isLocalKioskTarget(ip) {
    return getLocalIpv4Set().has(ip);
}

function getStandbySyncTarget() {
    const standbyHost = extractHostFromUrl(KIOSK_SERVER_URL_STANDBY);
    if (!standbyHost || isLocalKioskTarget(standbyHost)) return null;
    const kiosk = KIOSK_CLIENTS.find(k => k.ip === standbyHost);
    return {
        host: standbyHost,
        user: kiosk && kiosk.user ? kiosk.user : 'kiosk'
    };
}

function isPrimaryServerNode() {
    const primaryHost = extractHostFromUrl(KIOSK_SERVER_URL);
    return !!primaryHost && isLocalKioskTarget(primaryHost);
}

function getSshBaseArgs(target) {
    return [
        '-i', KIOSK_SSH_KEY,
        '-o', 'BatchMode=yes',
        '-o', 'ConnectTimeout=5',
        '-o', 'StrictHostKeyChecking=accept-new',
        '-o', `UserKnownHostsFile=${KIOSK_KNOWN_HOSTS_FILE}`,
        `${target.user}@${target.host}`
    ];
}

function getDataVersionValue() {
    return new Promise((resolve, reject) => {
        db.get(`SELECT COALESCE((SELECT value FROM settings WHERE key = 'data_version'), '0') AS value`, [], (err, row) => {
            if (err) return reject(err);
            resolve(String((row && row.value) || '0').trim() || '0');
        });
    });
}

function getLocalUploadsSignature() {
    const hash = crypto.createHash('sha256');
    let entries = [];
    try {
        entries = fs.readdirSync(UPLOADS_LOWER, { withFileTypes: true })
            .filter((entry) => entry.isFile())
            .map((entry) => {
                const fullPath = path.join(UPLOADS_LOWER, entry.name);
                const stat = fs.statSync(fullPath);
                return `${entry.name}\t${stat.size}\t${stat.mtimeMs}`;
            })
            .sort();
    } catch (err) {
        return 'missing';
    }

    if (entries.length === 0) return 'empty';
    for (const line of entries) {
        hash.update(line);
        hash.update('\n');
    }
    return hash.digest('hex');
}

async function getRemoteDataVersion(target) {
    const result = await runCommandCapture('ssh', [
        ...getSshBaseArgs(target),
        `sqlite3 '${STANDBY_DB_FILE}' "SELECT COALESCE((SELECT value FROM settings WHERE key='data_version'),'0');"`
    ], { timeout: 15000 });
    if (result.status !== 0) {
        throw new Error(((result.stderr || '').trim() || result.error || 'failed to query standby data_version'));
    }
    return String((result.stdout || '').trim() || '0');
}

async function getRemoteUploadsSignature(target) {
    const remoteCmd = `
        set -e
        uploads_dir='${STANDBY_UPLOADS_DIR}'
        if [[ -d /media/root-ro/home/kiosk/building-directory/server ]]; then
            uploads_dir='/media/root-ro/home/kiosk/building-directory/server/uploads'
        fi
        if [[ ! -d "$uploads_dir" ]]; then
            printf 'missing\\n'
            exit 0
        fi
        mapfile -t files < <(find "$uploads_dir" -maxdepth 1 -type f -printf '%f\\t%s\\t%T@\\n' | LC_ALL=C sort)
        if [[ "\${#files[@]}" -eq 0 ]]; then
            printf 'empty\\n'
            exit 0
        fi
        printf '%s\\n' "\${files[@]}" | sha256sum | awk '{print $1}'
    `;
    const result = await runCommandCapture('ssh', [
        ...getSshBaseArgs(target),
        remoteCmd
    ], { timeout: 15000 });
    if (result.status !== 0) {
        throw new Error(((result.stderr || '').trim() || result.error || 'failed to query standby uploads signature'));
    }
    return String((result.stdout || '').trim() || 'missing');
}

async function syncStandbyDatabaseNow(reason = 'manual') {
    const target = getStandbySyncTarget();
    if (!KIOSK_STANDBY_SYNC_ENABLED || !isPrimaryServerNode() || !target) return { skipped: true };
    if (!fs.existsSync(KIOSK_SSH_KEY)) {
        throw new Error(`SSH deploy key not found at ${KIOSK_SSH_KEY}`);
    }

    const localVersion = await getDataVersionValue();
    const localUploadsSignature = getLocalUploadsSignature();
    let standbyVersion = 'unknown';
    let standbyUploadsSignature = 'unknown';
    try {
        [standbyVersion, standbyUploadsSignature] = await Promise.all([
            getRemoteDataVersion(target),
            getRemoteUploadsSignature(target)
        ]);
        if (standbyVersion === localVersion && standbyUploadsSignature === localUploadsSignature) {
            return { skipped: true, localVersion, standbyVersion, uploadsSignature: localUploadsSignature };
        }
    } catch (err) {
        console.warn(`Standby sync precheck failed (${reason}): ${err.message}`);
    }

    const ts = Date.now();
    const localBackup = path.join(os.tmpdir(), `standby-sync-${ts}.sqlite`);
    const localUploadsArchive = path.join(os.tmpdir(), `standby-sync-uploads-${ts}.tar.gz`);
    const remoteStageDir = `/tmp/standby-sync-${ts}`;
    const remoteBackup = `${remoteStageDir}/directory.sqlite`;
    const remoteUploadsArchive = `${remoteStageDir}/uploads.tar.gz`;

    try {
        const backup = await runCommandCapture('sqlite3', [DB_FILE, `.backup ${localBackup}`], {
            timeout: KIOSK_STANDBY_SYNC_TIMEOUT_MS
        });
        if (backup.status !== 0 || !fs.existsSync(localBackup)) {
            throw new Error(((backup.stderr || '').trim() || backup.error || 'failed to create local backup'));
        }

        const archive = await runCommandCapture('tar', [
            '-C', UPLOADS_LOWER,
            '-czf', localUploadsArchive,
            '.'
        ], { timeout: KIOSK_STANDBY_SYNC_TIMEOUT_MS });
        if (archive.status !== 0 || !fs.existsSync(localUploadsArchive)) {
            throw new Error(((archive.stderr || '').trim() || archive.error || 'failed to archive local uploads'));
        }

        const remoteStage = await runCommandCapture('ssh', [
            ...getSshBaseArgs(target),
            `mkdir -p '${remoteStageDir}'`
        ], { timeout: 15000 });
        if (remoteStage.status !== 0) {
            throw new Error(((remoteStage.stderr || '').trim() || remoteStage.error || 'failed to create standby staging directory'));
        }

        const scp = await runCommandCapture('scp', [
            '-i', KIOSK_SSH_KEY,
            '-o', 'BatchMode=yes',
            '-o', 'ConnectTimeout=5',
            '-o', 'StrictHostKeyChecking=accept-new',
            '-o', `UserKnownHostsFile=${KIOSK_KNOWN_HOSTS_FILE}`,
            localBackup,
            localUploadsArchive,
            `${target.user}@${target.host}:${remoteStageDir}/`
        ], { timeout: KIOSK_STANDBY_SYNC_TIMEOUT_MS });
        if (scp.status !== 0) {
            throw new Error(((scp.stderr || '').trim() || scp.error || 'failed to copy standby sync payload'));
        }

        const remoteRestore = await runCommandCapture('ssh', [
            ...getSshBaseArgs(target),
            `set -e
             test -s '${remoteBackup}'
             test -s '${remoteUploadsArchive}'
             sqlite3 '${remoteBackup}' 'PRAGMA schema_version;' >/dev/null
             uploads_dir='${STANDBY_UPLOADS_DIR}'
             if [[ -d /media/root-ro/home/kiosk/building-directory/server ]]; then
                 uploads_dir='/media/root-ro/home/kiosk/building-directory/server/uploads'
             fi
             sudo -n systemctl stop directory-server
             rm -rf "$uploads_dir"
             mkdir -p "$uploads_dir"
             tar -xzf '${remoteUploadsArchive}' -C "$uploads_dir"
             cp '${remoteBackup}' '${STANDBY_DB_FILE}'
             sudo -n chown -R kiosk:kiosk "$uploads_dir"
             sudo -n chown kiosk:kiosk '${STANDBY_DB_FILE}'
             sudo -n systemctl start directory-server
             rm -f '${remoteBackup}'`
        ], { timeout: KIOSK_STANDBY_SYNC_TIMEOUT_MS });
        if (remoteRestore.status !== 0) {
            throw new Error(((remoteRestore.stderr || '').trim() || remoteRestore.error || 'failed to restore standby backup'));
        }

        const [verifyVersion, verifyUploadsSignature] = await Promise.all([
            getRemoteDataVersion(target),
            getRemoteUploadsSignature(target)
        ]);
        if (verifyVersion !== localVersion) {
            throw new Error(`standby data_version mismatch after sync (local=${localVersion}, standby=${verifyVersion})`);
        }
        if (verifyUploadsSignature !== localUploadsSignature) {
            throw new Error(`standby uploads signature mismatch after sync (local=${localUploadsSignature}, standby=${verifyUploadsSignature})`);
        }

        console.log(`Standby sync complete (${reason}): ${target.host} data_version=${localVersion} uploads=${localUploadsSignature}`);
        return { synced: true, localVersion, standbyVersion: verifyVersion, uploadsSignature: verifyUploadsSignature };
    } finally {
        fs.unlink(localBackup, () => {});
        fs.unlink(localUploadsArchive, () => {});
        void runCommandCapture('ssh', [
            ...getSshBaseArgs(target),
            `rm -rf '${remoteStageDir}'`
        ], { timeout: 5000 });
    }
}

const standbySyncState = {
    dirty: false,
    timer: null,
    running: false
};

async function runStandbySync(reason = 'manual') {
    if (!KIOSK_STANDBY_SYNC_ENABLED || !isPrimaryServerNode() || !getStandbySyncTarget()) {
        return { skipped: true };
    }
    if (standbySyncState.running) {
        standbySyncState.dirty = true;
        return { skipped: true, busy: true };
    }

    standbySyncState.running = true;
    standbySyncState.dirty = false;
    try {
        return await syncStandbyDatabaseNow(reason);
    } catch (err) {
        console.warn(`Standby DB sync failed (${reason}): ${err.message}`);
        standbySyncState.dirty = true;
        throw err;
    } finally {
        standbySyncState.running = false;
        if (standbySyncState.dirty && !standbySyncState.timer) {
            scheduleStandbySync('retry');
        }
    }
}

function scheduleStandbySync(reason = 'update') {
    if (!KIOSK_STANDBY_SYNC_ENABLED || !isPrimaryServerNode() || !getStandbySyncTarget()) return;
    standbySyncState.dirty = true;
    if (standbySyncState.timer) return;
    standbySyncState.timer = setTimeout(async () => {
        standbySyncState.timer = null;
        try {
            await runStandbySync(reason);
        } catch (err) {
            // runStandbySync already logged and marked dirty for retry.
        }
    }, KIOSK_STANDBY_SYNC_DELAY_MS);
    if (typeof standbySyncState.timer.unref === 'function') standbySyncState.timer.unref();
}

const KIOSK_STATUS_REFRESH_MS = Number.parseInt(process.env.KIOSK_STATUS_REFRESH_MS || '', 10) || 30000;
const kioskStatusCache = new Map(
    KIOSK_CLIENTS.map(k => [k.id, {
        overlay: 'unknown',
        reachable: false,
        error: 'Status pending',
        checkedAt: null
    }])
);
let kioskStatusRefreshPromise = null;
let kioskStatusLastRefreshStartedAt = 0;

function runCommandCapture(cmd, args, options = {}) {
    const timeout = options.timeout || 0;
    return new Promise((resolve) => {
        let stdout = '';
        let stderr = '';
        let timedOut = false;
        let settled = false;
        let child;

        const finalize = (result) => {
            if (settled) return;
            settled = true;
            if (timer) clearTimeout(timer);
            resolve(result);
        };

        let timer = null;
        try {
            child = spawn(cmd, args, {
                stdio: ['ignore', 'pipe', 'pipe'],
                ...options.spawnOptions
            });
        } catch (err) {
            finalize({ status: 1, stdout, stderr, error: err.message, timedOut: false });
            return;
        }

        if (child.stdout) {
            child.stdout.on('data', (chunk) => {
                stdout += chunk.toString();
            });
        }
        if (child.stderr) {
            child.stderr.on('data', (chunk) => {
                stderr += chunk.toString();
            });
        }

        child.on('error', (err) => {
            finalize({ status: 1, stdout, stderr, error: err.message, timedOut });
        });
        child.on('close', (code) => {
            finalize({
                status: code == null ? 1 : code,
                stdout,
                stderr,
                error: timedOut ? `Timed out after ${timeout}ms` : '',
                timedOut
            });
        });

        if (timeout > 0) {
            timer = setTimeout(() => {
                timedOut = true;
                child.kill('SIGKILL');
            }, timeout);
        }
    });
}

async function probeKioskOverlayStatus(kiosk) {
    const localIps = getLocalIpv4Set();
    if (localIps.has(kiosk.ip)) {
        const local = await runCommandCapture('bash', [
            '-lc',
            "if mount | grep -q '^overlayroot on / type overlay'; then echo on; else echo off; fi"
        ], { timeout: 3000 });
        if (local.status === 0) {
            return {
                id: kiosk.id,
                overlay: ((local.stdout || '').trim() === 'on') ? 'on' : 'off',
                reachable: true,
                error: null
            };
        }
    }

    if (!fs.existsSync(KIOSK_SSH_KEY)) {
        return {
            id: kiosk.id,
            overlay: 'unknown',
            reachable: false,
            error: 'SSH key not found'
        };
    }
    const result = await runCommandCapture('ssh', [
        '-i', KIOSK_SSH_KEY,
        '-o', 'BatchMode=yes',
        '-o', 'ConnectTimeout=4',
        '-o', 'StrictHostKeyChecking=accept-new',
        `${kiosk.user}@${kiosk.ip}`,
        "if mount | grep -q '^overlayroot on / type overlay'; then echo on; else echo off; fi"
    ], { timeout: 7000 });

    if (result.status !== 0) {
        const err = ((result.stderr || '').trim() || result.error || 'unreachable');
        return {
            id: kiosk.id,
            overlay: 'unknown',
            reachable: false,
            error: err
        };
    }

    const overlay = ((result.stdout || '').trim() === 'on') ? 'on' : 'off';
    return {
        id: kiosk.id,
        overlay,
        reachable: true,
        error: null
    };
}

function getCachedKioskStatuses() {
    return KIOSK_CLIENTS.map(k => {
        const cached = kioskStatusCache.get(k.id) || {};
        return {
            id: k.id,
            name: k.name,
            ip: k.ip,
            serverRole: getKioskServerRole(k.ip),
            overlay: cached.overlay || 'unknown',
            reachable: !!cached.reachable,
            error: cached.error || null,
            checkedAt: cached.checkedAt || null,
            refreshing: !!kioskStatusRefreshPromise
        };
    });
}

function refreshKioskStatusCache(force = false) {
    const now = Date.now();
    if (kioskStatusRefreshPromise) return kioskStatusRefreshPromise;
    if (!force && kioskStatusLastRefreshStartedAt && (now - kioskStatusLastRefreshStartedAt) < KIOSK_STATUS_REFRESH_MS) {
        return Promise.resolve();
    }

    kioskStatusLastRefreshStartedAt = now;
    kioskStatusRefreshPromise = (async () => {
        const checkedAt = new Date().toISOString();
        const statuses = await Promise.all(KIOSK_CLIENTS.map(k => probeKioskOverlayStatus(k)));
        for (const status of statuses) {
            kioskStatusCache.set(status.id, {
                overlay: status.overlay,
                reachable: status.reachable,
                error: status.error,
                checkedAt
            });
        }
    })().catch((err) => {
        console.warn('Failed to refresh kiosk status cache:', err.message);
    }).finally(() => {
        kioskStatusRefreshPromise = null;
    });

    return kioskStatusRefreshPromise;
}

const kioskStatusInterval = setInterval(() => {
    void refreshKioskStatusCache(false);
}, KIOSK_STATUS_REFRESH_MS);
if (typeof kioskStatusInterval.unref === 'function') kioskStatusInterval.unref();
void refreshKioskStatusCache(true);

function resolveFirstLanIp() {
    try {
        const interfaces = os.networkInterfaces() || {};
        for (const iface of Object.values(interfaces)) {
            if (!Array.isArray(iface)) continue;
            for (const addr of iface) {
                if (addr && addr.family === 'IPv4' && !addr.internal) return addr.address;
            }
        }
    } catch (e) {
        // Ignore and fall back to unknown.
    }
    return '';
}

function resolveKioskLocationIp(req) {
    const clientIp = getClientIp(req);
    if (clientIp !== '127.0.0.1' && clientIp !== '::1') return clientIp;
    // Combined server+kiosk machine often appears as loopback through nginx.
    return resolveServerLanIpFromUrl() || resolveFirstLanIp() || clientIp;
}

// Kiosk location metadata for welcome screen line 3
app.get('/api/kiosk-location', (req, res) => {
    const clientIp = resolveKioskLocationIp(req);
    const buildingSuffix = mapKioskBuildingSuffix(clientIp);
    res.json({
        ip: clientIp,
        buildingSuffix,
        buildingCode: `430${buildingSuffix}`
    });
});

function incrementDataVersion() {
    db.serialize(() => {
        db.run(`INSERT OR IGNORE INTO settings (key, value) VALUES ('data_version', '1')`);
        db.run(
            `UPDATE settings
             SET value = CAST(COALESCE(value, '0') AS INTEGER) + 1,
                 updated_at = CURRENT_TIMESTAMP
             WHERE key = 'data_version'`,
            (err) => {
                if (err) {
                    console.error('Failed to update data_version:', err.message);
                    return;
                }
                scheduleStandbySync('data_version');
            }
        );
    });
}

// Kiosk client management

// List kiosk display clients
app.get('/api/kiosks', (req, res) => {
    res.json(KIOSK_CLIENTS.map(k => ({
        id: k.id,
        name: k.name,
        ip: k.ip,
        user: k.user,
        serverRole: getKioskServerRole(k.ip),
        localTarget: isLocalKioskTarget(k.ip)
    })));
});

// Live per-kiosk node status (overlay + reachability)
app.get('/api/kiosks/status', (req, res) => {
    const forceRefresh = req.query.refresh === '1' || req.query.refresh === 'true';
    void refreshKioskStatusCache(forceRefresh);
    res.json(getCachedKioskStatuses());
});

// Server URL that kiosk machines should use to reach this server
app.get('/api/kiosks/server-url', (req, res) => {
    res.json({ url: KIOSK_SERVER_URL, standbyUrl: KIOSK_SERVER_URL_STANDBY });
});

// SSH public key for kiosk deploy access — generates key pair on first call
app.get('/api/kiosks/deploy-pubkey', (req, res) => {
    const pubKeyPath = KIOSK_SSH_KEY + '.pub';
    if (!fs.existsSync(pubKeyPath)) {
        const dir = path.dirname(KIOSK_SSH_KEY);
        fs.mkdirSync(dir, { recursive: true });
        const gen = spawnSync('ssh-keygen', [
            '-t', 'ed25519', '-f', KIOSK_SSH_KEY, '-N', '', '-C', 'kiosk-deploy'
        ], { encoding: 'utf8' });
        if (gen.status !== 0) {
            return res.status(500).json({ error: 'Failed to generate SSH key: ' + gen.stderr });
        }
    }
    try {
        const pubkey = fs.readFileSync(pubKeyPath, 'utf8').trim();
        res.json({ pubkey, keyPath: KIOSK_SSH_KEY });
    } catch (e) {
        res.status(500).json({ error: e.message });
    }
});

// Deploy client runtime scripts to one kiosk machine
app.post('/api/kiosks/:id/deploy', (req, res) => {
    const id = parseInt(req.params.id);
    const kiosk = KIOSK_CLIENTS.find(k => k.id === id);
    if (!kiosk) return res.status(404).json({ error: 'Kiosk not found' });
    if (isLocalKioskTarget(kiosk.ip)) {
        return res.status(409).json({
            error: 'Self-deploy from the active admin host is not supported. Use the external deploy command instead.'
        });
    }
    if (!fs.existsSync(KIOSK_SSH_KEY)) {
        return res.status(400).json({
            error: 'SSH deploy key not found. Open the Deploy tab to generate it first.'
        });
    }
    const result = spawnSync('bash', [
        KIOSK_DEPLOY_SCRIPT,
        '--client',
        '--host', `${kiosk.user}@${kiosk.ip}`
    ], {
        encoding: 'utf8',
        timeout: 90000,
        env: {
            ...process.env,
            KIOSK_PRIMARY_URL: KIOSK_SERVER_URL,
            KIOSK_STANDBY_URL: KIOSK_SERVER_URL_STANDBY,
            KIOSK_SSH_KEY,
        },
    });
    const output = ((result.stdout || '') + (result.stderr || '')).trim();
    if (result.status !== 0) {
        return res.status(500).json({ error: 'Deploy failed', output });
    }
    res.json({ success: true, output });
});

const standbySyncInterval = setInterval(() => {
    if (!KIOSK_STANDBY_SYNC_ENABLED || !isPrimaryServerNode() || !getStandbySyncTarget()) return;
    if (standbySyncState.running || standbySyncState.timer) return;
    void runStandbySync('periodic-check');
}, KIOSK_STANDBY_SYNC_CHECK_MS);
if (typeof standbySyncInterval.unref === 'function') standbySyncInterval.unref();

if (KIOSK_STANDBY_SYNC_ENABLED && isPrimaryServerNode() && getStandbySyncTarget()) {
    const startupStandbySync = setTimeout(() => {
        if (standbySyncState.running || standbySyncState.timer) return;
        void runStandbySync('startup-check');
    }, 1000);
    if (typeof startupStandbySync.unref === 'function') startupStandbySync.unref();
}

// Start server
app.listen(PORT, HOST, () => {
    console.log(`Directory server running on port ${PORT}`);
    console.log(`Listening on ${HOST}:${PORT}`);
    console.log(`Kiosk interface: http://localhost/`);
    console.log(`Admin interface: http://localhost/admin`);
    console.log(`Revision: ${DEPLOY_REVISION} (${REVISION_SOURCE})`);
});

// Handle shutdown gracefully
process.on('SIGINT', () => {
    db.close((err) => {
        if (err) {
            console.error(err.message);
        }
        console.log('Database connection closed.');
        process.exit(0);
    });
});
