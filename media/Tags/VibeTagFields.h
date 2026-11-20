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

FOUNDATION_EXTERN VibeTagField const VibeTagFieldTitle;            // TITLE
FOUNDATION_EXTERN VibeTagField const VibeTagFieldArtist;           // ARTIST
FOUNDATION_EXTERN VibeTagField const VibeTagFieldAlbum;            // ALBUM
FOUNDATION_EXTERN VibeTagField const VibeTagFieldAlbumArtist;      // ALBUMARTIST
// The release date, "2001" or "2001-02-03".
FOUNDATION_EXTERN VibeTagField const VibeTagFieldDate;             // DATE
// TRAP: ID3v2 and MP4 hold the number and the total in one frame, "3/12".
// The writer folds a total into it, and VibeTagLibReadFields splits it out.
FOUNDATION_EXTERN VibeTagField const VibeTagFieldTrackNumber;      // TRACKNUMBER
FOUNDATION_EXTERN VibeTagField const VibeTagFieldTrackTotal;       // TRACKTOTAL
FOUNDATION_EXTERN VibeTagField const VibeTagFieldDiscNumber;       // DISCNUMBER
FOUNDATION_EXTERN VibeTagField const VibeTagFieldDiscTotal;        // DISCTOTAL
// "1" for a compilation.
FOUNDATION_EXTERN VibeTagField const VibeTagFieldCompilation;      // COMPILATION
FOUNDATION_EXTERN VibeTagField const VibeTagFieldGenre;            // GENRE
FOUNDATION_EXTERN VibeTagField const VibeTagFieldGrouping;         // GROUPING
// The comment with no description. ID3v2's described comments, such as
// iTunNORM, are other keys ("COMMENT:iTunNORM").
FOUNDATION_EXTERN VibeTagField const VibeTagFieldComment;          // COMMENT
FOUNDATION_EXTERN VibeTagField const VibeTagFieldComposer;         // COMPOSER
// MP4 holds a whole number.
FOUNDATION_EXTERN VibeTagField const VibeTagFieldBPM;              // BPM
FOUNDATION_EXTERN VibeTagField const VibeTagFieldInitialKey;       // INITIALKEY
FOUNDATION_EXTERN VibeTagField const VibeTagFieldLabel;            // LABEL
FOUNDATION_EXTERN VibeTagField const VibeTagFieldCatalogNumber;    // CATALOGNUMBER
FOUNDATION_EXTERN VibeTagField const VibeTagFieldISRC;             // ISRC
FOUNDATION_EXTERN VibeTagField const VibeTagFieldConductor;        // CONDUCTOR
FOUNDATION_EXTERN VibeTagField const VibeTagFieldRemixer;          // REMIXER
FOUNDATION_EXTERN VibeTagField const VibeTagFieldLyricist;         // LYRICIST
FOUNDATION_EXTERN VibeTagField const VibeTagFieldMood;             // MOOD
FOUNDATION_EXTERN VibeTagField const VibeTagFieldLanguage;         // LANGUAGE
FOUNDATION_EXTERN VibeTagField const VibeTagFieldCopyright;        // COPYRIGHT
// ID3v2.3 holds the original year alone.
FOUNDATION_EXTERN VibeTagField const VibeTagFieldOriginalDate;     // ORIGINALDATE
FOUNDATION_EXTERN VibeTagField const VibeTagFieldTitleSort;        // TITLESORT
FOUNDATION_EXTERN VibeTagField const VibeTagFieldArtistSort;       // ARTISTSORT
FOUNDATION_EXTERN VibeTagField const VibeTagFieldAlbumSort;        // ALBUMSORT
FOUNDATION_EXTERN VibeTagField const VibeTagFieldAlbumArtistSort;  // ALBUMARTISTSORT

// Every field above, in that order.
FOUNDATION_EXTERN NSArray<VibeTagField> *VibeTagFieldsEdited(void);

// A rating, as each tag holds one (media/Tags/AGENTS.md, Ratings). The writer
// takes these, and VibeTagLibReadFields answers them, but they are not in
// VibeTagFieldsEdited(): a rating's scale is the app's to choose, and this
// piece reads and writes the values as they are stored, as text.
// A Xiph comment's RATING, an MP4's rate atom, an ID3v2 TXXX:RATING, and an
// APE item, each as stored.
FOUNDATION_EXTERN VibeTagField const VibeTagFieldRating;           // RATING
// FMPS's rating, 0.0 to 1.0: ID3v2's TXXX:FMPS_Rating, a Xiph comment's
// FMPS_RATING, and MP4's ----:com.apple.iTunes:FMPS_Rating.
FOUNDATION_EXTERN VibeTagField const VibeTagFieldFMPSRating;       // FMPS_RATING
// ID3v2's POPM frame of one email, "POPM:" and the email as stored, its
// case kept: its rating byte, 1 to 255, as text. Only ID3v2 holds it.
FOUNDATION_EXTERN NSString *const VibeTagFieldPopularimeterPrefix; // POPM:
// A Xiph comment's rating of one email, "RATING:" and the email, which a
// Xiph comment holds upper case.
FOUNDATION_EXTERN NSString *const VibeTagFieldRatingPrefix;        // RATING:

// Whether the name is one of the rating fields above.
FOUNDATION_EXTERN BOOL VibeTagFieldIsRating(NSString *name);
// The key a read answers for a field's name: upper case, except a POPM
// field's email, which keeps its case.
FOUNDATION_EXTERN NSString *VibeTagFieldKey(NSString *name);

NS_ASSUME_NONNULL_END
