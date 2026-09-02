PREFIX ?= /usr/local
BINDIR  = $(PREFIX)/bin
APPDIR ?= $(HOME)/Applications
VERSION ?= 0.3.1

APP_NAME   = StringsmithPreview
APP_BUNDLE = .build/$(APP_NAME).app
DIST       = .build/dist
ARM_DIR    = .build/arch-arm64
X86_DIR    = .build/arch-x86_64
FAT_DIR    = .build/universal

# 기본은 현재 아키텍처만 빌드한다. `make release` 는 유니버설로 다시 잡는다.
BUILD_DIR ?= .build/release
BIN        = $(BUILD_DIR)/stringsmith
APP_BIN    = $(BUILD_DIR)/$(APP_NAME)

.PHONY: build universal app install install-app release uninstall test clean

build:
	swift build -c release

## Intel·Apple Silicon 양쪽에서 도는 유니버설 바이너리.
## 배포본은 받는 쪽 기기를 고를 수 없으므로 이쪽을 쓴다.
##
## 한 번의 `--arch arm64 --arch x86_64` 호출은 Xcode 빌드 시스템을 타는데,
## 타깃이 여럿인 이 패키지에서는 Xcode 버전에 따라 "duplicate output file" 로 깨진다.
## 아키텍처별로 따로 빌드해 lipo 로 합치면 평범한 SwiftPM 경로만 쓰므로 안정적이다.
universal:
	swift build -c release --arch arm64  --scratch-path "$(ARM_DIR)"
	swift build -c release --arch x86_64 --scratch-path "$(X86_DIR)"
	rm -rf "$(FAT_DIR)" && mkdir -p "$(FAT_DIR)"
	@# 리소스 번들은 아키텍처와 무관하므로 한쪽 것을 그대로 쓴다.
	cp -R "$(ARM_DIR)/arm64-apple-macosx/release/"*.bundle "$(FAT_DIR)/" 2>/dev/null || true
	lipo -create \
		"$(ARM_DIR)/arm64-apple-macosx/release/stringsmith" \
		"$(X86_DIR)/x86_64-apple-macosx/release/stringsmith" \
		-output "$(FAT_DIR)/stringsmith"
	lipo -create \
		"$(ARM_DIR)/arm64-apple-macosx/release/$(APP_NAME)" \
		"$(X86_DIR)/x86_64-apple-macosx/release/$(APP_NAME)" \
		-output "$(FAT_DIR)/$(APP_NAME)"

## 미리보기 앱을 .app 번들로 감싼다.
##
## SPM 실행 파일을 그대로 띄우면 macOS 가 액세서리 프로세스로 취급해 키보드 입력을
## 받지 못한다. 번들로 만들면 정상 앱이 되고 Dock·Spotlight 에도 뜬다.
app:
	rm -rf "$(APP_BUNDLE)"
	mkdir -p "$(APP_BUNDLE)/Contents/MacOS" "$(APP_BUNDLE)/Contents/Resources"
	cp "$(APP_BIN)" "$(APP_BUNDLE)/Contents/MacOS/$(APP_NAME)"
	@# SPM 이 만든 리소스 번들(.lproj 포함)을 함께 넣는다.
	cp -R "$(BUILD_DIR)/stringsmith_$(APP_NAME).bundle" "$(APP_BUNDLE)/Contents/Resources/" 2>/dev/null || true
	printf '%s\n' \
	  '<?xml version="1.0" encoding="UTF-8"?>' \
	  '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
	  '<plist version="1.0"><dict>' \
	  '  <key>CFBundleName</key><string>$(APP_NAME)</string>' \
	  '  <key>CFBundleDisplayName</key><string>Stringsmith Preview</string>' \
	  '  <key>CFBundleExecutable</key><string>$(APP_NAME)</string>' \
	  '  <key>CFBundleIdentifier</key><string>io.github.keenkim1202.stringsmith.preview</string>' \
	  '  <key>CFBundlePackageType</key><string>APPL</string>' \
	  '  <key>CFBundleShortVersionString</key><string>$(VERSION)</string>' \
	  '  <key>CFBundleVersion</key><string>$(VERSION)</string>' \
	  '  <key>LSMinimumSystemVersion</key><string>13.0</string>' \
	  '  <key>NSPrincipalClass</key><string>NSApplication</string>' \
	  '  <key>NSHighResolutionCapable</key><true/>' \
	  '  <key>CFBundleDevelopmentRegion</key><string>en</string>' \
	  '  <key>CFBundleLocalizations</key><array>' \
	  '    <string>en</string><string>ko</string><string>ja</string>' \
	  '  </array>' \
	  '</dict></plist>' > "$(APP_BUNDLE)/Contents/Info.plist"
	@echo "  ✅ $(APP_BUNDLE)"

