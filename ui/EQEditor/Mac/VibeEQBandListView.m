//
//  VibeEQBandListView.m
//  vibe-libs
//
//  A row per band, every field edited by typing, with add and remove. A
//  field's commit is one edit.
//

#import "VibeEQEditorParts.h"

#import "DrawnControls.h"
#import "VibeEQEditorFormat.h"
#import "VibeEQEditorMath.h"

static NSUserInterfaceItemIdentifier const kOnColumn = @"on";
static NSUserInterfaceItemIdentifier const kTypeColumn = @"type";
static NSUserInterfaceItemIdentifier const kFrequencyColumn = @"frequency";
static NSUserInterfaceItemIdentifier const kGainColumn = @"gain";
static NSUserInterfaceItemIdentifier const kQColumn = @"q";
static const CGFloat kButtonSize = 22;

// A number field, centered in its row as the pop-up's title is.
@interface VibeEQFieldCell : NSTableCellView
@end

@implementation VibeEQFieldCell

- (void)layout {
    [super layout];
    CGFloat height = self.textField.intrinsicContentSize.height;
    self.textField.frame = NSMakeRect(2, round((NSHeight(self.bounds) - height) / 2), MAX(0, NSWidth(self.bounds) - 6),
                                      height);
}

@end

// The band's number, as its node shows it, and its on switch. The switch is
// drawn, since a checkbox is hosted in SwiftUI on macOS 26.
@interface VibeEQSwitchCell : NSTableCellView
@property (nonatomic, readonly) VibeSwitch *toggle;
@end

@implementation VibeEQSwitchCell

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        NSTextField *number = [NSTextField labelWithString:@""];
        number.font = [NSFont monospacedDigitSystemFontOfSize:NSFont.smallSystemFontSize weight:NSFontWeightRegular];
        number.textColor = NSColor.secondaryLabelColor;
        number.alignment = NSTextAlignmentRight;
        self.textField = number;
        [self addSubview:number];
        _toggle = [[VibeSwitch alloc] initWithFrame:NSZeroRect];
        [self addSubview:_toggle];
    }
    return self;
}

- (void)layout {
    [super layout];
    NSRect bounds = self.bounds;
    CGFloat labelHeight = self.textField.intrinsicContentSize.height;
    self.textField.frame = NSMakeRect(0, round((NSHeight(bounds) - labelHeight) / 2), 16, labelHeight);
    NSSize size = _toggle.intrinsicContentSize;
    _toggle.frame = NSMakeRect(22, round((NSHeight(bounds) - size.height) / 2), size.width, size.height);
}

@end

@interface VibeEQBandListView () <NSTableViewDataSource, NSTableViewDelegate>
@end

@implementation VibeEQBandListView {
    NSScrollView *_scrollView;
    BOOL _needsReload;
    BOOL _settingSelection;
}

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _bands = @[];
        _selectedIndex = NSNotFound;
        _enabled = YES;
        _locale = NSLocale.currentLocale;
        _strings = [[VibeEQEditorStrings alloc] init];

        _tableView = [[NSTableView alloc] initWithFrame:NSZeroRect];
        _tableView.style = NSTableViewStyleInset;
        _tableView.rowHeight = 22;
        _tableView.usesAlternatingRowBackgroundColors = YES;
        _tableView.allowsEmptySelection = YES;
        _tableView.allowsMultipleSelection = NO;
        _tableView.columnAutoresizingStyle = NSTableViewUniformColumnAutoresizingStyle;
        _tableView.dataSource = self;
        _tableView.delegate = self;
        for (NSArray *column in @[
                 @[kOnColumn, @70], @[kTypeColumn, @112], @[kFrequencyColumn, @80], @[kGainColumn, @70], @[kQColumn, @56]
             ]) {
            NSTableColumn *tableColumn = [[NSTableColumn alloc] initWithIdentifier:column[0]];
            tableColumn.width = [column[1] doubleValue];
            tableColumn.minWidth = [column[0] isEqual:kOnColumn] ? 70 : 44;
            tableColumn.resizingMask = [column[0] isEqual:kOnColumn] ? NSTableColumnNoResizing
                                                                     : NSTableColumnAutoresizingMask;
            BOOL numeric = [@[kFrequencyColumn, kGainColumn, kQColumn] containsObject:column[0]];
            tableColumn.headerCell.alignment = numeric ? NSTextAlignmentRight : NSTextAlignmentLeft;
            [_tableView addTableColumn:tableColumn];
        }

        _scrollView = [[NSScrollView alloc] initWithFrame:NSZeroRect];
        _scrollView.documentView = _tableView;
        _scrollView.hasVerticalScroller = YES;
        _scrollView.autohidesScrollers = YES;
        _scrollView.borderType = NSNoBorder;
        _scrollView.drawsBackground = NO;
        [self addSubview:_scrollView];

        _addButton = [self squareButtonWithSymbol:@"plus" action:@selector(addBand:)];
        _removeButton = [self squareButtonWithSymbol:@"minus" action:@selector(removeBand:)];
        [self applyStrings];
        [self updateButtons];
    }
    return self;
}

