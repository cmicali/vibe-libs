//
//  AudioError.m
//  vibe-libs
//
//  In a file of their own, so a test can link the error vocabulary without
//  compiling the player.
//

#import "AudioError.h"

NSString *const kVibeAudioErrorTrackURLKey = @"VibeAudioErrorTrackURL";
NSString *const kVibeAudioErrorTrackKey = @"VibeAudioErrorTrack";
NSString *const kVibeAudioErrorRequestIdentifierKey = @"VibeAudioErrorRequestIdentifier";
NSString *const kVibeAudioErrorPrecedingRequestIdentifierKey = @"VibeAudioErrorPrecedingRequestIdentifier";
NSString *const kVibeAudioErrorKindKey = @"VibeAudioErrorKind";

static NSString *sDomain;

void VibeAudioErrorSetDomain(NSString *domain) {
    sDomain = [domain copy];
}

NSString *VibeAudioErrorDomain(void) {
    NSString *domain = sDomain;
    NSCAssert(domain, @"VibeAudioErrorSetDomain was not called before the first play-path error");
    return domain ?: @"VibeAudioErrorDomain";
}

static VibeAudioErrorKind VibeAudioErrorKindOfCode(VibeAudioErrorCode code) {
    switch (code) {
        case VibeAudioErrorFileOpenFailed:
        case VibeAudioErrorFileOpenTimedOut:
        case VibeAudioErrorConnectionLost:
            return VibeAudioErrorKindTrack;
        case VibeAudioErrorNotPlaying:
            return VibeAudioErrorKindNotPlaying;
        case VibeAudioErrorEngineStartFailed:
        case VibeAudioErrorDeviceUnavailable:
        case VibeAudioErrorDeviceInUse:
            return VibeAudioErrorKindOutput;
    }
    return VibeAudioErrorKindUnknown;
}

VibeAudioErrorKind VibeAudioErrorKindOf(NSError *error) {
    id kind = error.userInfo[kVibeAudioErrorKindKey];
    return [kind isKindOfClass:NSNumber.class] ? (VibeAudioErrorKind)[kind integerValue] : VibeAudioErrorKindUnknown;
}

NSError *VibeAudioErrorOfKind(VibeAudioErrorKind kind, VibeAudioErrorCode code, NSString *description,
                              NSError *underlying, NSURL *trackURL) {
    NSMutableDictionary *info = [NSMutableDictionary new];
    if (underlying) {
        info[NSUnderlyingErrorKey] = underlying;
        if (underlying.localizedDescription.length) {
            description = [NSString stringWithFormat:@"%@ (%@)", description, underlying.localizedDescription];
        }
    }
    info[NSLocalizedDescriptionKey] = description;
    info[kVibeAudioErrorKindKey] = @(kind);
    if (trackURL) {
        info[kVibeAudioErrorTrackURLKey] = trackURL;
    }
    return [NSError errorWithDomain:VibeAudioErrorDomain() code:code userInfo:info];
}

// Descriptions are for logs and are never localized. An app chooses the
// line it shows from the error code, with its own rule.
NSError *VibeAudioError(VibeAudioErrorCode code, NSString *description, NSError *underlying) {
    return VibeAudioErrorOfKind(VibeAudioErrorKindOfCode(code), code, description, underlying, nil);
}

NSError *VibeAudioErrorForTrack(VibeAudioErrorCode code, NSString *description, NSError *underlying, NSURL *trackURL) {
    return VibeAudioErrorOfKind(VibeAudioErrorKindOfCode(code), code, description, underlying, trackURL);
}
