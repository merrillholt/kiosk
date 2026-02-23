const express = require('express');
const sqlite3 = require('sqlite3').verbose();
const cors = require('cors');
const path = require('path');

const app = express();
const PORT = process.env.PORT || 3000;

// Middleware
app.use(cors());
app.use(express.json());
app.use(express.static(path.join(__dirname, '../kiosk')));
app.use('/admin', express.static(path.join(__dirname, 'admin')));

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
