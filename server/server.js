const express = require('express');
const sqlite3 = require('sqlite3').verbose();
const path = require('path');
const multer = require('multer');
const fs = require('fs');
const os = require('os');
const crypto = require('crypto');
const { spawnSync } = require('child_process');

const app = express();
const PORT = process.env.PORT || 3000;
const HOST = process.env.HOST || '127.0.0.1';

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
    '/kiosk-location'
]);
const ADMIN_PASSWORD = process.env.KIOSK_ADMIN_PASSWORD || 'kiosk';
const SESSION_COOKIE = 'kiosk_admin_session';
const SESSION_TTL_MS = 8 * 60 * 60 * 1000; // 8 hours
const adminSessions = new Map();
const ALLOW_DEFAULT_PASSWORD = process.env.KIOSK_ALLOW_DEFAULT_PASSWORD === 'true';
const LOGIN_WINDOW_MS = Number.parseInt(process.env.KIOSK_LOGIN_WINDOW_MS || '', 10) || (15 * 60 * 1000);
const LOGIN_MAX_ATTEMPTS = Number.parseInt(process.env.KIOSK_LOGIN_MAX_ATTEMPTS || '', 10) || 10;
const LOGIN_BLOCK_MS = Number.parseInt(process.env.KIOSK_LOGIN_BLOCK_MS || '', 10) || (15 * 60 * 1000);
const loginAttempts = new Map();
// SSH private key used to connect to kiosk machines for deployment
const KIOSK_SSH_KEY = process.env.KIOSK_SSH_KEY ||
    path.join(os.homedir(), '.ssh', 'kiosk_deploy_key');
// URL kiosk machines use to reach this server (auto-detected if not set)
const KIOSK_SERVER_URL = process.env.KIOSK_SERVER_URL || (() => {
    try {
        const interfaces = os.networkInterfaces() || {};
        for (const iface of Object.values(interfaces)) {
            if (!Array.isArray(iface)) continue;
            for (const addr of iface) {
                if (addr && addr.family === 'IPv4' && !addr.internal) return `http://${addr.address}`;
            }
        }
    } catch (err) {
        console.warn('Could not auto-detect network interface for KIOSK_SERVER_URL:', err.message);
    }
    return 'http://localhost';
})();
const KIOSK_DEPLOY_SCRIPT = path.join(__dirname, 'kiosk-deploy.sh');
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
    if (!ALLOW_DEFAULT_PASSWORD) {
        console.error('FATAL: Default admin password "kiosk" is active.');
        console.error('Set KIOSK_ADMIN_PASSWORD to a strong value, or set KIOSK_ALLOW_DEFAULT_PASSWORD=true for dev only.');
        process.exit(1);
    }
    console.warn('WARNING: Default password "kiosk" is active (KIOSK_ALLOW_DEFAULT_PASSWORD=true).');
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

        // Set initial data version
        db.run(`INSERT OR IGNORE INTO settings (key, value) VALUES ('data_version', '1')`);
        // Set initial background image
        db.run(`INSERT OR IGNORE INTO settings (key, value) VALUES ('background_image', '18.jpg')`);

        console.log('Database initialized');
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
    db.run('DELETE FROM companies WHERE id = ?', [req.params.id], (err) => {
        if (err) {
            res.status(500).json({ error: err.message });
        } else {
            incrementDataVersion();
            res.json({ success: true });
        }
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
    const filename = req.file.filename;
    const result = spawnSync(PERSIST_ARGV[0], [...PERSIST_ARGV.slice(1), 'copy', req.file.path, filename]);
    if (result.status !== 0) {
        return res.status(500).json({ error: 'Failed to persist file: ' + (result.stderr ? result.stderr.toString().trim() : 'unknown error') });
    }
    const dbKey = `uploads/${filename}`;
    db.run(
        `INSERT OR REPLACE INTO settings (key, value, updated_at) VALUES ('background_image', ?, CURRENT_TIMESTAMP)`,
        [dbKey],
        (err) => {
            if (err) return res.status(500).json({ error: err.message });
            incrementDataVersion();
            res.json({ success: true, filename: dbKey });
        }
    );
});

// Background image — set active from gallery
app.put('/api/background-image', (req, res) => {
    const { filename } = req.body;
    if (!filename) return res.status(400).json({ error: 'filename required' });
    db.run(
        `INSERT OR REPLACE INTO settings (key, value, updated_at) VALUES ('background_image', ?, CURRENT_TIMESTAMP)`,
        [filename],
        (err) => {
            if (err) return res.status(500).json({ error: err.message });
            incrementDataVersion();
            res.json({ success: true });
        }
    );
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
            res.json({ version: parseInt(row.value) });
        }
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

// Kiosk location metadata for welcome screen line 3
app.get('/api/kiosk-location', (req, res) => {
    const rawIp = req.ip || req.socket.remoteAddress || '';
    const clientIp = rawIp.startsWith('::ffff:') ? rawIp.slice(7) : rawIp;
    const buildingSuffix = mapKioskBuildingSuffix(clientIp);
    res.json({
        ip: clientIp,
        buildingSuffix,
        buildingCode: `430${buildingSuffix}`
    });
});

function incrementDataVersion() {
    db.run('UPDATE settings SET value = value + 1, updated_at = CURRENT_TIMESTAMP WHERE key = "data_version"');
}

// Kiosk client management

// List kiosk display clients
app.get('/api/kiosks', (req, res) => {
    res.json(KIOSK_CLIENTS.map(k => ({ id: k.id, name: k.name, ip: k.ip, user: k.user })));
});

// Server URL that kiosk machines should use to reach this server
app.get('/api/kiosks/server-url', (req, res) => {
    res.json({ url: KIOSK_SERVER_URL });
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

// Deploy system scripts to one kiosk machine
app.post('/api/kiosks/:id/deploy', (req, res) => {
    const id = parseInt(req.params.id);
    const kiosk = KIOSK_CLIENTS.find(k => k.id === id);
    if (!kiosk) return res.status(404).json({ error: 'Kiosk not found' });
    if (!fs.existsSync(KIOSK_SSH_KEY)) {
        return res.status(400).json({
            error: 'SSH deploy key not found. Open the Deploy tab to generate it first.'
        });
    }
    const result = spawnSync('bash', [
        KIOSK_DEPLOY_SCRIPT, kiosk.ip, kiosk.user, KIOSK_SSH_KEY, KIOSK_SERVER_URL
    ], { encoding: 'utf8', timeout: 90000 });
    const output = ((result.stdout || '') + (result.stderr || '')).trim();
    if (result.status !== 0) {
        return res.status(500).json({ error: 'Deploy failed', output });
    }
    res.json({ success: true, output });
});

// Start server
app.listen(PORT, HOST, () => {
    console.log(`Directory server running on port ${PORT}`);
    console.log(`Listening on ${HOST}:${PORT}`);
    console.log(`Kiosk interface: http://localhost/`);
    console.log(`Admin interface: http://localhost/admin`);
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
