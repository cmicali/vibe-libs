//
//  VibeTagWriter.mm
//  vibe-libs
//

#import "VibeTagWriter.h"
#import "TagLibAudioFile.h"
#import "VibeMacros.h"

#include <stdexcept>
#include <aifffile.h>
#include <apetag.h>
#include <attachedpictureframe.h>
#include <commentsframe.h>
#include <flacfile.h>
#include <flacpicture.h>
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

NSErrorDomain const VibeTagWriteErrorDomain = @"vibe-libs.tags.write";

namespace {

// Keys upper case, each with its values. Empty values remove the key.
using Edits = TagLib::Map<TagLib::String, TagLib::StringList>;

struct Cover {
    bool change = false;
    TagLib::ByteVector data;  // empty removes
    TagLib::String mimeType;
};

// What a format's edit reports back: a value it cannot hold.
struct UnsupportedValue : std::runtime_error {
    using std::runtime_error::runtime_error;
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

NSString *NS(const TagLib::String &string) {
    return @(string.toCString(true)) ?: @"";
}

// The number before a slash, and the total after it.
void SplitPair(const TagLib::StringList &values, TagLib::String *number, TagLib::String *total) {
    *number = TagLib::String();
    *total = TagLib::String();
    if (values.isEmpty()) return;
    const TagLib::String &value = values.front();
    const int slash = value.find("/");
    if (slash < 0) {
        *number = value.stripWhiteSpace();
        return;
    }
    *number = value.substr(0, slash).stripWhiteSpace();
    *total = value.substr(slash + 1).stripWhiteSpace();
}

// ID3v2, MP4, APE, ID3v1, and INFO hold a total inside the number's "3/12".
// A total edit folds into the number, keeping the half not named.
Edits FoldTotals(const Edits &edits, const TagLib::PropertyMap &current) {
    Edits folded = edits;
    const std::pair<const char *, const char *> pairs[] = {{"TRACKNUMBER", "TRACKTOTAL"},
                                                           {"DISCNUMBER", "DISCTOTAL"}};
    for (const auto &[numberKey, totalKey] : pairs) {
        const bool numberNamed = edits.contains(numberKey);
        const bool totalNamed = edits.contains(totalKey);
        if (!numberNamed && !totalNamed) continue;
        TagLib::String number, total;
        SplitPair(current.value(numberKey), &number, &total);
        if (numberNamed) {
            TagLib::String givenTotal;
            SplitPair(edits.value(numberKey), &number, &givenTotal);
            if (!givenTotal.isEmpty()) total = givenTotal;
        }
        if (totalNamed) {
            const TagLib::StringList values = edits.value(totalKey);
            total = values.isEmpty() ? TagLib::String() : values.front().stripWhiteSpace();
        }
        folded.erase(totalKey);
        if (number.isEmpty() && total.isEmpty()) {
            folded[numberKey] = TagLib::StringList();
        }
        else {
            folded[numberKey] = TagLib::StringList(total.isEmpty() ? number
                                                   : (number.isEmpty() ? TagLib::String("0") : number) + "/" + total);
        }
    }
    return folded;
}

// A tag with no editor of its own: its whole map, with the edits applied.
// APE, ID3v1, and INFO keep what their maps do not name.
void ApplyByPropertyMap(TagLib::Tag *tag, const Edits &edits) {
    TagLib::PropertyMap properties = tag->properties();
    for (const auto &[key, values] : FoldTotals(edits, properties)) {
        if (values.isEmpty()) properties.erase(key);
        else properties.replace(key, values);
    }
    tag->setProperties(properties);
}

#pragma mark - ID3v2

TagLib::ID3v2::Version ID3v2VersionToKeep(TagLib::ID3v2::Tag *tag) {
    return tag && tag->header()->majorVersion() == 3 ? TagLib::ID3v2::v3 : TagLib::ID3v2::v4;
}

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

// Removes each frame that holds the key alone, then adds the key's frame.
// TIPL and TMCL hold several keys, and none of the edited fields.
void ApplyID3v2(TagLib::ID3v2::Tag *tag, const Edits &edits, TagLib::ID3v2::Version version) {
    for (const auto &[key, values] : FoldTotals(edits, tag->properties())) {
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

void ApplyID3v2Cover(TagLib::ID3v2::Tag *tag, const Cover &cover) {
    if (!cover.change) return;
    TagLib::ID3v2::FrameList remove;
    for (TagLib::ID3v2::Frame *frame : tag->frameList("APIC")) {
        auto picture = dynamic_cast<TagLib::ID3v2::AttachedPictureFrame *>(frame);
        if (picture && picture->type() == TagLib::ID3v2::AttachedPictureFrame::FrontCover) remove.append(frame);
    }
    for (TagLib::ID3v2::Frame *frame : remove) tag->removeFrame(frame, true);
    if (cover.data.isEmpty()) return;
    auto frame = new TagLib::ID3v2::AttachedPictureFrame();
    frame->setTextEncoding(TagLib::String::UTF8);
    frame->setMimeType(cover.mimeType);
    frame->setType(TagLib::ID3v2::AttachedPictureFrame::FrontCover);
    frame->setPicture(cover.data);
    tag->addFrame(frame);
}

#pragma mark - Xiph comments

void ApplyXiph(TagLib::Ogg::XiphComment *tag, const Edits &edits) {
    for (const auto &[key, values] : edits) {
        tag->removeFields(key);
        // The totals' other spellings are the same field.
        if (key == "TRACKTOTAL") tag->removeFields("TOTALTRACKS");
        if (key == "DISCTOTAL") tag->removeFields("TOTALDISCS");
        for (const TagLib::String &value : values) tag->addField(key, value, false);
    }
}

TagLib::FLAC::Picture *NewFLACPicture(const Cover &cover) {
    auto picture = new TagLib::FLAC::Picture();
    picture->setType(TagLib::FLAC::Picture::FrontCover);
    picture->setMimeType(cover.mimeType);
    picture->setData(cover.data);
    return picture;
}

void ApplyXiphCover(TagLib::Ogg::XiphComment *tag, const Cover &cover) {
    if (!cover.change) return;
    for (TagLib::FLAC::Picture *picture : tag->pictureList()) {
        if (picture->type() == TagLib::FLAC::Picture::FrontCover) tag->removePicture(picture, true);
    }
    if (!cover.data.isEmpty()) tag->addPicture(NewFLACPicture(cover));
}

void ApplyFLACCover(TagLib::FLAC::File *file, const Cover &cover) {
    if (!cover.change) return;
    for (TagLib::FLAC::Picture *picture : file->pictureList()) {
        if (picture->type() == TagLib::FLAC::Picture::FrontCover) file->removePicture(picture, true);
    }
    if (!cover.data.isEmpty()) file->addPicture(NewFLACPicture(cover));
}

#pragma mark - MP4

bool IsWholeNumber(const TagLib::String &value) {
    bool ok = false;
    value.stripWhiteSpace().toInt(&ok);
    return ok;
}

void ApplyMP4(TagLib::MP4::Tag *tag, const Edits &edits) {
    TagLib::MP4::ItemFactory *factory = TagLib::MP4::ItemFactory::instance();
    for (const auto &[key, values] : FoldTotals(edits, tag->properties())) {
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
        const bool numeric = name == "tmpo" || name == "cpil";
        if (!item.isValid() || (numeric && !IsWholeNumber(values.front()))) {
            throw UnsupportedValue(std::string("MP4 cannot hold ") + key.to8Bit(true) + " = "
                                   + values.front().to8Bit(true));
        }
        tag->setItem(TagLib::String(name, TagLib::String::Latin1), item);
    }
}

// MP4's pictures have no type. The first is the cover, which the read answers.
void ApplyMP4Cover(TagLib::MP4::Tag *tag, const Cover &cover) {
    if (!cover.change) return;
    TagLib::MP4::CoverArtList list = tag->item("covr").toCoverArtList();
    if (!list.isEmpty()) list.erase(list.begin());
    if (!cover.data.isEmpty()) {
        const auto format = cover.mimeType == "image/png" ? TagLib::MP4::CoverArt::PNG : TagLib::MP4::CoverArt::JPEG;
        list.prepend(TagLib::MP4::CoverArt(format, cover.data));
    }
    if (list.isEmpty()) tag->removeItem("covr");
    else tag->setItem("covr", TagLib::MP4::Item(list));
}

#pragma mark - Per file

// The tag the edit writes starts with what the file reads today when it is
// new. TRAP: TagLib's read takes the first tag that is not empty, so a new
// ID3v2 tag holding one field would hide every field of an ID3v1, APE, or
// INFO tag beside it.
void Seed(TagLib::Tag *written, bool existed, TagLib::File *file) {
    if (existed && !written->isEmpty()) return;
    const TagLib::PropertyMap current = file->properties();
    if (!current.isEmpty()) written->setProperties(current);
}

bool Save(TagLib::File *file, const Edits &edits, const Cover &cover) {
    if (auto mpeg = dynamic_cast<TagLib::MPEG::File *>(file)) {
        const bool hadID3v2 = mpeg->hasID3v2Tag(), hadAPE = mpeg->hasAPETag(), hadID3v1 = mpeg->hasID3v1Tag();
        TagLib::ID3v2::Tag *id3 = mpeg->ID3v2Tag(true);
        const TagLib::ID3v2::Version version = ID3v2VersionToKeep(hadID3v2 ? id3 : nullptr);
        Seed(id3, hadID3v2, file);
        ApplyID3v2(id3, edits, version);
        ApplyID3v2Cover(id3, cover);
        int tags = TagLib::MPEG::File::ID3v2;
        if (hadAPE) {
            ApplyByPropertyMap(mpeg->APETag(), edits);
            tags |= TagLib::MPEG::File::APE;
        }
        if (hadID3v1) {
            ApplyByPropertyMap(mpeg->ID3v1Tag(), edits);
            tags |= TagLib::MPEG::File::ID3v1;
        }
        return mpeg->save(tags, TagLib::File::StripNone, version, TagLib::File::DoNotDuplicate);
    }
    if (auto flac = dynamic_cast<TagLib::FLAC::File *>(file)) {
        const bool had = flac->xiphComment() != nullptr;
        TagLib::Ogg::XiphComment *xiph = flac->xiphComment(true);
        Seed(xiph, had, file);
        ApplyXiph(xiph, edits);
        ApplyFLACCover(flac, cover);
        return flac->save();
    }
    if (auto vorbis = dynamic_cast<TagLib::Ogg::Vorbis::File *>(file)) {
        ApplyXiph(vorbis->tag(), edits);
        ApplyXiphCover(vorbis->tag(), cover);
        return vorbis->save();
    }
    if (auto opus = dynamic_cast<TagLib::Ogg::Opus::File *>(file)) {
        ApplyXiph(opus->tag(), edits);
        ApplyXiphCover(opus->tag(), cover);
        return opus->save();
    }
    if (auto mp4 = dynamic_cast<TagLib::MP4::File *>(file)) {
        ApplyMP4(mp4->tag(), edits);
        ApplyMP4Cover(mp4->tag(), cover);
        return mp4->save();
    }
    if (auto wav = dynamic_cast<TagLib::RIFF::WAV::File *>(file)) {
        const bool hadID3v2 = wav->hasID3v2Tag(), hadInfo = wav->hasInfoTag();
        TagLib::ID3v2::Tag *id3 = wav->ID3v2Tag();
        const TagLib::ID3v2::Version version = ID3v2VersionToKeep(hadID3v2 ? id3 : nullptr);
        Seed(id3, hadID3v2, file);
        ApplyID3v2(id3, edits, version);
        ApplyID3v2Cover(id3, cover);
        int tags = TagLib::RIFF::WAV::File::ID3v2;
        if (hadInfo) {
            ApplyByPropertyMap(wav->InfoTag(), edits);
            tags |= TagLib::RIFF::WAV::File::Info;
        }
        return wav->save(static_cast<TagLib::RIFF::WAV::File::TagTypes>(tags), TagLib::File::StripNone, version);
    }
    if (auto aiff = dynamic_cast<TagLib::RIFF::AIFF::File *>(file)) {
        TagLib::ID3v2::Tag *id3 = aiff->tag();
        const TagLib::ID3v2::Version version = ID3v2VersionToKeep(aiff->hasID3v2Tag() ? id3 : nullptr);
        ApplyID3v2(id3, edits, version);
        ApplyID3v2Cover(id3, cover);
        return aiff->save(version);
    }
    throw UnsupportedValue("no writer for this format");
}

// A property key TagLib can write in every format: printable ASCII, no '='.
bool IsValidKey(NSString *key) {
    if (key.length == 0 || [key.uppercaseString isEqualToString:@"PICTURE"]) return false;
    for (NSUInteger i = 0; i < key.length; i++) {
        const unichar c = [key characterAtIndex:i];
        if (c < 0x20 || c > 0x7D || c == '=') return false;
    }
    return true;
}

} // namespace

BOOL VibeTagLibWriteTags(NSString *path, VibeTagFieldValues *fields, BOOL changeCover, NSData *coverData,
                         NSString *coverMIMEType, NSError *__autoreleasing *error) {
    Edits edits;
    for (NSString *key in fields) {
        if (!IsValidKey(key)) {
            return Fail(error, VibeTagWriteErrorInvalidField, path,
                        [NSString stringWithFormat:@"Invalid tag field name \"%@\"", key]);
        }
        TagLib::StringList values;
        for (NSString *value in fields[key]) values.append(TL(value));
        edits[TL(key.uppercaseString)] = values;
    }
    Cover cover;
    if (changeCover) {
        cover.change = true;
        if (coverData) {
            NSString *mime = coverMIMEType.lowercaseString;
            if ([mime isEqualToString:@"image/jpg"]) mime = @"image/jpeg";
            if (coverData.length == 0 || !([mime isEqualToString:@"image/jpeg"] || [mime isEqualToString:@"image/png"])) {
                return Fail(error, VibeTagWriteErrorInvalidImage, path,
                            [NSString stringWithFormat:@"Cover must be JPEG or PNG bytes, not \"%@\"", coverMIMEType]);
            }
            cover.data = TagLib::ByteVector((const char *)coverData.bytes, (unsigned int)coverData.length);
            cover.mimeType = TL(mime);
        }
    }
    // The barrier: no C++ exception leaves this call.
    try {
        TagLibAudioFile fileRef(path.fileSystemRepresentation, false, nil, 0, true);
        if (!fileRef.streamIsOpen()) {
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
        try {
            if (!Save(fileRef.file(), edits, cover)) {
                return Fail(error, VibeTagWriteErrorSaveFailed, path, @"TagLib could not save the file");
            }
        }
        catch (const UnsupportedValue &e) {
            return Fail(error, VibeTagWriteErrorUnsupportedValue, path, @(e.what()));
        }
        return YES;
    }
    catch (const std::exception &e) {
        return Fail(error, VibeTagWriteErrorTagLibThrew, path, [NSString stringWithFormat:@"TagLib threw: %s", e.what()]);
    }
    catch (...) {
        return Fail(error, VibeTagWriteErrorTagLibThrew, path, @"TagLib threw");
    }
}

BOOL VibeTagLibWriteFields(NSString *path, VibeTagFieldValues *fields, NSError *__autoreleasing *error) {
    return VibeTagLibWriteTags(path, fields, NO, nil, nil, error);
}

BOOL VibeTagLibWriteFrontCover(NSString *path, NSData *data, NSString *mimeType, NSError *__autoreleasing *error) {
    return VibeTagLibWriteTags(path, nil, YES, data, mimeType, error);
}

VibeTagFieldValues *VibeTagLibReadFields(NSString *path, NSError *__autoreleasing *error) {
    try {
        TagLibAudioFile fileRef(path.fileSystemRepresentation, false);
        if (fileRef.isNull()) {
            Fail(error, VibeTagWriteErrorNoParser, path, @"No tag parser takes the file");
            return nil;
        }
        const TagLib::PropertyMap properties = fileRef.file()->properties();
        const bool xiph = dynamic_cast<TagLib::Ogg::XiphComment *>(fileRef.file()->tag()) != nullptr
                || dynamic_cast<TagLib::FLAC::File *>(fileRef.file()) != nullptr;
        NSMutableDictionary<VibeTagField, NSArray<NSString *> *> *fields = [NSMutableDictionary dictionary];
        for (const auto &[key, values] : properties) {
            NSMutableArray<NSString *> *strings = [NSMutableArray array];
            for (const TagLib::String &value : values) [strings addObject:NS(value)];
            fields[NS(key.upper())] = strings;
        }
        if (!xiph) {
            for (NSString *numberKey in @[VibeTagFieldTrackNumber, VibeTagFieldDiscNumber]) {
                NSString *totalKey = [numberKey isEqualToString:VibeTagFieldTrackNumber] ? VibeTagFieldTrackTotal
                                                                                        : VibeTagFieldDiscTotal;
                TagLib::String number, total;
                SplitPair(properties.value(TL(numberKey)), &number, &total);
                if (total.isEmpty() || fields[totalKey]) continue;
                fields[numberKey] = @[NS(number)];
                fields[totalKey] = @[NS(total)];
            }
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
