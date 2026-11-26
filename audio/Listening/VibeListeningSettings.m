//
//  VibeListeningSettings.m
//  vibe-libs
//

#import "VibeListeningSettings.h"
#import "VibeListeningBiquad.h"

static double VibeHold(double value, double low, double high, double fallback) {
    if (!isfinite(value)) {
        return fallback;
    }
    return fmin(fmax(value, low), high);
}

static VibeEQBandType VibeHoldType(NSInteger type) {
    return (type >= VibeEQBandTypePeak && type <= VibeEQBandTypeHighPass) ? (VibeEQBandType)type
                                                                           : VibeEQBandTypePeak;
}

static BOOL VibeBandTypeIsPass(VibeEQBandType type) {
    return type == VibeEQBandTypeLowPass || type == VibeEQBandTypeHighPass;
}

// The plist names stay fixed, since an app keeps them in its defaults.
static NSString *const kTypeNames[] = {@"peak", @"lowShelf", @"highShelf", @"lowPass", @"highPass"};
static NSString *const kCrossfeedNames[] = {@"off", @"light", @"medium", @"strong"};

#define VibeCount(array) ((NSInteger)(sizeof(array) / sizeof(*(array))))

static NSInteger VibeIndexOfName(id name, NSString *const *names, NSInteger count) {
    if (![name isKindOfClass:[NSString class]]) {
        return -1;
    }
    for (NSInteger i = 0; i < count; i++) {
        if ([names[i] isEqualToString:name]) {
            return i;
        }
    }
    return -1;
}

static double VibeNumber(NSDictionary *plist, NSString *key, double fallback) {
    id value = plist[key];
    return [value isKindOfClass:[NSNumber class]] ? [value doubleValue] : fallback;
}

static BOOL VibeBool(NSDictionary *plist, NSString *key, BOOL fallback) {
    id value = plist[key];
    return [value isKindOfClass:[NSNumber class]] ? [value boolValue] : fallback;
}

static NSUInteger VibeHashDouble(double value) {
    return (NSUInteger)[@(value) hash];
}

static const double kGraphicQ = 1.41;
static const double kGraphicFrequencies[] = {31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000};
static const NSUInteger kGraphicBandCount = VibeCount(kGraphicFrequencies);

#pragma mark - VibeEQBand

@implementation VibeEQBand

+ (BOOL)supportsSecureCoding {
    return YES;
}

+ (instancetype)bandWithType:(VibeEQBandType)type frequency:(double)frequency gainDB:(double)gainDB q:(double)q {
    return [[self alloc] initWithType:type frequency:frequency gainDB:gainDB q:q enabled:YES];
}

- (instancetype)initWithType:(VibeEQBandType)type
                   frequency:(double)frequency
                      gainDB:(double)gainDB
                           q:(double)q
                     enabled:(BOOL)enabled {
    self = [super init];
    _type = VibeHoldType(type);
    _frequency = VibeHold(frequency, 20, 20000, 1000);
    _gainDB = VibeHold(gainDB, -24, 24, 0);
    _q = VibeHold(q, 0.1, 10, 0.707);
    _enabled = enabled;
    return self;
}

- (instancetype)bandWithEnabled:(BOOL)enabled {
    return [[[self class] alloc] initWithType:_type frequency:_frequency gainDB:_gainDB q:_q enabled:enabled];
}

- (instancetype)bandWithGainDB:(double)gainDB {
    return [[[self class] alloc] initWithType:_type frequency:_frequency gainDB:gainDB q:_q enabled:_enabled];
}

- (BOOL)isNeutral {
    return !_enabled || (!VibeBandTypeIsPass(_type) && _gainDB == 0);
}

- (id)copyWithZone:(NSZone *)zone {
    return self;
}

- (void)encodeWithCoder:(NSCoder *)coder {
    [coder encodeInteger:_type forKey:@"type"];
    [coder encodeDouble:_frequency forKey:@"frequency"];
    [coder encodeDouble:_gainDB forKey:@"gainDB"];
    [coder encodeDouble:_q forKey:@"q"];
    [coder encodeBool:_enabled forKey:@"enabled"];
}

