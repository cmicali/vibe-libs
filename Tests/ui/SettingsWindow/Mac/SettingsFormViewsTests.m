//
//  SettingsFormViewsTests.m
//  SettingsWindowTests
//
//  The form views alone, with no window server: titles, enablement, captions,
//  the color-pair row's blocks, and the fill's appearance.
//

#import <XCTest/XCTest.h>
#import "DrawnViewTestSupport.h"
#import "DrawnControls.h"
#import "SettingsFormViews.h"
#import "SettingsPaneViewController.h"

@interface SettingsFormViewsTests : XCTestCase
@end

@implementation SettingsFormViewsTests

- (void)testRowTitleDropsATrailingColon {
    NSView *control = [[VibeSwitch alloc] init];
    XCTAssertEqualObjects([SettingsRowView rowWithTitle:@"Volume:" control:control].titleLabel.stringValue,
                          @"Volume");
    XCTAssertEqualObjects([SettingsRowView rowWithTitle:@"Volume :" control:control].titleLabel.stringValue,
                          @"Volume");
    XCTAssertEqualObjects([SettingsRowView rowWithTitle:@"音量：" control:control].titleLabel.stringValue,
                          @"音量");
    SettingsRowView *row = [SettingsRowView rowWithTitle:@"Volume" control:control];
    [row setRowTitle:@"Gain:"];
    XCTAssertEqualObjects(row.titleLabel.stringValue, @"Gain");
}

- (void)testSectionHeaderDropsATrailingColon {
    SettingsRowView *row = [SettingsRowView rowWithTitle:@"Volume" control:[[VibeSwitch alloc] init]];
    SettingsSectionView *section = [SettingsSectionView sectionWithHeader:@"Output:" rows:@[row]];
    XCTAssertEqualObjects(section.headerLabel.stringValue, @"Output");
    [section setHeader:@"Input:"];
    XCTAssertEqualObjects(section.headerLabel.stringValue, @"Input");
    XCTAssertEqual([SettingsSectionView sectionContaining:row.titleLabel], section);
    XCTAssertNil([SettingsSectionView sectionContaining:section]);
}

- (void)testAnUntitledRowHasNoTitle {
    SettingsRowView *row = [SettingsRowView rowWithTitle:nil control:[[VibeSwitch alloc] init]];
    XCTAssertNil(row.titleLabel);
    XCTAssertFalse([row setCaption:@"Ignored"]);
}

- (void)testDisablingEveryControlDimsTheRow {
    VibeSwitch *toggle = [[VibeSwitch alloc] init];
    SettingsRowView *row = [SettingsRowView rowWithTitle:@"Volume" caption:@"How loud" control:toggle];
    XCTAssertEqual(row.titleLabel.alphaValue, 1);

    [SettingsRowView setControl:toggle enabled:NO];
    XCTAssertFalse(toggle.enabled);
    XCTAssertEqual(toggle.alphaValue, 0.5);
    XCTAssertEqual(row.titleLabel.alphaValue, 0.5);
    XCTAssertEqual(row.captionLabel.alphaValue, 0.5);

    [SettingsRowView setControlsInView:row enabled:YES];
    XCTAssertTrue(toggle.enabled);
    XCTAssertEqual(toggle.alphaValue, 1);
    XCTAssertEqual(row.titleLabel.alphaValue, 1);
}

- (void)testOneEnabledControlKeepsTheRowLit {
    VibeSwitch *first = [[VibeSwitch alloc] init];
    VibeSwitch *second = [[VibeSwitch alloc] init];
    SettingsRowView *row = [SettingsRowView rowWithTitle:@"Both" controls:@[first, second]];
    [SettingsRowView setControl:first enabled:NO];
    XCTAssertEqual(first.alphaValue, 0.5);
    XCTAssertEqual(row.titleLabel.alphaValue, 1);
}

- (void)testAControlOutsideARowDimsItself {
    VibeSwitch *toggle = [[VibeSwitch alloc] init];
    [SettingsRowView setControl:toggle enabled:NO];
    XCTAssertEqual(toggle.alphaValue, 0.5);
}

- (void)testCaptionAnswersWhenItComesOrGoes {
    SettingsRowView *row = [SettingsRowView rowWithTitle:@"Volume" control:[[VibeSwitch alloc] init]];
    XCTAssertNil(row.captionLabel);
    XCTAssertTrue([row setCaption:@"How loud"]);
    XCTAssertFalse(row.captionLabel.hidden);
    XCTAssertFalse([row setCaption:@"How loud"]);
    XCTAssertTrue([row setCaption:nil]);
    XCTAssertTrue(row.captionLabel.hidden);
    XCTAssertFalse([row setCaption:@""]);
    XCTAssertTrue([row setCaption:@"How loud" detail:@"Muted"]);
    XCTAssertEqualObjects(row.captionLabel.stringValue, @"How loud\nMuted");
}

