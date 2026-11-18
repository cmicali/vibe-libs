//
//  VibeTagWriter.mm
//  vibe-libs
//

#import "VibeTagWriter.h"
#import "NSString+CPPStrings.h"
#import "TagLibAudioFile.h"
#import "VibeMacros.h"

#include <algorithm>
#include <stdexcept>
#include <aifffile.h>
#include <apetag.h>
#include <attachedpictureframe.h>
#include <commentsframe.h>
#include <flacfile.h>
#include <flacpicture.h>
#include <id3v1genres.h>
#include <id3v1tag.h>
#include <id3v2framefactory.h>
#include <id3v2header.h>
#include <id3v2tag.h>
#include <infotag.h>
#include <mp4file.h>
#include <mp4itemfactory.h>
#include <mpegfile.h>
#include <opusfile.h>
// TagLib's own doc comment in this header fails -Wdocumentation-html.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdocumentation-html"
#include <textidentificationframe.h>
#pragma clang diagnostic pop
#include <tpropertymap.h>
#include <vorbisfile.h>
#include <wavfile.h>
#include <xiphcomment.h>

#include "VibeCheckedFileStream.h"
#include "VibeMP4ItemNames.h"

NSErrorDomain const VibeTagWriteErrorDomain = @"vibe-libs.tags.write";

