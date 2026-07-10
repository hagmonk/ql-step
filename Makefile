OCCT_PREFIX ?= /opt/homebrew/opt/opencascade
APP := build/Build/Products/Release/QuickLookStep.app
VERSION := $(shell sed -n 's/.*MARKETING_VERSION = \(.*\);/\1/p' QuickLookStep/QuickLookStep.xcodeproj/project.pbxproj | head -1)
STEP_FILE ?= QuickLookStep/StepPreviewKitTests/Fixtures/178CT.stp
ITERATIONS ?= 5
WARMUPS ?= 1

# OpenCascade mesh backend — the same engine f3d uses, so geometry, assembly
# placement, and colors match f3d by construction.
.PHONY: occt-bridge
occt-bridge:
	clang++ -std=c++17 -O2 -arch arm64 -w -dynamiclib \
	  -mmacosx-version-min=14.6 \
	  -install_name @rpath/libocctbridge.dylib \
	  -I$(OCCT_PREFIX)/include/opencascade \
	  occt-bridge/occt_bridge.cpp \
	  -L$(OCCT_PREFIX)/lib \
	  -lTKDESTEP -lTKXCAF -lTKMesh -lTKBRep -lTKernel -lTKMath \
	  -lTKXSBase -lTKLCAF -lTKCDF -lTKTopAlgo -lTKG3d -lTKDE \
	  -o occt-bridge/libocctbridge.dylib

.PHONY: xcodebuild
xcodebuild: occt-bridge
	xcodebuild \
	  -project QuickLookStep/QuickLookStep.xcodeproj \
	  -scheme QuickLookStep \
	  -configuration Release \
	  -destination 'generic/platform=macOS' \
	  -derivedDataPath build \
	  ARCHS=arm64 ONLY_ACTIVE_ARCH=YES \
	  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= \
	  build
	./occt-bridge/bundle-occt.sh $(APP)

.PHONY: test
test: occt-bridge
	xcodebuild test \
	  -project QuickLookStep/QuickLookStep.xcodeproj \
	  -scheme StepPreviewKit \
	  -configuration Debug \
	  -destination 'platform=macOS,arch=arm64' \
	  -derivedDataPath build-test \
	  ARCHS=arm64 ONLY_ACTIVE_ARCH=YES \
	  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=

.PHONY: bench
bench:
	swift run -c release StepPreviewBench $(STEP_FILE) $(ITERATIONS) $(WARMUPS)

.PHONY: install
install: xcodebuild
	rm -rf /Applications/QuickLookStep.app
	cp -R $(APP) /Applications/
	rm -rf $(APP)   # or pluginkit elects the build-dir appex over /Applications
	./scripts/register-quicklook.sh

# Re-register the Quick Look extensions without rebuilding — fixes stale
# registrations, cached thumbnails, and "preview stopped working" states.
.PHONY: register
register:
	./scripts/register-quicklook.sh

# Tag the current commit with the marketing version and push; CI then builds,
# Developer ID-signs, notarizes, staples, and publishes the GitHub release
# (see .github/workflows/build.yml). The sha256 for the Homebrew cask is in
# the CI "Package app" step output.
.PHONY: release
release:
	git tag v$(VERSION)
	git push origin v$(VERSION)