- (NSButton *)squareButtonWithSymbol:(NSString *)symbol action:(SEL)action {
    NSImage *image = [NSImage imageWithSystemSymbolName:symbol accessibilityDescription:nil];
    NSButton *button = [NSButton buttonWithImage:image target:self action:action];
    button.bezelStyle = NSBezelStyleSmallSquare;
    button.bordered = YES;
    [self addSubview:button];
    return button;
}

- (BOOL)isFlipped {
    return YES;
}

- (void)layout {
    [super layout];
    NSRect bounds = self.bounds;
    CGFloat listHeight = MAX(0, NSHeight(bounds) - kButtonSize - 6);
    _scrollView.frame = NSMakeRect(0, 0, NSWidth(bounds), listHeight);
    _addButton.frame = NSMakeRect(0, listHeight + 6, kButtonSize + 4, kButtonSize);
    _removeButton.frame = NSMakeRect(kButtonSize + 4 - 1, listHeight + 6, kButtonSize + 4, kButtonSize);
    [_tableView sizeLastColumnToFit];
}

#pragma mark - Values

- (BOOL)isShown {
    return self.window != nil && !self.isHiddenOrHasHiddenAncestor;
}

- (void)setBands:(NSArray<VibeEQBand *> *)bands {
    NSArray<VibeEQBand *> *old = _bands;
    _bands = [bands copy];
    if (_selectedIndex != NSNotFound && _selectedIndex >= _bands.count) {
        _selectedIndex = NSNotFound;
    }
    if (!self.isShown) {
        _needsReload = YES;
        return;
    }
    if (_needsReload || old.count != _bands.count) {
        [self reload];
        return;
    }
    NSMutableIndexSet *changed = [NSMutableIndexSet indexSet];
    for (NSUInteger i = 0; i < _bands.count; i++) {
        if (![old[i] isEqual:_bands[i]]) {
            [changed addIndex:i];
        }
    }
    if (changed.count > 0) {
        [_tableView reloadDataForRowIndexes:changed
                              columnIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, _tableView.numberOfColumns)]];
    }
}

- (void)reload {
    _needsReload = NO;
    [_tableView reloadData];
    [self applySelection];
    [self updateButtons];
}

- (void)reloadIfNeeded {
    if (_needsReload && self.isShown) {
        [self reload];
    }
}

- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    [self reloadIfNeeded];
}

- (void)viewDidUnhide {
    [super viewDidUnhide];
    [self reloadIfNeeded];
}

- (void)setSelectedIndex:(NSUInteger)selectedIndex {
    _selectedIndex = selectedIndex < _bands.count ? selectedIndex : NSNotFound;
    if (self.isShown && !_needsReload) {
        [self applySelection];
    }
    [self updateButtons];
}

- (void)applySelection {
    _settingSelection = YES;
    if (_selectedIndex == NSNotFound) {
        [_tableView deselectAll:nil];
    } else {
        [_tableView selectRowIndexes:[NSIndexSet indexSetWithIndex:_selectedIndex] byExtendingSelection:NO];
        [_tableView scrollRowToVisible:(NSInteger)_selectedIndex];
    }
    _settingSelection = NO;
}

- (void)setEnabled:(BOOL)enabled {
    _enabled = enabled;
    _tableView.enabled = enabled;
    _needsReload = YES;
    [self reloadIfNeeded];
    [self updateButtons];
}

- (void)setLocale:(NSLocale *)locale {
    _locale = [locale copy];
    _needsReload = YES;
    [self reloadIfNeeded];
}

- (void)setStrings:(VibeEQEditorStrings *)strings {
    _strings = [strings copy];
    [self applyStrings];
    _needsReload = YES;
    [self reloadIfNeeded];
}

- (void)applyStrings {
    NSDictionary<NSString *, NSString *> *titles = @{
        kOnColumn: _strings.onColumn,
        kTypeColumn: _strings.typeColumn,
        kFrequencyColumn: _strings.frequencyColumn,
        kGainColumn: _strings.gainColumn,
        kQColumn: _strings.qColumn,
    };
    for (NSTableColumn *column in _tableView.tableColumns) {
        column.title = titles[column.identifier];
    }
    _addButton.toolTip = _strings.addBand;
    _addButton.accessibilityLabel = _strings.addBand;
    _removeButton.toolTip = _strings.removeBand;
    _removeButton.accessibilityLabel = _strings.removeBand;
}

