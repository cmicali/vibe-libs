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

// The rate atom's value when its data is a 4-byte integer, which TagLib
// reads by its first two bytes only, so as 0. -1 when the file holds no such
// rate (media/Tags/AGENTS.md, Ratings).
int64_t VibeMP4WideRate(const uint8_t *bytes, uint64_t length);
