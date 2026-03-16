# Hardware Requirements

## Deployed Hardware

### Qotom Q305P — Primary server + display (192.168.1.80)

| Spec | Value |
|------|-------|
| CPU | Intel Celeron 3205U, 2M Cache, 1.50 GHz |
| RAM | 1x DDR3L SODIMM slot, max 8GB, 1333/1600 MHz |
| Storage | 1x mSATA SSD slot + 1x 2.5" HDD/SSD bay |
| Graphics | Intel HD Graphics (integrated) |
| Network | Dual Intel Gigabit LAN |
| USB | 4x USB 3.0 (rear), 2x USB 2.0 (front) |
| Video output | 2x HDMI (rear) |
| Serial ports | 4x RS-232 rear + 2x RS-232 front (COM1–6) |
| Power | 12V DC, 4A (5.5mm/2.5mm jack) |
| Cooling | **Fanless** — aluminium alloy chassis |
| Dimensions | 155 × 127 × 48mm |
| VESA mount | Yes (bracket included) |
| OS support | Linux |

Reference docs: `docs/hardware/Mini PC Q300X S05 Series-Multi-Serial Port Series-Qotom Mini PC.pdf`, `docs/hardware/Qotom Q305P_Q310P Mini PC User Manual.pdf`

---

### Intel NUC DC3217IYE — Standby server + display (192.168.1.81)

| Spec | Value |
|------|-------|
| CPU | Intel Core i3-3217U, 3M Cache, 1.80 GHz (2 cores/4 threads) |
| Chipset | Mobile Intel QS77 Express |
| RAM | 2x DDR3 SODIMM slots, max 16GB, 1333/1600 MHz 1.5V |
| Storage | **mSATA only** — 1x full-length Mini PCIe (mSATA) |
| Graphics | Intel HD Graphics 4000 (i915 driver) |
| Network | Intel 10/100/1000 Gigabit (single port) |
| USB | 5x USB 2.0 total (3 external + 2 internal) — **no USB 3.0** |
| Video output | **Dual HDMI** (2 independent displays) |
| Serial ports | None |
| Power | 19V DC (external 65W brick) |
| Cooling | **Active (fan)** |
| Dimensions | 116.6 × 112.0 × 39.0mm (UCFF 4"×4") |
| VESA mount | Yes |
| TPM | No |
| AES-NI | No |
| Marketing status | Discontinued (launched Q4'12) |

Reference doc: `docs/hardware/Intel® NUC Kit DC3217IYE.pdf`

---

### Jetway JBC372F36 — Reserved server + display (192.168.1.82)

| Spec | Value |
|------|-------|
| CPU | Intel Atom N2600, 1.60 GHz, Dual-Core, 3.5W |
| Chipset | Intel NM10 Express |
| RAM | 1x DDR3-800 SODIMM slot, max 2GB |
| Storage | 1x 2.5" SATA3 6Gb/s bay + 1x CFast slot |
| Graphics | Intel GMA 3600 (Full HD 1080p) |
| Network | 2x Realtek RTL8111EVL PCIe Gigabit LAN |
| USB | 4x USB 2.0 (rear) + 2x USB 2.0 (front) — **no USB 3.0** |
| Video output | **DVI-I only** (DVI-to-VGA adapter included) — **no HDMI** |
| Serial ports | 2x RS-232 rear (RJ45) + 2x RS-232 front (DB9) |
| Power | 12V DC, 60W adapter |
| Cooling | **Fanless** |
| Dimensions | 180 × 142.6 × 48mm |
| VESA mount | Optional kit |
| Watchdog | Yes (hardware) |
| WiFi | Optional (Mini-PCIe slot) |

**Important:** DVI-I video output only — requires a DVI-to-HDMI active adapter or a DVI-compatible touchscreen display. Do not assume HDMI connectivity without the adapter.

Reference doc: `docs/hardware/JBC372F36.pdf`

---

## Hardware Comparison

| | Qotom Q305P (.80) | NUC DC3217IYE (.81) | Jetway JBC372F36 (.82) |
|--|--|--|--|
| Role | Primary server + display | Standby server + display | Reserved |
| CPU | Celeron 3205U (Broadwell) | Core i3-3217U (Ivy Bridge) | Atom N2600 (Cedar Trail) |
| Cooling | Fanless | Fan (active) | Fanless |
| Storage interface | mSATA + 2.5" SATA | mSATA only | 2.5" SATA + CFast |
| USB | USB 3.0 available | USB 2.0 only | USB 2.0 only |
| RAM max | 8GB DDR3L | 16GB DDR3 | 2GB DDR3 |
| Dual NIC | Yes (2 ports) | No (1 port) | Yes (2 ports) |
| Video output | 2x HDMI | 2x HDMI | DVI-I only |
| Power brick | 12V | 19V — do not mix | 12V |

**Do not interchange power supplies** — the NUC uses 19V; Qotom and Jetway use 12V (incompatible).

---

## Display Requirements

- Capacitive touchscreen (preferred over resistive)
- 1920×1080 resolution
- HDMI input
- USB HID touch connection (separate from video cable)
- VESA mount compatible

See `docs/07-touchscreen-setup.md` for driver and calibration details.
See `docs/elo-cage-wayland-kiosk-hardening.md` for Elo 3239L-specific configuration.

## Network Requirements

- Wired Ethernet (WiFi not recommended for permanent installation)
- DHCP reservation per host to maintain stable IPs
- Static assignment: `.80` = primary (Qotom Q305P), `.81` = standby (NUC DC3217IYE), `.82` = reserved (Jetway JBC372F36)

## Storage Sizing

Minimal Debian 13 + Node.js + Chromium + application uses approximately 8–12GB.
The `/data` partition for database and backups needs at minimum 2GB; 6–8GB recommended.

| Partition | Minimum | Recommended |
|-----------|---------|-------------|
| `/` (root, overlayroot) | 16GB | 20GB+ |
| `/data` (persistent) | 2GB | 6–8GB |
| swap | 1GB | 2GB |
