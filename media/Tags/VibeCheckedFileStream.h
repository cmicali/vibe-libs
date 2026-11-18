//
//  VibeCheckedFileStream.h
//  vibe-libs
//
//  The stream a tag write goes through. TagLib's FileStream ignores what
//  fwrite answers and loses the last flush's error in its destructor, so a
//  write cut short by a full disk reports success. This one writes with
//  pwrite, records the first failed read, write, or truncate, and stops
//  writing after it. finish() then checks the file's size against the one
//  the writes imply and flushes it. C++.
//

#pragma once

#include <string>
#include <sys/types.h>
#include <tiostream.h>

class VibeCheckedFileStream : public TagLib::IOStream {
public:
    // Opens for reading and writing, or for reading when the file refuses
    // writing.
    explicit VibeCheckedFileStream(const char *path);
    ~VibeCheckedFileStream() override;

    TagLib::FileName name() const override { return _path.c_str(); }
    TagLib::ByteVector readBlock(size_t length) override;
    void writeBlock(const TagLib::ByteVector &data) override;
    void insert(const TagLib::ByteVector &data, TagLib::offset_t start = 0, size_t replace = 0) override;
    void removeBlock(TagLib::offset_t start = 0, size_t length = 0) override;
    bool readOnly() const override { return _readOnly; }
    bool isOpen() const override { return _fd >= 0; }
    void seek(TagLib::offset_t offset, Position p = Beginning) override;
    void clear() override {}
    TagLib::offset_t tell() const override { return _position; }
    TagLib::offset_t length() override;
    void truncate(TagLib::offset_t length) override;

    // The first failure, or empty.
    const std::string &failure() const { return _failure; }
    // Whether any write reached the file, so a failure may have changed it.
    bool wrote() const { return _wrote; }
    // How finish() flushes. Full is F_FULLFSYNC, Barrier is F_BARRIERFSYNC.
    // A volume that refuses Barrier gets Full, and one that refuses Full
    // gets fsync.
    enum class Sync { Full, Barrier };
    // After the last write: checks the size, flushes, and closes. false
    // with failure() set when any step, or any write before it, failed.
    bool finish(Sync sync = Sync::Full);

private:
    bool fail(const char *operation);
    bool writeAt(const char *bytes, size_t length, off_t at);
    bool readAt(char *bytes, size_t length, off_t at, size_t *read);
    bool moveTail(off_t from, off_t to);

    std::string _path;
    int _fd = -1;
    bool _readOnly = true;
    bool _wrote = false;
    off_t _position = 0;
    // The size the writes imply, from the size at open.
    off_t _expectedLength = 0;
    std::string _failure;
};
