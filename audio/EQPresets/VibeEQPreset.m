//
//  VibeEQPreset.m
//  vibe-libs
//

#import "VibeEQPreset.h"

static NSString *const kIdentifierKey = @"identifier";
static NSString *const kNameKey = @"name";
static NSString *const kKindKey = @"kind";
static NSString *const kSourceKey = @"source";
static NSString *const kBandsKey = @"bands";
static NSString *const kPreampKey = @"preampDB";

@implementation VibeEQPreset

- (instancetype)initWithIdentifier:(NSString *)identifier
                              name:(NSString *)name
                              kind:(VibeEQPresetKind)kind
                            source:(NSString *)source
                             bands:(NSArray<VibeEQBand *> *)bands
                          preampDB:(double)preampDB {
    self = [super init];
    if (self) {
        _identifier = [identifier copy];
        _name = [name copy];
        _kind = (kind >= VibeEQPresetKindBuiltIn && kind <= VibeEQPresetKindUser) ? kind : VibeEQPresetKindUser;
        _source = [source copy];
        _bands = bands.count > kVibeListeningMaxBands ? [bands subarrayWithRange:NSMakeRange(0, kVibeListeningMaxBands)]
                                                      : [bands copy];
        _preampDB = isfinite(preampDB) ? MIN(kVibeListeningPreampMaxDB, MAX(kVibeListeningPreampMinDB, preampDB)) : 0;
    }
    return self;
}

+ (instancetype)presetWithName:(NSString *)name settings:(VibeListeningSettings *)settings {
    double preamp = settings.preampAutomatic ? VibeListeningAutomaticPreampDB(settings.bands) : settings.preampDB;
    return [[self alloc] initWithIdentifier:[@"user." stringByAppendingString:NSUUID.UUID.UUIDString]
                                       name:name
                                       kind:VibeEQPresetKindUser
                                     source:nil
                                      bands:settings.bands
                                   preampDB:preamp];
}

- (BOOL)matchesSettings:(VibeListeningSettings *)settings {
    if (!settings.eqEnabled || ![settings.bands isEqualToArray:self.bands]) {
        return NO;
    }
    // A manual preamp the preset saved matches too, though applying would turn
    // one that cuts less than the automatic preamp back to automatic.
    return (!settings.preampAutomatic && settings.preampDB == self.preampDB) ||
           fabs(settings.effectivePreampDB - [self applyingToSettings:settings].effectivePreampDB) < 1e-9;
}

- (VibeListeningSettings *)applyingToSettings:(VibeListeningSettings *)settings {
    VibeMutableListeningSettings *applied = [settings mutableCopy];
    applied.bands = self.bands;
    applied.eqEnabled = YES;
    BOOL manual = self.preampDB < VibeListeningAutomaticPreampDB(self.bands);
    applied.preampAutomatic = !manual;
    if (manual) {
        applied.preampDB = self.preampDB;
    }
    return [applied copy];
}

#pragma mark - Equality

- (BOOL)isEqual:(id)object {
    if (object == self) {
        return YES;
    }
    if (![object isKindOfClass:[VibeEQPreset class]]) {
        return NO;
    }
    VibeEQPreset *other = object;
    return [self.identifier isEqualToString:other.identifier] && [self.name isEqualToString:other.name] &&
           self.kind == other.kind && (self.source == other.source || [self.source isEqualToString:other.source]) &&
           [self.bands isEqualToArray:other.bands] && self.preampDB == other.preampDB;
}

- (NSUInteger)hash {
    return self.identifier.hash ^ self.name.hash;
}

#pragma mark - Property lists

static NSString *const kKindNames[] = {
    [VibeEQPresetKindBuiltIn] = @"builtIn", [VibeEQPresetKindHeadphone] = @"headphone", [VibeEQPresetKindUser] = @"user"};

- (NSDictionary<NSString *, id> *)propertyList {
    VibeMutableListeningSettings *settings = [[VibeListeningSettings neutralSettings] mutableCopy];
    settings.bands = self.bands;
    NSMutableDictionary *plist = [@{
        kIdentifierKey : self.identifier,
        kNameKey : self.name,
        kKindKey : kKindNames[self.kind],
        kBandsKey : settings.propertyList[@"bands"],
        kPreampKey : @(self.preampDB),
    } mutableCopy];
    plist[kSourceKey] = self.source;
    return [plist copy];
}

- (instancetype)initWithPropertyList:(id)propertyList {
    if (![propertyList isKindOfClass:[NSDictionary class]]) {
        return nil;
    }
    NSDictionary *plist = propertyList;
    id identifier = plist[kIdentifierKey], name = plist[kNameKey], source = plist[kSourceKey], preamp = plist[kPreampKey];
    id kindName = plist[kKindKey];
    NSInteger kind = -1;
    for (NSInteger i = VibeEQPresetKindBuiltIn; i <= VibeEQPresetKindUser && kind < 0; i++) {
        if ([kKindNames[i] isEqual:kindName]) {
            kind = i;
        }
    }
    if (![identifier isKindOfClass:[NSString class]] || ![name isKindOfClass:[NSString class]] || kind < 0) {
        return nil;
    }
    // The settings read the same "bands" key, and never throw.
    return [self initWithIdentifier:identifier
                               name:name
                               kind:kind
                             source:[source isKindOfClass:[NSString class]] ? source : nil
                              bands:[[VibeListeningSettings alloc] initWithPropertyList:plist].bands
                           preampDB:[preamp isKindOfClass:[NSNumber class]] ? [preamp doubleValue] : 0];
}

#pragma mark - Coding

+ (BOOL)supportsSecureCoding {
    return YES;
}

- (void)encodeWithCoder:(NSCoder *)coder {
    [coder encodeObject:self.identifier forKey:kIdentifierKey];
    [coder encodeObject:self.name forKey:kNameKey];
    [coder encodeInteger:self.kind forKey:kKindKey];
    [coder encodeObject:self.source forKey:kSourceKey];
    [coder encodeObject:self.bands forKey:kBandsKey];
    [coder encodeDouble:self.preampDB forKey:kPreampKey];
}

- (instancetype)initWithCoder:(NSCoder *)coder {
    NSString *identifier = [coder decodeObjectOfClass:[NSString class] forKey:kIdentifierKey];
    NSString *name = [coder decodeObjectOfClass:[NSString class] forKey:kNameKey];
    NSArray *bands = [coder decodeArrayOfObjectsOfClass:[VibeEQBand class] forKey:kBandsKey];
    if (identifier == nil || name == nil || bands == nil) {
        return nil;
    }
    return [self initWithIdentifier:identifier
                               name:name
                               kind:[coder decodeIntegerForKey:kKindKey]
                             source:[coder decodeObjectOfClass:[NSString class] forKey:kSourceKey]
                              bands:bands
                           preampDB:[coder decodeDoubleForKey:kPreampKey]];
}

@end