- (void)updateButtons {
    _addButton.enabled = _enabled && _bands.count < kVibeListeningMaxBands;
    _removeButton.enabled = _enabled && _selectedIndex != NSNotFound;
}

#pragma mark - Table

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    return (NSInteger)_bands.count;
}

- (NSString *)nameOfRow:(NSInteger)row column:(NSString *)column {
    return [NSString stringWithFormat:@"%@, %@", VibeEQBandName(_strings, (NSUInteger)row), column];
}

- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row {
    VibeEQBand *band = _bands[(NSUInteger)row];
    NSString *identifier = tableColumn.identifier;
    if ([identifier isEqual:kOnColumn]) {
        VibeEQSwitchCell *cell = [tableView makeViewWithIdentifier:identifier owner:self];
        if (!cell) {
            cell = [[VibeEQSwitchCell alloc] initWithFrame:NSZeroRect];
            cell.identifier = identifier;
            cell.toggle.target = self;
            cell.toggle.action = @selector(toggleBand:);
        }
        cell.textField.stringValue = [NSString stringWithFormat:@"%ld", (long)row + 1];
        cell.toggle.state = band.enabled ? NSControlStateValueOn : NSControlStateValueOff;
        cell.toggle.enabled = _enabled;
        cell.toggle.accessibilityLabel = VibeEQBandName(_strings, (NSUInteger)row);
        return cell;
    }
    if ([identifier isEqual:kTypeColumn]) {
        NSPopUpButton *popUp = [tableView makeViewWithIdentifier:identifier owner:self];
        if (!popUp) {
            popUp = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
            popUp.identifier = identifier;
            popUp.controlSize = NSControlSizeSmall;
            popUp.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
            popUp.bordered = NO;
            popUp.target = self;
            popUp.action = @selector(changeType:);
        }
        // A drag reloads its row on every move, so the menu is built only
        // when it's new or the words changed.
        if (![popUp.itemTitles isEqualToArray:_strings.bandTypes]) {
            [popUp removeAllItems];
            [popUp addItemsWithTitles:_strings.bandTypes];
        }
        [popUp selectItemAtIndex:band.type];
        popUp.enabled = _enabled;
        popUp.accessibilityLabel = [self nameOfRow:row column:_strings.typeColumn];
        return popUp;
    }
    VibeEQFieldCell *cell = [tableView makeViewWithIdentifier:identifier owner:self];
    if (!cell) {
        cell = [[VibeEQFieldCell alloc] initWithFrame:NSZeroRect];
        cell.identifier = identifier;
        NSTextField *field = [NSTextField textFieldWithString:@""];
        cell.textField = field;
        [cell addSubview:field];
        field.controlSize = NSControlSizeSmall;
        field.font = [NSFont monospacedDigitSystemFontOfSize:NSFont.smallSystemFontSize weight:NSFontWeightRegular];
        field.bordered = NO;
        field.drawsBackground = NO;
        field.alignment = NSTextAlignmentRight;
        field.target = self;
        field.action = @selector(commitField:);
        field.cell.sendsActionOnEndEditing = YES;
        field.cell.scrollable = YES;
    }
    NSTextField *field = cell.textField;
    field.enabled = _enabled;
    field.editable = _enabled;
    field.placeholderString = nil;
    if ([identifier isEqual:kFrequencyColumn]) {
        field.stringValue = VibeEQFormatFieldNumber(band.frequency, 0, 0, _locale);
        field.accessibilityLabel = [self nameOfRow:row column:_strings.frequencyColumn];
    } else if ([identifier isEqual:kGainColumn]) {
        BOOL hasGain = VibeEQBandHasGain(band.type);
        field.stringValue = hasGain ? VibeEQFormatFieldNumber(band.gainDB, 1, 1, _locale) : @"";
        field.placeholderString = hasGain ? nil : @"—";
        field.enabled = _enabled && hasGain;
        field.editable = field.enabled;
        field.accessibilityLabel = [self nameOfRow:row column:_strings.gainColumn];
    } else {
        field.stringValue = VibeEQFormatFieldNumber(band.q, 0, 2, _locale);
        field.accessibilityLabel = [self nameOfRow:row column:_strings.qColumn];
    }
    return cell;
}

- (void)tableViewSelectionDidChange:(NSNotification *)notification {
    if (_settingSelection) {
        return;
    }
    NSInteger row = _tableView.selectedRow;
    _selectedIndex = row >= 0 ? (NSUInteger)row : NSNotFound;
    [self updateButtons];
    [self.owner face:self didSelectBandAtIndex:_selectedIndex];
}

