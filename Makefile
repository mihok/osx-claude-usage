.PHONY: build test app install run preview clean

build:
	swift build

test:
	swift test

app:
	scripts/build-app.sh

install:
	scripts/install.sh

run: app
	open "build/Claude Usage.app"

preview: app
	"build/Claude Usage.app/Contents/MacOS/ClaudeUsage" --render-preview build/preview
	open build/preview

clean:
	rm -rf .build build
