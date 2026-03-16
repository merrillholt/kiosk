# Architecture Overview

## System Components

The building directory application consists of three main components:

```
┌─────────────────────────────────────────────────────────────┐
│                     Kiosk Display                            │
│  ┌─────────────────────────────────────────────────────┐    │
│  │                    Chromium                          │    │
│  │                  (Kiosk Mode)                        │    │
│  │  ┌─────────┐  ┌─────────┐  ┌─────────────────────┐  │    │
│  │  │Companies│  │Individ- │  │    Building Info    │  │    │
│  │  │   Tab   │  │uals Tab │  │        Tab          │  │    │
│  │  └─────────┘  └─────────┘  └─────────────────────┘  │    │
│  │  ┌─────────────────────────────────────────────┐    │    │
│  │  │           On-Screen Keyboard                │    │    │
│  │  └─────────────────────────────────────────────┘    │    │
│  └─────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────┘
                            │
                            │ HTTP API calls
                            ▼
┌─────────────────────────────────────────────────────────────┐
│                      Server                                  │
│  ┌──────────────┐    ┌──────────────┐    ┌──────────────┐   │
│  │   Node.js    │    │    Nginx     │    │    SQLite    │   │
│  │   Express    │◄───│   Reverse    │    │   Database   │   │
│  │     API      │    │    Proxy     │    │              │   │
│  └──────────────┘    └──────────────┘    └──────────────┘   │
│         │                                       ▲            │
│         └───────────────────────────────────────┘            │
└─────────────────────────────────────────────────────────────┘
                            │
                            │ HTTP (port 80)
                            ▼
┌─────────────────────────────────────────────────────────────┐
│                   Admin Interface                            │
│  ┌─────────────────────────────────────────────────────┐    │
│  │              Web Browser (any device)                │    │
│  │                                                      │    │
│  │   • Manage companies                                │    │
│  │   • Manage individuals                              │    │
│  │   • Edit building information                       │    │
│  └─────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────┘
```

## Technology Stack

| Component | Technology | Purpose |
|-----------|------------|---------|
| Frontend | HTML5, CSS3, Vanilla JS | Kiosk display interface |
| Backend | Node.js + Express | REST API server |
| Database | SQLite3 | Data storage |
| Web Server | Nginx | Reverse proxy, static files |
| Browser | Chromium | Kiosk mode display |
| OS | Debian 13 | Base operating system |

## Deployment Architecture

### Three-Kiosk Setup (Recommended)

```
                                    ┌─────────────────┐
                                    │  Admin Computer │
                                    │  (web browser)  │
                                    └────────┬────────┘
                                             │
    ┌────────────────────────────────────────┼────────────────────────────────────────┐
    │                                   Network                                        │
    └────────┬───────────────────────────────┼───────────────────────────┬────────────┘
             │                               │                           │
    ┌────────┴────────┐             ┌────────┴────────┐         ┌────────┴────────┐
    │    Kiosk 1      │             │    Kiosk 2      │         │    Kiosk 3      │
    │  (Read-only)    │             │  (Read-only)    │         │  (Read-only)    │
    │                 │             │                 │         │                 │
    │  ┌───────────┐  │             │  ┌───────────┐  │         │  ┌───────────┐  │
    │  │ Chromium  │  │             │  │ Chromium  │  │         │  │ Chromium  │  │
    │  │  Kiosk    │  │             │  │  Kiosk    │  │         │  │  Kiosk    │  │
    │  └───────────┘  │             │  └───────────┘  │         │  └───────────┘  │
    │        ↓        │             │        ↓        │         │        ↓        │
    │    Server       │◄─ sync ─────┤    Cache        │── sync ─┤    Cache        │
    │    + SQLite     │             │  (localStorage) │         │  (localStorage) │
    │                 │             │                 │         │                 │
    └─────────────────┘             └─────────────────┘         └─────────────────┘
           │
           └── One kiosk runs the server, others connect to it
```

### Alternative: Dedicated Server

```
    ┌─────────────────┐
    │  Server Machine │
    │  (always on)    │
    └────────┬────────┘
             │
    ┌────────┼────────┬────────────┐
    │        │        │            │
    ▼        ▼        ▼            ▼
 Kiosk 1  Kiosk 2  Kiosk 3    Admin PC
```

## Data Flow

### Read Operations (Kiosk Display)

```
1. User taps "Companies" tab
2. Chromium loads cached data from localStorage
3. Background: Check /api/data-version
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

## File Structure

```
building-directory/
├── kiosk/                    # Kiosk display frontend
│   ├── index.html
│   ├── app.js
│   └── styles.css
├── server/                   # Backend API
│   ├── server.js
│   ├── package.json
│   ├── directory.db          # SQLite database
│   └── admin/                # Admin interface
│       ├── index.html
│       ├── admin.js
│       └── admin.css
├── scripts/                  # Utility scripts
│   ├── start-kiosk.sh
│   ├── restart-kiosk.sh
│   ├── backup.sh
│   ├── restore-db.sh
│   └── production-ops.sh
├── docs/                     # Documentation
└── building-directory-install/
    ├── install.sh            # Main installer
    └── readonly/             # Read-only FS setup
```

## Database Schema

```sql
-- Companies directory
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

-- Individuals directory
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

-- Building information pages
CREATE TABLE building_info (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    title TEXT NOT NULL,
    content TEXT NOT NULL,
    display_order INTEGER DEFAULT 0,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Configuration settings
CREATE TABLE settings (
    key TEXT PRIMARY KEY,
    value TEXT,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);
```

## API Endpoints

| Method | Endpoint | Purpose |
|--------|----------|---------|
| GET | `/api/companies` | List all companies |
| GET | `/api/companies/search?q=` | Search companies |
| POST | `/api/companies` | Create company |
| PUT | `/api/companies/:id` | Update company |
| DELETE | `/api/companies/:id` | Delete company |
| GET | `/api/individuals` | List all individuals |
| GET | `/api/individuals/search?q=` | Search individuals |
| POST | `/api/individuals` | Create individual |
| PUT | `/api/individuals/:id` | Update individual |
| DELETE | `/api/individuals/:id` | Delete individual |
| GET | `/api/building-info` | Get building info |
| PUT | `/api/building-info` | Update building info |
| GET | `/api/data-version` | Check for updates |

## Sync Mechanism

Kiosks check for updates every 60 seconds:

```javascript
// In kiosk app.js
const REFRESH_INTERVAL = 60000; // 60 seconds

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

All data is cached in localStorage:

```javascript
// Cache structure
localStorage.setItem('companies', JSON.stringify(companiesArray));
localStorage.setItem('individuals', JSON.stringify(individualsArray));
localStorage.setItem('building_info', JSON.stringify(buildingInfoArray));
localStorage.setItem('data_version', versionString);
```

If the server is unreachable, the kiosk continues displaying cached data and can fall back to the standby server URL configured in `scripts/start-kiosk.sh`.