- (nullable instancetype)initWithCoder:(NSCoder *)coder {
    return [self initWithType:[coder decodeIntegerForKey:@"type"]
                    frequency:[coder containsValueForKey:@"frequency"] ? [coder decodeDoubleForKey:@"frequency"] : NAN
                       gainDB:[coder decodeDoubleForKey:@"gainDB"]
                            q:[coder containsValueForKey:@"q"] ? [coder decodeDoubleForKey:@"q"] : NAN
                      enabled:[coder containsValueForKey:@"enabled"] ? [coder decodeBoolForKey:@"enabled"] : YES];
}

- (NSDictionary *)propertyList {
    return @{
        @"type": kTypeNames[_type],
        @"frequency": @(_frequency),
        @"gainDB": @(_gainDB),
        @"q": @(_q),
        @"enabled": @(_enabled),
    };
}

+ (nullable VibeEQBand *)bandWithPropertyList:(id)plist {
    if (![plist isKindOfClass:[NSDictionary class]]) {
        return nil;
    }
    NSInteger type = VibeIndexOfName(plist[@"type"], kTypeNames, VibeCount(kTypeNames));
    if (type < 0) {
        return nil;
    }
    return [[VibeEQBand alloc] initWithType:type
                                  frequency:VibeNumber(plist, @"frequency", NAN)
                                     gainDB:VibeNumber(plist, @"gainDB", 0)
                                          q:VibeNumber(plist, @"q", NAN)
                                    enabled:VibeBool(plist, @"enabled", YES)];
}

- (BOOL)isEqual:(id)object {
    if (object == self) {
        return YES;
    }
    if (![object isKindOfClass:[VibeEQBand class]]) {
        return NO;
    }
    VibeEQBand *other = object;
    return other->_type == _type && other->_frequency == _frequency && other->_gainDB == _gainDB &&
           other->_q == _q && other->_enabled == _enabled;
}

- (NSUInteger)hash {
    return (NSUInteger)_type ^ (VibeHashDouble(_frequency) * 31) ^ (VibeHashDouble(_gainDB) * 131) ^
           (VibeHashDouble(_q) * 1031) ^ (NSUInteger)_enabled << 7;
}

- (NSString *)description {
    return [NSString stringWithFormat:@"<VibeEQBand %@ %.1f Hz %+.1f dB Q %.2f%@>", kTypeNames[_type], _frequency,
                                      _gainDB, _q, _enabled ? @"" : @" off"];
}

@end

#pragma mark - VibeListeningSettings

@implementation VibeListeningSettings {
  @protected
    BOOL _eqEnabled;
    NSArray<VibeEQBand *> *_bands;
    BOOL _preampAutomatic;
    double _preampDB;
    VibeCrossfeed _crossfeed;
    BOOL _mono;
    BOOL _swapChannels;
    double _balance;
}

@synthesize eqEnabled = _eqEnabled, bands = _bands, preampAutomatic = _preampAutomatic, preampDB = _preampDB,
            crossfeed = _crossfeed, mono = _mono, swapChannels = _swapChannels, balance = _balance;

+ (BOOL)supportsSecureCoding {
    return YES;
}

+ (instancetype)neutralSettings {
    return [[self alloc] init];
}

- (instancetype)init {
    self = [super init];
    _bands = @[];
    _preampAutomatic = YES;
    return self;
}

static NSArray<VibeEQBand *> *VibeHoldBands(NSArray *bands) {
    NSMutableArray<VibeEQBand *> *held = [NSMutableArray array];
    for (id band in bands) {
        if ([band isKindOfClass:[VibeEQBand class]] && held.count < kVibeListeningMaxBands) {
            [held addObject:band];
        }
    }
    return [held copy];
}

static VibeCrossfeed VibeHoldCrossfeed(NSInteger crossfeed) {
    return (crossfeed >= VibeCrossfeedOff && crossfeed <= VibeCrossfeedStrong) ? (VibeCrossfeed)crossfeed
                                                                               : VibeCrossfeedOff;
}

static double VibeHoldPreamp(double preampDB) {
    return VibeHold(preampDB, kVibeListeningPreampMinDB, kVibeListeningPreampMaxDB, 0);
}

static double VibeHoldBalance(double balance) {
    return VibeHold(balance, -1, 1, 0);
}

