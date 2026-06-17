/*
 * SmartHighlight.mm - Native macOS Notepad++ plugin
 *
 * Floating highlight-panel with persistent keyword list.
 * Storage : ~/.notepad++/plugins/Config/SmartHighlight_highlights.json  (auto)
 * Export  : any path with .cch extension                              (manual)
 *
 * Panel features
 *   Add          - add selected text / word under cursor as new entry
 *   Delete       - remove selected entry from list and document
 *   New          - clear all entries and document indicators
 *   Select All   - enable every checkbox -> apply to document
 *   Unselect All - disable every checkbox -> remove from document
 *   Refresh      - re-apply all enabled entries to current document
 *   Search Next  - go to next match (of selected row, or all)
 *   Search Prev  - go to previous match
 *   Open         - load .cch / .json keyword list
 *   Save         - export current list to .cch file
 */

#include "NppPluginInterfaceMac.h"

// Scintilla message IDs
#define SCI_GETLENGTH               2006
#define SCI_GETCURRENTPOS           2008
#define SCI_GETTEXT                 2182
#define SCI_GETSELECTIONSTART       2143
#define SCI_GETSELECTIONEND         2145
#define SCI_WORDSTARTPOSITION       2266
#define SCI_WORDENDPOSITION         2267
#define SCI_GOTOPOS                 2025
#define SCI_SCROLLCARET             2169
#define SCI_INDICSETSTYLE           2080
#define SCI_INDICSETFORE            2082
#define SCI_INDICSETALPHA           2523
#define SCI_INDICSETOUTLINEALPHA    2526
#define SCI_INDICSETUNDER           2510
#define SCI_SETINDICATORCURRENT     2500
#define SCI_SETINDICATORVALUE       2502
#define SCI_INDICATORFILLRANGE      2504
#define SCI_INDICATORCLEARRANGE     2505
#define INDIC_STRAIGHTBOX           8

#import <Cocoa/Cocoa.h>
#include <algorithm>
#include <atomic>
#include <cstring>
#include <ctime>
#include <memory>
#include <regex>
#include <set>
#include <string>
#include <unordered_map>
#include <utility>
#include <vector>

// Style palette
static const int MAX_STYLES     = 10;
static const int INDICATOR_BASE = 15;

static inline int rgb(int r, int g, int b) { return r | (g << 8) | (b << 16); }

static const int kStyleColor[MAX_STYLES] = {
    rgb(  0,  80, 255),   // 0 Blue
    rgb(  0, 200,  80),   // 1 Green
    rgb(255, 140,   0),   // 2 Orange
    rgb(140, 140, 140),   // 3 Gray
    rgb(200, 200, 200),   // 4 White
    rgb(255, 220,   0),   // 5 Yellow
    rgb(  0, 200, 200),   // 6 Cyan
    rgb(  0, 180, 100),   // 7 Teal
    rgb(220,  50,  50),   // 8 Red
    rgb(220,  50, 220),   // 9 Magenta
};

static const char *kStyleNames[MAX_STYLES] = {
    "Blue","Green","Orange","Gray","White",
    "Yellow","Cyan","Teal","Red","Magenta"
};

static NSColor *styleNSColor(int i) {
    if (i < 0 || i >= MAX_STYLES) i = 0;
    int c = kStyleColor[i];
    return [NSColor colorWithCalibratedRed:((c)       & 0xFF) / 255.0
                                     green:((c >>  8) & 0xFF) / 255.0
                                      blue:((c >> 16) & 0xFF) / 255.0
                                     alpha:1.0];
}

// Highlight entry
struct HighlightEntry {
    std::string pattern;
    int         styleIndex;
    bool        enabled;
    double      ts;
};

// Global state
static NppData g_nppData = {};
static std::string g_configPath;
static std::vector<HighlightEntry>                  gHighlights;
static std::unordered_map<int, std::set<intptr_t>>  gIndicatorStarts;
static std::atomic<int>                             gApplyTicket{0};

// Scintilla helpers
static NppHandle curScintilla() {
    int which = -1;
    g_nppData._sendMessage(g_nppData._nppHandle,
                           NPPM_GETCURRENTSCINTILLA, 0, (intptr_t)&which);
    if (which == -1) return g_nppData._scintillaMainHandle;
    return (which == 0) ? g_nppData._scintillaMainHandle
                        : g_nppData._scintillaSecondHandle;
}

