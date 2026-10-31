//
//  VibePlaylistEntry.m
//  vibe-libs
//

#import "VibePlaylistEntry.h"

@implementation VibePlaylistEntry

+ (instancetype)entryWithURL:(NSURL *)url {
    return [[self alloc] initWithURL:url cueStart:0 cueEnd:0 title:nil performer:nil sheet:nil trackNumber:0];
}

- (instancetype)initWithURL:(NSURL *)url cueStart:(NSUInteger)start cueEnd:(NSUInteger)end
                      title:(NSString *)title performer:(NSString *)performer
                      sheet:(NSURL *)sheet trackNumber:(NSInteger)trackNumber {
    return [self initWithURL:url cueStart:start cueEnd:end title:title performer:performer sheet:sheet
                 trackNumber:trackNumber duration:-1 displayTitle:nil displayArtist:nil];
}

- (instancetype)initWithURL:(NSURL *)url cueStart:(NSUInteger)start cueEnd:(NSUInteger)end
                      title:(NSString *)title performer:(NSString *)performer
                      sheet:(NSURL *)sheet trackNumber:(NSInteger)trackNumber
                   duration:(NSTimeInterval)duration displayTitle:(NSString *)displayTitle
              displayArtist:(NSString *)displayArtist {
    self = [super init];
    if (self) {
        _url = [url copy];
        _cueStart = start;
        _cueEnd = end;
        _cueTitle = [title copy];
        _cuePerformer = [performer copy];
        _cueSheetURL = [sheet copy];
        _cueTrackNumber = trackNumber;
        _duration = duration;
        _displayTitle = [displayTitle copy];
        _displayArtist = [displayArtist copy];
    }
    return self;
}

- (instancetype)entryBesideUnreadCueSheet:(NSURL *)sheet {
    VibePlaylistEntry *entry = [[VibePlaylistEntry alloc] initWithURL:_url cueStart:_cueStart cueEnd:_cueEnd
                                                                title:_cueTitle performer:_cuePerformer
                                                                sheet:_cueSheetURL trackNumber:_cueTrackNumber
                                                             duration:_duration displayTitle:_displayTitle
                                                        displayArtist:_displayArtist];
    entry->_unreadCueSheetURL = [sheet copy];
    return entry;
}

- (BOOL)isWindowed {
    return _cueStart > 0 || _cueEnd > 0;
}

@end
