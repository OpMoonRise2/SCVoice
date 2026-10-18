--[[
* SCVoice 1.4  (GUI and callout controls, 2026-10-18)
* Skillchain and Magic Burst voice callouts for Ashita v4.
* Public source snapshot; recordings are distributed separately.
*   1.1 changes:
*     - MB (msg 252) and Cosmic (msg 302) now honour the Voice Preset gate.
*     - New Callout Scope option: Everyone / Party+Alliance / Self only.
*     - MB cooldown is per caster (os.time) instead of one global timer.
*     - ZoneMusic duck length is derived from the measured length of the clip
*       actually played (falls back to the per-chain value).
*     - Persisted settings are clamped on load; RNG is seeded at startup.
*   1.2 changes:
*     - Sounds are shipped as MP3 (stereo 128 kbps CBR) instead of WAV to
*       reduce the size of the separately distributed voice pack. Original
*       recording masters are not required to install or run the addon.
*     - The addon now references .mp3 filenames; clip lengths for ducking are
*       read from RIFF/WAV headers or estimated from MP3 frame headers.
*   1.3 changes:
*     - Magic Burst callouts now support random variants: drop magic_burst1.mp3,
*       magic_burst2.mp3, ... into sounds\ and one is auto-detected and picked
*       at random per burst (falls back to magic_burst.mp3 if none exist).
*   1.4 changes:
*     - Resizable BeastVoice-style GUI with separate setup, callouts and audition pages.
*     - Saved switches for 16 skillchains, Magic Burst and Cosmic Elucidation.
* Original author (1.0): MoonRise (Eldorin). All original functionality and
* the 1.0 author credit below are retained.
--]]
addon.name      = 'SCVoice';
addon.author    = 'MoonRise (Eldorin)';
addon.version   = '1.4';
addon.desc      = 'Skillchain Voice Callouts /scvoice for gui';
addon.link      = '';

require('common');
local chat = require('chat');
local ffi = require('ffi');
local imgui = require('imgui');
local settings = require('settings');

local sc_callout_names = {
    'Liquefaction', 'Impaction', 'Detonation', 'Scission', 'Reverberation',
    'Transfixion', 'Induration', 'Compression', 'Fusion', 'Fragmentation',
    'Gravitation', 'Distortion', 'Light', 'Darkness', 'Radiance', 'Umbra',
    'Magic Burst', 'Cosmic Elucidation',
};

local function normalize_callouts(values)
    if type(values) ~= 'table' then values = {}; end
    for _, name in ipairs(sc_callout_names) do
        if type(values[name]) ~= 'boolean' then values[name] = true; end
    end
    return values;
end

local default_settings = T{
    enabled = true,
    volume = 500,
    -- Voice Preset: 0=Muted, 1=Occasional(0.1x), 2=Balanced(0.5x), 3=Spammy(1.0x)
    voice_preset = 3,
    -- Callout Scope: 0=Everyone (any nearby actor, legacy), 1=Party/Alliance, 2=Self only
    scope = 0,
    callouts = normalize_callouts({}),
};

-- Clamp/coerce a persisted value to sane bounds (guards against hand-edited JSON).
local function clamp_num(v, lo, hi, fallback)
    if type(v) ~= 'number' or v ~= v then return fallback; end -- reject non-numbers and NaN
    if v < lo then return lo; end
    if v > hi then return hi; end
    return v;
end

-- Validate and clamp the loaded settings in place. Returns the same table so
-- the settings module keeps tracking the object it handed us.
local function normalize_settings(s)
    if type(s.enabled) == 'boolean' then
        s.enabled = s.enabled;
    else
        s.enabled = default_settings.enabled; -- missing / non-boolean -> default (on)
    end
    s.volume       = math.floor(clamp_num(s.volume, 0, 1000, default_settings.volume));
    s.voice_preset = math.floor(clamp_num(s.voice_preset, 0, 3, default_settings.voice_preset));
    s.scope        = math.floor(clamp_num(s.scope, 0, 2, default_settings.scope));
    s.callouts = normalize_callouts(s.callouts);
    return s;
end

-- math.random() is deterministic unless seeded; seed once so variant/preset
-- choices don't repeat identically after every addon load.
math.randomseed(os.time());
math.random();

local sc_settings = settings.load(default_settings);
normalize_settings(sc_settings);

local sc_config = {
    is_open      = { false },
    callouts     = {},
    enabled      = { sc_settings.enabled },
    volume       = { math.floor(sc_settings.volume / 10) },
    voice_preset = { sc_settings.voice_preset },
    scope        = { sc_settings.scope },
};

