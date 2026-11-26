PREFIX ?= /usr/local
VERSION := $(shell sed -n 's/.*current = "\(.*\)"/\1/p' Sources/CappyKit/Core/Version.swift)
BIN := .build/release/cappy

.PHONY: build debug test integration-test install uninstall app run-app install-app release clean

build:
	swift build -c release
	@echo "built $(BIN) ($(VERSION))"

debug:
	swift build

test:
	swift test

# 実機の Core Audio を使う結合テスト。TAP=1 で afplay のタップと相互相関も確認する（要: システムオーディオ録音の許可）
integration-test:
	CAPPY_INTEGRATION=1 CAPPY_INTEGRATION_TAP=$(TAP) swift test --filter IntegrationTests

install: build
	install -d $(PREFIX)/bin
	install -m 0755 $(BIN) $(PREFIX)/bin/cappy

uninstall:
	rm -f $(PREFIX)/bin/cappy

# メニューバー版 gcappy.app を dist/ に作る（既定は ad-hoc 署名。CAPPY_SIGN_IDENTITY で変更）
app:
	scripts/build-app.sh $(VERSION)

run-app: app
	open dist/gcappy.app

# ~/Applications に gcappy.app をコピーする
install-app: app
	install -d $(HOME)/Applications
	rm -rf $(HOME)/Applications/gcappy.app
	ditto dist/gcappy.app $(HOME)/Applications/gcappy.app

# 配布用の zip を dist/ に作る（署名と公証は scripts/release.sh を参照）
release:
	scripts/release.sh $(VERSION)

clean:
	swift package clean
	rm -rf dist
