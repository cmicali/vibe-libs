# vibe-libs: build, test and check every piece on its own.
# Every target that builds regenerates the project first.

PROJECT := vibe-libs.xcodeproj
DERIVED := build/DerivedData

.PHONY: help project test build-ios consumer check-pieces test-strings analyze clean

# Every target, with the first sentence of its comment.
help:
	@awk '/^# /{c=substr($$0,3)} /^[a-z-]+:/{sub(":.*","",$$1); if (c) printf "  %-14s %s\n", $$1, c; c=""}' Makefile

# Generates the Xcode project from project.yml.
project:
	xcodegen generate --quiet

# Runs every piece's tests on macOS, Debug, with the headermap off.
test: project
	rm -rf build/TestResults.xcresult
	xcodebuild test -project $(PROJECT) -scheme vibe-libs -destination 'platform=macOS' \
		-derivedDataPath $(DERIVED) -resultBundlePath build/TestResults.xcresult -quiet
	@python3 -I scripts/checks/test-summary.py build/TestResults.xcresult

# Builds every piece for the iOS simulator, so an AppKit leak fails here.
build-ios: project
	xcodebuild build -project $(PROJECT) -scheme vibe-libs -destination 'generic/platform=iOS Simulator' \
		-derivedDataPath $(DERIVED) -quiet

# Builds and runs a minimal app that takes the pieces as another app would.
consumer:
	cd Tests/Consumer && xcodegen generate --quiet
	xcodebuild build -project Tests/Consumer/Consumer.xcodeproj -scheme Consumer -configuration Release \
		-derivedDataPath build/ConsumerDerivedData -quiet
	build/ConsumerDerivedData/Build/Products/Release/Consumer

# The message filter a move runs has its test here too.
# Checks the piece rules, then breaks each rule in a copy to prove the check fails.
check-pieces:
	python3 -I scripts/checks/check-pieces.py
	python3 -I scripts/checks/check-pieces-test.py
	python3 -I scripts/checks/filter-messages-test.py

# Runs the strings tools' self-test over a tiny app of their own.
test-strings:
	Tests/tools/strings/strings-test.sh

# Runs clang's static analyzer over every piece's macOS test bundle, in Release by default.
# SHARD=K/N analyzes only the Kth of N shards of the bundles, as CI does.
analyze: project
	scripts/checks/analyze.sh "$(CONFIG)" "$(SHARD)"

# Removes build output and the generated project.
clean:
	rm -rf build $(PROJECT)