for _, name in ipairs(sc_callout_names) do sc_config.callouts[name] = { sc_settings.callouts[name] }; end

local StopDisabledCallouts;
local function IsCalloutEnabled(name)
    local toggle = name and sc_config.callouts[name];
    return not toggle or toggle[1] ~= false;
end

settings.register('settings', 'scvoice_settings_update', function(new_settings)
    if type(new_settings) ~= 'table' then return; end
    sc_settings = normalize_settings(new_settings);
    sc_config.enabled[1]      = sc_settings.enabled;
    sc_config.volume[1]       = math.floor(sc_settings.volume / 10);
    sc_config.voice_preset[1] = sc_settings.voice_preset;
    sc_config.scope[1]        = sc_settings.scope;
    for _, name in ipairs(sc_callout_names) do sc_config.callouts[name][1] = sc_settings.callouts[name]; end
    if StopDisabledCallouts then StopDisabledCallouts(); end
end);

local function save_settings()
    sc_settings.enabled      = sc_config.enabled[1];
    sc_settings.volume       = sc_config.volume[1] * 10;
    sc_settings.voice_preset = sc_config.voice_preset[1];
    sc_settings.scope        = sc_config.scope[1];
    for _, name in ipairs(sc_callout_names) do sc_settings.callouts[name] = sc_config.callouts[name][1]; end
    settings.save();
    print(chat.header('SCVoice'):append(chat.message('Settings saved!')));
end

ffi.cdef[[
    uint32_t mciSendStringA(const char* lpstrCommand, char* lpstrReturnString, uint32_t uReturnLength, void* hwndCallback);
]]
local winmm = ffi.load('winmm');

-- Duck signal for ZoneMusic integration (os.time() is the ONLY cross-Lua-state safe timestamp)
local duck_signal_file = string.format('%saddons\\voice_duck_signal.txt', AshitaCore:GetInstallPath());
local function signal_duck(duration)
    duration = duration or 2.5;
    pcall(function()
        local f = io.open(duck_signal_file, 'w');
        if f then
            f:write(string.format('%s,%s', tostring(os.time()), tostring(duration)));
            f:close();
        end
    end);
end

-- Cache of measured clip durations (seconds) per file path.
local media_duration_cache = {};

-- Returns the total duration (s) of an audio clip, or nil if it can't be read:
--   * RIFF/WAVE: data-chunk size / byte-rate from the header (standard PCM
--     layout: fmt byte-rate at file offset 28, data-chunk size at offset 40).
--   * MP3: skip an ID3v2 tag if present, read the first frame header, and
--     estimate CBR duration from the frame bitrate (approximate, +/- a few %).
-- Used to duck ZoneMusic for the full length of the clip that actually plays.
local function media_duration(path)
    local cached = media_duration_cache[path];
    if cached ~= nil then return cached; end

    local f = io.open(path, 'rb');
    if not f then return nil; end
    local head = f:read(128);
    if not head then f:close(); return nil; end

    if #head >= 44 and head:sub(1, 4) == 'RIFF' then
        f:close();
        local function u32(off)
            local b1, b2, b3, b4 = head:byte(off, off + 3);
            return b1 + b2 * 256 + b3 * 65536 + b4 * 16777216;
        end
        local byte_rate = u32(29);
        local data_size = u32(41);
        if byte_rate > 0 then
            local dur = data_size / byte_rate;
            media_duration_cache[path] = dur;
            return dur;
        end
        return nil;
    end

    -- MP3 path.
    local skip = 0;
    if head:sub(1, 3) == 'ID3' and #head >= 10 then
        local a, b, c, d = head:byte(7, 10);
        skip = ((a or 0) * 2097152) + ((b or 0) * 16384) + ((c or 0) * 128) + (d or 0) + 10;
    end
    local file_size = f:seek('end');
    f:seek('set', skip);
    local hdr = f:read(4);
    f:close();

    if not hdr or #hdr < 4 then return nil; end
    local h0, h1, h2, h3 = hdr:byte(1, 4);
    if h0 ~= 0xFF then return nil; end
    local ver    = math.floor(h1 / 8) % 4;      -- 3=MPEG1, 2=MPEG2, 0=MPEG2.5
    local layer  = math.floor(h1 / 2) % 4;      -- Layer III == 1
    local bri    = math.floor(h2 / 16);         -- bitrate index
    local sri    = math.floor(h2 / 4) % 4;      -- sample-rate index
    if ver == 1 or layer ~= 1 or bri == 0 or bri == 15 or sri == 3 then return nil; end

    local bitrate_kbps;
    if ver == 3 then
        bitrate_kbps = ({ [1]=32,  [2]=40,  [3]=48,  [4]=56,  [5]=64,  [6]=80,  [7]=96,
                          [8]=112, [9]=128, [10]=160, [11]=192, [12]=224, [13]=256, [14]=320 })[bri];
    else
        bitrate_kbps = ({ [1]=8,   [2]=16,  [3]=24,  [4]=32,  [5]=40,  [6]=48,  [7]=56,
                          [8]=64,  [9]=80,  [10]=96, [11]=112, [12]=128, [13]=144, [14]=160 })[bri];
    end
    if not bitrate_kbps then return nil; end

    local dur = (file_size - skip) * 8 / (bitrate_kbps * 1000);
    if dur <= 0 then return nil; end
    media_duration_cache[path] = dur;
    return dur;
