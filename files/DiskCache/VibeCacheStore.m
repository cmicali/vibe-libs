//
//  VibeCacheStore.m
//  vibe-libs
//

#import "VibeCacheStore.h"
#import "VibeCacheStore+Testing.h"
#import "VibeMacros.h"

#import <CommonCrypto/CommonDigest.h>
#import <fcntl.h>
#import <pthread.h>
#import <sqlite3.h>
#import <stdatomic.h>
#import <sys/file.h>
#import <sys/stat.h>
#import <unistd.h>
#import <os/lock.h>

// TRAP: until the first release, a schema change edits this one schema and
// bumps the version. A store of another version is removed and made again.
static const int VibeCacheSchemaVersion = 2;

static NSString *const VibeCacheDatabaseName = @"Cache.sqlite";
static NSString *const VibeCacheLockName = @"Cache.lock";
static NSString *const VibeCacheFilesName = @"Files";
static NSString *const VibeCacheRemovedPrefix = @"Files removed ";

// The rows one step of a trim or a sweep takes, so a write waits little.
static const int VibeCacheBatch = 64;
static const NSUInteger VibeCacheIdleReaders = 4;
// Each connection's page cache, in KiB (CH22).
static const int VibeCacheReaderPageCacheKiB = 256;
static const int VibeCacheWriterPageCacheKiB = 1024;
// The page size. A larger page makes the trees shallower, so a first read from
// the disk reads fewer pages, and 16 KB pages hold a 1 KB row with less waste.
static const int VibeCachePageSize = 16384;
// The journal's pages that start a checkpoint on the queue, 4 MB.
static const int VibeCacheCheckpointPages = 4194304 / VibeCachePageSize;
static const int64_t VibeCacheSecondsPerDay = 86400;
// The daily work waits this long after an open, so a launch does none.
static const int64_t VibeCacheMaintenanceDelay = 10;
// A read's uses are written together this long after the first.
static const int64_t VibeCacheTouchDelayMs = 500;

// The triggers keep the totals, list each file a row lets go in `pending` as
// doomed, and remove the shared items no entry names any more. So no write
// path has to remember any of it.
static const char *const VibeCacheSchema =
    // An entry's row id is its key's hash (VibeCacheKeyID), so a lookup is one
    // descent of the table's tree, with no index of the keys to read first.
    // The key is kept, and every read and change checks it.
    "CREATE TABLE entries("
    "  id INTEGER PRIMARY KEY,"
    "  key TEXT NOT NULL,"
    "  format INTEGER NOT NULL,"
    "  shared TEXT,"
    "  data BLOB,"
    "  file TEXT,"
    "  size INTEGER NOT NULL,"
    "  used INTEGER NOT NULL,"
    "  written INTEGER NOT NULL);"
    // `written` orders the rows of one day of use, oldest write first, since
    // the row ids are hashes.
    "CREATE INDEX entries_used ON entries(used, written);"
    "CREATE INDEX entries_shared ON entries(shared) WHERE shared IS NOT NULL;"
    "CREATE TABLE shared("
    "  name TEXT NOT NULL,"
    "  part TEXT NOT NULL,"
    "  format INTEGER NOT NULL,"
    "  data BLOB,"
    "  file TEXT,"
    "  size INTEGER NOT NULL,"
    "  used INTEGER NOT NULL,"
    "  written INTEGER NOT NULL,"
    "  PRIMARY KEY(name, part));"
    "CREATE INDEX shared_used ON shared(used, written);"
    "CREATE INDEX shared_part_used ON shared(part, used, written);"
    // The bytes of each part, for a part with a byte limit of its own.
    "CREATE TABLE part_bytes(part TEXT NOT NULL PRIMARY KEY, bytes INTEGER NOT NULL) WITHOUT ROWID;"
    // A file listed here may be on disk with no row that names it: one being
    // written, or a doomed one a committed change let go. An open removes them
    // all, and a change removes its doomed ones once it commits.
    "CREATE TABLE pending(file TEXT NOT NULL PRIMARY KEY, doomed INTEGER NOT NULL) WITHOUT ROWID;"
    "CREATE TABLE meta(name TEXT NOT NULL PRIMARY KEY, value) WITHOUT ROWID;"
    "CREATE TABLE totals(id INTEGER PRIMARY KEY CHECK (id = 0),"
    "  entries INTEGER NOT NULL, shared INTEGER NOT NULL, bytes INTEGER NOT NULL);"
    "INSERT INTO totals VALUES(0, 0, 0, 0);"
    "CREATE TRIGGER entries_insert AFTER INSERT ON entries BEGIN"
    "  UPDATE totals SET entries = entries + 1, bytes = bytes + NEW.size; END;"
    "CREATE TRIGGER entries_delete AFTER DELETE ON entries BEGIN"
    "  UPDATE totals SET entries = entries - 1, bytes = bytes - OLD.size;"
    "  INSERT OR REPLACE INTO pending SELECT OLD.file, 1 WHERE OLD.file IS NOT NULL;"
    "  DELETE FROM shared WHERE OLD.shared IS NOT NULL AND name = OLD.shared"
    "    AND NOT EXISTS (SELECT 1 FROM entries WHERE shared = OLD.shared); END;"
    "CREATE TRIGGER entries_size AFTER UPDATE OF size ON entries BEGIN"
    "  UPDATE totals SET bytes = bytes - OLD.size + NEW.size; END;"
    "CREATE TRIGGER entries_file AFTER UPDATE OF file ON entries"
    "  WHEN OLD.file IS NOT NULL AND OLD.file IS NOT NEW.file BEGIN"
    "  INSERT OR REPLACE INTO pending VALUES (OLD.file, 1); END;"
    "CREATE TRIGGER entries_shared AFTER UPDATE OF shared ON entries"
    "  WHEN OLD.shared IS NOT NULL AND OLD.shared IS NOT NEW.shared BEGIN"
    "  DELETE FROM shared WHERE name = OLD.shared"
    "    AND NOT EXISTS (SELECT 1 FROM entries WHERE shared = OLD.shared); END;"
    "CREATE TRIGGER shared_insert AFTER INSERT ON shared BEGIN"
    "  UPDATE totals SET shared = shared + 1, bytes = bytes + NEW.size;"
    "  INSERT INTO part_bytes VALUES (NEW.part, NEW.size)"
    "    ON CONFLICT(part) DO UPDATE SET bytes = bytes + NEW.size; END;"
    "CREATE TRIGGER shared_delete AFTER DELETE ON shared BEGIN"
    "  UPDATE totals SET shared = shared - 1, bytes = bytes - OLD.size;"
    "  UPDATE part_bytes SET bytes = bytes - OLD.size WHERE part = OLD.part;"
    "  INSERT OR REPLACE INTO pending SELECT OLD.file, 1 WHERE OLD.file IS NOT NULL; END;"
    "CREATE TRIGGER shared_size AFTER UPDATE OF size ON shared BEGIN"
    "  UPDATE totals SET bytes = bytes - OLD.size + NEW.size;"
    "  UPDATE part_bytes SET bytes = bytes - OLD.size + NEW.size WHERE part = NEW.part; END;"
    "CREATE TRIGGER shared_file AFTER UPDATE OF file ON shared"
    "  WHEN OLD.file IS NOT NULL AND OLD.file IS NOT NEW.file BEGIN"
    "  INSERT OR REPLACE INTO pending VALUES (OLD.file, 1); END;";

// The statements a write runs, which an open prepares ahead of the first.
// An entry's statements take its key as ?1 and its row id as ?9
// (VibeCacheBindKey). Two keys of one id replace each other, as a cache may.
static const char *const VibeCacheUpsertEntry =
    "INSERT INTO entries(id, key, format, shared, data, file, size, used, written) "
    "VALUES (?9, ?1, ?2, ?3, ?4, ?5, ?6, ?7, ?10) "
    "ON CONFLICT(id) DO UPDATE SET key = excluded.key, format = excluded.format, shared = excluded.shared, "
    "data = excluded.data, file = excluded.file, size = excluded.size, used = excluded.used, "
    "written = excluded.written";
static const char *const VibeCacheUpsertShared =
    "INSERT INTO shared(name, part, format, data, file, size, used, written) VALUES (?1, ?8, ?2, ?4, ?5, ?6, ?7, ?10) "
    "ON CONFLICT(name, part) DO UPDATE SET format = excluded.format, "
    "data = excluded.data, file = excluded.file, size = excluded.size, used = excluded.used, "
    "written = excluded.written";