## CLI 를 설치한다. `ss` 짧은 별칭도 함께 만든다.
##
## /usr/local/bin 은 보통 root 소유라 sudo 가 필요하다. sudo 없이 쓰려면
## PREFIX=$HOME/.local make install 로 홈에 설치한다.
install: build
	@mkdir -p "$(BINDIR)" 2>/dev/null || true
	@if [ ! -w "$(BINDIR)" ]; then \
		echo ""; \
		echo "  ❌ $(BINDIR) 에 쓸 권한이 없습니다."; \
		echo ""; \
		echo "     둘 중 하나를 고르세요:"; \
		echo ""; \
		echo "       sudo make install                    # 시스템 전역"; \
		echo "       PREFIX=\$$HOME/.local make install    # 홈 디렉터리 (sudo 불필요)"; \
		echo ""; \
		exit 1; \
	fi
	@install -m 755 "$(BIN)" "$(BINDIR)/stringsmith"
	@ln -sf "$(BINDIR)/stringsmith" "$(BINDIR)/ss"
	@echo "  ✅ 설치 완료: $(BINDIR)/stringsmith   (별칭: ss)"
	@case ":$$PATH:" in \
		*":$(BINDIR):"*) ;; \
		*) echo ""; \
		   echo "  ⚠️  $(BINDIR) 가 PATH 에 없습니다. 셸 설정에 추가하세요:"; \
		   echo ""; \
		   echo "       echo 'export PATH=\"$(BINDIR):\$$PATH\"' >> ~/.zshrc" ;; \
	esac

## 미리보기 앱을 ~/Applications 에 설치한다. `stringsmith preview` 가 여기서 찾는다.
install-app: build app
	@mkdir -p "$(APPDIR)"
	rm -rf "$(APPDIR)/$(APP_NAME).app"
	cp -R "$(APP_BUNDLE)" "$(APPDIR)/"
	@echo "  ✅ 설치 완료: $(APPDIR)/$(APP_NAME).app"

## 배포용 묶음. GitHub Releases 에 올릴 파일을 만든다.
##
## `.app` 은 ditto 로 압축한다. zip 은 번들의 심볼릭 링크·확장 속성을 망가뜨린다.
release:
	$(MAKE) universal
	$(MAKE) app BUILD_DIR=$(FAT_DIR)
	rm -rf "$(DIST)" && mkdir -p "$(DIST)"
	ditto -c -k --keepParent "$(APP_BUNDLE)" "$(DIST)/$(APP_NAME)-macOS.zip"
	tar -czf "$(DIST)/stringsmith-macOS.tar.gz" -C "$(FAT_DIR)" stringsmith
	@echo ""
	@echo "  ✅ $(DIST)"
	@ls -lh "$(DIST)" | tail -n +2 | awk '{printf "     %s  %s\n", $$9, $$5}'
	@echo ""
	@echo "  아키텍처 확인:"
	@lipo -archs "$(FAT_DIR)/stringsmith" | sed 's/^/     stringsmith: /'
	@lipo -archs "$(APP_BUNDLE)/Contents/MacOS/$(APP_NAME)" | sed 's/^/     $(APP_NAME): /'

uninstall:
	rm -f "$(BINDIR)/stringsmith" "$(BINDIR)/ss"
	rm -rf "$(APPDIR)/$(APP_NAME).app"

test:
	swift test

clean:
	swift package clean
	rm -rf .build