end

-- ============================================================
-- SOUND ENGINE
-- ============================================================
local sound_pool_index = 1;
local MAX_POLYPHONY    = 15;

-- Single active SC slot. A new SC interrupts and replaces the current one.
local active_sc_alias = nil;
local sound_slot_owners = {};

local function stop_alias(alias)
    if alias then
        winmm.mciSendStringA('stop '  .. alias, nil, 0, nil);
        winmm.mciSendStringA('close ' .. alias, nil, 0, nil);
    end
end

-- Stop only SCVoice-owned channels affected by a disabled switch.
StopDisabledCallouts = function()
    for alias, name in pairs(sound_slot_owners) do
        if not sc_config.enabled[1] or not IsCalloutEnabled(name) then
            stop_alias(alias);
            sound_slot_owners[alias] = nil;
            if active_sc_alias == alias then active_sc_alias = nil; end
        end
    end
end;

local function SetCalloutEnabled(name, enabled)
    sc_config.callouts[name][1] = enabled;
    sc_settings.callouts[name] = enabled;
    StopDisabledCallouts();
end

local function mci_play(path, alias)
    local f = io.open(path, 'r');
    if not f then return false; end
    io.close(f);
    winmm.mciSendStringA('close ' .. alias, nil, 0, nil);
    local open_cmd = string.format('open "%s" type mpegvideo alias %s', path, alias);
    winmm.mciSendStringA(open_cmd, nil, 0, nil);
    local vol = sc_settings.volume or 500;
    winmm.mciSendStringA(string.format('setaudio %s volume to %d', alias, vol), nil, 0, nil);
    winmm.mciSendStringA('play ' .. alias, nil, 0, nil);
    return true;
end

-- ============================================================
-- SKILLCHAIN DATA
-- ============================================================

-- Packet SC index -> name (action packet, bit 272, 6 bits wide)
-- Index 0 = no skillchain.
-- Ordering verified against Ivaar/Ashita-addons Skillchains.lua `skillchain` table,
-- which indexes this array directly with the bit-272 value. The previous ordering
-- was wrong at every index except 15/16, which is why a real chain mis-announced
-- (e.g. raw index 13 -> 'Detonation' here, was 'Darkness' before).
local SC_INDEX_TO_NAME = {
    [1]  = 'Light',
    [2]  = 'Darkness',
    [3]  = 'Gravitation',
    [4]  = 'Fragmentation',
    [5]  = 'Distortion',
    [6]  = 'Fusion',
    [7]  = 'Compression',
    [8]  = 'Liquefaction',
    [9]  = 'Induration',
    [10] = 'Reverberation',
    [11] = 'Transfixion',
    [12] = 'Scission',
    [13] = 'Detonation',
    [14] = 'Impaction',
    [15] = 'Radiance',
    [16] = 'Umbra',
};

-- Per-skillchain config: variant count + duck duration (s) fallback.
-- Files are named sc_<lowercase name><n>.mp3 (n = 1..count), e.g. sc_light1.mp3, sc_light2.mp3.
-- One variant is chosen at random per trigger. Lead-in spacing is baked into the source audio.
-- To add a 3rd variant for a chain: drop sc_<name>3.mp3 in sounds\ and bump its count to 3.
local SC_DATA = {
    -- Tier 1
    ['Liquefaction']  = { count=2, duck=2.0 },
    ['Impaction']     = { count=2, duck=2.0 },
    ['Detonation']    = { count=2, duck=2.0 },
    ['Scission']      = { count=2, duck=2.0 },
    ['Reverberation'] = { count=2, duck=2.5 },
    ['Transfixion']   = { count=2, duck=2.0 },
    ['Induration']    = { count=2, duck=2.0 },
    ['Compression']   = { count=2, duck=2.0 },
    -- Tier 2
    ['Fusion']        = { count=2, duck=2.5 },
    ['Fragmentation'] = { count=2, duck=2.5 },
    ['Gravitation']   = { count=2, duck=2.5 },
    ['Distortion']    = { count=2, duck=2.5 },
    -- Tier 3
    ['Light']         = { count=2, duck=3.0 },
    ['Darkness']      = { count=2, duck=3.0 },
    ['Radiance']      = { count=2, duck=3.0 },
    ['Umbra']         = { count=2, duck=3.0 },
};
-- Note: Cosmic Elucidation (Tenzen, NPC-only) is NOT in this table. It is a single
-- unique line played via play_single('sc_cosmic_elucidation.mp3') from the msg-302
-- branch below, mirroring magic_burst.mp3.