static const char *const VibeCacheRemoveEntry = "DELETE FROM entries WHERE id = ?9 AND key = ?1";
static const char *const VibeCacheDoomedFiles = "SELECT file FROM pending WHERE doomed = 1";
static const char *const VibeCacheTotalBytes = "SELECT bytes FROM totals";

static void VibeCacheBindText(sqlite3_stmt *stmt, int index, NSString *_Nullable text) {
    // Every statement steps before the string's buffer goes, so no copy.
    if (text) {
        sqlite3_bind_text(stmt, index, text.UTF8String, -1, SQLITE_STATIC);
    } else {
        sqlite3_bind_null(stmt, index);
    }
}

// The row id of an entry's key: the first 8 bytes of its SHA-256. Stable
// across launches, since rows keep it.
static sqlite3_int64 VibeCacheKeyID(NSString *key) {
    const char *text = key.UTF8String;
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(text, (CC_LONG)strlen(text), digest);
    sqlite3_int64 id;
    memcpy(&id, digest, sizeof id);
    return id;
}

static void VibeCacheBindKey(sqlite3_stmt *stmt, NSString *key) {
    VibeCacheBindText(stmt, 1, key);
    sqlite3_bind_int64(stmt, 9, VibeCacheKeyID(key));
}

// An entry's key, or a shared item's name as ?1 and its part as ?2.
static void VibeCacheBindRow(sqlite3_stmt *stmt, NSString *_Nullable key, NSString *_Nullable name,
                             NSString *_Nullable part) {
    if (key) {
        VibeCacheBindKey(stmt, key);
    } else {
        VibeCacheBindText(stmt, 1, name);
        VibeCacheBindText(stmt, 2, part);
    }
}

static NSString *_Nullable VibeCacheColumnText(sqlite3_stmt *stmt, int column) {
    const unsigned char *text = sqlite3_column_text(stmt, column);
    return text ? [NSString stringWithUTF8String:(const char *)text] : nil;
}

static BOOL VibeCacheConfigure(sqlite3 *db, int pageCacheKiB) {
    sqlite3_busy_timeout(db, 5000);
    char sql[160];
    snprintf(sql, sizeof sql,
             "PRAGMA synchronous = NORMAL; PRAGMA cache_size = -%d; PRAGMA mmap_size = 0; PRAGMA temp_store = MEMORY;",
             pageCacheKiB);
    return sqlite3_exec(db, sql, NULL, NULL, NULL) == SQLITE_OK;
}

// MARK: - Hit

@implementation VibeCacheHit

- (instancetype)initWithData:(NSData *)data format:(NSInteger)format older:(BOOL)older sharedName:(nullable NSString *)sharedName {
    if ((self = [super init])) {
        _data = data;
        _format = format;
        _older = older;
        _sharedName = [sharedName copy];
    }
    return self;
}

@end

// MARK: - Reader

// One read connection and its statements. A reader is used by one thread at a
// time, borrowed from the store's pool.
@interface VibeCacheReader : NSObject {
@public
    sqlite3 *_db;
    sqlite3_stmt *_entry;
    sqlite3_stmt *_shared;
    sqlite3_stmt *_hasEntry;
    sqlite3_stmt *_hasShared;
    sqlite3_stmt *_totals;
    NSUInteger _generation;
}
@end

@implementation VibeCacheReader

- (nullable instancetype)initWithPath:(NSString *)path generation:(NSUInteger)generation {
    if ((self = [super init])) {
        _generation = generation;
        int flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOMUTEX;
        if (sqlite3_open_v2(path.fileSystemRepresentation, &_db, flags, NULL) != SQLITE_OK
            || !VibeCacheConfigure(_db, VibeCacheReaderPageCacheKiB)
            || sqlite3_exec(_db, "PRAGMA query_only = 1;", NULL, NULL, NULL) != SQLITE_OK
            || ![self prepare:&_entry sql:"SELECT format, shared, data, file, size, used FROM entries WHERE id = ?9 AND key = ?1"]
            || ![self prepare:&_shared sql:"SELECT format, NULL, data, file, size, used FROM shared WHERE name = ?1 AND part = ?2"]
            || ![self prepare:&_hasEntry sql:"SELECT 1 FROM entries WHERE id = ?9 AND key = ?1"]
            || ![self prepare:&_hasShared sql:"SELECT 1 FROM shared WHERE name = ?1 AND part = ?2"]
            || ![self prepare:&_totals sql:"SELECT entries, shared, bytes FROM totals"]) {
            return nil;
        }
    }
    return self;
}

- (BOOL)prepare:(sqlite3_stmt **)stmt sql:(const char *)sql {
    return sqlite3_prepare_v3(_db, sql, -1, SQLITE_PREPARE_PERSISTENT, stmt, NULL) == SQLITE_OK;
}

- (void)dealloc {
    sqlite3_finalize(_entry);
    sqlite3_finalize(_shared);
    sqlite3_finalize(_hasEntry);
    sqlite3_finalize(_hasShared);
    sqlite3_finalize(_totals);
    sqlite3_close_v2(_db);
}

@end

// MARK: - Store

static char VibeCacheQueueKey;

static int VibeCacheNoteJournal(void *context, sqlite3 *db, const char *name, int pages);

@implementation VibeCacheStore {
    unsigned long long _byteLimit;  // under @synchronized(self)
    // The one part with a byte limit of its own. Under @synchronized(self).
    NSString *_ownLimitPart;
    unsigned long long _ownLimitPartBytes;
    NSString *_databasePath;
    NSString *_filesPath;
    int _lockFD;
    dispatch_queue_t _queue;

    // The writer, its statements, and its state. Queue only.
    sqlite3 *_writer;
    NSMutableDictionary<NSValue *, NSValue *> *_statements;
    int _journalPages;
    BOOL _checkpointScheduled;
    BOOL _trimming;
    BOOL _remakeScheduled;
    BOOL _maintenanceScheduled;
    int64_t _maintenanceDay;
    // Each mark's day, -1 for a store that held no entry then. Under
    // @synchronized(self).
    NSMutableDictionary<NSString *, NSNumber *> *_marks;
    int64_t _lastWritten;

    // The readers. Under _poolMutex.
    pthread_mutex_t _poolMutex;
    pthread_cond_t _poolCondition;
    NSMutableArray<VibeCacheReader *> *_idleReaders;
    NSUInteger _borrowedReaders;
    NSUInteger _generation;
    BOOL _paused;
    BOOL _closed;

    // A read's uses, written together. Under _touchLock.
    os_unfair_lock _touchLock;
    NSMutableSet<NSString *> *_touchedEntries;
    NSMutableSet<NSArray<NSString *> *> *_touchedShared;
    BOOL _touchScheduled;

    _Atomic(int64_t) _dayOffset;
}

+ (unsigned long long)defaultByteLimit {
    return 1024ULL * 1024 * 1024;
}

+ (NSTimeInterval)defaultAgeLimit {
    return 180 * VibeCacheSecondsPerDay;
}

+ (nullable instancetype)storeWithName:(NSString *)name rootPath:(nullable NSString *)rootPath {
    NSString *root = rootPath ?: NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject;
    if (!root) {
        return nil;
    }
    return [[self alloc] initWithDirectory:[root stringByAppendingPathComponent:name]];
}

