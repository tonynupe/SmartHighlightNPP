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
#define SCI_BEGINUNDOACTION         2078
#define SCI_ENDUNDOACTION           2079
#define SCI_SETTARGETSTART          2190
#define SCI_SETTARGETEND            2192
#define SCI_REPLACETARGET           2194
#define SCI_POSITIONFROMPOINTCLOSE  2023
#define SCI_POSITIONFROMLINE        2167
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

// Scintilla notifications (subset)
#define SCN_UPDATEUI                2007
// Scintilla line-from-position
#define SCI_LINEFROMPOSITION        2166

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

// Keep style-to-indicator mapping explicit to avoid collisions with host/editor slots.
static const int kStyleIndicator[MAX_STYLES] = {
    15, 16, 17, 18, 24, 20, 21, 22, 23, 25
};

static inline int indicatorForStyle(int styleIndex) {
    if (styleIndex < 0 || styleIndex >= MAX_STYLES) styleIndex = 0;
    return kStyleIndicator[styleIndex];
}

static inline int rgb(int r, int g, int b) { return r | (g << 8) | (b << 16); }

static const int kStyleColor[MAX_STYLES] = {
    rgb( 64, 150, 255),   // 0 Vivid blue
    rgb( 78, 196,  92),   // 1 Vivid green
    rgb(245, 154,  52),   // 2 Vivid orange
    rgb(128, 128, 128),   // 3 Neutral gray
    rgb(235, 190,  32),   // 4 Gold (high-visibility Style 5)
    rgb( 45, 190, 190),   // 5 Vivid teal
    rgb(168, 116, 238),   // 6 Vivid violet
    rgb(176, 182,  62),   // 7 Vivid olive
    rgb(228,  74,  74),   // 8 Vivid red
    rgb(204, 126, 170),   // 9 Vivid rose
};

static const char *kStyleNames[MAX_STYLES] = {
    "Blue","Green","Orange","Gray","Slate",
    "Mint","Violet","Olive","Red","Rose"
};

static NSColor *styleNSColor(int i) {
    if (i < 0 || i >= MAX_STYLES) i = 0;
    int c = kStyleColor[i];
    return [NSColor colorWithCalibratedRed:((c)       & 0xFF) / 255.0
                                     green:((c >>  8) & 0xFF) / 255.0
                                      blue:((c >> 16) & 0xFF) / 255.0
                                     alpha:1.0];
}

