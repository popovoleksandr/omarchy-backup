# Installs omarchy-backup as a package would. The PKGBUILD runs:
#   make DESTDIR="$pkgdir" PREFIX=/usr install
PREFIX ?= /usr
DESTDIR ?=
SHARE := $(DESTDIR)$(PREFIX)/share/omarchy-backup

.PHONY: install test

install:
	install -Dm755 bin/omarchy-backup $(SHARE)/bin/omarchy-backup
	install -Dm644 -t $(SHARE)/lib lib/*.sh
	install -Dm644 -t $(SHARE)/share share/menu.jsonc share/paths
	install -Dm644 VERSION $(SHARE)/VERSION
	install -d $(DESTDIR)$(PREFIX)/bin
	ln -sf ../share/omarchy-backup/bin/omarchy-backup $(DESTDIR)$(PREFIX)/bin/omarchy-backup
	install -Dm644 share/omarchy-backup.desktop $(DESTDIR)$(PREFIX)/share/applications/omarchy-backup.desktop
	install -Dm644 share/omarchy-backup-menu.desktop $(DESTDIR)/etc/xdg/autostart/omarchy-backup-menu.desktop
	install -Dm644 share/omarchy-backup.svg $(DESTDIR)$(PREFIX)/share/icons/hicolor/scalable/apps/omarchy-backup.svg
	install -Dm644 README.md $(DESTDIR)$(PREFIX)/share/doc/omarchy-backup/README.md
	install -Dm644 LICENSE $(DESTDIR)$(PREFIX)/share/licenses/omarchy-backup/LICENSE

test:
	tests/run.sh