static intptr_t sci(NppHandle h, uint32_t msg,
                    uintptr_t w = 0, intptr_t l = 0) {
    return g_nppData._sendMessage(h, msg, w, l);
}

static void setupIndicators(NppHandle h) {
    for (int i = 0; i < MAX_STYLES; i++) {
        int ind = INDICATOR_BASE + i;
        sci(h, SCI_INDICSETSTYLE,        ind, INDIC_STRAIGHTBOX);
        sci(h, SCI_INDICSETFORE,         ind, kStyleColor[i]);
        sci(h, SCI_INDICSETALPHA,        ind, 70);
        sci(h, SCI_INDICSETOUTLINEALPHA, ind, 200);
        sci(h, SCI_INDICSETUNDER,        ind, 0);
    }
}

static void fillRange(NppHandle h, int ind, intptr_t start, intptr_t len) {
    sci(h, SCI_SETINDICATORCURRENT, ind);
    sci(h, SCI_SETINDICATORVALUE,   1);
    sci(h, SCI_INDICATORFILLRANGE,  start, len);
    gIndicatorStarts[ind].insert(start);
}

static void clearIndicator(NppHandle h, int ind) {
    sci(h, SCI_SETINDICATORCURRENT, ind);
    sci(h, SCI_INDICATORCLEARRANGE, 0, sci(h, SCI_GETLENGTH));
    gIndicatorStarts[ind].clear();
}

static void clearAllIndicators(NppHandle h) {
    for (int i = 0; i < MAX_STYLES; i++)
        clearIndicator(h, INDICATOR_BASE + i);
}

static std::string getDocumentText(NppHandle h) {
    intptr_t len = sci(h, SCI_GETLENGTH);
    if (len <= 0) return {};
    std::string buf(len + 1, '\0');
    sci(h, SCI_GETTEXT, len + 1, (intptr_t)buf.data());
    buf.resize(len);
    return buf;
}

// JSON persistence
static void saveHighlights() {
    @autoreleasepool {
        NSMutableArray *arr = [NSMutableArray arrayWithCapacity:gHighlights.size()];
        for (const auto &e : gHighlights) {
            [arr addObject:@{
                @"pattern":    [NSString stringWithUTF8String:e.pattern.c_str()],
                @"styleIndex": @(e.styleIndex),
                @"enabled":    @(e.enabled),
                @"ts":         @(e.ts),
            }];
        }
        NSDictionary *root = @{@"highlights": arr};
        NSError *err = nil;
        NSData *data = [NSJSONSerialization dataWithJSONObject:root
                                                       options:NSJSONWritingPrettyPrinted
                                                         error:&err];
        if (!err && data) {
            NSString *path = [NSString stringWithUTF8String:g_configPath.c_str()];
            [data writeToFile:path atomically:YES];
        }
    }
}

static void loadHighlights() {
    @autoreleasepool {
        NSString *path = [NSString stringWithUTF8String:g_configPath.c_str()];
        NSData *data = [NSData dataWithContentsOfFile:path];
        if (!data) return;
        NSError *err = nil;
        id root = [NSJSONSerialization JSONObjectWithData:data
                                                  options:0
                                                    error:&err];
        if (err || ![root isKindOfClass:[NSDictionary class]]) return;
        NSArray *arr = ((NSDictionary *)root)[@"highlights"];
        if (![arr isKindOfClass:[NSArray class]]) return;
        gHighlights.clear();
        for (NSDictionary *d in arr) {
            if (![d isKindOfClass:[NSDictionary class]]) continue;
            NSString *pat = d[@"pattern"];
            if (![pat isKindOfClass:[NSString class]]) continue;
            HighlightEntry e;
            e.pattern    = pat.UTF8String;
            e.styleIndex = [d[@"styleIndex"] intValue];
            e.enabled    = [d[@"enabled"] boolValue];
            e.ts         = [d[@"ts"] doubleValue];
            if (!e.pattern.empty())
                gHighlights.push_back(e);
        }
    }
}