namespace {

// Keys upper case, each with its values. Empty values remove the key.
using Edits = TagLib::Map<TagLib::String, TagLib::StringList>;

// A picture as a tag stores it, for a write that puts pictures back.
struct Record {
    TagLib::ByteVector data;
    TagLib::String mimeType;
    int type = 0;
    TagLib::String description;
    int width = 0, height = 0, colorDepth = 0, colorCount = 0;
};

struct Cover {
    bool change = false;
    TagLib::ByteVector data;  // empty removes
    TagLib::String mimeType;
    // Every picture becomes `records`, in order, and data is ignored.
    bool replaceAll = false;
    std::vector<Record> records;
};

// A refusal found before the first write, or a failure after it.
struct Refusal {
    VibeTagWriteError code;
    std::string reason;
};

[[noreturn]] void Refuse(VibeTagWriteError code, const std::string &reason) {
    throw Refusal{code, reason};
}

std::string Text(const TagLib::String &string) {
    return string.to8Bit(true);
}

// The largest cover: under FLAC's 16 MiB block, with room for its header.
constexpr NSUInteger kMaxCoverBytes = 16000000;
// A FLAC metadata block's length is 24 bits.
constexpr unsigned int kMaxFLACBlockBytes = 0xFFFFFF;

// A number and its total, which ID3v2, MP4, APE, and INFO hold in one frame
// as "3/12", and a Xiph comment in two. The alias is the total's other
// spelling, which media/Metadata also reads.
struct NumberKeys {
    const char *number;
    const char *total;
    const char *alias;
};
constexpr NumberKeys kNumberKeys[] = {
    {"TRACKNUMBER", "TRACKTOTAL", "TOTALTRACKS"},
    {"DISCNUMBER", "DISCTOTAL", "TOTALDISCS"},
};

// The other spellings media/Metadata's parse falls back to for a field. A
// write of the field clears them, so a removal sticks.
struct Aliases {
    const char *key;
    const char *aliases[2];
};
constexpr Aliases kAliases[] = {
    {"COMMENT", {"DESCRIPTION", nullptr}},
    {"LABEL", {"ORGANIZATION", "PUBLISHER"}},
    {"ORIGINALDATE", {"ORIGINALYEAR", nullptr}},
};

BOOL Fail(NSError *__autoreleasing *error, VibeTagWriteError code, NSString *path, NSString *reason) {
    LogError(@"Tag write failed for %@: %@", path.lastPathComponent, reason);
    if (error) {
        *error = [NSError errorWithDomain:VibeTagWriteErrorDomain code:code
                                 userInfo:@{NSLocalizedDescriptionKey: reason, NSFilePathErrorKey: path}];
    }
    return NO;
}

TagLib::String TL(NSString *string) {
    return TagLib::String(string.UTF8String ?: "", TagLib::String::UTF8);
}

// TRAP: not @(toCString()), which ends at an embedded NUL. This is the read
// an app checks a write by.
NSString *NS(const TagLib::String &string) {
    return [NSString stringWithStdString:string.to8Bit(true)] ?: @"";
}

TagLib::String First(const TagLib::StringList &values) {
    return values.isEmpty() ? TagLib::String() : values.front().stripWhiteSpace();
}

// The number before a slash, and the total after it.
void SplitPair(const TagLib::StringList &values, TagLib::String *number, TagLib::String *total) {
    *number = TagLib::String();
    *total = TagLib::String();
    const TagLib::String value = First(values);
    const int slash = value.find("/");
    if (slash < 0) {
        *number = value;
        return;
    }
    *number = value.substr(0, slash).stripWhiteSpace();
    *total = value.substr(slash + 1).stripWhiteSpace();
}

// How a tag holds numbers: in one frame, in two fields, or as ID3v1's bare
// number and year.
enum class Style { Folded, Xiph, ID3v1 };

// The operations on one tag for the named edits: each key set to its values,
// or removed when they are empty. A number edit keeps the half not named,
// and clears the total's other spellings. A field's aliases are cleared.
Edits Resolve(const Edits &named, const TagLib::PropertyMap &current, Style style, bool id3v2) {
    Edits ops;
    for (const auto &[key, values] : named) {
        bool number = false;
        for (const NumberKeys &keys : kNumberKeys) number = number || key == keys.number || key == keys.total;
        if (number) continue;
        ops[key] = values;
        for (const Aliases &alias : kAliases) {
            if (key != alias.key) continue;
            for (const char *other : alias.aliases) {
                if (other) ops[other] = TagLib::StringList();
            }
        }
    }
    for (const NumberKeys &keys : kNumberKeys) {
        if (!named.contains(keys.number) && !named.contains(keys.total)) continue;
        TagLib::String number, total;
        SplitPair(current.value(keys.number), &number, &total);
        const bool slashStyle = First(current.value(keys.number)).find("/") >= 0;
        if (total.isEmpty()) total = First(current.value(keys.total));
        if (total.isEmpty()) total = First(current.value(keys.alias));
        if (named.contains(keys.number)) {
            TagLib::String givenTotal;
            SplitPair(named.value(keys.number), &number, &givenTotal);
            if (!givenTotal.isEmpty()) total = givenTotal;
        }
        if (named.contains(keys.total)) total = First(named.value(keys.total));
        if (style == Style::ID3v1) {
            ops[keys.number] = number.isEmpty() ? TagLib::StringList() : TagLib::StringList(number);
            continue;
        }
        ops[keys.alias] = TagLib::StringList();
        if (style == Style::Xiph && !slashStyle) {
            ops[keys.number] = number.isEmpty() ? TagLib::StringList() : TagLib::StringList(number);
            ops[keys.total] = total.isEmpty() ? TagLib::StringList() : TagLib::StringList(total);
            continue;
        }
        ops[keys.total] = TagLib::StringList();
        if (number.isEmpty() && total.isEmpty()) {
            ops[keys.number] = TagLib::StringList();
        }
        else {
            ops[keys.number] = TagLib::StringList(total.isEmpty() ? number
                                                  : (number.isEmpty() ? TagLib::String("0") : number) + "/" + total);
        }
    }
    // ID3v1 holds a four-digit year.
    if (style == Style::ID3v1 && ops.contains("DATE") && !ops["DATE"].isEmpty()) {
        const TagLib::String date = First(ops["DATE"]);
        bool digits = date.size() >= 4;
        for (unsigned int i = 0; digits && i < 4; i++) digits = date[i] >= '0' && date[i] <= '9';
        ops["DATE"] = digits ? TagLib::StringList(date.substr(0, 4)) : TagLib::StringList();
    }
    // TRAP: media/Metadata reads ID3v2's TIT1, TagLib's WORK, as the
    // grouping when GRP1 is absent. So a removed grouping also removes a TIT1
    // the reader showed, and is refused when it would leave a TIT1 showing.
    if (id3v2 && named.contains("GROUPING") && named.value("GROUPING").isEmpty() && current.contains("WORK")) {
        if (current.contains("GROUPING")) {
            Refuse(VibeTagWriteErrorWouldLoseData,
                   "removing the grouping would show the TIT1 work frame as the grouping");
        }
        ops["WORK"] = TagLib::StringList();
    }
    return ops;
}

// A tag with no editor of its own: its whole map, with the operations
// applied. APE, ID3v1, and INFO keep what their maps do not name. Whether
// the tag changed, so an unchanged one is not rewritten.
bool ApplyByPropertyMap(TagLib::Tag *tag, const Edits &named, Style style) {
    const TagLib::PropertyMap before = tag->properties();
    TagLib::PropertyMap properties = before;
    for (const auto &[key, values] : Resolve(named, before, style, false)) {
        if (values.isEmpty()) properties.erase(key);
        else properties.replace(key, values);
    }
    tag->setProperties(properties);
    return tag->properties() != before;
}

#pragma mark - ID3v2

// Frame::asProperties is protected, but the text, TXXX, and comment frames
// that hold every edited field make theirs public. Another frame holds the
// key its ID maps to.
bool FrameHoldsKey(TagLib::ID3v2::Frame *frame, const TagLib::String &key) {
    if (auto comment = dynamic_cast<TagLib::ID3v2::CommentsFrame *>(frame)) {
        return comment->asProperties().contains(key);
    }
    if (auto text = dynamic_cast<TagLib::ID3v2::TextIdentificationFrame *>(frame)) {
        // UserTextIdentificationFrame derives from it and overrides it.
        return text->asProperties().contains(key);
    }
    return TagLib::ID3v2::Frame::frameIDToKey(frame->frameID()) == key;
}

// ID3v2.3's TYER, TDAT, and TIME hold a date to the minute.
bool V3HoldsDate(const TagLib::String &date) {
    const unsigned int size = date.size();
    return size == 4 || size == 10 || size == 16;
}

void CheckID3v2Values(const Edits &ops, TagLib::ID3v2::Version version) {
    if (version != TagLib::ID3v2::v3) return;
    for (const auto &[key, values] : ops) {
        if (values.isEmpty()) continue;
        if (key == "DATE" && !V3HoldsDate(First(values))) {
            Refuse(VibeTagWriteErrorUnsupportedValue,
                   "ID3v2.3 holds a date as YYYY, YYYY-MM-DD, or YYYY-MM-DDTHH:MM, not " + Text(First(values)));
        }
        if (key == "ORIGINALDATE" && First(values).size() != 4) {
            Refuse(VibeTagWriteErrorUnsupportedValue,
                   "ID3v2.3 holds the original date's year alone, not " + Text(First(values)));
        }
    }
}

// Removes each frame that holds a key, then adds the key's frame. TIPL and
// TMCL hold several keys, and none of the edited fields.
void ApplyID3v2Ops(TagLib::ID3v2::Tag *tag, const Edits &ops, TagLib::ID3v2::Version version) {
    for (const auto &[key, values] : ops) {
        TagLib::ID3v2::FrameList remove;
        for (TagLib::ID3v2::Frame *frame : tag->frameList()) {
            const TagLib::ByteVector id = frame->frameID();
            if (id == "TIPL" || id == "TMCL") continue;
            if (FrameHoldsKey(frame, key)) remove.append(frame);
        }
        for (TagLib::ID3v2::Frame *frame : remove) tag->removeFrame(frame, true);
        if (values.isEmpty()) continue;
        // TRAP: TagLib drops TMOO when it renders ID3v2.3, so the mood
        // goes in a TXXX frame, as Picard writes it. It reads back as MOOD.
        if (version == TagLib::ID3v2::v3 && key == "MOOD") {
            tag->addFrame(new TagLib::ID3v2::UserTextIdentificationFrame("MOOD", values, TagLib::String::UTF8));
            continue;
        }
        tag->addFrame(TagLib::ID3v2::FrameFactory::instance()->createFrameForProperty(key, values));
    }
}

// A removal takes every front cover, or every picture when none is one,
// since the art read falls back to any picture. A replacement takes every
// front cover. With replaceAll, every picture goes.
void ApplyID3v2Cover(TagLib::ID3v2::Tag *tag, const Cover &cover) {
    if (!cover.change) return;
    TagLib::ID3v2::FrameList fronts, all;
    for (TagLib::ID3v2::Frame *frame : tag->frameList("APIC")) {
        auto picture = dynamic_cast<TagLib::ID3v2::AttachedPictureFrame *>(frame);
        if (!picture) continue;
        all.append(frame);
        if (picture->type() == TagLib::ID3v2::AttachedPictureFrame::FrontCover) fronts.append(frame);
    }
    const bool takeAll = cover.replaceAll || (cover.data.isEmpty() && fronts.isEmpty());
    for (TagLib::ID3v2::Frame *frame : takeAll ? all : fronts) tag->removeFrame(frame, true);
    if (cover.replaceAll) {
        for (const Record &record : cover.records) {
            auto frame = new TagLib::ID3v2::AttachedPictureFrame();
            frame->setTextEncoding(TagLib::String::UTF8);
            frame->setMimeType(record.mimeType);
            frame->setType(static_cast<TagLib::ID3v2::AttachedPictureFrame::Type>(record.type));
            frame->setDescription(record.description);
            frame->setPicture(record.data);
            tag->addFrame(frame);
        }
        return;
    }
    if (cover.data.isEmpty()) return;
    auto frame = new TagLib::ID3v2::AttachedPictureFrame();
    frame->setTextEncoding(TagLib::String::UTF8);
    frame->setMimeType(cover.mimeType);
    frame->setType(TagLib::ID3v2::AttachedPictureFrame::FrontCover);
    frame->setPicture(cover.data);
    tag->addFrame(frame);
}

std::string FrameName(TagLib::ID3v2::Frame *frame) {
    const TagLib::ByteVector id = frame->frameID();
    return std::string(id.data(), id.size());
}

// TRAP: zlib is not built in, so a compressed frame parses as an
// UnknownFrame and renders as a plain one holding compressed bytes. An
// encrypted frame likewise. A tag holding one is refused.
void CheckID3v2Frames(TagLib::ID3v2::Tag *tag) {
    for (TagLib::ID3v2::Frame *frame : tag->frameList()) {
        if (frame->header()->compression() || frame->header()->encryption()) {
            Refuse(VibeTagWriteErrorUnsupportedFrame,
                   "the ID3v2 frame " + FrameName(frame) + " is compressed or encrypted");
        }
    }
}

// What the render would drop, refused before it can. TagLib marks a frame
// its parse cannot keep to be discarded: ID3v2.3's EQUA, RVAD, TIME, TRDA,
// TSIZ, and TDAT, and ID3v2.2's CRM, EQU, LNK, RVA, TIM, TSI, and TDA. A
// TDAT or TIME it merged into the date is kept by the date. Its
// ID3v2.3 render drops ID3v2.4's ASPI, EQU2, RVA2, SEEK, SIGN, TDRL, TDTG,
// TMOO, TPRO, and TSST. TRAP: its ID3v2.3 render keeps one genre with no
// ID3v1 number, so two such genres refuse.
void CheckID3v2Render(TagLib::ID3v2::Tag *tag, TagLib::ID3v2::Version version) {
    static const char *const kV4Only[] = {"ASPI", "EQU2", "RVA2", "SEEK", "SIGN", "TDRL", "TDTG", "TMOO",
                                          "TPRO", "TSST"};
    // TagLib's parse merges ID3v2.3's TDAT and TIME into a TDRC of a year
    // alone, leaving them marked. Merged, they are no loss.
    const TagLib::ID3v2::FrameList &dates = tag->frameList("TDRC");
    const unsigned int date = dates.isEmpty() ? 0 : dates.front()->toString().size();
    for (TagLib::ID3v2::Frame *frame : tag->frameList()) {
        const TagLib::ByteVector id = frame->frameID();
        const bool merged = (id == "TDAT" && date >= 10) || (id == "TIME" && date >= 16);
        bool dropped = (frame->header()->tagAlterPreservation() && !merged) || id.size() != 4;
        if (version == TagLib::ID3v2::v3) {
            for (const char *v4 : kV4Only) dropped = dropped || id == v4;
        }
        if (dropped) {
            Refuse(VibeTagWriteErrorWouldLoseData, "TagLib would drop the ID3v2 frame " + FrameName(frame));
        }
        if (version == TagLib::ID3v2::v3 && id == "TCON") {
            auto genre = dynamic_cast<TagLib::ID3v2::TextIdentificationFrame *>(frame);
            const TagLib::StringList genres = genre ? genre->fieldList() : TagLib::StringList();
            int unnumbered = 0;
            for (const TagLib::String &value : genres) {
                bool ok = false;
                const int number = value.toInt(&ok);
                const bool numbered = (ok && number >= 0 && number <= 255) || value == "RX" || value == "CR";
                if (!numbered && (genres.size() == 1 || TagLib::ID3v1::genreIndex(value) == 255)) unnumbered++;
            }
            if (unnumbered > 1) {
                Refuse(VibeTagWriteErrorWouldLoseData, "ID3v2.3 keeps only one genre without an ID3v1 number");
            }
        }
    }
}

TagLib::ID3v2::Version VersionToKeep(TagLib::ID3v2::Tag *tag, bool existed) {
    return existed && tag->header()->majorVersion() == 3 ? TagLib::ID3v2::v3 : TagLib::ID3v2::v4;
}

// The ID3v2 edit an MPEG, WAV, or AIFF file shares. TRAP: TagLib reads the
// first tag that is not empty, so a new or empty ID3v2 tag holding one
// field would hide every field of an ID3v1, APE, or INFO tag beside it. It
// first takes the fields the file reads today.
TagLib::ID3v2::Version ApplyID3v2Edits(TagLib::ID3v2::Tag *tag, bool existed, TagLib::File *file,
                                       const Edits &named, const Cover &cover) {
    CheckID3v2Frames(tag);
    const TagLib::ID3v2::Version version = VersionToKeep(tag, existed);
    if (!existed || tag->isEmpty()) {
        const TagLib::PropertyMap current = file->properties();
        if (!current.isEmpty()) tag->setProperties(current);
    }
    const Edits ops = Resolve(named, tag->properties(), Style::Folded, true);
    CheckID3v2Values(ops, version);
    ApplyID3v2Ops(tag, ops, version);
    ApplyID3v2Cover(tag, cover);
    CheckID3v2Render(tag, version);
    return version;
}

#pragma mark - Xiph comments

void ApplyXiphEdits(TagLib::Ogg::XiphComment *tag, const Edits &named) {
    for (const auto &[key, values] : Resolve(named, tag->properties(), Style::Xiph, false)) {
        tag->removeFields(key);
        for (const TagLib::String &value : values) tag->addField(key, value, false);
    }
}

// A FLAC file's picture blocks and a Xiph comment's pictures share the
// API, and the rule of ApplyID3v2Cover.
template <class Owner>
void ApplyPictureCover(Owner *owner, const Cover &cover) {
    if (!cover.change) return;
    bool hasFront = false;
    for (TagLib::FLAC::Picture *picture : owner->pictureList()) {
        if (picture->type() == TagLib::FLAC::Picture::FrontCover) hasFront = true;
    }
    const bool takeAll = cover.replaceAll || (cover.data.isEmpty() && !hasFront);
    const TagLib::List<TagLib::FLAC::Picture *> pictures = owner->pictureList();
    for (TagLib::FLAC::Picture *picture : pictures) {
        if (takeAll || picture->type() == TagLib::FLAC::Picture::FrontCover) owner->removePicture(picture, true);
    }
    if (cover.replaceAll) {
        for (const Record &record : cover.records) {
            auto picture = new TagLib::FLAC::Picture();
            picture->setType(static_cast<TagLib::FLAC::Picture::Type>(record.type));
            picture->setMimeType(record.mimeType);
            picture->setDescription(record.description);
            picture->setWidth(record.width);
            picture->setHeight(record.height);
            picture->setColorDepth(record.colorDepth);
            picture->setNumColors(record.colorCount);
            picture->setData(record.data);
            owner->addPicture(picture);
        }
        return;
    }
    if (cover.data.isEmpty()) return;
    auto picture = new TagLib::FLAC::Picture();
    picture->setType(TagLib::FLAC::Picture::FrontCover);
    picture->setMimeType(cover.mimeType);
    picture->setData(cover.data);
    owner->addPicture(picture);
}

#pragma mark - MP4

// A whole number from 0 to 65535, the range of MP4's numbers.
bool IsMP4Number(const TagLib::String &value) {
    if (value.isEmpty() || value.size() > 5) return false;
    for (unsigned int i = 0; i < value.size(); i++) {
        if (value[i] < '0' || value[i] > '9') return false;
    }
    return value.toInt() <= 65535;
}

void CheckMP4Value(const TagLib::ByteVector &name, const TagLib::String &key, const TagLib::StringList &values) {
    const bool pair = name == "trkn" || name == "disk";
    const bool number = name == "tmpo" || name == "cpil";
    if (!pair && !number) return;
    bool ok = values.size() == 1;
    if (ok && pair) {
        TagLib::String first, second;
        SplitPair(values, &first, &second);
        ok = IsMP4Number(first) && (second.isEmpty() || IsMP4Number(second));
    }
    else if (ok) {
        ok = IsMP4Number(First(values)) && (name != "cpil" || First(values).toInt() <= 1);
    }
    if (!ok) {
        Refuse(VibeTagWriteErrorUnsupportedValue,
               "MP4 holds " + Text(key) + " as one whole number from 0 to 65535, not " + Text(values.toString(", ")));
    }
}

void ApplyMP4Edits(TagLib::MP4::Tag *tag, const Edits &named) {
    TagLib::MP4::ItemFactory *factory = TagLib::MP4::ItemFactory::instance();
    const Edits ops = Resolve(named, tag->properties(), Style::Folded, false);
    for (const auto &[key, values] : ops) {
        if (!values.isEmpty()) CheckMP4Value(factory->itemFromProperty(key, values).first, key, values);
    }
    for (const auto &[key, values] : ops) {
        TagLib::StringList remove;
        for (const auto &[name, item] : tag->itemMap()) {
            if (factory->itemToProperty(name.data(TagLib::String::Latin1), item).first.upper() == key) {
                remove.append(name);
            }
        }
        // gnre, the ID3v1 genre number, is the genre too.
        if (key == "GENRE") remove.append("gnre");
        for (const TagLib::String &name : remove) tag->removeItem(name);
        if (values.isEmpty()) continue;
        auto [name, item] = factory->itemFromProperty(key, values);
        if (!item.isValid()) {
            Refuse(VibeTagWriteErrorUnsupportedValue, "MP4 cannot hold " + Text(key));
        }
        tag->setItem(TagLib::String(name, TagLib::String::Latin1), item);
    }
}

// MP4's pictures have no type. The first is the cover, which the read
// answers, and a replacement takes it. The read falls back to the next, so
// a removal takes every entry.
void ApplyMP4Cover(TagLib::MP4::Tag *tag, const Cover &cover) {
    if (!cover.change) return;
    TagLib::MP4::CoverArtList list = tag->item("covr").toCoverArtList();
    if (cover.replaceAll) {
        list.clear();
        for (const Record &record : cover.records) {
            TagLib::MP4::CoverArt::Format format = TagLib::MP4::CoverArt::Unknown;
            if (record.mimeType == "image/jpeg") format = TagLib::MP4::CoverArt::JPEG;
            else if (record.mimeType == "image/png") format = TagLib::MP4::CoverArt::PNG;
            else if (record.mimeType == "image/gif") format = TagLib::MP4::CoverArt::GIF;
            else if (record.mimeType == "image/bmp") format = TagLib::MP4::CoverArt::BMP;
            list.append(TagLib::MP4::CoverArt(format, record.data));
        }
    }
    else if (cover.data.isEmpty()) list.clear();
    else if (!list.isEmpty()) list.erase(list.begin());
    if (!cover.replaceAll && !cover.data.isEmpty()) {
        // TRAP: covr types only these four. TIFF or WebP would be an untyped
        // entry that Apple's readers need not show, so it is refused.
        TagLib::MP4::CoverArt::Format format;
        if (cover.mimeType == "image/jpeg") format = TagLib::MP4::CoverArt::JPEG;
        else if (cover.mimeType == "image/png") format = TagLib::MP4::CoverArt::PNG;
        else if (cover.mimeType == "image/gif") format = TagLib::MP4::CoverArt::GIF;
        else if (cover.mimeType == "image/bmp") format = TagLib::MP4::CoverArt::BMP;
        else Refuse(VibeTagWriteErrorInvalidImage, "MP4 cannot hold a " + Text(cover.mimeType) + " cover");
        list.prepend(TagLib::MP4::CoverArt(format, cover.data));
    }
    if (list.isEmpty()) tag->removeItem("covr");
    else tag->setItem("covr", TagLib::MP4::Item(list));
}

// TRAP: TagLib's MP4 save rewrites ilst from the items it parsed, so an
// item it could not parse, or a second item of one name, is lost. Each of
// the file's ilst children must be one of the parsed items.
void CheckMP4ItemsSurvive(NSString *path, TagLib::MP4::Tag *tag) {
    NSData *bytes = [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:NULL];
    std::vector<std::string> names;
    if (!bytes || !VibeMP4ItemNames((const uint8_t *)bytes.bytes, bytes.length, &names)) {
        Refuse(VibeTagWriteErrorNoParser, "the MP4's item list could not be read");
    }
    std::vector<std::string> parsed;
    for (const auto &[name, item] : tag->itemMap()) {
        const TagLib::ByteVector key = name.startsWith("----") ? name.data(TagLib::String::UTF8)
                                                               : name.data(TagLib::String::Latin1);
        parsed.emplace_back(key.data(), key.size());
    }
    for (const std::string &name : names) {
        const auto found = std::find(parsed.begin(), parsed.end(), name);
        if (found == parsed.end()) {
            Refuse(VibeTagWriteErrorWouldLoseData, "TagLib would drop the MP4 item " + name);
        }
        parsed.erase(found);
    }
}

#pragma mark - Per file

bool SaveFile(NSString *path, TagLib::File *file, const Edits &named, const Cover &cover) {
    if (auto mpeg = dynamic_cast<TagLib::MPEG::File *>(file)) {
        const bool hadID3v2 = mpeg->hasID3v2Tag(), hadAPE = mpeg->hasAPETag(), hadID3v1 = mpeg->hasID3v1Tag();
        const TagLib::ID3v2::Version version = ApplyID3v2Edits(mpeg->ID3v2Tag(true), hadID3v2, file, named, cover);
        int tags = TagLib::MPEG::File::ID3v2;
        if (hadAPE && ApplyByPropertyMap(mpeg->APETag(), named, Style::Folded)) tags |= TagLib::MPEG::File::APE;
        if (hadID3v1 && ApplyByPropertyMap(mpeg->ID3v1Tag(), named, Style::ID3v1)) tags |= TagLib::MPEG::File::ID3v1;
        return mpeg->save(tags, TagLib::File::StripNone, version, TagLib::File::DoNotDuplicate);
    }
    if (auto wav = dynamic_cast<TagLib::RIFF::WAV::File *>(file)) {
        const bool hadInfo = wav->hasInfoTag();
        const TagLib::ID3v2::Version version = ApplyID3v2Edits(wav->ID3v2Tag(), wav->hasID3v2Tag(), file, named, cover);
        int tags = TagLib::RIFF::WAV::File::ID3v2;
        // TRAP: an INFO chunk is rewritten only when the edit changes it.
        if (hadInfo && ApplyByPropertyMap(wav->InfoTag(), named, Style::Folded)) tags |= TagLib::RIFF::WAV::File::Info;
        return wav->save(static_cast<TagLib::RIFF::WAV::File::TagTypes>(tags), TagLib::File::StripNone, version);
    }
    if (auto aiff = dynamic_cast<TagLib::RIFF::AIFF::File *>(file)) {
        return aiff->save(ApplyID3v2Edits(aiff->tag(), aiff->hasID3v2Tag(), file, named, cover));
    }
    if (auto flac = dynamic_cast<TagLib::FLAC::File *>(file)) {
        // TRAP: FLAC's save renders its ID3v2 tag as 2.4, and copies the ID3
        // tags' fields into a missing Vorbis comment, so a removal would
        // not stick. A FLAC with ID3 tags is refused.
        if (flac->hasID3v2Tag() || flac->hasID3v1Tag()) {
            Refuse(VibeTagWriteErrorWouldLoseData, "the FLAC carries ID3 tags, which TagLib's save rewrites");
        }
        TagLib::Ogg::XiphComment *xiph = flac->xiphComment(true);
        ApplyXiphEdits(xiph, named);
        ApplyPictureCover(flac, cover);
        // TRAP: the save drops a block of 16 MiB or more and still succeeds.
        if (xiph->render(false).size() >= kMaxFLACBlockBytes) {
            Refuse(VibeTagWriteErrorWouldLoseData, "the Vorbis comment would pass FLAC's 16 MiB block");
        }
        for (TagLib::FLAC::Picture *picture : flac->pictureList()) {
            if (picture->render().size() >= kMaxFLACBlockBytes) {
                Refuse(VibeTagWriteErrorWouldLoseData, "a picture would pass FLAC's 16 MiB block");
            }
        }
        return flac->save();
    }
    // Vorbis and Opus, both tagged with a Xiph comment.
    if (auto xiph = dynamic_cast<TagLib::Ogg::XiphComment *>(file->tag())) {
        ApplyXiphEdits(xiph, named);
        ApplyPictureCover(xiph, cover);
        return file->save();
    }
    if (auto mp4 = dynamic_cast<TagLib::MP4::File *>(file)) {
        CheckMP4ItemsSurvive(path, mp4->tag());
        ApplyMP4Edits(mp4->tag(), named);
        ApplyMP4Cover(mp4->tag(), cover);
        return mp4->save();
    }
    Refuse(VibeTagWriteErrorNoParser, "no writer takes this format");
}

// The image type the bytes' signature names, or nil.
NSString *SniffedMIMEType(const void *bytes, size_t length) {
    const uint8_t *b = (const uint8_t *)bytes;
    auto starts = [&](const char *signature, size_t size, size_t at = 0) {
        return length >= at + size && memcmp(b + at, signature, size) == 0;
    };
    if (starts("\xFF\xD8\xFF", 3)) return @"image/jpeg";
    if (starts("\x89PNG\r\n\x1A\n", 8)) return @"image/png";
    if (starts("GIF87a", 6) || starts("GIF89a", 6)) return @"image/gif";
    if (starts("BM", 2) && length >= 26) return @"image/bmp";
    if (starts("II*\0", 4) || starts("MM\0*", 4)) return @"image/tiff";
    if (starts("RIFF", 4) && starts("WEBP", 4, 8)) return @"image/webp";
    return nil;
}

// A MIME type in the writer's spelling: lower case, with its aliases folded.
NSString *CanonicalMIMEType(NSString *mime) {
    NSString *lower = mime.lowercaseString;
    NSDictionary<NSString *, NSString *> *aliases = @{@"image/jpg": @"image/jpeg", @"image/pjpeg": @"image/jpeg",
                                                      @"image/x-ms-bmp": @"image/bmp", @"image/x-bmp": @"image/bmp",
                                                      @"image/tif": @"image/tiff"};
    return aliases[lower] ?: lower;
}

NSSet<NSString *> *EditedFields(void) {
    static NSSet<NSString *> *fields;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        fields = [NSSet setWithArray:VibeTagFieldsEdited()];
    });
    return fields;
}

} // namespace