static NSFont *ccMonoFont(CGFloat size, NSFontWeight weight) {
    if (@available(macOS 10.15, *)) {
        return [NSFont monospacedSystemFontOfSize:size weight:weight];
    }
    NSFont *fallback = [NSFont userFixedPitchFontOfSize:size];
    return fallback ?: [NSFont systemFontOfSize:size];
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

static NSString *ccCiscoUdlXml() {
    return @"<?xml version=\"1.0\" encoding=\"UTF-8\" ?>\n"
           "<NotepadPlus>\n"
           "  <UserLang name=\"CiscoCollab\" ext=\"cfg txt gzo log\" udlVersion=\"2.1\">\n"
           "    <Settings>\n"
           "      <Global caseIgnored=\"no\" allowFoldOfComments=\"no\" foldCompact=\"no\" forcePureLC=\"0\" decimalSeparator=\"0\" />\n"
           "      <Prefix Keywords1=\"no\" Keywords2=\"no\" Keywords3=\"no\" Keywords4=\"no\" Keywords5=\"no\" Keywords6=\"no\" Keywords7=\"no\" Keywords8=\"no\" />\n"
           "    </Settings>\n"
           "    <KeywordLists>\n"
           "      <Keywords name=\"Comments\">00! 01 02 03 04</Keywords>\n"
           "      <Keywords name=\"Numbers, prefix1\">+-[({&lt;</Keywords>\n"
           "      <Keywords name=\"Numbers, prefix2\">|</Keywords>\n"
           "      <Keywords name=\"Numbers, extras1\">.,:/_</Keywords>\n"
           "      <Keywords name=\"Numbers, extras2\">@^*xX</Keywords>\n"
           "      <Keywords name=\"Numbers, suffix1\">])}&gt;|,;*</Keywords>\n"
           "      <Keywords name=\"Numbers, suffix2\">^</Keywords>\n"
           "      <Keywords name=\"Numbers, range\">-</Keywords>\n"
           "      <Keywords name=\"Operators1\">| : , = ( ) [ ] { } &lt; &gt; / \\ + - ^ *</Keywords>\n"
           "      <Keywords name=\"Operators2\"></Keywords>\n"
           "      <Keywords name=\"Folders in code1, open\"></Keywords>\n"
           "      <Keywords name=\"Folders in code1, middle\"></Keywords>\n"
           "      <Keywords name=\"Folders in code1, close\"></Keywords>\n"
           "      <Keywords name=\"Folders in code2, open\"></Keywords>\n"
           "      <Keywords name=\"Folders in code2, middle\"></Keywords>\n"
           "      <Keywords name=\"Folders in code2, close\"></Keywords>\n"
           "      <Keywords name=\"Folders in comment, open\"></Keywords>\n"
           "      <Keywords name=\"Folders in comment, middle\"></Keywords>\n"
           "      <Keywords name=\"Folders in comment, close\"></Keywords>\n"
           "      <Keywords name=\"Keywords1\">access-list access-group extended standard crypto ipsec policy object-group object host static tunnel-group group-policy nat route pool deny permit any RoutePartition Pattern PatternType DialingPattern CallingPartyNumber CalledPartyNumber VoiceMailPilotNumber DisplayName CallingPartyName ConnectedPartyName RouteListName</Keywords>\n"
           "      <Keywords name=\"Keywords2\">INVITE OPTIONS REFER PRACK CANCEL ACK BYE INFO SUBSCRIBE NOTIFY UPDATE REGISTER User-Agent SdlSig-I SdlSig-O SdlSig-D CcT302ToInd StationT302 csf.voicemail csf.cert.utils csf.httpclient</Keywords>\n"
           "      <Keywords name=\"Keywords3\">AuthnRequest InResponseTo SingleSignOnService AssertionConsumerService idpEntityID spEntityID CtiCallRecordingStartedNotify CtiCallRecordingEndedNotify CtiCallAttributeInfoNotify CtiDeviceOpenDeviceReq RequestXmfConnectionMediaForking NotifyXmfConnectionData C_MediaFork_Start MEDIAFORK_Prepare_MediaEstablishedDone MEDIAFORK_Start_StartDone cc_api_call_disconnected mwiTargetDn maxDeskPickupWaitTime DATransformMatch MTPNeededDueToDTMFCapMismatch</Keywords>\n"
           "      <Keywords name=\"Keywords4\">Failed Error ERROR failed fail error AppError SdlError FailureResponse</Keywords>\n"
           "      <Keywords name=\"Keywords5\">party1DTMF party2DTMF MTPInsertionReason SoftKeyEvent SMDMSharedData::findLocalDevice</Keywords>\n"
           "      <Keywords name=\"Keywords6\"></Keywords>\n"
           "      <Keywords name=\"Keywords7\"></Keywords>\n"
           "      <Keywords name=\"Keywords8\"></Keywords>\n"
           "      <Keywords name=\"Delimiters\">00 01 02 03 04 05 06 07 08 09 10 11 12 13 14 15 16 17 18 19 20 21 22 23</Keywords>\n"
           "    </KeywordLists>\n"
           "    <Styles>\n"
           "      <WordsStyle name=\"DEFAULT\"           fgColor=\"202020\" bgColor=\"FFFFFF\" colorStyle=\"1\" fontStyle=\"0\" nesting=\"0\" />\n"
           "      <WordsStyle name=\"COMMENTS\"          fgColor=\"8A8A8A\" bgColor=\"FFFFFF\" colorStyle=\"1\" fontStyle=\"2\" nesting=\"0\" />\n"
           "      <WordsStyle name=\"LINE COMMENTS\"     fgColor=\"8A8A8A\" bgColor=\"FFFFFF\" colorStyle=\"1\" fontStyle=\"2\" nesting=\"0\" />\n"
           "      <WordsStyle name=\"NUMBERS\"           fgColor=\"E06C00\" bgColor=\"FFFFFF\" colorStyle=\"1\" fontStyle=\"1\" nesting=\"0\" />\n"
           "      <WordsStyle name=\"KEYWORDS1\"         fgColor=\"004E98\" bgColor=\"FFFFFF\" colorStyle=\"1\" fontStyle=\"1\" nesting=\"0\" />\n"
           "      <WordsStyle name=\"KEYWORDS2\"         fgColor=\"0D9488\" bgColor=\"FFFFFF\" colorStyle=\"1\" fontStyle=\"1\" nesting=\"0\" />\n"
           "      <WordsStyle name=\"KEYWORDS3\"         fgColor=\"166534\" bgColor=\"FFFFFF\" colorStyle=\"1\" fontStyle=\"1\" nesting=\"0\" />\n"
           "      <WordsStyle name=\"KEYWORDS4\"         fgColor=\"D62828\" bgColor=\"FFFFFF\" colorStyle=\"1\" fontStyle=\"1\" nesting=\"0\" />\n"
           "      <WordsStyle name=\"KEYWORDS5\"         fgColor=\"7C3AED\" bgColor=\"FFFFFF\" colorStyle=\"1\" fontStyle=\"1\" nesting=\"0\" />\n"
           "      <WordsStyle name=\"KEYWORDS6\"         fgColor=\"000000\" bgColor=\"FFFFFF\" colorStyle=\"0\" fontStyle=\"0\" nesting=\"0\" />\n"
           "      <WordsStyle name=\"KEYWORDS7\"         fgColor=\"000000\" bgColor=\"FFFFFF\" colorStyle=\"0\" fontStyle=\"0\" nesting=\"0\" />\n"
           "      <WordsStyle name=\"KEYWORDS8\"         fgColor=\"000000\" bgColor=\"FFFFFF\" colorStyle=\"0\" fontStyle=\"0\" nesting=\"0\" />\n"
           "      <WordsStyle name=\"OPERATORS\"         fgColor=\"C026D3\" bgColor=\"FFFFFF\" colorStyle=\"1\" fontStyle=\"1\" nesting=\"0\" />\n"
           "      <WordsStyle name=\"FOLDER IN CODE1\"   fgColor=\"000000\" bgColor=\"FFFFFF\" fontStyle=\"0\" nesting=\"0\" />\n"
           "      <WordsStyle name=\"FOLDER IN CODE2\"   fgColor=\"000000\" bgColor=\"FFFFFF\" fontStyle=\"0\" nesting=\"0\" />\n"
           "      <WordsStyle name=\"FOLDER IN COMMENT\" fgColor=\"000000\" bgColor=\"FFFFFF\" fontStyle=\"0\" nesting=\"0\" />\n"
           "      <WordsStyle name=\"DELIMITERS1\"       fgColor=\"000000\" bgColor=\"FFFFFF\" fontStyle=\"0\" nesting=\"0\" />\n"
           "      <WordsStyle name=\"DELIMITERS2\"       fgColor=\"000000\" bgColor=\"FFFFFF\" fontStyle=\"0\" nesting=\"0\" />\n"
           "      <WordsStyle name=\"DELIMITERS3\"       fgColor=\"000000\" bgColor=\"FFFFFF\" fontStyle=\"0\" nesting=\"0\" />\n"
           "      <WordsStyle name=\"DELIMITERS4\"       fgColor=\"000000\" bgColor=\"FFFFFF\" fontStyle=\"0\" nesting=\"0\" />\n"
           "      <WordsStyle name=\"DELIMITERS5\"       fgColor=\"000000\" bgColor=\"FFFFFF\" fontStyle=\"0\" nesting=\"0\" />\n"
           "      <WordsStyle name=\"DELIMITERS6\"       fgColor=\"000000\" bgColor=\"FFFFFF\" fontStyle=\"0\" nesting=\"0\" />\n"
           "      <WordsStyle name=\"DELIMITERS7\"       fgColor=\"000000\" bgColor=\"FFFFFF\" fontStyle=\"0\" nesting=\"0\" />\n"
           "      <WordsStyle name=\"DELIMITERS8\"       fgColor=\"000000\" bgColor=\"FFFFFF\" fontStyle=\"0\" nesting=\"0\" />\n"
           "    </Styles>\n"
           "  </UserLang>\n"
           "</NotepadPlus>\n";
}

static NSString *ccNextpadUserDefineLangDir() {
    NSString *home = NSHomeDirectory();
    if (!home || home.length == 0) return nil;
    return [home stringByAppendingPathComponent:@"Library/Application Support/Nextpad++/userDefineLangs"];
}

static void ccShowInfoAlert(NSString *title, NSString *message) {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = title ?: @"CiscoCollab";
        alert.informativeText = message ?: @"";
        [alert addButtonWithTitle:@"OK"];
        [alert runModal];
    });
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

static bool ccRunTaskCapture(NSString *launchPath,
                             NSArray<NSString *> *args,
                             NSString **stdoutText,
                             NSString **stderrText,
                             int *exitCode) {
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm isExecutableFileAtPath:launchPath]) {
        if (stderrText) *stderrText = [NSString stringWithFormat:@"Missing tool: %@", launchPath];
        if (exitCode) *exitCode = -1;
        return false;
    }

    NSPipe *outPipe = [NSPipe pipe];
    NSPipe *errPipe = [NSPipe pipe];
    NSTask *task = [[NSTask alloc] init];
    task.launchPath = launchPath;
    task.arguments = args ?: @[];
    task.standardOutput = outPipe;
    task.standardError = errPipe;

    @try {
        [task launch];
    } @catch (NSException *ex) {
        if (stderrText) *stderrText = [NSString stringWithFormat:@"Failed launching %@: %@", launchPath, ex.reason ?: @"unknown"];
        if (exitCode) *exitCode = -1;
        return false;
    }

    [task waitUntilExit];
    NSData *outData = [[outPipe fileHandleForReading] readDataToEndOfFile];
    NSData *errData = [[errPipe fileHandleForReading] readDataToEndOfFile];
    NSString *out = [[NSString alloc] initWithData:outData encoding:NSUTF8StringEncoding] ?: @"";
    NSString *err = [[NSString alloc] initWithData:errData encoding:NSUTF8StringEncoding] ?: @"";

    if (stdoutText) *stdoutText = out;
    if (stderrText) *stderrText = err;
    if (exitCode) *exitCode = (int)task.terminationStatus;
    return task.terminationStatus == 0;
}