- (void)testColorRowRefreshesSeedsAndWritesThroughItsBlocks {
    NSMutableArray<NSColor *> *model = [@[NSColor.redColor, NSColor.blueColor] mutableCopy];
    NSMutableArray<NSNumber *> *written = [NSMutableArray array];
    NSMutableArray<NSNumber *> *changes = [NSMutableArray array];
    SettingsColorRow *row = [SettingsColorRow rowWithCaptions:@[@"Dark", @"Light"]
            supportsAlpha:NO
                     read:^NSColor *(NSUInteger index) {
                         return model[index];
                     }
                    write:^(NSUInteger index, NSColor *color) {
                        [written addObject:@(index)];
                        model[index] = color;
                    }
                  changed:^(BOOL continuous) {
                      [changes addObject:@(continuous)];
                  }];
    XCTAssertEqual(row.wells.count, 2u);

    [row refresh];
    XCTAssertTrue(VibeColorsClose(row.wells[0].color, NSColor.redColor, 0.01));
    XCTAssertTrue(VibeColorsClose(row.wells[1].color, NSColor.blueColor, 0.01));
    XCTAssertEqualObjects(written, @[]);

    [row seed];
    XCTAssertEqualObjects(written, (@[@0, @1]));
    XCTAssertEqualObjects(changes, @[]);

    NSColorWell *light = row.wells[1];
    light.color = NSColor.greenColor;
    // NSApp is nil here, so the well's action is sent by hand.
    id target = light.target;
    ((void (*)(id, SEL, id))[target methodForSelector:light.action])(target, light.action, light);
    XCTAssertTrue(VibeColorsClose(model[1], NSColor.greenColor, 0.01));
    XCTAssertEqualObjects(changes, @[@YES]);
}

#pragma mark - Captions and indents

static NSString *const kLongCaption = @"A caption long enough to run well past any card of the design width, "
        @"so it must wrap under its title rather than push the controls and the pane out with it.";

// A section holding the row, laid out at width with no window.
- (SettingsSectionView *)sectionWithRow:(SettingsRowView *)row width:(CGFloat)width
                             constraint:(NSLayoutConstraint *__strong *)outWidth {
    SettingsSectionView *section = [SettingsSectionView sectionWithRows:@[row]];
    NSLayoutConstraint *constraint = [section.widthAnchor constraintEqualToConstant:width];
    constraint.active = YES;
    if (outWidth) *outWidth = constraint;
    [section layoutSubtreeIfNeeded];
    return section;
}

- (CGFloat)minXOf:(NSView *)view inRow:(SettingsRowView *)row {
    return NSMinX([view.superview convertRect:view.frame toView:row]);
}

// The room a row leaves its caption: from the title's leading edge to the
// gap before the control.
- (CGFloat)captionRoomOf:(SettingsRowView *)row before:(NSView *)control {
    return [self minXOf:control inRow:row] - 8 - NSMinX([self placed:row.titleLabel]);
}

// The room in a card of the design width, before the row lays out.
- (CGFloat)designRoomBefore:(NSView *)control indent:(NSInteger)level {
    return kSettingsPaneWidth - 2 * kPanePadding - 2 * kSettingsRowInset - level * kSettingsRowIndent - 8
            - control.fittingSize.width;
}

- (CGFloat)oneLineHeightOf:(NSTextField *)label {
    return [label.cell cellSizeForBounds:NSMakeRect(0, 0, 10000, 10000)].height;
}

// Where Auto Layout places a label: its alignment rect, two points inside
// its frame.
- (NSRect)placed:(NSTextField *)label {
    return [label alignmentRectForFrame:label.frame];
}

// The default: a caption keeps one line, and its row is as wide as it.
- (void)testACaptionKeepsOneLineUnlessToldToWrap {
    SettingsRowView *plain = [SettingsRowView rowWithTitle:@"Volume" control:[[VibeSwitch alloc] init]];
    SettingsRowView *captioned = [SettingsRowView rowWithTitle:@"Volume" caption:kLongCaption
                                                       control:[[VibeSwitch alloc] init]];
    XCTAssertFalse(captioned.wrapsCaption);
    XCTAssertEqual(captioned.captionLabel.preferredMaxLayoutWidth, 0);
    CGFloat oneLine = captioned.captionLabel.intrinsicContentSize.width;
    XCTAssertGreaterThan(captioned.fittingSize.width, plain.fittingSize.width + 400);
    XCTAssertGreaterThanOrEqual(captioned.fittingSize.width, oneLine);

    // Wrapping turns on and off again on a caption that is already there.
    captioned.wrapsCaption = YES;
    XCTAssertEqualWithAccuracy(captioned.fittingSize.width, plain.fittingSize.width, 0.5);
    captioned.wrapsCaption = NO;
    XCTAssertEqual(captioned.captionLabel.preferredMaxLayoutWidth, 0);
    XCTAssertGreaterThanOrEqual(captioned.fittingSize.width, oneLine);
}

