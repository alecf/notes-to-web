APP      := NotesToWeb
BUNDLE   := $(APP).app
CONFIG   := release
VERSION  := $(shell /usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)

# Apple Silicon only. Building for the host arch keeps SwiftPM on its normal
# build system; passing --arch routes through a different one with its own
# quirks (see AGENTS.md on package resources).
BINDIR   := $(shell swift build -c $(CONFIG) --show-bin-path)

.DEFAULT_GOAL := help

## help: list available targets
help:
	@grep -E '^## ' $(MAKEFILE_LIST) | sed 's/^## /  /'

## build: compile the library and executable
build:
	swift build -c $(CONFIG)

## version: print the version the app bundle will carry
version:
	@echo $(VERSION)

## test: run unit tests
test:
	swift test

## app: assemble NotesToWeb.app
app: build
	@rm -rf $(BUNDLE)
	@mkdir -p $(BUNDLE)/Contents/MacOS $(BUNDLE)/Contents/Resources
	@cp $(BINDIR)/$(APP) $(BUNDLE)/Contents/MacOS/$(APP)
	@cp Resources/Info.plist $(BUNDLE)/Contents/Info.plist
	@if [ -f Resources/AppIcon.icns ]; then cp Resources/AppIcon.icns $(BUNDLE)/Contents/Resources/; fi
	@printf 'APPL????' > $(BUNDLE)/Contents/PkgInfo
	@codesign --force --sign - \
		--entitlements Resources/$(APP).entitlements \
		--options runtime \
		$(BUNDLE) 2>/dev/null || \
	 codesign --force --sign - --entitlements Resources/$(APP).entitlements $(BUNDLE)
	@echo "built $(BUNDLE) $(VERSION) ($$(lipo -archs $(BUNDLE)/Contents/MacOS/$(APP)))"

## run: build the app bundle and launch it
run: app
	@open $(BUNDLE)

## install: copy the app to /Applications
install: app
	@rm -rf /Applications/$(BUNDLE)
	@cp -R $(BUNDLE) /Applications/
	@echo "installed /Applications/$(BUNDLE)"

## proto: regenerate Swift protobuf code (needs protoc on PATH)
proto:
	@command -v protoc >/dev/null || { echo "protoc not found; brew install protobuf"; exit 1; }
	@echo "building protoc-gen-swift…"
	@swift build -c release --package-path .build/protoc-gen-swift-src --product protoc-gen-swift 2>/dev/null || \
	 ( rm -rf .build/protoc-gen-swift-src && \
	   git clone -q --depth 1 https://github.com/apple/swift-protobuf.git .build/protoc-gen-swift-src && \
	   swift build -c release --package-path .build/protoc-gen-swift-src --product protoc-gen-swift )
	protoc --plugin=protoc-gen-swift=.build/protoc-gen-swift-src/.build/release/protoc-gen-swift \
		--swift_out=Sources/NotesToWebKit/Generated \
		--swift_opt=Visibility=Public \
		--proto_path=Protos Protos/NoteStore.proto
	@echo "regenerated Sources/NotesToWebKit/Generated/NoteStore.pb.swift"

## live: run the smoke tests against your real Notes library
live:
	NOTES_TO_WEB_LIVE=1 swift test

## dist: build a zipped app bundle for release
dist: app
	@rm -f $(APP)-$(VERSION).zip
	@ditto -c -k --sequesterRsrc --keepParent $(BUNDLE) $(APP)-$(VERSION).zip
	@echo "$(APP)-$(VERSION).zip  $$(shasum -a 256 $(APP)-$(VERSION).zip | cut -d' ' -f1)"

## clean: remove build products
clean:
	@rm -rf .build $(BUNDLE) $(APP)-*.zip

.PHONY: help build version test app run install proto live dist clean
