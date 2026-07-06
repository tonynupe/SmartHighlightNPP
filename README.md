# SmartHighlightNPP

SmartHighlight plugin for Nextpad++ (macOS), with:
- Dockable panel UI
- DTMF parser with user-friendly debug output
- Nested archive extractor (browse from panel)

## Build (local)

```sh
clang++ -fPIC -dynamiclib -std=c++17 -O2 -Wall -Wextra -fvisibility=hidden \
  -mmacosx-version-min=10.13 -arch arm64 -arch x86_64 \
  -framework Cocoa -framework CoreFoundation \
  -o SmartHighlight_stable.dylib SmartHighlight.mm
```

## Install (local)

Copy plugin binary to:

`~/Library/Application Support/Nextpad++/plugins/CiscoCollab/CiscoCollab.dylib`

## Release artifact

Use `release/SmartHighlightNPP_v1.0.0.zip`.
That zip already contains:

- `CiscoCollab/CiscoCollab.dylib`