static void exportToPath(const std::string &path) {
    std::string saved = g_configPath;
    g_configPath = path;
    saveHighlights();
    g_configPath = saved;
}

static void importFromPath(const std::string &path) {
    std::string saved = g_configPath;
    g_configPath = path;
    loadHighlights();
    g_configPath = saved;
}

static bool isSimpleLiteralPattern(const std::string &pattern) {
    static const std::string regexMeta = "\\.^$|?*+()[]{}";
    return pattern.find_first_of(regexMeta) == std::string::npos;
}

static bool decodeEscapedLiteralPattern(const std::string &pattern,
                                        std::string &outLiteral) {
    outLiteral.clear();
    if (pattern.empty()) return false;

    auto isRegexMeta = [](char c) {
        switch (c) {
            case '\\': case '.': case '^': case '$': case '|':
            case '?': case '*': case '+': case '(': case ')':
            case '[': case ']': case '{': case '}':
                return true;
            default:
                return false;
        }
    };

    auto canBeEscapedLiteralChar = [&](char c) {
        if (isRegexMeta(c)) return true;
        if (c == '-' || c == '#' || c == ',') return true;
        if (c == ' ' || c == '\t' || c == '\n' || c == '\r') return true;
        return false;
    };

    outLiteral.reserve(pattern.size());
    for (size_t i = 0; i < pattern.size(); ++i) {
        char c = pattern[i];
        if (c == '\\') {
            if (i + 1 >= pattern.size()) return false;
            char next = pattern[++i];
            if (!canBeEscapedLiteralChar(next)) return false;
            outLiteral.push_back(next);
            continue;
        }
        if (isRegexMeta(c)) return false;
        outLiteral.push_back(c);
    }
    return !outLiteral.empty();
}

static void collectRangesForPattern(const std::string &doc,
                                    const std::string &pattern,
                                    std::vector<std::pair<intptr_t, intptr_t>> &ranges) {
    if (doc.empty() || pattern.empty()) return;

    if (isSimpleLiteralPattern(pattern)) {
        size_t pos = 0;
        while ((pos = doc.find(pattern, pos)) != std::string::npos) {
            ranges.push_back({(intptr_t)pos, (intptr_t)pattern.size()});
            pos += pattern.size();
        }
        return;
    }

    std::string literal;
    if (decodeEscapedLiteralPattern(pattern, literal)) {
        size_t pos = 0;
        while ((pos = doc.find(literal, pos)) != std::string::npos) {
            ranges.push_back({(intptr_t)pos, (intptr_t)literal.size()});
            pos += literal.size();
        }
        return;
    }

    try {
        std::regex re(pattern, std::regex_constants::ECMAScript |
                               std::regex_constants::optimize);
        auto it  = std::sregex_iterator(doc.begin(), doc.end(), re);
        auto end = std::sregex_iterator();
        for (; it != end; ++it)
            ranges.push_back({(intptr_t)it->position(), (intptr_t)it->length()});
    } catch (...) {}
}

static void applySingleHighlight(int indicator, const std::string &pattern) {
    NppHandle h = curScintilla();
    if (!h || pattern.empty()) return;
    setupIndicators(h);

    std::string doc = getDocumentText(h);
    if (doc.empty()) return;

    std::vector<std::pair<intptr_t, intptr_t>> ranges;
    collectRangesForPattern(doc, pattern, ranges);
    for (const auto &r : ranges)
        fillRange(h, indicator, r.first, r.second);
}

// Async apply all enabled highlights to current doc
static void applyAllHighlights() {
    NppHandle h = curScintilla();
    if (!h) return;
    setupIndicators(h);
    clearAllIndicators(h);

    struct Job { int ind; std::string pattern; };
    auto jobs = std::make_shared<std::vector<Job>>();
    for (const auto &e : gHighlights) {
        if (!e.enabled) continue;
        jobs->push_back({INDICATOR_BASE + e.styleIndex, e.pattern});
    }
    if (jobs->empty()) return;

    auto docPtr = std::make_shared<std::string>(getDocumentText(h));
    if (docPtr->empty()) return;

    int ticket = gApplyTicket.fetch_add(1) + 1;

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        using Range = std::pair<intptr_t, intptr_t>;
        std::vector<std::pair<int, std::vector<Range>>> results;

        for (const auto &job : *jobs) {
            if (ticket != gApplyTicket.load()) return;
            std::vector<Range> ranges;
            collectRangesForPattern(*docPtr, job.pattern, ranges);
            if (!ranges.empty())
                results.push_back({job.ind, std::move(ranges)});
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            if (ticket != gApplyTicket.load()) return;
            for (const auto &r : results)
                for (const auto &range : r.second)
                    fillRange(h, r.first, range.first, range.second);
        });
    });
}

