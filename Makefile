# SPDX-License-Identifier: CC0-1.0
# Shortcuts for the scripts in this repository. Run `make` for the list.
# Written for the make of the Xcode command line tools (GNU make 3.81); it
# also avoids GNU-only syntax, so BSD make works too.
#
# A line "name: ## text" puts the target in the list printed by `make help`,
# and a line "##@ text" starts a new group there.

# Seconds to fuzz for: make fuzz FUZZ_SECONDS=300
FUZZ_SECONDS = 60

.PHONY: help test test-python test-swift fuzz apps dmg install uninstall \
	driver driver-signed clean clean-all

help: ## Show this list
	@echo "Usage: make TARGET [VARIABLE=value ...]"
	@awk -F ':.*## ' \
		'/^##@ /{printf "\n%s\n", substr($$0, 5)} /^[a-z-]+:.*## /{printf "  %-14s %s\n", $$1, $$2}' \
		Makefile
	@echo
	@echo "Variables"
	@echo "  FUZZ_SECONDS      how long 'fuzz' runs (default 60)"
	@echo "  CXX               the clang++ that 'fuzz' uses"
	@echo "  DEVELOPMENT_TEAM  Apple developer team ID to sign with (apps, dmg,"
	@echo "                    install; required for driver-signed)"
	@echo "  SIGN_IDENTITY     exact certificate for apps, dmg and install"
	@echo "  NOTARY_PROFILE    notarytool profile; 'dmg' then notarises the image"
	@echo "  DESTINATION       folder for install and uninstall (default /Applications)"

##@ Tests

test: test-python ## All tests: Python everywhere, Swift too on macOS
	@if [ "$$(uname)" = Darwin ]; then \
		$(MAKE) test-swift; \
	else \
		echo "Not on macOS: Swift tests skipped."; \
	fi

test-python: ## Tests of the two Python tools against simulated modems
	python3 serial-driver/tools/test_quectel_at.py
	python3 qmi-userspace/test_qmi.py

test-swift: ## ModemKit unit tests (macOS)
	swift test --package-path modem-gui

fuzz: ## Fuzz the driver logic (needs an LLVM clang with libFuzzer)
	serial-driver/fuzz/run.sh $(FUZZ_SECONDS)

##@ Apps (macOS)

apps: ## Build QuectelMenu.app and QuectelDebug.app into modem-gui/build
	modem-gui/scripts/bundle.sh

dmg: ## Build the apps and pack them into modem-gui/build/QuectelApps.dmg
	modem-gui/scripts/bundle.sh --dmg

install: ## Build the apps and copy them into /Applications
	modem-gui/scripts/install.sh

uninstall: ## Remove the installed apps
	modem-gui/scripts/install.sh --uninstall

##@ Serial driver (macOS, needs XcodeGen)

driver: ## Compile the driver and installer unsigned (a check, not loadable)
	serial-driver/scripts/build.sh --unsigned

driver-signed: ## Signed development build (needs DEVELOPMENT_TEAM)
	serial-driver/scripts/build.sh

##@ Cleaning

clean: ## Remove what the targets above built
	rm -rf modem-gui/build serial-driver/build serial-driver/fuzz/build
	rm -rf serial-driver/QuectelSerial.xcodeproj
	find . -name __pycache__ -type d -prune -exec rm -rf {} +

clean-all: clean ## Also remove the SwiftPM cache and the fuzz corpus
	rm -rf modem-gui/.build serial-driver/fuzz/corpus