- (instancetype)initWithSettings:(VibeListeningSettings *)other {
    self = [super init];
    _eqEnabled = other->_eqEnabled;
    _bands = other->_bands;
    _preampAutomatic = other->_preampAutomatic;
    _preampDB = other->_preampDB;
    _crossfeed = other->_crossfeed;
    _mono = other->_mono;
    _swapChannels = other->_swapChannels;
    _balance = other->_balance;
    return self;
}

- (BOOL)eqChangesSamples {
    if (!_eqEnabled) {
        return NO;
    }
    for (VibeEQBand *band in _bands) {
        if (!band.neutral) {
            return YES;
        }
    }
    // Every band is neutral, so the automatic preamp is 0.
    return !_preampAutomatic && _preampDB != 0;
}

- (BOOL)isNeutral {
    return ![self eqChangesSamples] && _crossfeed == VibeCrossfeedOff && !_mono && !_swapChannels && _balance == 0;
}

- (double)effectivePreampDB {
    if (!_eqEnabled) {
        return 0;
    }
    return _preampAutomatic ? VibeListeningAutomaticPreampDB(_bands) : _preampDB;
}

#pragma mark Copying

- (id)copyWithZone:(NSZone *)zone {
    if ([self isMemberOfClass:[VibeListeningSettings class]]) {
        return self;
    }
    return [[VibeListeningSettings alloc] initWithSettings:self];
}

- (id)mutableCopyWithZone:(NSZone *)zone {
    return [[VibeMutableListeningSettings alloc] initWithSettings:self];
}

#pragma mark Coding

- (void)encodeWithCoder:(NSCoder *)coder {
    [coder encodeBool:_eqEnabled forKey:@"eqEnabled"];
    [coder encodeObject:_bands forKey:@"bands"];
    [coder encodeBool:_preampAutomatic forKey:@"preampAutomatic"];
    [coder encodeDouble:_preampDB forKey:@"preampDB"];
    [coder encodeInteger:_crossfeed forKey:@"crossfeed"];
    [coder encodeBool:_mono forKey:@"mono"];
    [coder encodeBool:_swapChannels forKey:@"swapChannels"];
    [coder encodeDouble:_balance forKey:@"balance"];
}

- (nullable instancetype)initWithCoder:(NSCoder *)coder {
    self = [self init];
    _eqEnabled = [coder decodeBoolForKey:@"eqEnabled"];
    _bands = VibeHoldBands([coder decodeArrayOfObjectsOfClass:[VibeEQBand class] forKey:@"bands"]);
    _preampAutomatic =
        [coder containsValueForKey:@"preampAutomatic"] ? [coder decodeBoolForKey:@"preampAutomatic"] : YES;
    _preampDB = VibeHoldPreamp([coder decodeDoubleForKey:@"preampDB"]);
    _crossfeed = VibeHoldCrossfeed([coder decodeIntegerForKey:@"crossfeed"]);
    _mono = [coder decodeBoolForKey:@"mono"];
    _swapChannels = [coder decodeBoolForKey:@"swapChannels"];
    _balance = VibeHoldBalance([coder decodeDoubleForKey:@"balance"]);
    return self;
}

#pragma mark Property lists

- (NSDictionary<NSString *, id> *)propertyList {
    NSMutableArray *bands = [NSMutableArray arrayWithCapacity:_bands.count];
    for (VibeEQBand *band in _bands) {
        [bands addObject:[band propertyList]];
    }
    return @{
        @"eqEnabled": @(_eqEnabled),
        @"bands": bands,
        @"preampAutomatic": @(_preampAutomatic),
        @"preampDB": @(_preampDB),
        @"crossfeed": kCrossfeedNames[_crossfeed],
        @"mono": @(_mono),
        @"swapChannels": @(_swapChannels),
        @"balance": @(_balance),
    };
}

