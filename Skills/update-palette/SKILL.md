---
name: update-palette
description: Regenerate Packages/AppPalette/Sources/AppPalette/Palette+Generated.swift from the colour sets in Colors.xcassets. Run it after picking or adding a colour in Xcode's colour editor, when the user asks to "update the palette" / "I changed a colour in the catalogue", or after adding a colour set to AppPalette.
---

# Update the palette

The app's semantic colours are **colour sets in an asset catalogue**, picked in
Xcode's own editor with both appearances side by side:

```
Packages/AppPalette/Sources/AppPalette/Resources/Colors.xcassets
```

That catalogue is the source. Nothing about a colour is typed into Swift — this
skill reads the colour sets back out and rewrites the one generated file:

```
Packages/AppPalette/Sources/AppPalette/Palette+Generated.swift
```

## Why the generated file exists

`swift build` copies an `.xcassets` into the bundle verbatim; only Xcode runs
`actool` and produces the `Assets.car` that `NSColor(named:bundle:)` can read.
So the app — built by Xcode — reads the catalogue itself, while every package
test in this repository would see no colours at all. The generated file is the
same numbers, readable without a compiled catalogue, and the app suite's
`SemanticPaletteTests` is what keeps the two from drifting: it fails if the
catalogue and the generated values disagree in either theme.

## Run it

```sh
python3 Skills/update-palette/scripts/gen_palette.py
```

Stdlib only, no arguments. It prints every colour set it read with both shades,
and rewrites the Swift file only when something changed — so a run that read
half the catalogue is visible rather than committed.

## Changing a colour

1. Open `Colors.xcassets` in Xcode, pick the new shade for Any Appearance and
   for Dark.
2. Run the skill.
3. `cd Packages/AppPalette && swift test`, then the app suite's
   `SemanticPaletteTests`. Nothing else should need editing: the tests pin the
   palette's *rules* — both themes present, the dark shade the paler of the two,
   names distinct — rather than any particular shade, so picking a better green
   is not a code change.

## Adding a meaning

1. A new colour set in the catalogue, named `Semantic<Meaning>`.
2. Run the skill — the definition appears in the generated file.
3. Add one line to `SemanticColors` giving the meaning a name:

   ```swift
   /// What this colour says, in a sentence a reader can check a use against.
   public static let <meaning> = colour(.<meaning>)
   ```

The value is the catalogue's; the meaning is Swift's. That split is the point:
a caller picks `SemanticColors.bad` rather than a red, and what that red *is*
stays a thing you can see while you choose it.

## Do not

- Edit `Palette+Generated.swift` by hand. The header says so and the next run
  overwrites it.
- Add a colour to the app's own `Assets.xcassets` instead. A tool-module is a
  separate package that must build and test without the app, so the catalogue
  it reads has to be one a package owns.
