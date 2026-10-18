# Maintenance state

## Responsibilities

`scvoice.lua` owns settings normalization, packet handling, preset and scope gates, MCI channels and the GUI. Audio is distributed through the accompanying Nexus Mods package; character preferences and runtime signals remain local to the install.

## Version 1.4 — 2026-10-18

The public copy removes personal recording paths and internal agent wording while preserving MoonRise (Eldorin)'s author credit. This update adds a BeastVoice-style resizable GUI and saved switches for all 16 configured skillchains, Magic Burst and Cosmic Elucidation. Turning off a callout stops only affected SCVoice channels. Defaults preserve playback for older configurations.

The 37 MP3 files are unchanged from installed 1.3 and remain compatible. Packet offsets, category restrictions, scope rules, preset probabilities, per-caster burst cooldowns and the separate Cosmic scope exception are preserved. No license is assigned by this preparation.

## Verification

Source syntax and mocked tests cover all 18 switches, legacy defaults, saved OFF values, selective channel stopping, auditions, GUI settings/navigation/style balance, packet category and scope gates, per-caster Magic Burst cooldowns and Cosmic Elucidation. All 37 MP3s fully decoded during asset preparation. Real GUI rendering, live packet matching and ZoneMusic ducking require a client check; mocked tests alone do not establish engine compatibility.
