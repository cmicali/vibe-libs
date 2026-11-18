//
//  VibeCheckedFileStream.mm
//  vibe-libs
//

#include "VibeCheckedFileStream.h"

#include <algorithm>
#include <errno.h>
#include <fcntl.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#include <vector>

namespace {
constexpr size_t kChunk = 1024 * 1024;
}

VibeCheckedFileStream::VibeCheckedFileStream(const char *path) : _path(path ?: "") {
    _fd = open(_path.c_str(), O_RDWR | O_CLOEXEC);
    if (_fd >= 0) {
        _readOnly = false;
    }
    else {
        _fd = open(_path.c_str(), O_RDONLY | O_CLOEXEC);
    }
    struct stat info;
    if (_fd >= 0 && fstat(_fd, &info) == 0) {
        _expectedLength = info.st_size;
    }
}

VibeCheckedFileStream::~VibeCheckedFileStream() {
    if (_fd >= 0) close(_fd);
}

bool VibeCheckedFileStream::fail(const char *operation) {
    if (_failure.empty()) {
        _failure = std::string(operation) + ": " + strerror(errno);
    }
    return false;
}

bool VibeCheckedFileStream::readAt(char *bytes, size_t length, off_t at, size_t *read) {
    size_t done = 0;
    while (done < length) {
        const ssize_t count = pread(_fd, bytes + done, length - done, at + (off_t)done);
        if (count < 0) {
            if (errno == EINTR) continue;
            *read = done;
            return fail("read");
        }
        if (count == 0) break;
        done += (size_t)count;
    }
    *read = done;
    return true;
}

bool VibeCheckedFileStream::writeAt(const char *bytes, size_t length, off_t at) {
    if (!_failure.empty()) return false;
    if (_readOnly) {
        errno = EBADF;
        return fail("write");
    }
    size_t done = 0;
    while (done < length) {
        const ssize_t count = pwrite(_fd, bytes + done, length - done, at + (off_t)done);
        if (count < 0) {
            if (errno == EINTR) continue;
            return fail("write");
        }
        if (count == 0) {
            errno = EIO;
            return fail("write");
        }
        _wrote = true;
        done += (size_t)count;
    }
    _expectedLength = std::max(_expectedLength, at + (off_t)length);
    return true;
}

TagLib::ByteVector VibeCheckedFileStream::readBlock(size_t length) {
    if (_fd < 0 || length == 0) return TagLib::ByteVector();
    const off_t size = (off_t)this->length();
    if (_position >= size) return TagLib::ByteVector();
    length = (size_t)std::min<off_t>((off_t)length, size - _position);
    TagLib::ByteVector block((unsigned int)length);
    size_t read = 0;
    readAt(block.data(), length, _position, &read);
    block.resize((unsigned int)read);
    _position += (off_t)read;
    return block;
}

void VibeCheckedFileStream::writeBlock(const TagLib::ByteVector &data) {
    if (_fd < 0) return;
    if (writeAt(data.data(), data.size(), _position)) {
        _position += (off_t)data.size();
    }
}

// Moves the bytes from `from` to the end so they start at `to`, a chunk at
// a time: from the end down when they move later, so no byte is
// overwritten before it is read. TRAP: when a growth fails, the first write
// is the one at the end, so a full disk fails before any byte moves.
bool VibeCheckedFileStream::moveTail(off_t from, off_t to) {
    const off_t end = (off_t)length();
    if (from >= end || from == to) return _failure.empty();
    std::vector<char> buffer(kChunk);
    const off_t total = end - from;
    if (to > from) {
        off_t left = total;
        while (left > 0) {
            const size_t take = (size_t)std::min<off_t>(left, (off_t)kChunk);
            const off_t at = from + left - (off_t)take;
            size_t read = 0;
            if (!readAt(buffer.data(), take, at, &read) || read != take) {
                if (read != take) errno = EIO;
                return fail("read");
            }
            if (!writeAt(buffer.data(), take, to + (at - from))) return false;
            left -= (off_t)take;
        }
    }
    else {
        off_t done = 0;
        while (done < total) {
            const size_t take = (size_t)std::min<off_t>(total - done, (off_t)kChunk);
            size_t read = 0;
            if (!readAt(buffer.data(), take, from + done, &read) || read != take) {
                if (read != take) errno = EIO;
                return fail("read");
            }
            if (!writeAt(buffer.data(), take, to + done)) return false;
            done += (off_t)take;
        }
    }
    return true;
}

