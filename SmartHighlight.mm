/*
 * SmartHighlight.mm - Native macOS Notepad++ plugin
 *
 * Docked right-side highlight panel with persistent keyword list.
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

// Nextpad++ macOS dock panel API (host extension).
#ifndef NPPM_DMM_REGISTERPANEL
#define NPPMSG                      (0x0400 + 1000)
#define NPPM_DMM_REGISTERPANEL      (NPPMSG + 501)
#define NPPM_DMM_SHOWPANEL          (NPPMSG + 502)
#define NPPM_DMM_HIDEPANEL          (NPPMSG + 503)
#define NPPM_DMM_UNREGISTERPANEL    (NPPMSG + 504)
#endif

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

static bool ccHasSuffixCI(NSString *value, NSString *suffix) {
    if (!value || !suffix) return false;
    return [[value lowercaseString] hasSuffix:[suffix lowercaseString]];
}

static bool ccIsSupportedArchivePath(NSString *path) {
    if (!path) return false;
    return ccHasSuffixCI(path, @".zip") ||
           ccHasSuffixCI(path, @".tar") ||
           ccHasSuffixCI(path, @".tar.gz") ||
           ccHasSuffixCI(path, @".tgz") ||
           ccHasSuffixCI(path, @".gz") ||
           ccHasSuffixCI(path, @".7z") ||
           ccHasSuffixCI(path, @".rar");
}

static NSString *ccStripArchiveExtension(NSString *fileName) {
    if (!fileName) return @"archive";
    NSString *lower = [fileName lowercaseString];
    NSArray<NSString *> *suffixes = @[@".tar.gz", @".tgz", @".tar", @".zip", @".7z", @".rar", @".gz"];
    for (NSString *s in suffixes) {
        if ([lower hasSuffix:s]) {
            return [fileName substringToIndex:(fileName.length - s.length)];
        }
    }
    return [fileName stringByDeletingPathExtension];
}

static NSString *ccUniqueNestedOutputDir(NSString *archivePath) {
    NSString *parent = [archivePath stringByDeletingLastPathComponent];
    NSString *base = ccStripArchiveExtension([archivePath lastPathComponent]);
    NSString *candidate = [parent stringByAppendingPathComponent:base];

    if (![[NSFileManager defaultManager] fileExistsAtPath:candidate]) {
        return candidate;
    }

    candidate = [parent stringByAppendingPathComponent:[base stringByAppendingString:@"_nested"]];
    if (![[NSFileManager defaultManager] fileExistsAtPath:candidate]) {
        return candidate;
    }

    NSInteger i = 2;
    while ([[NSFileManager defaultManager] fileExistsAtPath:candidate]) {
        candidate = [parent stringByAppendingPathComponent:
                     [NSString stringWithFormat:@"%@_nested_%ld", base, (long)i]];
        i++;
    }
    return candidate;
}

static bool ccRunTask(NSString *launchPath,
                      NSArray<NSString *> *args,
                      NSString **errorText) {
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm isExecutableFileAtPath:launchPath]) {
        if (errorText) *errorText = [NSString stringWithFormat:@"Missing tool: %@", launchPath];
        return false;
    }

    NSPipe *errPipe = [NSPipe pipe];
    NSTask *task = [[NSTask alloc] init];
    task.launchPath = launchPath;
    task.arguments = args ?: @[];
    task.standardOutput = [NSPipe pipe];
    task.standardError = errPipe;

    @try {
        [task launch];
    } @catch (NSException *ex) {
        if (errorText) *errorText = [NSString stringWithFormat:@"Failed launching %@: %@", launchPath, ex.reason ?: @"unknown"];
        return false;
    }

    [task waitUntilExit];
    NSData *errData = [[errPipe fileHandleForReading] readDataToEndOfFile];
    if (task.terminationStatus != 0) {
        NSString *stderrStr = [[NSString alloc] initWithData:errData encoding:NSUTF8StringEncoding];
        if (stderrStr.length == 0) stderrStr = @"Unknown extraction error";
        if (errorText) *errorText = [NSString stringWithFormat:@"%@", stderrStr];
        return false;
    }
    return true;
}

static bool ccExtractGzipFile(NSString *archivePath,
                              NSString *outputDir,
                              NSString **errorText) {
    NSString *outName = [[archivePath lastPathComponent] stringByDeletingPathExtension];
    if (outName.length == 0) outName = @"archive.out";
    NSString *outPath = [outputDir stringByAppendingPathComponent:outName];

    NSFileManager *fm = [NSFileManager defaultManager];
    [fm createDirectoryAtPath:outputDir withIntermediateDirectories:YES attributes:nil error:nil];

    NSTask *task = [[NSTask alloc] init];
    task.launchPath = @"/usr/bin/gzip";
    task.arguments = @[@"-dc", archivePath];
    NSPipe *outPipe = [NSPipe pipe];
    NSPipe *errPipe = [NSPipe pipe];
    task.standardOutput = outPipe;
    task.standardError = errPipe;

    @try {
        [task launch];
    } @catch (NSException *ex) {
        if (errorText) *errorText = [NSString stringWithFormat:@"Failed launching gzip: %@", ex.reason ?: @"unknown"];
        return false;
    }

    NSData *data = [[outPipe fileHandleForReading] readDataToEndOfFile];
    [task waitUntilExit];
    NSData *errData = [[errPipe fileHandleForReading] readDataToEndOfFile];
    if (task.terminationStatus != 0) {
        NSString *stderrStr = [[NSString alloc] initWithData:errData encoding:NSUTF8StringEncoding];
        if (stderrStr.length == 0) stderrStr = @"gzip failed";
        if (errorText) *errorText = stderrStr;
        return false;
    }

    NSError *writeErr = nil;
    if (![data writeToFile:outPath options:NSDataWritingAtomic error:&writeErr]) {
        if (errorText) *errorText = [NSString stringWithFormat:@"Failed writing %@: %@", outPath, writeErr.localizedDescription ?: @"unknown"];
        return false;
    }
    return true;
}

static bool ccExtractArchiveToDirectory(NSString *archivePath,
                                        NSString *outputDir,
                                        NSString **errorText) {
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm createDirectoryAtPath:outputDir withIntermediateDirectories:YES attributes:nil error:nil];

    NSString *lower = [archivePath lowercaseString];
    if ([lower hasSuffix:@".zip"]) {
        return ccRunTask(@"/usr/bin/ditto", @[@"-x", @"-k", archivePath, outputDir], errorText);
    }
    if ([lower hasSuffix:@".tar"] || [lower hasSuffix:@".tar.gz"] || [lower hasSuffix:@".tgz"]) {
        return ccRunTask(@"/usr/bin/tar", @[@"-xf", archivePath, @"-C", outputDir], errorText);
    }
    if ([lower hasSuffix:@".gz"] && ![lower hasSuffix:@".tar.gz"] && ![lower hasSuffix:@".tgz"]) {
        return ccExtractGzipFile(archivePath, outputDir, errorText);
    }

    NSArray<NSArray<NSString *> *> *candidates = @[
        @[@"/opt/homebrew/bin/7z", @"x", @"-y", [@"-o" stringByAppendingString:outputDir], archivePath],
        @[@"/usr/local/bin/7z", @"x", @"-y", [@"-o" stringByAppendingString:outputDir], archivePath],
        @[@"/usr/bin/7z", @"x", @"-y", [@"-o" stringByAppendingString:outputDir], archivePath],
        @[@"/opt/homebrew/bin/unar", @"-q", @"-o", outputDir, archivePath],
        @[@"/usr/local/bin/unar", @"-q", @"-o", outputDir, archivePath],
        @[@"/usr/bin/unar", @"-q", @"-o", outputDir, archivePath],
        @[@"/usr/bin/bsdtar", @"-xf", archivePath, @"-C", outputDir],
    ];

    NSString *lastErr = nil;
    for (NSArray<NSString *> *cmd in candidates) {
        if (cmd.count < 1) continue;
        NSString *tool = cmd[0];
        NSArray<NSString *> *args = (cmd.count > 1) ? [cmd subarrayWithRange:NSMakeRange(1, cmd.count - 1)] : @[];
        NSString *err = nil;
        if (ccRunTask(tool, args, &err)) return true;
        lastErr = err;
    }

    if (errorText) *errorText = lastErr ?: @"No suitable extractor tool found";
    return false;
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

static bool gotoPatternHighlight(bool forward, const std::string &pattern) {
    NppHandle h = curScintilla();
    if (!h || pattern.empty()) return false;

    std::string doc = getDocumentText(h);
    if (doc.empty()) return false;

    std::vector<std::pair<intptr_t, intptr_t>> ranges;
    collectRangesForPattern(doc, pattern, ranges);
    if (ranges.empty()) return false;

    std::vector<intptr_t> starts;
    starts.reserve(ranges.size());
    for (const auto &r : ranges)
        starts.push_back(r.first);
    std::sort(starts.begin(), starts.end());

    intptr_t cur = sci(h, SCI_GETCURRENTPOS);
    intptr_t target;
    if (forward) {
        auto it = std::upper_bound(starts.begin(), starts.end(), cur);
        target = (it == starts.end()) ? starts.front() : *it;
    } else {
        auto it = std::lower_bound(starts.begin(), starts.end(), cur);
        if (it == starts.begin()) target = starts.back();
        else                      target = *std::prev(it);
    }

    sci(h, SCI_GOTOPOS, target);
    sci(h, SCI_SCROLLCARET);
    return true;
}

// Panel controller
@interface CCPanelController : NSObject
    <NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate>

@property (strong) NSPanel            *panel;
@property (strong) NSView             *dockView;
@property (strong) NSTableView        *tableView;
@property (strong) NSPopUpButton      *colorDropdown;
@property (strong) NSButton           *btnAdd, *btnDelete, *btnNew;
@property (strong) NSButton           *btnSelAll, *btnUnselAll;
@property (strong) NSButton           *btnRefresh;
@property (strong) NSButton           *btnPrev, *btnNext;
@property (strong) NSButton           *btnOpen, *btnSave;
@property (strong) NSButton           *btnDebugParse, *btnDebugClear;
@property (strong) NSButton           *btnExtractNested;
@property (strong) NSTextView         *debugTextView;

- (void)show;
- (NSView *)panelViewForDocking;
- (void)reloadTable;
- (int)selectedStyleIndex;
- (NSButton *)makeIconButton:(NSString *)symbol
                                        fallback:(NSString *)fallback
                                            action:(SEL)sel
                                                 tip:(NSString *)tip;
- (void)appendDebugLine:(NSString *)line;
- (void)appendParserSeparator:(NSString *)tag;
- (void)appendParserSection:(NSString *)tag title:(NSString *)title;
- (void)appendParserField:(NSString *)tag key:(NSString *)key value:(NSString *)value;
@end

@implementation CCPanelController

- (instancetype)init {
    self = [super init];
    if (self) [self buildPanel];
    return self;
}

- (void)buildPanel {
    NSRect fr = NSMakeRect(120, 120, 340, 560);
    _panel = [[NSPanel alloc]
              initWithContentRect:fr
                          styleMask:NSWindowStyleMaskUtilityWindow |
                                    NSWindowStyleMaskTitled |
                                    NSWindowStyleMaskClosable |
                                    NSWindowStyleMaskResizable
                          backing:NSBackingStoreBuffered
                            defer:NO];
    _panel.title = @"SmartHighlight";
    _panel.delegate = self;
    _panel.hidesOnDeactivate = NO;
    _panel.floatingPanel = YES;
    _panel.releasedWhenClosed = NO;
    _panel.hasShadow = YES;
    _panel.backgroundColor = [NSColor windowBackgroundColor];
    _panel.level = NSFloatingWindowLevel;
    _panel.minSize = NSMakeSize(280, 360);
    _panel.movableByWindowBackground = YES;
    [_panel setFrameAutosaveName:@"SmartHighlightPanelFrame"];

    NSView *cv = [[NSView alloc] initWithFrame:_panel.contentView.bounds];
    cv.translatesAutoresizingMaskIntoConstraints = NO;
    _panel.contentView = cv;
    _dockView = cv;

    _colorDropdown = [[NSPopUpButton alloc] init];
    _colorDropdown.autoenablesItems = NO;
    _colorDropdown.font = [NSFont systemFontOfSize:11];
    _colorDropdown.translatesAutoresizingMaskIntoConstraints = NO;

    for (int i = 0; i < MAX_STYLES; i++) {
        NSString *colorName = [NSString stringWithUTF8String:kStyleNames[i]];
        NSMutableAttributedString *attrStr =
            [[NSMutableAttributedString alloc] initWithString:@"● "];
        NSColor *itemColor = styleNSColor(i);
        [attrStr addAttribute:NSForegroundColorAttributeName
                        value:itemColor
                        range:NSMakeRange(0, 1)];
        NSAttributedString *nameStr =
            [[NSAttributedString alloc] initWithString:colorName
                                            attributes:@{NSForegroundColorAttributeName: [NSColor blackColor]}];
        [attrStr appendAttributedString:nameStr];

        [_colorDropdown addItemWithTitle:colorName];
        NSMenuItem *item = [_colorDropdown lastItem];
        [item setAttributedTitle:attrStr];
    }
    [_colorDropdown selectItemAtIndex:0];
    [_colorDropdown.widthAnchor constraintGreaterThanOrEqualToConstant:110].active = YES;

    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.hasVerticalScroller = YES;
    scroll.hasHorizontalScroller = NO;
    scroll.autohidesScrollers = YES;
    scroll.scrollerStyle = NSScrollerStyleOverlay;

    _tableView = [[NSTableView alloc] initWithFrame:NSZeroRect];
    _tableView.dataSource = self;
    _tableView.delegate = self;
    _tableView.usesAlternatingRowBackgroundColors = YES;
    _tableView.allowsMultipleSelection = NO;
    _tableView.rowHeight = 18;
    _tableView.headerView = nil;

    NSTableColumn *colCk = [[NSTableColumn alloc] initWithIdentifier:@"enabled"];
    colCk.title = @"";
    colCk.width = 18;
    colCk.minWidth = 18;
    colCk.maxWidth = 18;
    [_tableView addTableColumn:colCk];

    NSTableColumn *colPt = [[NSTableColumn alloc] initWithIdentifier:@"pattern"];
    colPt.title = @"Keyword";
    colPt.resizingMask = NSTableColumnAutoresizingMask;
    [_tableView addTableColumn:colPt];
    scroll.documentView = _tableView;

    _btnAdd = [self makeIconButton:@"plus"
                          fallback:@"Add"
                            action:@selector(actionAdd:)
                               tip:@"Add selected text"];
    _btnDelete = [self makeIconButton:@"trash"
                             fallback:@"Del"
                               action:@selector(actionDelete:)
                                  tip:@"Delete selected keyword"];
    _btnNew = [self makeIconButton:@"doc.badge.plus"
                          fallback:@"New"
                            action:@selector(actionNew:)
                               tip:@"Clear all keywords"];
    _btnSelAll = [self makeIconButton:@"checkmark.circle"
                             fallback:@"All"
                               action:@selector(actionSelectAll:)
                                  tip:@"Enable all keywords"];
    _btnUnselAll = [self makeIconButton:@"xmark.circle"
                               fallback:@"None"
                                 action:@selector(actionUnselectAll:)
                                    tip:@"Disable all keywords"];
    _btnRefresh = [self makeIconButton:@"arrow.clockwise"
                              fallback:@"R"
                                action:@selector(actionRefresh:)
                                   tip:@"Re-apply highlights"];
    _btnPrev = [self makeIconButton:@"arrow.up"
                           fallback:@"Prev"
                             action:@selector(actionPrev:)
                                tip:@"Previous match"];
    _btnNext = [self makeIconButton:@"arrow.down"
                           fallback:@"Next"
                             action:@selector(actionNext:)
                                tip:@"Next match"];
    _btnOpen = [self makeIconButton:@"folder"
                           fallback:@"Open"
                             action:@selector(actionOpen:)
                                tip:@"Open keyword list"];
    _btnSave = [self makeIconButton:@"square.and.arrow.down"
                           fallback:@"Save"
                             action:@selector(actionSave:)
                                tip:@"Save keyword list"];
    _btnDebugParse = [self makeIconButton:@"waveform.path.ecg"
                                 fallback:@"DTMF"
                                   action:@selector(actionDebugParse:)
                                      tip:@"Analyze DTMF in selection"];
    _btnDebugClear = [self makeIconButton:@"eraser"
                                 fallback:@"Clr"
                                   action:@selector(actionDebugClear:)
                                      tip:@"Clear debug log"];
        _btnExtractNested = [self makeIconButton:@"archivebox"
                                                                        fallback:@"Xtr"
                                                                            action:@selector(actionExtractNested:)
                                                                                 tip:@"Browse archive and extract nested files"];

    NSStackView *topRow = [NSStackView stackViewWithViews:@[
        _colorDropdown,
        _btnAdd,
        _btnDelete,
        _btnNew,
        _btnSelAll,
        _btnUnselAll,
        _btnRefresh
    ]];
    topRow.spacing = 4;
    topRow.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    topRow.distribution = NSStackViewDistributionFillProportionally;
    topRow.translatesAutoresizingMaskIntoConstraints = NO;

    NSStackView *bottomRow = [NSStackView stackViewWithViews:@[
        _btnPrev,
        _btnNext,
        _btnOpen,
        _btnSave,
        _btnExtractNested,
        _btnDebugParse,
        _btnDebugClear
    ]];
    bottomRow.spacing = 4;
    bottomRow.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    bottomRow.distribution = NSStackViewDistributionFillEqually;
    bottomRow.translatesAutoresizingMaskIntoConstraints = NO;

    NSScrollView *debugScroll = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    debugScroll.translatesAutoresizingMaskIntoConstraints = NO;
    debugScroll.hasVerticalScroller = YES;
    debugScroll.hasHorizontalScroller = NO;
    debugScroll.autohidesScrollers = YES;
    debugScroll.scrollerStyle = NSScrollerStyleOverlay;
    debugScroll.drawsBackground = YES;

    _debugTextView = [[NSTextView alloc] initWithFrame:NSZeroRect];
    _debugTextView.editable = NO;
    _debugTextView.selectable = YES;
    _debugTextView.richText = NO;
    _debugTextView.font = [NSFont userFixedPitchFontOfSize:11];
    _debugTextView.string = @"[debug] SmartHighlight debug panel ready\n";
    debugScroll.documentView = _debugTextView;

    NSView *tableContainer = [[NSView alloc] initWithFrame:NSZeroRect];
    tableContainer.translatesAutoresizingMaskIntoConstraints = NO;
    [tableContainer addSubview:scroll];
    [NSLayoutConstraint activateConstraints:@[
        [scroll.leadingAnchor constraintEqualToAnchor:tableContainer.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:tableContainer.trailingAnchor],
        [scroll.topAnchor constraintEqualToAnchor:tableContainer.topAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:tableContainer.bottomAnchor],
    ]];

    NSView *debugContainer = [[NSView alloc] initWithFrame:NSZeroRect];
    debugContainer.translatesAutoresizingMaskIntoConstraints = NO;
    [debugContainer addSubview:debugScroll];
    [NSLayoutConstraint activateConstraints:@[
        [debugScroll.leadingAnchor constraintEqualToAnchor:debugContainer.leadingAnchor],
        [debugScroll.trailingAnchor constraintEqualToAnchor:debugContainer.trailingAnchor],
        [debugScroll.topAnchor constraintEqualToAnchor:debugContainer.topAnchor],
        [debugScroll.bottomAnchor constraintEqualToAnchor:debugContainer.bottomAnchor],
    ]];

    NSSplitView *split = [[NSSplitView alloc] initWithFrame:NSZeroRect];
    split.translatesAutoresizingMaskIntoConstraints = NO;
    split.vertical = NO;
    split.dividerStyle = NSSplitViewDividerStyleThin;
    [split addArrangedSubview:tableContainer];
    [split addArrangedSubview:debugContainer];

    [cv addSubview:topRow];
    [cv addSubview:split];
    [cv addSubview:bottomRow];

    [NSLayoutConstraint activateConstraints:@[
        [topRow.leadingAnchor constraintEqualToAnchor:cv.leadingAnchor constant:6],
        [topRow.trailingAnchor constraintEqualToAnchor:cv.trailingAnchor constant:-6],
        [topRow.topAnchor constraintEqualToAnchor:cv.topAnchor constant:6],
        [topRow.heightAnchor constraintEqualToConstant:30],

        [split.leadingAnchor constraintEqualToAnchor:cv.leadingAnchor constant:6],
        [split.trailingAnchor constraintEqualToAnchor:cv.trailingAnchor constant:-6],
        [split.topAnchor constraintEqualToAnchor:topRow.bottomAnchor constant:6],

        [bottomRow.leadingAnchor constraintEqualToAnchor:cv.leadingAnchor constant:6],
        [bottomRow.trailingAnchor constraintEqualToAnchor:cv.trailingAnchor constant:-6],
        [bottomRow.topAnchor constraintEqualToAnchor:split.bottomAnchor constant:6],
        [bottomRow.bottomAnchor constraintEqualToAnchor:cv.bottomAnchor constant:-6],
        [bottomRow.heightAnchor constraintEqualToConstant:30],
    ]];

    [cv layoutSubtreeIfNeeded];
    [split setPosition:300 ofDividerAtIndex:0];
}

- (NSButton *)makeIconButton:(NSString *)symbol
                    fallback:(NSString *)fallback
                      action:(SEL)sel
                         tip:(NSString *)tip {
    NSButton *b = [NSButton buttonWithTitle:@"" target:self action:sel];
    NSImage *img = nil;
    if (@available(macOS 11.0, *)) {
        img = [NSImage imageWithSystemSymbolName:symbol accessibilityDescription:tip];
    }

    if (img) {
        b.image = img;
        b.imagePosition = NSImageOnly;
    } else {
        b.title = fallback;
        b.font = [NSFont systemFontOfSize:10 weight:NSFontWeightSemibold];
    }

    b.bezelStyle = NSBezelStyleTexturedRounded;
    b.toolTip = tip;
    b.translatesAutoresizingMaskIntoConstraints = NO;
    [b.widthAnchor constraintGreaterThanOrEqualToConstant:28].active = YES;
    [b.heightAnchor constraintEqualToConstant:26].active = YES;
    return b;
}

- (void)show {
    [_panel makeKeyAndOrderFront:nil];
    [_panel orderFrontRegardless];
    [self reloadTable];
}

- (NSView *)panelViewForDocking {
    return _dockView;
}

- (void)reloadTable { [_tableView reloadData]; }

- (int)selectedStyleIndex {
    return (int)_colorDropdown.indexOfSelectedItem;
}

- (void)windowWillClose:(NSNotification *)notification {
    if (notification.object == _panel) {
        [_panel orderOut:nil];
    }
}

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tv {
    (void)tv;
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
            cb.title = @"";
            cb.identifier = @"CkCell";
        }
        cb.state = e.enabled ? NSControlStateValueOn : NSControlStateValueOff;
        cb.tag = row;
        cb.target = self;
        cb.action = @selector(toggleEnabled:);
        return cb;
    }

    NSTextField *tf = [tv makeViewWithIdentifier:@"PtCell" owner:self];
    if (!tf) {
        tf = [[NSTextField alloc] init];
        tf.editable = NO;
        tf.bordered = NO;
        tf.drawsBackground = NO;
        tf.identifier = @"PtCell";
    }
    tf.stringValue = [NSString stringWithUTF8String:e.pattern.c_str()];
    return tf;
}

- (void)toggleEnabled:(NSButton *)sender {
    NSInteger row = sender.tag;
    if (row < 0 || row >= (NSInteger)gHighlights.size()) return;
    gHighlights[(size_t)row].enabled = (sender.state == NSControlStateValueOn);
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

- (void)appendDebugLine:(NSString *)line {
    if (!line) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!_debugTextView) return;
        NSString *existing = _debugTextView.string ?: @"";
        NSString *combined = [existing stringByAppendingFormat:@"%@\n", line];
        _debugTextView.string = combined;
        [_debugTextView scrollRangeToVisible:NSMakeRange(combined.length, 0)];
    });
}

- (void)actionExtractNested:(id)sender {
    (void)sender;
    NSOpenPanel *op = [NSOpenPanel openPanel];
    op.title = @"Select Compressed File(s)";
    op.canChooseFiles = YES;
    op.canChooseDirectories = NO;
    op.allowsMultipleSelection = YES;
    op.allowedFileTypes = @[@"zip", @"tar", @"gz", @"tgz", @"7z", @"rar"];

    if ([op runModal] != NSModalResponseOK || op.URLs.count == 0) return;

    NSMutableArray<NSString *> *archivePaths = [NSMutableArray array];
    for (NSURL *u in op.URLs) {
        if (!u.path) continue;
        if (ccIsSupportedArchivePath(u.path)) {
            [archivePaths addObject:u.path];
        }
    }

    if (archivePaths.count == 0) {
        [self appendDebugLine:@"[extract] No supported archives selected."];
        return;
    }

    [self appendDebugLine:[NSString stringWithFormat:@"[extract] Starting extraction for %lu file(s)", (unsigned long)archivePaths.count]];

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSFileManager *fm = [NSFileManager defaultManager];

        for (NSString *archivePath in archivePaths) {
            NSString *topOutput = ccUniqueNestedOutputDir(archivePath);
            NSString *err = nil;
            [self appendDebugLine:[NSString stringWithFormat:@"[extract] File: %@", [archivePath lastPathComponent]]];

            if (!ccExtractArchiveToDirectory(archivePath, topOutput, &err)) {
                [self appendDebugLine:[NSString stringWithFormat:@"[extract] Failed: %@", err ?: @"unknown"]];
                continue;
            }
            [self appendDebugLine:[NSString stringWithFormat:@"[extract] Output: %@", topOutput]];

            NSMutableArray<NSString *> *pendingDirs = [NSMutableArray arrayWithObject:topOutput];
            NSInteger nestedCount = 0;

            while (pendingDirs.count > 0) {
                NSString *dir = pendingDirs.firstObject;
                [pendingDirs removeObjectAtIndex:0];

                NSDirectoryEnumerator *en = [fm enumeratorAtURL:[NSURL fileURLWithPath:dir]
                                      includingPropertiesForKeys:@[NSURLIsDirectoryKey]
                                                         options:NSDirectoryEnumerationSkipsHiddenFiles
                                                    errorHandler:nil];
                for (NSURL *url in en) {
                    NSNumber *isDir = nil;
                    [url getResourceValue:&isDir forKey:NSURLIsDirectoryKey error:nil];
                    if (isDir.boolValue) continue;

                    NSString *p = url.path;
                    if (!ccIsSupportedArchivePath(p)) continue;

                    NSString *nestedOut = ccUniqueNestedOutputDir(p);
                    NSString *nestedErr = nil;
                    if (ccExtractArchiveToDirectory(p, nestedOut, &nestedErr)) {
                        nestedCount++;
                        [fm removeItemAtPath:p error:nil];
                        [pendingDirs addObject:nestedOut];
                        [self appendDebugLine:[NSString stringWithFormat:@"[extract] Nested: %@ -> %@", [p lastPathComponent], [nestedOut lastPathComponent]]];
                    } else {
                        [self appendDebugLine:[NSString stringWithFormat:@"[extract] Nested failed (%@): %@", [p lastPathComponent], nestedErr ?: @"unknown"]];
                    }
                }
            }

            NSError *removeErr = nil;
            if ([fm fileExistsAtPath:archivePath] && ![fm removeItemAtPath:archivePath error:&removeErr]) {
                [self appendDebugLine:[NSString stringWithFormat:@"[extract] Warning: could not remove source %@ (%@)",
                                      [archivePath lastPathComponent],
                                      removeErr.localizedDescription ?: @"unknown"]];
            } else {
                [self appendDebugLine:[NSString stringWithFormat:@"[extract] Source removed: %@",
                                      [archivePath lastPathComponent]]];
            }

            [self appendDebugLine:[NSString stringWithFormat:@"[extract] Completed: %@ (%ld nested extracted)", [topOutput lastPathComponent], (long)nestedCount]];
            dispatch_async(dispatch_get_main_queue(), ^{
                [[NSWorkspace sharedWorkspace] openURL:[NSURL fileURLWithPath:topOutput]];
            });
        }
    });
}

- (void)appendParserSeparator:(NSString *)tag {
    [self appendDebugLine:[NSString stringWithFormat:@"[%@] ----------------------------------------", tag ?: @"parser"]];
}

- (void)appendParserSection:(NSString *)tag title:(NSString *)title {
    NSString *safeTag = tag ?: @"parser";
    NSString *safeTitle = title ?: @"section";
    [self appendDebugLine:[NSString stringWithFormat:@"[%@] %@", safeTag, safeTitle]];
}

- (void)appendParserField:(NSString *)tag key:(NSString *)key value:(NSString *)value {
    NSString *safeTag = tag ?: @"parser";
    NSString *safeKey = key ?: @"field";
    NSString *safeVal = value ?: @"-";
    NSMutableString *padKey = [safeKey mutableCopy];
    while (padKey.length < 18) {
        [padKey appendString:@" "];
    }
    [self appendDebugLine:[NSString stringWithFormat:@"[%@]   %@: %@", safeTag, padKey, safeVal]];
}

- (void)actionDebugParse:(id)sender {
    (void)sender;
    NppHandle h = curScintilla();
    if (!h) {
        [self appendDebugLine:@"[dtmf] No active editor handle."];
        return;
    }

    std::string doc = getDocumentText(h);
    if (doc.empty()) {
        [self appendDebugLine:@"[dtmf] Document is empty."];
        return;
    }

    intptr_t selS = sci(h, SCI_GETSELECTIONSTART);
    intptr_t selE = sci(h, SCI_GETSELECTIONEND);
    std::string context;

    if (selE > selS && selS >= 0 && selE <= (intptr_t)doc.size()) {
        context = doc.substr((size_t)selS, (size_t)(selE - selS));
    } else {
        intptr_t cur = sci(h, SCI_GETCURRENTPOS);
        if (cur < 0) cur = 0;
        if (cur > (intptr_t)doc.size()) cur = (intptr_t)doc.size();

        intptr_t lineStart = cur;
        while (lineStart > 0 && doc[(size_t)lineStart - 1] != '\n') lineStart--;

        intptr_t lineEnd = cur;
        while (lineEnd < (intptr_t)doc.size() && doc[(size_t)lineEnd] != '\n') lineEnd++;

        if (lineEnd > lineStart)
            context = doc.substr((size_t)lineStart, (size_t)(lineEnd - lineStart));
    }

    if (context.empty()) {
        [self appendDebugLine:@"[dtmf] No selection/current line to analyze."];
        return;
    }

        std::string clipped = context.substr(0, std::min<size_t>(context.size(), 180));
        [self appendParserField:@"dtmf"
                                                key:@"context"
                                            value:[NSString stringWithUTF8String:clipped.c_str()]];

    bool foundAny = false;

    auto dtmfConfigNameFromCode = [](int code) -> const char * {
        switch (code) {
            case 0: return "Disabled";
            case 1: return "BestEffort";
            case 2: return "Required";
            default: return "Unknown";
        }
    };

    auto methodNameFromCode = [](int code) -> const char * {
        switch (code) {
            case 0: return "None";
            case 1: return "InBand";
            case 2: return "SIP INFO";
            case 3: return "OOB + RFC2833";
            case 4: return "KPML";
            default: return "Unknown";
        }
    };

    auto yesNo = [](int v) -> const char * {
        return v ? "Yes" : "No";
    };

    try {
        std::smatch m;
        std::regex tupleRe(
            R"((party[12]DTMF)\(\s*(\d+)\s+(\d+)\s+\(([^)]*)\)\s+(\d+)\s+(\d+)\s*\))",
            std::regex_constants::icase);

        auto begin = std::sregex_iterator(context.begin(), context.end(), tupleRe);
        auto end = std::sregex_iterator();
        for (auto it = begin; it != end; ++it) {
            foundAny = true;
            std::smatch mm = *it;

            std::string party = mm.str(1);
            int enabled = std::stoi(mm.str(2));
            int methodCode = std::stoi(mm.str(3));
            std::string payloadSpec = mm.str(4);
            int flag1 = std::stoi(mm.str(5));
            int flag2 = std::stoi(mm.str(6));

                        [self appendParserSeparator:@"dtmf"];
                        [self appendParserSection:@"dtmf"
                                                                title:[NSString stringWithUTF8String:party.c_str()]];
                        [self appendParserField:@"dtmf"
                                                                key:@"dtmf config"
                                                            value:[NSString stringWithFormat:@"%s (%d)",
                                                                         dtmfConfigNameFromCode(enabled), enabled]];
                        [self appendParserField:@"dtmf"
                                                                key:@"dtmf method"
                                                            value:[NSString stringWithFormat:@"%s (%d)",
                                                                         methodNameFromCode(methodCode), methodCode]];
                        [self appendParserField:@"dtmf"
                                                                key:@"wantDTMFreception"
                                                            value:[NSString stringWithUTF8String:yesNo(flag1)]];
                        [self appendParserField:@"dtmf"
                                                                key:@"provideOOB"
                                                            value:[NSString stringWithUTF8String:yesNo(flag2)]];

            std::regex pairRe(R"((\d+)\s*:\s*(\d+))");
            auto pBegin = std::sregex_iterator(payloadSpec.begin(), payloadSpec.end(), pairRe);
            auto pEnd = std::sregex_iterator();
            if (pBegin == pEnd) {
                [self appendParserField:@"dtmf"
                                    key:@"payload"
                                  value:[NSString stringWithFormat:@"(none parsed from: %s)", payloadSpec.c_str()]];
            } else {
                int idx = 0;
                for (auto pit = pBegin; pit != pEnd; ++pit) {
                    idx++;
                    int payload = std::stoi((*pit).str(1));
                    int clockRate = std::stoi((*pit).str(2));
                    if (idx == 1) {
                        [self appendParserField:@"dtmf"
                                            key:@"payload"
                                          value:[NSString stringWithFormat:@"%d", payload]];
                        [self appendParserField:@"dtmf"
                                            key:@"clock"
                                          value:[NSString stringWithFormat:@"%d", clockRate]];
                    } else {
                        [self appendParserField:@"dtmf"
                                            key:[NSString stringWithFormat:@"altPayload[%d]", idx]
                                          value:[NSString stringWithFormat:@"%d:%d", payload, clockRate]];
                    }
                }
            }
        }

        // Fallback heuristics for unstructured lines.
        std::regex methodRe(R"((dtmf|kpml|rfc\s*2833|sip\s*info|out\s*of\s*band|in\s*band))",
                            std::regex_constants::icase);
        if (!foundAny && std::regex_search(context, m, methodRe)) {
            foundAny = true;
            [self appendDebugLine:[NSString stringWithFormat:@"[dtmf] method(text): %s", m.str(1).c_str()]];
        }

        std::regex payloadRe(R"((?:payload(?:type)?|pt)\s*[:=]\s*(\d+))",
                             std::regex_constants::icase);
        if (!foundAny && std::regex_search(context, m, payloadRe)) {
            foundAny = true;
            [self appendDebugLine:[NSString stringWithFormat:@"[dtmf] payload: %s", m.str(1).c_str()]];
        }
    } catch (...) {
        [self appendDebugLine:@"[dtmf] Parser error while evaluating regex."];
        return;
    }

    if (!foundAny)
        [self appendDebugLine:@"[dtmf] No DTMF markers found in selected context."];
}

- (void)actionDebugClear:(id)sender {
    (void)sender;
    if (_debugTextView)
        _debugTextView.string = @"[debug] Cleared\n";
}

- (void)actionNext:(id)sender {
    NSInteger row = _tableView.selectedRow;
    if (row >= 0 && row < (NSInteger)gHighlights.size()) {
        const HighlightEntry &entry = gHighlights[(size_t)row];
        if (gotoPatternHighlight(true, entry.pattern)) return;
        gotoHighlight(true, entry.styleIndex);
        return;
    }
    gotoHighlight(true);
}

- (void)actionPrev:(id)sender {
    NSInteger row = _tableView.selectedRow;
    if (row >= 0 && row < (NSInteger)gHighlights.size()) {
        const HighlightEntry &entry = gHighlights[(size_t)row];
        if (gotoPatternHighlight(false, entry.pattern)) return;
        gotoHighlight(false, entry.styleIndex);
        return;
    }
    gotoHighlight(false);
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
static void *gDockPanelHandle = nullptr;
static bool  gDockPanelVisible = false;

static void showPanel() {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!gPanel) gPanel = [[CCPanelController alloc] init];

        if (!gDockPanelHandle) {
            NSView *v = [gPanel panelViewForDocking];
            if (v) {
                gDockPanelHandle = (void *)g_nppData._sendMessage(
                    g_nppData._nppHandle,
                    NPPM_DMM_REGISTERPANEL,
                    (uintptr_t)v,
                    (intptr_t)"SmartHighlight");
            }
        }

        if (gDockPanelHandle) {
            gDockPanelVisible = !gDockPanelVisible;
            g_nppData._sendMessage(
                g_nppData._nppHandle,
                gDockPanelVisible ? NPPM_DMM_SHOWPANEL : NPPM_DMM_HIDEPANEL,
                (uintptr_t)gDockPanelHandle,
                0);
            if (gDockPanelVisible) {
                [gPanel reloadTable];
            }
            return;
        }

        // Fallback for hosts that don't support dock panels.
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

// Plugin exports
static const int NB_FUNC = 1;
static FuncItem  g_funcItem[NB_FUNC];
static ShortcutKey g_sk[1];
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
    addItem("Toggle SmartHighlight Panel",  cmd_showPanel, &g_sk[0]);
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
            // NOTE: Do NOT call showPanel() here - it can cause startup crashes.
            // Panel is shown only via manual menu trigger (cmd_showPanel).
            break;
        case NPPN_BUFFERACTIVATED:
        case NPPN_FILEOPENED:
            requestDeferredApply(6);
            break;
        case NPPN_SHUTDOWN:
            if (gDockPanelHandle) {
                g_nppData._sendMessage(
                    g_nppData._nppHandle,
                    NPPM_DMM_UNREGISTERPANEL,
                    (uintptr_t)gDockPanelHandle,
                    0);
                gDockPanelHandle = nullptr;
                gDockPanelVisible = false;
            }
            break;
        default:
            break;
    }
}

extern "C" NPP_EXPORT intptr_t messageProc(uint32_t, uintptr_t, intptr_t) {
    return 1;
}