// Navigation
static void gotoHighlight(bool forward, int onlyStyleIndex = -1) {
    NppHandle h = curScintilla();
    if (!h) return;

    std::vector<intptr_t> starts;
    for (int i = 0; i < MAX_STYLES; i++) {
        if (onlyStyleIndex >= 0 && i != onlyStyleIndex) continue;
        auto it = gIndicatorStarts.find(INDICATOR_BASE + i);
        if (it != gIndicatorStarts.end())
            for (intptr_t s : it->second)
                starts.push_back(s);
    }
    if (starts.empty()) return;
    std::sort(starts.begin(), starts.end());

    intptr_t cur = sci(h, SCI_GETCURRENTPOS);
    intptr_t target;
    if (forward) {
        auto it = std::upper_bound(starts.begin(), starts.end(), cur);
        target  = (it == starts.end()) ? starts.front() : *it;
    } else {
        auto it = std::lower_bound(starts.begin(), starts.end(), cur);
        if (it == starts.begin()) target = starts.back();
        else                      target = *std::prev(it);
    }
    sci(h, SCI_GOTOPOS, target);
    sci(h, SCI_SCROLLCARET);
}

// Panel controller
@interface CCPanelController : NSObject
    <NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate>

@property (strong) NSPanel            *panel;
@property (strong) NSTableView        *tableView;
@property (strong) NSSegmentedControl *colorSelector;
@property (strong) NSButton           *btnAdd, *btnDelete, *btnNew;
@property (strong) NSButton           *btnSelAll, *btnUnselAll;
@property (strong) NSButton           *btnRefresh;
@property (strong) NSButton           *btnPrev, *btnNext;
@property (strong) NSButton           *btnOpen, *btnSave;

- (void)show;
- (void)reloadTable;
- (int)selectedStyleIndex;
@end

@implementation CCPanelController

- (instancetype)init {
    self = [super init];
    if (self) [self buildPanel];
    return self;
}

