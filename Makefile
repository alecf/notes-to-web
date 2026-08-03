APP      := NotesToWeb
BUNDLE   := $(APP).app
CONFIG   := release
BUILDDIR := .build/$(CONFIG)

.DEFAULT_GOAL := help

## help: list available targets
help:
	@grep -E '^## ' $(MAKEFILE_LIST) | sed 's/^## /  /'

## build: compile the library and executable
build:
	swift build -c $(CONFIG)

## test: run unit tests
test:
	swift test

## app: assemble NotesToWeb.app
app: build
	@rm -rf $(BUNDLE)
	@mkdir -p $(BUNDLE)/Contents/MacOS $(BUNDLE)/Contents/Resources
	@cp $(BUILDDIR)/$(APP) $(BUNDLE)/Contents/MacOS/$(APP)
	@cp Resources/Info.plist $(BUNDLE)/Contents/Info.plist
	@if [ -f Resources/AppIcon.icns ]; then cp Resources/AppIcon.icns $(BUNDLE)/Contents/Resources/; fi
	@printf 'APPL????' > $(BUNDLE)/Contents/PkgInfo
	@codesign --force --sign - \
		--entitlements Resources/$(APP).entitlements \
		--options runtime \
		$(BUNDLE) 2>/dev/null || \
	 codesign --force --sign - --entitlements Resources/$(APP).entitlements $(BUNDLE)
	@echo "built $(BUNDLE)"

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

## clean: remove build products
clean:
	@rm -rf .build $(BUNDLE)

.PHONY: help build test app run install proto live clean
