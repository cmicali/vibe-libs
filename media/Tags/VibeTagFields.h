//
//  VibeTagFields.h
//  vibe-libs
//
//  The tag fields an app edits, by TagLib's property-map name. TagLib turns
//  each format's frame, atom, or comment into one of these keys, and its keys
//  ignore case. Plain Objective-C, so Swift, a .m, and media/Metadata share
//  them. media/Tags/AGENTS.md lists what each format writes for each.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NSString *VibeTagField NS_TYPED_EXTENSIBLE_ENUM;

extern VibeTagField const VibeTagFieldTitle;            // TITLE
extern VibeTagField const VibeTagFieldArtist;           // ARTIST
extern VibeTagField const VibeTagFieldAlbum;            // ALBUM
extern VibeTagField const VibeTagFieldAlbumArtist;      // ALBUMARTIST
// The release date, "2001" or "2001-02-03".
extern VibeTagField const VibeTagFieldDate;             // DATE
// TRAP: ID3v2 and MP4 hold the number and the total in one frame, "3/12".
// The writer folds a total into it, and VibeTagLibReadFields splits it out.
extern VibeTagField const VibeTagFieldTrackNumber;      // TRACKNUMBER
extern VibeTagField const VibeTagFieldTrackTotal;       // TRACKTOTAL
extern VibeTagField const VibeTagFieldDiscNumber;       // DISCNUMBER
extern VibeTagField const VibeTagFieldDiscTotal;        // DISCTOTAL
// "1" for a compilation.
extern VibeTagField const VibeTagFieldCompilation;      // COMPILATION
extern VibeTagField const VibeTagFieldGenre;            // GENRE
extern VibeTagField const VibeTagFieldGrouping;         // GROUPING
// The comment with no description. ID3v2's described comments, such as
// iTunNORM, are other keys ("COMMENT:iTunNORM").
extern VibeTagField const VibeTagFieldComment;          // COMMENT
extern VibeTagField const VibeTagFieldComposer;         // COMPOSER
// MP4 holds a whole number.
extern VibeTagField const VibeTagFieldBPM;              // BPM
extern VibeTagField const VibeTagFieldInitialKey;       // INITIALKEY
extern VibeTagField const VibeTagFieldLabel;            // LABEL
extern VibeTagField const VibeTagFieldCatalogNumber;    // CATALOGNUMBER
extern VibeTagField const VibeTagFieldISRC;             // ISRC
extern VibeTagField const VibeTagFieldConductor;        // CONDUCTOR
extern VibeTagField const VibeTagFieldRemixer;          // REMIXER
extern VibeTagField const VibeTagFieldLyricist;         // LYRICIST
extern VibeTagField const VibeTagFieldMood;             // MOOD
extern VibeTagField const VibeTagFieldLanguage;         // LANGUAGE
extern VibeTagField const VibeTagFieldCopyright;        // COPYRIGHT
// ID3v2.3 holds the original year alone.
extern VibeTagField const VibeTagFieldOriginalDate;     // ORIGINALDATE
extern VibeTagField const VibeTagFieldTitleSort;        // TITLESORT
extern VibeTagField const VibeTagFieldArtistSort;       // ARTISTSORT
extern VibeTagField const VibeTagFieldAlbumSort;        // ALBUMSORT
extern VibeTagField const VibeTagFieldAlbumArtistSort;  // ALBUMARTISTSORT

// Every field above, in that order.
NSArray<VibeTagField> *VibeTagFieldsEdited(void);

NS_ASSUME_NONNULL_END
