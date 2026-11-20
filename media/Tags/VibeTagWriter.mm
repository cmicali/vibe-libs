//
//  VibeTagWriter.mm
//  vibe-libs
//

#import "VibeTagWriter.h"
#import "NSString+CPPStrings.h"
#import "TagLibAudioFile.h"
#import "VibeMacros.h"

#include <algorithm>
#include <memory>
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
#include <popularimeterframe.h>
#include <opusfile.h>
// TagLib's own doc comment in this header fails -Wdocumentation-html.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdocumentation-html"
#include <textidentificationframe.h>
#pragma clang diagnostic pop
#include <tbytevectorstream.h>
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

// A picture to add, as its tag will store it.
struct Record {
    TagLib::ByteVector data;
    TagLib::String mimeType;
    // ID3v2's numbering, or -1 for an MP4 entry's none, which the typed
    // formats write as "other" (0).
    int type = 3;
    TagLib::String description;
    int width = 0, height = 0, colorDepth = 0, colorCount = 0;
};

// MP4's entries hold no type, so a picture fits one only when it has none,
// or is the front cover an entry stands for. The reason when it does not,
// or empty.
std::string MP4PictureTypeFault(int type) {
    if (type == -1 || type == 3) return "";
    return "MP4 holds no picture type but none or a front cover, not " + std::to_string(type);
}

