# Building Directory Documentation

This project has separate documentation by scope.

Current Markdown docs in this folder are the primary operating instructions.
TeX and other legacy/reference documents may lag behind the current install and
deploy flow. If documents disagree and the question is about real deployed
behavior, verify the production system on `192.168.1.80`.

When the install tree is regenerated with `./tools/sync-install-tree.sh`, PDF
versions of the documentation are rebuilt into `building-directory-install/docs/`.

The packaged install tree now has two final PDFs:
- `building-directory-admin-guide.pdf`
- `building-directory-development-guide.pdf`

It also keeps individual development PDFs as reference copies.

## Primary By Scope

- **New host installation (all phases):** [10-new-host-installation.md](10-new-host-installation.md)
- **Client environment setup:** [10-new-host-installation.md](10-new-host-installation.md), [06-desktop-environment.md](06-desktop-environment.md), [07-touchscreen-setup.md](07-touchscreen-setup.md)
- **Server operations:** [09-server-operations.md](09-server-operations.md)
- **Server and packaging/deploy workflow:** [08-packaging-and-deploy.md](08-packaging-and-deploy.md)
- **System architecture overview:** [05-architecture-overview.md](05-architecture-overview.md)
- **Development environment workflow:** [04-development-environment.md](04-development-environment.md)

## Supporting Docs

- [debian13_kiosk_updated_docs.md](debian13_kiosk_updated_docs.md)
- [01-hardware-requirements.md](01-hardware-requirements.md)
- [03-read-only-filesystem.md](03-read-only-filesystem.md)
- [06-desktop-environment.md](06-desktop-environment.md)
- [07-touchscreen-setup.md](07-touchscreen-setup.md)

## Install/Deploy Entry Points

- Installer: `building-directory-install/install.sh`
- Read-only setup: `building-directory-install/readonly/`
- Deployment guide: [08-packaging-and-deploy.md](08-packaging-and-deploy.md)

## Archive

- `docs/archive/` contains legacy/reference artifacts.
- [archive/02-linux-distro-selection.md](archive/02-linux-distro-selection.md) — pre-decision OS comparison (Debian 13 selected)
- [archive/Debian 13 Configuration legacy.tex](archive/Debian%2013%20Configuration%20legacy.tex) — legacy/reference guide; verify against the current Markdown docs before using
- [archive/Enterprise_Kiosk_Deployment_Guide_v2.tex](archive/Enterprise_Kiosk_Deployment_Guide_v2.tex) — legacy/reference guide from the pre-current deploy workflow
