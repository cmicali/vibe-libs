//
//  VibeMP4ItemNames.h
//  vibe-libs
//
//  The names of an MP4's ilst children, read from its bytes without TagLib,
//  so the writer can see which items TagLib's parse kept. A freeform item is
//  "----:mean:name", as TagLib keys it. C++.
//

#pragma once

#include <stdint.h>
#include <string>
#include <vector>

// false when the file has no moov. No ilst is an empty list.
bool VibeMP4ItemNames(const uint8_t *bytes, uint64_t length, std::vector<std::string> *names);

// Whether the rate atom holds a number that isn't 2 bytes, as a 4-byte or an
// 8-byte integer, which TagLib reads by its first two bytes only, and saves
// back so. A text rate, a 2-byte one, and no rate answer false
// (media/Tags/AGENTS.md, Ratings).
bool VibeMP4RateIsUnkept(const uint8_t *bytes, uint64_t length);