- (nullable instancetype)initWithDirectory:(NSString *)directory {
    if (!(self = [super init])) {
        return nil;
    }
    _directory = [directory copy];
    _databasePath = [directory stringByAppendingPathComponent:VibeCacheDatabaseName];
    _filesPath = [directory stringByAppendingPathComponent:VibeCacheFilesName];
    _byteLimit = VibeCacheStore.defaultByteLimit;
    _ageLimit = VibeCacheStore.defaultAgeLimit;
    _inlineLimit = 64 * 1024;
    _lockFD = -1;
    _statements = [NSMutableDictionary dictionary];
    _idleReaders = [NSMutableArray array];
    _touchedEntries = [NSMutableSet set];
    _touchedShared = [NSMutableSet set];
    _touchLock = OS_UNFAIR_LOCK_INIT;
    pthread_mutex_init(&_poolMutex, NULL);
    pthread_cond_init(&_poolCondition, NULL);
    _queue = dispatch_queue_create("vibe.cache-store", dispatch_queue_attr_make_with_qos_class(
        DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0));
    dispatch_queue_set_specific(_queue, &VibeCacheQueueKey, (__bridge void *)self, NULL);

    NSFileManager *fm = NSFileManager.defaultManager;
    if (![fm createDirectoryAtPath:_filesPath withIntermediateDirectories:YES attributes:nil error:NULL]) {
        LogError(@"VibeCacheStore: can't make %@", directory.lastPathComponent);
        _closed = YES;
        return nil;
    }
    // CH21: one open at a time. flock holds per open file, so a second open in
    // this process fails as one in another process does.
    NSString *lockPath = [directory stringByAppendingPathComponent:VibeCacheLockName];
    _lockFD = open(lockPath.fileSystemRepresentation, O_RDWR | O_CREAT | O_CLOEXEC, 0644);
    if (_lockFD < 0 || flock(_lockFD, LOCK_EX | LOCK_NB) != 0) {
        LogError(@"VibeCacheStore: %@ is open elsewhere", directory.lastPathComponent);
        _closed = YES;
        return nil;
    }
    // CH20: a cache holds nothing the user made, so one that will not open is
    // made again.
    if (![self openWriter]) {
        LogWarn(@"VibeCacheStore: remaking %@, which would not open", directory.lastPathComponent);
        [self removeDatabaseFiles];
        if (![self openWriter]) {
            LogError(@"VibeCacheStore: can't make %@", directory.lastPathComponent);
            [self closeWriter];
            _closed = YES;
            return nil;
        }
    }
    [self removePendingFiles:NO];
    [self removeLeftFolders];
    [self scheduleMaintenance];
    // The first write would otherwise prepare its statements and make the
    // journal, about 2 ms, so the queue does both now.
    dispatch_async(_queue, ^{
        if (self->_writer) {
            for (NSValue *sql in @[[NSValue valueWithPointer:VibeCacheUpsertEntry],
                                   [NSValue valueWithPointer:VibeCacheUpsertShared],
                                   [NSValue valueWithPointer:VibeCacheRemoveEntry],
                                   [NSValue valueWithPointer:VibeCacheTotalBytes]]) {
                [self statement:sql.pointerValue];
            }
            [self setInteger:[self today] forMeta:@"opened"];
        }
    });
    return self;
}

- (void)dealloc {
    [self close];
    pthread_mutex_destroy(&_poolMutex);
    pthread_cond_destroy(&_poolCondition);
}

- (void)close {
    [self syncOnQueue:^{
        if (self->_writer) {
            [self flushTouches];
        }
        [self pauseReaders];
        [self closeWriter];
        pthread_mutex_lock(&self->_poolMutex);
        self->_closed = YES;
        self->_paused = NO;
        pthread_cond_broadcast(&self->_poolCondition);
        pthread_mutex_unlock(&self->_poolMutex);
    }];
    if (_lockFD >= 0) {
        flock(_lockFD, LOCK_UN);
        close(_lockFD);
        _lockFD = -1;
    }
}

// MARK: Queue

- (void)syncOnQueue:(dispatch_block_t)block {
    if (dispatch_get_specific(&VibeCacheQueueKey) == (__bridge void *)self) {
        block();
    } else {
        dispatch_sync(_queue, block);
    }
}

// MARK: Marks

// A mark's day as the database keeps it: absent, or the day, or -1.
static NSString *VibeCacheMarkName(NSString *mark) {
    return [@"mark " stringByAppendingString:mark];
}

- (BOOL)mayHoldEntriesFromBeforeMark:(NSString *)mark {
    NSNumber *day;
    @synchronized(self) {
        day = _marks[mark];
    }
    if (!day) {
        __block int64_t recorded = -1;
        [self syncOnQueue:^{
            if (!self->_writer) {
                return;
            }
            NSString *name = VibeCacheMarkName(mark);
            // Day 0, in 2001, is never today, so it means none yet.
            recorded = [self integerForMeta:name];
            if (recorded == 0) {
                sqlite3_stmt *stmt = [self statement:"SELECT entries FROM totals"];
                BOOL held = sqlite3_step(stmt) == SQLITE_ROW && sqlite3_column_int64(stmt, 0) > 0;
                sqlite3_reset(stmt);
                recorded = held ? [self today] : -1;
                [self setInteger:recorded forMeta:name];
            }
        }];
        day = @(recorded);
        @synchronized(self) {
            if (!_marks) {
                _marks = [NSMutableDictionary dictionary];
            }
            _marks[mark] = day;
        }
    }
    int64_t since = day.longLongValue;
    if (since < 0) {
        return NO;
    }
    NSTimeInterval age = self.ageLimit;
    return age <= 0 || [self today] - since <= (int64_t)ceil(age / VibeCacheSecondsPerDay);
}

- (void)renewMark:(NSString *)mark {
    __block int64_t today = 0;
    [self syncOnQueue:^{
        if (self->_writer) {
            today = [self today];
            [self setInteger:today forMeta:VibeCacheMarkName(mark)];
        }
    }];
    if (today) {
        @synchronized(self) {
            if (!_marks) {
                _marks = [NSMutableDictionary dictionary];
            }
            _marks[mark] = @(today);
        }
    }
}

- (void)performAfterQueuedWork:(dispatch_block_t)block {
    dispatch_async(_queue, block);
}

// Runs step on the queue, again and again while it returns YES, then next.
// Each run is its own transaction, so a write waits for one batch at most.
- (void)repeatStep:(BOOL (^)(void))step then:(nullable dispatch_block_t)next {
    dispatch_async(_queue, ^{
        if (self->_writer && step()) {
            [self repeatStep:step then:next];
        } else if (next) {
            next();
        }
    });
}

// The microsecond a row is written, never less than the last. Queue only.
- (int64_t)nextWritten {
    int64_t now = (int64_t)(CFAbsoluteTimeGetCurrent() * 1e6);
    _lastWritten = MAX(now, _lastWritten + 1);
    return _lastWritten;
}

// MARK: Days

- (int64_t)today {
    return [self dayOfTime:CFAbsoluteTimeGetCurrent()];
}

- (int64_t)dayOfTime:(CFAbsoluteTime)time {
    return (int64_t)floor(time / VibeCacheSecondsPerDay) + atomic_load_explicit(&_dayOffset, memory_order_relaxed);
}

// MARK: The writer

- (BOOL)openWriter {
    int flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX;
    if (sqlite3_open_v2(_databasePath.fileSystemRepresentation, &_writer, flags, NULL) != SQLITE_OK) {
        [self closeWriter];
        return NO;
    }
    int version = -1;
    sqlite3_stmt *stmt = NULL;
    if (sqlite3_prepare_v2(_writer, "PRAGMA user_version", -1, &stmt, NULL) == SQLITE_OK
        && sqlite3_step(stmt) == SQLITE_ROW) {
        version = sqlite3_column_int(stmt, 0);
    }
    sqlite3_finalize(stmt);
    BOOL ready = NO;
    if (version == 0) {
        // The page size and auto_vacuum take effect only before the first table.
        NSString *setup = [NSString stringWithFormat:@"PRAGMA page_size = %d; PRAGMA auto_vacuum = INCREMENTAL;",
                                                     VibeCachePageSize];
        ready = sqlite3_exec(_writer, setup.UTF8String, NULL, NULL, NULL) == SQLITE_OK
            && [self setJournalMode]
            && sqlite3_exec(_writer, "BEGIN", NULL, NULL, NULL) == SQLITE_OK
            && sqlite3_exec(_writer, VibeCacheSchema, NULL, NULL, NULL) == SQLITE_OK
            && sqlite3_exec(_writer, [NSString stringWithFormat:@"PRAGMA user_version = %d; COMMIT;",
                                                                VibeCacheSchemaVersion].UTF8String,
                            NULL, NULL, NULL) == SQLITE_OK;
    } else if (version == VibeCacheSchemaVersion) {
        ready = [self setJournalMode];
    }
    ready = ready && VibeCacheConfigure(_writer, VibeCacheWriterPageCacheKiB)
        && sqlite3_exec(_writer, "PRAGMA journal_size_limit = 4194304; SELECT bytes FROM totals;",
                        NULL, NULL, NULL) == SQLITE_OK;
    if (!ready) {
        [self closeWriter];
        return NO;
    }
    // A checkpoint runs on the queue, never inside a caller's write.
    sqlite3_wal_hook(_writer, VibeCacheNoteJournal, (__bridge void *)self);
    _maintenanceDay = [self integerForMeta:@"maintenance"];
    return YES;
}

