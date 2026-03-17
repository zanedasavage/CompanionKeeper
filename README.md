# Companion Keeper

Companion Keeper keeps a chosen companion pet out by re-summoning it after common interruptions such as flight paths, mounting, zoning, or loading.

It uses Blizzard's companion-pet journal APIs and avoids protected combat-pet behavior.

## Features

- Re-summons a chosen companion pet when it disappears
- Supports picking a pet from your collected pet journal
- Supports random favorites mode
- Includes an in-game settings panel under `Settings -> AddOns -> Companion Keeper`
- Shows a preview icon for the selected pet

## Commands

- `/ck`
- `/companionkeeper`

## Installation

1. Download the latest release zip.
2. Extract the `CompanionKeeper` folder into:
   `World of Warcraft/_retail_/Interface/AddOns/`
3. Reload the UI with `/reload`.

## Notes

- This addon is for companion pets / vanity pets, not warlock combat pets.
- Companion pet summoning is deferred until appropriate out-of-combat conditions.

## Packaging

The release zip should contain the top-level addon folder directly:

```text
CompanionKeeper.zip
  CompanionKeeper/
    CompanionKeeper.toc
    CompanionKeeper.lua
    README.md
    Media/
      companionkeeper.png
```
