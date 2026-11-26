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
