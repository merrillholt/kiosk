---
title: "Building Directory — Admin User Guide"
---

# Building Directory — Admin User Guide

This guide covers day-to-day management of the building directory through the web
admin interface. Part 1 is written for building staff who add and update listings.
Part 2 covers advanced features for technical administrators.

---

# Part 1 — Quick Start for Building Staff

## 1. Accessing the Admin Interface

Open a web browser and go to:

**`http://192.168.1.80/admin`**

Any modern browser works (Chrome, Firefox, Edge, Safari). No special software is
required. The interface is designed to work on tablets as well as desktop computers.

> **Note:** The admin interface is only accessible from within the building network.
> You cannot reach it from outside the building.

## 2. Logging In

On the login page, enter the admin password and click **Log In**.

After a successful login you will be taken to the main admin dashboard, which shows
tabs for Companies, Individuals, Building Info, Images, Backup/Restore, and Deploy.

**Session details:**

- Your session stays active for **8 hours** from last use. You will be logged out
  automatically after 8 hours of inactivity.
- After **10 failed login attempts**, the account is locked out for 15 minutes.
- To log out manually, click the **Log Out** link in the top-right corner of any
  admin page.

## 3. Adding a Company

1. Click the **Companies** tab.
2. Click **Add Company**.
3. Fill in the fields:

   | Field | Required | Description |
   |-------|----------|-------------|
   | Name | Yes | Company name as it should appear in the directory |
   | Building | Yes | Building identifier (e.g. `A`, `Main`, `North`) |
   | Suite | Yes | Suite or unit number |
   | Floor | No | Floor number or label |
   | Phone | No | Main phone number for the company |

4. Click **Save**.

The new company will appear in the kiosk directory within approximately 60 seconds.

## 4. Editing a Company

1. Click the **Companies** tab.
2. Find the company in the list and click **Edit**.
3. Update the fields as needed.
4. Click **Save**.

## 5. Deleting a Company

1. Click the **Companies** tab.
2. Find the company and click **Delete**.
3. A confirmation dialog will appear — click **Confirm** to proceed.

> **Important:** Deleting a company does **not** delete any individuals associated
> with it. Those individuals remain in the directory but will no longer be linked to
> a company. You may want to reassign or delete them separately.

## 6. Adding an Individual

1. Click the **Individuals** tab.
2. Click **Add Individual**.
3. Fill in the fields:

   | Field | Required | Description |
   |-------|----------|-------------|
   | First Name | Yes | |
   | Last Name | Yes | |
   | Building | Yes | Building identifier |
   | Suite | Yes | Suite or unit number |
   | Title | No | Job title or role |
   | Phone | No | Direct phone number |
   | Company | No | Select from the dropdown to link to a company |

4. Click **Save**.

## 7. Editing an Individual

1. Click the **Individuals** tab.
2. Find the person in the list and click **Edit**.
3. Update the fields as needed.
4. Click **Save**.

## 8. Deleting an Individual

1. Click the **Individuals** tab.
2. Find the person and click **Delete**.
3. A confirmation dialog will appear — click **Confirm** to proceed.

## 9. Logging Out

Click **Log Out** in the top-right corner. You will be returned to the kiosk home
page. Close the browser tab when finished.

---

# Part 2 — Full Reference for Technical Administrators

## 10. CSV Bulk Import — Companies

The CSV import replaces the entire companies table in one operation. Use it to load
a large number of companies at once, or to do a full refresh from an external source.

**Workflow:**

1. Click the **Companies** tab, then **Download CSV Template**.
   The template contains the correct column headers and a sample row.
2. Edit the CSV in a spreadsheet application or text editor.
3. Return to the Companies tab and click **Import CSV**.
4. Select your file and click **Upload**.

**Columns:**

| Column | Required | Notes |
|--------|----------|-------|
| `name` | Yes | |
| `building` | Yes | |
| `suite` | Yes | |
| `phone` | No | Leave blank if not applicable |
| `floor` | No | Leave blank if not applicable |

**Behavior:**

- The import is **atomic**: either all rows succeed or none are written. A partial
  upload will never leave the database in a half-updated state.
- On error, the response identifies the **stage** (parse, validate, insert) and the
  **row number** where the problem occurred.
- The existing companies table is **replaced entirely**. Rows not present in the CSV
  will be removed.

## 11. CSV Bulk Import — Individuals

Works the same way as company import but targets the individuals table.

**Columns:**

| Column | Required | Notes |
|--------|----------|-------|
| `first_name` | Yes | |
| `last_name` | Yes | |
| `building` | Yes | |
| `suite` | Yes | |
| `title` | No | |
| `phone` | No | |
| `company_id` | No | Numeric ID of the linked company |
| `company_name` | No | Name of the linked company (case-insensitive) |

