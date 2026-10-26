//
//  ICloudLookupFixtures.h
//
//  iCloud Drive's lookup, for the tests of a share link: one shared file's
//  answer, and the signed address it names. ShareLinks' tests and an app's
//  link tests share it.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// An iCloud Drive lookup's answer for one shared file, in the shape iCloud
// sends, with fake values. The owner's name and address are fake too:
// nothing may read them.
static const long long kICloudModified = 1700000000;

static inline NSMutableDictionary *ICloudLookup(NSString *checksum, long long size, NSString *basename,
                                                NSString *extension, NSString *address) {
    NSDictionary *owner = @{@"nameComponents": @{@"givenName": @"Owner", @"familyName": @"Name"},
                            @"lookupInfo": @{@"emailAddress": @"owner@example.com"}};
    NSDictionary *content = @{@"fileChecksum": checksum, @"size": @(size), @"wrappingKey": @"AAAAAAAAAAAAAAAAAAAAAA==",
                              @"referenceChecksum": @"AQAAAAAAAAAAAAAAAAAAAAAAAAAA", @"downloadURL": address};
    NSMutableDictionary *fields = [@{
        @"lastEditorName": @{@"value": @"{\"name\":{\"last\":\"Name\",\"first\":\"Owner\"}}", @"type": @"STRING"},
        @"extension": @{@"value": extension, @"type": @"STRING"},
        @"size": @{@"value": @(size), @"type": @"NUMBER_INT64"},
        @"encryptedBasename": @{@"value": [[basename dataUsingEncoding:NSUTF8StringEncoding] base64EncodedStringWithOptions:0],
                                @"type": @"ENCRYPTED_BYTES"},
        @"mtime": @{@"value": @(kICloudModified), @"type": @"NUMBER_INT64"},
        @"fileContent": @{@"value": content, @"type": @"ASSETID"},
    } mutableCopy];
    NSMutableDictionary *record = [@{@"recordName": @"documentContent/00000000-0000-0000-0000-000000000000",
                                     @"recordType": @"content", @"fields": fields} mutableCopy];
    NSMutableDictionary *result = [@{
        @"shortGUID": @{@"value": @"0FakeShareID0000000000000", @"shouldFetchRootRecord": @YES},
        @"containerIdentifier": @"com.apple.clouddocs",
        @"databaseScope": @"SHARED",
        @"share": @{@"recordType": @"cloudkit.share", @"publicPermission": @"READ_ONLY",
                    @"participants": @[@{@"type": @"OWNER", @"userIdentity": owner}]},
        @"rootRecord": record,
        @"ancestorRecords": @[],
        @"ownerIdentity": owner,
        @"anonymousPublicAccess": @{@"token": @"fake", @"tokenTTL": @1200000},
        @"minimallyResolved": @NO,
        @"requireAppleLogin": @NO,
    } mutableCopy];
    return [@{@"results": @[result]} mutableCopy];
}

// The answer's one result, to change a field.
static inline NSMutableDictionary *ICloudResult(NSMutableDictionary *lookup) {
    return lookup[@"results"][0];
}

// A signed address as iCloud's lookup gives it: ${f} for the name, an
// expiry, and a signature, which tells one lookup's address from another's.
static inline NSString *ICloudAddress(NSString *checksum, long long expiry, NSString *signature) {
    return [NSString stringWithFormat:@"https://cvws.icloud-content.com/B/%@/${f}?o=AAAA&v=1&e=%lld&k=key&s=%@",
                                      checksum, expiry, signature];
}

NS_ASSUME_NONNULL_END