- (void)buildPanel {
    NSRect fr = NSMakeRect(200, 400, 480, 420);
    _panel = [[NSPanel alloc]
              initWithContentRect:fr
                        styleMask:NSWindowStyleMaskTitled     |
                                  NSWindowStyleMaskClosable   |
                                  NSWindowStyleMaskResizable  |
                                  NSWindowStyleMaskUtilityWindow
                          backing:NSBackingStoreBuffered
                            defer:NO];
    _panel.title             = @"SmartHighlight";
    _panel.delegate          = self;
    _panel.hidesOnDeactivate = NO;
    _panel.floatingPanel     = YES;

    NSView *cv = _panel.contentView;

    // Color selector (top row)
    _colorSelector = [[NSSegmentedControl alloc] init];
    _colorSelector.segmentCount = MAX_STYLES;
    for (int i = 0; i < MAX_STYLES; i++)
        [_colorSelector setLabel:[NSString stringWithUTF8String:kStyleNames[i]]
                      forSegment:i];
    _colorSelector.selectedSegment = 0;
    _colorSelector.translatesAutoresizingMaskIntoConstraints = NO;
    [cv addSubview:_colorSelector];

    // Scroll + table
    NSScrollView *scroll = [[NSScrollView alloc] init];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.hasVerticalScroller   = YES;
    scroll.hasHorizontalScroller = NO;
    scroll.autohidesScrollers    = YES;
    [cv addSubview:scroll];

    _tableView = [[NSTableView alloc] init];
    _tableView.dataSource                        = self;
    _tableView.delegate                          = self;
    _tableView.usesAlternatingRowBackgroundColors = YES;
    _tableView.allowsMultipleSelection            = NO;
    _tableView.rowHeight                          = 20;

    NSTableColumn *colCk = [[NSTableColumn alloc] initWithIdentifier:@"enabled"];
    colCk.title = @""; colCk.width = 24; colCk.minWidth = 24; colCk.maxWidth = 24;
    [_tableView addTableColumn:colCk];

    NSTableColumn *colCl = [[NSTableColumn alloc] initWithIdentifier:@"color"];
    colCl.title = @"Color"; colCl.width = 72;
    [_tableView addTableColumn:colCl];

    NSTableColumn *colPt = [[NSTableColumn alloc] initWithIdentifier:@"pattern"];
    colPt.title = @"Pattern / Keyword";
    colPt.resizingMask = NSTableColumnAutoresizingMask;
    [_tableView addTableColumn:colPt];

    scroll.documentView = _tableView;

    // Buttons row 1
    _btnAdd      = [self makeButton:@"Add"          action:@selector(actionAdd:)];
    _btnDelete   = [self makeButton:@"Delete"        action:@selector(actionDelete:)];
    _btnNew      = [self makeButton:@"New"           action:@selector(actionNew:)];
    _btnSelAll   = [self makeButton:@"Select All"    action:@selector(actionSelectAll:)];
    _btnUnselAll = [self makeButton:@"Unselect All"  action:@selector(actionUnselectAll:)];
    _btnRefresh  = [self makeButton:@"Refresh"       action:@selector(actionRefresh:)];

    // Buttons row 2
    _btnPrev = [self makeButton:@"Prev"    action:@selector(actionPrev:)];
    _btnNext = [self makeButton:@"Next"    action:@selector(actionNext:)];
    _btnOpen = [self makeButton:@"Open..." action:@selector(actionOpen:)];
    _btnSave = [self makeButton:@"Save..." action:@selector(actionSave:)];

    NSStackView *row1 = [NSStackView stackViewWithViews:
        @[_btnAdd, _btnDelete, _btnNew,
          _btnSelAll, _btnUnselAll, _btnRefresh]];
    row1.spacing = 6;
    row1.translatesAutoresizingMaskIntoConstraints = NO;

    NSStackView *row2 = [NSStackView stackViewWithViews:
        @[_btnPrev, _btnNext, _btnOpen, _btnSave]];
    row2.spacing = 6;
    row2.translatesAutoresizingMaskIntoConstraints = NO;

    [cv addSubview:row1];
    [cv addSubview:row2];

    NSDictionary *views   = @{@"cs":_colorSelector, @"sc":scroll,
                               @"r1":row1, @"r2":row2};
    NSDictionary *metrics = @{@"p":@8};

    for (NSString *k in @[@"cs",@"sc",@"r1",@"r2"])
        [cv addConstraints:
            [NSLayoutConstraint
             constraintsWithVisualFormat:
                 [NSString stringWithFormat:@"H:|-(p)-[%@]-(p)-|", k]
                                 options:0 metrics:metrics views:views]];

    [cv addConstraints:
        [NSLayoutConstraint
         constraintsWithVisualFormat:
             @"V:|-(p)-[cs(28)]-(p)-[sc]-(p)-[r1]-(4)-[r2]-(p)-|"
                             options:0 metrics:metrics views:views]];
}

- (NSButton *)makeButton:(NSString *)title action:(SEL)sel {
    NSButton *b  = [[NSButton alloc] init];
    b.title      = title;
    b.bezelStyle = NSBezelStyleRounded;
    b.target     = self;
    b.action     = sel;
    b.translatesAutoresizingMaskIntoConstraints = NO;
    return b;
}

- (void)show {
    if (!_panel.isVisible) [_panel center];
    [_panel makeKeyAndOrderFront:nil];
    [self reloadTable];
}

- (void)reloadTable { [_tableView reloadData]; }

- (int)selectedStyleIndex {
    return (int)_colorSelector.selectedSegment;
}

// NSTableViewDataSource
- (NSInteger)numberOfRowsInTableView:(NSTableView *)tv {
    return (NSInteger)gHighlights.size();
}

