//
//  PINCacheTests.m
//
//  The vendored PINCache builds and links on its own: an object written to a
//  cache in a temporary folder reads back. A trim survives a record whose
//  size is unknown.
//

#import <XCTest/XCTest.h>
#import <PINCache/PINCache.h>
#import <PINCache/PINDiskCache.h>

@interface PINCacheTests : XCTestCase
// A record's size is nil when its file's attributes could not be read at
// launch. The size trim compared it with -[NSNumber compare:], which raises on
// nil. It now sorts as the largest, so it goes first. The record is reached
// by key-value coding, since no API makes one.
- (void)testATrimSurvivesARecordOfUnknownSize {
    NSString *root = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    PINDiskCache *disk = [[PINDiskCache alloc] initWithName:@"unknown-size" rootPath:root];
    NSData *bytes = [NSMutableData dataWithLength:1000];
    for (NSString *key in @[@"a", @"b", @"c"]) {
        [disk setObject:bytes forKey:key];
    }
    XCTAssertTrue([disk containsObjectForKey:@"b"]);
    NSDictionary *records = [disk valueForKey:@"metadata"];
    [records[@"b"] setValue:nil forKey:@"size"];
    XCTAssertNoThrow([disk trimToSize:disk.byteCount - 1]);
    XCTAssertFalse([disk containsObjectForKey:@"b"]);
    [disk removeAllObjects];
    [NSFileManager.defaultManager removeItemAtPath:root error:nil];
}

@end

@implementation PINCacheTests

- (void)testObjectReadsBack {
    NSString *root = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    PINCache *cache = [[PINCache alloc] initWithName:@"probe" rootPath:root];
    [cache setObject:@"value" forKey:@"key"];
    XCTAssertEqualObjects([cache objectForKey:@"key"], @"value");
    [cache removeAllObjects];
    [NSFileManager.defaultManager removeItemAtPath:root error:nil];
}

// A record's size is nil when its file's attributes could not be read at
// launch. The size trim compared it with -[NSNumber compare:], which raises on
// nil. It now sorts as the largest, so it goes first. The record is reached
// by key-value coding, since no API makes one.
- (void)testATrimSurvivesARecordOfUnknownSize {
    NSString *root = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    PINDiskCache *disk = [[PINDiskCache alloc] initWithName:@"unknown-size" rootPath:root];
    NSData *bytes = [NSMutableData dataWithLength:1000];
    for (NSString *key in @[@"a", @"b", @"c"]) {
        [disk setObject:bytes forKey:key];
    }
    XCTAssertTrue([disk containsObjectForKey:@"b"]);
    NSDictionary *records = [disk valueForKey:@"metadata"];
    [records[@"b"] setValue:nil forKey:@"size"];
    XCTAssertNoThrow([disk trimToSize:disk.byteCount - 1]);
    XCTAssertFalse([disk containsObjectForKey:@"b"]);
    [disk removeAllObjects];
    [NSFileManager.defaultManager removeItemAtPath:root error:nil];
}

@end