namespace {
BOOL WriteFile(NSString *path, const Edits &edits, const Cover &cover, VibeTagWriteSync sync,
               NSError *__autoreleasing *error);
}

BOOL VibeTagLibWriteTagsWithSync(NSString *path, VibeTagFieldValues *fields, BOOL changeCover, NSData *coverData,
                                 NSString *coverMIMEType, VibeTagWriteSync sync, NSError *__autoreleasing *error) {
    Edits edits;
    for (NSString *key in fields) {
        NSString *field = key.uppercaseString;
        if (![EditedFields() containsObject:field]) {
            return Fail(error, VibeTagWriteErrorInvalidField, path,
                        [NSString stringWithFormat:@"\"%@\" is not a field the writer edits", key]);
        }
        TagLib::StringList values;
        for (NSString *value in fields[key]) {
            if (value.length > 0) values.append(TL(value));
        }
        edits[TL(field)] = values;
    }
    Cover cover;
    if (changeCover) {
        cover.change = true;
        if (coverData) {
            NSString *mime = CanonicalMIMEType(coverMIMEType ?: @"");
            if (![VibeTagCoverMIMETypes() containsObject:mime]) {
                return Fail(error, VibeTagWriteErrorInvalidImage, path,
                            [NSString stringWithFormat:@"A cover must be JPEG, PNG, GIF, BMP, TIFF, or WebP, not \"%@\"",
                                                       coverMIMEType]);
            }
            if (coverData.length == 0 || coverData.length > kMaxCoverBytes
                    || ![SniffedMIMEType(coverData.bytes, coverData.length) isEqualToString:mime]) {
                return Fail(error, VibeTagWriteErrorInvalidImage, path,
                            [NSString stringWithFormat:@"A cover must be %@ bytes, 1 to %lu of them",
                                                       mime, (unsigned long)kMaxCoverBytes]);
            }
            cover.data = TagLib::ByteVector((const char *)coverData.bytes, (unsigned int)coverData.length);
            cover.mimeType = TL(mime);
        }
    }
    return WriteFile(path, edits, cover, sync, error);
}