- (void)testAWrappingCaptionNeverWidensItsRow {
    SettingsRowView *plain = [SettingsRowView rowWithTitle:@"Volume" control:[[VibeSwitch alloc] init]];
    SettingsRowView *captioned = [SettingsRowView rowWithTitle:@"Volume" caption:kLongCaption
                                                       control:[[VibeSwitch alloc] init]];
    captioned.wrapsCaption = YES;
    // Set before the caption exists, it holds for the caption that comes.
    plain.wrapsCaption = YES;
    XCTAssertEqualWithAccuracy(captioned.fittingSize.width, plain.fittingSize.width, 0.5);
    [plain setCaption:kLongCaption];
    XCTAssertEqualWithAccuracy(plain.fittingSize.width, captioned.fittingSize.width, 0.5);
    [plain setCaption:@"What it does" detail:kLongCaption];
    XCTAssertEqualWithAccuracy(plain.fittingSize.width, captioned.fittingSize.width, 0.5);
}

// Before its row lays out, a caption wraps at the room a card of the design
// width leaves it.
- (void)testACaptionFirstWrapsAtTheDesignWidth {
    VibeSwitch *toggle = [[VibeSwitch alloc] init];
    SettingsRowView *row = [SettingsRowView rowWithTitle:@"Volume" caption:kLongCaption control:toggle];
    row.wrapsCaption = YES;
    XCTAssertEqualWithAccuracy(row.captionLabel.preferredMaxLayoutWidth,
                               [self designRoomBefore:toggle indent:0], 0.5);
}

- (void)testACaptionWrapsInTheRoomItsRowGivesIt {
    VibeSwitch *toggle = [[VibeSwitch alloc] init];
    SettingsRowView *row = [SettingsRowView rowWithTitle:@"Volume" caption:kLongCaption control:toggle];
    row.wrapsCaption = YES;
    NSLayoutConstraint *width = nil;
    SettingsSectionView *section = [self sectionWithRow:row width:440 constraint:&width];
    NSTextField *caption = row.captionLabel;
    CGFloat room = [self captionRoomOf:row before:toggle];
    XCTAssertEqualWithAccuracy(NSWidth(row.frame), 440, 0.5);
    XCTAssertEqualWithAccuracy(caption.preferredMaxLayoutWidth, room, 0.5);
    XCTAssertLessThanOrEqual(NSMaxX([self placed:caption]), [self minXOf:toggle inRow:row] - 8 + 0.5);
    CGFloat oneLine = [self oneLineHeightOf:caption];
    CGFloat wrapped = NSHeight(caption.frame);
    XCTAssertGreaterThan(wrapped, oneLine * 1.5);
    XCTAssertGreaterThanOrEqual(NSHeight(row.frame), wrapped + NSHeight(row.titleLabel.frame));

    // A wider card gives the caption more room, and fewer lines.
    width.constant = 900;
    [section layoutSubtreeIfNeeded];
    XCTAssertEqualWithAccuracy(caption.preferredMaxLayoutWidth,
                               [self captionRoomOf:row before:toggle], 0.5);
    XCTAssertGreaterThan(caption.preferredMaxLayoutWidth, room + 400);
    XCTAssertLessThan(NSHeight(caption.frame), wrapped);
}

- (void)testACaptionSetLaterWrapsTheSame {
    VibeSwitch *toggle = [[VibeSwitch alloc] init];
    SettingsRowView *row = [SettingsRowView rowWithTitle:@"Volume" control:toggle];
    row.wrapsCaption = YES;
    SettingsSectionView *section = [self sectionWithRow:row width:440 constraint:NULL];
    CGFloat bare = NSHeight(row.frame);
    XCTAssertTrue([row setCaption:kLongCaption]);
    [section layoutSubtreeIfNeeded];
    XCTAssertEqualWithAccuracy(NSWidth(row.frame), 440, 0.5);
    XCTAssertEqualWithAccuracy(row.captionLabel.preferredMaxLayoutWidth,
                               [self captionRoomOf:row before:toggle], 0.5);
    XCTAssertGreaterThan(NSHeight(row.frame), bare + 20);

    // A caption of the same line count leaves the height alone; a short one
    // gives lines back.
    XCTAssertFalse([row setCaption:[kLongCaption stringByReplacingOccurrencesOfString:@"wrap" withString:@"fold"]]);
    XCTAssertTrue([row setCaption:@"Short"]);
}

