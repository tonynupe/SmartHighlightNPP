// NppPluginInterfaceMac.h
// Minimal Notepad++ macOS plugin interface header.
// Derived from the public types found in the Notepad++ macOS test harness
// (github.com/notepad-plus-plus-mac/notepad-plus-plus-macos/test_plugins).
//
// Include this header (and Scintilla.h from the scintilla/include/ vendored
// copy) in every macOS Notepad++ plugin.

#pragma once
#include <cstdint>
#include <cstring>

// ── Export macro ─────────────────────────────────────────────────────────────
#define NPP_EXPORT __attribute__((visibility("default")))

// ── Handle / messaging types ─────────────────────────────────────────────────
typedef uintptr_t NppHandle;
typedef intptr_t (*NppSendMessageFunc)(uintptr_t handle,
                                       uint32_t  msg,
                                       uintptr_t wParam,
                                       intptr_t  lParam);

struct NppData {
    NppHandle          _nppHandle;
    NppHandle          _scintillaMainHandle;
    NppHandle          _scintillaSecondHandle;
    NppSendMessageFunc _sendMessage;
};

// ── Keyboard shortcut ─────────────────────────────────────────────────────────
struct ShortcutKey {
    bool          _isCtrl;
    bool          _isAlt;
    bool          _isShift;
    bool          _isCmd;    // Command key (macOS-specific)
    unsigned char _key;
};

// ── Menu item ─────────────────────────────────────────────────────────────────
#define NPP_MENU_ITEM_SIZE 64
typedef void (*PFUNCPLUGINCMD)(void);

struct FuncItem {
    char           _itemName[NPP_MENU_ITEM_SIZE];
    PFUNCPLUGINCMD _pFunc;
    int            _cmdID;
    bool           _init2Check;
    ShortcutKey   *_pShKey;
};

// ── Scintilla notification header (minimal — full struct is in Scintilla.h) ──
struct NotifyHeader {
    uintptr_t hwndFrom;
    uintptr_t idFrom;
    uint32_t  code;
};
struct SCNotification {
    NotifyHeader nmhdr;
    intptr_t     position;
    int          ch;
    int          modifiers;
    int          modificationType;
    const char  *text;
    intptr_t     length;
    intptr_t     linesAdded;
    int          message;
    uintptr_t    wParam;
    intptr_t     lParam;
    intptr_t     line;
    int          foldLevelNow;
    int          foldLevelPrev;
    int          margin;
    int          listType;
    int          x;
    int          y;
    int          token;
    intptr_t     annotationLinesAdded;
    int          updated;
    int          listCompletionMethod;
    int          characterSource;
};

// ── Notepad++ notification codes (subset) ────────────────────────────────────
#define NPPN_FIRST          1000
#define NPPN_READY          (NPPN_FIRST + 1)
#define NPPN_TBMODIFICATION (NPPN_FIRST + 2)
#define NPPN_FILEBEFORECLOSE (NPPN_FIRST + 3)
#define NPPN_FILEOPENED     (NPPN_FIRST + 4)
#define NPPN_FILECLOSED     (NPPN_FIRST + 5)
#define NPPN_FILEBEFOREOPEN (NPPN_FIRST + 6)
#define NPPN_FILEBEFORESAVE (NPPN_FIRST + 7)
#define NPPN_FILESAVED      (NPPN_FIRST + 8)
#define NPPN_SHUTDOWN       (NPPN_FIRST + 9)
#define NPPN_BUFFERACTIVATED (NPPN_FIRST + 10)
#define NPPN_LANGCHANGED    (NPPN_FIRST + 11)

// ── Notepad++ messages (subset) ──────────────────────────────────────────────
#define NPPM_BASE                     1024
#define NPPM_GETCURRENTSCINTILLA      (NPPM_BASE + 4)
#define NPPM_GETPLUGINSCONFIGDIR      (NPPM_BASE + 97)
#define NPPM_GETCURRENTFILENAME       (NPPM_BASE + 38)
#define NPPM_GETFULLCURRENTPATH       (NPPM_BASE + 35)
#define NPPM_MENUCOMMAND              (NPPM_BASE + 48)
#define NPPM_ADDTOOLBARICON_FORDARKMODE (NPPM_BASE + 101)