namespace {

BOOL WriteFile(NSString *path, const Edits &edits, const Cover &cover, VibeTagWriteSync sync,
               NSError *__autoreleasing *error) {
    // The barrier: no C++ exception leaves this call.
    try {
        const VibeInfoEncodingScope infoEncoding;
        TagLibAudioFile fileRef(path.fileSystemRepresentation, false, nil, 0, true);
        auto stream = dynamic_cast<VibeCheckedFileStream *>(fileRef.stream());
        if (!stream || !fileRef.streamIsOpen()) {
            return Fail(error, VibeTagWriteErrorOpenFailed, path, @"The file could not be opened");
        }
        if (fileRef.streamIsReadOnly()) {
            return Fail(error, VibeTagWriteErrorReadOnly, path, @"The file is read-only");
        }
        if (fileRef.isNull()) {
            return Fail(error, VibeTagWriteErrorNoParser, path, @"No tag parser takes the file");
        }
        // TRAP: MPEG::File takes any bytes as valid, so a text file named
        // .mp3 would gain a tag. A file with no MPEG frame is refused.
        auto mpeg = dynamic_cast<TagLib::MPEG::File *>(fileRef.file());
        if (mpeg && mpeg->firstFrameOffset() < 0) {
            return Fail(error, VibeTagWriteErrorNoParser, path, @"The file holds no MPEG frame");
        }
        if (!stream->failure().empty()) {
            Refuse(VibeTagWriteErrorSaveFailed, "the file could not be read: " + stream->failure());
        }
        const bool saved = SaveFile(path, fileRef.file(), edits, cover);
        const bool finished = stream->finish(sync == VibeTagWriteSyncBarrier ? VibeCheckedFileStream::Sync::Barrier
                                                                              : VibeCheckedFileStream::Sync::Full);
        if (!saved || !finished) {
            Refuse(VibeTagWriteErrorSaveFailed,
                   stream->failure().empty() ? "TagLib could not save the file" : stream->failure());
        }
        return YES;
    }
    catch (const Refusal &refusal) {
        return Fail(error, refusal.code, path, @(refusal.reason.c_str()) ?: @"The write was refused");
    }
    catch (const std::exception &e) {
        return Fail(error, VibeTagWriteErrorTagLibThrew, path, [NSString stringWithFormat:@"TagLib threw: %s", e.what()]);
    }
    catch (...) {
        return Fail(error, VibeTagWriteErrorTagLibThrew, path, @"TagLib threw");
    }
}

} // namespace