static NSString *ccPrettyPrintXmlFragment(NSString *xmlInput, NSString **errorText) {
    if (!xmlInput || xmlInput.length == 0) {
        if (errorText) *errorText = @"Empty XML input.";
        return nil;
    }

    NSError *parseErr = nil;
    NSXMLDocument *doc = [[NSXMLDocument alloc] initWithXMLString:xmlInput
                                                           options:0
                                                             error:&parseErr];
    if (!doc || parseErr) {
        if (errorText) *errorText = [NSString stringWithFormat:@"XML parse error: %@",
                                     parseErr.localizedDescription ?: @"unknown"];
        return nil;
    }

    NSData *prettyData = [doc XMLDataWithOptions:NSXMLNodePrettyPrint];
    if (!prettyData || prettyData.length == 0) {
        if (errorText) *errorText = @"Failed generating pretty-printed XML.";
        return nil;
    }

    NSString *pretty = [[NSString alloc] initWithData:prettyData encoding:NSUTF8StringEncoding];
    if (!pretty || pretty.length == 0) {
        if (errorText) *errorText = @"Failed converting pretty XML to UTF-8 text.";
        return nil;
    }
    return pretty;
}

static NSString *ccExtractX509Base64FromText(NSString *text) {
    if (!text || text.length == 0) return nil;
    NSError *reErr = nil;
    NSRegularExpression *re = [NSRegularExpression
        regularExpressionWithPattern:@"<(?:ds:)?X509Certificate>\\s*([A-Za-z0-9+/=\\r\\n\\t ]+?)\\s*</(?:ds:)?X509Certificate>"
                         options:(NSRegularExpressionCaseInsensitive | NSRegularExpressionDotMatchesLineSeparators)
                           error:&reErr];
    if (reErr || !re) return nil;
    NSTextCheckingResult *m = [re firstMatchInString:text options:0 range:NSMakeRange(0, text.length)];
    if (!m || [m numberOfRanges] < 2) return nil;
    NSRange rg = [m rangeAtIndex:1];
    if (rg.location == NSNotFound || rg.length == 0) return nil;
    NSString *b64 = [text substringWithRange:rg];
    NSArray<NSString *> *parts = [b64 componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return [parts componentsJoinedByString:@""];
}

static NSString *ccPemFromDer(NSData *der) {
    if (!der || der.length == 0) return nil;
    NSString *b64 = [der base64EncodedStringWithOptions:0];
    if (!b64 || b64.length == 0) return nil;

    NSMutableString *pem = [NSMutableString stringWithString:@"-----BEGIN CERTIFICATE-----\n"];
    NSUInteger idx = 0;
    while (idx < b64.length) {
        NSUInteger chunk = MIN((NSUInteger)64, b64.length - idx);
        [pem appendFormat:@"%@\n", [b64 substringWithRange:NSMakeRange(idx, chunk)]];
        idx += chunk;
    }
    [pem appendString:@"-----END CERTIFICATE-----\n"];
    return pem;
}

static NSString *ccDecodeX509SummaryFromText(NSString *text, NSString **errorText) {
    NSString *b64 = ccExtractX509Base64FromText(text);
    if (!b64 || b64.length == 0) {
        if (errorText) *errorText = @"No <X509Certificate> block found in selected context.";
        return nil;
    }

    NSData *der = [[NSData alloc] initWithBase64EncodedString:b64
                                                      options:NSDataBase64DecodingIgnoreUnknownCharacters];
    if (!der || der.length == 0) {
        if (errorText) *errorText = @"Base64 decode failed for <X509Certificate>.";
        return nil;
    }

    NSString *pem = ccPemFromDer(der);
    if (!pem) {
        if (errorText) *errorText = @"Failed to convert DER certificate into PEM.";
        return nil;
    }

    NSString *tmpPath = [NSTemporaryDirectory() stringByAppendingPathComponent:
                         [NSString stringWithFormat:@"cc_cert_%@.pem", [[NSUUID UUID] UUIDString]]];
    NSError *writeErr = nil;
    BOOL ok = [pem writeToFile:tmpPath atomically:YES encoding:NSUTF8StringEncoding error:&writeErr];
    if (!ok || writeErr) {
        if (errorText) *errorText = [NSString stringWithFormat:@"Failed writing temp PEM: %@",
                                     writeErr.localizedDescription ?: @"unknown"];
        return nil;
    }

    NSString *stdoutStr = nil;
    NSString *stderrStr = nil;
    int code = 0;
    bool ran = ccRunTaskCapture(@"/usr/bin/openssl",
                                @[@"x509", @"-in", tmpPath, @"-noout",
                                  @"-subject", @"-issuer", @"-dates", @"-serial", @"-fingerprint", @"-sha256"],
                                &stdoutStr,
                                &stderrStr,
                                &code);

    [[NSFileManager defaultManager] removeItemAtPath:tmpPath error:nil];

    if (!ran || code != 0) {
        if (errorText) {
            NSString *msg = stderrStr.length ? stderrStr : @"openssl x509 failed";
            *errorText = [NSString stringWithFormat:@"OpenSSL decode failed: %@", msg];
        }
        return nil;
    }

    return stdoutStr ?: @"";
}

static NSString *ccQ850CauseMeaning(int cause) {
    switch (cause) {
        case 1:   return @"Unallocated (unassigned) number";
        case 2:   return @"No route to specified transit network";
        case 3:   return @"No route to destination";
        case 16:  return @"Normal call clearing";
        case 17:  return @"User busy";
        case 18:  return @"No user responding";
        case 19:  return @"No answer from user (user alerted)";
        case 21:  return @"Call rejected";
        case 22:  return @"Number changed";
        case 27:  return @"Destination out of order";
        case 28:  return @"Invalid number format (incomplete number)";
        case 31:  return @"Normal, unspecified";
        case 34:  return @"No circuit/channel available";
        case 38:  return @"Network out of order";
        case 41:  return @"Temporary failure";
        case 42:  return @"Switching equipment congestion";
        case 47:  return @"Resource unavailable, unspecified";
        case 57:  return @"Bearer capability not authorized";
        case 58:  return @"Bearer capability not presently available";
        case 65:  return @"Bearer capability not implemented";
        case 79:  return @"Service or option not implemented, unspecified";
        case 87:  return @"User not member of CUG";
        case 88:  return @"Incompatible destination";
        case 95:  return @"Invalid message, unspecified";
        case 96:  return @"Mandatory information element is missing";
        case 97:  return @"Message type non-existent or not implemented";
        case 98:  return @"Message not compatible with call state";
        case 99:  return @"Information element non-existent or not implemented";
        case 100: return @"Invalid information element contents";
        case 102: return @"Recovery on timer expiry";
        case 111: return @"Protocol error, unspecified";
        case 127: return @"Interworking, unspecified";
        default:  return @"Unknown/unspecified Q.850 cause";
    }
}

static NSString *ccDtmfConfigMeaning(int code) {
    switch (code) {
        case 0: return @"Disabled";
        case 1: return @"BestEffort";
        case 2: return @"Required";
        default: return @"Unknown";
    }
}

static NSString *ccDtmfMethodMeaning(int code) {
    switch (code) {
        case 0: return @"None";
        case 1: return @"InBand";
        case 2: return @"SIP INFO";
        case 3: return @"OOB + RFC2833";
        case 4: return @"KPML";
        default: return @"Unknown";
    }
}

static NSString *ccYesNoString(int value) {
    return value ? @"Yes" : @"No";
}

static bool ccIsLikelyBase64CertLine(const std::string &line) {
    if (line.empty()) return false;
    int useful = 0;
    for (char c : line) {
        if (c == ' ' || c == '\t' || c == '\r' || c == '\n') continue;
        if ((c >= 'A' && c <= 'Z') ||
            (c >= 'a' && c <= 'z') ||
            (c >= '0' && c <= '9') ||
            c == '+' || c == '/' || c == '=') {
            useful++;
            continue;
        }
        return false;
    }
    return useful >= 24;
}

static NSString *ccExtractCertificateCandidateNearPosition(const std::string &doc, intptr_t pos) {
    if (doc.empty() || pos < 0 || pos > (intptr_t)doc.size()) return nil;

    const std::vector<std::pair<std::string, std::string>> tags = {
        {"<ds:X509Certificate>", "</ds:X509Certificate>"},
        {"<X509Certificate>", "</X509Certificate>"},
        {"-----BEGIN CERTIFICATE-----", "-----END CERTIFICATE-----"}
    };

    size_t pivot = (size_t)pos;
    for (const auto &tag : tags) {
        size_t start = doc.rfind(tag.first, pivot);
        if (start == std::string::npos) continue;
        size_t end = doc.find(tag.second, pivot);
        if (end == std::string::npos) continue;
        end += tag.second.size();
        std::string frag = doc.substr(start, end - start);
        return [[NSString alloc] initWithBytes:frag.data()
                                        length:frag.size()
                                      encoding:NSUTF8StringEncoding];
    }
    return nil;
}

static NSString *ccExtractBase64NeighborhoodCertificateCandidate(const std::string &doc, intptr_t pos) {
    if (doc.empty() || pos < 0 || pos > (intptr_t)doc.size()) return nil;

    intptr_t curLineStart = pos;
    while (curLineStart > 0 && doc[(size_t)curLineStart - 1] != '\n') curLineStart--;
    intptr_t curLineEnd = pos;
    while (curLineEnd < (intptr_t)doc.size() && doc[(size_t)curLineEnd] != '\n') curLineEnd++;
    std::string currentLine = doc.substr((size_t)curLineStart, (size_t)(curLineEnd - curLineStart));
    if (!ccIsLikelyBase64CertLine(currentLine)) return nil;

    intptr_t blockStart = curLineStart;
    intptr_t probeStart = curLineStart;
    while (probeStart > 0) {
        intptr_t prevEnd = probeStart - 1;
        intptr_t prevStart = prevEnd;
        while (prevStart > 0 && doc[(size_t)prevStart - 1] != '\n') prevStart--;
        std::string prevLine = doc.substr((size_t)prevStart, (size_t)(prevEnd - prevStart));
        if (!ccIsLikelyBase64CertLine(prevLine)) break;
        blockStart = prevStart;
        probeStart = prevStart;
    }

    intptr_t blockEnd = curLineEnd;
    intptr_t probeEnd = curLineEnd;
    while (probeEnd < (intptr_t)doc.size()) {
        intptr_t nextStart = probeEnd;
        if (nextStart < (intptr_t)doc.size() && doc[(size_t)nextStart] == '\n') nextStart++;
        if (nextStart >= (intptr_t)doc.size()) break;
        intptr_t nextEnd = nextStart;
        while (nextEnd < (intptr_t)doc.size() && doc[(size_t)nextEnd] != '\n') nextEnd++;
        std::string nextLine = doc.substr((size_t)nextStart, (size_t)(nextEnd - nextStart));
        if (!ccIsLikelyBase64CertLine(nextLine)) break;
        blockEnd = nextEnd;
        probeEnd = nextEnd;
    }

    std::string block = doc.substr((size_t)blockStart, (size_t)(blockEnd - blockStart));
    NSString *text = [[NSString alloc] initWithBytes:block.data() length:block.size() encoding:NSUTF8StringEncoding];
    if (!text || text.length == 0) return nil;
    NSArray<NSString *> *parts = [text componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSString *b64 = [parts componentsJoinedByString:@""];
    if (b64.length == 0) return nil;
    return [NSString stringWithFormat:@"<ds:X509Certificate>%@</ds:X509Certificate>", b64];
}

static bool ccFixDirectoryPermissions(NSString *path, NSString **errorText) {
    return ccRunTask(@"/bin/chmod", @[@"-R", @"u+w", path], errorText);
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
static bool                                         gCiscoNativeLanguageEnabled = false;
static uintptr_t                                    gLastParsedHandle = 0;
static intptr_t                                     gLastParsedLineStart = -1;
static std::string                                  gLastParsedLineText;
static uintptr_t                                    gLastCaretHandle = 0;
static intptr_t                                     gLastCaretLineNum = -1;

// Residual Cisco overlay cleaner. Native Cisco coloring now comes from the UDL.
static const int CC_NUM_STYLES = 7;
static const int CC_IND_BASE   = 30;

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
        int ind = indicatorForStyle(i);
        sci(h, SCI_INDICSETSTYLE,        ind, INDIC_STRAIGHTBOX);
        sci(h, SCI_INDICSETFORE,         ind, kStyleColor[i]);
        sci(h, SCI_INDICSETALPHA,        ind, 115);
        sci(h, SCI_INDICSETOUTLINEALPHA, ind, 245);
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
    clearIndicator(h, indicatorForStyle(i));
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

static void ccClearNativeLanguageFromCurrentDocument() {
    NppHandle h = curScintilla();
    if (!h) return;
    for (int i = 0; i < CC_NUM_STYLES; i++)
        clearIndicator(h, CC_IND_BASE + i);
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
        jobs->push_back({indicatorForStyle(e.styleIndex), e.pattern});
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
        auto it = gIndicatorStarts.find(indicatorForStyle(i));
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

// Custom NSTableView that handles DEL key for deleting rows
@interface CustomHighlightTableView : NSTableView
@property (assign) NSObject *deleteDelegate;
@end

@implementation CustomHighlightTableView
- (void)keyDown:(NSEvent *)event {
    NSUInteger flags = event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask;
    
    // Check for Delete key (keyCode 51)
    if (event.keyCode == 51 && flags == 0) {
        if (self.deleteDelegate && [self.deleteDelegate respondsToSelector:@selector(actionDelete:)]) {
            [self.deleteDelegate performSelector:@selector(actionDelete:) withObject:nil];
        }
        return;
    }
    
    [super keyDown:event];
}
@end

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
@property (strong) NSButton           *btnDebugWrap;
@property (strong) NSButton           *btnSamlFormat;
@property (strong) NSButton           *btnExtractNested;
@property (strong) NSTextView         *debugTextView;
@property (assign) BOOL               debugWrapEnabled;

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
- (void)updateDebugWrapUI;
- (BOOL)autoParseRelevantAtPosition:(intptr_t)pos inHandle:(NppHandle)h;
@end

@implementation CCPanelController

- (instancetype)init {
    self = [super init];
    if (self) [self buildPanel];
    return self;
}

- (void)buildPanel {
    NSRect fr = NSMakeRect(120, 120, 420, 620);
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
    _panel.minSize = NSMakeSize(320, 420);
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

    _tableView = [[CustomHighlightTableView alloc] initWithFrame:NSZeroRect];
    ((CustomHighlightTableView *)_tableView).deleteDelegate = self;
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
                                                                            tip:@"Analyze DTMF/Cert in selection"];
        _btnSamlFormat = [self makeIconButton:@"doc.text"
                                                                 fallback:@"SAML"
                                                                     action:@selector(actionSamlFormat:)
                                                                            tip:@"Pretty print selected SAML/XML block"];
    _btnDebugClear = [self makeIconButton:@"eraser"
                                 fallback:@"Clr"
                                   action:@selector(actionDebugClear:)
                                      tip:@"Clear debug log"];
        _btnDebugWrap = [NSButton buttonWithTitle:@"Wrap Off"
                                                                             target:self
                                                                             action:@selector(actionDebugWrap:)];
        _btnDebugWrap.bezelStyle = NSBezelStyleTexturedRounded;
        _btnDebugWrap.font = [NSFont systemFontOfSize:10 weight:NSFontWeightSemibold];
        _btnDebugWrap.toolTip = @"Toggle line wrapping in debug output";
        _btnDebugWrap.translatesAutoresizingMaskIntoConstraints = NO;
        [_btnDebugWrap.widthAnchor constraintGreaterThanOrEqualToConstant:70].active = YES;
        [_btnDebugWrap.heightAnchor constraintEqualToConstant:26].active = YES;
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
        _btnSamlFormat,
        _btnDebugWrap,
        _btnDebugClear
    ]];
    bottomRow.spacing = 4;
    bottomRow.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    bottomRow.distribution = NSStackViewDistributionFillEqually;
    bottomRow.translatesAutoresizingMaskIntoConstraints = NO;

    NSScrollView *debugScroll = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    debugScroll.translatesAutoresizingMaskIntoConstraints = NO;
    debugScroll.hasVerticalScroller = YES;
    debugScroll.hasHorizontalScroller = YES;
    debugScroll.autohidesScrollers = YES;
    debugScroll.scrollerStyle = NSScrollerStyleOverlay;
    debugScroll.drawsBackground = YES;
    debugScroll.backgroundColor = [NSColor colorWithCalibratedWhite:0.98 alpha:1.0];

    _debugTextView = [[NSTextView alloc] initWithFrame:NSZeroRect];
    _debugTextView.editable = NO;
    _debugTextView.selectable = YES;
    _debugTextView.richText = YES;
    _debugTextView.font = ccMonoFont(12, NSFontWeightRegular);
    _debugTextView.textContainerInset = NSMakeSize(8, 8);
    _debugTextView.automaticQuoteSubstitutionEnabled = NO;
    _debugTextView.automaticDashSubstitutionEnabled = NO;
    _debugTextView.automaticTextReplacementEnabled = NO;
    _debugTextView.backgroundColor = [NSColor colorWithCalibratedWhite:0.98 alpha:1.0];
    _debugTextView.horizontallyResizable = YES;
    _debugTextView.verticallyResizable = YES;
    if (_debugTextView.textContainer) {
        _debugTextView.textContainer.widthTracksTextView = NO;
        _debugTextView.textContainer.containerSize = NSMakeSize(CGFLOAT_MAX, CGFLOAT_MAX);
        _debugTextView.textContainer.lineFragmentPadding = 0.0;
    }
    self.debugWrapEnabled = NO;
    [self updateDebugWrapUI];

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
    [split setPosition:240 ofDividerAtIndex:0];
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

        NSFont *monoFont = ccMonoFont(12, NSFontWeightRegular);
        NSMutableParagraphStyle *para = [[NSMutableParagraphStyle alloc] init];
        para.lineSpacing = 2.0;

        NSMutableDictionary *baseAttrs = [@{
            NSForegroundColorAttributeName: [NSColor colorWithCalibratedWhite:0.13 alpha:1.0],
            NSFontAttributeName: monoFont,
            NSParagraphStyleAttributeName: para
        } mutableCopy];

        NSString *finalLine = [line stringByAppendingString:@"\n"];
        NSMutableAttributedString *entry = [[NSMutableAttributedString alloc] initWithString:finalLine
                                                                                   attributes:baseAttrs];

        NSRange closeBracket = [line rangeOfString:@"]"];
        if ([line hasPrefix:@"["] && closeBracket.location != NSNotFound) {
            NSRange tagRange = NSMakeRange(0, closeBracket.location + 1);
            NSString *tag = [[line substringWithRange:tagRange] lowercaseString];
            NSColor *tagColor = [NSColor colorWithCalibratedRed:0.27 green:0.38 blue:0.55 alpha:1.0];

            if ([tag containsString:@"[cert]"]) {
                tagColor = [NSColor colorWithCalibratedRed:0.15 green:0.45 blue:0.28 alpha:1.0];
            } else if ([tag containsString:@"[dtmf]"]) {
                tagColor = [NSColor colorWithCalibratedRed:0.13 green:0.33 blue:0.68 alpha:1.0];
            } else if ([tag containsString:@"[extract]"]) {
                tagColor = [NSColor colorWithCalibratedRed:0.55 green:0.35 blue:0.09 alpha:1.0];
            } else if ([tag containsString:@"[sip]"]) {
                tagColor = [NSColor colorWithCalibratedRed:0.58 green:0.16 blue:0.44 alpha:1.0];
            } else if ([tag containsString:@"[debug]"]) {
                tagColor = [NSColor colorWithCalibratedRed:0.35 green:0.35 blue:0.35 alpha:1.0];
            }

            [entry addAttribute:NSForegroundColorAttributeName value:tagColor range:tagRange];
            [entry addAttribute:NSFontAttributeName
                          value:ccMonoFont(12, NSFontWeightSemibold)
                          range:tagRange];
        }

        NSTextStorage *ts = _debugTextView.textStorage;
        if (!ts) return;
        [ts appendAttributedString:entry];
        [_debugTextView scrollRangeToVisible:NSMakeRange(ts.length, 0)];
    });
}