- (BOOL)setJournalMode {
    sqlite3_stmt *stmt = NULL;
    BOOL wal = NO;
    if (sqlite3_prepare_v2(_writer, "PRAGMA journal_mode = WAL", -1, &stmt, NULL) == SQLITE_OK
        && sqlite3_step(stmt) == SQLITE_ROW) {
        wal = [VibeCacheColumnText(stmt, 0) isEqualToString:@"wal"];
    }
    sqlite3_finalize(stmt);
    return wal;
}

- (void)closeWriter {
    for (NSValue *value in _statements.allValues) {
        sqlite3_finalize(value.pointerValue);
    }
    [_statements removeAllObjects];
    if (_writer) {
        sqlite3_close_v2(_writer);
        _writer = NULL;
    }
}

static int VibeCacheNoteJournal(void *context, sqlite3 *db, const char *name, int pages) {
    VibeCacheStore *store = (__bridge VibeCacheStore *)context;
    store->_journalPages = pages;
    return SQLITE_OK;
}

- (void)checkpointIfLarge {
    if (_journalPages < VibeCacheCheckpointPages || _checkpointScheduled) {
        return;
    }
    _checkpointScheduled = YES;
    dispatch_async(_queue, ^{
        self->_checkpointScheduled = NO;
        if (self->_writer) {
            sqlite3_wal_checkpoint_v2(self->_writer, NULL, SQLITE_CHECKPOINT_PASSIVE, NULL, NULL);
            self->_journalPages = 0;
        }
    });
}

// The database, its journal, and its folder of files. The folder is renamed,
// then removed off the queue. An open removes one a crash left.
- (void)removeDatabaseFiles {
    NSFileManager *fm = NSFileManager.defaultManager;
    for (NSString *suffix in @[@"", @"-wal", @"-shm"]) {
        [fm removeItemAtPath:[_databasePath stringByAppendingString:suffix] error:NULL];
    }
    [self removeFolderAtPath:_filesPath];
    [fm createDirectoryAtPath:_filesPath withIntermediateDirectories:YES attributes:nil error:NULL];
}

- (void)removeFolderAtPath:(NSString *)path {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *removed = [_directory stringByAppendingPathComponent:
        [VibeCacheRemovedPrefix stringByAppendingString:NSUUID.UUID.UUIDString]];
    if ([fm moveItemAtPath:path toPath:removed error:NULL]) {
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_BACKGROUND, 0), ^{
            [NSFileManager.defaultManager removeItemAtPath:removed error:NULL];
        });
    } else {
        [fm removeItemAtPath:path error:NULL];
    }
}

- (void)removeLeftFolders {
    NSString *directory = _directory;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_BACKGROUND, 0), ^{
        NSFileManager *fm = NSFileManager.defaultManager;
        for (NSString *name in [fm contentsOfDirectoryAtPath:directory error:NULL]) {
            if ([name hasPrefix:VibeCacheRemovedPrefix]) {
                [fm removeItemAtPath:[directory stringByAppendingPathComponent:name] error:NULL];
            }
        }
    });
}

// Removes the files listed in pending, the doomed ones alone or, at an open,
// every one: no committed row names any of them.
- (void)removePendingFiles:(BOOL)doomedOnly {
    sqlite3_stmt *list = doomedOnly ? [self statement:VibeCacheDoomedFiles]
                                    : [self statement:"SELECT file FROM pending"];
    BOOL any = NO;
    while (sqlite3_step(list) == SQLITE_ROW) {
        any = YES;
        unlink([self pathOfFile:VibeCacheColumnText(list, 0)].fileSystemRepresentation);
    }
    sqlite3_reset(list);
    if (any) {
        [self run:doomedOnly ? [self statement:"DELETE FROM pending WHERE doomed = 1"]
                             : [self statement:"DELETE FROM pending"]];
    }
}

// Remakes the database after damage, or for a removal of everything.
- (void)remakeDatabase {
    [self pauseReaders];
    [self closeWriter];
    [self removeDatabaseFiles];
    _trimming = NO;
    _journalPages = 0;
    if (![self openWriter]) {
        LogError(@"VibeCacheStore: can't make %@ again", _directory.lastPathComponent);
    }
    [self resumeReaders];
}

// Damage found by a read or a write remakes the database (CH20).
- (void)noteResult:(int)rc {
    int primary = rc & 0xff;
    if (primary != SQLITE_CORRUPT && primary != SQLITE_NOTADB) {
        return;
    }
    dispatch_async(_queue, ^{
        if (self->_remakeScheduled || !self->_writer) {
            return;
        }
        self->_remakeScheduled = YES;
        LogWarn(@"VibeCacheStore: remaking %@, which is damaged", self->_directory.lastPathComponent);
        [self remakeDatabase];
        self->_remakeScheduled = NO;
    });
}

- (sqlite3_stmt *)statement:(const char *)sql {
    NSValue *key = [NSValue valueWithPointer:sql];
    sqlite3_stmt *stmt = [_statements[key] pointerValue];
    if (!stmt) {
        if (sqlite3_prepare_v3(_writer, sql, -1, SQLITE_PREPARE_PERSISTENT, &stmt, NULL) != SQLITE_OK) {
            LogError(@"VibeCacheStore: can't prepare a statement, %s", sqlite3_errmsg(_writer));
            return NULL;
        }
        _statements[key] = [NSValue valueWithPointer:stmt];
    }
    return stmt;
}

// Steps a statement that returns no row, then resets it.
- (BOOL)run:(sqlite3_stmt *)stmt {
    if (!stmt) {
        return NO;
    }
    int rc = sqlite3_step(stmt);
    sqlite3_reset(stmt);
    [self noteResult:rc];
    return rc == SQLITE_DONE;
}

// Runs body in a transaction, commits it when body returns YES, then removes
// the files it doomed.
- (BOOL)transaction:(BOOL (^)(void))body {
    if (sqlite3_exec(_writer, "BEGIN", NULL, NULL, NULL) != SQLITE_OK) {
        return NO;
    }
    if (!body()) {
        sqlite3_exec(_writer, "ROLLBACK", NULL, NULL, NULL);
        return NO;
    }
    int rc = sqlite3_exec(_writer, "COMMIT", NULL, NULL, NULL);
    if (rc != SQLITE_OK) {
        [self noteResult:rc];
        sqlite3_exec(_writer, "ROLLBACK", NULL, NULL, NULL);
        return NO;
    }
    [self removePendingFiles:YES];
    return YES;
}

- (NSString *)pathOfFile:(NSString *)file {
    return [_filesPath stringByAppendingPathComponent:file];
}

- (int64_t)integerForMeta:(NSString *)name {
    sqlite3_stmt *stmt = [self statement:"SELECT value FROM meta WHERE name = ?1"];
    VibeCacheBindText(stmt, 1, name);
    int64_t value = sqlite3_step(stmt) == SQLITE_ROW ? sqlite3_column_int64(stmt, 0) : 0;
    sqlite3_reset(stmt);
    return value;
}

- (void)setInteger:(int64_t)value forMeta:(NSString *)name {
    sqlite3_stmt *stmt = [self statement:"INSERT OR REPLACE INTO meta(name, value) VALUES (?1, ?2)"];
    VibeCacheBindText(stmt, 1, name);
    sqlite3_bind_int64(stmt, 2, value);
    [self run:stmt];
}

- (unsigned long long)bytesOnQueue {
    sqlite3_stmt *stmt = [self statement:VibeCacheTotalBytes];
    sqlite3_int64 bytes = sqlite3_step(stmt) == SQLITE_ROW ? sqlite3_column_int64(stmt, 0) : 0;
    sqlite3_reset(stmt);
    return bytes > 0 ? (unsigned long long)bytes : 0;
}

// MARK: Files