-- Build the clip filename for a given skillchain + variant index.
local function sc_filename(sc_name, n)
    -- Lowercase + spaces to underscores (e.g. 'Cosmic Elucidation' -> 'cosmic_elucidation').
    return string.format('sc_%s%d.mp3', (sc_name:lower():gsub(' ', '_')), n);
end

-- Picks a random variant for the skillchain and plays it immediately.
-- Interrupts any SC currently playing.
local function play_sc_variant(sc_name)
    if not sc_config.enabled[1] or not IsCalloutEnabled(sc_name) then return; end
    local d = SC_DATA[sc_name];
    if not d then return; end

    local count = d.count or 1;
    local n = (count > 1) and math.random(1, count) or 1;
    local root = string.format('%saddons\\scvoice\\sounds\\', AshitaCore:GetInstallPath());
    local path = root .. sc_filename(sc_name, n);

    -- Interrupt whatever SC is currently playing
    stop_alias(active_sc_alias);
    if active_sc_alias then sound_slot_owners[active_sc_alias] = nil; end
    active_sc_alias = nil;

    local alias = 'scv_sc_' .. sound_pool_index;
    sound_pool_index = sound_pool_index + 1;
    if sound_pool_index > MAX_POLYPHONY then sound_pool_index = 1; end

    if mci_play(path, alias) then
        active_sc_alias = alias;
        sound_slot_owners[alias] = sc_name;
        -- Duck ZoneMusic for the full measured length of the clip actually
        -- played; fall back to the per-chain config if it can't be measured.
        signal_duck(media_duration(path) or (d.duck or 2.5));
    end
end

-- Fallback: play a single named file (for magic burst). Does NOT interrupt an SC.
local function play_single(filename, duck_duration)
    if not sc_config.enabled[1] then return; end
    local callout = filename:match('^magic_burst') and 'Magic Burst'
                 or (filename == 'sc_cosmic_elucidation.mp3' and 'Cosmic Elucidation' or nil);
    if not IsCalloutEnabled(callout) then return; end
    local path = string.format('%saddons\\scvoice\\sounds\\%s', AshitaCore:GetInstallPath(), filename);
    local f = io.open(path, 'r');
    if not f then return; end
    io.close(f);
    local alias = 'scv_sfx_' .. sound_pool_index;
    sound_pool_index = sound_pool_index + 1;
    if sound_pool_index > MAX_POLYPHONY then sound_pool_index = 1; end
    winmm.mciSendStringA('close ' .. alias, nil, 0, nil);
    local open_cmd = string.format('open "%s" type mpegvideo alias %s', path, alias);
    winmm.mciSendStringA(open_cmd, nil, 0, nil);
    local vol = sc_settings.volume or 500;
    winmm.mciSendStringA(string.format('setaudio %s volume to %d', alias, vol), nil, 0, nil);
    winmm.mciSendStringA('play ' .. alias, nil, 0, nil);
    sound_slot_owners[alias] = callout;
    -- Duck for the measured length of this clip (fallback: the passed duration).
    signal_duck(media_duration(path) or (duck_duration or 2.5));
end

-- Magic Burst variant support, mirroring the skillchain sc_<name><n>.mp3 scheme:
-- numbered variants magic_burst1.mp3, magic_burst2.mp3, ... are auto-detected
-- at trigger time and one is picked at random per burst. Just drop new files
-- into sounds\ (no code/config change needed). Falls back to the legacy single
-- magic_burst.mp3 when no numbered variants exist.
local function magic_burst_variant_count()
    local n = 1;
    while true do
        local p = string.format('%saddons\\scvoice\\sounds\\magic_burst%d.mp3', AshitaCore:GetInstallPath(), n);
        local f = io.open(p, 'r');
        if not f then break; end
        io.close(f);
        n = n + 1;
    end
    return n - 1;