BOOL VibeTagLibWriteTags(NSString *path, VibeTagFieldValues *fields, BOOL changeCover, NSData *coverData,
                         NSString *coverMIMEType, NSError *__autoreleasing *error) {
    return VibeTagLibWriteTagsWithSync(path, fields, changeCover, coverData, coverMIMEType, VibeTagWriteSyncFull, error);
}

BOOL VibeTagLibWriteFields(NSString *path, VibeTagFieldValues *fields, NSError *__autoreleasing *error) {
    return VibeTagLibWriteTags(path, fields, NO, nil, nil, error);
}

BOOL VibeTagLibWriteFrontCover(NSString *path, NSData *data, NSString *mimeType, NSError *__autoreleasing *error) {
    return VibeTagLibWriteTags(path, nil, YES, data, mimeType, error);
}

NSArray<NSString *> *VibeTagCoverMIMETypes(void) {
    return @[@"image/jpeg", @"image/png", @"image/gif", @"image/bmp", @"image/tiff", @"image/webp"];
}

@implementation VibeTagPicture

- (instancetype)initWithData:(NSData *)data mimeType:(NSString *)mimeType type:(VibeTagPictureType)type
                 description:(NSString *)pictureDescription {
    return [self initWithData:data mimeType:mimeType type:type description:pictureDescription width:0 height:0
                   colorDepth:0 colorCount:0];
}

