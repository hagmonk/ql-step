OCCT_PREFIX ?= /opt/homebrew/opt/opencascade
APP := build/Build/Products/Release/QuickLookStep.app

# OpenCascade mesh backend — the same engine f3d uses, so geometry, assembly
# placement, and colors match f3d by construction.
.PHONY: occt-bridge
occt-bridge:
	clang++ -std=c++17 -O2 -arch arm64 -w -dynamiclib \
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
	  OTHER_LDFLAGS='$$(inherited) $(CURDIR)/occt-bridge/libocctbridge.dylib -Wl,-rpath,@loader_path/../Frameworks -Wl,-rpath,@loader_path/../../../../Frameworks' \
	  build
	./occt-bridge/bundle-occt.sh $(APP)

.PHONY: install
install: xcodebuild
	rm -rf /Applications/QuickLookStep.app
	cp -R $(APP) /Applications/
	./scripts/register-quicklook.sh

# Re-register the Quick Look extensions without rebuilding — fixes stale
# registrations, cached thumbnails, and "preview stopped working" states.
.PHONY: register
register:
	./scripts/register-quicklook.sh