- (NSView *)tableView:(NSTableView *)tv
   viewForTableColumn:(NSTableColumn *)col
                  row:(NSInteger)row {
    if (row < 0 || row >= (NSInteger)gHighlights.size()) return nil;
    const HighlightEntry &e = gHighlights[(size_t)row];

    if ([col.identifier isEqualToString:@"enabled"]) {
        NSButton *cb = [tv makeViewWithIdentifier:@"CkCell" owner:self];
        if (!cb) {
            cb = [[NSButton alloc] init];
            cb.buttonType = NSButtonTypeSwitch;
            cb.title      = @"";
            cb.identifier = @"CkCell";
        }
        cb.state  = e.enabled ? NSControlStateValueOn : NSControlStateValueOff;
        cb.tag    = row;
        cb.target = self;
        cb.action = @selector(toggleEnabled:);
        return cb;
    }

    if ([col.identifier isEqualToString:@"color"]) {
        NSTextField *tf = [tv makeViewWithIdentifier:@"ClCell" owner:self];
        if (!tf) {
            tf = [[NSTextField alloc] init];
            tf.editable        = NO;
            tf.bordered        = NO;
            tf.drawsBackground = YES;
            tf.alignment       = NSTextAlignmentCenter;
            tf.identifier      = @"ClCell";
        }
        int si = (e.styleIndex >= 0 && e.styleIndex < MAX_STYLES)
                 ? e.styleIndex : 0;
        tf.stringValue     = [NSString stringWithUTF8String:kStyleNames[si]];
        tf.backgroundColor = styleNSColor(si);
        int c = kStyleColor[si];
        float lum = (0.299f*(c&0xFF) + 0.587f*((c>>8)&0xFF) +
                     0.114f*((c>>16)&0xFF)) / 255.0f;
        tf.textColor = (lum > 0.5f) ? [NSColor blackColor] : [NSColor whiteColor];
        return tf;
    }

    if ([col.identifier isEqualToString:@"pattern"]) {
        NSTextField *tf = [tv makeViewWithIdentifier:@"PtCell" owner:self];
        if (!tf) {
            tf = [[NSTextField alloc] init];
            tf.editable        = NO;
            tf.bordered        = NO;
            tf.drawsBackground = NO;
            tf.identifier      = @"PtCell";
        }
        tf.stringValue = [NSString stringWithUTF8String:e.pattern.c_str()];
        return tf;
    }
    return nil;
}

- (void)toggleEnabled:(NSButton *)sender {
    NSInteger row = sender.tag;
    if (row < 0 || row >= (NSInteger)gHighlights.size()) return;
    gHighlights[(size_t)row].enabled =
        (sender.state == NSControlStateValueOn);
    saveHighlights();
    applyAllHighlights();
}

// Button actions

- (void)actionAdd:(id)sender {
    NppHandle h = curScintilla();
    if (!h) return;
    intptr_t selS = sci(h, SCI_GETSELECTIONSTART);
    intptr_t selE = sci(h, SCI_GETSELECTIONEND);
    std::string doc = getDocumentText(h);
    if (doc.empty()) return;

    std::string literal;
    if (selS == selE) {
        intptr_t ws = sci(h, SCI_WORDSTARTPOSITION, selS, 1);
        intptr_t we = sci(h, SCI_WORDENDPOSITION,   selS, 1);
        if (ws >= we || ws < 0 || we > (intptr_t)doc.size()) return;
        literal = doc.substr((size_t)ws, (size_t)(we - ws));
    } else {
        if (selS < 0 || selE > (intptr_t)doc.size() || selE <= selS) return;
        literal = doc.substr((size_t)selS, (size_t)(selE - selS));
    }
    if (literal.empty()) return;

    // Escape regex special chars so we match the literal string
    std::string pattern = std::regex_replace(
        literal,
        std::regex(R"([-\[\]{}()*+?.,\\^$|#\s])"),
        R"(\$&)");

    int styleIdx = [self selectedStyleIndex];

    // Re-enable existing entry with same pattern+style
    for (auto &e : gHighlights) {
        if (e.pattern == pattern && e.styleIndex == styleIdx) {
            bool wasEnabled = e.enabled;
            e.enabled = true;
            saveHighlights();
            if (!wasEnabled)
                applySingleHighlight(INDICATOR_BASE + styleIdx, pattern);
            [self reloadTable];
            return;
        }
    }

    HighlightEntry e;
    e.pattern    = pattern;
    e.styleIndex = styleIdx;
    e.enabled    = true;
    e.ts         = (double)std::time(nullptr);
    gHighlights.push_back(e);

    saveHighlights();
    applySingleHighlight(INDICATOR_BASE + styleIdx, pattern);
    [self reloadTable];
    NSInteger newRow = (NSInteger)gHighlights.size() - 1;
    [_tableView selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)newRow]
               byExtendingSelection:NO];
    [_tableView scrollRowToVisible:newRow];
}