// A new file's name, listed as pending before anything is on disk under it.
- (nullable NSString *)listNewFile {
    uint8_t bytes[8];
    arc4random_buf(bytes, sizeof bytes);
    NSString *file = [NSString stringWithFormat:@"%02x%02x%02x%02x%02x%02x%02x%02x", bytes[0], bytes[1], bytes[2],
                                                bytes[3], bytes[4], bytes[5], bytes[6], bytes[7]];
    sqlite3_stmt *stmt = [self statement:"INSERT OR REPLACE INTO pending VALUES (?1, 0)"];
    VibeCacheBindText(stmt, 1, file);
    return [self run:stmt] ? file : nil;
}

// Lists a new file as pending, then writes it. So a crash at any point leaves
// a file an open removes, never one no row lists.
- (nullable NSString *)writeFileForData:(NSData *)data {
    NSString *file = [self listNewFile];
    if (!file) {
        return nil;
    }
    const char *path = [self pathOfFile:file].fileSystemRepresentation;
    int fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0644);
    BOOL written = fd >= 0;
    const uint8_t *cursor = data.bytes;
    size_t remaining = data.length;
    while (written && remaining > 0) {
        ssize_t count = write(fd, cursor, remaining);
        if (count < 0 && errno == EINTR) {
            continue;
        }
        written = count > 0;
        cursor += written ? count : 0;
        remaining -= written ? (size_t)count : 0;
    }
    if (fd >= 0) {
        written = close(fd) == 0 && written;
    }
    if (!written) {
        LogError(@"VibeCacheStore: can't write a file, errno %d", errno);
        [self dropWrittenFile:file];
        return nil;
    }
    return file;
}

// A file this store wrote whose row never committed.
- (void)dropWrittenFile:(NSString *)file {
    unlink([self pathOfFile:file].fileSystemRepresentation);
    sqlite3_stmt *stmt = [self statement:"DELETE FROM pending WHERE file = ?1"];
    VibeCacheBindText(stmt, 1, file);
    [self run:stmt];
}

// The file's bytes, when its size is the row's. Sets errno to ENOENT when the
// file is gone.
static NSData *_Nullable VibeCacheReadFile(NSString *path, sqlite3_int64 size) {
    int fd = open(path.fileSystemRepresentation, O_RDONLY | O_CLOEXEC);
    if (fd < 0) {
        return nil;
    }
    struct stat info;
    NSData *data = nil;
    BOOL sized = fstat(fd, &info) == 0 && info.st_size == size;
    // Into a buffer that is not zeroed first, since every byte is read over.
    uint8_t *buffer = sized ? malloc(MAX((size_t)size, 1)) : NULL;
    if (buffer) {
        uint8_t *cursor = buffer;
        size_t remaining = (size_t)size;
        BOOL complete = YES;
        while (remaining > 0) {
            ssize_t count = read(fd, cursor, remaining);
            if (count < 0 && errno == EINTR) {
                continue;
            }
            if (count <= 0) {
                complete = NO;
                break;
            }
            cursor += count;
            remaining -= (size_t)count;
        }
        if (complete) {
            data = [NSData dataWithBytesNoCopy:buffer length:(NSUInteger)size freeWhenDone:YES];
        } else {
            free(buffer);
        }
    }
    close(fd);
    if (!data) {
        errno = EIO;
    }
    return data;
}

// MARK: Readers

- (nullable VibeCacheReader *)borrowReader {
    pthread_mutex_lock(&_poolMutex);
    while (_paused) {
        pthread_cond_wait(&_poolCondition, &_poolMutex);
    }
    if (_closed) {
        pthread_mutex_unlock(&_poolMutex);
        return nil;
    }
    VibeCacheReader *reader = _idleReaders.lastObject;
    if (reader) {
        [_idleReaders removeLastObject];
    }
    _borrowedReaders++;
    NSUInteger generation = _generation;
    pthread_mutex_unlock(&_poolMutex);
    if (!reader) {
        reader = [[VibeCacheReader alloc] initWithPath:_databasePath generation:generation];
        if (!reader) {
            [self returnReader:nil];
        }
    }
    return reader;
}

// A reader not kept closes when this returns, outside the lock.
- (void)returnReader:(nullable VibeCacheReader *)reader {
    pthread_mutex_lock(&_poolMutex);
    _borrowedReaders--;
    if (reader && !_closed && !_paused && reader->_generation == _generation
        && _idleReaders.count < VibeCacheIdleReaders) {
        [_idleReaders addObject:reader];
    }
    if (_paused) {
        pthread_cond_broadcast(&_poolCondition);
    }
    pthread_mutex_unlock(&_poolMutex);
}

// Waits for every borrowed reader, and closes the idle ones. Readers then wait
// until resumeReaders. Queue only.
- (void)pauseReaders {
    pthread_mutex_lock(&_poolMutex);
    _paused = YES;
    while (_borrowedReaders > 0) {
        pthread_cond_wait(&_poolCondition, &_poolMutex);
    }
    NSArray *closing = [_idleReaders copy];
    [_idleReaders removeAllObjects];
    pthread_mutex_unlock(&_poolMutex);
    // The idle readers close here, outside the lock.
    (void)closing;
}

- (void)resumeReaders {
    pthread_mutex_lock(&_poolMutex);
    _paused = NO;
    _generation++;
    pthread_cond_broadcast(&_poolCondition);
    pthread_mutex_unlock(&_poolMutex);
}

// MARK: Reads

// An entry under key, or a shared item under name and part when key is nil.
- (nullable VibeCacheHit *)readKey:(nullable NSString *)key
                             name:(nullable NSString *)name
                             part:(nullable NSString *)part
                           format:(NSInteger)format
                      acceptOlder:(BOOL)acceptOlder {
    // A miss on a file that just went may be a replacement's, so it asks once more.
    for (int attempt = 0; attempt < 2; attempt++) {
        VibeCacheReader *reader = [self borrowReader];
        if (!reader) {
            return nil;
        }
        sqlite3_stmt *stmt = key ? reader->_entry : reader->_shared;
        VibeCacheBindRow(stmt, key, name, part);
        int rc = sqlite3_step(stmt);
        if (rc != SQLITE_ROW) {
            sqlite3_reset(stmt);
            [self returnReader:reader];
            [self noteResult:rc];
            return nil;
        }
        NSInteger rowFormat = (NSInteger)sqlite3_column_int64(stmt, 0);
        if (rowFormat > format || (rowFormat < format && !acceptOlder)) {
            sqlite3_reset(stmt);
            [self returnReader:reader];
            return nil;
        }
        NSString *sharedName = VibeCacheColumnText(stmt, 1);
        NSString *file = VibeCacheColumnText(stmt, 3);
        sqlite3_int64 size = sqlite3_column_int64(stmt, 4);
        int64_t used = sqlite3_column_int64(stmt, 5);
        NSData *data = nil;
        if (!file) {
            const void *bytes = sqlite3_column_blob(stmt, 2);
            int length = sqlite3_column_bytes(stmt, 2);
            data = [NSData dataWithBytes:bytes length:(NSUInteger)length];
        }
        sqlite3_reset(stmt);
        [self returnReader:reader];

        if (file) {
            data = VibeCacheReadFile([self pathOfFile:file], size);
            if (!data) {
                if (errno == ENOENT && attempt == 0) {
                    continue;
                }
                [self removeDamagedKey:key name:name part:part file:file];
                return nil;
            }
        }
        if (used < [self today]) {
            [self noteUseOfKey:key name:name part:part];
        }
        return [[VibeCacheHit alloc] initWithData:data format:rowFormat older:rowFormat < format sharedName:sharedName];
    }
    return nil;
}

// A row whose file is gone or the wrong size reads as a miss, and goes, if it
// still names that file.
- (void)removeDamagedKey:(nullable NSString *)key name:(nullable NSString *)name part:(nullable NSString *)part file:(NSString *)file {
    dispatch_async(_queue, ^{
        if (!self->_writer) {
            return;
        }
        sqlite3_stmt *stmt = key ? [self statement:"DELETE FROM entries WHERE id = ?9 AND key = ?1 AND file = ?3"]
                                 : [self statement:"DELETE FROM shared WHERE name = ?1 AND part = ?2 AND file = ?3"];
        VibeCacheBindRow(stmt, key, name, part);
        VibeCacheBindText(stmt, 3, file);
        [self run:stmt];
        [self removePendingFiles:YES];
    });
}

