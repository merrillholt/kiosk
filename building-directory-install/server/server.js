const express = require('express');
const sqlite3 = require('sqlite3').verbose();
const cors = require('cors');
const path = require('path');
const multer = require('multer');
const fs = require('fs');
const { spawnSync } = require('child_process');

const app = express();
const PORT = process.env.PORT || 3000;

// Temp dir for multer uploads (lost on reboot — persist script copies to lower layer)
const TEMP_DIR = process.env.KIOSK_TEMP_DIR || '/tmp/kiosk-uploads';
// Persistent uploads dir on ext4 lower layer (survives reboots via overlayroot)
const UPLOADS_LOWER = process.env.KIOSK_UPLOADS_LOWER || '/media/root-ro/home/merrill/building-directory/server/uploads';
// Persist command: space-separated argv[0..n], e.g. "/tmp/mock-persist.sh" for tests
const PERSIST_ARGV = process.env.KIOSK_PERSIST_CMD
    ? process.env.KIOSK_PERSIST_CMD.split(' ')
    : ['sudo', '/usr/local/bin/persist-upload.sh'];
fs.mkdirSync(TEMP_DIR, { recursive: true });

// Middleware
app.use(cors());
app.use(express.json());
app.use(express.static(path.join(__dirname, '../kiosk')));
app.use('/uploads', express.static(UPLOADS_LOWER));
app.use('/admin', express.static(path.join(__dirname, 'admin')));

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

// Database setup
const db = new sqlite3.Database('./directory.db', (err) => {
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
            res.json(row ? row.content : '');
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

function incrementDataVersion() {
    db.run('UPDATE settings SET value = value + 1, updated_at = CURRENT_TIMESTAMP WHERE key = "data_version"');
}

// Start server
app.listen(PORT, () => {
    console.log(`Directory server running on port ${PORT}`);
    console.log(`Kiosk interface: http://localhost:${PORT}/`);
    console.log(`Admin interface: http://localhost:${PORT}/admin`);
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
