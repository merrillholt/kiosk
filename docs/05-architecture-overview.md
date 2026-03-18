# Architecture Overview

## System Components

The building directory application consists of three main components:

```
+-------------------------------------------------------------+
|                     Kiosk Display                           |
|  +-----------------------------------------------------+    |
|  |                    Chromium                          |   |
|  |                  (Kiosk Mode)                        |   |
|  |  +---------+  +---------+  +---------------------+  |    |
|  |  |Companies|  |Individ- |  |    Building Info    |  |    |
|  |  |   Tab   |  |uals Tab |  |        Tab          |  |    |
|  |  +---------+  +---------+  +---------------------+  |    |
|  +-----------------------------------------------------+    |
+-------------------------------------------------------------+
                            |
                            | HTTP API calls
                            v
+-------------------------------------------------------------+
|                      Server                                 |
|  +--------------+    +--------------+    +--------------+   |
|  |   Node.js    |    |    Nginx     |    |    SQLite    |   |
|  |   Express    |<---|   Reverse    |    |   Database   |   |
|  |     API      |    |    Proxy     |    |              |   |
|  +--------------+    +--------------+    +--------------+   |
|         |                                       ^           |
|         +---------------------------------------+           |
+-------------------------------------------------------------+
                            |
                            | HTTP (port 80)
                            v
+-------------------------------------------------------------+
|                   Admin Interface                           |
|  +-----------------------------------------------------+    |
|  |              Web Browser (any device)                |   |
|  |                                                      |   |
|  |   • Manage companies                                |    |
|  |   • Manage individuals                              |    |
|  |   • Edit building information                       |    |
|  +-----------------------------------------------------+    |
+-------------------------------------------------------------+
```

## Technology Stack

| Component | Technology | Purpose |
|-----------|------------|---------|
| Frontend | HTML5, CSS3, Vanilla JS | Kiosk display interface |
| Backend | Node.js + Express | REST API server |
| Database | SQLite3 | Data storage |
| Web Server | Nginx | Reverse proxy, static files |
| Compositor | Cage (Wayland) | Kiosk window management |
| Browser | Chromium | Kiosk mode display |
| OS | Debian 13 | Base operating system |

## Deployed Architecture

```
    +--------------------------------------------------+
    |                     Network                       |
    +------+-----------------------------------+-------+
           |                                   |
  +--------+--------+                 +--------+--------+
  |  192.168.1.80   |                 |  192.168.1.81   |
  |  Qotom Q305P    |                 |  Intel NUC      |
  |  Primary        |                 |  Standby        |
  |                 |                 |                 |
  |  Chromium+Cage  |                 |  Chromium+Cage  |
  |  directory-     |                 |  directory-     |
  |  server         |                 |  server         |
  |  SQLite (live)  |                 |  SQLite (sync'd)|
  |  overlayroot    |                 |  overlayroot    |
  +-----------------+                 +-----------------+
           |
           |  DB sync (periodic)
           v
  +----------------------------------------------------+
  |  Dev machine: /home/security/Public-Kiosk          |
  |  Deploys to .80 and .81 via tools/deploy-ssh.sh    |
  +----------------------------------------------------+
```

Production kiosks are configured with a primary server URL of
`http://192.168.1.80` and a standby URL of `http://192.168.1.81`. On boot, the
kiosk waits for the primary and falls back to the standby if the primary is
unreachable (`SERVER_URL` / `SERVER_URL_STANDBY` in `start-kiosk.sh`).

`localhost` is only used as the installer-time default for a fresh host
installed in "Both Server and Client" mode before production deployment rewrites
`start-kiosk.sh`. A client-only host such as `.82` should use network server
URLs, not `localhost`.

`192.168.1.82` is reserved for a second Qotom Q305P (identical to `.80`).

## Data Flow

### Read Operations (Kiosk Display)

```
1. User taps "Companies" tab
2. Chromium loads cached data from localStorage
3. Background: check /api/data-version every 60 seconds
4. If version changed:
   - Fetch /api/companies
   - Update localStorage cache
   - Refresh display
```

### Write Operations (Admin Interface)

