//
//  VibeTagFields.m
//  vibe-libs
//

#import "VibeTagFields.h"

VibeTagField const VibeTagFieldTitle = @"TITLE";
VibeTagField const VibeTagFieldArtist = @"ARTIST";
VibeTagField const VibeTagFieldAlbum = @"ALBUM";
VibeTagField const VibeTagFieldAlbumArtist = @"ALBUMARTIST";
VibeTagField const VibeTagFieldDate = @"DATE";
VibeTagField const VibeTagFieldTrackNumber = @"TRACKNUMBER";
VibeTagField const VibeTagFieldTrackTotal = @"TRACKTOTAL";
VibeTagField const VibeTagFieldDiscNumber = @"DISCNUMBER";
VibeTagField const VibeTagFieldDiscTotal = @"DISCTOTAL";
VibeTagField const VibeTagFieldCompilation = @"COMPILATION";
VibeTagField const VibeTagFieldGenre = @"GENRE";
VibeTagField const VibeTagFieldGrouping = @"GROUPING";
VibeTagField const VibeTagFieldComment = @"COMMENT";
VibeTagField const VibeTagFieldComposer = @"COMPOSER";
VibeTagField const VibeTagFieldBPM = @"BPM";
VibeTagField const VibeTagFieldInitialKey = @"INITIALKEY";
VibeTagField const VibeTagFieldLabel = @"LABEL";
VibeTagField const VibeTagFieldCatalogNumber = @"CATALOGNUMBER";
VibeTagField const VibeTagFieldISRC = @"ISRC";
VibeTagField const VibeTagFieldConductor = @"CONDUCTOR";
VibeTagField const VibeTagFieldRemixer = @"REMIXER";
VibeTagField const VibeTagFieldLyricist = @"LYRICIST";
VibeTagField const VibeTagFieldMood = @"MOOD";
VibeTagField const VibeTagFieldLanguage = @"LANGUAGE";
VibeTagField const VibeTagFieldCopyright = @"COPYRIGHT";
VibeTagField const VibeTagFieldOriginalDate = @"ORIGINALDATE";
VibeTagField const VibeTagFieldTitleSort = @"TITLESORT";
VibeTagField const VibeTagFieldArtistSort = @"ARTISTSORT";
VibeTagField const VibeTagFieldAlbumSort = @"ALBUMSORT";
VibeTagField const VibeTagFieldAlbumArtistSort = @"ALBUMARTISTSORT";

NSArray<VibeTagField> *VibeTagFieldsEdited(void) {
    return @[
        VibeTagFieldTitle, VibeTagFieldArtist, VibeTagFieldAlbum, VibeTagFieldAlbumArtist, VibeTagFieldDate,
        VibeTagFieldTrackNumber, VibeTagFieldTrackTotal, VibeTagFieldDiscNumber, VibeTagFieldDiscTotal,
        VibeTagFieldCompilation, VibeTagFieldGenre, VibeTagFieldGrouping, VibeTagFieldComment,
        VibeTagFieldComposer, VibeTagFieldBPM, VibeTagFieldInitialKey, VibeTagFieldLabel,
        VibeTagFieldCatalogNumber, VibeTagFieldISRC, VibeTagFieldConductor, VibeTagFieldRemixer,
        VibeTagFieldLyricist, VibeTagFieldMood, VibeTagFieldLanguage, VibeTagFieldCopyright,
        VibeTagFieldOriginalDate, VibeTagFieldTitleSort, VibeTagFieldArtistSort, VibeTagFieldAlbumSort,
        VibeTagFieldAlbumArtistSort,
    ];
}
