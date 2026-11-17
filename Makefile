PREFIX ?= $(HOME)/.local

# The embedded Info.plist carries the location usage description; without it macOS
# silently refuses to show the Location Services prompt for a command-line binary.
wifiinfo: wifiinfo.swift Info.plist
	swiftc -O -o wifiinfo wifiinfo.swift \
	  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker Info.plist
	codesign --force --sign - wifiinfo

install: wifiinfo
	mkdir -p $(PREFIX)/bin
	ln -sf $(CURDIR)/net $(PREFIX)/bin/net

uninstall:
	rm -f $(PREFIX)/bin/net

clean:
	rm -f wifiinfo

.PHONY: install uninstall clean