- (instancetype)initWithData:(NSData *)data mimeType:(NSString *)mimeType type:(VibeTagPictureType)type
                 description:(NSString *)pictureDescription width:(NSUInteger)width height:(NSUInteger)height
                  colorDepth:(NSUInteger)colorDepth colorCount:(NSUInteger)colorCount {
    if ((self = [super init])) {
        _data = [data copy];
        _mimeType = [mimeType copy];
        _type = type;
        _pictureDescription = [pictureDescription copy] ?: @"";
        _width = width;
        _height = height;
        _colorDepth = colorDepth;
        _colorCount = colorCount;
    }
    return self;
}

- (NSString *)imageMIMEType {
    NSString *sniffed = SniffedMIMEType(_data.bytes, _data.length);
    if (sniffed) return sniffed;
    return _mimeType.length ? CanonicalMIMEType(_mimeType) : nil;
}

- (BOOL)isEqual:(id)object {
    if (![object isKindOfClass:VibeTagPicture.class]) return NO;
    VibeTagPicture *other = object;
    return [_data isEqualToData:other.data] && (_mimeType == other.mimeType || [_mimeType isEqual:other.mimeType])
            && _type == other.type && [_pictureDescription isEqualToString:other.pictureDescription]
            && _width == other.width && _height == other.height && _colorDepth == other.colorDepth
            && _colorCount == other.colorCount;
}