- (BOOL)hasRowForKey:(nullable NSString *)key name:(nullable NSString *)name part:(nullable NSString *)part {
    VibeCacheReader *reader = [self borrowReader];
    if (!reader) {
        return NO;
    }
    sqlite3_stmt *stmt = key ? reader->_hasEntry : reader->_hasShared;
    VibeCacheBindRow(stmt, key, name, part);
    int rc = sqlite3_step(stmt);
    sqlite3_reset(stmt);
    [self returnReader:reader];
    [self noteResult:rc];
    return rc == SQLITE_ROW;
}

- (nullable VibeCacheHit *)hitForKey:(NSString *)key format:(NSInteger)format {
    return [self readKey:key name:nil part:nil format:format acceptOlder:NO];
}

- (nullable VibeCacheHit *)hitForKey:(NSString *)key acceptingFormatsUpTo:(NSInteger)format {
    return [self readKey:key name:nil part:nil format:format acceptOlder:YES];
}

- (BOOL)hasEntryForKey:(NSString *)key {
    return [self hasRowForKey:key name:nil part:nil];
}

- (nullable VibeCacheHit *)sharedHitForName:(NSString *)name part:(NSString *)part format:(NSInteger)format {
    return [self readKey:nil name:name part:part format:format acceptOlder:NO];
}

- (nullable VibeCacheHit *)sharedHitForName:(NSString *)name part:(NSString *)part acceptingFormatsUpTo:(NSInteger)format {
    return [self readKey:nil name:name part:part format:format acceptOlder:YES];
}

- (BOOL)hasSharedItemForName:(NSString *)name part:(NSString *)part {
    return [self hasRowForKey:nil name:name part:part];
}

- (VibeCacheUsage)usage {
    VibeCacheUsage usage = {0, 0, 0};
    VibeCacheReader *reader = [self borrowReader];
    if (!reader) {
        return usage;
    }
    int rc = sqlite3_step(reader->_totals);
    if (rc == SQLITE_ROW) {
        usage.entries = (NSUInteger)MAX(sqlite3_column_int64(reader->_totals, 0), 0);
        usage.sharedItems = (NSUInteger)MAX(sqlite3_column_int64(reader->_totals, 1), 0);
        usage.bytes = (unsigned long long)MAX(sqlite3_column_int64(reader->_totals, 2), 0);
    }
    sqlite3_reset(reader->_totals);
    [self returnReader:reader];
    [self noteResult:rc];
    return usage;
}

- (void)usageWithCompletion:(void (^)(VibeCacheUsage))completion {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        VibeCacheUsage usage = [self usage];
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(usage);
        });
    });
}

// MARK: Uses

// A read records its use once a day at most, and the writes wait a moment so
// a launch's reads share one transaction.
- (void)noteUseOfKey:(nullable NSString *)key name:(nullable NSString *)name part:(nullable NSString *)part {
    BOOL schedule = NO;
    os_unfair_lock_lock(&_touchLock);
    if (key) {
        [_touchedEntries addObject:key];
    } else if (name && part) {
        [_touchedShared addObject:@[name, part]];
    }
    if (!_touchScheduled) {
        _touchScheduled = schedule = YES;
    }
    os_unfair_lock_unlock(&_touchLock);
    if (schedule) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, VibeCacheTouchDelayMs * NSEC_PER_MSEC), _queue, ^{
            [self flushTouches];
        });
    }
}

- (void)flushTouches {
    os_unfair_lock_lock(&_touchLock);
    NSSet<NSString *> *entries = _touchedEntries;
    NSSet<NSArray<NSString *> *> *shared = _touchedShared;
    _touchedEntries = [NSMutableSet set];
    _touchedShared = [NSMutableSet set];
    _touchScheduled = NO;
    os_unfair_lock_unlock(&_touchLock);
    if (!_writer || (entries.count == 0 && shared.count == 0)) {
        return;
    }
    int64_t today = [self today];
    [self transaction:^BOOL {
        sqlite3_stmt *stmt = [self statement:"UPDATE entries SET used = ?2 WHERE id = ?9 AND key = ?1 AND used < ?2"];
        for (NSString *key in entries) {
            VibeCacheBindKey(stmt, key);
            sqlite3_bind_int64(stmt, 2, today);
            [self run:stmt];
        }
        stmt = [self statement:"UPDATE shared SET used = ?3 WHERE name = ?1 AND part = ?2 AND used < ?3"];
        for (NSArray<NSString *> *pair in shared) {
            VibeCacheBindText(stmt, 1, pair[0]);
            VibeCacheBindText(stmt, 2, pair[1]);
            sqlite3_bind_int64(stmt, 3, today);
            [self run:stmt];
        }
        return YES;
    }];
}

// MARK: Writes

- (void)setData:(NSData *)data forKey:(NSString *)key format:(NSInteger)format sharedName:(nullable NSString *)sharedName {
    if (data && key) {
        [self writeKey:key data:data format:format sharedName:sharedName parts:nil partFormat:0 missingOnly:NO];
    }
}

- (void)setData:(NSData *)data
               forKey:(NSString *)key
               format:(NSInteger)format
           sharedName:(NSString *)sharedName
    missingSharedParts:(NSDictionary<NSString *, NSData *> *)parts
           partFormat:(NSInteger)partFormat {
    if (data && key) {
        [self writeKey:key data:data format:format sharedName:sharedName parts:sharedName ? parts : nil
            partFormat:partFormat missingOnly:YES];
    }
}

- (void)setSharedData:(NSData *)data forName:(NSString *)name part:(NSString *)part format:(NSInteger)format {
    if (data && name && part) {
        [self writeKey:nil data:nil format:0 sharedName:name parts:@{part: data} partFormat:format missingOnly:NO];
    }
}

// Writes the entry under key, if any, and the parts of the shared item
// sharedName, in one transaction. With missingOnly, a part the item has is
// left as it is. A failed write leaves none of its rows, so each reads as a
// miss. Queue only, through syncOnQueue.
- (void)writeKey:(nullable NSString *)key
            data:(nullable NSData *)data
          format:(NSInteger)format
      sharedName:(nullable NSString *)sharedName
           parts:(nullable NSDictionary<NSString *, NSData *> *)parts
      partFormat:(NSInteger)partFormat
     missingOnly:(BOOL)missingOnly {
    NSUInteger inlineLimit = self.inlineLimit;
    [self syncOnQueue:^{
        if (!self->_writer) {
            return;
        }
        NSMutableArray<NSString *> *partNames = [NSMutableArray array];
        for (NSString *part in parts) {
            if (missingOnly) {
                sqlite3_stmt *has = [self statement:"SELECT 1 FROM shared WHERE name = ?1 AND part = ?2"];
                VibeCacheBindText(has, 1, sharedName);
                VibeCacheBindText(has, 2, part);
                BOOL present = sqlite3_step(has) == SQLITE_ROW;
                sqlite3_reset(has);
                if (present) {
                    continue;
                }
            }
            [partNames addObject:part];
        }
        // A large blob's file is written before the transaction, listed as
        // pending, and the transaction takes it off the list.
        NSMutableArray<NSString *> *files = [NSMutableArray array];
        NSString *(^fileFor)(NSData *) = ^NSString *(NSData *blob) {
            if (blob.length <= inlineLimit) {
                return (NSString *)NSNull.null;
            }
            NSString *file = [self writeFileForData:blob];
            if (file) {
                [files addObject:file];
            }
            return file;
        };
        NSString *entryFile = key ? fileFor(data) : nil;
        NSMutableArray<NSString *> *partFiles = [NSMutableArray array];
        BOOL filed = !key || entryFile;
        for (NSString *part in partNames) {
            NSString *file = filed ? fileFor(parts[part]) : nil;
            filed = filed && file;
            if (file) {
                [partFiles addObject:file];
            }
        }
        BOOL written = filed && [self transaction:^BOOL {
            int64_t today = [self today];
            NSString *(^fileOrNil)(NSString *) = ^NSString *(NSString *file) {
                return [file isEqual:NSNull.null] ? nil : file;
            };
            if (key && ![self upsertRowForKey:key name:nil part:nil format:format sharedName:sharedName
                                          data:fileOrNil(entryFile) ? nil : data file:fileOrNil(entryFile)
                                          size:data.length used:today]) {
                return NO;
            }
            for (NSUInteger i = 0; i < partNames.count; i++) {
                NSData *blob = parts[partNames[i]];
                NSString *file = fileOrNil(partFiles[i]);
                if (![self upsertRowForKey:nil name:sharedName part:partNames[i] format:partFormat sharedName:nil
                                      data:file ? nil : blob file:file size:blob.length used:today]) {
                    return NO;
                }
            }
            sqlite3_stmt *listed = [self statement:"DELETE FROM pending WHERE file = ?1"];
            for (NSString *file in files) {
                VibeCacheBindText(listed, 1, file);
                if (![self run:listed]) {
                    return NO;
                }
            }
            return YES;
        }];
        if (!written) {
            // A failed write leaves no row, so an old one can't answer.
            for (NSString *file in files) {
                [self dropWrittenFile:file];
            }
            if (key) {
                [self removeRowOfKey:key name:nil part:nil];
            }
            for (NSString *part in partNames) {
                [self removeRowOfKey:nil name:sharedName part:part];
            }
            return;
        }
        [self afterWrite];
    }];
}

