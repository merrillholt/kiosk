SHELL := /bin/bash

.PHONY: drift sync package package-clean deploy-local deploy-local-full deploy-ssh deploy-ssh-full sync-primary-db docs docs-all docs-clean

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


deploy-ssh:
	tools/deploy-ssh.sh


deploy-ssh-full:
	tools/deploy-ssh.sh --full


sync-primary-db:
	tools/sync-primary-db.sh

docs-all:
	tools/print-docs.sh all

docs-clean:
	rm -rf dist/docs/

docs:
	@tools/print-docs.sh --list