- (NSUInteger)hash {
    return _data.hash ^ (NSUInteger)_type;
}

- (NSString *)description {
    return [NSString stringWithFormat:@"<VibeTagPicture type %ld, %@, \"%@\", %lu bytes, %lux%lu>", (long)_type,
                                      _mimeType, _pictureDescription, (unsigned long)_data.length,
                                      (unsigned long)_width, (unsigned long)_height];
}

@end

namespace {

NSData *Data(const TagLib::ByteVector &bytes) {
    return [NSData dataWithBytes:bytes.data() length:bytes.size()];
}

// The tag's MIME string, or nil for none.
NSString *StoredMIMEType(const TagLib::String &mime) {
    return mime.isEmpty() ? nil : NS(mime);
}

NSArray<VibeTagPicture *> *PicturesOfID3v2(TagLib::ID3v2::Tag *tag) {
    NSMutableArray<VibeTagPicture *> *pictures = [NSMutableArray array];
    if (!tag) return pictures;
    for (TagLib::ID3v2::Frame *frame : tag->frameList("APIC")) {
        auto picture = dynamic_cast<TagLib::ID3v2::AttachedPictureFrame *>(frame);
        if (!picture) continue;
        [pictures addObject:[[VibeTagPicture alloc] initWithData:Data(picture->picture())
                                                        mimeType:StoredMIMEType(picture->mimeType())
                                                            type:(VibeTagPictureType)picture->type()
                                                     description:NS(picture->description())]];
    }
    return pictures;
}

NSArray<VibeTagPicture *> *PicturesOfList(const TagLib::List<TagLib::FLAC::Picture *> &list) {
    NSMutableArray<VibeTagPicture *> *pictures = [NSMutableArray array];
    for (TagLib::FLAC::Picture *picture : list) {
        [pictures addObject:[[VibeTagPicture alloc] initWithData:Data(picture->data()) mimeType:StoredMIMEType(picture->mimeType())
                                                            type:(VibeTagPictureType)picture->type()
                                                     description:NS(picture->description())
                                                           width:(NSUInteger)std::max(0, picture->width())
                                                          height:(NSUInteger)std::max(0, picture->height())
                                                      colorDepth:(NSUInteger)std::max(0, picture->colorDepth())
                                                      colorCount:(NSUInteger)std::max(0, picture->numColors())]];
    }
    return pictures;
}

NSArray<VibeTagPicture *> *PicturesOfMP4(TagLib::MP4::Tag *tag) {
    NSMutableArray<VibeTagPicture *> *pictures = [NSMutableArray array];
    for (const TagLib::MP4::CoverArt &art : tag->item("covr").toCoverArtList()) {
        NSString *typed = nil;
        switch (art.format()) {
            case TagLib::MP4::CoverArt::JPEG: typed = @"image/jpeg"; break;
            case TagLib::MP4::CoverArt::PNG: typed = @"image/png"; break;
            case TagLib::MP4::CoverArt::GIF: typed = @"image/gif"; break;
            case TagLib::MP4::CoverArt::BMP: typed = @"image/bmp"; break;
            default: break;
        }
        [pictures addObject:[[VibeTagPicture alloc] initWithData:Data(art.data()) mimeType:typed
                                                            type:VibeTagPictureTypeUntyped description:@""]];
    }
    return pictures;
}

// Which picture the art read shows: the first front cover with bytes, else
// the first picture with bytes (TagLibAudioFile.mm, albumArtDataFromTagLibFile).
NSUInteger ShownIndex(NSArray<VibeTagPicture *> *pictures) {
    NSUInteger fallback = NSNotFound;
    for (NSUInteger i = 0; i < pictures.count; i++) {
        if (pictures[i].data.length == 0) continue;
        if (pictures[i].type == VibeTagPictureTypeFrontCover) return i;
        if (fallback == NSNotFound) fallback = i;
    }
    return fallback;
}

} // namespace