void VibeCheckedFileStream::insert(const TagLib::ByteVector &data, TagLib::offset_t start, size_t replace) {
    if (_fd < 0 || !_failure.empty()) return;
    const off_t at = (off_t)start;
    const off_t tail = at + (off_t)replace;
    const off_t shift = (off_t)data.size() - (off_t)replace;
    if (shift > 0) {
        if (!moveTail(tail, tail + shift)) return;
    }
    else if (shift < 0) {
        if (!moveTail(tail, tail + shift)) return;
        truncate((TagLib::offset_t)(length() + shift));
        if (!_failure.empty()) return;
    }
    if (writeAt(data.data(), data.size(), at)) {
        _position = at + (off_t)data.size();
    }
}

void VibeCheckedFileStream::removeBlock(TagLib::offset_t start, size_t length) {
    if (_fd < 0 || !_failure.empty() || length == 0) return;
    const off_t from = (off_t)start + (off_t)length;
    const off_t end = (off_t)this->length();
    if (!moveTail(from, (off_t)start)) return;
    truncate((TagLib::offset_t)(end - std::min<off_t>((off_t)length, std::max<off_t>(0, end - (off_t)start))));
}

void VibeCheckedFileStream::seek(TagLib::offset_t offset, Position p) {
    const off_t base = p == Beginning ? 0 : (p == Current ? _position : (off_t)length());
    _position = std::max<off_t>(0, base + (off_t)offset);
}

TagLib::offset_t VibeCheckedFileStream::length() {
    struct stat info;
    if (_fd < 0) return 0;
    if (fstat(_fd, &info) != 0) {
        fail("stat");
        return 0;
    }
    return info.st_size;
}

void VibeCheckedFileStream::truncate(TagLib::offset_t length) {
    if (_fd < 0 || !_failure.empty()) return;
    if (_readOnly) {
        errno = EBADF;
        fail("truncate");
        return;
    }
    while (ftruncate(_fd, (off_t)length) != 0) {
        if (errno == EINTR) continue;
        fail("truncate");
        return;
    }
    _wrote = true;
    _expectedLength = (off_t)length;
}

namespace {
// A file system that lacks the call answers one of these.
bool Refused(int error) { return error == ENOTSUP || error == ENOTTY || error == EINVAL; }
}

bool VibeCheckedFileStream::finish(Sync sync) {
    if (_fd < 0) {
        if (_failure.empty()) _failure = "the file is not open";
        return false;
    }
    if (_failure.empty()) {
        struct stat info;
        if (fstat(_fd, &info) != 0) {
            fail("stat");
        }
        else if (info.st_size != _expectedLength) {
            _failure = "the file is " + std::to_string((long long)info.st_size) + " bytes, not the "
                    + std::to_string((long long)_expectedLength) + " its writes imply";
        }
    }
    // F_FULLFSYNC flushes the drive's own cache too. F_BARRIERFSYNC orders
    // these writes before any the device takes after it. A volume that
    // refuses the barrier gets the full flush, and one that refuses that
    // gets fsync.
    if (_failure.empty() && _wrote) {
        bool done = false;
        if (sync == Sync::Barrier) {
            if (fcntl(_fd, F_BARRIERFSYNC) == 0) done = true;
            else if (!Refused(errno)) {
                fail("F_BARRIERFSYNC");
                done = true;
            }
        }
        if (!done) {
            if (fcntl(_fd, F_FULLFSYNC) == 0) {}
            else if (!Refused(errno)) fail("F_FULLFSYNC");
            else if (fsync(_fd) != 0) fail("fsync");
        }
    }
    const int fd = _fd;
    _fd = -1;
    if (close(fd) != 0 && _failure.empty()) {
        fail("close");
    }
    return _failure.empty();
}
