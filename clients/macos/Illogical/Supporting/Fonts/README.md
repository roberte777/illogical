# Embedded fonts

The app ships its default font rather than taking whatever
`.userFixedPitch` hands back, so a fresh install looks right without the
user installing anything. libghostty does the same thing with the same
files — see `src/font/embedded.zig` and `src/font/SharedGridSet.zig` in
`vendor/ghostty`, and its warning, which applies here too:

> Be careful to ensure that any fonts you embed are licensed for
> redistribution and include their license as necessary.

`OFL.txt` is copied into the bundle alongside the fonts. This README is
excluded from it — see `excludes` in `clients/macos/project.yml`.

## What is here, and where it came from

Both files are the **variable** faces, byte-for-byte out of the tarball
ghostty pins:

    https://deps.files.ghostty.org/JetBrainsMono-2.304.tar.gz
    sha256-xXppHouCrQmLWWPzlZAy5AOPORCHr3cViFulkEYQXMQ=

which is the `.jetbrains_mono` dependency in `vendor/ghostty/build.zig.zon`,
at the same version and hash. To refresh them:

```bash
curl -sSLO https://deps.files.ghostty.org/JetBrainsMono-2.304.tar.gz
shasum -a 256 JetBrainsMono-2.304.tar.gz   # must match the hash above
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

## Licenses

- JetBrains Mono (OFL-1.1)
  - [Copyright 2020 The JetBrains Mono Project Authors](https://github.com/JetBrains/JetBrainsMono/blob/master/OFL.txt)

A full copy of the OFL license is at [OFL.txt](./OFL.txt). An accompanying
FAQ is at <https://openfontlicense.org/>.