end

local function play_magic_burst()
    if not sc_config.enabled[1] then return; end
    local count = magic_burst_variant_count();
    local filename;
    if count > 0 then
        filename = string.format('magic_burst%d.mp3', math.random(1, count));
    else
        filename = 'magic_burst.mp3'; -- legacy single-file behaviour
    end
    play_single(filename, 2.5);
end

-- ============================================================
-- PRESET / RATE GATE
-- ============================================================
local SC_PRESET_MULT = { [0]=0.0, [1]=0.1, [2]=0.5, [3]=1.0 };

local function sc_should_play()
    local preset = sc_config.voice_preset[1];
    if preset == 3 then return true;  end
    if preset == 0 then return false; end
    local rate = math.floor(100 * (SC_PRESET_MULT[preset] or 1.0));
    return math.random(1, 100) <= rate;
end

-- ============================================================
-- SCOPE FILTER
-- ============================================================
-- Actor server id of the 0x28 sender (packet bits 40..71) - the same offset
-- used by the tHotBar/LuAshitacast-style action parser and Ivaar's addon.
local function packet_actor(e)
    return ashita.bits.unpack_be(e.data_raw, 0, 40, 32);
end

-- True when the packet's actor is inside the configured announce scope
-- (0=everyone, 1=party/alliance incl. self, 2=self only). Wrapped in pcall so a
-- party-manager API hiccup degrades to "out of scope" instead of erroring the
-- packet handler. Never consulted for the legacy scope 0.
local function actor_in_scope(actor)
    local scope = sc_config.scope[1];
    if scope == 0 then return true; end
    local ok, in_scope = pcall(function()
        local party = AshitaCore:GetMemoryManager():GetParty();
        if scope == 1 then
            for i = 0, 17 do
                if party:GetMemberIsActive(i) == 1 and party:GetMemberServerId(i) == actor then
                    return true;
                end
            end
            return false;
        end
        return party:GetMemberServerId(0) == actor;
    end);
    return ok and in_scope or false;
end

-- ============================================================
-- TRIGGER: PACKET (0x28 action packet)
-- Fires at animation start. Callout plays immediately; lead-in spacing
-- is baked into the source audio, so no scheduled delay is used.
-- ============================================================
local MB_COOLDOWN = 3.0;
-- Per-actor last-MB-callout timestamps (os.time seconds): one caster's burst no
-- longer suppresses another's inside the cooldown window.
local mb_cooldowns = {};

-- Keep the cooldown map bounded: entries older than MB_COOLDOWN can no longer
-- gate anything, so drop them whenever a new callout is allowed.
local function prune_mb_cooldowns(now)
    for actor, ts in pairs(mb_cooldowns) do
        if (now - ts) >= MB_COOLDOWN then
            mb_cooldowns[actor] = nil;
        end
    end
end