```
1. Admin adds new company via web form
2. POST /api/companies with JSON data
3. Server validates and inserts into SQLite
4. Server increments data_version
5. Kiosks detect version change on next sync
6. Kiosks fetch updated data
```

## File Structure (Production Host)

```
/home/kiosk/building-directory/         ← application root
+-- kiosk/                              ← kiosk display frontend
|   +-- index.html
|   +-- app.js
|   +-- styles.css
+-- server/                             ← backend API
|   +-- server.js
|   +-- package.json
|   +-- directory.db → /data/directory/directory.db   ← production symlink to live DB
|   +-- admin/                          ← admin interface
|       +-- index.html
|       +-- admin.js
|       +-- admin.css
+-- scripts/                            ← ops scripts
|   +-- start-kiosk.sh
|   +-- backup.sh
|   +-- restore-db.sh
|   +-- production-ops.sh
+-- REVISION                            ← deployed git revision

/data/                                  ← persistent partition (always rw)
+-- directory/directory.db              ← live SQLite database
+-- backups/building-directory/         ← timestamped DB backups
+-- logs/                               ← persistent application logs
```

In steady-state production, `server/directory.db` resolves to the live database
on `/data/directory/directory.db`. The root filesystem (`/`) is read-only under
overlayroot. `/data` is a separate ext4 partition mounted read-write and is
never overlaid. See `docs/03-read-only-filesystem.md`.

## Database Schema

```sql
CREATE TABLE companies (
    id INTEGER PRIMARY KEY,
    name TEXT NOT NULL,
    building TEXT,
    suite TEXT,
    phone TEXT,
    floor TEXT,
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
    updated_at DATETIME DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE individuals (
    id INTEGER PRIMARY KEY,
    first_name TEXT NOT NULL,
    last_name TEXT NOT NULL,
    company_id INTEGER REFERENCES companies(id),
    building TEXT,
    suite TEXT,
    title TEXT,
    phone TEXT,
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
    updated_at DATETIME DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE building_info (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    title TEXT NOT NULL,
    content TEXT NOT NULL,
    display_order INTEGER DEFAULT 0,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE settings (
    key TEXT PRIMARY KEY,
    value TEXT,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);
```

## API Endpoints

| Method | Endpoint | Auth | Purpose |
|--------|----------|------|---------|
| GET | `/api/companies` | IP allowlist | List all companies |
| GET | `/api/companies/search?q=` | IP allowlist | Search companies |
| POST | `/api/companies` | Session | Create company |
| PUT | `/api/companies/:id` | Session | Update company |
| DELETE | `/api/companies/:id` | Session | Delete company |
| GET | `/api/individuals` | IP allowlist | List all individuals |
| GET | `/api/individuals/search?q=` | IP allowlist | Search individuals |
| POST | `/api/individuals` | Session | Create individual |
| PUT | `/api/individuals/:id` | Session | Update individual |
| DELETE | `/api/individuals/:id` | Session | Delete individual |
| GET | `/api/building-info` | IP allowlist | Get building info |
| PUT | `/api/building-info` | Session | Update building info |
| GET | `/api/data-version` | IP allowlist | Check for updates |
| GET | `/api/backup.txt` | Session | Download SQL backup |
| POST | `/api/restore` | Session | Restore from backup |
| POST | `/api/auth/login` | — | Authenticate |
| GET | `/api/auth/me` | — | Session status |

## Sync Mechanism

Kiosks check for updates every 60 seconds:

```javascript
// In kiosk app.js
const REFRESH_INTERVAL = 60000;

async function checkForUpdates() {
    const response = await fetch(`${CONFIG.API_URL}/data-version`);
    const { version } = await response.json();

    if (version !== localStorage.getItem('data_version')) {
        await refreshAllData();
        localStorage.setItem('data_version', version);
    }
}

setInterval(checkForUpdates, REFRESH_INTERVAL);
```

## Offline Capability

All data is cached in localStorage. If the server is unreachable the kiosk
continues displaying cached data and falls back to the standby server URL
configured in `scripts/start-kiosk.sh`.