- (void)testAShortCaptionKeepsOneLine {
    SettingsRowView *row = [SettingsRowView rowWithTitle:@"Volume" caption:@"How loud"
                                                 control:[[VibeSwitch alloc] init]];
    [self sectionWithRow:row width:440 constraint:NULL];
    NSTextField *caption = row.captionLabel;
    CGFloat oneLine = [self oneLineHeightOf:caption];
    XCTAssertEqualWithAccuracy(NSHeight(caption.frame), oneLine, 0.5);
}

- (void)testAnIndentMovesTheTitleAndItsCaption {
    SettingsRowView *row = [SettingsRowView rowWithTitle:@"Volume" caption:@"How loud"
                                                 control:[[VibeSwitch alloc] init]];
    SettingsSectionView *section = [self sectionWithRow:row width:440 constraint:NULL];
    XCTAssertEqual(row.indentLevel, 0);
    CGFloat flush = NSMinX([self placed:row.titleLabel]);
    XCTAssertEqualWithAccuracy(NSMinX([self placed:row.captionLabel]), flush, 0.5);

    row.indentLevel = 1;
    [section layoutSubtreeIfNeeded];
    XCTAssertEqualWithAccuracy(NSMinX([self placed:row.titleLabel]), flush + kSettingsRowIndent, 0.5);
    XCTAssertEqualWithAccuracy(NSMinX([self placed:row.captionLabel]), flush + kSettingsRowIndent, 0.5);

    row.indentLevel = 2;
    [section layoutSubtreeIfNeeded];
    XCTAssertEqualWithAccuracy(NSMinX([self placed:row.titleLabel]), flush + 2 * kSettingsRowIndent, 0.5);

    row.indentLevel = -3;
    XCTAssertEqual(row.indentLevel, 0);
    [section layoutSubtreeIfNeeded];
    XCTAssertEqualWithAccuracy(NSMinX([self placed:row.titleLabel]), flush, 0.5);
}

// The caption made after the indent sits under the title once, not twice.
- (void)testACaptionSetAfterAnIndentSitsUnderTheTitle {
    VibeSwitch *toggle = [[VibeSwitch alloc] init];
    SettingsRowView *row = [SettingsRowView rowWithTitle:@"Volume" control:toggle];
    row.wrapsCaption = YES;
    row.indentLevel = 1;
    [row setCaption:kLongCaption];
    XCTAssertEqualWithAccuracy(row.captionLabel.preferredMaxLayoutWidth,
                               [self designRoomBefore:toggle indent:1], 0.5);
    [self sectionWithRow:row width:440 constraint:NULL];
    XCTAssertEqualWithAccuracy(NSMinX([self placed:row.titleLabel]), NSMinX([self placed:row.captionLabel]), 0.5);
    XCTAssertEqualWithAccuracy(row.captionLabel.preferredMaxLayoutWidth,
                               [self captionRoomOf:row before:toggle], 0.5);
    XCTAssertLessThanOrEqual(NSMaxX([self placed:row.captionLabel]), [self minXOf:toggle inRow:row] - 8 + 0.5);
}

- (void)testAnIndentLeavesAnUntitledRowAlone {
    SettingsRowView *row = [SettingsRowView rowWithTitle:nil control:[[VibeSwitch alloc] init]];
    row.indentLevel = 1;
    XCTAssertEqual(row.indentLevel, 1);
    XCTAssertNil(row.titleLabel);
}

- (void)testFillFollowsTheAppearance {
    SettingsFillView *fill = [[SettingsFillView alloc] initWithFrame:NSMakeRect(0, 0, 20, 20)];
    fill.translatesAutoresizingMaskIntoConstraints = YES;
    fill.lightColor = NSColor.whiteColor;
    fill.darkColor = NSColor.blackColor;
    NSWindow *window = VibeOffscreenWindow(NSMakeSize(20, 20));
    [window.contentView addSubview:fill];

    window.appearance = [NSAppearance appearanceNamed:NSAppearanceNameAqua];
    [fill displayIfNeeded];
    XCTAssertTrue(VibeColorsClose(VibePixel(VibeRenderLayer(fill.layer), NO, 10, 10), NSColor.whiteColor, 0.01));

    window.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
    [fill displayIfNeeded];
    XCTAssertTrue(VibeColorsClose(VibePixel(VibeRenderLayer(fill.layer), NO, 10, 10), NSColor.blackColor, 0.01));
}

@end
