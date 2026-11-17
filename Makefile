PREFIX ?= $(HOME)/.local

APP = net-doctor.app
BIN = $(APP)/Contents/MacOS/wifiinfo
# Sign with a real identity when one exists so the Location Services grant survives
# rebuilds (an ad-hoc signature changes every build and macOS then forgets the grant).
SIGN ?= $(shell security find-identity -v -p codesigning 2>/dev/null | awk -F'"' 'NR==1 && $$2 != "" {print $$2}')
ifeq ($(SIGN),)
SIGN = -
endif

# The helper lives in a minimal app bundle because macOS only shows the Location
# Services prompt (needed for network names) to bundled, signed apps; a bare binary
# is silently denied.
$(BIN): wifiinfo.swift Info.plist
	mkdir -p $(APP)/Contents/MacOS
	cp Info.plist $(APP)/Contents/Info.plist
	swiftc -O -o $(BIN) wifiinfo.swift
	codesign --force --sign "$(SIGN)" $(APP)

install: $(BIN)
	mkdir -p $(PREFIX)/bin
	ln -sf $(CURDIR)/net $(PREFIX)/bin/net

uninstall:
	rm -f $(PREFIX)/bin/net

clean:
	rm -rf $(APP)

.PHONY: install uninstall clean