BOOL VibeTagLibReadPictures(NSString *path, NSArray<VibeTagPicture *> *__autoreleasing *pictures,
                            NSUInteger *shownIndex, NSError *__autoreleasing *error) {
    NSArray<VibeTagPicture *> *found = @[];
    try {
        TagLibAudioFile fileRef(path.fileSystemRepresentation, false);
        if (fileRef.isNull()) {
            return Fail(error, VibeTagWriteErrorNoParser, path, @"No tag parser takes the file");
        }
        TagLib::File *file = fileRef.file();
        if (auto mpeg = dynamic_cast<TagLib::MPEG::File *>(file)) {
            found = PicturesOfID3v2(mpeg->hasID3v2Tag() ? mpeg->ID3v2Tag() : nullptr);
        }
        else if (auto wav = dynamic_cast<TagLib::RIFF::WAV::File *>(file)) {
            found = PicturesOfID3v2(wav->hasID3v2Tag() ? wav->ID3v2Tag() : nullptr);
        }
        else if (auto aiff = dynamic_cast<TagLib::RIFF::AIFF::File *>(file)) {
            found = PicturesOfID3v2(aiff->hasID3v2Tag() ? aiff->tag() : nullptr);
        }
        else if (auto flac = dynamic_cast<TagLib::FLAC::File *>(file)) {
            found = PicturesOfList(flac->pictureList());
        }
        else if (auto xiph = dynamic_cast<TagLib::Ogg::XiphComment *>(file->tag())) {
            found = PicturesOfList(xiph->pictureList());
        }
        else if (auto mp4 = dynamic_cast<TagLib::MP4::File *>(file)) {
            found = PicturesOfMP4(mp4->tag());
        }
    }
    catch (const std::exception &e) {
        return Fail(error, VibeTagWriteErrorTagLibThrew, path, [NSString stringWithFormat:@"TagLib threw: %s", e.what()]);
    }
    catch (...) {
        return Fail(error, VibeTagWriteErrorTagLibThrew, path, @"TagLib threw");
    }
    if (pictures) *pictures = found;
    if (shownIndex) *shownIndex = ShownIndex(found);
    return YES;
}

BOOL VibeTagLibReadCover(NSString *path, NSData *__autoreleasing *data, NSString *__autoreleasing *mimeType,
                         NSError *__autoreleasing *error) {
    NSArray<VibeTagPicture *> *pictures = nil;
    NSUInteger shown = NSNotFound;
    if (!VibeTagLibReadPictures(path, &pictures, &shown, error)) return NO;
    VibeTagPicture *picture = shown == NSNotFound ? nil : pictures[shown];
    if (data) *data = picture.data;
    if (mimeType) *mimeType = picture.imageMIMEType;
    return YES;
}

BOOL VibeTagLibWritePictures(NSString *path, NSArray<VibeTagPicture *> *pictures, VibeTagWriteSync sync,
                             NSError *__autoreleasing *error) {
    Cover cover;
    cover.change = true;
    cover.replaceAll = true;
    for (VibeTagPicture *picture in pictures) {
        if (picture.data.length == 0 || picture.type < VibeTagPictureTypeUntyped || picture.type > 20) {
            return Fail(error, VibeTagWriteErrorInvalidImage, path,
                        [NSString stringWithFormat:@"A picture must hold bytes and a type from -1 to 20, not %@",
                                                   picture]);
        }
        Record record;
        record.data = TagLib::ByteVector((const char *)picture.data.bytes, (unsigned int)picture.data.length);
        record.mimeType = TL(picture.mimeType ?: @"");
        record.type = picture.type == VibeTagPictureTypeUntyped ? (int)VibeTagPictureTypeOther : (int)picture.type;
        record.description = TL(picture.pictureDescription);
        record.width = (int)std::min<NSUInteger>(picture.width, INT_MAX);
        record.height = (int)std::min<NSUInteger>(picture.height, INT_MAX);
        record.colorDepth = (int)std::min<NSUInteger>(picture.colorDepth, INT_MAX);
        record.colorCount = (int)std::min<NSUInteger>(picture.colorCount, INT_MAX);
        cover.records.push_back(record);
    }
    return WriteFile(path, Edits(), cover, sync, error);
}

VibeTagFieldValues *VibeTagLibReadFields(NSString *path, NSError *__autoreleasing *error) {
    try {
        TagLibAudioFile fileRef(path.fileSystemRepresentation, false);
        if (fileRef.isNull()) {
            Fail(error, VibeTagWriteErrorNoParser, path, @"No tag parser takes the file");
            return nil;
        }
        const TagLib::PropertyMap properties = fileRef.file()->properties();
        NSMutableDictionary<VibeTagField, NSArray<NSString *> *> *fields = [NSMutableDictionary dictionary];
        for (const auto &[key, values] : properties) {
            NSMutableArray<NSString *> *strings = [NSMutableArray array];
            for (const TagLib::String &value : values) [strings addObject:NS(value)];
            fields[NS(key.upper())] = strings;
        }
        for (const NumberKeys &keys : kNumberKeys) {
            TagLib::String number, total;
            SplitPair(properties.value(keys.number), &number, &total);
            if (total.isEmpty()) total = First(properties.value(keys.total));
            if (total.isEmpty()) total = First(properties.value(keys.alias));
            [fields removeObjectForKey:@(keys.alias)];
            [fields removeObjectForKey:@(keys.total)];
            if (number.isEmpty()) [fields removeObjectForKey:@(keys.number)];
            else fields[@(keys.number)] = @[NS(number)];
            if (!total.isEmpty()) fields[@(keys.total)] = @[NS(total)];
        }
        return fields;
    }
    catch (const std::exception &e) {
        Fail(error, VibeTagWriteErrorTagLibThrew, path, [NSString stringWithFormat:@"TagLib threw: %s", e.what()]);
    }
    catch (...) {
        Fail(error, VibeTagWriteErrorTagLibThrew, path, @"TagLib threw");
    }
    return nil;
}
