PREFIX ?= $(HOME)/.local

APP = net-doctor.app
BIN = $(APP)/Contents/MacOS/wifiinfo

# The helper lives in a minimal app bundle because macOS only shows the Location
# Services prompt (needed for network names) to bundled, signed apps; a bare binary
# is silently denied.
$(BIN): wifiinfo.swift Info.plist
	mkdir -p $(APP)/Contents/MacOS
	cp Info.plist $(APP)/Contents/Info.plist
	swiftc -O -o $(BIN) wifiinfo.swift
	codesign --force --sign - $(APP)

install: $(BIN)
	mkdir -p $(PREFIX)/bin
	ln -sf $(CURDIR)/net $(PREFIX)/bin/net

uninstall:
	rm -f $(PREFIX)/bin/net

clean:
	rm -rf $(APP)

.PHONY: install uninstall clean