// Writes one row, in a transaction that also takes its file off the pending
// list. Queue only.
- (BOOL)writeRowForKey:(nullable NSString *)key
                  name:(nullable NSString *)name
                  part:(nullable NSString *)part
                format:(NSInteger)format
            sharedName:(nullable NSString *)sharedName
                  data:(nullable NSData *)data
                  file:(nullable NSString *)file
                  size:(NSUInteger)size
                  used:(int64_t)used {
    return [self transaction:^BOOL {
        if (![self upsertRowForKey:key name:name part:part format:format sharedName:sharedName data:data
                              file:file size:size used:used]) {
            return NO;
        }
        if (!file) {
            return YES;
        }
        sqlite3_stmt *listed = [self statement:"DELETE FROM pending WHERE file = ?1"];
        VibeCacheBindText(listed, 1, file);
        return [self run:listed];
    }];
}

// Writes or replaces one row, an entry under key or a shared item's part, with
// its blob in the row or its file's name. Inside a transaction. Queue only.
- (BOOL)upsertRowForKey:(nullable NSString *)key
                   name:(nullable NSString *)name
                   part:(nullable NSString *)part
                 format:(NSInteger)format
             sharedName:(nullable NSString *)sharedName
                   data:(nullable NSData *)data
                   file:(nullable NSString *)file
                   size:(NSUInteger)size
                   used:(int64_t)used {
    sqlite3_stmt *stmt = [self statement:key ? VibeCacheUpsertEntry : VibeCacheUpsertShared];
    if (key) {
        VibeCacheBindKey(stmt, key);
        VibeCacheBindText(stmt, 3, sharedName);
    } else {
        VibeCacheBindText(stmt, 1, name);
        VibeCacheBindText(stmt, 8, part);
    }
    sqlite3_bind_int64(stmt, 2, format);
    if (file) {
        sqlite3_bind_null(stmt, 4);
    } else {
        sqlite3_bind_blob64(stmt, 4, data.bytes ?: "", data.length, SQLITE_STATIC);
    }
    VibeCacheBindText(stmt, 5, file);
    sqlite3_bind_int64(stmt, 6, (sqlite3_int64)size);
    sqlite3_bind_int64(stmt, 7, used);
    sqlite3_bind_int64(stmt, 10, [self nextWritten]);
    return [self run:stmt];
}

- (BOOL)adoptFileAtPath:(NSString *)path forKey:(NSString *)key format:(NSInteger)format lastUse:(nullable NSDate *)lastUse {
    struct stat info;
    if (!path || !key || stat(path.fileSystemRepresentation, &info) != 0 || !S_ISREG(info.st_mode)) {
        return NO;
    }
    __block BOOL adopted = NO;
    [self syncOnQueue:^{
        if (!self->_writer) {
            return;
        }
        // An entry already there is newer than the file.
        sqlite3_stmt *has = [self statement:"SELECT 1 FROM entries WHERE id = ?9 AND key = ?1"];
        VibeCacheBindKey(has, key);
        BOOL present = sqlite3_step(has) == SQLITE_ROW;
        sqlite3_reset(has);
        if (present) {
            return;
        }
        int64_t today = [self today];
        int64_t used = lastUse ? MIN(today, [self dayOfTime:lastUse.timeIntervalSinceReferenceDate]) : today;
        NSUInteger size = (NSUInteger)info.st_size;
        // A small file goes into its row, as a write's would, and a large one
        // is renamed into Files. Listed first, so a crash after the rename
        // leaves a file the next open removes.
        NSData *data = size <= self.inlineLimit ? VibeCacheReadFile(path, info.st_size) : nil;
        NSString *file = data ? nil : [self listNewFile];
        if (file && rename(path.fileSystemRepresentation, [self pathOfFile:file].fileSystemRepresentation) != 0) {
            [self dropWrittenFile:file];
            file = nil;
        }
        if (!data && !file) {
            return;
        }
        adopted = [self writeRowForKey:key name:nil part:nil format:format sharedName:nil data:data file:file
                                  size:size used:used];
        if (!adopted && file) {
            [self dropWrittenFile:file];
        }
        if (adopted && data) {
            unlink(path.fileSystemRepresentation);
        }
        if (adopted) {
            [self afterWrite];
        }
    }];
    return adopted;
}

// Removes one row. The triggers list its file and the shared item it was the
// last to name. Queue only.
- (void)removeRowOfKey:(nullable NSString *)key name:(nullable NSString *)name part:(nullable NSString *)part {
    sqlite3_stmt *stmt = key ? [self statement:VibeCacheRemoveEntry]
                             : [self statement:"DELETE FROM shared WHERE name = ?1 AND part = ?2"];
    VibeCacheBindRow(stmt, key, name, part);
    [self run:stmt];
    [self removePendingFiles:YES];
}

- (void)removeEntryForKey:(NSString *)key {
    if (!key) {
        return;
    }
    [self syncOnQueue:^{
        if (self->_writer) {
            [self removeRowOfKey:key name:nil part:nil];
        }
    }];
}

- (void)removeSharedItemForName:(NSString *)name part:(NSString *)part {
    if (!name || !part) {
        return;
    }
    [self syncOnQueue:^{
        if (self->_writer) {
            [self removeRowOfKey:nil name:name part:part];
        }
    }];
}

- (BOOL)moveEntryFromKey:(NSString *)oldKey toKey:(NSString *)newKey {
    if (!oldKey || !newKey) {
        return NO;
    }
    if ([oldKey isEqualToString:newKey]) {
        return [self hasEntryForKey:oldKey];
    }
    __block BOOL moved = NO;
    [self syncOnQueue:^{
        if (!self->_writer) {
            return;
        }
        moved = [self transaction:^BOOL {
            sqlite3_stmt *has = [self statement:"SELECT 1 FROM entries WHERE id = ?9 AND key = ?1"];
            VibeCacheBindKey(has, oldKey);
            BOOL present = sqlite3_step(has) == SQLITE_ROW;
            sqlite3_reset(has);
            if (!present) {
                return NO;
            }
            // The row the new key's id holds goes first, whatever its key,
            // while the moved row still names its shared item, so the two
            // can share one.
            sqlite3_stmt *remove = [self statement:"DELETE FROM entries WHERE id = ?9"];
            sqlite3_bind_int64(remove, 9, VibeCacheKeyID(newKey));
            sqlite3_stmt *move = [self statement:"UPDATE entries SET id = ?8, key = ?2 WHERE id = ?9 AND key = ?1"];
            VibeCacheBindKey(move, oldKey);
            VibeCacheBindText(move, 2, newKey);
            sqlite3_bind_int64(move, 8, VibeCacheKeyID(newKey));
            return [self run:remove] && [self run:move];
        }];
    }];
    return moved;
}

- (void)removeAllWithCompletion:(nullable dispatch_block_t)completion {
    dispatch_async(_queue, ^{
        if (self->_writer) {
            [self remakeDatabase];
        }
        if (completion) {
            completion();
        }
    });
}

// MARK: Limits

- (unsigned long long)byteLimit {
    @synchronized(self) {
        return _byteLimit;
    }
}

- (void)setByteLimit:(unsigned long long)byteLimit {
    @synchronized(self) {
        _byteLimit = byteLimit;
    }
    dispatch_async(_queue, ^{
        [self afterWrite];
    });
}

