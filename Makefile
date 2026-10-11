# Corral: menu-bar tiler for Terminal.app windows running Claude Code.
APP       := build/Corral.app
VERSION   := 0.4.0
BUNDLE_ID := com.urbanodx.corral
COMMIT    := $(shell git rev-parse --short HEAD 2>/dev/null || echo local)
SOURCES   := $(wildcard Sources/*.swift)
IDENTITY  := Corral Local Signing
SIGN      := $(shell security find-identity -p codesigning 2>/dev/null | grep -q "$(IDENTITY)" && echo "$(IDENTITY)" || echo -)
INSTALL   := $(HOME)/Applications/Corral.app
# This Mac's architecture; `make universal` builds for Apple silicon and Intel at once.
ARCHS     ?= $(shell uname -m)
SWIFTC    := swiftc -O -parse-as-library

.PHONY: build universal test install run uninstall cert clean

build: $(APP)

$(APP): $(SOURCES) Resources/Info.plist Makefile
	rm -rf $(APP) build/bin
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources build/bin
	for arch in $(ARCHS); do \
		$(SWIFTC) -target $$arch-apple-macos13.0 -o build/bin/Corral-$$arch $(SOURCES) || exit 1; \
	done
	lipo -create build/bin/Corral-* -output $(APP)/Contents/MacOS/Corral
	cp Resources/Info.plist $(APP)/Contents/Info.plist
	plutil -replace CFBundleIdentifier -string $(BUNDLE_ID) $(APP)/Contents/Info.plist
	plutil -replace CFBundleShortVersionString -string $(VERSION) $(APP)/Contents/Info.plist
	plutil -replace CorralCommit -string $(COMMIT) $(APP)/Contents/Info.plist
	codesign --force --sign "$(SIGN)" --identifier $(BUNDLE_ID) $(APP)
	@echo "built $(APP) $(VERSION) ($(COMMIT)) for $(ARCHS), signed with: $(SIGN)"

universal:
	$(MAKE) -B build ARCHS="arm64 x86_64"

# Everything but App.swift (it holds @main) plus the test harness.
test:
	@mkdir -p build
	swiftc -O -o build/tests $(filter-out Sources/App.swift,$(SOURCES)) Tests/main.swift
	./build/tests

# Replaces the installed copy and restarts it.
install: build
	-pkill -x Corral
	rm -rf "$(INSTALL)"
	mkdir -p "$(HOME)/Applications"
	cp -R $(APP) "$(INSTALL)"
	open "$(INSTALL)"

run: build
	-pkill -x Corral
	open $(APP)

# Removes the app, its login item and its settings. The signing identity stays;
# remove it with: security delete-identity -c "Corral Local Signing"
uninstall:
	-"$(INSTALL)/Contents/MacOS/Corral" --open-at-login off
	-pkill -x Corral
	rm -rf "$(INSTALL)"
	-defaults delete $(BUNDLE_ID)
	@echo "Corral removed. Also remove it from System Settings > Privacy & Security > Accessibility and > Automation."

cert:
	./scripts/make-cert.sh

clean:
	rm -rf build
