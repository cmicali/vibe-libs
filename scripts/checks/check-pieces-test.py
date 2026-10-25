"""The piece checker's own tests: each case breaks one rule in a copy of the
repo and expects check-pieces.py to fail with that rule's message.

Usage: python3 -I scripts/checks/check-pieces-test.py   (from the repo root)
"""
import os
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.abspath(".")
CHECKER = os.path.join("scripts", "checks", "check-pieces.py")


def copy_repo(into):
    listed = subprocess.run(["git", "ls-files", "-co", "--exclude-standard"], capture_output=True,
                            text=True, check=True).stdout.split("\n")
    for path in filter(None, listed):
        if os.path.isfile(path):
            os.makedirs(os.path.join(into, os.path.dirname(path)), exist_ok=True)
            shutil.copy2(path, os.path.join(into, path))


def write(root, path, text):
    os.makedirs(os.path.dirname(os.path.join(root, path)), exist_ok=True)
    with open(os.path.join(root, path), "w") as f:
        f.write(text)


def append(root, path, text):
    with open(os.path.join(root, path), "a") as f:
        f.write(text)


def replace(root, path, old, new):
    full = os.path.join(root, path)
    text = open(full).read()
    if old not in text:
        raise AssertionError(f"{path}: the mutation's text is gone: {old!r}")
    with open(full, "w") as f:
        f.write(text.replace(old, new, 1))


HEADER = "core/Common/VibeMacros.h"
SOURCE = "audio/DSP/AudioVarispeed.m"
OTHER_APP = "vibe" + " " + "pro"
# The macOS-only cases make audio/Analysis macOS only, since the map gives it
# no dependent. A piece another piece's iOS target reaches would fail on that
# target, as audio/Meter does since Player-iOS reaches it.
LEAF_SOURCE = "audio/Analysis/AudioBPMAnalyzer.mm"
LEAF_ROW = "| audio/Analysis | audio/AudioTypes |"
LEAF_MAC_ROW = "| audio/Analysis | audio/AudioTypes, macOS only |"
DSP_ROW = "| audio/DSP | third_party/r8brain |"
LEAF_IOS = """  # audio/Analysis built for iOS. Key analysis is an app's choice per
  # platform, so the piece builds on both.
  Analysis-iOS:
    type: library.static
    platform: iOS
    templates: [VibeLibsAnalysis]
    templateAttributes:
      excludedPlatform: Mac

"""
COMMON_IOS_TEMPLATES = "    templates: [VibeLibsCommon]\n    templateAttributes:\n      excludedPlatform: Mac"
EXCLUDE_MAC = "    templateAttributes:\n      excludedPlatform: Mac\n"
EXCLUDE_IOS = "    templateAttributes:\n      excludedPlatform: iOS\n"
DSP_IOS = "  DSP-iOS:\n    type: library.static\n    platform: iOS\n    templates: [VibeLibsDSP]\n" + EXCLUDE_MAC
DSP_TESTS = "  DSPTests:\n    type: bundle.unit-test\n    platform: macOS\n    templates: [VibeLibsDSP]\n" + EXCLUDE_IOS
# The iOS-only cases use the touch driver, the first such piece.
DRIVER_SOURCE = "dev/iOSDriver/VibeiOSDriverTests.m"
COMMON_TESTS_TEMPLATES = "  CommonTests:\n    type: bundle.unit-test\n    platform: macOS\n    templates: [VibeLibsCommon]"


def mac_only(root):
    """audio/Analysis becomes macOS only, the way a shell piece arrives: the map
    row says so, and the piece has no iOS target."""
    replace(root, "docs/plan.md", LEAF_ROW, LEAF_MAC_ROW)
    replace(root, "project.yml", LEAF_IOS, "")
    replace(root, "project.yml", "        Analysis-iOS: all\n", "")


def recount(root, path, word):
    """Rewrites the piece count's word in one doc, or the sentence away."""
    full = os.path.join(root, path)
    text = open(full).read()
    sentence = re.compile(r"The first [a-z]+(?:-[a-z]+)? pieces are here")
    if not sentence.search(text):
        raise AssertionError(f"{path}: the mutation's text is gone: the piece count")
    new = f"The first {word} pieces are here" if word else "Some pieces are here"
    with open(full, "w") as f:
        f.write(sentence.sub(new, text, count=1))


def ios_target_listing(root, listed):
    mac_only(root)
    replace(root, "project.yml", COMMON_IOS_TEMPLATES, COMMON_IOS_TEMPLATES.replace("VibeLibsCommon]", f"VibeLibsCommon, {listed}]"))