// What a write does to the pictures. Cover takes the cover (CoverIndexes),
// All takes every picture. Then `add` goes in, in order. A cover write adds
// one front cover, a removal adds nothing, and VibeTagLibWritePictures
// takes All and adds what it was given.
struct Cover {
    enum class Take { None, Cover, All };
    Take take = Take::None;
    std::vector<Record> add;
    // The format's own indexes of the pictures Take::Cover takes, set by
    // SaveFile before the edit.
    std::vector<size_t> taken;
    bool takes(size_t index) const {
        return take == Take::All || std::find(taken.begin(), taken.end(), index) != taken.end();
    }
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

// Whether a picture fits a FLAC block: its type, its two lengths, four
// sizes, and its data's length are 32 bytes, then its MIME type, its
// description in UTF-8, and its data. TRAP: FLAC's save drops a block of
// 16 MiB or more and still succeeds.
uint64_t FLACPictureBlockBytes(uint64_t mime, uint64_t description, uint64_t data) {
    return 32 + mime + description + data;
}

bool FitsFLACBlock(uint64_t mime, uint64_t description, uint64_t data) {
    return FLACPictureBlockBytes(mime, description, data) < kMaxFLACBlockBytes;
}

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
const char *aliases[3];
};
constexpr Aliases kAliases[] = {
    {"COMMENT", {"DESCRIPTION", nullptr}},
    {"LABEL", {"ORGANIZATION", "PUBLISHER"}},
    {"ORIGINALDATE", {"ORIGINAL DATE", "ORIGINALYEAR", "ORIGINAL YEAR"}},
    {"CATALOGNUMBER", {"CATALOGID"}},
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

#pragma mark - Ratings

bool IsRatingKey(const TagLib::String &key) {
    return VibeTagFieldIsRating(NS(key));
}

bool IsPopularimeterKey(const TagLib::String &key) {
    return key.startsWith(TL(VibeTagFieldPopularimeterPrefix));
}

// The edits without the ratings, for a tag that holds none: APE, ID3v1, and
// INFO, beside the tag that does.
Edits WithoutRatings(const Edits &named) {
    Edits kept;
    for (const auto &[key, values] : named) {
        if (!IsRatingKey(key)) kept[key] = values;
    }
    return kept;
}

// A POPM rating byte, 1 to 255, from its one value, or 0 for none.
int PopularimeterRating(const TagLib::String &key, const TagLib::StringList &values) {
    if (values.isEmpty()) return 0;
    const TagLib::String value = First(values);
    bool digits = values.size() == 1 && !value.isEmpty() && value.size() <= 3;
    for (unsigned int i = 0; digits && i < value.size(); i++) digits = value[i] >= '0' && value[i] <= '9';
    if (!digits || value.toInt() < 1 || value.toInt() > 255) {
        Refuse(VibeTagWriteErrorUnsupportedValue,
               Text(key) + " holds one rating from 1 to 255, not " + Text(values.toString(", ")));
    }
    return value.toInt();
}

// Sets every POPM frame of the email to the rating, keeping its counter. A
// removal takes a frame with no plays counted, and sets a counted one's
// rating to 0, so its count stays.
void ApplyPopularimeter(TagLib::ID3v2::Tag *tag, const TagLib::String &key, const TagLib::StringList &values) {
    const TagLib::String email = key.substr(TL(VibeTagFieldPopularimeterPrefix).size());
    const int rating = PopularimeterRating(key, values);
    TagLib::ID3v2::FrameList remove;
    bool found = false;
    for (TagLib::ID3v2::Frame *frame : tag->frameListMap().value("POPM")) {
        auto popm = dynamic_cast<TagLib::ID3v2::PopularimeterFrame *>(frame);
        if (!popm || popm->email() != email) continue;
        found = true;
        if (rating == 0 && popm->counter() == 0) remove.append(frame);
        else popm->setRating(rating);
    }
    for (TagLib::ID3v2::Frame *frame : remove) tag->removeFrame(frame, true);
    if (!found && rating > 0) {
        auto popm = new TagLib::ID3v2::PopularimeterFrame();
        popm->setEmail(email);
        popm->setRating(rating);
        tag->addFrame(popm);
    }
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
    for (const auto &[key, values] : Resolve(WithoutRatings(named), before, style, false)) {
        if (values.isEmpty()) properties.erase(key);
        else properties.replace(key, values);
    }
    tag->setProperties(properties);
    return tag->properties() != before;
}

#pragma mark - ID3v2

// Frame::asProperties is protected, but the text, TXXX, and comment frames
// that hold every edited field make theirs public. Another frame holds the
// key its ID maps to. A null frame holds no key. No frame list holds one,
// but the static analyzer reads the casts below as saying one could come.
bool FrameHoldsKey(TagLib::ID3v2::Frame *frame, const TagLib::String &key) {
    if (!frame) {
        return false;
    }
    if (auto comment = dynamic_cast<TagLib::ID3v2::CommentsFrame *>(frame)) {
        return comment->asProperties().contains(key);
    }
    if (auto text = dynamic_cast<TagLib::ID3v2::TextIdentificationFrame *>(frame)) {
        // UserTextIdentificationFrame derives from it and overrides it.
        return text->asProperties().contains(key);
    }
    return TagLib::ID3v2::Frame::frameIDToKey(frame->frameID()) == key;
}

// Removes each frame that holds a key, then adds the key's frame. TIPL and
// TMCL hold several keys, and none of the edited fields.
void ApplyID3v2Ops(TagLib::ID3v2::Tag *tag, const Edits &ops, TagLib::ID3v2::Version version) {
    for (const auto &[key, values] : ops) {
        if (IsPopularimeterKey(key)) {
            ApplyPopularimeter(tag, key, values);
            continue;
        }
        if (key.startsWith(TL(VibeTagFieldRatingPrefix))) {
            Refuse(VibeTagWriteErrorUnsupportedValue, "only a Xiph comment holds " + Text(key));
        }
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
        // FMPS spells its frame's description so. TagLib's would be upper case.
        if (key == "FMPS_RATING") {
            tag->addFrame(new TagLib::ID3v2::UserTextIdentificationFrame("FMPS_Rating", values, TagLib::String::UTF8));
            continue;
        }
        tag->addFrame(TagLib::ID3v2::FrameFactory::instance()->createFrameForProperty(key, values));
    }
}

TagLib::ID3v2::AttachedPictureFrame *NewAPIC(const Record &record) {
    auto frame = new TagLib::ID3v2::AttachedPictureFrame();
    frame->setTextEncoding(TagLib::String::UTF8);
    frame->setMimeType(record.mimeType);
    frame->setType(static_cast<TagLib::ID3v2::AttachedPictureFrame::Type>(std::max(record.type, 0)));
    frame->setDescription(record.description);
    frame->setPicture(record.data);
    return frame;
}

// The pictures in their new order: each one kept where it was, and the
// added ones where the first taken one was, or at the end when none was.
template <class Picture, class Make>
std::vector<Picture> Arrange(const std::vector<Picture> &existing, const Cover &cover, Make make,
                             std::vector<Picture> *taken) {
    std::vector<Picture> arranged;
    bool added = false;
    for (size_t index = 0; index < existing.size(); index++) {
        if (!cover.takes(index)) {
            arranged.push_back(existing[index]);
            continue;
        }
        taken->push_back(existing[index]);
        if (added) continue;
        for (const Record &record : cover.add) arranged.push_back(make(record));
        added = true;
    }
    if (!added) {
        for (const Record &record : cover.add) arranged.push_back(make(record));
    }
    return arranged;
}

// The APIC frames VibeEmbeddedPictures indexes, empty ones counted. A tag
// keeps no picture's place but by its order, so every APIC frame leaves and
// comes back in the new order, after the tag's other frames.
void ApplyID3v2Cover(TagLib::ID3v2::Tag *tag, const Cover &cover) {
    if (cover.take == Cover::Take::None) return;
    std::vector<TagLib::ID3v2::Frame *> existing, taken;
    for (TagLib::ID3v2::Frame *frame : tag->frameList("APIC")) {
        if (dynamic_cast<TagLib::ID3v2::AttachedPictureFrame *>(frame)) existing.push_back(frame);
    }
    const std::vector<TagLib::ID3v2::Frame *> arranged = Arrange<TagLib::ID3v2::Frame *>(
            existing, cover, [](const Record &record) -> TagLib::ID3v2::Frame * { return NewAPIC(record); }, &taken);
    for (TagLib::ID3v2::Frame *frame : existing) tag->removeFrame(frame, false);
    for (TagLib::ID3v2::Frame *frame : taken) delete frame;
    for (TagLib::ID3v2::Frame *frame : arranged) tag->addFrame(frame);
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
// TMOO, TPRO, and TSST. Those that hold a property make a 2.3 tag 2.4
// first (V3ReadsBack), so only the rest reach this refusal.
void CheckID3v2Render(TagLib::ID3v2::Tag *tag, TagLib::ID3v2::Version version) {
    static const char *const kV4Only[] = {"ASPI", "EQU2", "RVA2", "SEEK", "SIGN", "TDRL", "TDTG", "TMOO",
                                          "TPRO", "TSST"};
    // TagLib's parse merges ID3v2.3's TDAT into the one TDRC when it holds a
    // year alone, and TIME too when TDAT merged, leaving them marked.
    // Merged, they are no loss.
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
    }
}

// A file over a stream, so TagLib's ID3v2 parse can read a tag from bytes.
class BytesFile : public TagLib::File {
public:
    explicit BytesFile(TagLib::IOStream *stream) : TagLib::File(stream) {}
    TagLib::Tag *tag() const override { return nullptr; }
    TagLib::AudioProperties *audioProperties() const override { return nullptr; }
    bool save() override { return false; }
};

// The one rule for ID3v2.3: a 2.3 tag is written as 2.4 when its 2.3 render
// would not read back what the tag holds after the edit. The render is
// parsed again, as any reader would, and its properties compared. So it
// catches each way the 2.3 render loses: its genres, whose names or order
// change (TagLib keeps one genre without an ID3v1 number, puts numbered
// ones first, and renames some by their number), its dates, which it cuts
// to a year, a day, or a minute, a time it drops after TagLib's own merge,
// and a frame it holds twice, of which it keeps one. ID3v2.4 holds them all.
bool V3ReadsBack(TagLib::ID3v2::Tag *tag) {
    TagLib::ByteVectorStream stream(tag->render(TagLib::ID3v2::v3));
    BytesFile file(&stream);
    const TagLib::ID3v2::Tag reparsed(&file, 0);
    return reparsed.properties() == tag->properties();
}

// The ID3v2 edit an MPEG, WAV, or AIFF file shares. TRAP: TagLib reads the
// first tag that is not empty, so a new or empty ID3v2 tag holding one
// field would hide every field of an ID3v1, APE, or INFO tag beside it. It
// first takes the fields the file reads today.
//
// An existing tag keeps its version, but a 2.2 tag, which TagLib cannot
// write, and a 2.3 tag V3ReadsBack refuses become 2.4, and *upgraded says
// so. TagLib's parse already holds a 2.3 tag as 2.4 frames, so the 2.4
// render keeps what the 2.3 one would. The frames both drop stay refused
// (CheckID3v2Render).
TagLib::ID3v2::Version ApplyID3v2Edits(TagLib::ID3v2::Tag *tag, bool existed, TagLib::File *file,
                                       const Edits &named, const Cover &cover, bool *upgraded) {
    CheckID3v2Frames(tag);
    const unsigned int major = existed ? tag->header()->majorVersion() : 4;
    TagLib::ID3v2::Version version = major == 3 ? TagLib::ID3v2::v3 : TagLib::ID3v2::v4;
    if (!existed || tag->isEmpty()) {
        const TagLib::PropertyMap current = file->properties();
        if (!current.isEmpty()) tag->setProperties(current);
    }
    const Edits ops = Resolve(named, tag->properties(), Style::Folded, true);
    ApplyID3v2Ops(tag, ops, version);
    ApplyID3v2Cover(tag, cover);
    if (version == TagLib::ID3v2::v3 && !V3ReadsBack(tag)) version = TagLib::ID3v2::v4;
    *upgraded = existed && major < 4 && version == TagLib::ID3v2::v4;
    CheckID3v2Render(tag, version);
    return version;
}

#pragma mark - Xiph comments

void ApplyXiphEdits(TagLib::Ogg::XiphComment *tag, const Edits &named) {
    for (const auto &[key, values] : named) {
        if (IsPopularimeterKey(key)) Refuse(VibeTagWriteErrorUnsupportedValue, "only ID3v2 holds " + Text(key));
    }
    for (const auto &[key, values] : Resolve(named, tag->properties(), Style::Xiph, false)) {
        tag->removeFields(key);
        for (const TagLib::String &value : values) tag->addField(key, value, false);
    }
}

TagLib::FLAC::Picture *NewPicture(const Record &record) {
    auto picture = new TagLib::FLAC::Picture();
    picture->setType(static_cast<TagLib::FLAC::Picture::Type>(std::max(record.type, 0)));
    picture->setMimeType(record.mimeType);
    picture->setDescription(record.description);
    picture->setWidth(record.width);
    picture->setHeight(record.height);
    picture->setColorDepth(record.colorDepth);
    picture->setNumColors(record.colorCount);
    picture->setData(record.data);
    return picture;
}

// A FLAC file's picture blocks and a Xiph comment's pictures share the API.
template <class Owner>
void ApplyPictureCover(Owner *owner, const Cover &cover) {
    if (cover.take == Cover::Take::None) return;
    // TRAP: never hold a copy of pictureList(). It shares the list's
    // auto-delete, so the copy deletes the pictures a second time.
    std::vector<TagLib::FLAC::Picture *> existing, taken;
    for (TagLib::FLAC::Picture *picture : owner->pictureList()) existing.push_back(picture);
    const std::vector<TagLib::FLAC::Picture *> arranged = Arrange<TagLib::FLAC::Picture *>(
            existing, cover, [](const Record &record) { return NewPicture(record); }, &taken);
    for (TagLib::FLAC::Picture *picture : existing) owner->removePicture(picture, false);
    for (TagLib::FLAC::Picture *picture : taken) delete picture;
    for (TagLib::FLAC::Picture *picture : arranged) owner->addPicture(picture);
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

// Takes out every item that reads as the key, and the extra items named.
void RemoveMP4Items(TagLib::MP4::Tag *tag, const TagLib::String &key, const TagLib::StringList &extra) {
    TagLib::MP4::ItemFactory *factory = TagLib::MP4::ItemFactory::instance();
    TagLib::StringList remove = extra;
    for (const auto &[name, item] : tag->itemMap()) {
        if (factory->itemToProperty(name.data(TagLib::String::Latin1), item).first.upper() == key) {
            remove.append(name);
        }
    }
    for (const TagLib::String &name : remove) tag->removeItem(name);
}

// MP4's ratings: RATING is the rate atom, which TagLib's property map does
// not name, and FMPS_RATING a freeform atom spelled as FMPS spells it. Each
// replaces every item that reads as its key.
void ApplyMP4Ratings(TagLib::MP4::Tag *tag, const Edits &named) {
    for (const auto &[key, values] : named) {
        if (!IsRatingKey(key)) continue;
        if (key != "RATING" && key != "FMPS_RATING") {
            Refuse(VibeTagWriteErrorUnsupportedValue, "MP4 does not hold " + Text(key));
        }
        RemoveMP4Items(tag, key, key == "RATING" ? TagLib::StringList("rate") : TagLib::StringList());
        if (values.isEmpty()) continue;
        tag->setItem(key == "RATING" ? "rate" : "----:com.apple.iTunes:FMPS_Rating", TagLib::MP4::Item(values));
    }
}

void ApplyMP4Edits(TagLib::MP4::Tag *tag, const Edits &named) {
    TagLib::MP4::ItemFactory *factory = TagLib::MP4::ItemFactory::instance();
    ApplyMP4Ratings(tag, named);
    const Edits ops = Resolve(WithoutRatings(named), tag->properties(), Style::Folded, false);
    for (const auto &[key, values] : ops) {
        if (!values.isEmpty()) CheckMP4Value(factory->itemFromProperty(key, values).first, key, values);
    }
    for (const auto &[key, values] : ops) {
        // gnre, the ID3v1 genre number, is the genre too.
        RemoveMP4Items(tag, key, key == "GENRE" ? TagLib::StringList("gnre") : TagLib::StringList());
        if (values.isEmpty()) continue;
        auto [name, item] = factory->itemFromProperty(key, values);
        if (!item.isValid()) {
            Refuse(VibeTagWriteErrorUnsupportedValue, "MP4 cannot hold " + Text(key));
        }
        tag->setItem(TagLib::String(name, TagLib::String::Latin1), item);
    }
}

// MP4's pictures have no type, so each is the cover's (CoverIndexes). A new
// cover goes first, where the read finds it.
void ApplyMP4Cover(TagLib::MP4::Tag *tag, const Cover &cover) {
    if (cover.take == Cover::Take::None) return;
    for (const Record &record : cover.add) {
        // TRAP: covr types only JPEG, PNG, GIF, and BMP. A new TIFF or WebP
        // cover would be untyped, which Apple's readers need not show. An
        // untyped picture put back as it was is no new cover.
        if (cover.take != Cover::Take::All && VibeMP4FormatOfMIMEType(record.mimeType) == TagLib::MP4::CoverArt::Unknown) {
            Refuse(VibeTagWriteErrorInvalidImage, "MP4 cannot hold a " + Text(record.mimeType) + " cover");
        }
        const std::string fault = MP4PictureTypeFault(record.type);
        if (!fault.empty()) Refuse(VibeTagWriteErrorInvalidImage, fault);
    }
    std::vector<TagLib::MP4::CoverArt> existing, taken;
    for (const TagLib::MP4::CoverArt &art : tag->item("covr").toCoverArtList()) existing.push_back(art);
    const std::vector<TagLib::MP4::CoverArt> arranged = Arrange<TagLib::MP4::CoverArt>(
            existing, cover, [](const Record &record) {
                return TagLib::MP4::CoverArt(
                        static_cast<TagLib::MP4::CoverArt::Format>(VibeMP4FormatOfMIMEType(record.mimeType)), record.data);
            }, &taken);
    TagLib::MP4::CoverArtList list;
    for (const TagLib::MP4::CoverArt &art : arranged) list.append(art);
    if (list.isEmpty()) tag->removeItem("covr");
    else tag->setItem("covr", TagLib::MP4::Item(list));
}

// TRAP: TagLib's MP4 save rewrites ilst from the items it parsed, so an
// item it could not parse, or a second item of one name, is lost. Each of
// the file's ilst children must be one of the parsed items.
void CheckMP4ItemsSurvive(NSString *path, TagLib::MP4::Tag *tag, const Edits &named) {
    NSData *bytes = [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:NULL];
    // TRAP: TagLib reads a numeric rate by its first two bytes, and saves
    // what it read, so any other edit would destroy another app's rating
    // held in another width.
    if (bytes && !named.contains("RATING") && VibeMP4RateIsUnkept((const uint8_t *)bytes.bytes, bytes.length)) {
        Refuse(VibeTagWriteErrorWouldLoseData, "TagLib would save the MP4's rate atom, a number not of 2 bytes, as another");
    }
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

// The pictures a cover write or removal takes: every front cover, or when
// the file has none, the one picture the art read shows, whatever its
// type. So the picture the user sees is always the one taken, and a
// picture that never showed is never taken.
std::vector<size_t> CoverIndexes(TagLib::File *file) {
    const std::vector<VibeEmbeddedPicture> pictures = VibeEmbeddedPictures(file);
    std::vector<size_t> taken;
    for (const VibeEmbeddedPicture &picture : pictures) {
        if (picture.type == 3) taken.push_back(picture.index);
    }
    const size_t shown = VibeShownPicture(pictures);
    if (taken.empty() && shown != SIZE_MAX) taken.push_back(pictures[shown].index);
    return taken;
}

bool SaveFile(NSString *path, TagLib::File *file, const Edits &named, const Cover &asked, bool *upgraded) {
    Cover cover = asked;
    if (cover.take == Cover::Take::Cover) cover.taken = CoverIndexes(file);
    if (auto mpeg = dynamic_cast<TagLib::MPEG::File *>(file)) {
        const bool hadID3v2 = mpeg->hasID3v2Tag(), hadAPE = mpeg->hasAPETag(), hadID3v1 = mpeg->hasID3v1Tag();
        const TagLib::ID3v2::Version version = ApplyID3v2Edits(mpeg->ID3v2Tag(true), hadID3v2, file, named, cover, upgraded);
        int tags = TagLib::MPEG::File::ID3v2;
        if (hadAPE && ApplyByPropertyMap(mpeg->APETag(), named, Style::Folded)) tags |= TagLib::MPEG::File::APE;
        if (hadID3v1 && ApplyByPropertyMap(mpeg->ID3v1Tag(), named, Style::ID3v1)) tags |= TagLib::MPEG::File::ID3v1;
        return mpeg->save(tags, TagLib::File::StripNone, version, TagLib::File::DoNotDuplicate);
    }
    if (auto wav = dynamic_cast<TagLib::RIFF::WAV::File *>(file)) {
        const bool hadInfo = wav->hasInfoTag();
        const TagLib::ID3v2::Version version = ApplyID3v2Edits(wav->ID3v2Tag(), wav->hasID3v2Tag(), file, named, cover, upgraded);
        int tags = TagLib::RIFF::WAV::File::ID3v2;
        // TRAP: an INFO chunk is rewritten only when the edit changes it.
        if (hadInfo && ApplyByPropertyMap(wav->InfoTag(), named, Style::Folded)) tags |= TagLib::RIFF::WAV::File::Info;
        return wav->save(static_cast<TagLib::RIFF::WAV::File::TagTypes>(tags), TagLib::File::StripNone, version);
    }
    if (auto aiff = dynamic_cast<TagLib::RIFF::AIFF::File *>(file)) {
        return aiff->save(ApplyID3v2Edits(aiff->tag(), aiff->hasID3v2Tag(), file, named, cover, upgraded));
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
            if (!FitsFLACBlock(picture->mimeType().data(TagLib::String::UTF8).size(),
                               picture->description().data(TagLib::String::UTF8).size(), picture->data().size())) {
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
        CheckMP4ItemsSurvive(path, mp4->tag(), named);
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
    if (starts("BM", 2)) return @"image/bmp";
    if (starts("II*\0", 4) || starts("MM\0*", 4)) return @"image/tiff";
    if (starts("RIFF", 4) && starts("WEBP", 4, 8)) return @"image/webp";
    return nil;
}

uint32_t LE32(const uint8_t *b) {
    return (uint32_t)b[0] | (uint32_t)b[1] << 8 | (uint32_t)b[2] << 16 | (uint32_t)b[3] << 24;
}

// Whether an image of `mime` is whole: its end marker is at its end, after
// any zero padding, or the size its header declares fits. A download cut
// short, or a tail of zeros where bytes never arrived, fails.
bool IsWhole(NSString *mime, const uint8_t *b, size_t length) {
    size_t end = length;
    while (end > 0 && b[end - 1] == 0) end--;
    // The marker ends within `slack` bytes of the end.
    auto endsWith = [&](const char *marker, size_t size, size_t slack) {
        if (end < size) return false;
        const size_t last = end - size;
        for (size_t at = last > slack ? last - slack : 0; at <= last; at++) {
            if (memcmp(b + at, marker, size) == 0) return true;
        }
        return false;
    };
    if ([mime isEqualToString:@"image/jpeg"]) return endsWith("\xFF\xD9", 2, 32);
    // IEND's chunk ends in its CRC, AE 42 60 82, which no zero trims.
    if ([mime isEqualToString:@"image/png"]) return endsWith("IEND\xAE\x42\x60\x82", 8, 32);
    // TRAP: 0x3B is common in LZW data, so a GIF's trailer must be its last
    // byte, past the block terminator's zero.
    if ([mime isEqualToString:@"image/gif"]) return endsWith("\x3B", 1, 0);
    if ([mime isEqualToString:@"image/bmp"]) {
        if (length < 18) return false;
        const uint32_t header = LE32(b + 14);
        const bool known = header == 12 || header == 40 || header == 52 || header == 56 || header == 64
                || header == 108 || header == 124;
        return known && LE32(b + 2) >= 14 + header && LE32(b + 2) <= length;
    }
    if ([mime isEqualToString:@"image/webp"]) return length >= 12 && (uint64_t)LE32(b + 4) + 8 <= length;
    return true;
}

// A MIME type in the writer's spelling: lower case, with its aliases folded.
NSString *CanonicalMIMEType(NSString *mime) {
    NSString *lower = mime.lowercaseString;
    NSDictionary<NSString *, NSString *> *aliases = @{@"image/jpg": @"image/jpeg", @"image/pjpeg": @"image/jpeg",
                                                      @"image/x-ms-bmp": @"image/bmp", @"image/x-bmp": @"image/bmp",
                                                      @"image/tif": @"image/tiff"};
    return aliases[lower] ?: lower;
}

// Why a rating field can't be written as given, or nil (media/Tags/AGENTS.md,
// Ratings): more than one value, in any format, since only the first reads
// back; a POPM email over 256 bytes, with a NUL, or with a character past
// Latin-1, which ID3v2 can't hold; and a RATING:<email> TagLib's Xiph key
// check would drop.
// The email is checked as the caller gave it, before upper case would turn
// a ß into SS.
NSString *_Nullable RatingFault(NSString *field, NSString *given, unsigned int count) {
    if (!VibeTagFieldIsRating(field)) return nil;
    if (count > 1) return [NSString stringWithFormat:@"%@ holds one value", field];
    NSString *email = nil;
    BOOL xiph = NO;
    if ([field hasPrefix:VibeTagFieldPopularimeterPrefix]) {
        email = [given substringFromIndex:VibeTagFieldPopularimeterPrefix.length];
    } else if ([field hasPrefix:VibeTagFieldRatingPrefix]) {
        email = [given substringFromIndex:VibeTagFieldRatingPrefix.length];
        xiph = YES;
    }
    if (!email) return nil;
    if ([email lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > 256) {
        return [NSString stringWithFormat:@"%@'s email is over 256 bytes", field];
    }
    for (NSUInteger i = 0; i < email.length; i++) {
        unichar c = [email characterAtIndex:i];
        BOOL bad = xiph ? (c < 0x20 || c > 0x7D || c == '=') : (c == 0 || c > 0xFF);
        if (bad) return [NSString stringWithFormat:@"%@'s email can't be held", field];
    }
    return nil;
}

NSSet<NSString *> *EditedFields(void) {
    static NSSet<NSString *> *fields;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        fields = [NSSet setWithArray:VibeTagFieldsEdited()];
    });
    return fields;
}

// Each picture 1 to 16,000,000 bytes, FLAC's block less its header, and
// all of them under ID3v2's 256 MiB tag, the smallest whole-tag limit.
constexpr NSUInteger kMaxPicturesBytes = 250000000;

BOOL WriteFile(NSString *path, const Edits &edits, const Cover &cover, VibeTagWriteSync sync,
               VibeTagWriteChanges *changes, NSError *__autoreleasing *error) {
    // Outlives the try, so a failure part way can say whether an upgraded
    // tag may be on disk.
    std::unique_ptr<TagLibAudioFile> opened;
    bool upgraded = false;
    auto reportUpgrade = [&] {
        auto written = opened ? dynamic_cast<VibeCheckedFileStream *>(opened->stream()) : nullptr;
        if (changes && upgraded && written && written->wrote()) *changes |= VibeTagWriteChangeID3v2UpgradedTo24;
    };
    // The barrier: no C++ exception leaves this call.
    try {
        const VibeInfoEncodingScope infoEncoding;
        opened = std::make_unique<TagLibAudioFile>(path.fileSystemRepresentation, false, nil, 0, true);
        TagLibAudioFile &fileRef = *opened;
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
        const bool saved = SaveFile(path, fileRef.file(), edits, cover, &upgraded);
        const bool finished = stream->finish(sync == VibeTagWriteSyncBarrier ? VibeCheckedFileStream::Sync::Barrier
                                                                              : VibeCheckedFileStream::Sync::Full);
        if (!saved || !finished) {
            Refuse(VibeTagWriteErrorSaveFailed,
                   stream->failure().empty() ? "TagLib could not save the file" : stream->failure());
        }
        reportUpgrade();
        return YES;
    }
    catch (const Refusal &refusal) {
        reportUpgrade();
        return Fail(error, refusal.code, path, @(refusal.reason.c_str()) ?: @"The write was refused");
    }
    catch (const std::exception &e) {
        reportUpgrade();
        return Fail(error, VibeTagWriteErrorTagLibThrew, path, [NSString stringWithFormat:@"TagLib threw: %s", e.what()]);
    }
    catch (...) {
        reportUpgrade();
        return Fail(error, VibeTagWriteErrorTagLibThrew, path, @"TagLib threw");
    }
}

} // namespace

BOOL VibeTagLibWriteTags(NSString *path, VibeTagFieldValues *fields, BOOL changeCover, NSData *coverData,
                         NSString *coverMIMEType, VibeTagWriteSync sync, VibeTagWriteChanges *changes,
                         NSError *__autoreleasing *error) {
    if (changes) *changes = VibeTagWriteChangeNone;
    Edits edits;
    for (NSString *key in fields) {
        NSString *field = VibeTagFieldKey(key);
        if (![EditedFields() containsObject:field] && !VibeTagFieldIsRating(field)) {
            return Fail(error, VibeTagWriteErrorInvalidField, path,
                        [NSString stringWithFormat:@"\"%@\" is not a field the writer edits", key]);
        }
        TagLib::StringList values;
        for (NSString *value in fields[key]) {
            if (value.length > 0) values.append(TL(value));
        }
        NSString *why = RatingFault(field, key, values.size());
        if (why) {
            return Fail(error, VibeTagWriteErrorUnsupportedValue, path, why);
        }
        edits[TL(field)] = values;
    }
    Cover cover;
    if (changeCover) {
        cover.take = Cover::Take::Cover;
        if (coverData) {
            NSString *mime = CanonicalMIMEType(coverMIMEType ?: @"");
            if (![VibeTagCoverMIMETypes() containsObject:mime]) {
                return Fail(error, VibeTagWriteErrorInvalidImage, path,
                            [NSString stringWithFormat:@"A cover must be JPEG, PNG, GIF, BMP, TIFF, or WebP, not \"%@\"",
                                                       coverMIMEType]);
            }
            if (coverData.length == 0 || coverData.length > kMaxCoverBytes
                    || ![SniffedMIMEType(coverData.bytes, coverData.length) isEqualToString:mime]
                    || !IsWhole(mime, (const uint8_t *)coverData.bytes, coverData.length)) {
                return Fail(error, VibeTagWriteErrorInvalidImage, path,
                            [NSString stringWithFormat:@"A cover must be a whole %@ image of 1 to %lu bytes",
                                                       mime, (unsigned long)kMaxCoverBytes]);
            }
            Record record;
            record.data = TagLib::ByteVector((const char *)coverData.bytes, (unsigned int)coverData.length);
            record.mimeType = TL(mime);
            cover.add.push_back(record);
        }
    }
    return WriteFile(path, edits, cover, sync, changes, error);
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
        _mimeType = mimeType.length ? [mimeType copy] : nil;
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
    NSUInteger hash = _data.hash;
    for (NSUInteger part : {_mimeType.hash, (NSUInteger)_type, _pictureDescription.hash, _width, _height, _colorDepth,
                            _colorCount}) {
        hash = hash * 31 + part;
    }
    return hash;
}

- (NSString *)description {
    return [NSString stringWithFormat:@"<VibeTagPicture type %ld, %@, \"%@\", %lu bytes, %lux%lu>", (long)_type,
                                      _mimeType, _pictureDescription, (unsigned long)_data.length,
                                      (unsigned long)_width, (unsigned long)_height];
}

@end

BOOL VibeTagLibReadPictures(NSString *path, NSArray<VibeTagPicture *> *__autoreleasing *pictures,
                            NSUInteger *shownIndex, NSError *__autoreleasing *error) {
    NSMutableArray<VibeTagPicture *> *found = [NSMutableArray array];
    size_t shown = SIZE_MAX;
    try {
        TagLibAudioFile fileRef(path.fileSystemRepresentation, false);
        if (fileRef.isNull()) {
            return Fail(error, VibeTagWriteErrorNoParser, path, @"No tag parser takes the file");
        }
        const std::vector<VibeEmbeddedPicture> embedded = VibeEmbeddedPictures(fileRef.file());
        shown = VibeShownPicture(embedded);
        for (const VibeEmbeddedPicture &picture : embedded) {
            NSData *data = [NSData dataWithBytes:picture.data.data() length:picture.data.size()];
            [found addObject:[[VibeTagPicture alloc] initWithData:data mimeType:NS(picture.mimeType)
                                                             type:(VibeTagPictureType)picture.type
                                                      description:NS(picture.description)
                                                            width:(NSUInteger)std::max(0, picture.width)
                                                           height:(NSUInteger)std::max(0, picture.height)
                                                       colorDepth:(NSUInteger)std::max(0, picture.colorDepth)
                                                       colorCount:(NSUInteger)std::max(0, picture.colorCount)]];
        }
    }
    catch (const std::exception &e) {
        return Fail(error, VibeTagWriteErrorTagLibThrew, path, [NSString stringWithFormat:@"TagLib threw: %s", e.what()]);
    }
    catch (...) {
        return Fail(error, VibeTagWriteErrorTagLibThrew, path, @"TagLib threw");
    }
    if (pictures) *pictures = found;
    if (shownIndex) *shownIndex = shown == SIZE_MAX ? NSNotFound : (NSUInteger)shown;
    return YES;
}

namespace {

// What VibeTagLibWritePictures checks of the list before the file opens:
// each picture holds bytes and a type from -1 to 20, fits a FLAC block in
// every format, and all of them, counted as blocks, fit kMaxPicturesBytes.
// With a container, its own rules too. The reason it does not fit, which
// is always InvalidImage, or empty.
std::string PictureListFault(NSArray<VibeTagPicture *> *pictures, VibeTagContainer container) {
    uint64_t total = 0;
    for (VibeTagPicture *picture in pictures) {
        const uint64_t mime = [picture.mimeType ?: @"" lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
        const uint64_t description = [picture.pictureDescription lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
        if (picture.data.length == 0 || picture.type < VibeTagPictureTypeUntyped || picture.type > 20) {
            return "a picture holds bytes and a type from -1 to 20, not " + std::string(picture.description.UTF8String);
        }
        if (picture.data.length > kMaxCoverBytes || !FitsFLACBlock(mime, description, picture.data.length)) {
            return "a picture of " + std::to_string(picture.data.length) + " bytes, with its type and description, "
                    "would pass FLAC's 16 MiB block";
        }
        if (container == VibeTagContainerMP4) {
            const std::string fault = MP4PictureTypeFault((int)picture.type);
            if (!fault.empty()) return fault;
        }
        total += FLACPictureBlockBytes(mime, description, picture.data.length);
    }
    if (total > kMaxPicturesBytes) {
        return "the pictures hold " + std::to_string(total) + " bytes, past " + std::to_string(kMaxPicturesBytes);
    }
    return "";
}

} // namespace

BOOL VibeTagLibPicturesFit(NSArray<VibeTagPicture *> *pictures, VibeTagContainer container,
                           NSError *__autoreleasing *error) {
    const std::string fault = PictureListFault(pictures, container);
    if (fault.empty()) return YES;
    if (error) {
        *error = [NSError errorWithDomain:VibeTagWriteErrorDomain code:VibeTagWriteErrorInvalidImage
                                 userInfo:@{NSLocalizedDescriptionKey: @(fault.c_str())}];
    }
    return NO;
}

BOOL VibeTagLibWritePictures(NSString *path, NSArray<VibeTagPicture *> *pictures, VibeTagWriteSync sync,
                             VibeTagWriteChanges *changes, NSError *__autoreleasing *error) {
    if (changes) *changes = VibeTagWriteChangeNone;
    // The container's own rules wait for the parse, in the save.
    const std::string fault = PictureListFault(pictures, VibeTagContainerUnknown);
    if (!fault.empty()) return Fail(error, VibeTagWriteErrorInvalidImage, path, @(fault.c_str()));
    // The barrier: an allocation that fails is an error, not an abort.
    try {
        Cover cover;
        cover.take = Cover::Take::All;
        for (VibeTagPicture *picture in pictures) {
            Record record;
            record.data = TagLib::ByteVector((const char *)picture.data.bytes, (unsigned int)picture.data.length);
            record.mimeType = TL(picture.mimeType ?: @"");
            record.type = (int)picture.type;
            record.description = TL(picture.pictureDescription);
            record.width = (int)std::min<NSUInteger>(picture.width, INT_MAX);
            record.height = (int)std::min<NSUInteger>(picture.height, INT_MAX);
            record.colorDepth = (int)std::min<NSUInteger>(picture.colorDepth, INT_MAX);
            record.colorCount = (int)std::min<NSUInteger>(picture.colorCount, INT_MAX);
            cover.add.push_back(record);
        }
        return WriteFile(path, Edits(), cover, sync, changes, error);
    }
    catch (const std::bad_alloc &) {
        return Fail(error, VibeTagWriteErrorSaveFailed, path, @"The pictures ran out of memory before the write");
    }
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
            // Each rating comes from the rating read below, by the same
            // rules as the parse's.
            if (VibeTagFieldIsRating(NS(key))) continue;
            NSMutableArray<NSString *> *strings = [NSMutableArray array];
            for (const TagLib::String &value : values) [strings addObject:NS(value)];
            fields[NS(key.upper())] = strings;
        }
        // An editor needs the value the reader showed, including for undo.
        for (const Aliases &alias : kAliases) {
            NSString *key = @(alias.key);
            for (const char *other : alias.aliases) {
                if (!other || [fields[key].firstObject stringByTrimmingCharactersInSet:
                               NSCharacterSet.whitespaceAndNewlineCharacterSet].length) break;
                NSArray *values = fields[@(other)];
                if ([values.firstObject stringByTrimmingCharactersInSet:
                     NSCharacterSet.whitespaceAndNewlineCharacterSet].length) fields[key] = values;
            }
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
        // Each rating by its key, its first value, from the one read the
        // parse makes too.
        [VibeTagRatingFields(fileRef.file(), properties) enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSString *value,
                                                                                            BOOL *stop) {
            fields[key] = @[value];
        }];
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
