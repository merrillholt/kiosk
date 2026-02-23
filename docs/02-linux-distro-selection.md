# Linux Distribution Selection

## Recommended Distros for Kiosk Use

### Tier 1: Best Fit for This Project

| Distro | Base Install | RAM Idle | Support Cycle |
|--------|-------------|----------|---------------|
| **Debian 13 (Trixie)** | ~2-3 GB | ~150 MB | 5 years (~2030) |
| **Ubuntu Server 24.04 LTS minimal** | ~4-5 GB | ~200 MB | 10 years |
| **Alpine Linux** | ~130 MB | ~50 MB | 2 years |

---

## Debian 13 (Trixie) Stable - RECOMMENDED

**Advantages:**
- Rock-solid stability (packages tested extensively before release)
- Minimal bloat - you install only what you need
- 5-year support lifecycle (until ~2030)
- Excellent for "set and forget" deployments
- Smaller footprint than Ubuntu
- No snaps or commercial steering
- Install scripts work with minimal changes
- Current stable release with newest kernel and better hardware support

**Disadvantages:**
- Packages can be 1-2 years behind (not an issue for kiosks)
- Slightly less beginner-friendly documentation than Ubuntu
- Security updates only, no feature backports

**Best for:** Production kiosks where stability matters most

---

## Ubuntu Server 24.04 LTS (minimal install)

**Advantages:**
- Excellent documentation and huge community
- 10-year support with Ubuntu Pro (free for up to 5 machines)
- Easiest to find answers to problems
- Install scripts already target this
- Livepatch for kernel updates without reboots
- Familiar tooling (apt, systemd)

**Disadvantages:**
- Snap packages can consume extra storage and RAM
- Slightly heavier than Debian
- Some Canonical-specific quirks
- Telemetry enabled by default (can disable)

**Best for:** Easiest path to deployment, good community support

---

## Alpine Linux

**Advantages:**
- Extremely lightweight (~130MB base system)
- Boots in seconds
- Security-focused (PaX, PIE, stack-smashing protection)
- Perfect for 32GB storage constraint
- Read-only root filesystem easy to configure
- Uses OpenRC (simpler than systemd)

**Disadvantages:**
- Uses musl libc instead of glibc (occasional compatibility issues)
- Different package manager (apk vs apt)
- Smaller community, less documentation
- Chromium may need extra configuration
- Steeper learning curve

**Best for:** Maximizing limited storage, security-conscious deployments

---

## Tier 2: Specialized Options

| Distro | Use Case | Trade-off |
|--------|----------|-----------|
| **Fedora IoT** | Immutable OS with atomic updates | Shorter support (13 months) |
| **openSUSE MicroOS** | Transactional updates, auto-rollback | Smaller community |
| **Porteus Kiosk** | Turnkey kiosk solution | Limited flexibility, commercial |

---

## Fedora IoT

**Advantages:**
- Immutable filesystem (can't be corrupted)
- Atomic updates with automatic rollback on failure
- OSTree-based - easy to replicate across multiple kiosks
- Modern packages
- Greenboot health checks

**Disadvantages:**
- 13-month support cycle (must upgrade regularly)
- Heavier than Debian/Alpine
- Different paradigm (rpm-ostree vs apt)
- Less kiosk-specific documentation

**Best for:** Bulletproof updates with automatic rollback

---

## Porteus Kiosk

**Advantages:**
- Purpose-built for kiosk use cases
- Runs entirely from RAM (SSD barely touched)
- Read-only by design - power loss safe
- Web-based configuration wizard
- Automatic Chromium kiosk mode

**Disadvantages:**
- Less flexible for custom applications
- Commercial support requires payment
- Closed development model
- Harder to add Node.js backend components

**Best for:** Simple web-only kiosks (not ideal for this project due to local server component)

---

## Final Recommendation

```
┌─────────────────────────────────────────────────────────┐
│                                                         │
│   Debian 13 Stable (minimal + Chromium + Node.js)      │
│                                                         │
│   • Best stability for 24/7 operation                   │
│   • Fits comfortably in 32GB                           │
│   • 5-year support (until ~2030)                       │
│   • Easy to configure read-only root                   │
│   • Install scripts need minimal changes               │
│                                                         │
└─────────────────────────────────────────────────────────┘
```

**Second choice:** Ubuntu Server 24.04 LTS minimal - better documentation and community support.

**Third choice:** Alpine Linux - maximum headroom on 32GB SSD.