#pragma mark - Edits

- (NSUInteger)rowOfSender:(NSView *)sender {
    NSInteger row = [_tableView rowForView:sender];
    return row >= 0 && (NSUInteger)row < _bands.count ? (NSUInteger)row : NSNotFound;
}

// One finished edit: the new bands, then the end.
- (void)commitBands:(NSArray<VibeEQBand *> *)bands {
    self.bands = bands;
    [self.owner face:self didChangeBands:_bands];
    [self.owner faceDidEndEditing:self];
}

- (void)replaceBandAtIndex:(NSUInteger)index with:(VibeEQBand *)band {
    if ([band isEqual:_bands[index]]) {
        [_tableView reloadDataForRowIndexes:[NSIndexSet indexSetWithIndex:index]
                              columnIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, _tableView.numberOfColumns)]];
        return;
    }
    NSMutableArray<VibeEQBand *> *bands = [_bands mutableCopy];
    bands[index] = band;
    [self commitBands:bands];
}

- (void)toggleBand:(VibeSwitch *)sender {
    NSUInteger index = [self rowOfSender:sender];
    if (index == NSNotFound || !_enabled) {
        return;
    }
    [self replaceBandAtIndex:index with:[_bands[index] bandWithEnabled:sender.state == NSControlStateValueOn]];
}

- (void)changeType:(NSPopUpButton *)sender {
    NSUInteger index = [self rowOfSender:sender];
    if (index == NSNotFound || !_enabled) {
        return;
    }
    VibeEQBand *band = _bands[index];
    VibeEQBandType type = (VibeEQBandType)MAX(VibeEQBandTypePeak, MIN(sender.indexOfSelectedItem, VibeEQBandTypeHighPass));
    [self replaceBandAtIndex:index with:VibeEQBandChanged(band, type, band.frequency, band.gainDB, band.q)];
}

- (void)commitField:(NSTextField *)sender {
    NSUInteger index = [self rowOfSender:sender];
    if (index == NSNotFound || !_enabled) {
        return;
    }
    VibeEQBand *band = _bands[index];
    double value = 0;
    if (!VibeEQParseNumber(sender.stringValue, _locale, &value)) {
        [self replaceBandAtIndex:index with:band];
        return;
    }
    double frequency = band.frequency, gain = band.gainDB, q = band.q;
    NSUserInterfaceItemIdentifier column = _tableView.tableColumns[(NSUInteger)[_tableView columnForView:sender]].identifier;
    if ([column isEqual:kFrequencyColumn]) {
        frequency = VibeEQClamp(round(value), kVibeEQMinFrequency, kVibeEQMaxFrequency);
    } else if ([column isEqual:kGainColumn]) {
        gain = VibeEQSnapGain(value, kVibeEQParametricStepDB, kVibeEQMaxGainDB);
    } else {
        q = VibeEQClamp(round(value * 100) / 100, kVibeEQMinQ, kVibeEQMaxQ);
    }
    [self replaceBandAtIndex:index with:VibeEQBandChanged(band, band.type, frequency, gain, q)];
}

// The bands, then the selection, then the end, so the host's undo record
// sees the editor settled.
- (void)commitBands:(NSArray<VibeEQBand *> *)bands selecting:(NSUInteger)index {
    _selectedIndex = NSNotFound;
    self.bands = bands;
    [self.owner face:self didChangeBands:_bands];
    self.selectedIndex = index;
    [self.owner face:self didSelectBandAtIndex:_selectedIndex];
    [self.owner faceDidEndEditing:self];
}

// A new peak at 0 dB, where VibeEQFrequencyForNewBand puts it.
- (void)addBand:(id)sender {
    if (_bands.count >= kVibeListeningMaxBands) {
        return;
    }
    double frequencies[kVibeListeningMaxBands];
    for (NSUInteger i = 0; i < _bands.count; i++) {
        frequencies[i] = _bands[i].frequency;
    }
    VibeEQBand *band = [VibeEQBand bandWithType:VibeEQBandTypePeak
                                      frequency:VibeEQRoundFrequency(VibeEQFrequencyForNewBand(frequencies, _bands.count))
                                         gainDB:0
                                              q:1];
    [self commitBands:[_bands arrayByAddingObject:band] selecting:_bands.count];
}

- (void)removeBand:(id)sender {
    if (_selectedIndex == NSNotFound) {
        return;
    }
    NSMutableArray<VibeEQBand *> *bands = [_bands mutableCopy];
    [bands removeObjectAtIndex:_selectedIndex];
    [self commitBands:bands selecting:VibeEQSelectionAfterRemoving(_selectedIndex, bands.count)];
}

@end
