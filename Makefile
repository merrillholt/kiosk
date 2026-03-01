SHELL := /bin/bash

.PHONY: drift sync package package-clean deploy-local deploy-local-full

drift:
	tools/check-install-drift.sh

sync:
	tools/sync-install-tree.sh

package:
	tools/package-install.sh

package-clean:
	rm -rf dist/install/building-directory-install dist/building-directory-install.zip


deploy-local:
	tools/deploy-local.sh


deploy-local-full:
	tools/deploy-local.sh --full