ashita.events.register('packet_in', 'scvoice_packet', function(e)
    if not sc_config.enabled[1] then return; end
    if e.id ~= 0x28 then return; end

    -- Action category: bit 82, 4 bits wide.
    --   1 = melee auto-attack   2 = ranged auto-attack   3 = weapon skill
    --   4 = magic (spell finish) 6 = job ability  11 = monster TP move  13 = pet ability
    -- Verified against Ivaar/Ashita-addons Skillchains.lua. The 6-bit skillchain
    -- property at bit 272 is only meaningful on a CLOSING weapon skill. On every
    -- other category those bits carry unrelated data that can decode to a nonzero
    -- index:
    --   - melee/ranged rounds: added-effect (enspell) data   -> false "Reverberation"
    --   - cat 4 spell finish (cures, Protect, Reraise, etc.)  -> false "Fusion"
    -- Ivaar gates the bit-272 read behind a skills[category][param] lookup plus a
    -- category-4/Immanence check. SCVoice has no skills table, so the equivalent
    -- safe gate is category == 3. A non-closing WS reports sc_index 0, so
    -- (category == 3 and sc_index ~= 0) isolates exactly a real closed skillchain.
    local category = ashita.bits.unpack_be(e.data_raw, 0, 82, 4);
    local msg_id   = ashita.bits.unpack_be(e.data_raw, 0, 230, 10);

    -- Magic burst (msg 252) rides the spell-finish packet (category 4), separate
    -- from the skillchain path. Handle it BEFORE the category/sc_index gates so it
    -- is not swallowed by the early returns below. It now passes the same preset
    -- gate as SC callouts and honours the callout scope, with a per-caster
    -- cooldown instead of one global timer.
    if msg_id == 252 then
        if IsCalloutEnabled('Magic Burst') and sc_should_play() then
            local actor = packet_actor(e);
            if actor_in_scope(actor) then
                local now = os.time();
                if (mb_cooldowns[actor] == nil) or ((now - mb_cooldowns[actor]) >= MB_COOLDOWN) then
                    mb_cooldowns[actor] = now;
                    prune_mb_cooldowns(now);
                    -- play_magic_burst -> play_single so MB does not interrupt an in-flight SC callout
                    play_magic_burst();
                end
            end
        end
    end

    -- Cosmic Elucidation (msg 302): Tenzen's unique NPC-only skillchain. It arrives as
    -- a mob skill (LSB mob_skill 1396 / category 11), not a category-3 closing WS, and
    -- is identified by its message id rather than the bit-272 property. Handle here,
    -- before the category gate. Single unique line via play_single (no variant digit)
    -- -> sc_cosmic_elucidation.mp3. Preset-gated like the other callouts; the actor
    -- scope is intentionally NOT applied, since an NPC actor can never match a player
    -- scope and this is a rare, unique event line.
    if msg_id == 302 then
        if IsCalloutEnabled('Cosmic Elucidation') and sc_should_play() then
            play_single('sc_cosmic_elucidation.mp3', 3.5);
        end
        return;
    end

    -- Skillchain callout path: weapon-skill closing actions only.
    if category ~= 3 then return; end

    -- Skillchain property: bit 272, 6 bits wide
    -- Ashita v4: ashita.bits.unpack_be(data_raw, byteOffset, bitOffset, bitLength)
    local sc_index = ashita.bits.unpack_be(e.data_raw, 0, 272, 6);
    if sc_index == 0 then return; end

    -- DEBUG: uncomment to print the raw index + resolved name on every closing WS.
    -- Close several DIFFERENT known skillchains and confirm the index varies and
    -- matches the table. If the index is constant across different chains, the
    -- bit-272 offset is wrong for this client and needs a capture-based fix.
    -- print(chat.header('SCVoice'):append(chat.message(string.format(
    --     'raw sc_index=%d -> %s', sc_index, tostring(SC_INDEX_TO_NAME[sc_index])))));

    local sc_name = SC_INDEX_TO_NAME[sc_index];
    if not sc_name or not IsCalloutEnabled(sc_name) then return; end

    -- Only announce chains closed by actors inside the configured scope.
    if not actor_in_scope(packet_actor(e)) then return; end

    if not sc_should_play() then return; end

    play_sc_variant(sc_name);
end);

-- ============================================================
-- GUI TICKER (d3d_present)
-- ============================================================
-- A resizable voice-control window shared visually with BeastVoice.
local sc_gui_page = 0;

local function sc_help(text)
    imgui.PushStyleColor(ImGuiCol_Text, {0.62, 0.68, 0.76, 1.0});
    imgui.TextWrapped(text);
    imgui.PopStyleColor(1);
end

local function sc_section(label)
    imgui.Spacing();
    imgui.TextColored({0.94, 0.73, 0.43, 1.0}, label);
    imgui.Separator();
end