- (void)setByteLimit:(unsigned long long)byteLimit ofSharedPart:(NSString *)part {
    @synchronized(self) {
        _ownLimitPart = [part copy];
        _ownLimitPartBytes = byteLimit;
    }
    dispatch_async(_queue, ^{
        [self afterWrite];
    });
}

// The bytes of one part's rows. Queue only.
- (unsigned long long)bytesOfPart:(NSString *)part {
    sqlite3_stmt *stmt = [self statement:"SELECT bytes FROM part_bytes WHERE part = ?1"];
    VibeCacheBindText(stmt, 1, part);
    sqlite3_int64 bytes = sqlite3_step(stmt) == SQLITE_ROW ? sqlite3_column_int64(stmt, 0) : 0;
    sqlite3_reset(stmt);
    return bytes > 0 ? (unsigned long long)bytes : 0;
}

// The bytes a trim measures: the part's own, or every row's but that
// part's. Queue only.
- (unsigned long long)bytesOfBudget:(nullable NSString *)part apart:(nullable NSString *)apart {
    if (part) {
        return [self bytesOfPart:part];
    }
    unsigned long long bytes = [self bytesOnQueue];
    unsigned long long apartBytes = apart ? [self bytesOfPart:apart] : 0;
    return bytes > apartBytes ? bytes - apartBytes : 0;
}

- (void)afterWrite {
    if (!_writer) {
        return;
    }
    [self checkpointIfLarge];
    if (_maintenanceDay != [self today]) {
        [self scheduleMaintenance];
    }
    if (_trimming) {
        return;
    }
    unsigned long long limit;
    NSString *part;
    unsigned long long partLimit;
    @synchronized(self) {
        limit = _byteLimit;
        part = _ownLimitPart;
        partLimit = _ownLimitPartBytes;
    }
    BOOL trimPart = part && partLimit > 0 && [self bytesOfPart:part] > partLimit;
    BOOL trimRest = limit > 0 && [self bytesOfBudget:nil apart:part] > limit;
    if (!trimPart && !trimRest) {
        return;
    }
    _trimming = YES;
    // The part's own budget first, then the rest's, each to 90% of its limit.
    // A budget at its target returns at once.
    [self repeatStep:^BOOL {
        return (trimPart && [self removeOldestUsedBefore:INT64_MAX untilBytes:partLimit / 10 * 9 ofPart:part apart:nil])
            || (trimRest && [self removeOldestUsedBefore:INT64_MAX untilBytes:limit / 10 * 9 ofPart:nil apart:part]);
    } then:^{
        self->_trimming = NO;
        [self vacuum];
        // Writes during the trim skipped their own check.
        [self afterWrite];
    }];
}

// Removes a batch of the least recently used rows used before `cutoff`,
// stopping once the budget's bytes are at `target`. With `part`, only that
// part's shared items, against its own bytes. Otherwise entries and shared
// items together, except `apart`'s, against every other row's bytes. A target
// of 0 removes every such row used before the cutoff. YES when more may
// remain.
- (BOOL)removeOldestUsedBefore:(int64_t)cutoff
                    untilBytes:(unsigned long long)target
                        ofPart:(nullable NSString *)part
                         apart:(nullable NSString *)apart {
    if (target > 0 && [self bytesOfBudget:part apart:apart] <= target) {
        return NO;
    }
    __block int removed = 0;
    __block BOOL reachedTarget = NO;
    BOOL committed = [self transaction:^BOOL {
        sqlite3_stmt *oldest;
        if (part) {
            oldest = [self statement:
                "SELECT 1, rowid FROM shared WHERE part = ?3 AND used < ?1 ORDER BY used, written LIMIT ?2"];
            VibeCacheBindText(oldest, 3, part);
        } else {
            // SQLite merges the two tables' indexes of use, oldest first.
            oldest = [self statement:
                "SELECT 0, rowid, used, written FROM entries WHERE used < ?1 "
                "UNION ALL SELECT 1, rowid, used, written FROM shared WHERE used < ?1 AND part IS NOT ?3 "
                "ORDER BY used, written LIMIT ?2"];
            VibeCacheBindText(oldest, 3, apart);
        }
        sqlite3_bind_int64(oldest, 1, cutoff);
        sqlite3_bind_int(oldest, 2, VibeCacheBatch);
        sqlite3_int64 rows[VibeCacheBatch][2];
        int count = 0;
        while (count < VibeCacheBatch && sqlite3_step(oldest) == SQLITE_ROW) {
            rows[count][0] = sqlite3_column_int64(oldest, 0);
            rows[count][1] = sqlite3_column_int64(oldest, 1);
            count++;
        }
        sqlite3_reset(oldest);
        sqlite3_stmt *removeEntry = [self statement:"DELETE FROM entries WHERE rowid = ?1"];
        sqlite3_stmt *removeShared = [self statement:"DELETE FROM shared WHERE rowid = ?1"];
        for (int i = 0; i < count; i++) {
            if (target > 0 && [self bytesOfBudget:part apart:apart] <= target) {
                reachedTarget = YES;
                break;
            }
            sqlite3_stmt *stmt = rows[i][0] == 0 ? removeEntry : removeShared;
            sqlite3_bind_int64(stmt, 1, rows[i][1]);
            [self run:stmt];
            removed++;
        }
        return YES;
    }];
    return committed && removed == VibeCacheBatch && !reachedTarget;
}

// Gives the freed pages back to the disk.
- (void)vacuum {
    if (_writer) {
        sqlite3_exec(_writer, "PRAGMA incremental_vacuum", NULL, NULL, NULL);
    }
}

// MARK: Maintenance

- (void)scheduleMaintenance {
    if (_maintenanceScheduled) {
        return;
    }
    _maintenanceScheduled = YES;
    __weak VibeCacheStore *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, VibeCacheMaintenanceDelay * NSEC_PER_SEC), _queue, ^{
        [weakSelf maintainIfNewDay];
    });
}

- (void)maintainIfNewDay {
    _maintenanceScheduled = NO;
    if (_writer && _maintenanceDay != [self today]) {
        [self maintainWithCompletion:nil];
    }
}

- (void)performMaintenanceWithCompletion:(nullable dispatch_block_t)completion {
    dispatch_async(_queue, ^{
        if (!self->_writer) {
            if (completion) {
                completion();
            }
            return;
        }
        [self maintainWithCompletion:completion];
    });
}

// The age limit, then the shared items no entry ever named, then the byte
// limit, each in batches. Queue only.
- (void)maintainWithCompletion:(nullable dispatch_block_t)completion {
    int64_t today = [self today];
    _maintenanceDay = today;
    [self setInteger:today forMeta:@"maintenance"];
    NSTimeInterval age = self.ageLimit;
    int64_t cutoff = age > 0 ? today - (int64_t)ceil(age / VibeCacheSecondsPerDay) : INT64_MIN;
    [self repeatStep:^BOOL {
        return cutoff > INT64_MIN && [self removeOldestUsedBefore:cutoff untilBytes:0 ofPart:nil apart:nil];
    } then:^{
        [self repeatStep:^BOOL {
            return [self sweepUnnamedShared];
        } then:^{
            [self vacuum];
            [self afterWrite];
            if (completion) {
                completion();
            }
        }];
    }];
}

// One batch of the shared items no entry names: those written before any entry
// named them, whose entry never came. The triggers take the rest as they go.
// YES when more may remain.
- (BOOL)sweepUnnamedShared {
    __block int removed = 0;
    BOOL committed = [self transaction:^BOOL {
        sqlite3_stmt *stmt = [self statement:
            "DELETE FROM shared WHERE rowid IN (SELECT rowid FROM shared WHERE NOT EXISTS "
            "(SELECT 1 FROM entries WHERE entries.shared = shared.name) LIMIT ?1)"];
        sqlite3_bind_int(stmt, 1, VibeCacheBatch);
        BOOL ran = [self run:stmt];
        removed = sqlite3_changes(self->_writer);
        return ran;
    }];
    return committed && removed == VibeCacheBatch;
}

@end

// MARK: - Testing

@implementation VibeCacheStore (Testing)

- (void)setDayOffsetForTesting:(NSInteger)days {
#if DEBUG
    atomic_store(&_dayOffset, (int64_t)days);
#endif
}

- (void)recordUsesNowForTesting {
#if DEBUG
    [self syncOnQueue:^{
        [self flushTouches];
    }];
#endif
}

@end
