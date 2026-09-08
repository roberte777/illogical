# Embedded fonts

The app ships its default font rather than taking whatever
`.userFixedPitch` hands back, so a fresh install looks right without the
user installing anything — and it ships the Nerd Font symbols beside it, so
the icons Neovim's plugins draw with look right too. libghostty does the
same thing with the same files — see `src/font/embedded.zig` and
`src/font/SharedGridSet.zig` in `vendor/ghostty`, and its warning, which
applies here too:

> Be careful to ensure that any fonts you embed are licensed for
> redistribution and include their license as necessary.

`OFL.txt` and `NerdFonts-LICENSE.txt` are copied into the bundle alongside
the fonts. This README is excluded from it — see `excludes` in
`clients/macos/project.yml`.

## JetBrains Mono

Both files are the **variable** faces, byte-for-byte out of the tarball
ghostty pins:

    https://deps.files.ghostty.org/JetBrainsMono-2.304.tar.gz
    sha256-xXppHouCrQmLWWPzlZAy5AOPORCHr3cViFulkEYQXMQ=

which is the `.jetbrains_mono` dependency in `vendor/ghostty/build.zig.zon`,
at the same version. `build.zig.zon` itself carries Zig's own multihash; the
base64 SRI quoted above is the one in `build.zig.zon.json` beside it. To
refresh them:

```bash
curl -sSLO https://deps.files.ghostty.org/JetBrainsMono-2.304.tar.gz
# Base64 SRI, which is not what `shasum` prints. Must match the hash above.
openssl dgst -sha256 -binary JetBrainsMono-2.304.tar.gz | base64
tar xzf JetBrainsMono-2.304.tar.gz 'fonts/variable/*' OFL.txt
```

| File | Tarball path |
| --- | --- |
| `JetBrainsMono[wght].ttf` | `fonts/variable/JetBrainsMono[wght].ttf` |
| `JetBrainsMono-Italic[wght].ttf` | `fonts/variable/JetBrainsMono-Italic[wght].ttf` |
| `OFL.txt` | `OFL.txt` |

Two files, not four. Bold is the regular face with the `wght` axis pinned
to 700 and bold-italic is the italic face with the same, which is what
ghostty does and why the static `JetBrainsMono-Bold.ttf` and friends are
not here.

## Nerd Fonts Symbols Only

The icons, as a face of their own rather than a patched JetBrains Mono.
That is ghostty's arrangement, and the reason is the fallback order: the
symbols go behind every configured family, so the icons survive the user
naming a font of their own. Byte-for-byte out of the tarball ghostty pins:

    https://deps.files.ghostty.org/NerdFontsSymbolsOnly-3.4.0.tar.gz
    sha256-EWTRuVbUveJI17LwmYxDzJT1ICQxoVZKeTiVsec7DQQ=

which is the `.nerd_fonts_symbols_only` dependency in
`vendor/ghostty/build.zig.zon`, at the same version, and again quoted from
`build.zig.zon.json` rather than from the multihash beside it. To refresh:

```bash
curl -sSLO https://deps.files.ghostty.org/NerdFontsSymbolsOnly-3.4.0.tar.gz
# Base64 SRI, which is not what `shasum` prints. Must match the hash above.
openssl dgst -sha256 -binary NerdFontsSymbolsOnly-3.4.0.tar.gz | base64
tar xzf NerdFontsSymbolsOnly-3.4.0.tar.gz SymbolsNerdFont-Regular.ttf LICENSE
mv LICENSE NerdFonts-LICENSE.txt
```

| File | Tarball path |
| --- | --- |
| `SymbolsNerdFont-Regular.ttf` | `SymbolsNerdFont-Regular.ttf` |
| `NerdFonts-LICENSE.txt` | `LICENSE` |

The tarball also carries `SymbolsNerdFontMono-Regular.ttf`, every icon
squeezed into one cell. Not that one: ghostty's `src/build/SharedDeps.zig`
maps the non-Mono file, and the fit to the cell is done per icon at render
time by `NerdFontConstraints`, which is the patcher's own arithmetic.

## Licenses

- JetBrains Mono (OFL-1.1)
  - [Copyright 2020 The JetBrains Mono Project Authors](https://github.com/JetBrains/JetBrainsMono/blob/master/OFL.txt)
- Nerd Fonts (MIT)
  - [Copyright (c) 2014 Ryan L McIntyre](https://github.com/ryanoasis/nerd-fonts/blob/master/LICENSE.txt)
  - The icon sets the symbols file aggregates are each under their own
    permissive license; nerd-fonts lists them under *Glyph Sets* in its
    [README](https://github.com/ryanoasis/nerd-fonts#glyph-sets-and-codepoints).

A full copy of the OFL license is at [OFL.txt](./OFL.txt) and of the Nerd
Fonts license at [NerdFonts-LICENSE.txt](./NerdFonts-LICENSE.txt). An OFL
FAQ is at <https://openfontlicense.org/>.
