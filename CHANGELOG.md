# Changelog

## v1.0.11

- Fix: Threat module secret value comparisons now fully pcall-wrapped (fixes taint errors in instanced combat)
- Fix: Aura stack counts now display correctly in battlegrounds and instanced content using SetFormattedText for secret values
- Fix: Mobs that change faction/spawn after interaction (e.g. Apothecary Hummel) now correctly receive nameplates via UNIT_FACTION and retry logic
- Fix: Nameplate name text pre-positioned even when hidden to prevent "name squished to bar" layout bug on freshly spawned NPCs
- Fix: UNIT_NAME_UPDATE registered so late-arriving NPC names (e.g. Bran) are set and laid out correctly
- Fix: /tpr slash command no longer errors (removed invalid Settings.OpenToCategory call)
- Fix: Enemy player health bars in BGs now use class colors via GetClassColor() which handles secret class tokens at C level
- Fix: Class color fallback chain restructured so failed lookups fall through to reaction/custom color instead of leaving bars white
- Fix: Health bar initialised white instead of red so color failures don't leave bars stuck red
- Fix: Channeled spells (Rapid Fire, Penance, etc.) no longer persist on recycled nameplate frames; UNIT_REMOVED now clears cast state
- Fix: Added frame.unitId guard in cast/channel update handlers to reject stale recycled-frame events
- Fix: ValidateCastBars timer (0.5s) clears any cast bar whose unit stopped casting without firing a STOP event
- New: "Show Friendly Nameplates" toggle in General tab now correctly sets nameplateShowFriends and nameplateShowFriendlyNPCs CVars
- New: "Class Colors for Enemy Players" toggle — controls class coloring for BG opponents and training dummies separately from ally class colors
- New: "Hide Enemy Pet Nameplates" toggle in General tab
- New: PvP Cooldown Tracker — tracks offensive and defensive cooldown usage by enemy players; shows countdown icons below their nameplate; configurable per type, size, and position

## v1.0.0

- Initial release
- Customizable health bars with double border system (inner + outer)
- Cast bars with interrupt indicators and SetTimerDuration support
- Aura/debuff tracking with whitelist/blacklist filtering
- Threat coloring with separate tank and DPS/healer modes
- Target highlighting and scaling
- Built-in presets: Classic ThreatPlates, Minimal, Glossy
- Custom preset saving and sharing (import/export)
- Full AceDB profile management
- Live preview window
- 20+ bundled fonts and 8 statusbar textures
- WoW Midnight (12.0) Secret Values API compatible
