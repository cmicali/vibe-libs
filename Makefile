# vibe-libs: build, test and check every piece on its own.
# Every target that builds regenerates the project first.

PROJECT := vibe-libs.xcodeproj
DERIVED := build/DerivedData

.PHONY: help project ready-to-push test test-asan test-tsan build-ios consumer check-pieces test-strings fuzz fuzz-replay fuzz-triage clean

# Every target, with the first sentence of its comment.
help:
	@awk '/^# /{c=substr($$0,3)} /^[a-z-]+:/{sub(":.*","",$$1); if (c) printf "  %-14s %s\n", $$1, c; c=""}' Makefile

# Git reads a relative hooks path from each worktree's root.
# Generates the Xcode project from project.yml, and installs the commit-msg hook.
project:
	xcodegen generate --quiet
	git config core.hooksPath .githooks

# SINCE is where this branch leaves origin/main, as CI's is the pull request's base.
# Runs every step CI runs on a pull request, in order, read from the workflow.
ready-to-push:
	SINCE="$$(git merge-base origin/main HEAD)" python3 -I scripts/checks/ready-to-push.py .github/workflows/ci.yml

# SINCE=<rev> limits test and build-ios to the targets a change since that
# commit reaches. CI sets it on a pull request.
SINCE ?=

# SAN_ARGS is test-asan's and test-tsan's.
# Runs every piece's tests on macOS, Debug, with the headermap off.
test: project
	rm -rf build/TestResults.xcresult
	@set -e; \
	chosen="$$(python3 -I scripts/checks/targets.py $(if $(SINCE),--since '$(SINCE)') --scheme vibe-libs-test)"; \
	if [ -z "$$chosen" ]; then echo "test: no test bundle reaches a change since $(SINCE)"; exit 0; fi; \
	xcodebuild test -project $(PROJECT) -scheme vibe-libs-test -destination 'platform=macOS' \
		-derivedDataPath $(DERIVED) -resultBundlePath build/TestResults.xcresult -quiet $(SAN_ARGS); \
	python3 -I scripts/checks/test-summary.py build/TestResults.xcresult

# Each sanitizer writes every report to a file of its own in
# build/sanitizers/$(SAN)/, from every test process, and the run fails on
# any report. Its build has a DerivedData of its own.
SAN_DIR = $(CURDIR)/build/sanitizers/$(SAN)
SAN_OPTIONS = log_path=$(SAN_DIR)/report:print_stacktrace=1

# Runs make test under Address Sanitizer and Undefined Behavior Sanitizer.
test-asan: SAN = asan
test-asan: SAN_ARGS = -enableAddressSanitizer YES -enableUndefinedBehaviorSanitizer YES

# Runs make test under Thread Sanitizer.
test-tsan: SAN = tsan
test-tsan: SAN_ARGS = -enableThreadSanitizer YES

test-asan test-tsan:
	mkdir -p "$(SAN_DIR)" && find "$(SAN_DIR)" -name 'report.*' -delete
	TEST_RUNNER_ASAN_OPTIONS='$(SAN_OPTIONS)' TEST_RUNNER_UBSAN_OPTIONS='$(SAN_OPTIONS)' \
		TEST_RUNNER_TSAN_OPTIONS='$(SAN_OPTIONS):suppressions=$(CURDIR)/scripts/checks/tsan.supp' \
		$(MAKE) --no-print-directory test DERIVED=build/DerivedData-$(SAN) SAN_ARGS='$(SAN_ARGS)'; \
	status=$$?; python3 -I scripts/checks/sanitizer-report.py "$(SAN_DIR)" && test $$status -eq 0

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

# The message filter a move runs, the commit-msg hook, and ready-to-push have
# their tests here too.
# With SINCE, a change to a TagLib file must change TagLib's dated record too.
# Checks the piece rules, then breaks each rule in a copy to prove the check fails.
check-pieces:
	python3 -I scripts/checks/check-pieces.py
	python3 -I scripts/checks/check-pieces-test.py
	python3 -I scripts/checks/filter-messages-test.py
	python3 -I scripts/checks/commit-msg-test.py
	python3 -I scripts/checks/ready-to-push-test.py
	python3 -I scripts/checks/taglib-record.py $(if $(SINCE),--since '$(SINCE)')
	python3 -I scripts/checks/taglib-record-test.py

# Runs the strings tools' self-test over a tiny app of their own.
test-strings:
	Tests/tools/strings/strings-test.sh

# FUZZ_TARGETS limits the fuzz targets below to some targets; fuzz.py list
# names them. FUZZ_SECONDS is each target's run (600), and FUZZ_JOBS its
# workers (4).
FUZZ_TARGETS ?=
FUZZ_FLAGS = $(if $(FUZZ_JOBS),--jobs $(FUZZ_JOBS))

# Fuzzes the parsers under Homebrew's clang, one target at a time (Tests/Fuzz).
fuzz:
	python3 -I scripts/fuzz/fuzz.py run $(FUZZ_TARGETS) $(FUZZ_FLAGS) $(if $(FUZZ_SECONDS),--seconds $(FUZZ_SECONDS))

# Replays each fuzz target's seeds and regressions once, under Xcode's clang.
fuzz-replay:
	python3 -I scripts/fuzz/fuzz.py replay $(FUZZ_TARGETS) $(FUZZ_FLAGS) $(if $(SINCE),--since '$(SINCE)')

# Replays each saved fuzz artifact once, with its peak memory.
fuzz-triage:
	python3 -I scripts/fuzz/fuzz.py triage $(FUZZ_TARGETS) $(FUZZ_FLAGS)

# Removes build output and the generated project.
clean:
	rm -rf build $(PROJECT)