- (void)actionDelete:(id)sender {
    NSInteger row = _tableView.selectedRow;
    if (row < 0 || row >= (NSInteger)gHighlights.size()) return;
    gHighlights.erase(gHighlights.begin() + row);
    saveHighlights();
    applyAllHighlights();
    [self reloadTable];
}

- (void)actionNew:(id)sender {
    gHighlights.clear();
    saveHighlights();
    NppHandle h = curScintilla();
    if (h) clearAllIndicators(h);
    gIndicatorStarts.clear();
    [self reloadTable];
}

- (void)actionSelectAll:(id)sender {
    for (auto &e : gHighlights) e.enabled = true;
    saveHighlights();
    applyAllHighlights();
    [self reloadTable];
}

- (void)actionUnselectAll:(id)sender {
    for (auto &e : gHighlights) e.enabled = false;
    saveHighlights();
    NppHandle h = curScintilla();
    if (h) clearAllIndicators(h);
    gIndicatorStarts.clear();
    [self reloadTable];
}

- (void)actionRefresh:(id)sender {
    applyAllHighlights();
}

- (void)actionNext:(id)sender {
    NSInteger row = _tableView.selectedRow;
    int styleIdx  = -1;
    if (row >= 0 && row < (NSInteger)gHighlights.size())
        styleIdx = gHighlights[(size_t)row].styleIndex;
    gotoHighlight(true, styleIdx);
}

- (void)actionPrev:(id)sender {
    NSInteger row = _tableView.selectedRow;
    int styleIdx  = -1;
    if (row >= 0 && row < (NSInteger)gHighlights.size())
        styleIdx = gHighlights[(size_t)row].styleIndex;
    gotoHighlight(false, styleIdx);
}

- (void)actionOpen:(id)sender {
    NSOpenPanel *op = [NSOpenPanel openPanel];
    op.allowedFileTypes = @[@"cch", @"json"];
    op.title            = @"Open Highlight List";
    if ([op runModal] != NSModalResponseOK || !op.URL) return;
    importFromPath(op.URL.path.UTF8String);
    saveHighlights();
    applyAllHighlights();
    [self reloadTable];
}

- (void)actionSave:(id)sender {
    NSSavePanel *sp = [NSSavePanel savePanel];
    sp.allowedFileTypes     = @[@"cch"];
    sp.nameFieldStringValue = @"highlights.cch";
    sp.title                = @"Save Highlight List";
    if ([sp runModal] != NSModalResponseOK || !sp.URL) return;
    exportToPath(sp.URL.path.UTF8String);
}

@end  // CCPanelController

// Singleton panel instance
static CCPanelController *gPanel = nil;

static void showPanel() {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!gPanel) gPanel = [[CCPanelController alloc] init];
        [gPanel show];
    });
}

// Deferred apply on document open / buffer switch
static void deferredApply(int retriesLeft, int ticket) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 80 * NSEC_PER_MSEC),
                   dispatch_get_main_queue(), ^{
        if (ticket != gApplyTicket.load()) return;
        NppHandle h = curScintilla();
        if (!h) {
            if (retriesLeft > 0) deferredApply(retriesLeft - 1, ticket);
            return;
        }
        setupIndicators(h);
        if (sci(h, SCI_GETLENGTH) == 0) {
            if (retriesLeft > 0) deferredApply(retriesLeft - 1, ticket);
            return;
        }
        applyAllHighlights();
    });
}