**Company resolution** (applied per row, in order):

1. If `company_id` is provided and matches an existing company, that company is used.
2. Otherwise, if `company_name` is provided, the system looks for a case-insensitive
   name match among current companies.
3. If neither resolves, the individual is saved with no company link (`NULL`).

The same atomic replacement behavior applies: all or nothing.

## 12. Building Info

1. Click the **Building Info** tab.
2. Edit the content in the text area. The field accepts **raw HTML**.
3. Click **Save**.

The building info panel on the kiosk displays the content exactly as entered,
including any HTML formatting tags.

> **Warning:** There is no HTML sanitization on the kiosk display. Ensure the
> content is correct and does not contain unintended markup. Invalid HTML may
> render incorrectly on the kiosk screen.

## 13. Background Images

The kiosk can display a custom background image. The admin interface shows a gallery
of available images.

**Accepted formats:** JPG, PNG, GIF, WebP
**Maximum file size:** 20 MB

**To upload a new image:**

1. Click the **Images** tab.
2. Click **Upload Image** and select a file.
3. The image is uploaded and automatically set as the active background.

**To switch the active image:**

- Click any image in the gallery to set it as active. The currently active image is
  highlighted.

**Deleting images:**

- Click the delete icon on an image to remove it.
- The **built-in default image cannot be deleted**.
- If the active image is deleted, the system falls back to the built-in default.

## 14. Backup and Restore

Use the **Backup/Restore** tab to safeguard database contents or migrate data.

### Download a Backup

Click **Download Text Backup**. The browser will download a `.txt` file containing
a plain-text SQL dump of the entire database. Store this file somewhere safe.

### Restore from Backup

1. Click **Choose File** and select your backup file.
   Accepted formats:
   - `.txt` or `.sql` — plain-text SQL dump (from this tool)
   - `.sqlite` or `.db` — binary SQLite file
2. Click **Restore**.
3. The system validates that the required tables are present in the backup.
4. On success, the database is replaced atomically and the response shows row counts
   for each table.

**Limits:** Maximum restore file size is 100 MB.

> **Warning:** Restore replaces the live database immediately. Download a fresh
> backup before restoring if you want to be able to undo.

## 15. Deploy Tab

The Deploy tab pushes the current kiosk software to one or more kiosk machines over
SSH.

### SSH Deploy Key

The server generates a dedicated SSH key pair for deployments. The key is
created on first load of the Deploy tab and stored at
`/data/directory/kiosk_deploy_key` on the server — the `/data` partition
is persistent across reboots. The public key is shown in the Deploy tab.

To authorise the server to deploy to a kiosk:

1. Click **Deploy** tab.
2. Copy the **public key** shown in the SSH Deploy Key section.
3. Log in to the target kiosk machine and append the public key to
   `~/.ssh/authorized_keys` for the kiosk user.

This only needs to be done once per kiosk machine. The key does not change
unless the key file at `/data/directory/kiosk_deploy_key` is deleted.

**If the Deploy tab shows "Failed to generate SSH key: Read-only file
system"**, the service is not configured with `KIOSK_SSH_KEY` pointing to
`/data/`. Check that `KIOSK_SSH_KEY=/data/directory/kiosk_deploy_key` is
set in `/etc/systemd/system/directory-server.service` (this requires writing
to the overlay lower layer via `overlayroot-chroot` or the deploy script).
See `docs/09-server-operations.md` for environment variable details.

### Kiosk Status

Each kiosk is listed with:

- **Overlay status** — whether the read-only overlay filesystem is active
- **Reachability** — whether the kiosk responded to the last status check

### Deploying

- **Deploy** (per-kiosk button) — pushes to that kiosk only.
- **Deploy to All** — pushes to every configured kiosk in sequence.

The output pane below the buttons shows live stdout and stderr from the deploy
script. A green status indicates success; red indicates an error. Review the output
if a deployment fails before retrying.

---

## Quick Reference

| Action | Tab | Time to appear on kiosk |
|--------|-----|--------------------------|
| Add / edit / delete company | Companies | ~60 seconds |
| Add / edit / delete individual | Individuals | ~60 seconds |
| Update building info | Building Info | ~60 seconds |
| Change background image | Images | ~60 seconds |
| CSV bulk import | Companies / Individuals | ~60 seconds after upload |
| Restore database | Backup/Restore | Immediate |
| Deploy software | Deploy | Immediate (per deploy run) |

Every change to the database automatically increments a version counter. Kiosks
check this counter every 60 seconds and reload data when it changes.