- (instancetype)initWithPropertyList:(nullable id)propertyList {
    self = [self init];
    if (![propertyList isKindOfClass:[NSDictionary class]]) {
        return self;
    }
    NSDictionary *plist = propertyList;
    _eqEnabled = VibeBool(plist, @"eqEnabled", NO);
    NSMutableArray *bands = [NSMutableArray array];
    id bandList = plist[@"bands"];
    if ([bandList isKindOfClass:[NSArray class]]) {
        for (id entry in bandList) {
            VibeEQBand *band = [VibeEQBand bandWithPropertyList:entry];
            if (band) {
                [bands addObject:band];
            }
        }
    }
    _bands = VibeHoldBands(bands);
    _preampAutomatic = VibeBool(plist, @"preampAutomatic", YES);
    _preampDB = VibeHoldPreamp(VibeNumber(plist, @"preampDB", 0));
    NSInteger crossfeed = VibeIndexOfName(plist[@"crossfeed"], kCrossfeedNames, VibeCount(kCrossfeedNames));
    _crossfeed = crossfeed < 0 ? VibeCrossfeedOff : (VibeCrossfeed)crossfeed;
    _mono = VibeBool(plist, @"mono", NO);
    _swapChannels = VibeBool(plist, @"swapChannels", NO);
    _balance = VibeHoldBalance(VibeNumber(plist, @"balance", 0));
    return self;
}

#pragma mark The graphic face

+ (NSArray<NSNumber *> *)graphicFrequencies {
    NSMutableArray<NSNumber *> *frequencies = [NSMutableArray arrayWithCapacity:kGraphicBandCount];
    for (NSUInteger i = 0; i < kGraphicBandCount; i++) {
        [frequencies addObject:@(kGraphicFrequencies[i])];
    }
    return [frequencies copy];
}

+ (NSArray<VibeEQBand *> *)graphicBandsWithGains:(NSArray<NSNumber *> *)gains {
    NSMutableArray<VibeEQBand *> *bands = [NSMutableArray arrayWithCapacity:kGraphicBandCount];
    for (NSUInteger i = 0; i < kGraphicBandCount; i++) {
        id gain = i < gains.count ? gains[i] : nil;
        double dB = [gain isKindOfClass:[NSNumber class]] ? [gain doubleValue] : 0;
        [bands addObject:[VibeEQBand bandWithType:VibeEQBandTypePeak
                                        frequency:kGraphicFrequencies[i]
                                           gainDB:dB
                                                q:kGraphicQ]];
    }
    return [bands copy];
}

- (BOOL)isGraphic {
    if (_bands.count != kGraphicBandCount) {
        return NO;
    }
    for (NSUInteger i = 0; i < kGraphicBandCount; i++) {
        VibeEQBand *band = _bands[i];
        if (band.type != VibeEQBandTypePeak || !band.enabled || band.q != kGraphicQ ||
            band.frequency != kGraphicFrequencies[i]) {
            return NO;
        }
    }
    return YES;
}

#pragma mark Equality

- (BOOL)isEqual:(id)object {
    if (object == self) {
        return YES;
    }
    if (![object isKindOfClass:[VibeListeningSettings class]]) {
        return NO;
    }
    VibeListeningSettings *other = object;
    return other->_eqEnabled == _eqEnabled && [other->_bands isEqualToArray:_bands] &&
           other->_preampAutomatic == _preampAutomatic && other->_preampDB == _preampDB &&
           other->_crossfeed == _crossfeed && other->_mono == _mono && other->_swapChannels == _swapChannels &&
           other->_balance == _balance;
}

- (NSUInteger)hash {
    return _bands.hash ^ _bands.firstObject.hash ^ ((NSUInteger)_eqEnabled << 1) ^ ((NSUInteger)_preampAutomatic << 2) ^
           ((NSUInteger)_mono << 3) ^ ((NSUInteger)_swapChannels << 4) ^ ((NSUInteger)_crossfeed << 5) ^
           (VibeHashDouble(_preampDB) * 31) ^ (VibeHashDouble(_balance) * 131);
}

- (NSString *)description {
    return [NSString stringWithFormat:@"<%@ eq %@ %lu bands, preamp %@ %.1f dB, crossfeed %@, mono %d, swap %d, "
                                      @"balance %.2f>",
                                      [self class], _eqEnabled ? @"on" : @"off", (unsigned long)_bands.count,
                                      _preampAutomatic ? @"auto" : @"manual", _preampDB, kCrossfeedNames[_crossfeed],
                                      _mono, _swapChannels, _balance];
}