ashita.events.register('d3d_present', 'scvoice_tick', function()
    if not sc_config.is_open[1] then return; end
    local preset_names = { 'Muted', 'Occasional', 'Balanced', 'Spammy' };
    local scope_names = { 'Everyone', 'Party/Alliance', 'Self Only' };
    local colors = {
        { ImGuiCol_WindowBg, {0.065, 0.080, 0.105, 0.98} },
        { ImGuiCol_ChildBg, {0.090, 0.110, 0.145, 1.0} },
        { ImGuiCol_Border, {0.23, 0.28, 0.35, 0.75} },
        { ImGuiCol_Text, {0.90, 0.93, 0.97, 1.0} },
        { ImGuiCol_TitleBg, {0.10, 0.12, 0.16, 1.0} },
        { ImGuiCol_TitleBgActive, {0.15, 0.19, 0.24, 1.0} },
        { ImGuiCol_FrameBg, {0.13, 0.17, 0.22, 1.0} },
        { ImGuiCol_FrameBgHovered, {0.19, 0.24, 0.31, 1.0} },
        { ImGuiCol_FrameBgActive, {0.23, 0.29, 0.37, 1.0} },
        { ImGuiCol_Button, {0.17, 0.22, 0.29, 1.0} },
        { ImGuiCol_ButtonHovered, {0.26, 0.33, 0.43, 1.0} },
        { ImGuiCol_ButtonActive, {0.33, 0.39, 0.47, 1.0} },
        { ImGuiCol_Header, {0.25, 0.31, 0.40, 1.0} },
        { ImGuiCol_HeaderHovered, {0.32, 0.39, 0.49, 1.0} },
        { ImGuiCol_HeaderActive, {0.39, 0.45, 0.54, 1.0} },
        { ImGuiCol_CheckMark, {0.94, 0.73, 0.43, 1.0} },
        { ImGuiCol_SliderGrab, {0.79, 0.59, 0.32, 1.0} },
        { ImGuiCol_SliderGrabActive, {0.98, 0.79, 0.48, 1.0} },
    };
    for _, color in ipairs(colors) do imgui.PushStyleColor(color[1], color[2]); end
    imgui.PushStyleVar(ImGuiStyleVar_WindowPadding, {16, 14});
    imgui.PushStyleVar(ImGuiStyleVar_WindowRounding, 7);
    imgui.PushStyleVar(ImGuiStyleVar_ChildRounding, 5);
    imgui.PushStyleVar(ImGuiStyleVar_FrameRounding, 4);
    imgui.PushStyleVar(ImGuiStyleVar_FramePadding, {9, 6});
    imgui.PushStyleVar(ImGuiStyleVar_ItemSpacing, {10, 9});
    imgui.SetNextWindowSizeConstraints({620, 460}, {1200, 1000});
    imgui.SetNextWindowSize({700, 560}, ImGuiCond_FirstUseEver);
    if imgui.Begin('SCVoice', sc_config.is_open, 0) then
        imgui.TextColored({0.94, 0.73, 0.43, 1.0}, 'SCVOICE');
        imgui.SameLine(); imgui.Text('Skillchain callouts');
        sc_help('Choose who you hear, how often they speak, and which recordings to audition.');
        imgui.Separator();

        local available_w, available_h = imgui.GetContentRegionAvail();
        local body_h = math.max(160, available_h - 76);
        imgui.BeginChild('##sc_navigation', {156, body_h}, ImGuiChildFlags_Borders);
        imgui.TextColored(sc_config.enabled[1] and {0.40,0.82,0.63,1.0} or {0.88,0.52,0.43,1.0}, sc_config.enabled[1] and 'ACTIVE' or 'PAUSED');
        sc_help(preset_names[sc_config.voice_preset[1] + 1] .. '\n' .. scope_names[sc_config.scope[1] + 1]);
        imgui.Spacing();
        for i, label in ipairs({'General', 'Voice Setup', 'Callouts', 'Audition'}) do
            local active = sc_gui_page == i - 1;
            if active then
                imgui.PushStyleColor(ImGuiCol_Button, {0.38,0.29,0.18,1.0});
                imgui.PushStyleColor(ImGuiCol_Text, {1.0,0.82,0.55,1.0});
            end
            if imgui.Button(label, {-1, 34}) then sc_gui_page = i - 1; end
            if active then imgui.PopStyleColor(2); end
        end
        imgui.Spacing(); imgui.Separator();
        if imgui.Checkbox('Enabled', sc_config.enabled) then sc_settings.enabled = sc_config.enabled[1]; StopDisabledCallouts(); end
        imgui.EndChild(); imgui.SameLine();

        imgui.BeginChild('##sc_content', {0, body_h}, ImGuiChildFlags_Borders);
        imgui.PushItemWidth(-1);
        if sc_gui_page == 0 then
            sc_section('Playback');
            imgui.Text(string.format('Volume - %d%%', sc_config.volume[1]));
            imgui.SetNextItemWidth(-1);
            if imgui.SliderInt('##scvol', sc_config.volume, 0, 100) then sc_settings.volume = sc_config.volume[1] * 10; end
            sc_help('Adjust the callout volume independently of your voice preset.');
            sc_section('Music integration');
            sc_help('When ZoneMusic is installed, callouts send a ducking signal based on the recorded clip length. SCVoice also works on its own.');
            sc_section('Quick start');
            sc_help('Choose a preset and callout scope under Voice Setup. Use Audition to preview your recordings, then Save Settings to keep your choices.');
        elseif sc_gui_page == 1 then
            sc_section('Voice preset');
            imgui.SetNextItemWidth(-1);
            if imgui.BeginCombo('##scpreset', preset_names[sc_config.voice_preset[1] + 1]) then
                for i = 0, 3 do
                    if imgui.Selectable(preset_names[i+1], sc_config.voice_preset[1] == i) then
                        sc_config.voice_preset[1] = i; sc_settings.voice_preset = i;
                    end
                end
                imgui.EndCombo();
            end
            local descriptions = {
                'Muted disables automatic callouts. Audition remains available while the addon is enabled.',
                'Occasional allows a 10% chance for each eligible automatic callout.',
                'Balanced allows a 50% chance for each eligible automatic callout.',
                'Spammy allows every eligible automatic callout. Magic Burst cooldowns still apply.',
            };
            sc_help(descriptions[sc_config.voice_preset[1] + 1]);
            sc_section('Callout scope');
            imgui.SetNextItemWidth(-1);
            if imgui.BeginCombo('##scscope', scope_names[sc_config.scope[1] + 1]) then
                for i = 0, 2 do
                    if imgui.Selectable(scope_names[i+1], sc_config.scope[1] == i) then
                        sc_config.scope[1] = i; sc_settings.scope = i;
                    end
                end
                imgui.EndCombo();
            end
            sc_help('Everyone includes nearby actors. Party/Alliance limits callouts to active members. Self Only limits them to your own actions.');
            sc_help('Magic Bursts keep their existing per-caster cooldown. Cosmic Elucidation retains its separate encounter callout.');
        elseif sc_gui_page == 2 then
            sc_section('Choose your callouts');
            sc_help('Enable individual skillchains and special callouts. Turning one off also stops its current recording.');
            if imgui.Button('All On', {140, 32}) then
                for _, name in ipairs(sc_callout_names) do SetCalloutEnabled(name, true); end
            end
            imgui.SameLine();
            if imgui.Button('All Off', {140, 32}) then
                for _, name in ipairs(sc_callout_names) do SetCalloutEnabled(name, false); end
            end
            imgui.Separator();
            for _, name in ipairs(sc_callout_names) do
                local toggle = sc_config.callouts[name];
                if imgui.Checkbox(name .. '##sccallout', toggle) then SetCalloutEnabled(name, toggle[1]); end
            end
            sc_help('Callout switches also apply to Audition. Preset and scope filters still control automatic playback. Save Settings keeps these choices.');
        else
            sc_section('Audition recordings');
            sc_help('Preview buttons bypass automatic preset and scope filters. Enable SCVoice to hear them. Each skillchain preview selects a recorded variation.');
            for _, group in ipairs({
                {'Tier 1', {'Transfixion','Liquefaction','Scission','Reverberation','Detonation','Induration','Impaction','Compression'}},
                {'Tier 2', {'Fusion','Fragmentation','Gravitation','Distortion'}},
                {'Tier 3 / higher', {'Light','Darkness','Radiance','Umbra'}},
            }) do
                sc_section(group[1]);
                local width = imgui.GetContentRegionAvail();
                local button_w = math.max(130, (width - 10) / 2);
                for i, name in ipairs(group[2]) do
                    if imgui.Button(name, {button_w, 32}) then play_sc_variant(name); end
                    if i % 2 == 1 then imgui.SameLine(); end
                end
            end
            sc_section('Special callouts');
            if imgui.Button('Cosmic Elucidation', {-1, 32}) then play_single('sc_cosmic_elucidation.mp3', 3.5); end
            if imgui.Button('Magic Burst', {-1, 32}) then play_magic_burst(); end
        end
        imgui.PopItemWidth();
        imgui.EndChild();
        imgui.Spacing();
        if imgui.Button('Save Settings', {156, 32}) then save_settings(); end
        imgui.SameLine();
        if imgui.Button('Close', {90, 32}) then sc_config.is_open[1] = false; end
        sc_help('Changes apply immediately. Save keeps them for your next session.');
    end
    imgui.End();
    imgui.PopStyleVar(6);
    imgui.PopStyleColor(#colors);
end);

-- ============================================================
-- COMMANDS
-- ============================================================
ashita.events.register('command', 'scvoice_cmd', function(e)
    local args = e.command:args();
    if #args > 0 and args[1] == '/scvoice' then
        sc_config.is_open[1] = not sc_config.is_open[1];
        e.blocked = true;
    end
end);

-- ============================================================
-- UNLOAD
-- ============================================================
ashita.events.register('unload', 'scvoice_unload', function()
    pcall(save_settings);
    pcall(function()
        for i = 1, MAX_POLYPHONY do
            winmm.mciSendStringA('stop scv_sc_'  .. i, nil, 0, nil);
            winmm.mciSendStringA('close scv_sc_' .. i, nil, 0, nil);
            winmm.mciSendStringA('stop scv_sfx_' .. i, nil, 0, nil);
            winmm.mciSendStringA('close scv_sfx_' .. i, nil, 0, nil);
        end
    end);
end);
