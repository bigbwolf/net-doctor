PREFIX ?= $(HOME)/.local

wifiinfo: wifiinfo.swift
	swiftc -O -o wifiinfo wifiinfo.swift

install: wifiinfo
	mkdir -p $(PREFIX)/bin
	ln -sf $(CURDIR)/net $(PREFIX)/bin/net

uninstall:
	rm -f $(PREFIX)/bin/net

clean:
	rm -f wifiinfo

.PHONY: install uninstall clean