@end

#pragma mark - VibeMutableListeningSettings

@implementation VibeMutableListeningSettings

@dynamic eqEnabled, bands, preampAutomatic, preampDB, crossfeed, mono, swapChannels, balance;

- (void)setEqEnabled:(BOOL)eqEnabled {
    _eqEnabled = eqEnabled;
}

- (void)setBands:(NSArray<VibeEQBand *> *)bands {
    _bands = VibeHoldBands(bands);
}

- (void)setPreampAutomatic:(BOOL)preampAutomatic {
    _preampAutomatic = preampAutomatic;
}

- (void)setPreampDB:(double)preampDB {
    _preampDB = VibeHoldPreamp(preampDB);
}

- (void)setCrossfeed:(VibeCrossfeed)crossfeed {
    _crossfeed = VibeHoldCrossfeed(crossfeed);
}

- (void)setMono:(BOOL)mono {
    _mono = mono;
}

- (void)setSwapChannels:(BOOL)swapChannels {
    _swapChannels = swapChannels;
}

- (void)setBalance:(double)balance {
    _balance = VibeHoldBalance(balance);
}

@end

#pragma mark - The response

typedef struct {
    NSUInteger count;
    VibeListeningBiquad filters[kVibeListeningMaxBands];
} VibeFilterSet;

static VibeFilterSet VibeFilterSetMake(NSArray<VibeEQBand *> *bands, double sampleRate) {
    VibeFilterSet set = {0};
    for (VibeEQBand *band in bands) {
        if (band.enabled && set.count < kVibeListeningMaxBands) {
            set.filters[set.count++] =
                VibeListeningBiquadMake(band.type, band.frequency, band.gainDB, band.q, sampleRate);
        }
    }
    return set;
}

static double VibeFilterSetResponseDB(const VibeFilterSet *set, double frequency, double sampleRate) {
    double dB = 0;
    for (NSUInteger i = 0; i < set->count; i++) {
        dB += VibeListeningBiquadResponseDB(set->filters[i], frequency, sampleRate);
    }
    return dB;
}

double VibeListeningResponseDB(NSArray<VibeEQBand *> *bands, double frequency, double sampleRate) {
    VibeFilterSet set = VibeFilterSetMake(bands, sampleRate);
    return VibeFilterSetResponseDB(&set, frequency, sampleRate);
}

double VibeListeningAutomaticPreampDB(NSArray<VibeEQBand *> *bands) {
    static const double kRate = 48000;
    static const int kPoints = 1024;
    BOOL boosts = NO;
    for (VibeEQBand *band in bands) {
        boosts = boosts || !band.neutral;
    }
    if (!boosts) {
        return 0;
    }
    VibeFilterSet set = VibeFilterSetMake(bands, kRate);
    // A log grid, then a golden-section search beside the best point, so a
    // narrow peak between two points still counts.
    double low = log(20.0), high = log(20000.0), step = (high - low) / (kPoints - 1);
    double best = -INFINITY;
    int bestIndex = 0;
    for (int i = 0; i < kPoints; i++) {
        double dB = VibeFilterSetResponseDB(&set, exp(low + step * i), kRate);
        if (dB > best) {
            best = dB;
            bestIndex = i;
        }
    }
    const double ratio = 0.6180339887498949;
    double a = fmax(low, low + step * (bestIndex - 1)), b = fmin(high, low + step * (bestIndex + 1));
    double c = b - ratio * (b - a), d = a + ratio * (b - a);
    double fc = VibeFilterSetResponseDB(&set, exp(c), kRate), fd = VibeFilterSetResponseDB(&set, exp(d), kRate);
    for (int i = 0; i < 30; i++) {
        if (fc > fd) {
            b = d;
            d = c;
            fd = fc;
            c = b - ratio * (b - a);
            fc = VibeFilterSetResponseDB(&set, exp(c), kRate);
        } else {
            a = c;
            c = d;
            fc = fd;
            d = a + ratio * (b - a);
            fd = VibeFilterSetResponseDB(&set, exp(d), kRate);
        }
        best = fmax(best, fmax(fc, fd));
    }
    return best > 0 ? -best : 0;
}