- (void)updateDebugWrapUI {
    if (!_debugTextView) return;

    self.btnDebugWrap.title = self.debugWrapEnabled ? @"Wrap On" : @"Wrap Off";

    _debugTextView.horizontallyResizable = !self.debugWrapEnabled;
    if (_debugTextView.textContainer) {
        _debugTextView.textContainer.widthTracksTextView = self.debugWrapEnabled;
        _debugTextView.textContainer.containerSize = self.debugWrapEnabled
            ? NSMakeSize(_debugTextView.bounds.size.width, CGFLOAT_MAX)
            : NSMakeSize(CGFLOAT_MAX, CGFLOAT_MAX);
    }

    NSScrollView *sv = _debugTextView.enclosingScrollView;
    if (sv) {
        sv.hasHorizontalScroller = !self.debugWrapEnabled;
    }
}

- (void)actionDebugWrap:(id)sender {
    (void)sender;
    self.debugWrapEnabled = !self.debugWrapEnabled;
    [self updateDebugWrapUI];
}

- (void)actionSamlFormat:(id)sender {
    (void)sender;
    NppHandle h = curScintilla();
    if (!h) {
        [self appendDebugLine:@"[saml] No active editor handle."];
        return;
    }

    std::string doc = getDocumentText(h);
    if (doc.empty()) {
        [self appendDebugLine:@"[saml] Document is empty."];
        return;
    }

    intptr_t selS = sci(h, SCI_GETSELECTIONSTART);
    intptr_t selE = sci(h, SCI_GETSELECTIONEND);
    if (selE <= selS || selS < 0 || selE > (intptr_t)doc.size()) {
        [self appendDebugLine:@"[saml] Select XML/SAML block first."];
        return;
    }

    std::string selected = doc.substr((size_t)selS, (size_t)(selE - selS));
    NSString *selectedText = [[NSString alloc] initWithBytes:selected.data()
                                                      length:selected.size()
                                                    encoding:NSUTF8StringEncoding];
    if (!selectedText || selectedText.length == 0) {
        [self appendDebugLine:@"[saml] Selection is not valid UTF-8 text."];
        return;
    }

    NSRange firstLt = [selectedText rangeOfString:@"<"];
    NSRange lastGt = [selectedText rangeOfString:@">" options:NSBackwardsSearch];
    if (firstLt.location == NSNotFound || lastGt.location == NSNotFound || lastGt.location <= firstLt.location) {
        [self appendDebugLine:@"[saml] No XML fragment detected in selection."];
        return;
    }

    NSRange xmlRange = NSMakeRange(firstLt.location, (lastGt.location - firstLt.location + 1));
    NSString *xmlFragment = [selectedText substringWithRange:xmlRange];

    NSString *fmtErr = nil;
    NSString *prettyXml = ccPrettyPrintXmlFragment(xmlFragment, &fmtErr);
    if (!prettyXml || prettyXml.length == 0) {
        [self appendDebugLine:[NSString stringWithFormat:@"[saml] %@", fmtErr ?: @"Failed to format XML."]];
        return;
    }

    NSString *prefix = [selectedText substringToIndex:xmlRange.location];
    NSString *suffix = [selectedText substringFromIndex:(xmlRange.location + xmlRange.length)];
    NSString *trimPrefix = [prefix stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSString *trimSuffix = [suffix stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];

    NSMutableString *replacement = [NSMutableString string];
    if (trimPrefix.length > 0) {
        [replacement appendString:prefix];
        if (![prefix hasSuffix:@"\n"]) [replacement appendString:@"\n"];
    }
    [replacement appendString:prettyXml];
    if (trimSuffix.length > 0) {
        if (![replacement hasSuffix:@"\n"]) [replacement appendString:@"\n"];
        [replacement appendString:suffix];
    }

    NSData *repData = [replacement dataUsingEncoding:NSUTF8StringEncoding];
    if (!repData) {
        [self appendDebugLine:@"[saml] Failed to encode formatted XML as UTF-8."];
        return;
    }

    sci(h, SCI_BEGINUNDOACTION);
    sci(h, SCI_SETTARGETSTART, (uintptr_t)selS, 0);
    sci(h, SCI_SETTARGETEND, (uintptr_t)selE, 0);
    sci(h, SCI_REPLACETARGET, repData.length, (intptr_t)repData.bytes);
    sci(h, SCI_ENDUNDOACTION);

    [self appendDebugLine:@"[saml] Pretty print applied to selected XML block."];
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
            
            // Fix permissions on extracted directory
            NSString *permErr = nil;
            if (!ccFixDirectoryPermissions(topOutput, &permErr)) {
                [self appendDebugLine:[NSString stringWithFormat:@"[extract] Warning: could not fix permissions on %@", topOutput]];
            }

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
                    NSString *lower = [p lowercaseString];
                    
                    // Skip .gzo (open files)
                    if ([lower hasSuffix:@".gzo"]) continue;
                    
                    // Handle plain .gz files: extract to parent directory, don't recurse
                    if ([lower hasSuffix:@".gz"] && ![lower hasSuffix:@".tar.gz"] && ![lower hasSuffix:@".tgz"]) {
                        NSString *parentDir = [p stringByDeletingLastPathComponent];
                        NSString *gzErr = nil;
                        if (ccExtractGzipFile(p, parentDir, &gzErr)) {
                            [fm removeItemAtPath:p error:nil];
                            [self appendDebugLine:[NSString stringWithFormat:@"[extract] Nested: %@ -> extracted", [p lastPathComponent]]];
                        } else {
                            [self appendDebugLine:[NSString stringWithFormat:@"[extract] Nested failed (%@): %@", [p lastPathComponent], gzErr ?: @"unknown"]];
                        }
                        continue;
                    }
                    
                    // Only process archive containers (.zip, .tar, .tar.gz, .tgz, .7z, .rar)
                    if (!ccIsSupportedArchivePath(p)) continue;

                    NSString *nestedOut = ccUniqueNestedOutputDir(p);
                    NSString *nestedErr = nil;
                    if (ccExtractArchiveToDirectory(p, nestedOut, &nestedErr)) {
                        // Fix permissions on nested extracted directory
                        NSString *nestedPermErr = nil;
                        if (!ccFixDirectoryPermissions(nestedOut, &nestedPermErr)) {
                            [self appendDebugLine:[NSString stringWithFormat:@"[extract] Warning: could not fix permissions on nested %@", nestedOut]];
                        }
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

    // Try certificate decode first (SAML/XML X509 blocks), then fallback to DTMF.
    NSString *ctxText = [[NSString alloc] initWithBytes:context.data()
                                                 length:context.size()
                                               encoding:NSUTF8StringEncoding];
    NSString *certErr = nil;
    NSString *certSummary = ccDecodeX509SummaryFromText(ctxText, &certErr);

    if (!certSummary) {
        // Fallback: search the full document in case current selection/line is partial.
        NSString *docText = [[NSString alloc] initWithBytes:doc.data()
                                                     length:doc.size()
                                                   encoding:NSUTF8StringEncoding];
        certSummary = ccDecodeX509SummaryFromText(docText, &certErr);
    }

    if (certSummary && certSummary.length > 0) {
        [self appendParserSeparator:@"cert"];
        [self appendParserSection:@"cert" title:@"X509 Certificate (SAML/XML)"];

        NSArray<NSString *> *lines = [certSummary componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
        NSInteger shown = 0;
        for (NSString *line in lines) {
            if (line.length == 0) continue;
            [self appendDebugLine:[NSString stringWithFormat:@"[cert]   %@", line]];
            shown++;
            if (shown >= 40) {
                [self appendDebugLine:@"[cert]   ...(output truncated)"];
                break;
            }
        }
        return;
    }

        std::string clipped = context.substr(0, std::min<size_t>(context.size(), 180));
        [self appendParserField:@"dtmf"
                                                key:@"context"
                                            value:[NSString stringWithUTF8String:clipped.c_str()]];

    bool foundAny = false;

    // SIP Reason parser: Reason: Q.850;cause=<n>;text=...
    try {
        std::regex q850Re(R"((Reason\s*:\s*Q\.850\s*;\s*cause\s*=\s*(\d+)(?:\s*;\s*text\s*=\s*\"?([^\"\r\n;]*)\"?)?))",
                          std::regex_constants::icase);
        auto sBegin = std::sregex_iterator(context.begin(), context.end(), q850Re);
        auto sEnd = std::sregex_iterator();
        for (auto it = sBegin; it != sEnd; ++it) {
            foundAny = true;
            std::smatch mm = *it;
            int cause = std::stoi(mm.str(2));
            NSString *meaning = ccQ850CauseMeaning(cause);

            [self appendParserSeparator:@"sip"];
            [self appendParserSection:@"sip" title:@"SIP Reason (Q.850)"];
            [self appendParserField:@"sip"
                                key:@"header"
                              value:[NSString stringWithUTF8String:mm.str(1).c_str()]];
            [self appendParserField:@"sip"
                                key:@"cause"
                              value:[NSString stringWithFormat:@"%d", cause]];
            [self appendParserField:@"sip"
                                key:@"meaning"
                              value:meaning ?: @"Unknown"];

            if (mm.size() >= 4 && !mm.str(3).empty()) {
                [self appendParserField:@"sip"
                                    key:@"text"
                                  value:[NSString stringWithUTF8String:mm.str(3).c_str()]];
            }
        }
    } catch (...) {
        [self appendDebugLine:@"[sip] Parser error while evaluating Q.850 reason header."];
    }

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

- (BOOL)autoParseRelevantAtPosition:(intptr_t)pos inHandle:(NppHandle)h {
    if (!h || pos < 0) return NO;

    std::string doc = getDocumentText(h);
    if (doc.empty() || pos >= (intptr_t)doc.size()) return NO;

    intptr_t lineStart = pos;
    while (lineStart > 0 && doc[(size_t)lineStart - 1] != '\n') lineStart--;

    intptr_t lineEnd = pos;
    while (lineEnd < (intptr_t)doc.size() && doc[(size_t)lineEnd] != '\n') lineEnd++;

    if (lineEnd <= lineStart) return NO;
    std::string line = doc.substr((size_t)lineStart, (size_t)(lineEnd - lineStart));
    if (line.empty()) return NO;

    // Dedupe: skip if we already emitted for this exact line.
    if (gLastParsedHandle == (uintptr_t)h &&
        gLastParsedLineStart == lineStart &&
        gLastParsedLineText == line) {
        return NO;
    }

    bool hasQ850 = false;
    bool hasDtmf = false;
    bool hasCert = false;
    try {
        hasQ850 = std::regex_search(line, std::regex(R"(Reason\s*:\s*Q\.850\s*;\s*cause\s*=\s*\d+)", std::regex_constants::icase));
        hasDtmf = std::regex_search(line, std::regex(R"((party[12]DTMF\(|\bdtmf\b|\bkpml\b|rfc\s*2833|sip\s*info))", std::regex_constants::icase));
    } catch (...) {
        return NO;
    }
    hasCert = (line.find("X509Certificate") != std::string::npos ||
               line.find("BEGIN CERTIFICATE") != std::string::npos ||
               ccIsLikelyBase64CertLine(line));

    if (!(hasQ850 || hasDtmf || hasCert)) return NO;

    bool emitted = false;

    if (hasQ850) {
        const std::string &q850Text = line;
        try {
            std::regex q850Re(R"((Reason\s*:\s*Q\.850\s*;\s*cause\s*=\s*(\d+)(?:\s*;\s*text\s*=\s*\"?([^\"\r\n;]*)\"?)?))",
                              std::regex_constants::icase);
            auto sBegin = std::sregex_iterator(q850Text.begin(), q850Text.end(), q850Re);
            auto sEnd = std::sregex_iterator();
            for (auto it = sBegin; it != sEnd; ++it) {
                std::smatch mm = *it;
                int cause = std::stoi(mm.str(2));
                emitted = true;
                [self appendParserSeparator:@"sip"];
                [self appendParserSection:@"sip" title:@"SIP Reason (Q.850)"];
                [self appendParserField:@"sip" key:@"cause" value:[NSString stringWithFormat:@"%d", cause]];
                [self appendParserField:@"sip" key:@"meaning" value:ccQ850CauseMeaning(cause)];
                if (mm.size() >= 4 && !mm.str(3).empty()) {
                    [self appendParserField:@"sip"
                                        key:@"text"
                                      value:[NSString stringWithUTF8String:mm.str(3).c_str()]];
                }
            }
        } catch (...) {}
    }

    if (hasDtmf) {
        const std::string &dtmfText = line;
        try {
            std::regex tupleRe(R"((party[12]DTMF)\(\s*(\d+)\s+(\d+)\s+\(([^)]*)\)\s+(\d+)\s+(\d+)\s*\))",
                              std::regex_constants::icase);
            auto begin = std::sregex_iterator(dtmfText.begin(), dtmfText.end(), tupleRe);
            auto end = std::sregex_iterator();
            if (begin != end) {
                emitted = true;
                [self appendParserSeparator:@"dtmf"];
                [self appendParserSection:@"dtmf" title:@"DTMF"];
                int idx = 0;
                for (auto it = begin; it != end; ++it) {
                    idx++;
                    std::smatch m = *it;
                                        int enabled = std::stoi(m.str(2));
                                        int method = std::stoi(m.str(3));
                                        int flag1 = std::stoi(m.str(5));
                                        int flag2 = std::stoi(m.str(6));
                    NSString *partyKey = (idx == 1)
                        ? @"party"
                        : [NSString stringWithFormat:@"party[%d]", idx];
                    [self appendParserField:@"dtmf"
                                        key:partyKey
                                      value:[NSString stringWithUTF8String:m.str(1).c_str()]];
                    [self appendParserField:@"dtmf"
                                                                                key:(idx == 1 ? @"dtmf config" : [NSString stringWithFormat:@"dtmf cfg[%d]", idx])
                                                                            value:[NSString stringWithFormat:@"%@ (%d)", ccDtmfConfigMeaning(enabled), enabled]];
                                        [self appendParserField:@"dtmf"
                                                                                key:(idx == 1 ? @"dtmf method" : [NSString stringWithFormat:@"dtmf method[%d]", idx])
                                                                            value:[NSString stringWithFormat:@"%@ (%d)", ccDtmfMethodMeaning(method), method]];
                    [self appendParserField:@"dtmf"
                                        key:(idx == 1 ? @"payload spec" : [NSString stringWithFormat:@"payload[%d]", idx])
                                      value:[NSString stringWithUTF8String:m.str(4).c_str()]];
                                        [self appendParserField:@"dtmf"
                                                                                key:(idx == 1 ? @"wantDTMFreception" : [NSString stringWithFormat:@"wantRx[%d]", idx])
                                                                            value:ccYesNoString(flag1)];
                                        [self appendParserField:@"dtmf"
                                                                                key:(idx == 1 ? @"provideOOB" : [NSString stringWithFormat:@"provideOOB[%d]", idx])
                                                                            value:ccYesNoString(flag2)];
                }
            } else {
                [self appendDebugLine:@"[dtmf] DTMF markers detected (use Parse for full breakdown)."];
            }
        } catch (...) {}
    }

    if (hasCert) {
        NSString *candidate = ccExtractCertificateCandidateNearPosition(doc, pos);
        if ((!candidate || candidate.length == 0) && ccIsLikelyBase64CertLine(line)) {
            candidate = ccExtractBase64NeighborhoodCertificateCandidate(doc, pos);
        }
        if (!candidate || candidate.length == 0) {
            candidate = [[NSString alloc] initWithBytes:line.data()
                                                 length:line.size()
                                               encoding:NSUTF8StringEncoding];
        }

        NSString *err = nil;
        NSString *summary = ccDecodeX509SummaryFromText(candidate, &err);
        if ((!summary || summary.length == 0) && hasCert) {
            NSString *docText = [[NSString alloc] initWithBytes:doc.data()
                                                         length:doc.size()
                                                       encoding:NSUTF8StringEncoding];
            summary = ccDecodeX509SummaryFromText(docText, &err);
        }
        if (summary.length > 0) {
            emitted = true;
            [self appendParserSeparator:@"cert"];
            [self appendParserSection:@"cert" title:@"X509 Certificate"];
            NSArray<NSString *> *lines = [summary componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
            NSInteger shown = 0;
            for (NSString *one in lines) {
                if (one.length == 0) continue;
                [self appendDebugLine:[NSString stringWithFormat:@"[cert]   %@", one]];
                shown++;
                if (shown >= 8) {
                    [self appendDebugLine:@"[cert]   ...(use Parse for full output)"];
                    break;
                }
            }
        } else if (err.length > 0) {
            [self appendDebugLine:[NSString stringWithFormat:@"[cert] Certificate-like content detected but could not decode: %@", err]];
        }
    }

    if (emitted) {
        gLastParsedHandle = (uintptr_t)h;
        gLastParsedLineStart = lineStart;
        gLastParsedLineText = line;
    }
    return emitted ? YES : NO;
}

- (void)actionDebugClear:(id)sender {
    (void)sender;
    gLastParsedHandle = 0;
    gLastParsedLineStart = -1;
    gLastParsedLineText.clear();
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

static void cmd_installCiscoUdlLanguage() {
    @autoreleasepool {
        NSString *dir = ccNextpadUserDefineLangDir();
        if (!dir) {
            ccShowInfoAlert(@"CiscoCollab Language",
                            @"No se pudo resolver el directorio userDefineLangs.");
            return;
        }

        NSError *mkdirErr = nil;
        [[NSFileManager defaultManager] createDirectoryAtPath:dir
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:&mkdirErr];
        if (mkdirErr) {
            ccShowInfoAlert(@"CiscoCollab Language",
                            [NSString stringWithFormat:@"No se pudo crear %@\n%@",
                             dir, mkdirErr.localizedDescription ?: @"error desconocido"]);
            return;
        }

        NSString *path = [dir stringByAppendingPathComponent:@"CiscoCollab.xml"];
        NSError *writeErr = nil;
        BOOL ok = [ccCiscoUdlXml() writeToFile:path
                                     atomically:YES
                                       encoding:NSUTF8StringEncoding
                                          error:&writeErr];
        if (!ok || writeErr) {
            ccShowInfoAlert(@"CiscoCollab Language",
                            [NSString stringWithFormat:@"No se pudo escribir %@\n%@",
                             path, writeErr.localizedDescription ?: @"error desconocido"]);
            return;
        }

        NSString *msg = [NSString stringWithFormat:
            @"Lenguaje CiscoCollab instalado/actualizado en:\n%@\n\n"
             "Luego en Nextpad++ selecciona:\nLanguage -> CiscoCollab\n\n"
             "Si no aparece, reinicia Nextpad++.", path];
        ccShowInfoAlert(@"CiscoCollab Language", msg);
    }
}

static void cmd_toggleCiscoColoring() {
    gCiscoNativeLanguageEnabled = false;
    ccClearNativeLanguageFromCurrentDocument();
}

// Plugin exports
static const int NB_FUNC = 3;
static FuncItem  g_funcItem[NB_FUNC];
static ShortcutKey g_sk[2];
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
    g_sk[1] = {true, false, false, true, (unsigned char)'C'};
    addItem("Clear Cisco Overlay", cmd_toggleCiscoColoring, &g_sk[1]);
    addItem("Install/Update Cisco Language (UDL)", cmd_installCiscoUdlLanguage, nullptr);
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
            // Clear any leftover Cisco indicators from previous sessions
            for (int i = 0; i < CC_NUM_STYLES; i++) {
                clearIndicator(g_nppData._scintillaMainHandle,   CC_IND_BASE + i);
                clearIndicator(g_nppData._scintillaSecondHandle, CC_IND_BASE + i);
            }
            requestDeferredApply(12);
            // NOTE: Do NOT call showPanel() here - it can cause startup crashes.
            // Panel is shown only via manual menu trigger (cmd_showPanel).
            break;
        case NPPN_BUFFERACTIVATED:
        case NPPN_FILEOPENED:
            requestDeferredApply(6);
            gLastParsedHandle = 0;
            gLastParsedLineStart = -1;
            gLastParsedLineText.clear();
            gLastCaretHandle = 0;
            gLastCaretLineNum = -1;
            for (int i = 0; i < CC_NUM_STYLES; i++)
                clearIndicator(curScintilla(), CC_IND_BASE + i);
            break;
        case SCN_UPDATEUI:
            if (gPanel) {
                NppHandle h = curScintilla();
                if (h) {
                    intptr_t caretPos = sci(h, SCI_GETCURRENTPOS, 0, 0);
                    if (caretPos >= 0) {
                        intptr_t lineNum = sci(h, SCI_LINEFROMPOSITION, (uintptr_t)caretPos, 0);
                        if (gLastCaretHandle != (uintptr_t)h || gLastCaretLineNum != lineNum) {
                            gLastCaretHandle = (uintptr_t)h;
                            gLastCaretLineNum = lineNum;
                            // Reset parse dedupe so auto-parse runs fresh on each new line.
                            gLastParsedHandle = 0;
                            gLastParsedLineStart = -1;
                            gLastParsedLineText.clear();
                            [gPanel autoParseRelevantAtPosition:caretPos inHandle:h];
                        }
                    }
                }
            }
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