# (name, mutation, text the failure must contain, or None for a pass)
CASES = [
    ("an angled include the map does not allow",
     lambda r: append(r, HEADER, "\n#import <AudioVarispeed.h>\n"),
     "which the map does not allow core/Common"),
    ("a quoted include the map does not allow",
     lambda r: append(r, HEADER, '\n#import "AudioVarispeed.h"\n'),
     "which the map does not allow core/Common"),
    ("a cycle in the map",
     lambda r: replace(r, "docs/plan.md", "| core/Common | nothing |", "| core/Common | audio/DSP |"),
     "has a cycle"),
    ("a map row naming an unknown piece",
     lambda r: replace(r, "docs/plan.md", "| audio/OutputDevices | nothing |", "| audio/OutputDevices | audio/Nowhere |"),
     "which has no row in the map"),
    ("two headers with one name",
     lambda r: write(r, "core/Common/AudioVarispeed.h", "#pragma once\n"),
     "headers share the name"),
    ("a template compiling outside its piece",
     lambda r: replace(r, "vibe-libs.yml", "- path: audio/DSP", "- path: audio"),
     "compiles audio, outside audio/DSP"),
    ("a template searching outside its piece",
     lambda r: replace(r, "vibe-libs.yml", '"$(VIBE_LIBS_ROOT)/audio/DSP"]', '"$(VIBE_LIBS_ROOT)/audio/DSP", "$(VIBE_LIBS_ROOT)/core/Common"]'),
     "searches core/Common, outside audio/DSP"),
    ("a template not excluding the other platform",
     lambda r: replace(r, "vibe-libs.yml", 'path: audio/DSP\n        excludes: ["**/*.md", "${excludedPlatform}/**"]',
                       'path: audio/DSP\n        excludes: ["**/*.md"]'),
     "does not exclude ${excludedPlatform}/**"),
    ("a template listing a piece the map does not allow",
     lambda r: replace(r, "vibe-libs.yml", "  VibeLibsCommon:\n", "  VibeLibsCommon:\n    templates: [VibeLibsDSP]\n"),
     "the map does not allow core/Common -> audio/DSP"),
    ("a platform directory with another name",
     lambda r: write(r, "audio/DSP/macOS/Thing.m", "int VibeThing(void) { return 0; }\n"),
     "the only platform directories"),
    ("a platform half below the top of its piece",
     lambda r: write(r, "audio/DSP/Sub/Mac/Thing.m", "int VibeThing(void) { return 0; }\n"),
     "sits at the top of its piece"),
    ("a shared file importing AppKit with no guard",
     lambda r: append(r, SOURCE, "\n#import <AppKit/AppKit.h>\n"),
     "with no platform guard"),
    ("a shared file importing AppKit under a guard",
     lambda r: append(r, SOURCE, "\n#if TARGET_OS_OSX\n#import <AppKit/AppKit.h>\n#endif\n"),
     None),
    ("a shared file importing UIKit in the other branch of a mac guard",
     lambda r: append(r, SOURCE, "\n#if TARGET_OS_OSX\n#else\n#import <UIKit/UIKit.h>\n#endif\n"),
     None),
    ("the iOS half importing AppKit",
     lambda r: write(r, "audio/DSP/iOS/Thing.m", "#import <AppKit/AppKit.h>\n"),
     "in the iOS/ half"),
    ("a header nothing compiles",
     lambda r: write(r, "audio/DSP/Orphan.h", "#pragma once\n"),
     "nothing in audio/DSP or its tests compiles it"),
    ("a quoted include of an app header",
     lambda r: append(r, SOURCE, '\n#import "AppSettings.h"\n'),
     "is in no piece"),
    ("an app header included only when it exists",
     lambda r: append(r, SOURCE, '\n#if __has_include("AppSettings.h")\n#import "AppSettings.h"\n#endif\n'),
     None),
    ("an app header included when it does not exist",
     lambda r: append(r, SOURCE, '\n#if __has_include("AppSettings.h")\n#else\n#import "AppSettings.h"\n#endif\n'),
     "is in no piece"),
    ("a test including a piece its test bundle lists",
     lambda r: append(r, "Tests/files/ShareLinks/LinkRulesTests.m", '\n#import "PlayableExtensions.h"\n'),
     None),
    ("a test including a piece its test bundle does not list",
     lambda r: append(r, "Tests/files/ShareLinks/LinkRulesTests.m", '\n#import "AudioVarispeed.h"\n'),
     "which the map does not allow files/ShareLinks"),
    ("a test including a shared test helper",
     lambda r: append(r, "Tests/audio/DSP/AudioVarispeedTests.m", '\n#import "DrawnViewTestSupport.h"\n'),
     None),
    ("a piece's source including a shared test helper",
     lambda r: append(r, SOURCE, '\n#import "DrawnViewTestSupport.h"\n'),
     "is in no piece"),
    ("#if DEBUG in a shipping header",
     lambda r: append(r, HEADER, "\n#if DEBUG\n#endif\n"),
     "#if DEBUG in a shipping header"),
    ("the other app's name",
     lambda r: append(r, "README.md", f"\n{OTHER_APP}\n"),
     "names the other app"),
    ("a word that only starts like the other app's name",
     lambda r: append(r, "README.md", "\nVibeProbe\n"),
     None),
    ("a macOS-only piece given an iOS target",
     lambda r: replace(r, "docs/plan.md", LEAF_ROW, LEAF_MAC_ROW),
     "Analysis-iOS builds for iOS and lists VibeLibsAnalysis, but audio/Analysis is macOS only"),
    ("an iOS target listing a macOS-only template",
     lambda r: ios_target_listing(r, "VibeLibsAnalysis"),
     "Common-iOS builds for iOS and lists VibeLibsAnalysis, but audio/Analysis is macOS only"),
    ("an iOS target reaching a macOS-only template through a stack",
     lambda r: (append(r, "vibe-libs.yml", "\n  VibeLibsShell:\n    templates: [VibeLibsAnalysis]\n"),
                ios_target_listing(r, "VibeLibsShell")),
     "Common-iOS builds for iOS and reaches VibeLibsAnalysis through VibeLibsShell, but audio/Analysis is macOS only"),
    ("a macOS-only piece with an iOS/ half",
     lambda r: (mac_only(r), write(r, "audio/Analysis/iOS/Thing.m", "int VibeThing(void) { return 0; }\n")),
     "audio/Analysis is macOS only and has no iOS/ half"),
    ("a macOS-only piece with a Mac/ half",
     lambda r: (mac_only(r), write(r, "audio/Analysis/Mac/Thing.m", "int VibeThing(void) { return 0; }\n")),
     None),
    ("a macOS-only piece importing AppKit with no guard",
     lambda r: (mac_only(r), append(r, LEAF_SOURCE, "\n#import <AppKit/AppKit.h>\n")),
     None),
    ("a macOS target listing an iOS-only template",
     lambda r: replace(r, "project.yml", COMMON_TESTS_TEMPLATES,
                       COMMON_TESTS_TEMPLATES.replace("VibeLibsCommon]", "VibeLibsCommon, VibeLibsIOSDriver]")),
     "CommonTests builds for macOS and lists VibeLibsIOSDriver, but dev/iOSDriver is iOS only"),
    ("an iOS-only piece with a Mac/ half",
     lambda r: write(r, "dev/iOSDriver/Mac/Thing.m", "int VibeThing(void) { return 0; }\n"),
     "dev/iOSDriver is iOS only and has no Mac/ half"),
    ("an iOS-only piece importing UIKit with no guard",
     lambda r: append(r, DRIVER_SOURCE, "\n#import <UIKit/UIKit.h>\n"),
     None),
    ("a first-party template searching third_party/",
     lambda r: replace(r, "vibe-libs.yml", '"$(VIBE_LIBS_ROOT)/audio/DSP"]', '"$(VIBE_LIBS_ROOT)/audio/DSP", "$(VIBE_LIBS_ROOT)/third_party"]'),
     "searches third_party, outside audio/DSP"),
    ("a vendored piece including another through third_party/",
     lambda r: append(r, "third_party/dr_flac/dr_flac.c", '\n#include "dr_mp3/dr_mp3.h"\n'),
     "which the map does not allow third_party/dr_flac"),
    ("a map row dropping a vendored piece whose name holds a digit",
     lambda r: replace(r, "docs/plan.md", DSP_ROW, "| audio/DSP | nothing |"),
     "the map does not allow audio/DSP -> third_party/r8brain"),
    ("a spelling two vendored pieces answer, unsettled",
     lambda r: write(r, "third_party/taglib/ogg/ogg/ogg.h", "#pragma once\n"),
     "ogg/ogg.h is ambiguous"),
    ("an iOS target that excludes no platform",
     lambda r: replace(r, "project.yml", DSP_IOS, DSP_IOS.replace(EXCLUDE_MAC, "")),
     "DSP-iOS builds for iOS with VibeLibsDSP, but sets no excludedPlatform"),
    ("an iOS target that excludes iOS",
     lambda r: replace(r, "project.yml", DSP_IOS, DSP_IOS.replace("excludedPlatform: Mac", "excludedPlatform: iOS")),
     "DSP-iOS builds for iOS with VibeLibsDSP, but sets excludedPlatform: iOS"),
    ("a macOS test bundle that excludes no platform",
     lambda r: replace(r, "project.yml", DSP_TESTS, DSP_TESTS.replace(EXCLUDE_IOS, "")),
     "DSPTests builds for macOS with VibeLibsDSP, but sets no excludedPlatform"),
    ("a merge conflict's first marker",
     lambda r: append(r, SOURCE, "\n" + "<" * 7 + " HEAD\n"),
     "AudioVarispeed.m:"),
    ("a merge conflict's middle marker in a doc",
     lambda r: append(r, "audio/DSP/AGENTS.md", "\n" + "=" * 7 + "\n"),
     "audio/DSP/AGENTS.md:"),
    ("a merge conflict's last marker",
     lambda r: append(r, "README.md", "\n" + ">" * 7 + " main\n"),
     "README.md:"),
    ("a Markdown underline longer than a marker",
     lambda r: append(r, "README.md", "\nHeading\n" + "=" * 12 + "\n"),
     None),
    ("a marker in vendored code",
     lambda r: append(r, "third_party/dr_flac/AGENTS.md", "\n" + "=" * 7 + "\n"),
     None),
    ("a doc line over 1500 characters",
     lambda r: append(r, "audio/DSP/AGENTS.md", "\n" + "word " * 301 + "\n"),
     "a doc line of 1505 characters, over 1500"),
    ("a doc line of exactly 1500 characters",
     lambda r: append(r, "audio/DSP/AGENTS.md", "\n" + "x" * 1500 + "\n"),
     None),
    ("a long line in vendored docs",
     lambda r: append(r, "third_party/dr_flac/AGENTS.md", "\n" + "word " * 301 + "\n"),
     None),
    # A tools/ piece is scripts, so it has no template, but it is still a piece.
    ("a tools piece with no AGENTS.md",
     lambda r: os.remove(os.path.join(r, "tools/strings/AGENTS.md")),
     "tools/strings: no AGENTS.md"),
    # The count is whatever main holds, so the cases rewrite the word they find.
    ("a README whose piece count is wrong",
     lambda r: recount(r, "README.md", "one"),
     'README.md: the piece count says "one"'),
    ("an AGENTS.md with no piece count",
     lambda r: recount(r, "AGENTS.md", None),
     'AGENTS.md: no "The first <number> pieces are here" sentence'),
    # An app's no-updater configuration excludes VibeUpdater.m by name.
    ("a second updater source that reaches Sparkle through the piece's header",
     lambda r: write(r, "system/Updates/Mac/VibeUpdaterMenu.m", '#import "VibeUpdater.h"\n'),
     "the sources that reach Sparkle are VibeUpdater.m, VibeUpdaterMenu.m"),
    ("the updater's source renamed",
     lambda r: os.rename(os.path.join(r, "system/Updates/Mac/VibeUpdater.m"),
                         os.path.join(r, "system/Updates/Mac/Updater.m")),
     "the sources that reach Sparkle are Updater.m"),
    ("a second updater source that reaches no Sparkle",
     lambda r: write(r, "system/Updates/Mac/UpdaterRules.m", '#import "UpdaterRules.h"\n'),
     None),
]


def run(root):
    result = subprocess.run([sys.executable, "-I", os.path.join(root, CHECKER), root], capture_output=True, text=True)
    return result.returncode, result.stdout + result.stderr


def main():
    problems = []
    base = tempfile.mkdtemp(prefix="check-pieces-")
    try:
        clean = os.path.join(base, "clean")
        copy_repo(clean)
        code, output = run(clean)
        if code != 0:
            problems.append(f"the unchanged repo fails:\n{output}")
        for i, (name, mutate, expected) in enumerate(CASES):
            root = os.path.join(base, str(i))
            shutil.copytree(clean, root)
            mutate(root)
            code, output = run(root)
            if expected is None and code != 0:
                problems.append(f"{name}: should pass, but failed:\n{output}")
            elif expected is not None and (code == 0 or expected not in output):
                problems.append(f"{name}: expected a failure containing {expected!r}, got exit {code}:\n{output}")
    finally:
        shutil.rmtree(base, ignore_errors=True)
    if problems:
        print("\n\n".join(problems))
        sys.exit(1)
    print(f"check-pieces tests OK: {len(CASES)} cases")


if __name__ == "__main__":
    main()
