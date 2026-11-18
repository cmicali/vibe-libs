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