static void requestDeferredApply(int retriesLeft = 8) {
    int ticket = gApplyTicket.fetch_add(1) + 1;
    deferredApply(retriesLeft, ticket);
}

// Plugin-menu commands
static void cmd_showPanel() { showPanel(); }
static void cmd_gotoNext()  { gotoHighlight(true);  }
static void cmd_gotoPrev()  { gotoHighlight(false); }
static void cmd_refresh()   { applyAllHighlights(); }

// Plugin exports
static const int NB_FUNC = 6;
static FuncItem  g_funcItem[NB_FUNC];
static ShortcutKey g_sk[3];
static int gFuncIdx = 0;

static void addItem(const char *name, PFUNCPLUGINCMD fn,
                    ShortcutKey *sk = nullptr) {
    if (gFuncIdx >= NB_FUNC) return;
    strlcpy(g_funcItem[gFuncIdx]._itemName, name, NPP_MENU_ITEM_SIZE);
    g_funcItem[gFuncIdx]._pFunc      = fn;
    g_funcItem[gFuncIdx]._cmdID      = 0;
    g_funcItem[gFuncIdx]._init2Check = false;
    g_funcItem[gFuncIdx]._pShKey     = sk;
    gFuncIdx++;
}

static void addSep() {
    if (gFuncIdx >= NB_FUNC) return;
    g_funcItem[gFuncIdx]._itemName[0] = '-';
    g_funcItem[gFuncIdx]._itemName[1] = '\0';
    g_funcItem[gFuncIdx]._pFunc       = nullptr;
    g_funcItem[gFuncIdx]._cmdID       = 0;
    g_funcItem[gFuncIdx]._init2Check  = false;
    g_funcItem[gFuncIdx]._pShKey      = nullptr;
    gFuncIdx++;
}

extern "C" NPP_EXPORT void setInfo(NppData data) {
    g_nppData = data;

    char buf[4096] = {};
    g_nppData._sendMessage(g_nppData._nppHandle,
                           NPPM_GETPLUGINSCONFIGDIR,
                           sizeof(buf), (intptr_t)buf);
    std::string configDir = buf;
    if (configDir.empty() || configDir[0] != '/') {
        const char *home = getenv("HOME");
        configDir = home
            ? std::string(home) + "/.notepad++/plugins/Config"
            : ".";
    }

    @autoreleasepool {
        NSString *dir = [[NSString stringWithUTF8String:configDir.c_str()]
                         stringByStandardizingPath];
        [[NSFileManager defaultManager]
            createDirectoryAtPath:dir
          withIntermediateDirectories:YES
                         attributes:nil
                              error:nil];
    }
    g_configPath = configDir + "/SmartHighlight_highlights.json";

    loadHighlights();

    gFuncIdx = 0;
    g_sk[0] = {true, false, false, true, (unsigned char)'H'};
    addItem("Show SmartHighlight Panel",    cmd_showPanel, &g_sk[0]);
    addSep();
    g_sk[1] = {true, false, false, true, (unsigned char)']'};
    addItem("Go to Next Highlight",     cmd_gotoNext,  &g_sk[1]);
    g_sk[2] = {true, false, false, true, (unsigned char)'['};
    addItem("Go to Previous Highlight", cmd_gotoPrev,  &g_sk[2]);
    addSep();
    addItem("Refresh SmartHighlight",       cmd_refresh);
}

extern "C" NPP_EXPORT const char *getName() {
    static const char *kName = "SmartHighlight";
    return kName;
}

extern "C" NPP_EXPORT FuncItem *getFuncsArray(int *nbF) {
    *nbF = NB_FUNC;
    return g_funcItem;
}

extern "C" NPP_EXPORT void beNotified(SCNotification *notif) {
    switch (notif->nmhdr.code) {
        case NPPN_READY:
            setupIndicators(g_nppData._scintillaMainHandle);
            setupIndicators(g_nppData._scintillaSecondHandle);
            requestDeferredApply(12);
            break;
        case NPPN_BUFFERACTIVATED:
        case NPPN_FILEOPENED:
            requestDeferredApply(6);
            break;
        default:
            break;
    }
}

extern "C" NPP_EXPORT intptr_t messageProc(uint32_t, uintptr_t, intptr_t) {
    return 1;
}
