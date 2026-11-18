# vibe-libs: build, test and check every piece on its own.
# Every target that builds regenerates the project first.

PROJECT := vibe-libs.xcodeproj
DERIVED := build/DerivedData

.PHONY: help project test test-asan test-tsan sanitized build-ios consumer check-pieces test-strings clean

# Every target, with the first sentence of its comment.
help:
	@awk '/^# /{c=substr($$0,3)} /^[a-z-]+:/{sub(":.*","",$$1); if (c) printf "  %-14s %s\n", $$1, c; c=""}' Makefile

# Generates the Xcode project from project.yml.
project:
	xcodegen generate --quiet

# SINCE=<rev> limits test and build-ios to the targets a change since that
# commit reaches. CI sets it on a pull request.
SINCE ?=

# Runs every piece's tests on macOS, Debug, with the headermap off.
test: project
	rm -rf build/TestResults.xcresult
	@set -e; \
	chosen="$$(python3 -I scripts/checks/targets.py $(if $(SINCE),--since '$(SINCE)') --scheme vibe-libs-test)"; \
	if [ -z "$$chosen" ]; then echo "test: no test bundle reaches a change since $(SINCE)"; exit 0; fi; \
	xcodebuild test -project $(PROJECT) -scheme vibe-libs-test -destination 'platform=macOS' \
		-derivedDataPath $(DERIVED) -resultBundlePath build/TestResults.xcresult -quiet; \
	python3 -I scripts/checks/test-summary.py build/TestResults.xcresult

# Runs make test's bundles under Address Sanitizer and Undefined Behavior Sanitizer.
test-asan:
	$(MAKE) --no-print-directory sanitized SAN=asan SAN_ARGS='-enableAddressSanitizer YES -enableUndefinedBehaviorSanitizer YES'

# Runs make test's bundles under Thread Sanitizer.
test-tsan:
	$(MAKE) --no-print-directory sanitized SAN=tsan SAN_ARGS='-enableThreadSanitizer YES'

# test-asan's and test-tsan's run. Each sanitizer writes every report to a
# file of its own in build/sanitizers/$(SAN)/, from every test process, and
# the run fails on any report. Its build has a DerivedData of its own.
SAN_DIR = $(CURDIR)/build/sanitizers/$(SAN)
SAN_OPTIONS = log_path=$(SAN_DIR)/report:print_stacktrace=1
sanitized: project
	@test -n "$(SAN)" || { echo "make test-asan or make test-tsan"; exit 2; }
	mkdir -p "$(SAN_DIR)" && find "$(SAN_DIR)" -name 'report.*' -delete && rm -rf "$(SAN_DIR)/TestResults.xcresult"
	TEST_RUNNER_ASAN_OPTIONS='$(SAN_OPTIONS)' TEST_RUNNER_UBSAN_OPTIONS='$(SAN_OPTIONS)' \
		TEST_RUNNER_TSAN_OPTIONS='$(SAN_OPTIONS):suppressions=$(CURDIR)/scripts/checks/tsan.supp' \
		xcodebuild test -project $(PROJECT) -scheme vibe-libs-test -destination 'platform=macOS' \
		-derivedDataPath build/DerivedData-$(SAN) -resultBundlePath "$(SAN_DIR)/TestResults.xcresult" -quiet $(SAN_ARGS); \
	status=$$?; python3 -I scripts/checks/test-summary.py "$(SAN_DIR)/TestResults.xcresult"; \
	python3 -I scripts/checks/sanitizer-report.py "$(SAN_DIR)" && test $$status -eq 0

# Builds every piece for the iOS simulator, so an AppKit leak fails here.
build-ios: project
	@set -e; \
	chosen="$$(python3 -I scripts/checks/targets.py --ios $(if $(SINCE),--since '$(SINCE)') --scheme vibe-libs-ios)"; \
	if [ -z "$$chosen" ]; then echo "build-ios: no iOS target reaches a change since $(SINCE)"; exit 0; fi; \
	xcodebuild build -project $(PROJECT) -scheme vibe-libs-ios -destination 'generic/platform=iOS Simulator' \
		-derivedDataPath $(DERIVED) -quiet

# Builds and runs a minimal app that takes the pieces as another app would.
consumer:
	cd Tests/Consumer && xcodegen generate --quiet
	xcodebuild build -project Tests/Consumer/Consumer.xcodeproj -scheme Consumer -configuration Release \
		-derivedDataPath build/ConsumerDerivedData -quiet
	build/ConsumerDerivedData/Build/Products/Release/Consumer

# The message filter a move runs has its test here too.
# With SINCE, a change to a TagLib file must change TagLib's dated record too.
# Checks the piece rules, then breaks each rule in a copy to prove the check fails.
check-pieces:
	python3 -I scripts/checks/check-pieces.py
	python3 -I scripts/checks/check-pieces-test.py
	python3 -I scripts/checks/filter-messages-test.py
	python3 -I scripts/checks/taglib-record.py $(if $(SINCE),--since '$(SINCE)')
	python3 -I scripts/checks/taglib-record-test.py

# Runs the strings tools' self-test over a tiny app of their own.
test-strings:
	Tests/tools/strings/strings-test.sh

# Removes build output and the generated project.
clean:
	rm -rf build $(PROJECT)
