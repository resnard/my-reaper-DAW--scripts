--[[
  FX Browser — a clean plugin / FX-chain browser for REAPER
  Requires: ReaImGui 0.9+ (ReaPack > ReaTeam Extensions). Optional: SWS/js_ReaScriptAPI (open links, show in explorer).

  Default keys (all configurable in Settings > Shortcuts)
    Enter ............ insert on selected track(s)      Ctrl+Enter ........ insert on selected take(s)
    Shift+Enter ...... insert on track(s) and open      Ctrl+Shift+Enter .. insert on take(s) and open
    Double-click ..... insert on selected track(s)      Drag .............. drop onto a track or item
    Alt+S ............ fluent mode                      Alt+Q ............. info window per selected plugin
    Alt+B ............ bulk edit metadata               Alt+P ............. toggle side panel
    Alt+1..5 / Alt+0 . rate / clear rating              Esc ............... leave scope / clear / leave fluent
    Alt+C ............ clear side-panel filters           Alt+R ............. refresh the FX list
    Ctrl+D ........... deselect all results             Alt+W ............. close the active script window
    Ctrl+Shift+click . skip a confirmation dialog (delete / reset buttons)
    Tab .............. activate scope (type its key first; !key inverts) or autocomplete
    Right-click ...... script menu       Ctrl+Right-click ... native-style menu
    Ctrl+click in the order you want, then Enter = insert them as a chain in that order.

  Search syntax
    word word      AND                 a && b     both searches; results of a come first
    a || b         OR (by relevance)   -word      NOT
    "exact phrase"                     dev:fab  fmt:vst3  cat:eq  folder:mix  kw:warm
    is:<field>|free|hidden|notes|rated|meta        rating:>=4    <field>:>=5 (number)   <field>:text   <field>:no
    Your own metadata fields (Settings > Fields) work in all of these, e.g. is:paid  cpu:<5  mood:warm
]]

local r = reaper
if not r.ImGui_CreateContext then
  r.MB("This script needs ReaImGui.\nInstall it via ReaPack (ReaTeam Extensions > ReaImGui).", "FX Browser", 0)
  return
end
pcall(function() dofile(r.GetResourcePath() .. '/Scripts/ReaTeam Extensions/API/imgui.lua')('0.9') end)

-------------------------------------------------------------------------------
-- Basics
-------------------------------------------------------------------------------
local KC = setmetatable({}, { __index = function(t, n)
  local f = r['ImGui_' .. n]; local v = f and f() or 0; t[n] = v; return v end })
local function hasConst(n) return r['ImGui_' .. n] ~= nil end

local MAIN_PATH = (debug.getinfo(1, "S").source or ""):match("^@(.+)$")
local IS_WIN = r.GetOS():find("Win") ~= nil
local IS_MAC = r.GetOS():find("OSX") ~= nil or r.GetOS():find("macOS") ~= nil
local SEP = IS_WIN and "\\" or "/"
local RES = r.GetResourcePath()
local function rgb(h, a) return (h << 8) | (a or 255) end

local C = {}   -- filled by applyTheme()

local ctx = r.ImGui_CreateContext("FX Browser")

-- Row badges: the order list doubles as display order and hide-priority.
local BADGE_ORDER = { "dev", "fmt", "rating", "cpu", "notes", "paid", "net", "early", "inst", "x32" }
local BADGE_LABEL = { dev = "Developer", fmt = "Format", rating = "Rating", notes = "Notes" }
local THEMES = {
  dark = { bg = 0x1d2127, panel = 0x232930, frame = 0x2a313a, frameH = 0x323a45, input = 0x171b20, inputH = 0x1d2329,
    button = 0x303944, buttonH = 0x3b4653, border = 0x3a434e, text = 0xdde3ea, muted = 0x8d98a6, faint = 0x5f6a78,
    accent = 0x7bbf9f, accentDim = 0x2b4a3f, sel = 0x294539, hover = 0x28312e,
    gold = 0xe0b252, green = 0x7bc4a0, red = 0xd9777a, warn = 0xd9a15f },
  light = { bg = 0xf3f5f7, panel = 0xffffff, frame = 0xe8ecf0, frameH = 0xdce2e8, input = 0xffffff, inputH = 0xf4f7f9,
    button = 0xdde3e9, buttonH = 0xcdd6de, border = 0xc5cdd6, text = 0x1f2933, muted = 0x52606d, faint = 0x8794a1,
    accent = 0x2f8f6b, accentDim = 0xcde7da, sel = 0xd5ebdf, hover = 0xe4eee9,
    gold = 0xb7791f, green = 0x2f855a, red = 0xc53030, warn = 0xb7611f },
}
local TOKENS = { { "bg", "Window background" }, { "panel", "Panels" }, { "input", "Input fields" }, { "button", "Buttons" },
  { "border", "Borders" }, { "text", "Text" }, { "muted", "Secondary text" }, { "faint", "Hints" },
  { "accent", "Accent" }, { "accentDim", "Accent (selected)" }, { "sel", "Row selection" }, { "hover", "Row hover" },
  { "gold", "Stars" } }
local BADGE_COLOR = {
  dark = { dev = 0x8d98a6, fmt = 0x8d98a6, rating = 0xe0b252, cpu = 0x6bb0d1, notes = 0xa7b8cc, paid = 0x7bc4a0,
    net = 0xd9a15f, early = 0xd9777a, inst = 0xb59bd6, x32 = 0xc9a27e },
  light = { dev = 0x52606d, fmt = 0x52606d, rating = 0xb7791f, cpu = 0x1f7aa8, notes = 0x5b6b82, paid = 0x2f855a,
    net = 0xb7611f, early = 0xc53030, inst = 0x6b46c1, x32 = 0x8a5a2b },
}
local FMT_LIST = { "VST3", "VST2", "CLAP", "JSFX", "AU", "LV2", "DX", "CHAIN" }
local FMT_COLOR = {
  dark = { VST3 = 0x6bb0d1, VST2 = 0xa7b8cc, CLAP = 0x9ccf8e, JSFX = 0xe0b252, AU = 0xd9a1c9, LV2 = 0xc9b27e,
    DX = 0x8d98a6, CHAIN = 0xd9a15f, ["?"] = 0x8d98a6 },
  light = { VST3 = 0x1f7aa8, VST2 = 0x5b6b82, CLAP = 0x2f855a, JSFX = 0xb7791f, AU = 0x9b4d8a, LV2 = 0x7a6a2e,
    DX = 0x52606d, CHAIN = 0xb7611f, ["?"] = 0x52606d },
}

local function trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end

-------------------------------------------------------------------------------
-- Persistence
-------------------------------------------------------------------------------
local DATA_DIR = RES .. SEP .. "Data" .. SEP .. "FXBrowser"
r.RecursiveCreateDirectory(DATA_DIR, 0)

local function ser(v, ind)
  ind = ind or ""
  local t = type(v)
  if t == "table" then
    local out, ni, n = {}, ind .. " ", #v
    for i = 1, n do out[#out + 1] = ni .. ser(v[i], ni) .. "," end
    for k, val in pairs(v) do
      if not (math.type(k) == "integer" and k >= 1 and k <= n) then
        local ks = type(k) == "string" and string.format("[%q]", k) or "[" .. tostring(k) .. "]"
        out[#out + 1] = ni .. ks .. "=" .. ser(val, ni) .. ","
      end
    end
    return "{\n" .. table.concat(out, "\n") .. "\n" .. ind .. "}"
  elseif t == "string" then return string.format("%q", v)
  else return tostring(v) end
end
local function loadTable(path)
  local f = io.open(path, "rb"); if not f then return nil end
  local s = f:read("a"); f:close()
  local fn = load("return " .. s, "=data", "t", {})
  if not fn then return nil end
  local ok, t = pcall(fn)
  return (ok and type(t) == "table") and t or nil
end
local function saveTable(path, t)
  local f = io.open(path, "wb"); if not f then return end
  f:write(ser(t)); f:close()
end

local S = loadTable(DATA_DIR .. SEP .. "settings.lua") or {}
local function def(k, v) if S[k] == nil then S[k] = v end end
def("dock", false); def("sidepos", "left"); def("side", true)
def("icons", {}); def("rowh", 28); def("fluent_max", 5)
def("badge_order", { table.unpack(BADGE_ORDER) }); def("badge_off", {})
def("theme", "dark"); def("tcol", { dark = {}, light = {} }); def("bcol", { dark = {}, light = {} }); def("fcol", { dark = {}, light = {} })
def("rf_on", false); def("rf_mode", "both"); def("rf_max", 8); def("rf_fluent", false); def("keep_order", true)
def("keys", {}); def("launchers", {}); def("js_cats", false); def("show_hidden", false); def("fmt_sort", false); def("fmt_order", {})
def("new_days", 14); def("fluent_w", 640); def("side_w", 190); def("side_mode", "filters"); def("marquee", "hover"); def("badge_kw", false)
def("fs_ui", 13); def("fs_list", 13); def("font_family", "default"); def("font_custom", ""); def("font_bold", false); def("font_italic", false)
def("bangs", {
  { key = "ch", kind = "chain", value = "", flags = {} },
  { key = "v3", kind = "type", value = "VST3", flags = {} },
  { key = "cl", kind = "type", value = "CLAP", flags = {} },
  { key = "js", kind = "type", value = "JSFX", flags = {} },
  { key = "in", kind = "all", value = "", flags = { inst = 1 } },
  { key = "pd", kind = "all", value = "", flags = { paid = 1 } },
})
local M = loadTable(DATA_DIR .. SEP .. "meta.lua") or {}   -- per-plugin user metadata
local U = loadTable(DATA_DIR .. SEP .. "usage.lua") or {}   -- insert history: [full] = { n = count, t = last time }
local SEEN = loadTable(DATA_DIR .. SEP .. "seen.lua") or {}   -- first time each plugin was seen: .t[full] = os.time() (0 = known before tracking)
SEEN.t = SEEN.t or {}
local settings_dirty, meta_dirty, usage_dirty, seen_dirty, dirty_since = false, false, false, false, 0
local sver = 0   -- bumped whenever settings change (row badge cache key)
local function touchSettings() settings_dirty = true; sver = sver + 1; dirty_since = r.time_precise() end
local meta_ver = 0   -- bumped whenever metadata changes (search cache key)
local function touchMeta() meta_dirty = true; meta_ver = meta_ver + 1; dirty_since = r.time_precise() end
local function touchUsage() usage_dirty = true; dirty_since = r.time_precise() end
local function touchSeen() seen_dirty = true; dirty_since = r.time_precise() end
local function flushSaves()
  if settings_dirty then saveTable(DATA_DIR .. SEP .. "settings.lua", S); settings_dirty = false end
  if meta_dirty then saveTable(DATA_DIR .. SEP .. "meta.lua", M); meta_dirty = false end
  if usage_dirty then saveTable(DATA_DIR .. SEP .. "usage.lua", U); usage_dirty = false end
  if seen_dirty then saveTable(DATA_DIR .. SEP .. "seen.lua", SEEN); seen_dirty = false end
end

-------------------------------------------------------------------------------
-- State
-------------------------------------------------------------------------------
do -- migrations: every badge must be in the order list; add the default 'dbg' bang once
  local have = {}
  for _, k in ipairs(S.badge_order) do have[k] = true end
  for _, k in ipairs(BADGE_ORDER) do if not have[k] then S.badge_order[#S.badge_order + 1] = k end end
  if not S.dbg_added then
    local exists = false
    for _, b in ipairs(S.bangs) do if b.key == "dbg" then exists = true end end
    if not exists then S.bangs[#S.bangs + 1] = { key = "dbg", kind = "all", value = "", flags = { meta = 1 } } end
    S.dbg_added = true; touchSettings()
  end
end
do -- settings shape migrations
  for _, k in ipairs({ "tcol", "bcol", "fcol" }) do
    S[k].dark = S[k].dark or {}; S[k].light = S[k].light or {}
  end
  if type(S.colors) == "table" then   -- old flat badge colours -> dark theme
    for k, v in pairs(S.colors) do S.bcol.dark[k] = v end
    S.colors = nil; touchSettings()
  end
end
do -- per-format sort order must list every known format
  local have = {}
  for _, f in ipairs(S.fmt_order) do have[f] = true end
  for _, f in ipairs(FMT_LIST) do if not have[f] then S.fmt_order[#S.fmt_order + 1] = f end end
end
local function curTheme() return S.theme == "light" and "light" or "dark" end
local function applyTheme()
  local t = curTheme()
  local ov = S.tcol[t]
  for k, v in pairs(THEMES[t]) do C[k] = rgb(ov[k] or v) end
end
applyTheme()
local function badgeColor(k) local t = curTheme(); return rgb(S.bcol[t][k] or BADGE_COLOR[t][k]) end
local function fmtColor(f) local t = curTheme(); return rgb(S.fcol[t][f] or FMT_COLOR[t][f] or FMT_COLOR[t]["?"]) end

-- Custom metadata fields ("F") --------------------------------------------------------------
-- A field is { id, name, type = "bool" | "number" | "text", icon = { mode, value }, col = { dark, light },
--   show = "true" | "false"            (bool: show the badge when the value is true / false)
--   showValue, showIcon, unit          (number / text) }.  Values live in M[key].f[id].
local F = {}
function F.defaults()
  return {
    { id = "net", name = "Requires internet", type = "bool", show = "true", icon = { mode = "default", value = "net" } },
    { id = "paid", name = "Paid", type = "bool", show = "true", icon = { mode = "default", value = "paid" } },
    { id = "early", name = "Early access", type = "bool", show = "true", icon = { mode = "default", value = "early" } },
    { id = "inst", name = "Instrument", type = "bool", show = "true", icon = { mode = "default", value = "inst" } },
    { id = "x32", name = "32-bit", type = "bool", show = "true", icon = { mode = "default", value = "x32" } },
    { id = "cpu", name = "CPU", type = "number", showValue = true, showIcon = true, unit = "",
      icon = { mode = "default", value = "cpu" } },
  }
end
F.vectors = { "net", "paid", "early", "inst", "x32", "cpu", "notes", "star", "dot", "check", "flag", "bolt", "heart" }
F.counter = 0
function F.newId() F.counter = F.counter + 1; return "u" .. os.time() .. "_" .. F.counter end
function F.reindex()
  F.byId, F.query = {}, {}
  for _, d in ipairs(S.fields) do
    F.byId[d.id] = d
    F.query[d.id:lower()] = d
    local nk = (d.name:lower():gsub("%s+", ""))
    if nk ~= "" and not F.query[nk] then F.query[nk] = d end
  end
  local have = {}
  for _, k in ipairs(S.badge_order) do have[k] = true end
  for _, d in ipairs(S.fields) do if not have[d.id] then S.badge_order[#S.badge_order + 1] = d.id end end
  local keep = {}   -- drop stale badge ids of deleted fields
  for _, k in ipairs(S.badge_order) do
    if F.byId[k] or k == "dev" or k == "fmt" or k == "rating" or k == "notes" then keep[#keep + 1] = k end
  end
  S.badge_order = keep
  F.flags = F.flags or {}
  for i = #F.flags, 1, -1 do F.flags[i] = nil end
  for _, d in ipairs(S.fields) do F.flags[#F.flags + 1] = { d.id, d.name } end
  for _, x in ipairs({ { "notes", "Has notes" }, { "rated", "Rated" }, { "meta", "Has metadata" }, { "hidden", "Hidden in REAPER" }, { "new", "Newly added" } }) do
    F.flags[#F.flags + 1] = x
  end
end
function F.get(p, id)   -- raw value; "inst" falls back to the detected instrument flag
  local m = M[p.full]
  local v = m and m.f and m.f[id]
  if v == nil and id == "inst" then return p.inst end
  return v
end
function F.truthy(p, id)
  local d = F.byId[id]; if not d then return false end
  local v = F.get(p, id)
  if d.type == "bool" then return v == true end
  if d.type == "number" then return v ~= nil end
  return v ~= nil and v ~= ""
end
function F.shown(p, d)   -- should this field produce a badge on the plugin's row?
  local v = F.get(p, d.id)
  if d.type == "bool" then
    if d.show == "false" then return v ~= true end
    return v == true
  elseif d.type == "number" then return v ~= nil
  else return v ~= nil and v ~= "" end
end
function F.text(d, v)   -- value text for number / text badges
  local t
  if d.type == "number" then
    t = string.format("%.2f", v):gsub("0+$", ""):gsub("%.$", "")
  else t = tostring(v) end
  if d.unit and d.unit ~= "" then t = t .. " " .. d.unit end
  return t
end
function F.color(d)
  local t = curTheme()
  local c = d.col and d.col[t]
  if c then return rgb(c) end
  c = BADGE_COLOR[t][d.id] or (t == "dark" and 0x9aa7b5 or 0x5b6b7a)
  return rgb(c)
end
function F.hasMeta(m)
  if not m then return false end
  if (m.rating or 0) > 0 or (m.kw and #m.kw > 0) or (m.notes and m.notes ~= "") or (m.links and #m.links > 0) then return true end
  return m.f ~= nil and next(m.f) ~= nil
end

do -- build field list on first run, carry over earlier icon / colour customisations
  if type(S.fields) ~= "table" then
    S.fields = F.defaults()
    for _, d in ipairs(S.fields) do
      local ic = S.icons[d.id]
      if ic and ic.mode and ic.mode ~= "default" then d.icon = { mode = ic.mode, value = ic.value } end
      for _, th in ipairs({ "dark", "light" }) do
        local c = S.bcol[th][d.id]
        if c then d.col = d.col or {}; d.col[th] = c end
      end
    end
    touchSettings()
  end
  F.reindex()
  local changed = false   -- legacy per-plugin keys -> m.f
  for _, m in pairs(M) do
    if m.paid ~= nil or m.net ~= nil or m.early ~= nil or m.x32 ~= nil or m.inst ~= nil or m.cpu ~= nil then
      m.f = m.f or {}
      for _, k in ipairs({ "paid", "net", "early", "x32" }) do
        if m[k] == true then m.f[k] = true end
        m[k] = nil
      end
      if m.inst ~= nil then m.f.inst = m.inst; m.inst = nil end
      if m.cpu ~= nil then m.f.cpu = m.cpu; m.cpu = nil end
      changed = true
    end
  end
  if changed then touchMeta() end
end

-- Keyboard bindings (configurable) -------------------------------------------------
local KB = {}
KB.actions = {
  { id = "ins_track", label = "Insert on selected track(s)", def = { key = "Enter" } },
  { id = "ins_take", label = "Insert on selected take(s)", def = { key = "Enter", ctrl = true } },
  { id = "open_track", label = "Insert on track(s) and open FX window", def = { key = "Enter", shift = true } },
  { id = "open_take", label = "Insert on take(s) and open FX window", def = { key = "Enter", ctrl = true, shift = true } },
  { id = "fluent", label = "Toggle fluent search mode", def = { key = "S", alt = true } },
  { id = "meta", label = "Open plugin info window(s)", def = { key = "Q", alt = true } },
  { id = "bulk", label = "Bulk edit metadata", def = { key = "B", alt = true } },
  { id = "panel", label = "Toggle side panel", def = { key = "P", alt = true } },
  { id = "clear_filters", label = "Clear side-panel filters", def = { key = "C", alt = true } },
  { id = "deselect", label = "Deselect all results", def = { key = "D", ctrl = true } },
  { id = "side_mode", label = "Side panel: switch Filters / Info", def = { key = "I", alt = true } },
  { id = "close_window", label = "Close the active script window", def = { key = "W", alt = true } },
  { id = "refresh", label = "Refresh FX list", def = { key = "R", alt = true } },
  { id = "rate1", label = "Rate 1 star", def = { key = "1", alt = true } },
  { id = "rate2", label = "Rate 2 stars", def = { key = "2", alt = true } },
  { id = "rate3", label = "Rate 3 stars", def = { key = "3", alt = true } },
  { id = "rate4", label = "Rate 4 stars", def = { key = "4", alt = true } },
  { id = "rate5", label = "Rate 5 stars", def = { key = "5", alt = true } },
  { id = "rate0", label = "Clear rating", def = { key = "0", alt = true } },
}
KB.byId = {}
for _, a in ipairs(KB.actions) do KB.byId[a.id] = a end
KB.keynames = {}
do
  local names = {}
  for c = string.byte("A"), string.byte("Z") do names[#names + 1] = string.char(c) end
  for d = 0, 9 do names[#names + 1] = tostring(d) end
  for f = 1, 12 do names[#names + 1] = "F" .. f end
  for _, n in ipairs({ "Enter", "Space", "Insert", "Delete", "Home", "End", "PageUp", "PageDown", "Comma", "Period",
    "Slash", "Minus", "Equal", "Semicolon", "Apostrophe", "Backslash", "LeftBracket", "RightBracket", "GraveAccent" }) do
    names[#names + 1] = n
  end
  for _, n in ipairs(names) do if hasConst("Key_" .. n) then KB.keynames[#KB.keynames + 1] = n end end
end
function KB.get(id) return S.keys[id] or (KB.byId[id] and KB.byId[id].def) end
function KB.text(b)
  if not b then return "(none)" end
  local t = ""
  if b.ctrl then t = t .. (IS_MAC and "Cmd+" or "Ctrl+") end
  if b.shift then t = t .. "Shift+" end
  if b.alt then t = t .. (IS_MAC and "Opt+" or "Alt+") end
  return t .. b.key
end
function KB.name(id) return KB.text(KB.get(id)) end
function KB.needsMod(key)   -- keys that would otherwise type into the search box
  return not (key == "Enter" or key == "Insert" or key:match("^F%d+$") ~= nil)
end
function KB.mods()
  local m = r.ImGui_GetKeyMods(ctx)
  return (m & (KC.Mod_Ctrl | KC.Mod_Super)) ~= 0, (m & KC.Mod_Shift) ~= 0, (m & KC.Mod_Alt) ~= 0
end
function KB.hit(id)
  local b = KB.get(id); if not b then return false end
  local ctrl, shift, alt = KB.mods()
  if ctrl ~= (b.ctrl == true) or shift ~= (b.shift == true) or alt ~= (b.alt == true) then return false end
  if r.ImGui_IsKeyPressed(ctx, KC["Key_" .. b.key], false) then return true end
  return b.key == "Enter" and r.ImGui_IsKeyPressed(ctx, KC.Key_KeypadEnter, false)
end

local st = {
  text = "", bang = nil, dirty = true, results = {}, sel = {}, cursor = 1, anchor = 1,
  fluent = false, status = "", status_t = 0, focus = true, scroll = false,
  selfmt = {}, selcat = {}, seldev = {}, selfold = {},
  meta_open = false, settings_open = false, edit = false, ed = nil, newlink = "",
  undock = false, nw = 900, nh = 560, fl_h = nil, fl_restore = false, qver = 0,
  drag = false, pending_collapse = nil, open_menu = nil,
  seq = {}, seqn = 0, infos = {}, bulk = nil, capture = nil, capture_err = nil, dead = nil, quit = false,
  autoclose = false, frame = 0, want_focus = false, rfActive = false, wx = nil, wy = nil, fonts_dirty = true,
}
local DB = { items = {}, byKey = {}, f = {} }
local Q, Act = {}, {}
local openInfo, openBulk, recordUse   -- defined further down
local function status(msg) st.status = msg; st.status_t = r.time_precise() end
-- Programmatically replace the search text. The input widget is recreated (new ID) because an active
-- ImGui text field ignores external changes to its buffer.
local function setText(t)
  st.text = t; st.qver = st.qver + 1; st.focus = true; st.dirty = true
  st.cursor = 1; st.anchor = 1; st.sel = {}; st.scroll = true
end

-------------------------------------------------------------------------------
-- Plugin name parsing / cleaning
-------------------------------------------------------------------------------
local PFX = { VST = "VST2", VSTi = "VST2", VST3 = "VST3", VST3i = "VST3", CLAP = "CLAP", CLAPi = "CLAP",
  JS = "JSFX", AU = "AU", AUi = "AU", LV2 = "LV2", LV2i = "LV2", DX = "DX", DXi = "DX" }

local function isJunkParen(s)
  s = s:lower()
  return s:match("^x?%d+$") or s:match("^%d+[%- ]?bit") or s:match("^%d+%s*out") or s:match("^%d+%s*in")
      or s:match("^%d+ch$") or s == "mono" or s == "stereo" or s == "multi" or s == "mc" or s:match("^x%d+$")
end

local devCanon = {}
local function canonDev(d)
  d = trim(d)
  local k = d:lower():gsub("[,%.]", ""):gsub("%s+inc$", ""):gsub("%s+llc$", ""):gsub("%s+ltd$", ""):gsub("%s+gmbh$", ""):gsub("%s+co$", "")
  k = trim(k)
  if k == "" then return "" end
  if not devCanon[k] then devCanon[k] = d end
  return devCanon[k]
end

local function parseName(full)
  local pre, rest = full:match("^(%w+):%s*(.*)$")
  local fmt, inst = "?", false
  if pre and PFX[pre] then fmt = PFX[pre]; inst = pre:sub(-1) == "i"
  else rest = full end
  local base, dev = rest, nil
  for _ = 1, 3 do
    local head, inner = base:match("^(.-)%s*%(([^()]*)%)%s*$")
    if not head or head == "" then break end
    if isJunkParen(inner) then base = head
    elseif not dev then dev = inner; base = head
    else break end
  end
  base = base:gsub("[%s_]+[xX]64$", ""):gsub("[%s_]+[xX]86$", ""):gsub("%s*%(?64[%- ]?[bB]it%)?$", "")
  base = trim(base)
  local name = base
  if dev and dev ~= "" then
    local ld, ln = dev:lower(), base:lower()
    if ln:sub(1, #ld + 1) == ld .. " " and #base > #dev + 2 then name = trim(base:sub(#dev + 2)) end
  end
  if name == "" then name = full end
  return fmt, inst, name, dev and canonDev(dev) or "", base
end

-------------------------------------------------------------------------------
-- INI parsing
-------------------------------------------------------------------------------
local function parseIni(path, lastEq)
  local f = io.open(path, "rb"); if not f then return nil end
  local secs, order, cur = {}, {}, nil
  for line in f:lines() do
    line = line:gsub("\r$", "")
    local s = line:match("^%[(.-)%]$")
    if s then cur = { map = {}, list = {} }; secs[s] = cur; order[#order + 1] = s
    elseif cur and line ~= "" then
      local k, v
      if lastEq then k, v = line:match("^(.*)=(.*)$") else k, v = line:match("^([^=]*)=(.*)$") end
      if k then cur.map[k] = v; cur.list[#cur.list + 1] = { k, v } end
    end
  end
  f:close()
  return secs, order
end

-------------------------------------------------------------------------------
-- Database build
-------------------------------------------------------------------------------
local function subseq(s, v)
  local pos = 1
  for i = 1, #v do
    local a = s:find(v:sub(i, i), pos, true)
    if not a then return false end
    pos = a + 1
  end
  return true
end

local function reindex(p)
  local m = M[p.full]
  p.lname = p.name:lower(); p.ldev = p.dev:lower()
  p.lcats = table.concat(p.cats, "|"):lower()
  p.lfolders = table.concat(p.folderList, "|"):lower()
  local kw = (m and m.kw) and table.concat(m.kw, " "):lower() or ""
  local extra = ((p.orig and p.orig:lower() or "") .. " " .. (p.autoKw and table.concat(p.autoKw, " ") or ""))
  p.hay = p.lname .. " " .. p.ldev .. " " .. p.fmt:lower() .. " " .. p.lcats .. " " .. kw .. " " .. extra
end

local function scanChains(dir, rel, out)
  r.EnumerateFiles(dir, -1); r.EnumerateSubdirectories(dir, -1)
  local i = 0
  while true do
    local f = r.EnumerateFiles(dir, i); if not f then break end
    if f:lower():match("%.rfxchain$") then out[#out + 1] = { rel = rel, file = f } end
    i = i + 1
  end
  i = 0
  local subs = {}
  while true do
    local d = r.EnumerateSubdirectories(dir, i); if not d then break end
    subs[#subs + 1] = d; i = i + 1
  end
  for _, d in ipairs(subs) do scanChains(dir .. SEP .. d, rel == "" and d or (rel .. "/" .. d), out) end
end

local function newFacet() return { cnt = {}, names = {} } end
local function bump(f, k)
  if not f.cnt[k] then f.cnt[k] = 0; f.names[#f.names + 1] = k end
  f.cnt[k] = f.cnt[k] + 1
end
local function lookup(s)
  return DB.byKey[s] or DB.byKey[s:lower()]
end

-- Read-only access to REAPER's own files; nothing here ever writes to them.
local FXTYPE = { [1] = { LV2 = true }, [2] = { JSFX = true }, [3] = { VST2 = true, VST3 = true }, [5] = { AU = true },
  [7] = { CLAP = true } }

local function listResFiles(pattern)
  local out, i = {}, 0
  while true do
    local f = r.EnumerateFiles(RES, i); if not f then break end
    if f:lower():match(pattern) then out[#out + 1] = RES .. SEP .. f end
    i = i + 1
  end
  return out
end

function DB.build()
  local t0 = r.time_precise()
  devCanon = {}
  local items = {}
  local i = 0
  while true do
    local ok, full, ident = r.EnumInstalledFX(i)
    if not ok then break end
    i = i + 1
    local fmt, inst, name, dev, base = parseName(full)
    ident = ident or ""
    items[#items + 1] = { kind = "fx", full = full, ident = ident, name = name, dev = dev, fmt = fmt, inst = inst, pdev = dev,
      cats = {}, folderList = {}, folders = {}, add = full, base = base }
  end

  -- Index: every spelling REAPER's ini files may use for a plugin -> plugin(s)
  local idx = {}
  local function indexPlugin(p)
    local seen = {}
    local function add(k)
      if k and k ~= "" and not seen[k] then
        seen[k] = true
        local l = idx[k]
        if not l then idx[k] = { p } elseif l[#l] ~= p then l[#l + 1] = p end
      end
    end
    local id = p.ident:lower()
    add(id); add((id:gsub(" ", "_")))
    local b = id:match("([^/\\]+)$") or id
    local bundle = id:match("([^/\\]+%.vst3)[/\\]") or (b:match("%.vst3$") and b or nil)
    for _, v in ipairs({ b, bundle or "" }) do
      if v ~= "" then
        add(v); add((v:gsub(" ", "_")))
        local noext = v:gsub("%.[^.]+$", "")
        add(noext); add((noext:gsub(" ", "_")))
        local noext2 = noext:gsub("%.vst$", "")
        add(noext2); add((noext2:gsub(" ", "_")))
      end
    end
    if p.fmt == "JSFX" then
      local jp = id:gsub("%.jsfx$", ""); add(jp); add((jp:gsub(" ", "_")))
      local js = (jp:match("([^/\\]+)$")); add(js)
    end
    local lf = p.full:lower()
    add(lf); add((lf:gsub("^%w+:%s*", "")))
  end
  for _, p in ipairs(items) do indexPlugin(p) end

  local function findAll(key, allowed)
    key = trim(key or "")
    if key == "" then return nil end
    local lk = key:lower():gsub('^"(.*)"$', "%1")
    local tries = { lk, (lk:gsub("_", " ")) }
    local b = lk:match("([^/\\]+)$")
    if b and b ~= lk then tries[#tries + 1] = b; tries[#tries + 1] = (b:gsub("_", " ")) end
    for _, t in ipairs(tries) do
      local l = idx[t]
      if l then
        local out
        for _, p in ipairs(l) do
          if not allowed or allowed[p.fmt] then out = out or {}; out[#out + 1] = p end
        end
        if out then return out end
      end
    end
    return nil
  end

  local stats = { folders = {}, unmatched = {}, unTags = {}, unHidden = {}, tagKeys = 0 }

  -- Tags: [category] / [developer]; reaper-fxfolders.ini holds the user's overrides in the same sections.
  local tagCat, tagDev, knownDev = {}, {}, {}
  local function applyTags(path)
    local secs = parseIni(path, true)
    if not secs then return false end
    for sname, sec in pairs(secs) do
      local ln = sname:lower()
      local target = (ln == "category" or ln == "categories") and tagCat or ((ln == "developer" or ln == "developers") and tagDev or nil)
      if target then
        for _, kv in ipairs(sec.list) do
          stats.tagKeys = stats.tagKeys + 1
          local ps = findAll(kv[1])
          if ps then for _, p in ipairs(ps) do target[p] = kv[2] end
          elseif #stats.unTags < 400 then stats.unTags[#stats.unTags + 1] = sname .. ": " .. kv[1] end
          if target == tagDev then
            for d in kv[2]:gmatch("[^|]+") do knownDev[trim(d):lower()] = true end
          end
        end
      end
    end
    return true
  end
  applyTags(RES .. SEP .. "reaper-fxtags.ini")
  applyTags(RES .. SEP .. "reaper-fxfolders.ini")
  DB.tagInfo = { cat = 0, dev = 0 }
  for _ in pairs(tagCat) do DB.tagInfo.cat = DB.tagInfo.cat + 1 end
  for _ in pairs(tagDev) do DB.tagInfo.dev = DB.tagInfo.dev + 1 end

  -- Original names (before the user renamed them in REAPER) and renamed flags
  local origOf = {}
  for _, path in ipairs(listResFiles("^reaper%-vstplugins.*%.ini$")) do
    local secs = parseIni(path, false)
    local sec = secs and secs["vstcache"]
    if sec then
      for _, kv in ipairs(sec.list) do
        local nm = kv[2]:match("^[^,]*,[^,]*,(.*)$")
        if nm and nm ~= "" then origOf[kv[1]:lower()] = nm end
      end
    end
  end
  local clapOrig = {}
  for _, path in ipairs(listResFiles("^reaper%-clap%-.*%.ini$")) do
    if not path:lower():find("rename", 1, true) then
      local secs = parseIni(path, false)
      if secs then
        for _, sec in pairs(secs) do
          for _, kv in ipairs(sec.list) do
            if kv[1] ~= "_" then
              local nm = kv[2]:match("^%d*|(.*)$")
              if nm and nm ~= "" then clapOrig[kv[1]:lower()] = nm end
            end
          end
        end
      end
    end
  end
  local nRenamed = 0
  local function markRenamed(p, orig)
    if not p.renamed then p.renamed = true; nRenamed = nRenamed + 1 end
    if orig and orig ~= "" then p.orig = orig end
  end
  for _, path in ipairs(listResFiles("^reaper%-vstrenames.*%.ini$")) do
    local secs = parseIni(path, false)
    local sec = secs and secs["vstaliasinfo"]
    if sec then
      for _, kv in ipairs(sec.list) do
        local ps = findAll(kv[1], { VST2 = true, VST3 = true })
        if ps then for _, p in ipairs(ps) do markRenamed(p, origOf[kv[1]:lower()] or origOf[(kv[1]:lower():gsub("_", " "))]) end end
      end
    end
  end
  for _, path in ipairs(listResFiles("^reaper%-clap%-rename.*%.ini$")) do
    local secs = parseIni(path, false)
    local sec = secs and secs["renames"]
    if sec then
      for _, kv in ipairs(sec.list) do
        local ps = findAll(kv[1], { CLAP = true })
        if ps then for _, p in ipairs(ps) do markRenamed(p, clapOrig[kv[1]:lower()]) end end
      end
    end
  end
  -- developer hints inside the original cache names
  for _, nm in pairs(origOf) do
    local d = nm:match("%(([^()]*)%)%s*$")
    if d and not isJunkParen(d) then knownDev[d:lower()] = true end
  end

  -- JSFX tags (reaper-jsfx.ini: TAGS <path> "words")
  local nJsTags = 0
  do
    local f = io.open(RES .. SEP .. "reaper-jsfx.ini", "rb")
    if f then
      for line in f:lines() do
        local path, words = line:match('^TAGS%s+(.-)%s+"([^"]*)"%s*$')
        if path then
          local ps = findAll(path, { JSFX = true })
          if ps then
            local kws = {}
            for w in words:gmatch("%S+") do kws[#kws + 1] = w end
            for _, p in ipairs(ps) do
              p.autoKw = kws; nJsTags = nJsTags + 1
              for _, w in ipairs(kws) do if w:lower() == "instrument" then p.inst = true end end
            end
          end
        end
      end
      f:close()
    end
  end

  -- Resolve developer and categories
  for _, p in ipairs(items) do
    local d = tagDev[p]
    if d and d ~= "" then p.dev = canonDev(trim(d:match("^[^|]+") or d))
    else
      local dd = p.pdev
      if p.orig then
        local _, _, _, od = parseName(p.orig)
        if od and od ~= "" then dd = od end
      end
      if p.fmt == "JSFX" and dd ~= "" and not knownDev[dd:lower()] then dd = "" end
      p.dev = dd ~= "" and canonDev(dd) or ""
    end
    local tc = tagCat[p]
    if tc and tc ~= "" then for c in tc:gmatch("[^|]+") do c = trim(c); if c ~= "" then p.cats[#p.cats + 1] = c end end end
    if #p.cats == 0 and p.fmt == "JSFX" and S.js_cats then
      local dir = p.ident:match("^(.*)[/\\][^/\\]+$")
      if dir and dir ~= "" then p.cats[1] = dir:sub(1, 1):upper() .. dir:sub(2) end
    end
  end

  -- FX chains
  local chains = {}
  scanChains(RES .. SEP .. "FxChains", "", chains)
  local chainFolders = {}
  for _, c in ipairs(chains) do
    local rel = (c.rel ~= "" and (c.rel .. "/") or "") .. c.file
    items[#items + 1] = { kind = "chain", full = "CHAIN:" .. rel, ident = rel, name = c.file:gsub("%.[Rr]fx[Cc]hain$", ""),
      dev = "", fmt = "CHAIN", inst = false, cats = {}, folderList = {}, folders = {}, sub = c.rel,
      add = IS_WIN and (rel:gsub("/", "\\")) or rel, chainFolder = c.rel }
    if c.rel ~= "" then chainFolders[c.rel] = true end
  end

  DB.items, DB.byKey, DB.fullSet = items, {}, {}
  DB.chainByName = {}
  local firstRun = next(SEEN.t) == nil and #items > 0   -- first ever scan: everything counts as already known
  local nowT = os.time()
  for n, p in ipairs(items) do
    if p.kind == "fx" then
      local t = SEEN.t[p.full]
      if t == nil then t = firstRun and 0 or nowT; SEEN.t[p.full] = t; touchSeen() end
      p.added = t
    end
    p.id = n; p.lfull = p.full:lower()
    DB.byKey[p.full] = p; DB.fullSet[p.full] = true
    if p.kind == "chain" then
      DB.chainByName[p.name:lower()] = DB.chainByName[p.name:lower()] or p
      DB.chainByName[(p.ident:gsub("%.[Rr]fx[Cc]hain$", "")):lower()] = p
    end
  end

  -- FX folders and hidden FX (reaper-fxfolders.ini)
  --   [Folders] NbFolders, IdN, NameN     [FolderID] ItemK, TypeK     [HiddenFX] ItemN, TypeN
  --   TypeK 1048576 = smart folder (search string), 1000 = FX chain, 2 JSFX, 3 VST/VST3, 7 CLAP, 1 LV2, 5 AU
  local function addTo(p, fname)
    if not p.folders[fname] then p.folders[fname] = true; p.folderList[#p.folderList + 1] = fname end
  end
  local fx, order = parseIni(RES .. SEP .. "reaper-fxfolders.ini")
  stats.hasFile = fx ~= nil
  local nHidden = 0
  if fx then
    local head = fx["Folders"] and fx["Folders"].map or {}
    local defs = {}
    local nb = tonumber(head.NbFolders) or 0
    for k = 0, nb - 1 do defs[#defs + 1] = { id = head["Id" .. k] or tostring(k), name = head["Name" .. k] or ("Folder " .. k) } end
    if nb == 0 then
      for _, sname in ipairs(order) do
        local ix = sname:match("^[Ff]older(%d+)$")
        if ix then defs[#defs + 1] = { id = ix, name = head["Name" .. ix] or ("Folder " .. ix) } end
      end
    end
    for _, d in ipairs(defs) do
      local info = { name = d.name, items = 0, smart = 0, matched = 0 }
      stats.folders[#stats.folders + 1] = info
      local sec = fx["Folder" .. d.id]
      if sec then
        local k = 0
        while true do
          local v = sec.map["Item" .. k]
          if v == nil then break end
          local ty = tonumber(sec.map["Type" .. k]) or 0
          info.items = info.items + 1
          local plain = trim(v):gsub('^"(.*)"$', "%1")
          if ty == 1000 then
            local p = DB.chainByName[plain:lower()]
            if p then addTo(p, d.name); info.matched = info.matched + 1
            else stats.unmatched[#stats.unmatched + 1] = d.name .. ": chain '" .. plain .. "'" end
          elseif (ty & 1048576) ~= 0 then
            info.smart = info.smart + 1
            local groups = Q.smartCompile(v)
            for _, p in ipairs(items) do
              if p.kind == "fx" and Q.smartMatch(groups, p.lfull) then addTo(p, d.name); info.matched = info.matched + 1 end
            end
          else
            local ps = findAll(plain, FXTYPE[ty]) or findAll(plain:match("^[^|]+") or plain, FXTYPE[ty])
              or findAll(plain:match("([^|]+)$") or plain, FXTYPE[ty])
            if ps then for _, p in ipairs(ps) do addTo(p, d.name) end; info.matched = info.matched + 1
            else stats.unmatched[#stats.unmatched + 1] = d.name .. ": '" .. plain .. "' (type " .. ty .. ")" end
          end
          k = k + 1
        end
      end
    end
    local hs = fx["HiddenFX"]
    if hs then
      local k = 0
      while true do
        local v = hs.map["Item" .. k]
        if v == nil then break end
        local ty = tonumber(hs.map["Type" .. k])
        local ps = findAll(v, ty and FXTYPE[ty] or nil) or findAll(v)
        if ps then for _, p in ipairs(ps) do if not p.hidden then p.hidden = true; nHidden = nHidden + 1 end end
        elseif #stats.unHidden < 200 then stats.unHidden[#stats.unHidden + 1] = v .. " (type " .. tostring(ty) .. ")" end
        k = k + 1
      end
    end
  end
  for _, p in ipairs(items) do
    if p.kind == "chain" and p.chainFolder ~= "" and not p.folders[p.chainFolder] then
      p.folders[p.chainFolder] = true; p.folderList[#p.folderList + 1] = p.chainFolder
    end
  end

  -- keep the list alphabetical (the empty-query view relies on this) and build facets
  for _, p in ipairs(items) do reindex(p) end
  table.sort(items, function(a, b) if a.lname ~= b.lname then return a.lname < b.lname end return a.full < b.full end)
  local FA = { fmt = newFacet(), cat = newFacet(), dev = newFacet(), fold = newFacet(), chainf = { names = {} } }
  for _, p in ipairs(items) do
    bump(FA.fmt, p.fmt)
    if p.kind == "fx" and not (p.hidden and not S.show_hidden) then
      if #p.cats == 0 then bump(FA.cat, "Uncategorized") else for _, c in ipairs(p.cats) do bump(FA.cat, c) end end
      if p.dev ~= "" then bump(FA.dev, p.dev) end
    end
    for _, fo in ipairs(p.folderList) do bump(FA.fold, fo) end
  end
  for k in pairs(chainFolders) do FA.chainf.names[#FA.chainf.names + 1] = k end
  local function alpha(a, b) return a:lower() < b:lower() end
  table.sort(FA.cat.names, alpha); table.sort(FA.dev.names, alpha); table.sort(FA.fold.names, alpha)
  table.sort(FA.chainf.names, alpha)
  table.sort(FA.fmt.names, function(a, b) return FA.fmt.cnt[a] > FA.fmt.cnt[b] end)
  DB.f = FA
  stats.hidden, stats.renamed, stats.jstags = nHidden, nRenamed, nJsTags
  stats.ms = (r.time_precise() - t0) * 1000
  DB.stats = stats
  DB.hiddenCount = nHidden
  DB.version = (DB.version or 0) + 1
  Q._cutT = nil
  DB.countNew()
  Q.cache = nil
  st.dirty = true; st.rep = nil; st.dead = nil
end

function DB.report()
  local nfx, nch, ncat, ndev = 0, 0, 0, 0
  local samples, sc = {}, {}
  for _, p in ipairs(DB.items) do
    if p.kind == "fx" then
      nfx = nfx + 1
      if #p.cats > 0 then ncat = ncat + 1 end
      if p.dev ~= "" then ndev = ndev + 1 end
      sc[p.fmt] = (sc[p.fmt] or 0) + 1
      if sc[p.fmt] <= 3 then samples[#samples + 1] = ("  %s | ident=%s | full=%s"):format(p.fmt, p.ident, p.full) end
    else nch = nch + 1 end
  end
  local ti = DB.tagInfo or { cat = 0, dev = 0 }
  local stt = DB.stats or {}
  local sum = ("%d plugins, %d chains. Categories found for %d, developers for %d (tag entries: %d category, %d developer). Folders: %d. Hidden: %d, renamed: %d, JSFX tags: %d. Scan: %.0f ms."):format(
    nfx, nch, ncat, ndev, ti.cat, ti.dev, DB.stats and #DB.stats.folders or 0, stt.hidden or 0, stt.renamed or 0, stt.jstags or 0, stt.ms or 0)
  local L = { sum, "" }
  for _, f in ipairs({ "reaper-fxtags.ini", "reaper-fxfolders.ini", "reaper-vstplugins64.ini", "reaper-jsfx.ini", "reaper-recentfx.ini" }) do
    local h = io.open(RES .. SEP .. f, "rb"); L[#L + 1] = f .. ": " .. (h and "found" or "missing"); if h then h:close() end
  end
  L[#L + 1] = ""; L[#L + 1] = "Folders:"
  for _, f in ipairs(DB.stats and DB.stats.folders or {}) do
    L[#L + 1] = ("  %s: %d item(s), %d smart, %d match(es)"):format(f.name, f.items, f.smart, f.matched)
  end
  if DB.stats and #DB.stats.unmatched > 0 then
    L[#L + 1] = ""; L[#L + 1] = "Unmatched folder items:"
    for i = 1, math.min(15, #DB.stats.unmatched) do L[#L + 1] = "  " .. DB.stats.unmatched[i] end
  end
  if DB.stats and #DB.stats.unTags > 0 then
    L[#L + 1] = ""; L[#L + 1] = ("Tag entries without an installed plugin (%d, usually stale):"):format(#DB.stats.unTags)
    for k = 1, math.min(10, #DB.stats.unTags) do L[#L + 1] = "  " .. DB.stats.unTags[k] end
  end
  if DB.stats and #DB.stats.unHidden > 0 then
    L[#L + 1] = ""; L[#L + 1] = ("Hidden entries without an installed plugin (%d):"):format(#DB.stats.unHidden)
    for k = 1, math.min(10, #DB.stats.unHidden) do L[#L + 1] = "  " .. DB.stats.unHidden[k] end
  end
  L[#L + 1] = ""; L[#L + 1] = "Sample plugin identifiers:"
  for _, x in ipairs(samples) do L[#L + 1] = x end
  return { summary = sum, full = table.concat(L, "\n") }
end

-------------------------------------------------------------------------------
-- Query engine
-------------------------------------------------------------------------------
local FIELDS = { dev = "dev", developer = "dev", d = "dev", fmt = "fmt", format = "fmt", type = "fmt", t = "fmt",
  cat = "cat", category = "cat", c = "cat", folder = "folder", f = "folder", is = "is", rating = "rating",
  stars = "rating", kw = "kw", keyword = "kw" }

local function tokens(s)
  local out, i, n = {}, 1, #s
  while i <= n do
    if s:sub(i, i):match("%s") then i = i + 1
    else
      local j, buf, inq = i, "", false
      while j <= n do
        local ch = s:sub(j, j)
        if ch == '"' then inq = not inq
        elseif ch:match("%s") and not inq then break
        else buf = buf .. ch end
        j = j + 1
      end
      out[#out + 1] = buf; i = j
    end
  end
  return out
end

function Q.compile(q)
  q = q:lower()
  local parts, s = {}, q
  while true do
    local a, b = s:find("||", 1, true)
    if not a then parts[#parts + 1] = s; break end
    parts[#parts + 1] = s:sub(1, a - 1); s = s:sub(b + 1)
  end
  local groups = {}
  local subs = {}   -- "a && b": each side is its own search; results of earlier sides are listed first
  for _, part in ipairs(parts) do
    local s2 = part
    local segs = {}
    while true do
      local a, b = s2:find("&&", 1, true)
      if not a then segs[#segs + 1] = s2; break end
      segs[#segs + 1] = s2:sub(1, a - 1); s2 = s2:sub(b + 1)
    end
    for i, sg in ipairs(segs) do subs[#subs + 1] = { text = sg, bonus = (#segs > 1) and (#segs - i + 1) * 1000 or 0 } end
  end
  for _, sub in ipairs(subs) do
    local part = sub.text
    local terms = { bonus = sub.bonus }
    for _, tk in ipairs(tokens(part)) do
      local neg = false
      if tk:sub(1, 1) == "-" and #tk > 1 then neg = true; tk = tk:sub(2) end
      local f, v = tk:match("^(%a+):(.+)$")
      local term
      if f and FIELDS[f] then
        term = { f = FIELDS[f], v = v }
        if term.f == "rating" then
          local op, num = v:match("^([<>=]*)(%d+%.?%d*)$")
          if num then term.op = (op == "" and "=" or op); term.num = tonumber(num) else term = nil end
        end
      elseif f and F.query[f] then
        local d = F.query[f]
        term = { f = "field", d = d, v = v }
        if d.type == "number" then
          local op, num = v:match("^([<>=]*)(%-?%d+%.?%d*)$")
          if num then term.op = (op == "" and "=" or op); term.num = tonumber(num) else term = nil end
        end
      else term = { f = "text", v = tk } end
      if term then term.neg = neg; terms[#terms + 1] = term end
    end
    if #terms > 0 then groups[#groups + 1] = terms end
  end
  return groups
end

local function mflag(p, k)
  local m = M[p.full]
  if F.byId[k] then return F.truthy(p, k)
  elseif k == "hidden" then return p.hidden == true
  elseif k == "new" then return Q.isNew(p)
  elseif k == "free" then return not F.truthy(p, "paid")
  elseif k == "notes" then return (m and ((m.notes and m.notes ~= "") or (m.links and #m.links > 0))) and true or false
  elseif k == "rated" then return (m and (m.rating or 0) > 0) and true or false
  elseif k == "meta" then return F.hasMeta(m)
  end
  return false
end
local IS_MAP = { free = "free", online = "net", internet = "net", instrument = "inst", ["32"] = "x32", notes = "notes",
  rated = "rated", meta = "meta", tagged = "meta", hidden = "hidden", new = "new", added = "new" }

local function cmp(a, op, b)
  if op == ">=" then return a >= b elseif op == "<=" then return a <= b
  elseif op == ">" then return a > b elseif op == "<" then return a < b end
  return a == b
end

function Q.term(p, t)
  local f, v = t.f, t.v
  if f == "text" then
    local pos = p.lname:find(v, 1, true)
    if pos then
      if pos == 1 then return 100 end
      if p.lname:sub(pos - 1, pos - 1):match("[%s%-_%.]") then return 80 end
      return 60
    end
    if p.hay:find(v, 1, true) then return 30 end
    if S.badge_kw then
      local bw = p._bw
      local key = meta_ver .. ":" .. sver
      if not bw or bw.key ~= key then
        local w = {}
        for _, d in ipairs(S.fields) do if F.shown(p, d) then w[#w + 1] = d.name:lower() end end
        local m = M[p.full]
        if m and (m.rating or 0) > 0 then w[#w + 1] = "rated" end
        if m and ((m.notes and m.notes ~= "") or (m.links and #m.links > 0)) then w[#w + 1] = "notes" end
        if p.hidden then w[#w + 1] = "hidden" end
        if Q.isNew(p) then w[#w + 1] = "new" end
        bw = { key = key, s = table.concat(w, " ") }; p._bw = bw
      end
      if bw.s:find(v, 1, true) then return 25 end
    end
    if #v >= 3 and subseq(p.lname, v) then return 10 end
    return nil
  elseif f == "dev" then return p.ldev:find(v, 1, true) and 50 or nil
  elseif f == "fmt" then local lf = p.fmt:lower(); return (lf:find(v, 1, true) == 1) and 50 or nil
  elseif f == "cat" then return p.lcats:find(v, 1, true) and 50 or nil
  elseif f == "folder" then return p.lfolders:find(v, 1, true) and 50 or nil
  elseif f == "kw" then
    local m = M[p.full]
    return (m and m.kw and table.concat(m.kw, " "):lower():find(v, 1, true)) and 50 or nil
  elseif f == "is" then
    local k = IS_MAP[v] or (F.query[v] and F.query[v].id)
    if not k then return nil end
    return mflag(p, k) and 20 or nil
  elseif f == "rating" then
    local m = M[p.full]; return cmp((m and m.rating) or 0, t.op, t.num) and 20 or nil
  elseif f == "field" then
    local d = t.d
    local val = F.get(p, d.id)
    if d.type == "bool" then
      local want = not (t.v == "no" or t.v == "false" or t.v == "0" or t.v == "off")
      return ((val == true) == want) and 20 or nil
    elseif d.type == "number" then
      if val == nil then return nil end
      return cmp(val, t.op, t.num) and 20 or nil
    end
    return (val and tostring(val):lower():find(t.v, 1, true)) and 40 or nil
  end
  return nil
end

function Q.run(groups, p)
  if #groups == 0 then return 0 end
  local best
  for _, terms in ipairs(groups) do
    local sc, ok = 0, true
    for _, t in ipairs(terms) do
      local s = Q.term(p, t)
      if t.neg then if s then ok = false; break end
      else if not s then ok = false; break end; sc = sc + s end
    end
    if ok then sc = sc + (terms.bonus or 0); if not best or sc > best then best = sc end end
  end
  return best
end

-- REAPER smart-folder search strings: "quoted phrase", OR, NOT, AND (implicit), matched against the display name.
function Q.smartCompile(str)
  local toks, i, n = {}, 1, #str
  while i <= n do
    local c = str:sub(i, i)
    if c:match("%s") then i = i + 1
    elseif c == '"' then
      local j = str:find('"', i + 1, true) or (n + 1)
      toks[#toks + 1] = { t = str:sub(i + 1, j - 1):lower() }; i = j + 1
    else
      local j = i
      while j <= n and not str:sub(j, j):match("%s") do j = j + 1 end
      local w = str:sub(i, j - 1)
      local isop = (w == "OR" or w == "NOT" or w == "AND")
      toks[#toks + 1] = { t = isop and w or w:lower(), op = isop }
      i = j
    end
  end
  local groups, cur, neg = {}, {}, false
  for _, k in ipairs(toks) do
    if k.op and k.t == "OR" then
      if #cur > 0 then groups[#groups + 1] = cur end
      cur, neg = {}, false
    elseif k.op and k.t == "NOT" then neg = true
    elseif k.op then -- AND: no-op
    else cur[#cur + 1] = { v = k.t, neg = neg }; neg = false end
  end
  if #cur > 0 then groups[#groups + 1] = cur end
  return groups
end
function Q.smartMatch(groups, hay)
  for _, g in ipairs(groups) do
    local ok = true
    for _, t in ipairs(g) do
      local found = hay:find(t.v, 1, true) ~= nil
      if found == t.neg then ok = false; break end
    end
    if ok then return true end
  end
  return false
end

local function anySel(t) return next(t) ~= nil end
local function passesBang(p, b)
  if b.kind == "chain" then
    if p.kind ~= "chain" then return false end
    if b.value and b.value ~= "" and p.chainFolder ~= b.value then return false end
  elseif b.kind ~= "all" then
    if p.kind == "chain" then return false end
    local v = b.value or ""
    if v ~= "" then
      if b.kind == "type" and p.fmt ~= v then return false
      elseif b.kind == "category" then
        local hit = false
        if v == "Uncategorized" then hit = #p.cats == 0 else for _, c in ipairs(p.cats) do if c == v then hit = true end end end
        if not hit then return false end
      elseif b.kind == "folder" and not p.folders[v] then return false
      elseif b.kind == "developer" and p.dev ~= v then return false end
    end
  end
  for k, mode in pairs(b.flags or {}) do
    local on = mflag(p, k)
    if mode == 1 and not on then return false end
    if mode == -1 and on then return false end
  end
  if b.query and b.query ~= "" then   -- any search syntax: fmt:vst3 cpu:<1 is:paid mood:warm ...
    if b._qk ~= b.query then b._qk = b.query; b._qc = Q.compile(b.query) end
    if #b._qc > 0 and not Q.run(b._qc, p) then return false end
  end
  return true
end

-- Recent / frequent plugins shown when the search box is empty.
function Q.rfList()
  local rec, frq = {}, {}
  for full, u in pairs(U) do
    local p = DB.byKey[full]
    if p and p.full == full and (u.n or 0) > 0 then
      rec[#rec + 1] = { p = p, t = u.t or 0 }
      frq[#frq + 1] = { p = p, n = u.n, t = u.t or 0 }
    end
  end
  table.sort(rec, function(a, b) return a.t > b.t end)
  table.sort(frq, function(a, b) if a.n ~= b.n then return a.n > b.n end return a.t > b.t end)
  local max, out, seen = S.rf_max, {}, {}
  local function add(e) if not seen[e.p.id] and #out < max then seen[e.p.id] = true; out[#out + 1] = e.p end end
  if S.rf_mode == "recent" then for _, e in ipairs(rec) do add(e) end
  elseif S.rf_mode == "frequent" then for _, e in ipairs(frq) do add(e) end
  else
    for i = 1, math.min(math.ceil(max / 2), #rec) do add(rec[i]) end
    for _, e in ipairs(frq) do add(e) end
    for _, e in ipairs(rec) do add(e) end
  end
  return out
end

local function selSig(t)
  local k = {}
  for key in pairs(t) do k[#k + 1] = key end
  table.sort(k); return table.concat(k, "\1")
end
-- Filters that apply regardless of the query text (side panel, scope, hidden toggle, metadata version).
function Q.filterSig(showHidden)
  local b = st.bang
  return table.concat({ selSig(st.selfmt), selSig(st.selcat), selSig(st.seldev), selSig(st.selfold),
    b and (b.key .. tostring(b.invert) .. (b.query or "")) or "", showHidden and "H" or "h", meta_ver, DB.version or 0,
    st.onlyNew and ("N" .. S.new_days) or "", S.badge_kw and "K" or "k",
    S.fmt_sort and table.concat(S.fmt_order, ",") or "" }, "\2")
end

function Q.isNew(p)
  local a = p.added
  if not a or a <= 0 then return false end
  local now = os.time()
  if Q._cutT ~= now then Q._cutT = now; Q.newCut = now - S.new_days * 86400 end
  return a >= Q.newCut
end
function DB.countNew()
  local n = 0
  for _, p in ipairs(DB.items) do if p.kind == "fx" and Q.isNew(p) then n = n + 1 end end
  DB.newCount = n
end

function Q.refresh()
  st.rfActive = false
  if S.rf_on and st.text == "" and not st.bang and (not st.fluent or S.rf_fluent)
      and not (anySel(st.selfmt) or anySel(st.selcat) or anySel(st.seldev) or anySel(st.selfold) or st.onlyNew) then
    local list = Q.rfList()
    if #list > 0 then
      st.results = list; st.rfActive = true; st.dirty = false
      if st.cursor > #list then st.cursor = #list end
      return
    end
  end
  local ltext = st.text:lower()
  local showHidden = S.show_hidden or ltext:find("is:hidden", 1, true) ~= nil
  local sig = Q.filterSig(showHidden)
  local groups = Q.compile(st.text)
  local b = st.bang
  -- Incremental narrowing: typing more characters into a plain query can only shrink the result set.
  local pool = DB.items
  local c = Q.cache
  if c and c.sig == sig and #c.text > 0 and ltext:sub(1, #c.text) == c.text and not ltext:find("[%-|\"&:]") and not c.text:find("[%-|\"&:]") then
    pool = c.pool
  end
  local wantChains = (b and (b.kind == "all" or (b.kind == "chain" and not b.invert))) or st.selfmt["CHAIN"] or ltext:find("chain", 1, true)
  local sf, sc, sd, sfo = anySel(st.selfmt), anySel(st.selcat), anySel(st.seldev), anySel(st.selfold)
  local res, scored = {}, #groups > 0
  for _, p in ipairs(pool) do
    local ok = true
    if p.hidden and not showHidden then ok = false end
    if ok and p.kind == "chain" and not wantChains then ok = false end
    if ok and st.onlyNew and not Q.isNew(p) then ok = false end
    if ok and sf and not st.selfmt[p.fmt] then ok = false end
    if ok and sc then
      local hit = false
      if #p.cats == 0 then hit = st.selcat["Uncategorized"] end
      for _, ct in ipairs(p.cats) do if st.selcat[ct] then hit = true end end
      ok = hit
    end
    if ok and sd and not st.seldev[p.dev] then ok = false end
    if ok and sfo then
      local hit = false
      for _, fo in ipairs(p.folderList) do if st.selfold[fo] then hit = true end end
      ok = hit
    end
    if ok and b then local pb = passesBang(p, b); if b.invert then pb = not pb end; ok = pb end
    if ok then
      local score = Q.run(groups, p)
      if score then res[#res + 1] = scored and { p = p, s = score } or p end
    end
  end
  local rank
  if S.fmt_sort then rank = {}; for i, f in ipairs(S.fmt_order) do rank[f] = i end end
  local function fr(p) return rank and (rank[p.fmt] or 99) or 0 end
  if scored then
    table.sort(res, function(a, cc)
      local ra, rc = fr(a.p), fr(cc.p)
      if ra ~= rc then return ra < rc end
      if a.s ~= cc.s then return a.s > cc.s end
      if a.p.lname ~= cc.p.lname then return a.p.lname < cc.p.lname end
      return a.p.id < cc.p.id
    end)
    local plain = {}
    for i, e in ipairs(res) do plain[i] = e.p end
    res = plain
  elseif rank then
    table.sort(res, function(a, cc)
      local ra, rc = fr(a), fr(cc)
      if ra ~= rc then return ra < rc end
      if a.lname ~= cc.lname then return a.lname < cc.lname end
      return a.id < cc.id
    end)
  end
  Q.cache = { sig = sig, text = ltext, pool = res }
  st.results = res
  st.dirty = false
  if st.cursor > #res then st.cursor = math.max(1, #res) end
end

-- One-line summary of the active side-panel filters (shown in fluent mode, where the panel is hidden).
function Q.facetLine()
  local parts = {}
  local function add(label, t)
    local k = {}
    for key in pairs(t) do k[#k + 1] = key end
    table.sort(k)
    if #k > 0 then parts[#parts + 1] = label .. ": " .. table.concat(k, ", ") end
  end
  add("Format", st.selfmt); add("Category", st.selcat); add("Developer", st.seldev); add("Folder", st.selfold)
  if st.onlyNew then parts[#parts + 1] = "New in last " .. S.new_days .. " days" end
  if #parts == 0 then return nil end
  return "Filters  " .. table.concat(parts, "  ·  ")
end

-- Describes what is currently narrowing the list (used by the "no results" message).
function Q.filterInfo()
  local L = {}
  local function list(label, t)
    local k = {}
    for key in pairs(t) do k[#k + 1] = key end
    table.sort(k)
    if #k > 0 then L[#L + 1] = label .. ": " .. table.concat(k, ", ") end
  end
  if st.text ~= "" then L[#L + 1] = 'Search: "' .. st.text .. '"' end
  if st.bang then L[#L + 1] = "Scope: " .. (st.bang.invert and "!" or "") .. st.bang.key end
  list("Format", st.selfmt); list("Category", st.selcat); list("Developer", st.seldev); list("Folder", st.selfold)
  if st.onlyNew then L[#L + 1] = "New in the last " .. S.new_days .. " days" end
  if not S.show_hidden then L[#L + 1] = "Hidden FX are not shown" end
  return L
end

-------------------------------------------------------------------------------
-- Selection / actions
-------------------------------------------------------------------------------
local function markSel(p)
  if not p then return end
  st.last = p
  st.sel[p.id] = true; st.seqn = st.seqn + 1; st.seq[p.id] = st.seqn
end
-- Selected plugins; when "keep selection order" is on they come back in the order they were selected.
local function selList()
  local out = {}
  for _, p in ipairs(st.results) do if st.sel[p.id] then out[#out + 1] = p end end
  if #out == 0 and st.results[st.cursor] then out[1] = st.results[st.cursor] end
  if S.keep_order and #out > 1 then
    table.sort(out, function(a, b) return (st.seq[a.id] or 0) < (st.seq[b.id] or 0) end)
  end
  return out
end
local function selCount()
  local n = 0
  for _, p in ipairs(st.results) do if st.sel[p.id] then n = n + 1 end end
  return n
end
local function selectOnly(i)
  st.sel = {}; st.seq = {}
  local p = st.results[i]; if p then markSel(p) end
  st.cursor = i; st.anchor = i
end
local function selectRange(a, b)
  st.sel = {}; st.seq = {}
  local step = (b >= a) and 1 or -1
  for k = a, b, step do markSel(st.results[k]) end
  st.cursor = b
end

recordUse = function(list)
  for _, p in ipairs(list) do
    local u = U[p.full] or { n = 0 }
    st.useSeq = (st.useSeq or 0) + 1
    u.n = (u.n or 0) + 1; u.t = os.time() + (st.useSeq % 1000) / 1000
    U[p.full] = u
  end
  touchUsage()
end
local function afterInsert(list, n)
  if n and n > 0 then
    recordUse(list)
    if S.rf_on then st.dirty = true end
    if st.autoclose then st.quit = true end
  end
end

local function addToTrack(tr, list, rec, open)
  local n = 0
  for _, p in ipairs(list) do
    local idx = r.TrackFX_AddByName(tr, p.add, rec or false, -1)
    if idx >= 0 then n = n + 1; if open then r.TrackFX_Show(tr, idx, 3) end end
  end
  return n
end
local function addToTake(tk, list, open)
  local n = 0
  for _, p in ipairs(list) do
    local idx = r.TakeFX_AddByName(tk, p.add, -1)
    if idx >= 0 then n = n + 1; if open then r.TakeFX_Show(tk, idx, 3) end end
  end
  return n
end

function Act.toTracks(list, rec, open)
  local cnt = r.CountSelectedTracks(0)
  if cnt == 0 then status("Select a track first"); return end
  r.Undo_BeginBlock()
  local n = 0
  for i = 0, cnt - 1 do n = n + addToTrack(r.GetSelectedTrack(0, i), list, rec, open) end
  r.Undo_EndBlock("FX Browser: insert FX on track(s)", -1)
  status(("Inserted %d FX on %d track(s)"):format(n, cnt))
  afterInsert(list, n)
end
function Act.toTakes(list, open)
  local cnt = r.CountSelectedMediaItems(0)
  if cnt == 0 then status("Select an item first"); return end
  r.Undo_BeginBlock()
  local n = 0
  for i = 0, cnt - 1 do
    local tk = r.GetActiveTake(r.GetSelectedMediaItem(0, i))
    if tk then n = n + addToTake(tk, list, open) end
  end
  r.Undo_EndBlock("FX Browser: insert FX on take(s)", -1)
  r.UpdateArrange()
  status(("Inserted %d FX on take(s)"):format(n))
  afterInsert(list, n)
end
function Act.toNewTrack(list)
  r.Undo_BeginBlock()
  r.InsertTrackAtIndex(r.CountTracks(0), true)
  local tr = r.GetTrack(0, r.CountTracks(0) - 1)
  local n = addToTrack(tr, list)
  r.SetOnlyTrackSelected(tr)
  r.Undo_EndBlock("FX Browser: insert FX on new track", -1)
  r.TrackList_AdjustWindows(false)
  status("Inserted on new track")
  afterInsert(list, n)
end
function Act.toMaster(list, monitoring)
  r.Undo_BeginBlock()
  local n = addToTrack(r.GetMasterTrack(0), list, monitoring)
  r.Undo_EndBlock("FX Browser: insert FX on master", -1)
  status(("Inserted %d FX on %s"):format(n, monitoring and "monitoring FX" or "master"))
  afterInsert(list, n)
end
function Act.dropAt(list)
  local mx, my = r.GetMousePosition()
  local item, take = r.GetItemFromPoint(mx, my, false)
  if take then
    r.Undo_BeginBlock(); local n = addToTake(take, list)
    r.Undo_EndBlock("FX Browser: drop FX on take", -1); r.UpdateArrange()
    status(("Dropped %d FX on take"):format(n)); afterInsert(list, n); return
  end
  local tr = r.GetTrackFromPoint(mx, my)
  if tr then
    r.Undo_BeginBlock(); local n = addToTrack(tr, list)
    r.Undo_EndBlock("FX Browser: drop FX on track", -1)
    status(("Dropped %d FX on track"):format(n)); afterInsert(list, n)
  end
end

local function openLink(v)
  if r.CF_ShellExecute then r.CF_ShellExecute(v); return end
  if IS_WIN then os.execute('start "" "' .. v .. '"')
  elseif IS_MAC then os.execute('open "' .. v .. '"')
  else os.execute('xdg-open "' .. v .. '" &') end
end

function Act.setRating(list, n)
  for _, p in ipairs(list) do
    local m = M[p.full] or {}; M[p.full] = m
    m.rating = n
  end
  touchMeta(); st.dirty = true
  status(n == 0 and "Rating cleared" or ("Rated " .. n .. " star" .. (n > 1 and "s" or "")))
end
function Act.clearFilters()
  st.selfmt, st.selcat, st.seldev, st.selfold = {}, {}, {}, {}; st.onlyNew = false; st.dirty = true
  status("Side-panel filters cleared")
end
function Act.deselect()
  if next(st.sel) == nil then return end
  st.sel = {}; st.seq = {}; status("Selection cleared")
end
-- Closes the topmost auxiliary window (confirmation, bulk edit, last info window, settings).
function Act.closeWindow()
  if st.confirm then st.confirm = nil; return true end
  if st.bulk then st.bulk = nil; return true end
  if #st.infos > 0 then table.remove(st.infos); return true end
  if st.settings_open then st.settings_open = false; st.capture = nil; return true end
  return false
end
function Act.refresh() DB.build(); st.dirty = true; status("FX list refreshed") end
function Act.toggleFlag(list, k)
  local want = not mflag(list[1], k)
  for _, p in ipairs(list) do
    local m = M[p.full] or {}; M[p.full] = m
    m.f = m.f or {}
    if k == "inst" then m.f.inst = want else m.f[k] = want or nil end
  end
  touchMeta(); st.dirty = true
end

-------------------------------------------------------------------------------
-- Icons (vector by default; emoji/text or PNG override per icon)
-------------------------------------------------------------------------------
local imgCache = {}
local function getImage(path)
  if imgCache[path] ~= nil then return imgCache[path] or nil end
  local ok, img = pcall(r.ImGui_CreateImage, path)
  if ok and img then
    if r.ImGui_Attach then pcall(r.ImGui_Attach, ctx, img) end
    imgCache[path] = img; return img
  end
  imgCache[path] = false; return nil
end

local ICON = {}
local function line(dl, x1, y1, x2, y2, col, th) r.ImGui_DrawList_AddLine(dl, x1, y1, x2, y2, col, th or 1.3) end
local function rect(dl, x1, y1, x2, y2, col, rd, th) r.ImGui_DrawList_AddRect(dl, x1, y1, x2, y2, col, rd or 2, 0, th or 1.3) end
local function rectF(dl, x1, y1, x2, y2, col, rd) r.ImGui_DrawList_AddRectFilled(dl, x1, y1, x2, y2, col, rd or 0) end
local function circ(dl, cx, cy, rad, col, th) r.ImGui_DrawList_AddCircle(dl, cx, cy, rad, col, 0, th or 1.3) end

function ICON.refresh(dl, x, y, s, col)
  local cx, cy, rad = x + s / 2, y + s / 2, s * 0.34
  local a0, a1 = 0.6, 0.6 + math.pi * 2 * 0.8
  r.ImGui_DrawList_PathArcTo(dl, cx, cy, rad, a0, a1, 20)
  r.ImGui_DrawList_PathStroke(dl, col, 0, 1.6)
  local ex, ey = cx + rad * math.cos(a1), cy + rad * math.sin(a1)
  local tx, ty, nx, ny = -math.sin(a1), math.cos(a1), math.cos(a1), math.sin(a1)
  r.ImGui_DrawList_AddTriangleFilled(dl, ex + tx * 4, ey + ty * 4, ex + nx * 3, ey + ny * 3, ex - nx * 3, ey - ny * 3, col)
end
function ICON.fluent(dl, x, y, s, col)
  local a, b, l = x + 2, x + s - 2, s * 0.3
  line(dl, a, y + 2, a + l, y + 2, col); line(dl, a, y + 2, a, y + 2 + l, col)
  line(dl, b, y + 2, b - l, y + 2, col); line(dl, b, y + 2, b, y + 2 + l, col)
  line(dl, a, y + s - 2, a + l, y + s - 2, col); line(dl, a, y + s - 2, a, y + s - 2 - l, col)
  line(dl, b, y + s - 2, b - l, y + s - 2, col); line(dl, b, y + s - 2, b, y + s - 2 - l, col)
end
function ICON.dock(dl, x, y, s, col)
  local cx = x + s / 2
  line(dl, cx, y + 2, cx, y + s - 6, col, 1.6)
  line(dl, cx - 4, y + s - 10, cx, y + s - 6, col, 1.6); line(dl, cx + 4, y + s - 10, cx, y + s - 6, col, 1.6)
  line(dl, x + 3, y + s - 2, x + s - 3, y + s - 2, col, 1.6)
end
function ICON.settings(dl, x, y, s, col)
  local cx, cy = x + s / 2, y + s / 2
  circ(dl, cx, cy, s * 0.2, col); circ(dl, cx, cy, s * 0.34, col)
  for k = 0, 7 do
    local a = k * math.pi / 4
    line(dl, cx + math.cos(a) * s * 0.34, cy + math.sin(a) * s * 0.34, cx + math.cos(a) * s * 0.47, cy + math.sin(a) * s * 0.47, col, 2)
  end
end
function ICON.star(dl, x, y, s, col, filled)
  local cx, cy, R = x + s / 2, y + s / 2 + s * 0.04, s * 0.5
  local pts = {}
  for k = 0, 9 do
    local a = -math.pi / 2 + k * math.pi / 5
    local rad = (k % 2 == 0) and R or R * 0.42
    pts[#pts + 1] = { cx + rad * math.cos(a), cy + rad * math.sin(a) }
  end
  for k = 1, 10 do
    local a, b = pts[k], pts[k % 10 + 1]
    if filled then r.ImGui_DrawList_AddTriangleFilled(dl, cx, cy, a[1], a[2], b[1], b[2], col) end
    line(dl, a[1], a[2], b[1], b[2], col, 1.1)
  end
end
function ICON.notes(dl, x, y, s, col)
  rect(dl, x + 3, y + 1, x + s - 2, y + s - 1, col, 2, 1.2)
  for k = 1, 3 do line(dl, x + 6, y + 1 + k * (s - 2) / 4, x + s - 5, y + 1 + k * (s - 2) / 4, col, 1) end
  for k = 1, 3 do line(dl, x + 1, y + 1 + k * (s - 2) / 4, x + 4, y + 1 + k * (s - 2) / 4, col, 1.2) end
end
function ICON.cpu(dl, x, y, s, col)
  rect(dl, x + 3, y + 3, x + s - 3, y + s - 3, col, 2, 1.2)
  rect(dl, x + 6, y + 6, x + s - 6, y + s - 6, col, 0, 1)
  for k = 1, 3 do
    local t = k * s / 4
    line(dl, x + t, y + 0.5, x + t, y + 3, col, 1); line(dl, x + t, y + s - 3, x + t, y + s - 0.5, col, 1)
    line(dl, x + 0.5, y + t, x + 3, y + t, col, 1); line(dl, x + s - 3, y + t, x + s - 0.5, y + t, col, 1)
  end
end
function ICON.paid(dl, x, y, s, col)
  circ(dl, x + s / 2, y + s / 2, s / 2 - 1, col, 1.2)
  local cur = "$"
  local tw, th = r.ImGui_CalcTextSize(ctx, cur)
  r.ImGui_DrawList_AddText(dl, x + (s - tw) / 2, y + (s - th) / 2, col, cur)
end
function ICON.net(dl, x, y, s, col)
  local cx, cy, rad = x + s / 2, y + s / 2, s / 2 - 1
  circ(dl, cx, cy, rad, col, 1.2)
  line(dl, cx - rad, cy, cx + rad, cy, col, 1); line(dl, cx, cy - rad, cx, cy + rad, col, 1)
  r.ImGui_DrawList_AddBezierQuadratic(dl, cx, cy - rad, cx - rad * 0.9, cy, cx, cy + rad, col, 1, 0)
  r.ImGui_DrawList_AddBezierQuadratic(dl, cx, cy - rad, cx + rad * 0.9, cy, cx, cy + rad, col, 1, 0)
end
function ICON.early(dl, x, y, s, col)
  rect(dl, x + 3, y + 1, x + s - 3, y + s - 1, col, 1, 1.2)
  line(dl, x + 1, y + s - 1, x + s - 1, y + s - 1, col, 1.2)
  r.ImGui_DrawList_AddCircleFilled(dl, x + s - 6.5, y + s / 2 + 1, 1.3, col)
end
function ICON.inst(dl, x, y, s, col)
  rect(dl, x + 1, y + 2, x + s - 1, y + s - 2, col, 1, 1.1)
  local w = (s - 2) / 4
  for k = 1, 3 do line(dl, x + 1 + k * w, y + 2, x + 1 + k * w, y + s - 2, col, 1) end
  for k = 1, 3 do if k ~= 2 then rectF(dl, x + 1 + k * w - 1.5, y + 2, x + 1 + k * w + 1.5, y + s * 0.6, col) end end
end
function ICON.x32(dl, x, y, s, col)
  local tw, th = r.ImGui_CalcTextSize(ctx, "x32")
  r.ImGui_DrawList_AddText(dl, x + (s - tw) / 2, y + (s - th) / 2, col, "x32")
end

function ICON.dot(dl, x, y, s, col) r.ImGui_DrawList_AddCircleFilled(dl, x + s / 2, y + s / 2, s * 0.28, col) end
function ICON.check(dl, x, y, s, col)
  line(dl, x + 2, y + s / 2 + 1, x + s * 0.4, y + s - 3, col, 1.6); line(dl, x + s * 0.4, y + s - 3, x + s - 2, y + 3, col, 1.6)
end
function ICON.flag(dl, x, y, s, col)
  line(dl, x + 3, y + 1, x + 3, y + s - 1, col, 1.4)
  r.ImGui_DrawList_AddTriangleFilled(dl, x + 3, y + 2, x + s - 2, y + 4.5, x + 3, y + s / 2 + 1, col)
end
function ICON.bolt(dl, x, y, s, col)
  local m = s / 2
  r.ImGui_DrawList_AddTriangleFilled(dl, x + m + 1, y + 1, x + 3, y + m + 1, x + m, y + m + 1, col)
  r.ImGui_DrawList_AddTriangleFilled(dl, x + m - 1, y + s - 1, x + s - 3, y + m - 1, x + m, y + m - 1, col)
end
function ICON.heart(dl, x, y, s, col)
  local cx, cy = x + s / 2, y + s / 2
  r.ImGui_DrawList_AddCircleFilled(dl, cx - s * 0.2, cy - s * 0.1, s * 0.24, col)
  r.ImGui_DrawList_AddCircleFilled(dl, cx + s * 0.2, cy - s * 0.1, s * 0.24, col)
  r.ImGui_DrawList_AddTriangleFilled(dl, cx - s * 0.43, cy, cx + s * 0.43, cy, cx, cy + s * 0.42, col)
end

local function drawIcon(dl, name, x, y, s, col, filled)
  local o = S.icons[name]
  if o and o.mode == "text" and o.value and o.value ~= "" then
    local tw, th = r.ImGui_CalcTextSize(ctx, o.value)
    r.ImGui_DrawList_AddText(dl, x + (s - tw) / 2, y + (s - th) / 2, col, o.value); return
  elseif o and o.mode == "image" and o.value and o.value ~= "" then
    local img = getImage(o.value)
    if img then r.ImGui_DrawList_AddImage(dl, img, x, y, x + s, y + s); return end
  end
  if ICON[name] then ICON[name](dl, x, y, s, col, filled) end
end

-- Icon of a custom field: vector / text-or-emoji / image
local function drawFieldIcon(dl, d, x, y, s, col, filled)
  local ic = d.icon or { mode = "default", value = "dot" }
  if ic.mode == "text" and ic.value and ic.value ~= "" then
    local tw, th = r.ImGui_CalcTextSize(ctx, ic.value)
    r.ImGui_DrawList_AddText(dl, x + (s - tw) / 2, y + (s - th) / 2, col, ic.value)
  elseif ic.mode == "image" and ic.value and ic.value ~= "" then
    local img = getImage(ic.value)
    if img then r.ImGui_DrawList_AddImage(dl, img, x, y, x + s, y + s) end
  else
    local nm = ic.value
    if not ICON[nm] then nm = "dot" end
    local o = S.icons[nm]   -- icon overrides made in earlier versions
    if o and (o.mode == "text" or o.mode == "image") and nm == d.id then drawIcon(dl, nm, x, y, s, col, filled)
    else ICON[nm](dl, x, y, s, col, filled) end
  end
end

-------------------------------------------------------------------------------
-- Theme
-------------------------------------------------------------------------------
local COLS = {
  { "Col_WindowBg", "bg" }, { "Col_ChildBg", "panel" }, { "Col_PopupBg", "panel" }, { "Col_Border", "border" },
  { "Col_Text", "text" }, { "Col_TextDisabled", "faint" }, { "Col_FrameBg", "input" },
  { "Col_FrameBgHovered", "inputH" }, { "Col_FrameBgActive", "inputH" }, { "Col_Button", "button" },
  { "Col_ButtonHovered", "buttonH" }, { "Col_ButtonActive", "accentDim" }, { "Col_Header", "accentDim" },
  { "Col_HeaderHovered", "hover" }, { "Col_HeaderActive", "accentDim" }, { "Col_TitleBg", "bg" },
  { "Col_TitleBgActive", "panel" }, { "Col_TitleBgCollapsed", "bg" }, { "Col_Separator", "border" },
  { "Col_CheckMark", "accent" }, { "Col_ScrollbarBg", "panel" }, { "Col_ScrollbarGrab", "border" },
  { "Col_ScrollbarGrabHovered", "faint" }, { "Col_ScrollbarGrabActive", "muted" },
  { "Col_TextSelectedBg", "accentDim" }, { "Col_InputTextCursor", "text" }, { "Col_DockingPreview", "accentDim" }, { "Col_SliderGrab", "accent" },
  { "Col_SliderGrabActive", "accent" },
  { "Col_Tab", "panel" }, { "Col_TabHovered", "frameH" }, { "Col_TabSelected", "accentDim" }, { "Col_TabActive", "accentDim" },
  { "Col_TabDimmed", "panel" }, { "Col_TabDimmedSelected", "accentDim" },
}

local function pushTheme()
  local nc = 0
  for _, c in ipairs(COLS) do
    if hasConst(c[1]) then r.ImGui_PushStyleColor(ctx, KC[c[1]], C[c[2]]); nc = nc + 1 end
  end
  local nv = 0
  local function sv(name, a, b) if hasConst(name) then r.ImGui_PushStyleVar(ctx, KC[name], a, b); nv = nv + 1 end end
  sv("StyleVar_WindowPadding", 10, 10); sv("StyleVar_FramePadding", 10, 6); sv("StyleVar_ItemSpacing", 8, 6)
  sv("StyleVar_FrameRounding", 6); sv("StyleVar_ChildRounding", 8); sv("StyleVar_WindowRounding", 10)
  sv("StyleVar_PopupRounding", 8); sv("StyleVar_ScrollbarRounding", 6); sv("StyleVar_GrabRounding", 4)
  sv("StyleVar_WindowBorderSize", 1); sv("StyleVar_FrameBorderSize", 0); sv("StyleVar_ChildBorderSize", 1)
  return nc, nv
end

-- Fonts. The built-in font is only replaced when the user changes size, family or style.
local FONT = { ui = nil, list = nil, key = "", ready_at = 0 }
FONT.families = { { "default", "Default (built-in)" }, { "sans-serif", "Sans-serif" }, { "serif", "Serif" },
  { "monospace", "Monospace" }, { "custom", "Custom name or file" } }
function FONT.family()
  if S.font_family == "default" then return nil end
  if S.font_family == "custom" then return (S.font_custom ~= "" and S.font_custom) or nil end
  return S.font_family
end
function FONT.make(family, size)
  local flags = 0
  if S.font_bold and hasConst("FontFlags_Bold") then flags = flags | KC.FontFlags_Bold end
  if S.font_italic and hasConst("FontFlags_Italic") then flags = flags | KC.FontFlags_Italic end
  local ok, f = pcall(r.ImGui_CreateFont, family, size, flags)
  if not ok or not f then ok, f = pcall(r.ImGui_CreateFont, family, flags) end
  if not ok or not f then return nil end
  pcall(r.ImGui_Attach, ctx, f)
  return f
end
function FONT.rebuild()
  local fam = FONT.family()
  local styled = S.font_bold or S.font_italic
  local key = table.concat({ fam or "", S.fs_ui, S.fs_list, tostring(S.font_bold), tostring(S.font_italic) }, "|")
  if key == FONT.key then return end
  FONT.key = key
  FONT.ui, FONT.list = nil, nil
  local face = fam or "sans-serif"
  if fam or styled or S.fs_ui ~= 13 then FONT.ui = FONT.make(face, S.fs_ui) end
  if fam or styled or S.fs_list ~= 13 then
    FONT.list = (S.fs_list == S.fs_ui and FONT.ui) or FONT.make(face, S.fs_list)
  end
  FONT.ready_at = st.frame + 2   -- newly attached fonts become usable a couple of frames later
end
function FONT.push(f, size)
  if not f or st.frame < FONT.ready_at then return false end
  if pcall(r.ImGui_PushFont, ctx, f) then return true end
  return pcall(r.ImGui_PushFont, ctx, f, size)
end

-------------------------------------------------------------------------------
-- Small widgets
-------------------------------------------------------------------------------
local function tip(text)
  if r.ImGui_IsItemHovered(ctx, KC.HoveredFlags_DelayNormal) then r.ImGui_SetTooltip(ctx, text) end
end

local function iconBtn(id, name, label, on)
  local s = r.ImGui_GetFrameHeight(ctx)
  local x, y = r.ImGui_GetCursorScreenPos(ctx)
  local clicked = r.ImGui_InvisibleButton(ctx, "##ib" .. id, s, s)
  local hov = r.ImGui_IsItemHovered(ctx)
  local dl = r.ImGui_GetWindowDrawList(ctx)
  if hov or on then r.ImGui_DrawList_AddRectFilled(dl, x, y, x + s, y + s, on and C.accentDim or C.buttonH, 6) end
  drawIcon(dl, name, x + (s - 16) / 2, y + (s - 16) / 2, 16, on and C.accent or (hov and C.text or C.muted))
  tip(label)
  return clicked
end

local acf = {}
local function autoCombo(id, w, cur, options, display)
  r.ImGui_SetNextItemWidth(ctx, w)
  local out
  -- our own size constraint stops ImGui's default combo height cap, which made the whole popup scroll
  r.ImGui_SetNextWindowSizeConstraints(ctx, math.max(w, 160), 0, 600, 2000)
  if r.ImGui_BeginCombo(ctx, "##" .. id, display or cur) then
    if r.ImGui_IsWindowAppearing(ctx) then r.ImGui_SetKeyboardFocusHere(ctx); acf[id] = "" end
    local _, f = r.ImGui_InputTextWithHint(ctx, "##flt", "type to filter...", acf[id] or "")
    acf[id] = f
    local lf = f:lower()
    local shown = {}
    for _, o in ipairs(options) do
      local val = type(o) == "table" and o[1] or o
      local label = type(o) == "table" and o[2] or o
      if lf == "" or label:lower():find(lf, 1, true) then shown[#shown + 1] = { val, label } end
    end
    r.ImGui_Separator(ctx)
    if #shown == 0 then
      r.ImGui_TextColored(ctx, C.faint, "No matches")
    else
      local rowh = r.ImGui_GetTextLineHeightWithSpacing(ctx)
      local rows = math.min(#shown, 5)
      if r.ImGui_BeginChild(ctx, "##lst", 0, rows * rowh + 4) then
        for _, o in ipairs(shown) do
          if r.ImGui_Selectable(ctx, o[2] .. "##o" .. o[1], o[1] == cur) then out = o[1]; r.ImGui_CloseCurrentPopup(ctx) end
        end
        r.ImGui_EndChild(ctx)
      end
    end
    r.ImGui_EndCombo(ctx)
  end
  return out
end

local function chipFlow(list, color)
  local aw = r.ImGui_GetContentRegionAvail(ctx)
  local used = 0
  for i, label in ipairs(list) do
    local tw, th = r.ImGui_CalcTextSize(ctx, label)
    local w, h = tw + 16, th + 8
    if i > 1 and used + w + 6 <= aw then r.ImGui_SameLine(ctx, 0, 6) else used = 0 end
    local x, y = r.ImGui_GetCursorScreenPos(ctx)
    r.ImGui_Dummy(ctx, w, h)
    local dl = r.ImGui_GetWindowDrawList(ctx)
    r.ImGui_DrawList_AddRect(dl, x, y, x + w, y + h, color or C.border, h / 2, 0, 1)
    r.ImGui_DrawList_AddText(dl, x + 8, y + 4, color or C.muted, label)
    used = used + w + 6
  end
end

-------------------------------------------------------------------------------
-- Result rows
-------------------------------------------------------------------------------
local function listScale() return S.fs_list / 13 end
local function rowHeight() return math.max(S.rowh, math.floor(S.fs_list * 1.9 + 4)) end

-- The badges a plugin has, in the user's priority order, with their pixel widths. Cached per plugin until
-- metadata, settings or the font change.
local function badgeCands(p, sc)
  local m = M[p.full]
  local key = meta_ver .. ":" .. sver .. ":" .. sc .. ":" .. S.font_family .. tostring(S.font_bold) .. tostring(S.font_italic) .. S.fs_list
  local bc = p._bc
  if bc and bc.key == key then return bc.cands, m end
  local pad = 7 * sc
  local cands = {}
  for _, k in ipairs(S.badge_order) do
    if not S.badge_off[k] then
      local wd, d, txt
      if k == "dev" then
        if p.dev ~= "" then wd = math.min((r.ImGui_CalcTextSize(ctx, p.dev)), 120 * sc) end
      elseif k == "fmt" then wd = (r.ImGui_CalcTextSize(ctx, p.fmt:lower())) + 2 * pad + 4
      elseif k == "rating" then
        if m and (m.rating or 0) > 0 then wd = (r.ImGui_CalcTextSize(ctx, tostring(m.rating))) + pad + 4 + 13 * sc + 6 end
      elseif k == "notes" then
        if m and ((m.notes and m.notes ~= "") or (m.links and #m.links > 0)) then wd = 24 * sc end
      else
        d = F.byId[k]
        if d and F.shown(p, d) then
          if d.type == "bool" then
            local ic = d.icon
            if ic and ic.mode == "text" and ic.value and ic.value ~= "" then
              wd = math.max(24 * sc, (r.ImGui_CalcTextSize(ctx, ic.value)) + 2 * pad)
            else wd = 24 * sc end
          else
            local v = F.get(p, d.id)
            txt = F.text(d, v)
            local sv, si = d.showValue ~= false, d.showIcon ~= false
            if not sv and not si then si = true end
            local tw = sv and (r.ImGui_CalcTextSize(ctx, txt)) or 0
            if sv and si then wd = tw + pad + 4 + 13 * sc + 6
            elseif sv then wd = tw + 2 * pad
            else wd = 24 * sc end
            if not sv then txt = nil end
          end
        end
      end
      if wd then cands[#cands + 1] = { k = k, w = wd, d = d, txt = txt } end
    end
  end
  p._bc = { key = key, cands = cands }
  return cands, m
end

local function drawBadge(dl, c, p, m, cx, py, ph, ty, sc)
  local k = c.k
  local d = c.d
  local col = (k == "fmt") and fmtColor(p.fmt) or (d and F.color(d)) or badgeColor(k)
  local pad = 7 * sc
  if k == "dev" then
    r.ImGui_DrawList_PushClipRect(dl, cx, py - 2, cx + c.w, py + ph + 2, true)
    r.ImGui_DrawList_AddText(dl, cx, ty, col, p.dev)
    r.ImGui_DrawList_PopClipRect(dl)
  elseif k == "fmt" then
    r.ImGui_DrawList_AddRect(dl, cx, py, cx + c.w, py + ph, col, ph / 2, 0, 1)
    r.ImGui_DrawList_AddText(dl, cx + pad, ty, col, p.fmt:lower())
  elseif k == "rating" then
    local isz = 13 * sc
    r.ImGui_DrawList_AddRect(dl, cx, py, cx + c.w, py + ph, col, ph / 2, 0, 1)
    r.ImGui_DrawList_AddText(dl, cx + pad, ty, col, tostring(m.rating))
    drawIcon(dl, "star", cx + c.w - 6 - isz, py + (ph - isz) / 2, isz, col, true)
  elseif d and d.type ~= "bool" then
    local isz = 13 * sc
    r.ImGui_DrawList_AddRect(dl, cx, py, cx + c.w, py + ph, col, ph / 2, 0, 1)
    if c.txt then
      r.ImGui_DrawList_AddText(dl, cx + pad, ty, col, c.txt)
      drawFieldIcon(dl, d, cx + c.w - 6 - isz, py + (ph - isz) / 2, isz, col, true)
    else
      drawFieldIcon(dl, d, cx + (c.w - isz) / 2, py + (ph - isz) / 2, isz, col, true)
    end
  elseif d then
    local isz = 12 * sc
    r.ImGui_DrawList_AddRect(dl, cx, py, cx + c.w, py + ph, col, ph / 2, 0, 1)
    drawFieldIcon(dl, d, cx + (c.w - isz) / 2, py + (ph - isz) / 2, isz, col)
    if d.show == "false" then   -- badge marks the *absence* of the property: strike it through
      line(dl, cx + c.w * 0.25, py + ph * 0.78, cx + c.w * 0.75, py + ph * 0.22, col, 1.3)
    end
  else
    local isz = 12 * sc
    r.ImGui_DrawList_AddRect(dl, cx, py, cx + c.w, py + ph, col, ph / 2, 0, 1)
    drawIcon(dl, k, cx + (c.w - isz) / 2, py + (ph - isz) / 2, isz, col)
  end
end

-- Draws one result row. Badges follow the user's priority order; whatever does not fit collapses into a
-- "+N" pill and is returned so the caller can show those badges in a tooltip.
local function rowContent(dl, p, x, y, w, h, nameOff, active)
  nameOff = nameOff or 0
  local sc = listScale()
  local fh = r.ImGui_GetTextLineHeight(ctx)
  local ty = y + (h - fh) / 2
  local ph = math.floor(18 * sc + 0.5)
  local gap, pad, minName, overflowW = 5, 8, 150 * sc, 30 * sc
  local py = y + (h - ph) / 2
  local cands, m = badgeCands(p, sc)

  local limit = w - pad - minName - nameOff
  local n, used = 0, 0
  for i, c in ipairs(cands) do
    if used + c.w + gap <= limit then used = used + c.w + gap; n = i else break end
  end
  local hidden
  if n < #cands then
    while n > 0 and used + overflowW + gap > limit do used = used - (cands[n].w + gap); n = n - 1 end
    used = used + overflowW + gap
    hidden = {}
    for i = n + 1, #cands do hidden[#hidden + 1] = cands[i] end
  end

  local cx = x + w - pad - used + gap
  local startx = cx
  for i = 1, n do
    drawBadge(dl, cands[i], p, m, cx, py, ph, ty, sc)
    cx = cx + cands[i].w + gap
  end
  if hidden then
    r.ImGui_DrawList_AddRect(dl, cx, py, cx + overflowW, py + ph, C.faint, ph / 2, 0, 1)
    local label = "+" .. #hidden
    local tw = r.ImGui_CalcTextSize(ctx, label)
    r.ImGui_DrawList_AddText(dl, cx + (overflowW - tw) / 2, ty, C.muted, label)
  end

  -- name; when it does not fit and the row is active, it scrolls back and forth like a music player title
  local nx0, availW = x + 10 + nameOff, (startx - 8) - (x + 10 + nameOff)
  local nw = r.ImGui_CalcTextSize(ctx, p.name)
  local hasSub = p.sub and p.sub ~= ""
  local totalW = nw + (hasSub and (8 + (r.ImGui_CalcTextSize(ctx, p.sub))) or 0)
  local moff = 0
  if active and totalW > availW then
    local over = totalW - availW + 6
    local speed, pause = 46 * sc, 0.9
    local dur = over / speed
    local t = (r.time_precise() - (st.mq_t0 or 0)) % (2 * pause + 2 * dur)
    if t < pause then moff = 0
    elseif t < pause + dur then moff = (t - pause) * speed
    elseif t < 2 * pause + dur then moff = over
    else moff = over - (t - 2 * pause - dur) * speed end
  end
  r.ImGui_DrawList_PushClipRect(dl, nx0, y, startx - 8, y + h, true)
  r.ImGui_DrawList_AddText(dl, nx0 - moff, ty, p.hidden and C.faint or C.text, p.name)
  if hasSub then r.ImGui_DrawList_AddText(dl, nx0 + 8 + nw - moff, ty, C.faint, p.sub) end
  r.ImGui_DrawList_PopClipRect(dl)
  return hidden
end

-- Tooltip for a row whose badges did not fit: shows the hidden badges themselves.
local function hiddenTooltip(hidden, p)
  local pf = FONT.push(FONT.list, S.fs_list)
  if r.ImGui_BeginTooltip(ctx) then
    local sc = listScale()
    local ph = math.floor(18 * sc + 0.5)
    local m = M[p.full]
    local items, total = {}, 0
    for _, c in ipairs(hidden) do
      local w2 = c.k == "dev" and ((r.ImGui_CalcTextSize(ctx, p.dev))) or c.w
      items[#items + 1] = { k = c.k, w = w2, d = c.d, txt = c.txt }; total = total + w2 + 6
    end
    local x, y = r.ImGui_GetCursorScreenPos(ctx)
    r.ImGui_Dummy(ctx, math.max(total, 10), ph + 2)
    local dl = r.ImGui_GetWindowDrawList(ctx)
    local ty = y + 1 + (ph - r.ImGui_GetTextLineHeight(ctx)) / 2
    local cx = x
    for _, c in ipairs(items) do
      drawBadge(dl, c, p, m, cx, y + 1, ph, ty, sc)
      cx = cx + c.w + 6
    end
    r.ImGui_EndTooltip(ctx)
  end
  if pf then r.ImGui_PopFont(ctx) end
end

local function ctxMenu(native)
  local list = selList()
  if #list == 0 then return end
  local n = #list
  local head = n == 1 and list[1].name or (n .. " items")
  r.ImGui_TextColored(ctx, C.faint, head); r.ImGui_Separator(ctx)
  if r.ImGui_MenuItem(ctx, "Add to selected track(s)", KB.name("ins_track")) then Act.toTracks(list) end
  if r.ImGui_MenuItem(ctx, "Add to selected track(s) and open", KB.name("open_track")) then Act.toTracks(list, false, true) end
  if r.ImGui_MenuItem(ctx, "Add to selected take(s)", KB.name("ins_take")) then Act.toTakes(list) end
  if r.ImGui_MenuItem(ctx, "Add to selected take(s) and open", KB.name("open_take")) then Act.toTakes(list, true) end
  if r.ImGui_MenuItem(ctx, "Add to new track") then Act.toNewTrack(list) end
  if r.ImGui_MenuItem(ctx, "Add to master track") then Act.toMaster(list, false) end
  if r.ImGui_MenuItem(ctx, "Add as input FX on selected track(s)") then Act.toTracks(list, true) end
  if r.ImGui_MenuItem(ctx, "Add to monitoring FX") then Act.toMaster(list, true) end
  r.ImGui_Separator(ctx)
  if native then
    if r.ImGui_MenuItem(ctx, "Show in explorer / finder", nil, false, (r.CF_LocateInExplorer ~= nil) and list[1].kind == "fx") then
      local path = list[1].ident
      if path ~= "" then r.CF_LocateInExplorer(path) end
    end
    if r.ImGui_MenuItem(ctx, "Reveal FX chain file", nil, false, (r.CF_LocateInExplorer ~= nil) and list[1].kind == "chain") then
      r.CF_LocateInExplorer(RES .. SEP .. "FxChains" .. SEP .. list[1].add)
    end
    if r.ImGui_MenuItem(ctx, "Copy FX name") then r.ImGui_SetClipboardText(ctx, list[1].full) end
    if r.ImGui_MenuItem(ctx, "Rescan plugin list") then DB.build() end
  else
    if r.ImGui_BeginMenu(ctx, "Rating") then
      for k = 1, 5 do
        if r.ImGui_MenuItem(ctx, k .. (k == 1 and " star" or " stars"), KB.name("rate" .. k)) then Act.setRating(list, k) end
      end
      if r.ImGui_MenuItem(ctx, "Clear rating", KB.name("rate0")) then Act.setRating(list, 0) end
      r.ImGui_EndMenu(ctx)
    end
    if r.ImGui_BeginMenu(ctx, "Mark as") then
      for _, d in ipairs(S.fields) do
        if d.type == "bool" and r.ImGui_MenuItem(ctx, d.name .. "##f" .. d.id, nil, mflag(list[1], d.id)) then Act.toggleFlag(list, d.id) end
      end
      r.ImGui_EndMenu(ctx)
    end
    if r.ImGui_MenuItem(ctx, "Info / edit metadata", KB.name("meta")) then openInfo(list) end
    if r.ImGui_MenuItem(ctx, "Bulk edit metadata...", KB.name("bulk")) then openBulk(list) end
    if r.ImGui_MenuItem(ctx, "Copy name") then r.ImGui_SetClipboardText(ctx, list[1].full) end
  end
end

local function resultsList(w, h, border)
  if not r.ImGui_BeginChild(ctx, "##results", w, h, border and KC.ChildFlags_Border or 0) then return end
  local pf = FONT.push(FONT.list, S.fs_list)
  local res = st.results
  local n = #res
  local rowH = rowHeight()
  local sc = listScale()
  local aw = r.ImGui_GetContentRegionAvail(ctx)
  local ch = r.ImGui_GetWindowHeight(ctx)
  local ctrl = (r.ImGui_GetKeyMods(ctx) & (KC.Mod_Ctrl | KC.Mod_Super)) ~= 0
  local shift = (r.ImGui_GetKeyMods(ctx) & KC.Mod_Shift) ~= 0

  -- selection order numbers (only when several are selected)
  local ranks
  if S.keep_order then
    local ord = {}
    for id, on in pairs(st.sel) do if on then ord[#ord + 1] = id end end
    if #ord > 1 then
      table.sort(ord, function(a, b) return (st.seq[a] or 0) < (st.seq[b] or 0) end)
      ranks = {}
      for i, id in ipairs(ord) do ranks[id] = i end
    end
  end

  if n == 0 then
    r.ImGui_Dummy(ctx, 1, 6)
    r.ImGui_TextColored(ctx, C.muted, "  No matches")
    local info = Q.filterInfo()
    if #info > 0 then
      r.ImGui_TextColored(ctx, C.faint, "  Active filters:")
      for _, line_ in ipairs(info) do r.ImGui_TextColored(ctx, C.faint, "    " .. line_) end
      r.ImGui_TextColored(ctx, C.faint, "  Clear side-panel filters: " .. KB.name("clear_filters"))
    end
  end

  if st.scroll and n > 0 then
    local sy = r.ImGui_GetScrollY(ctx)
    local y = (st.cursor - 1) * rowH
    if y < sy then r.ImGui_SetScrollY(ctx, y) elseif y + rowH > sy + ch - 4 then r.ImGui_SetScrollY(ctx, y + rowH - ch + 4) end
    st.scroll = false
  end

  r.ImGui_PushStyleVar(ctx, KC.StyleVar_ItemSpacing, 0, 0)
  local sy = r.ImGui_GetScrollY(ctx)
  local first = math.max(1, math.floor(sy / rowH))
  local last = math.min(n, first + math.ceil(ch / rowH) + 1)
  if n > 0 and first > 1 then r.ImGui_Dummy(ctx, 1, (first - 1) * rowH) end
  local dl = r.ImGui_GetWindowDrawList(ctx)
  for i = first, last do
    local p = res[i]
    local x, y = r.ImGui_GetCursorScreenPos(ctx)
    r.ImGui_InvisibleButton(ctx, "##r" .. i, aw, rowH)
    local hov = r.ImGui_IsItemHovered(ctx)
    local selected = st.sel[p.id]
    if selected then r.ImGui_DrawList_AddRectFilled(dl, x + 2, y + 1, x + aw - 2, y + rowH - 1, C.sel, 6)
    elseif hov then r.ImGui_DrawList_AddRectFilled(dl, x + 2, y + 1, x + aw - 2, y + rowH - 1, C.hover, 6) end
    if i == st.cursor then r.ImGui_DrawList_AddRect(dl, x + 2, y + 1, x + aw - 2, y + rowH - 1, C.accent, 6, 0, 1) end

    local off = 0
    if ranks and ranks[p.id] then
      local label = tostring(ranks[p.id])
      local rad = math.max(8, 8 * sc)
      off = rad * 2 + 6
      local cx, cy = x + 10 + rad, y + rowH / 2
      r.ImGui_DrawList_AddCircleFilled(dl, cx, cy, rad, C.accent)
      local tw, th = r.ImGui_CalcTextSize(ctx, label)
      r.ImGui_DrawList_AddText(dl, cx - tw / 2, cy - th / 2, C.bg, label)
    end
    if hov and st.mq_id ~= p.id then st.mq_id = p.id; st.mq_t0 = r.time_precise() end
    local active = S.marquee == "always" or (S.marquee == "hover" and (hov or selected or i == st.cursor))
    local hid = rowContent(dl, p, x, y, aw, rowH, off, active)
    if hid and hov and not st.drag and r.ImGui_IsItemHovered(ctx, KC.HoveredFlags_DelayNormal) then
      hiddenTooltip(hid, p)
    end

    if r.ImGui_IsItemClicked(ctx, 0) then
      if ctrl then
        if st.sel[p.id] then st.sel[p.id] = nil; st.seq[p.id] = nil else markSel(p) end
        st.cursor = i; st.anchor = i
      elseif shift then selectRange(st.anchor, i)
      elseif st.sel[p.id] then st.pending_collapse = i; st.cursor = i
      else selectOnly(i) end
    end
    if hov and r.ImGui_IsMouseDoubleClicked(ctx, 0) then selectOnly(i); Act.toTracks({ p }) end
    if r.ImGui_IsItemActive(ctx) and r.ImGui_IsMouseDragging(ctx, 0, 6) and not st.drag then
      st.drag = true; st.pending_collapse = nil
    end
    if r.ImGui_IsItemClicked(ctx, 1) then
      if not st.sel[p.id] then selectOnly(i) end
      st.open_menu = ctrl and "native" or "script"
    end
  end
  if n > 0 and n - last > 0 then r.ImGui_Dummy(ctx, 1, (n - last) * rowH) end
  r.ImGui_PopStyleVar(ctx)

  if st.pending_collapse and r.ImGui_IsMouseReleased(ctx, 0) then
    selectOnly(st.pending_collapse); st.pending_collapse = nil
  end
  if st.open_menu then st.menu_kind = st.open_menu; r.ImGui_OpenPopup(ctx, "rowmenu"); st.open_menu = nil end
  if r.ImGui_BeginPopup(ctx, "rowmenu") then ctxMenu(st.menu_kind == "native"); r.ImGui_EndPopup(ctx) end
  if pf then r.ImGui_PopFont(ctx) end
  r.ImGui_EndChild(ctx)
end

-------------------------------------------------------------------------------
-- Side panel
-------------------------------------------------------------------------------
local function facetSection(title, facet, selset, open, prefix)
  local flags = open and KC.TreeNodeFlags_DefaultOpen or 0
  if r.ImGui_CollapsingHeader(ctx, title .. "##h" .. prefix, nil, flags) then
    for _, name in ipairs(facet.names) do
      local label = name .. "  (" .. facet.cnt[name] .. ")##" .. prefix .. name
      if r.ImGui_Selectable(ctx, label, selset[name] == true) then
        local mods = r.ImGui_GetKeyMods(ctx)
        if (mods & (KC.Mod_Ctrl | KC.Mod_Super | KC.Mod_Shift)) ~= 0 then
          selset[name] = (not selset[name]) or nil            -- Ctrl/Shift: add or remove
        else
          local only = selset[name] and next(selset, next(selset)) == nil
          for key in pairs(selset) do selset[key] = nil end
          if not only then selset[name] = true end             -- plain click: exclusive (click again to clear)
        end
        st.dirty = true
      end
    end
  end
end
local Pnl = {}   -- info panel, defined after the metadata view
local function sidePanel(w, h)
  if not r.ImGui_BeginChild(ctx, "##side", w, h, KC.ChildFlags_Border) then return end
  local tw = math.floor((w - 28) / 2)
  for k, t in ipairs({ { "filters", "Filters" }, { "info", "Info" } }) do
    if k > 1 then r.ImGui_SameLine(ctx, 0, 4) end
    local on = S.side_mode == t[1]
    if on then r.ImGui_PushStyleColor(ctx, KC.Col_Button, C.accentDim) end
    if r.ImGui_Button(ctx, t[2], tw) then S.side_mode = t[1]; touchSettings() end
    if on then r.ImGui_PopStyleColor(ctx) end
    if k == 2 then tip("Switch panel: " .. KB.name("side_mode")) end
  end
  r.ImGui_Dummy(ctx, 1, 2)
  if S.side_mode == "info" then Pnl.info(); r.ImGui_EndChild(ctx); return end
  local any = anySel(st.selfmt) or anySel(st.selcat) or anySel(st.seldev) or anySel(st.selfold) or st.onlyNew
  if any then
    if r.ImGui_Button(ctx, "Clear filters  (" .. KB.name("clear_filters") .. ")", -1) then Act.clearFilters() end
  else
    r.ImGui_TextColored(ctx, C.faint, "Filters")
  end
  if (DB.hiddenCount or 0) > 0 then
    local rv, b = r.ImGui_Checkbox(ctx, "Show hidden (" .. DB.hiddenCount .. ")", S.show_hidden)
    if rv then S.show_hidden = b; touchSettings(); DB.build() end
    tip("FX hidden in REAPER's own FX browser")
  end
  if (DB.newCount or 0) > 0 or st.onlyNew then
    local rv, b = r.ImGui_Checkbox(ctx, "New, last " .. S.new_days .. " days (" .. (DB.newCount or 0) .. ")", st.onlyNew == true)
    if rv then st.onlyNew = b; st.dirty = true end
    tip("Plugins first seen by this browser within the last " .. S.new_days .. " days")
  end
  facetSection("Type / Format", DB.f.fmt, st.selfmt, true, "fmt")
  facetSection("Categories", DB.f.cat, st.selcat, true, "cat")
  facetSection("Folders", DB.f.fold, st.selfold, false, "fold")
  facetSection("Developers", DB.f.dev, st.seldev, false, "dev")
  r.ImGui_EndChild(ctx)
end

-------------------------------------------------------------------------------
-- Scopes
-------------------------------------------------------------------------------
local FLAG_LIST = F.flags
local FLAG_WORDS = { paid = { "paid ", "free " }, net = { "online ", "offline " }, early = { "early-access ", "" },
  inst = { "instrument ", "effect " }, x32 = { "32-bit ", "" }, notes = { "annotated ", "" }, rated = { "rated ", "unrated " },
  meta = { "", "" }, hidden = { "hidden ", "" }, new = { "new ", "" } }
local function flagWord(f, i)
  local w = FLAG_WORDS[f[1]]
  if w then return w[i] end
  local nm = f[2]:lower() .. " "
  return i == 1 and nm or ("not " .. nm)
end
local KINDS = { { "all", "All" }, { "type", "Type / format" }, { "category", "Category" }, { "folder", "Folder" },
  { "developer", "Developer" }, { "chain", "FX chain" } }
local function kindLabel(k) for _, x in ipairs(KINDS) do if x[1] == k then return x[2] end end return k end

local function bangHint(b)
  local words, metaSuffix = "", ""
  for _, f in ipairs(FLAG_LIST) do
    local m = (b.flags or {})[f[1]]
    if m and b.invert then m = -m end   -- "!key" flips include/exclude
    if f[1] == "meta" then
      if m == 1 then metaSuffix = " with metadata" elseif m == -1 then metaSuffix = " without metadata" end
    elseif m == 1 then words = words .. flagWord(f, 1)
    elseif m == -1 then words = words .. flagWord(f, 2) end
  end
  local v = b.value or ""
  local noun
  if b.kind == "chain" then noun = v ~= "" and ("fx chains in " .. v) or "fx chains"
  elseif b.kind == "type" then noun = (v ~= "" and v or "") .. " plugins"
  elseif b.kind == "category" then noun = (v ~= "" and v or "") .. " plugins"
  elseif b.kind == "folder" then noun = v ~= "" and ("plugins in " .. v) or "folders"
  elseif b.kind == "developer" then noun = (v ~= "" and (v .. " ") or "") .. "plugins"
  else noun = (words == "" and metaSuffix == "") and "everything" or "plugins" end
  if b.invert and b.kind ~= "all" then noun = "everything except " .. noun end
  local qs = (b.query and b.query ~= "") and (" where " .. b.query) or ""
  return trim("search " .. words .. noun:gsub("^%s+", "")) .. metaSuffix .. qs .. "..."
end

local function bangOptions(kind)
  local f = DB.f
  local list = { { "", "(any)" } }
  local src
  if kind == "type" then src = f.fmt.names elseif kind == "category" then src = f.cat.names
  elseif kind == "folder" then src = f.fold.names elseif kind == "developer" then src = f.dev.names
  elseif kind == "chain" then src = f.chainf.names end
  if not src then return {} end
  for _, n in ipairs(src) do if n ~= "CHAIN" then list[#list + 1] = n end end
  return list
end

local function activateBang(b, inv)
  st.bang = { key = b.key, kind = b.kind, value = b.value, flags = b.flags, query = b.query, invert = inv or false }; setText("")
end

-------------------------------------------------------------------------------
-- Metadata window
-------------------------------------------------------------------------------
local function copyLinks(l) local o = {}; for i, v in ipairs(l or {}) do o[i] = { t = v.t, v = v.v } end return o end
local function addLink(ed, v)
  v = trim(v); if v == "" then return end
  local isUrl = v:match("^https?://") or v:match("^www%.")
  ed.links[#ed.links + 1] = { t = isUrl and "url" or "file", v = v }
end
local function shortLink(l)
  local v = l.v
  if l.t == "url" then v = v:gsub("^https?://", ""):gsub("^www%.", "") else v = v:match("([^/\\]+)$") or v end
  if #v > 56 then v = v:sub(1, 53) .. "..." end
  return v
end

local function starRow(value, interactive, size)
  local sz = size or 18
  local dl = r.ImGui_GetWindowDrawList(ctx)
  local newv
  for k = 1, 5 do
    if k > 1 then r.ImGui_SameLine(ctx, 0, 3) end
    local x, y = r.ImGui_GetCursorScreenPos(ctx)
    local clicked = r.ImGui_InvisibleButton(ctx, "##star" .. k, sz, sz)
    drawIcon(dl, "star", x, y, sz, k <= value and C.gold or C.faint, k <= value)
    if interactive and clicked then newv = (value == k) and 0 or k end
  end
  return newv
end

local function pill(label, col, icon)
  local tw, th = r.ImGui_CalcTextSize(ctx, label)
  local iw = icon and 16 or 0
  local w, h = tw + 16 + iw, th + 6
  local x, y = r.ImGui_GetCursorScreenPos(ctx)
  r.ImGui_Dummy(ctx, w, h)
  local dl = r.ImGui_GetWindowDrawList(ctx)
  r.ImGui_DrawList_AddRect(dl, x, y, x + w, y + h, col, h / 2, 0, 1)
  if icon then
    if type(icon) == "table" then drawFieldIcon(dl, icon, x + 8, y + (h - 12) / 2, 12, col, true)
    else drawIcon(dl, icon, x + 8, y + (h - 12) / 2, 12, col, true) end
  end
  r.ImGui_DrawList_AddText(dl, x + 8 + iw, y + 3, col, label)
end
local function pillFlow(items)
  local aw = r.ImGui_GetContentRegionAvail(ctx)
  local used = 0
  for i, it in ipairs(items) do
    local w = (r.ImGui_CalcTextSize(ctx, it[1])) + 16 + (it[3] and 16 or 0)
    if i > 1 and used + w + 6 <= aw then r.ImGui_SameLine(ctx, 0, 6) else used = 0 end
    pill(it[1], it[2], it[3]); used = used + w + 6
  end
end

-- Notes: BBCode ([b] [i] [u] [s] [color=#hex|name] [url=...] [list][*] [quote] [code] [hr] [h]) plus the older
-- shorthand ("- item" bullets, "# Title" headings). Laid out once per (text, width, font) and cached.
local NOTE = { cache = {}, n = 0 }
NOTE.names = { red = 0xe06c75, green = 0x7bc4a0, blue = 0x61afef, yellow = 0xe5c07b, orange = 0xd19a66, purple = 0xc678dd,
  cyan = 0x56b6c2, pink = 0xe58fc4, gray = 0x8d98a6, grey = 0x8d98a6, white = 0xffffff, black = 0x000000 }
NOTE.tags = { b = true, i = true, u = true, s = true, color = true, url = true, code = true, quote = true, list = true,
  ["*"] = true, hr = true, h = true }

function NOTE.tokens(text)
  local lines = {}
  for ln in (text .. "\n"):gmatch("(.-)\n") do
    if ln:match("^%s*[%-%*]%s+") then ln = "[*]" .. (ln:gsub("^%s*[%-%*]%s+", ""))
    elseif ln:match("^#+%s") then ln = "[h]" .. (ln:gsub("^#+%s*", "")) .. "[/h]" end
    lines[#lines + 1] = ln
  end
  text = table.concat(lines, "\n")
  local toks, i, buf = {}, 1, {}
  local function flush() if #buf > 0 then toks[#toks + 1] = { text = table.concat(buf) }; buf = {} end end
  while i <= #text do
    local ch = text:sub(i, i)
    local a, e, close, name, arg
    if ch == "[" then a, e, close, name, arg = text:find("^%[(/?)([%a%*]+)=?([^%]]*)%]", i) end
    name = name and name:lower()
    if a and NOTE.tags[name] then
      flush()
      if name == "code" and close == "" then
        local ce, cf = text:find("[/code]", e + 1, true)
        local body = text:sub(e + 1, (ce or #text + 1) - 1)
        toks[#toks + 1] = { tag = "code", raw = body }
        i = cf and cf + 1 or #text + 1
      else
        toks[#toks + 1] = { tag = name, close = close == "/", arg = arg }
        i = e + 1
      end
    else
      buf[#buf + 1] = ch; i = i + 1
    end
  end
  flush()
  for k, tk in ipairs(toks) do   -- [url]address[/url]: the address is both label and target
    if tk.tag == "url" and not tk.close and tk.arg == "" and toks[k + 1] and toks[k + 1].text
        and toks[k + 2] and toks[k + 2].tag == "url" and toks[k + 2].close then
      tk.arg = trim(toks[k + 1].text)
    end
  end
  return toks
end

function NOTE.layout(text, width)
  local toks = NOTE.tokens(text)
  local fh = r.ImGui_GetTextLineHeight(ctx)
  local lineH = fh + 3
  local ops = {}
  local x, y = 0, 0
  local base, cur = 0, 0           -- indent of the block / of the current wrapped item
  local st_ = { b = 0, i = 0, u = 0, s = 0, h = 0, quote = 0, list = 0 }
  local colors, urls, quotes = {}, {}, {}
  local function newline(gap)
    if x <= cur and gap then y = y + lineH * 0.5 else y = y + lineH end
    x = cur
  end
  local function style()
    local col = colors[#colors]
    if not col then
      if st_.h > 0 then col = "accent" elseif urls[#urls] then col = "accent" elseif st_.i > 0 then col = "accent" else col = "text" end
    end
    return col
  end
  local function word(wd, code)
    local bare = wd:gsub("%s+$", "")
    local sw = r.ImGui_CalcTextSize(ctx, bare)
    local full = r.ImGui_CalcTextSize(ctx, wd)
    if x + sw > width and x > cur then newline(); wd = wd:gsub("^%s+", ""); bare = wd:gsub("%s+$", ""); full = r.ImGui_CalcTextSize(ctx, wd) end
    if wd == "" then return end
    local bold = st_.b > 0 or st_.h > 0
    if code then ops[#ops + 1] = { bg = true, x = x, y = y, w = full, h = lineH } end
    ops[#ops + 1] = { x = x, y = y, w = full, s = wd, col = code and "text" or style(), b = bold, u = st_.u > 0 or (urls[#urls] and true or false),
      st = st_.s > 0, url = urls[#urls] or nil }
    x = x + full
  end
  for _, tk in ipairs(toks) do
    if tk.text then
      local first = true
      for piece in (tk.text .. "\n"):gmatch("(.-)\n") do
        if not first then
          newline(true)
          if st_.list == 0 then cur = base end
        end
        first = false
        if piece ~= "" then
          for wd in piece:gmatch("%s*%S+%s*") do word(wd) end
          if not piece:find("%S") then word(piece) end
        end
      end
    elseif tk.raw then
      newline(); cur = base; x = cur
      for piece in (tk.raw:gsub("^\n", "") .. "\n"):gmatch("(.-)\n") do
        word(piece == "" and " " or piece, true); newline()
      end
    else
      local t = tk.tag
      if t == "b" or t == "i" or t == "u" or t == "s" or t == "h" then
        st_[t] = math.max(0, st_[t] + (tk.close and -1 or 1))
        if t == "h" and tk.close then newline() end
      elseif t == "color" then
        if tk.close then colors[#colors] = nil
        else
          local c = tk.arg:match("^#?(%x%x%x%x%x%x)$")
          colors[#colors + 1] = c and tonumber(c, 16) or NOTE.names[tk.arg:lower()] or "text"
        end
      elseif t == "url" then
        if tk.close then urls[#urls] = nil
        else urls[#urls + 1] = tk.arg ~= "" and tk.arg or false end
      elseif t == "list" then
        if tk.close then st_.list = math.max(0, st_.list - 1); base = base - 16; cur = base; newline() else
          if x > cur then newline() end
          st_.list = st_.list + 1; base = base + 16; cur = base; x = cur
        end
      elseif t == "*" then
        if x > cur then newline() end
        local ind = (st_.list > 0) and base or (base + 16)
        ops[#ops + 1] = { bullet = true, x = ind - 11, y = y + fh / 2 + 1 }
        cur = ind; x = cur
      elseif t == "quote" then
        if tk.close then
          local q = table.remove(quotes)
          if x > cur then newline() end
          if q then ops[#ops + 1] = { bar = true, x = q.x, y1 = q.y, y2 = y } end
          base = base - 14; cur = base; x = cur
        else
          if x > cur then newline() end
          quotes[#quotes + 1] = { x = base + 2, y = y }
          base = base + 14; cur = base; x = cur
        end
      elseif t == "hr" then
        if x > cur then newline() end
        ops[#ops + 1] = { hr = true, y = y + lineH / 2 }
        y = y + lineH; x = cur
      end
    end
  end
  return { ops = ops, h = y + lineH }
end

function NOTE.render(text, width)
  if not width then width = r.ImGui_GetContentRegionAvail(ctx) end
  width = math.max(60, math.floor(width))
  local key = table.concat({ text, width, S.fs_ui, S.font_family, tostring(S.font_bold), tostring(S.font_italic) }, "\1")
  local L = NOTE.cache[key]
  if not L then
    if NOTE.n > 200 then NOTE.cache, NOTE.n = {}, 0 end
    L = NOTE.layout(text, width); NOTE.cache[key] = L; NOTE.n = NOTE.n + 1
  end
  local x0, y0 = r.ImGui_GetCursorScreenPos(ctx)
  r.ImGui_Dummy(ctx, width, L.h)
  local dl = r.ImGui_GetWindowDrawList(ctx)
  local fh = r.ImGui_GetTextLineHeight(ctx)
  local win = r.ImGui_IsWindowHovered(ctx)
  local mx, my = r.ImGui_GetMousePos(ctx)
  local hand
  for _, o in ipairs(L.ops) do
    if o.bar then r.ImGui_DrawList_AddRectFilled(dl, x0 + o.x, y0 + o.y1, x0 + o.x + 2, y0 + o.y2, C.faint)
    elseif o.hr then r.ImGui_DrawList_AddLine(dl, x0, y0 + o.y, x0 + width, y0 + o.y, C.border, 1)
    elseif o.bullet then r.ImGui_DrawList_AddCircleFilled(dl, x0 + o.x, y0 + o.y, 2.2, C.muted)
    elseif o.bg then r.ImGui_DrawList_AddRectFilled(dl, x0 + o.x - 1, y0 + o.y, x0 + o.x + o.w + 1, y0 + o.y + o.h, C.button, 3)
    else
      local col = type(o.col) == "number" and rgb(o.col) or C[o.col] or C.text
      local px, py = x0 + o.x, y0 + o.y
      if o.url and win and mx >= px and mx <= px + o.w and my >= py and my <= py + fh + 2 then
        hand = true; col = C.green
        if r.ImGui_IsMouseClicked(ctx, 0) then openLink(o.url) end
      end
      r.ImGui_DrawList_AddText(dl, px, py, col, o.s)
      if o.b then r.ImGui_DrawList_AddText(dl, px + 1, py, col, o.s) end
      local bare = o.s:gsub("%s+$", "")
      local bw = (r.ImGui_CalcTextSize(ctx, bare)) + (o.b and 1 or 0)
      if o.u then r.ImGui_DrawList_AddLine(dl, px, py + fh, px + bw, py + fh, col, 1) end
      if o.st then r.ImGui_DrawList_AddLine(dl, px, py + fh * 0.55, px + bw, py + fh * 0.55, col, 1) end
    end
  end
  if hand and hasConst("MouseCursor_Hand") then r.ImGui_SetMouseCursor(ctx, KC.MouseCursor_Hand) end
end

local function infoView(p, m)
  starRow(m.rating or 0, false, 15)
  r.ImGui_Dummy(ctx, 1, 1)
  local items = {}
  for _, d in ipairs(S.fields) do
    local v = F.get(p, d.id)
    local col = F.color(d)
    if d.type == "bool" then
      if v == true then items[#items + 1] = { d.name, col, d }
      elseif d.id == "paid" then items[#items + 1] = { "Free", C.muted } end
    elseif (d.type == "number" and v ~= nil) or (d.type == "text" and v and v ~= "") then
      items[#items + 1] = { d.name .. ": " .. F.text(d, v), col, d }
    end
  end
  if p.hidden then items[#items + 1] = { "Hidden in REAPER", C.faint } end
  if p.renamed then items[#items + 1] = { "Renamed in REAPER", C.faint } end
  pillFlow(items)
  if p.orig and p.orig ~= "" then
    r.ImGui_TextColored(ctx, C.faint, "Original name: " .. p.orig)
  end
  if p.autoKw and #p.autoKw > 0 then
    r.ImGui_TextColored(ctx, C.faint, "JSFX tags: " .. table.concat(p.autoKw, ", "))
  end
  -- keywords
  if m.kw and #m.kw > 0 then
    r.ImGui_Dummy(ctx, 1, 1)
    local chips = {}
    for _, k in ipairs(m.kw) do chips[#chips + 1] = "#" .. k end
    chipFlow(chips, C.muted)
  end
  if p.added and p.added > 0 then
    r.ImGui_TextColored(ctx, C.faint, "Added: " .. os.date("%Y-%m-%d", p.added) .. (Q.isNew(p) and "  (new)" or ""))
  end
  -- notes
  r.ImGui_Dummy(ctx, 1, 2)
  r.ImGui_TextColored(ctx, C.faint, "NOTES")
  if m.notes and m.notes ~= "" then NOTE.render(m.notes) else r.ImGui_TextColored(ctx, C.faint, "No notes yet.") end
  -- links
  local nlinks = m.links and #m.links or 0
  if nlinks > 0 then
    r.ImGui_Dummy(ctx, 1, 2)
    r.ImGui_TextColored(ctx, C.faint, "LINKS")
    local dl = r.ImGui_GetWindowDrawList(ctx)
    for i, l in ipairs(m.links) do
      local x, y = r.ImGui_GetCursorScreenPos(ctx)
      local aw = r.ImGui_GetContentRegionAvail(ctx)
      if r.ImGui_Selectable(ctx, "##lk" .. i, false, 0, aw, 20) then openLink(l.v) end
      local hov = r.ImGui_IsItemHovered(ctx)
      local col = hov and C.accent or C.text
      drawIcon(dl, l.t == "url" and "net" or "notes", x + 6, y + 4, 12, col)
      r.ImGui_DrawList_AddText(dl, x + 26, y + 2, col, shortLink(l))
      tip(l.v)
    end
  end
end

local function infoEdit(w, p)
  local ed = w.ed
  local _, b
  local nv = starRow(ed.rating, true, 18); if nv then ed.rating = nv end
  r.ImGui_Dummy(ctx, 1, 1)
  local sameLine = false
  for _, d in ipairs(S.fields) do
    if d.type == "bool" then
      if sameLine then r.ImGui_SameLine(ctx, 0, 14) end
      _, b = r.ImGui_Checkbox(ctx, d.name .. "##e" .. d.id, ed.f[d.id] == true); ed.f[d.id] = b
      local ix = r.ImGui_GetItemRectMax(ctx)
      local wx = r.ImGui_GetWindowPos(ctx)
      sameLine = type(ix) == "number" and type(wx) == "number" and (ix - wx) < (r.ImGui_GetWindowWidth(ctx) - 150)
    end
  end
  for _, d in ipairs(S.fields) do
    if d.type ~= "bool" then
      r.ImGui_AlignTextToFramePadding(ctx); r.ImGui_TextColored(ctx, C.faint, d.name)
      r.ImGui_SameLine(ctx, 0, 8)
      if d.type == "number" then
        r.ImGui_SetNextItemWidth(ctx, 90)
        local cur = ed.f[d.id]
        local v2; _, v2 = r.ImGui_InputDouble(ctx, "##e" .. d.id, cur or 0, 0, 0, "%.2f")
        ed.f[d.id] = v2
        r.ImGui_SameLine(ctx, 0, 8)
        if r.ImGui_SmallButton(ctx, "clear##c" .. d.id) then ed.f[d.id] = nil end
        if cur == nil then r.ImGui_SameLine(ctx, 0, 6); r.ImGui_TextColored(ctx, C.faint, "(unset)") end
      else
        r.ImGui_SetNextItemWidth(ctx, 220)
        local t2; _, t2 = r.ImGui_InputText(ctx, "##e" .. d.id, ed.f[d.id] or ""); ed.f[d.id] = t2 ~= "" and t2 or nil
      end
    end
  end
  r.ImGui_Dummy(ctx, 1, 1)
  r.ImGui_TextColored(ctx, C.faint, "KEYWORDS (comma separated)")
  r.ImGui_SetNextItemWidth(ctx, -1)
  local kw; _, kw = r.ImGui_InputTextWithHint(ctx, "##kw", "e.g. warm, tape, saturation", ed.kw); ed.kw = kw
  r.ImGui_Dummy(ctx, 1, 1)
  r.ImGui_TextColored(ctx, C.faint, "NOTES")
  r.ImGui_SameLine(ctx, 0, 8); r.ImGui_TextColored(ctx, C.muted, "(?)")
  tip("BBCode: [b]bold[/b]  [i]emphasis[/i]  [u]underline[/u]  [s]strike[/s]  [color=#e0b252]colour[/color]  " ..
    "[url=https://...]link[/url]  [list][*]item[/list]  [quote]..[/quote]  [code]..[/code]  [hr]\n" ..
    "Shorthand: \"- item\" makes a bullet, \"# Title\" a heading, a blank line a gap.\n" ..
    "Italic is shown as a highlight colour (no italic font is available).")
  local function ins(a, b2) ed.notes = ed.notes .. a .. b2; w.nver = (w.nver or 0) + 1 end
  local TB = { { "B", "[b]", "[/b]" }, { "I", "[i]", "[/i]" }, { "U", "[u]", "[/u]" }, { "S", "[s]", "[/s]" },
    { "Link", "[url=https://]", "[/url]" }, { "Color", "[color=#e0b252]", "[/color]" }, { "List", "\n[list]\n[*]", "\n[/list]" },
    { "Quote", "[quote]", "[/quote]" }, { "Code", "[code]", "[/code]" }, { "Rule", "\n[hr]\n", "" } }
  for k, bt in ipairs(TB) do
    if k > 1 then r.ImGui_SameLine(ctx, 0, 4) end
    if r.ImGui_SmallButton(ctx, bt[1] .. "##tb" .. k) then ins(bt[2], bt[3]) end
  end
  r.ImGui_SameLine(ctx, 0, 12)
  local pv; _, pv = r.ImGui_Checkbox(ctx, "Preview", w.preview == true); w.preview = pv
  local _, availH = r.ImGui_GetContentRegionAvail(ctx)
  local linksH = #ed.links * 24 + 26 + 34 + 30
  local nh = math.max(70, availH - linksH)
  if w.preview then
    if r.ImGui_BeginChild(ctx, "##npv", -1, nh, KC.ChildFlags_Border) then
      if ed.notes ~= "" then NOTE.render(ed.notes) else r.ImGui_TextColored(ctx, C.faint, "Nothing to preview.") end
      r.ImGui_EndChild(ctx)
    end
  else
    local nt; _, nt = r.ImGui_InputTextMultiline(ctx, "##notes" .. (w.nver or 0), ed.notes, -1, nh); ed.notes = nt
  end
  r.ImGui_TextColored(ctx, C.faint, "LINKS")
  for i, l in ipairs(ed.links) do
    r.ImGui_PushID(ctx, "l" .. i)
    if r.ImGui_SmallButton(ctx, "x") then table.remove(ed.links, i); r.ImGui_PopID(ctx); break end
    r.ImGui_SameLine(ctx)
    r.ImGui_TextColored(ctx, l.t == "url" and C.accent or C.text, shortLink(l))
    r.ImGui_PopID(ctx)
  end
  local x, y = r.ImGui_GetCursorScreenPos(ctx)
  local aw = r.ImGui_GetContentRegionAvail(ctx)
  r.ImGui_InvisibleButton(ctx, "##dropzone", aw, 26)
  local dl = r.ImGui_GetWindowDrawList(ctx)
  r.ImGui_DrawList_AddRect(dl, x, y, x + aw, y + 26, r.ImGui_IsItemHovered(ctx) and C.accent or C.border, 6, 0, 1)
  r.ImGui_DrawList_AddText(dl, x + 10, y + 6, C.faint, "Drop a file or website link here")
  if r.ImGui_BeginDragDropTarget(ctx) then
    local rv, cnt = r.ImGui_AcceptDragDropPayloadFiles(ctx)
    if rv then
      for k = 0, cnt - 1 do local ok, f = r.ImGui_GetDragDropPayloadFile(ctx, k); if ok then addLink(ed, f) end end
    end
    r.ImGui_EndDragDropTarget(ctx)
  end
  r.ImGui_SetNextItemWidth(ctx, aw - 64)
  local rv, nl = r.ImGui_InputTextWithHint(ctx, "##newlink", "paste a link, press Enter", w.newlink, KC.InputTextFlags_EnterReturnsTrue)
  w.newlink = nl
  if rv then addLink(ed, w.newlink); w.newlink = ""; r.ImGui_SetKeyboardFocusHere(ctx, -1) end
  r.ImGui_SameLine(ctx)
  if r.ImGui_Button(ctx, "Paste") then addLink(ed, r.ImGui_GetClipboardText(ctx) or "") end
end

function Pnl.current()
  local p = st.last
  if p and DB.byKey[p.full] ~= p then p = nil end
  return p or st.results[st.cursor]
end
function Pnl.info()
  local p = Pnl.current()
  if not p then r.ImGui_TextColored(ctx, C.faint, "Select a plugin to see its metadata."); return end
  r.ImGui_PushStyleColor(ctx, KC.Col_Text, C.accent); r.ImGui_TextWrapped(ctx, p.name); r.ImGui_PopStyleColor(ctx)
  local sub = {}
  if p.dev ~= "" then sub[#sub + 1] = p.dev end
  sub[#sub + 1] = p.fmt:lower()
  if #p.cats > 0 then sub[#sub + 1] = table.concat(p.cats, ", ") end
  r.ImGui_PushStyleColor(ctx, KC.Col_Text, C.muted); r.ImGui_TextWrapped(ctx, table.concat(sub, "  ·  ")); r.ImGui_PopStyleColor(ctx)
  r.ImGui_Separator(ctx)
  infoView(p, M[p.full] or {})
  if #p.folderList > 0 then
    r.ImGui_Dummy(ctx, 1, 2)
    r.ImGui_TextColored(ctx, C.faint, "FOLDERS")
    chipFlow(p.folderList, C.muted)
  end
  r.ImGui_Dummy(ctx, 1, 4)
  if r.ImGui_Button(ctx, "Open / edit...", -1) then openInfo({ p }) end
end

local function startEdit(w)
  local p = w.p; local m = M[p.full] or {}
  local f = {}
  for _, d in ipairs(S.fields) do
    local v = F.get(p, d.id)
    if d.type == "bool" then f[d.id] = v == true else f[d.id] = v end
  end
  w.ed = { rating = m.rating or 0, f = f, kw = table.concat(m.kw or {}, ", "), notes = m.notes or "",
    links = copyLinks(m.links) }
  w.edit = true
end
local function commitEdit(w)
  local p, ed = w.p, w.ed
  local kws = {}
  for k in ed.kw:gmatch("[^,]+") do k = trim(k); if k ~= "" then kws[#kws + 1] = k end end
  local m = M[p.full] or {}; M[p.full] = m
  m.rating = ed.rating
  m.f = m.f or {}
  for _, d in ipairs(S.fields) do
    local v = ed.f[d.id]
    if d.type == "bool" then
      if d.id == "inst" then if v == p.inst then m.f.inst = nil else m.f.inst = v end
      else m.f[d.id] = v or nil end
    else m.f[d.id] = v end
  end
  m.kw = kws; m.notes = ed.notes; m.links = copyLinks(ed.links)
  reindex(p)
  touchMeta(); st.dirty = true; w.edit = false
end

-- Where an auxiliary window opens: beside the main window (right if the screen has room, else left).
local function screenBounds()
  local wx, wy = st.wx or 100, st.wy or 100
  local ww, wh = st.mw or 900, st.mh or 560
  if r.JS_Window_GetViewportFromRect then
    local ok, l, t, rr, b = pcall(function()
      local x1, y1 = r.ImGui_PointConvertNative(ctx, wx, wy, true)
      local x2, y2 = r.ImGui_PointConvertNative(ctx, wx + ww, wy + wh, true)
      local L, T, R, B = r.JS_Window_GetViewportFromRect(math.floor(math.min(x1, x2)), math.floor(math.min(y1, y2)),
        math.floor(math.max(x1, x2)), math.floor(math.max(y1, y2)), true)
      local a, b2 = r.ImGui_PointConvertNative(ctx, L, T)
      local c, d = r.ImGui_PointConvertNative(ctx, R, B)
      return math.min(a, c), math.min(b2, d), math.max(a, c), math.max(b2, d)
    end)
    if ok and l then return l, t, rr, b end
  end
  return -1e5, -1e5, 1e5, 1e5
end
local function spot(W, H, yoff)
  local wx, wy = st.wx or 100, st.wy or 100
  local ww = st.mw or 900
  local L, T, R, B = screenBounds()
  local gap = 8
  local x
  if wx + ww + gap + W <= R then x = wx + ww + gap
  elseif wx - gap - W >= L then x = wx - gap - W
  else x = math.max(L, math.min(wx + ww + gap, R - W)) end
  local y = math.max(T, math.min(wy + (yoff or 0), B - H))
  return x, y
end

local infoSlot = 0
openInfo = function(list)
  local opened = 0
  for _, p in ipairs(list) do
    if opened >= 8 then status("Opened the first 8 info windows"); break end
    local found
    for _, w in ipairs(st.infos) do if w.p.full == p.full then found = w end end
    if found then found.focus = true
    else
      infoSlot = infoSlot + 1
      st.infos[#st.infos + 1] = { p = p, edit = false, ed = nil, newlink = "", slot = infoSlot, fresh = true, focus = true }
    end
    opened = opened + 1
  end
end

local function infoWindow(w)
  local p = w.p
  r.ImGui_SetNextWindowSize(ctx, 400, 470, KC.Cond_FirstUseEver)
  r.ImGui_SetNextWindowSizeConstraints(ctx, 340, 300, 900, 1100)
  if w.fresh then
    local x, y = spot(400, 470, (w.slot % 8) * 28)
    r.ImGui_SetNextWindowPos(ctx, x, y, KC.Cond_Appearing)
    w.fresh = false
  end
  if w.focus then r.ImGui_SetNextWindowFocus(ctx); w.focus = false end
  local vis, open = r.ImGui_Begin(ctx, p.name .. "###fxbinfo" .. p.full, true,
    KC.WindowFlags_NoCollapse | KC.WindowFlags_NoDocking | KC.WindowFlags_NoScrollbar | KC.WindowFlags_NoScrollWithMouse)
  if vis then
    local m = M[p.full] or {}
    r.ImGui_TextColored(ctx, C.accent, p.name)
    local sub = {}
    if p.dev ~= "" then sub[#sub + 1] = p.dev end
    sub[#sub + 1] = p.fmt:lower()
    if #p.cats > 0 then sub[#sub + 1] = table.concat(p.cats, ", ") end
    r.ImGui_TextColored(ctx, C.muted, table.concat(sub, "  ·  "))
    r.ImGui_Separator(ctx)
    local bh = r.ImGui_GetFrameHeight(ctx)
    local _, availH = r.ImGui_GetContentRegionAvail(ctx)
    if r.ImGui_BeginChild(ctx, "##body", 0, availH - bh - 12, 0) then
      if w.edit then infoEdit(w, p) else infoView(p, m) end
      r.ImGui_EndChild(ctx)
    end
    r.ImGui_Separator(ctx)
    if not w.edit then
      if r.ImGui_Button(ctx, "Edit") then startEdit(w) end
      r.ImGui_SameLine(ctx)
      if r.ImGui_Button(ctx, "Copy name") then r.ImGui_SetClipboardText(ctx, p.full) end
    else
      if r.ImGui_Button(ctx, "Save") then commitEdit(w) end
      r.ImGui_SameLine(ctx)
      if r.ImGui_Button(ctx, "Cancel") then w.edit = false end
    end
    r.ImGui_End(ctx)
  end
  return open
end
local function infoWindows()
  local i = 1
  while i <= #st.infos do
    if infoWindow(st.infos[i]) then i = i + 1 else table.remove(st.infos, i) end
  end
end

-- Bulk edit -----------------------------------------------------------------------------------
local function simpleCombo(id, w, cur, opts)
  r.ImGui_SetNextItemWidth(ctx, w)
  local out, disp = nil, cur
  for _, o in ipairs(opts) do if o[1] == cur then disp = o[2] end end
  if r.ImGui_BeginCombo(ctx, "##" .. id, disp) then
    for _, o in ipairs(opts) do
      if r.ImGui_Selectable(ctx, o[2] .. "##" .. id .. o[1], o[1] == cur) then out = o[1] end
    end
    r.ImGui_EndCombo(ctx)
  end
  return out
end
-- Confirmation for destructive buttons. Ctrl+Shift+click skips it.
local function askConfirm(msg, fn)
  local ctrl, shift = KB.mods()
  if ctrl and shift then fn() else st.confirm = { msg = msg, fn = fn, fresh = true } end
end
local function confirmBtn(label, msg, fn, w)
  if r.ImGui_Button(ctx, label, w) then askConfirm(msg, fn) end
end
local function confirmWindow()
  local c = st.confirm; if not c then return end
  if c.fresh then
    r.ImGui_SetNextWindowPos(ctx, (st.wx or 100) + 120, (st.wy or 100) + 120, KC.Cond_Appearing)
    r.ImGui_SetNextWindowFocus(ctx); c.fresh = false
  end
  r.ImGui_SetNextWindowSizeConstraints(ctx, 300, 0, 520, 400)
  local vis, open = r.ImGui_Begin(ctx, "Please confirm###fxbconfirm", true,
    KC.WindowFlags_NoCollapse | KC.WindowFlags_NoDocking | KC.WindowFlags_AlwaysAutoResize)
  if vis then
    r.ImGui_TextWrapped(ctx, c.msg)
    r.ImGui_TextColored(ctx, C.faint, "Tip: Ctrl+Shift+click skips this confirmation.")
    r.ImGui_Dummy(ctx, 1, 2)
    if r.ImGui_Button(ctx, "Confirm") then local fn = c.fn; st.confirm = nil; fn() end
    r.ImGui_SameLine(ctx)
    if r.ImGui_Button(ctx, "Cancel") then st.confirm = nil end
    r.ImGui_End(ctx)
  end
  if not open then st.confirm = nil end
end
local TRI = { { "keep", "Unchanged" }, { "yes", "Yes" }, { "no", "No" } }
local TRI_INST = { { "keep", "Unchanged" }, { "yes", "Yes" }, { "no", "No" }, { "auto", "Auto (detected)" } }
local RATE_OPTS = { { "keep", "Unchanged" }, { "0", "Clear" }, { "1", "1 star" }, { "2", "2 stars" }, { "3", "3 stars" },
  { "4", "4 stars" }, { "5", "5 stars" } }
local VAL_OPTS = { { "keep", "Unchanged" }, { "set", "Set to..." }, { "clear", "Clear" } }

openBulk = function(list)
  if #list == 0 then status("Select plugins first"); return end
  local copy = {}
  for i, p in ipairs(list) do copy[i] = p end
  st.bulk = { list = copy, fresh = true, rating = "keep", add = "", rem = "", clear = false, flags = {}, vals = {} }
  for _, d in ipairs(S.fields) do
    if d.type == "bool" then st.bulk.flags[d.id] = "keep" else st.bulk.vals[d.id] = { mode = "keep", num = 0, txt = "" } end
  end
end

local function splitKw(str)
  local out = {}
  for k in str:gmatch("[^,]+") do k = trim(k); if k ~= "" then out[#out + 1] = k end end
  return out
end
local function applyBulk(b)
  local add, rem = splitKw(b.add), {}
  for _, k in ipairs(splitKw(b.rem)) do rem[k:lower()] = true end
  for _, p in ipairs(b.list) do
    if b.clear then M[p.full] = nil
    else
      local m = M[p.full] or {}; M[p.full] = m
      if b.rating ~= "keep" then m.rating = tonumber(b.rating) end
      m.f = m.f or {}
      for _, d in ipairs(S.fields) do
        if d.type == "bool" then
          local v = b.flags[d.id]
          if d.id == "inst" then
            if v == "yes" then m.f.inst = true elseif v == "no" then m.f.inst = false elseif v == "auto" then m.f.inst = nil end
          elseif v == "yes" then m.f[d.id] = true elseif v == "no" then m.f[d.id] = nil end
        else
          local e = b.vals[d.id]
          if e.mode == "set" then
            if d.type == "number" then m.f[d.id] = e.num else m.f[d.id] = e.txt ~= "" and e.txt or nil end
          elseif e.mode == "clear" then m.f[d.id] = nil end
        end
      end
      if #add > 0 or next(rem) then
        local have, out = {}, {}
        for _, k in ipairs(m.kw or {}) do
          if not rem[k:lower()] then out[#out + 1] = k; have[k:lower()] = true end
        end
        for _, k in ipairs(add) do if not have[k:lower()] then out[#out + 1] = k; have[k:lower()] = true end end
        m.kw = out
      end
    end
    reindex(p)
  end
  touchMeta(); st.dirty = true
  status(("Updated metadata of %d plugin(s)"):format(#b.list))
end

local function bulkWindow()
  local b = st.bulk; if not b then return end
  if b.fresh then
    local x, y = spot(460, 520, 0); r.ImGui_SetNextWindowPos(ctx, x, y, KC.Cond_Appearing); b.fresh = false
  end
  r.ImGui_SetNextWindowSizeConstraints(ctx, 420, 0, 700, 900)
  local vis, open = r.ImGui_Begin(ctx, "Bulk edit###fxbbulk", true,
    KC.WindowFlags_NoCollapse | KC.WindowFlags_NoDocking | KC.WindowFlags_AlwaysAutoResize)
  if vis then
    r.ImGui_TextColored(ctx, C.accent, #b.list .. " plugin" .. (#b.list == 1 and "" or "s") .. " selected")
    local names = {}
    for i = 1, math.min(4, #b.list) do names[i] = b.list[i].name end
    local more = #b.list > 4 and ("  +" .. (#b.list - 4) .. " more") or ""
    r.ImGui_TextColored(ctx, C.muted, table.concat(names, ", ") .. more)
    r.ImGui_Separator(ctx)
    r.ImGui_BeginDisabled(ctx, b.clear)
    local function label(t) r.ImGui_AlignTextToFramePadding(ctx); r.ImGui_Text(ctx, t); r.ImGui_SameLine(ctx, 140) end
    label("Rating"); local v = simpleCombo("rate", 150, b.rating, RATE_OPTS); if v then b.rating = v end
    for _, d in ipairs(S.fields) do
      label(d.name)
      if d.type == "bool" then
        v = simpleCombo("fl" .. d.id, 150, b.flags[d.id] or "keep", d.id == "inst" and TRI_INST or TRI); if v then b.flags[d.id] = v end
      else
        local e = b.vals[d.id] or { mode = "keep", num = 0, txt = "" }; b.vals[d.id] = e
        v = simpleCombo("vm" .. d.id, 150, e.mode, VAL_OPTS); if v then e.mode = v end
        if e.mode == "set" then
          r.ImGui_SameLine(ctx); r.ImGui_SetNextItemWidth(ctx, 90)
          if d.type == "number" then local nv; _, nv = r.ImGui_InputDouble(ctx, "##vn" .. d.id, e.num, 0, 0, "%.2f"); e.num = nv
          else local nt; _, nt = r.ImGui_InputText(ctx, "##vt" .. d.id, e.txt); e.txt = nt end
        end
      end
    end
    label("Add keywords"); r.ImGui_SetNextItemWidth(ctx, 240)
    local t; _, t = r.ImGui_InputTextWithHint(ctx, "##kwadd", "comma separated", b.add); b.add = t
    label("Remove keywords"); r.ImGui_SetNextItemWidth(ctx, 240)
    _, t = r.ImGui_InputTextWithHint(ctx, "##kwrem", "comma separated", b.rem); b.rem = t
    r.ImGui_EndDisabled(ctx)
    r.ImGui_Separator(ctx)
    local c; _, c = r.ImGui_Checkbox(ctx, "Clear ALL metadata of these plugins instead", b.clear); b.clear = c
    r.ImGui_Dummy(ctx, 1, 2)
    if r.ImGui_Button(ctx, "Apply") then
      if b.clear then
        askConfirm("Clear ALL metadata of " .. #b.list .. " plugin(s)? Ratings, notes, links, keywords and field values are removed.",
          function() applyBulk(b); st.bulk = nil end)
      else applyBulk(b); st.bulk = nil end
    end
    r.ImGui_SameLine(ctx)
    if r.ImGui_Button(ctx, "Cancel") then st.bulk = nil end
    r.ImGui_End(ctx)
  end
  if not open then st.bulk = nil end
end

-------------------------------------------------------------------------------
-- Settings window
-------------------------------------------------------------------------------
local ICON_LIST = { { "refresh", "Refresh" }, { "fluent", "Fluent mode" }, { "dock", "Dock" },
  { "settings", "Settings" }, { "star", "Rating" }, { "notes", "Notes" } }
local MODES = { { "default", "Default (vector)" }, { "text", "Emoji / text" }, { "image", "PNG image" } }

local function modeLabel(mode)
  for _, m in ipairs(MODES) do if m[1] == mode then return m[2] end end
  return MODES[1][2]
end

-- Launcher actions (hotkey-able scripts written to the Scripts folder and registered in the Action list) -----
local LAUNCH = { dir = RES .. SEP .. "Scripts" .. SEP .. "FXBrowser Launchers" }
LAUNCH.template = [[-- Generated by FX Browser (%s). Re-create it from FX Browser > Settings > Launchers.
reaper.SetExtState("FXBrowser", "launch", %q, false)
local ok, err = pcall(dofile, %q)
if not ok then reaper.MB(tostring(err), "FX Browser launcher", 0) end
]]
function LAUNCH.spec(l)
  local t = {}
  if l.bang and l.bang ~= "" then t[#t + 1] = "bang=" .. l.bang; t[#t + 1] = "inv=" .. (l.inv and "1" or "0") end
  t[#t + 1] = "fluent=" .. (l.fluent and "1" or "0")
  t[#t + 1] = "close=" .. (l.close and "1" or "0")
  return table.concat(t, ";")
end
function LAUNCH.write(l)
  if not MAIN_PATH then status("Cannot locate this script's file path"); return false end
  local nm = trim((l.name or ""):gsub('[\\/:*?"<>|]', "_"))
  if nm == "" then status("Give the launcher a name first"); return false end
  r.RecursiveCreateDirectory(LAUNCH.dir, 0)
  local path = LAUNCH.dir .. SEP .. "FX Browser - " .. nm .. ".lua"
  if l.file and l.file ~= path then r.AddRemoveReaScript(false, 0, l.file, true); os.remove(l.file) end
  local f = io.open(path, "wb")
  if not f then status("Could not write the launcher file"); return false end
  f:write(string.format(LAUNCH.template, nm, LAUNCH.spec(l), MAIN_PATH)); f:close()
  r.AddRemoveReaScript(true, 0, path, true)
  l.file = path; touchSettings()
  status("Action ready: FX Browser - " .. nm)
  return true
end
function LAUNCH.remove(l)
  if l.file then r.AddRemoveReaScript(false, 0, l.file, true); os.remove(l.file); l.file = nil end
end

-- Dead plugin detection: metadata / history entries whose plugin is no longer installed ----------------------
function DB.dead()
  local nfx = 0
  for _, p in ipairs(DB.items) do if p.kind == "fx" then nfx = nfx + 1 end end
  if nfx == 0 then return nil end
  local seen, out = {}, {}
  for _, tbl in ipairs({ M, U }) do
    for key in pairs(tbl) do
      if not DB.fullSet[key] and not seen[key] then seen[key] = true; out[#out + 1] = key end
    end
  end
  table.sort(out)
  return out
end
function DB.cleanDead(list)
  saveTable(DATA_DIR .. SEP .. "meta.backup-" .. os.date("%Y%m%d-%H%M%S") .. ".lua", M)
  for _, k in ipairs(list) do M[k] = nil; U[k] = nil end
  touchMeta(); touchUsage(); st.dead = nil; st.dirty = true
  status(("Removed %d stale entries (backup saved in Data/FXBrowser)"):format(#list))
end

-- Shortcut capture ---------------------------------------------------------------------------------------------
function KB.capture(id)
  if r.ImGui_IsKeyPressed(ctx, KC.Key_Escape, false) then st.capture = nil; st.capture_err = nil; return end
  local ctrl, shift, alt = KB.mods()
  for _, name in ipairs(KB.keynames) do
    if r.ImGui_IsKeyPressed(ctx, KC["Key_" .. name], false) then
      if KB.needsMod(name) and not (ctrl or alt) then
        st.capture_err = "Letters, digits and punctuation need Ctrl or Alt (they type into the search box)."
        return
      end
      S.keys[id] = { key = name, ctrl = ctrl or nil, shift = shift or nil, alt = alt or nil }
      touchSettings(); st.capture = nil; st.capture_err = nil
      return
    end
  end
end

local function colorRow(value, id, label, onChange)
  r.ImGui_PushID(ctx, id)
  local rv, nc = r.ImGui_ColorEdit3(ctx, "##c", value, KC.ColorEditFlags_NoInputs | KC.ColorEditFlags_NoLabel)
  if rv then onChange(nc & 0xFFFFFF) end
  r.ImGui_SameLine(ctx, 0, 8); r.ImGui_AlignTextToFramePadding(ctx); r.ImGui_Text(ctx, label)
  r.ImGui_PopID(ctx)
end

local function settingsWindow()
  if not st.settings_open then st.set_placed = false; return end
  if not st.set_placed then
    local x, y = spot(700, 580, 0); r.ImGui_SetNextWindowPos(ctx, x, y, KC.Cond_Appearing); st.set_placed = true
  end
  r.ImGui_SetNextWindowSize(ctx, 700, 580, KC.Cond_FirstUseEver)
  r.ImGui_SetNextWindowSizeConstraints(ctx, 560, 400, 1800, 1600)
  local vis, open = r.ImGui_Begin(ctx, "FX Browser settings###fxbset", true, KC.WindowFlags_NoCollapse | KC.WindowFlags_NoDocking)
  if vis then
    if r.ImGui_BeginTabBar(ctx, "##settabs") then
      local theme = curTheme()

      -- General ---------------------------------------------------------
      if r.ImGui_BeginTabItem(ctx, "General") then
        r.ImGui_Dummy(ctx, 1, 2)
        local rv, b = r.ImGui_Checkbox(ctx, "Allow docking", S.dock)
        if rv then S.dock = b; if not b then st.undock = true end; touchSettings() end
        rv, b = r.ImGui_Checkbox(ctx, "Show side panel", S.side); if rv then S.side = b; touchSettings() end
        local pos = autoCombo("sidepos", 140, S.sidepos, { { "left", "Left" }, { "right", "Right" } }, S.sidepos == "left" and "Left" or "Right")
        r.ImGui_SameLine(ctx); r.ImGui_Text(ctx, "Side panel position")
        if pos then S.sidepos = pos; touchSettings() end
        r.ImGui_SetNextItemWidth(ctx, 160)
        local rv2, rh = r.ImGui_SliderInt(ctx, "Row height", S.rowh, 22, 40)
        if rv2 then S.rowh = rh; touchSettings() end
        r.ImGui_SetNextItemWidth(ctx, 160)
        local rv3, fm = r.ImGui_SliderInt(ctx, "Fluent mode: max visible results", S.fluent_max, 1, 15)
        if rv3 then S.fluent_max = fm; touchSettings() end
        rv, b = r.ImGui_Checkbox(ctx, "Keep my selection order when inserting (numbers shown on multi-select)", S.keep_order)
        if rv then S.keep_order = b; touchSettings() end
        tip("Select plugins one by one (Ctrl+click) to insert them as a chain in that exact order.")

        r.ImGui_SeparatorText(ctx, "FX list")
        rv, b = r.ImGui_Checkbox(ctx, "Derive categories of JSFX from their folder (e.g. JS: Distortion/...)", S.js_cats)
        if rv then S.js_cats = b; touchSettings(); DB.build() end
        tip("Off: only categories from REAPER's own tag files are used.")
        rv, b = r.ImGui_Checkbox(ctx, "Show FX hidden in REAPER's FX browser", S.show_hidden)
        if rv then S.show_hidden = b; touchSettings(); DB.build() end
        tip("Hidden FX are read from reaper-fxfolders.ini (read-only). They are dimmed when shown; is:hidden also reveals them.")
        rv, b = r.ImGui_Checkbox(ctx, "Sort results by format priority", S.fmt_sort)
        if rv then S.fmt_sort = b; st.dirty = true; touchSettings() end
        tip("Groups results by format in the order below; within a format the usual relevance / alphabetical order applies.")
        if S.fmt_sort then
          local mvf
          for i, f in ipairs(S.fmt_order) do
            r.ImGui_PushID(ctx, "fo" .. f)
            if r.ImGui_ArrowButton(ctx, "##up", KC.Dir_Up) and i > 1 then mvf = { i, i - 1 } end
            r.ImGui_SameLine(ctx, 0, 4)
            if r.ImGui_ArrowButton(ctx, "##dn", KC.Dir_Down) and i < #S.fmt_order then mvf = { i, i + 1 } end
            r.ImGui_SameLine(ctx, 0, 10); r.ImGui_AlignTextToFramePadding(ctx)
            r.ImGui_TextColored(ctx, fmtColor(f), i .. ".  " .. f)
            r.ImGui_PopID(ctx)
          end
          if mvf then
            S.fmt_order[mvf[1]], S.fmt_order[mvf[2]] = S.fmt_order[mvf[2]], S.fmt_order[mvf[1]]
            st.dirty = true; touchSettings()
          end
        end

        rv, b = r.ImGui_Checkbox(ctx, "Badge names also work as search keywords (e.g. \"paid\", \"instrument\")", S.badge_kw)
        if rv then S.badge_kw = b; st.dirty = true; touchSettings() end
        tip("Typing a word that matches a badge the plugin shows (a field name, rated, notes, hidden, new) finds it.")

        r.ImGui_SeparatorText(ctx, "New FX")
        r.ImGui_SetNextItemWidth(ctx, 120)
        local rvn, nd = r.ImGui_InputInt(ctx, "Count as new for (days)", S.new_days)
        if rvn then S.new_days = math.max(1, math.min(365, nd)); Q._cutT = nil; DB.countNew(); st.dirty = true; touchSettings() end
        r.ImGui_TextColored(ctx, C.faint, "Plugins are timestamped the first time this browser sees them. Everything installed at the first scan counts as known.")
        confirmBtn("Mark all as seen", "Mark every installed FX as seen? Nothing will count as new until you install more.", function()
          for _, p in ipairs(DB.items) do if p.kind == "fx" then SEEN.t[p.full] = 0; p.added = 0 end end
          touchSeen(); DB.countNew(); st.dirty = true
        end)

        r.ImGui_SeparatorText(ctx, "Layout")
        r.ImGui_SetNextItemWidth(ctx, 220)
        local rvw, fw = r.ImGui_SliderInt(ctx, "Fluent window width", S.fluent_w, 360, 1400)
        if rvw then S.fluent_w = fw; touchSettings() end
        local sm = simpleCombo("sidemode", 150, S.side_mode, { { "filters", "Filters" }, { "info", "Info" } })
        if sm then S.side_mode = sm; touchSettings() end
        r.ImGui_SameLine(ctx); r.ImGui_Text(ctx, "Side panel shows  (" .. KB.name("side_mode") .. " switches)")
        local mq = simpleCombo("marquee", 190, S.marquee, { { "off", "Off" }, { "hover", "On hover / selection" }, { "always", "Always (visible rows)" } })
        if mq then S.marquee = mq; touchSettings() end
        r.ImGui_SameLine(ctx); r.ImGui_Text(ctx, "Scroll long names")
        r.ImGui_TextColored(ctx, C.faint, "Drag the divider between the list and the side panel to resize it.")

        r.ImGui_SeparatorText(ctx, "Recent and frequent")
        rv, b = r.ImGui_Checkbox(ctx, "Show recent / frequent plugins when the search box is empty", S.rf_on)
        if rv then S.rf_on = b; st.dirty = true; touchSettings() end
        local modes = { { "recent", "Recent" }, { "frequent", "Frequent" }, { "both", "Recent + frequent" } }
        local nm = simpleCombo("rfmode", 170, S.rf_mode, modes)
        if nm then S.rf_mode = nm; st.dirty = true; touchSettings() end
        r.ImGui_SameLine(ctx); r.ImGui_Text(ctx, "Show")
        r.ImGui_SetNextItemWidth(ctx, 160)
        local rvm, mx = r.ImGui_SliderInt(ctx, "Max visible results##rfmax", S.rf_max, 1, 30)
        if rvm then S.rf_max = mx; st.dirty = true; touchSettings() end
        rv, b = r.ImGui_Checkbox(ctx, "Also show in fluent mode", S.rf_fluent)
        if rv then S.rf_fluent = b; st.dirty = true; touchSettings() end
        confirmBtn("Clear history", "Clear the recent / frequent history?", function()
          for k in pairs(U) do U[k] = nil end; touchUsage(); st.dirty = true; status("History cleared")
        end)
        r.ImGui_EndTabItem(ctx)
      end

      -- Appearance ------------------------------------------------------
      if r.ImGui_BeginTabItem(ctx, "Appearance") then
        r.ImGui_Dummy(ctx, 1, 2)
        r.ImGui_AlignTextToFramePadding(ctx); r.ImGui_Text(ctx, "Theme"); r.ImGui_SameLine(ctx, 80)
        local nt = simpleCombo("theme", 140, S.theme, { { "dark", "Dark" }, { "light", "Light" } })
        if nt then S.theme = nt; applyTheme(); touchSettings() end

        r.ImGui_SeparatorText(ctx, "Interface colors  (" .. theme .. " theme)")
        for i, tk in ipairs(TOKENS) do
          local key = tk[1]
          colorRow(S.tcol[theme][key] or THEMES[theme][key], "t" .. key, tk[2], function(c)
            S.tcol[theme][key] = c; applyTheme(); touchSettings()
          end)
          if i % 2 == 1 then r.ImGui_SameLine(ctx, 340) end
        end
        confirmBtn("Reset interface colors", "Reset all interface colors of the " .. theme .. " theme?", function()
          S.tcol[theme] = {}; applyTheme(); touchSettings()
        end)

        r.ImGui_SeparatorText(ctx, "Format badge colors  (" .. theme .. " theme)")
        for i, f in ipairs(FMT_LIST) do
          colorRow(S.fcol[theme][f] or FMT_COLOR[theme][f], "f" .. f, f, function(c)
            S.fcol[theme][f] = c; touchSettings()
          end)
          if i % 2 == 1 then r.ImGui_SameLine(ctx, 340) end
        end
        confirmBtn("Reset format colors", "Reset the format colors of the " .. theme .. " theme?", function()
          S.fcol[theme] = {}; touchSettings()
        end)

        r.ImGui_SeparatorText(ctx, "Fonts")
        r.ImGui_AlignTextToFramePadding(ctx); r.ImGui_Text(ctx, "Font"); r.ImGui_SameLine(ctx, 80)
        local fam = simpleCombo("ff", 190, S.font_family, FONT.families)
        if fam then S.font_family = fam; st.fonts_dirty = true; touchSettings() end
        if S.font_family == "custom" then
          r.ImGui_SetNextItemWidth(ctx, -1)
          local rvf, nf = r.ImGui_InputTextWithHint(ctx, "##fcustom", "font family name (e.g. Segoe UI) or path to a .ttf", S.font_custom)
          if rvf then S.font_custom = nf; st.fonts_dirty = true; touchSettings() end
        end
        r.ImGui_SetNextItemWidth(ctx, 200)
        local rv1, v1 = r.ImGui_SliderInt(ctx, "Interface font size", S.fs_ui, 9, 24)
        if rv1 then S.fs_ui = v1; st.fonts_dirty = true; touchSettings() end
        r.ImGui_SetNextItemWidth(ctx, 200)
        local rv2, v2 = r.ImGui_SliderInt(ctx, "Results and badges font size", S.fs_list, 9, 24)
        if rv2 then S.fs_list = v2; st.fonts_dirty = true; touchSettings() end
        local rvb, bb = r.ImGui_Checkbox(ctx, "Bold", S.font_bold)
        if rvb then S.font_bold = bb; st.fonts_dirty = true; touchSettings() end
        r.ImGui_SameLine(ctx, 0, 16)
        local rvi, ib = r.ImGui_Checkbox(ctx, "Italic", S.font_italic)
        if rvi then S.font_italic = ib; st.fonts_dirty = true; touchSettings() end
        r.ImGui_TextColored(ctx, C.faint, "Default keeps REAPER's built-in font (size 13). Changing size or style switches to the system font.")
        confirmBtn("Reset fonts", "Reset font family, size and style to the defaults?", function()
          S.font_family, S.font_custom, S.fs_ui, S.fs_list, S.font_bold, S.font_italic = "default", "", 13, 13, false, false
          st.fonts_dirty = true; touchSettings()
        end)
        r.ImGui_EndTabItem(ctx)
      end

      -- Badges ----------------------------------------------------------
      if r.ImGui_BeginTabItem(ctx, "Badges") then
        r.ImGui_Dummy(ctx, 1, 2)
        r.ImGui_TextWrapped(ctx, "Order = priority. When a result row gets narrow, badges at the bottom of this list are hidden first " ..
          "and collapse into a +N pill (hover the row to see them). Untick a badge to never show it.")
        r.ImGui_Dummy(ctx, 1, 2)
        local mv
        for i, k in ipairs(S.badge_order) do
          r.ImGui_PushID(ctx, k)
          if r.ImGui_ArrowButton(ctx, "##up", KC.Dir_Up) and i > 1 then mv = { i, i - 1 } end
          r.ImGui_SameLine(ctx, 0, 4)
          if r.ImGui_ArrowButton(ctx, "##dn", KC.Dir_Down) and i < #S.badge_order then mv = { i, i + 1 } end
          r.ImGui_SameLine(ctx, 0, 14)
          if k == "fmt" then
            r.ImGui_AlignTextToFramePadding(ctx); r.ImGui_TextColored(ctx, C.faint, "per format")
            tip("Format colors are set per format in the Appearance tab")
          else
            local fd = F.byId[k]
            local curc = fd and ((fd.col and fd.col[theme]) or BADGE_COLOR[theme][k] or (theme == "dark" and 0x9aa7b5 or 0x5b6b7a))
              or (S.bcol[theme][k] or BADGE_COLOR[theme][k])
            local rv, nc = r.ImGui_ColorEdit3(ctx, "##col", curc, KC.ColorEditFlags_NoInputs | KC.ColorEditFlags_NoLabel)
            if rv then
              if fd then fd.col = fd.col or {}; fd.col[theme] = nc & 0xFFFFFF else S.bcol[theme][k] = nc & 0xFFFFFF end
              touchSettings()
            end
            tip("Badge color (" .. theme .. " theme)")
          end
          r.ImGui_SameLine(ctx, 0, 14)
          local rv2, v = r.ImGui_Checkbox(ctx, BADGE_LABEL[k] or (F.byId[k] and F.byId[k].name) or k, not S.badge_off[k])
          if rv2 then S.badge_off[k] = (not v) or nil; touchSettings() end
          r.ImGui_PopID(ctx)
        end
        if mv then
          S.badge_order[mv[1]], S.badge_order[mv[2]] = S.badge_order[mv[2]], S.badge_order[mv[1]]; touchSettings()
        end
        r.ImGui_Dummy(ctx, 1, 4)
        confirmBtn("Reset order", "Reset the badge order to the default?", function()
          S.badge_order = { table.unpack(BADGE_ORDER) }; F.reindex(); touchSettings()
        end)
        r.ImGui_SameLine(ctx)
        confirmBtn("Reset badge colors", "Reset all badge colors of the " .. theme .. " theme?", function()
          S.bcol[theme] = {}
          for _, d in ipairs(S.fields) do if d.col then d.col[theme] = nil end end
          touchSettings()
        end)
        r.ImGui_EndTabItem(ctx)
      end

      -- Fields ----------------------------------------------------------
      if r.ImGui_BeginTabItem(ctx, "Fields") then
        r.ImGui_Dummy(ctx, 1, 2)
        r.ImGui_TextWrapped(ctx, "Your own metadata. Yes/no fields show a badge when true (or when false); number and text fields " ..
          "show their value, an icon, or both. Search with is:name, name:>=3, name:text. Rating, notes and keywords are built in.")
        r.ImGui_Dummy(ctx, 1, 2)
        local delAt, mvF
        local TYPES = { { "bool", "Yes / no" }, { "number", "Number" }, { "text", "Text" } }
        local ICMODES = { { "default", "Vector icon" }, { "text", "Emoji / text" }, { "image", "PNG image" } }
        for i, d in ipairs(S.fields) do
          r.ImGui_PushID(ctx, "fd" .. d.id)
          if r.ImGui_CollapsingHeader(ctx, d.name .. "###hdr") then
            d.icon = d.icon or { mode = "default", value = "dot" }
            r.ImGui_SetNextItemWidth(ctx, 200)
            local rv, nm = r.ImGui_InputText(ctx, "Name##nm", d.name)
            if rv then d.name = nm; F.reindex(); touchSettings() end
            local tv = simpleCombo("ftype", 120, d.type, TYPES)
            if tv then d.type = tv; touchSettings(); st.dirty = true end
            r.ImGui_SameLine(ctx); r.ImGui_Text(ctx, "Type")
            if d.type == "bool" then
              local sv = simpleCombo("fshow", 160, d.show or "true", { { "true", "When yes" }, { "false", "When no" } })
              if sv then d.show = sv; touchSettings(); st.dirty = true end
              r.ImGui_SameLine(ctx); r.ImGui_Text(ctx, "Show badge")
            else
              local b2
              rv, b2 = r.ImGui_Checkbox(ctx, "Show value##sv", d.showValue ~= false); if rv then d.showValue = b2; touchSettings() end
              r.ImGui_SameLine(ctx)
              rv, b2 = r.ImGui_Checkbox(ctx, "Show icon##si", d.showIcon ~= false); if rv then d.showIcon = b2; touchSettings() end
              r.ImGui_SameLine(ctx); r.ImGui_SetNextItemWidth(ctx, 70)
              local un; rv, un = r.ImGui_InputTextWithHint(ctx, "Unit##un", "unit", d.unit or ""); if rv then d.unit = un; touchSettings() end
            end
            local x, y = r.ImGui_GetCursorScreenPos(ctx)
            r.ImGui_Dummy(ctx, 20, 20)
            drawFieldIcon(r.ImGui_GetWindowDrawList(ctx), d, x + 2, y + 2, 16, F.color(d), true)
            r.ImGui_SameLine(ctx)
            local im = simpleCombo("ficm", 130, d.icon.mode, ICMODES)
            if im then d.icon.mode = im; d.icon.value = (im == "default") and "dot" or ""; touchSettings() end
            r.ImGui_SameLine(ctx)
            if d.icon.mode == "default" then
              local opts = {}
              for _, vname in ipairs(F.vectors) do opts[#opts + 1] = { vname, vname } end
              local iv = simpleCombo("ficv", 110, d.icon.value, opts)
              if iv then d.icon.value = iv; touchSettings() end
            else
              r.ImGui_SetNextItemWidth(ctx, 200)
              local vv; rv, vv = r.ImGui_InputTextWithHint(ctx, "##icv", d.icon.mode == "text" and "emoji or text" or "path to .png", d.icon.value or "")
              if rv then d.icon.value = vv; touchSettings() end
            end
            for _, th in ipairs({ "dark", "light" }) do
              r.ImGui_SameLine(ctx, 0, 10)
              local cur = (d.col and d.col[th]) or BADGE_COLOR[th][d.id] or (th == "dark" and 0x9aa7b5 or 0x5b6b7a)
              local crv, nc = r.ImGui_ColorEdit3(ctx, "##c" .. th, cur, KC.ColorEditFlags_NoInputs | KC.ColorEditFlags_NoLabel)
              if crv then d.col = d.col or {}; d.col[th] = nc & 0xFFFFFF; touchSettings() end
              tip("Badge color (" .. th .. " theme)")
            end
            if r.ImGui_Button(ctx, "Move up##u") and i > 1 then mvF = { i, i - 1 } end
            r.ImGui_SameLine(ctx)
            if r.ImGui_Button(ctx, "Move down##d") and i < #S.fields then mvF = { i, i + 1 } end
            r.ImGui_SameLine(ctx)
            confirmBtn("Delete field##x", "Delete the field '" .. d.name .. "' and its values on every plugin?", function()
              local id = d.id
              for k, x in ipairs(S.fields) do if x.id == id then table.remove(S.fields, k); break end end
              for _, m in pairs(M) do if m.f then m.f[id] = nil end end
              F.reindex(); touchSettings(); touchMeta(); st.dirty = true
            end)
            r.ImGui_Dummy(ctx, 1, 4)
          end
          r.ImGui_PopID(ctx)
        end
        if mvF then S.fields[mvF[1]], S.fields[mvF[2]] = S.fields[mvF[2]], S.fields[mvF[1]]; touchSettings() end
        if delAt then
          local id = S.fields[delAt].id
          table.remove(S.fields, delAt)
          for _, m in pairs(M) do if m.f then m.f[id] = nil end end
          F.reindex(); touchSettings(); touchMeta(); st.dirty = true
        end
        if r.ImGui_Button(ctx, "Add field") then
          S.fields[#S.fields + 1] = { id = F.newId(), name = "New field", type = "bool", show = "true",
            icon = { mode = "default", value = "dot" } }
          F.reindex(); touchSettings()
        end
        r.ImGui_SameLine(ctx)
        if r.ImGui_Button(ctx, "Restore default fields") then
          for _, d0 in ipairs(F.defaults()) do if not F.byId[d0.id] then S.fields[#S.fields + 1] = d0 end end
          F.reindex(); touchSettings()
        end
        r.ImGui_EndTabItem(ctx)
      end

      -- Icons -----------------------------------------------------------
      if r.ImGui_BeginTabItem(ctx, "Icons") then
        r.ImGui_Dummy(ctx, 1, 2)
        r.ImGui_TextWrapped(ctx, "Pick a PNG or an emoji/text per icon (SVG is not supported by ReaImGui). " ..
          "Icons of metadata fields (paid, CPU, ...) are set in the Fields tab.")
        r.ImGui_Dummy(ctx, 1, 2)
        for _, ic in ipairs(ICON_LIST) do
          local o = S.icons[ic[1]] or { mode = "default", value = "" }
          r.ImGui_PushID(ctx, ic[1])
          local x, y = r.ImGui_GetCursorScreenPos(ctx)
          r.ImGui_Dummy(ctx, 20, 20)
          drawIcon(r.ImGui_GetWindowDrawList(ctx), ic[1], x + 2, y + 2, 16, C.text, true)
          r.ImGui_SameLine(ctx); r.ImGui_Text(ctx, ic[2])
          r.ImGui_SameLine(ctx, 130)
          local nm = autoCombo("icmode", 140, o.mode, MODES, modeLabel(o.mode))
          if nm then o.mode = nm; S.icons[ic[1]] = o; touchSettings() end
          if o.mode ~= "default" then
            r.ImGui_SameLine(ctx); r.ImGui_SetNextItemWidth(ctx, -1)
            local rvv, val = r.ImGui_InputTextWithHint(ctx, "##val", o.mode == "text" and "emoji or text" or "path to .png", o.value or "")
            if rvv then o.value = val; S.icons[ic[1]] = o; touchSettings() end
          end
          r.ImGui_PopID(ctx)
        end
        r.ImGui_EndTabItem(ctx)
      end

      -- Scopes -----------------------------------------------------------
      if r.ImGui_BeginTabItem(ctx, "Scopes") then
        r.ImGui_Dummy(ctx, 1, 2)
        r.ImGui_TextWrapped(ctx, "Type a keybind in the search box and press Tab. Type ! before it (e.g. !dbg) to invert the scope.")
        r.ImGui_Dummy(ctx, 1, 2)
        local removeAt
        for i, bg in ipairs(S.bangs) do
          r.ImGui_PushID(ctx, "b" .. i)
          local kind = autoCombo("kind", 120, bg.kind, KINDS, kindLabel(bg.kind))
          if kind then bg.kind = kind; bg.value = ""; touchSettings() end
          r.ImGui_SameLine(ctx)
          local sum = {}
          for _, f in ipairs(FLAG_LIST) do
            local m = (bg.flags or {})[f[1]]
            if m == 1 then sum[#sum + 1] = "+" .. f[2] elseif m == -1 then sum[#sum + 1] = "-" .. f[2] end
          end
          if r.ImGui_Button(ctx, (#sum > 0 and table.concat(sum, " ") or "Metadata") .. "##meta", 130) then r.ImGui_OpenPopup(ctx, "flags") end
          tip("Include (+) or exclude (-) plugins by metadata")
          if r.ImGui_BeginPopup(ctx, "flags") then
            bg.flags = bg.flags or {}
            for _, f in ipairs(FLAG_LIST) do
              local m = bg.flags[f[1]] or 0
              local txt = (m == 1 and "+ " or m == -1 and "- " or "  ") .. f[2]
              if r.ImGui_Selectable(ctx, txt .. "##f" .. f[1], m ~= 0, (hasConst('SelectableFlags_NoAutoClosePopups') and KC.SelectableFlags_NoAutoClosePopups or KC.SelectableFlags_DontClosePopups)) then
                m = (m == 0) and 1 or (m == 1 and -1 or 0)
                bg.flags[f[1]] = (m ~= 0) and m or nil; touchSettings()
              end
            end
            r.ImGui_EndPopup(ctx)
          end
          r.ImGui_SameLine(ctx)
          local opts = bangOptions(bg.kind)
          local disp = (bg.value and bg.value ~= "") and bg.value or "(any)"
          if bg.kind == "all" then r.ImGui_BeginDisabled(ctx) end
          local val = autoCombo("val", 170, bg.value or "", opts, disp)
          if bg.kind == "all" then r.ImGui_EndDisabled(ctx) end
          if val then bg.value = val; touchSettings() end
          r.ImGui_SameLine(ctx); r.ImGui_SetNextItemWidth(ctx, 60)
          local rk, key = r.ImGui_InputTextWithHint(ctx, "##key", "key", bg.key)
          if rk then bg.key = trim(key:lower():gsub("[%s!]", "")); touchSettings() end
          tip("Keybind: type it in the search box and press Tab")
          r.ImGui_SameLine(ctx)
          confirmBtn("x##del", "Remove the scope '" .. bg.key .. "'?", function()
            for k, x in ipairs(S.bangs) do if x == bg then table.remove(S.bangs, k); break end end
            touchSettings()
          end)
          -- extra filter on metadata: any search syntax
          r.ImGui_AlignTextToFramePadding(ctx); r.ImGui_TextColored(ctx, C.faint, "   Filter")
          r.ImGui_SameLine(ctx); r.ImGui_SetNextItemWidth(ctx, -100)
          local rq, qv = r.ImGui_InputTextWithHint(ctx, "##q", "e.g.  cpu:<1   is:paid   mood:warm   reviewed:no   rating:>=4", bg.query or "")
          if rq then bg.query = qv ~= "" and qv or nil; touchSettings() end
          tip("Extra conditions in the search syntax. Combine with the Type / Category / Metadata selectors on this row.")
          r.ImGui_SameLine(ctx)
          local qopts = { { "is:new", "is:new" }, { "rating:>=4", "rating:>=4" }, { "fmt:", "fmt:" }, { "dev:", "dev:" }, { "cat:", "cat:" },
            { "kw:", "kw:" } }
          for _, d in ipairs(S.fields) do
            local nm = d.name:lower():gsub("%s+", "")
            if d.type == "bool" then
              qopts[#qopts + 1] = { "is:" .. nm, "is:" .. nm }; qopts[#qopts + 1] = { nm .. ":no", nm .. ":no" }
            elseif d.type == "number" then qopts[#qopts + 1] = { nm .. ":<", nm .. ":<  (number)" }; qopts[#qopts + 1] = { nm .. ":>=", nm .. ":>=  (number)" }
            else qopts[#qopts + 1] = { nm .. ":", nm .. ":  (text)" } end
          end
          local add = simpleCombo("addq", 90, "+ add", qopts)
          if add then bg.query = trim((bg.query or "") .. " " .. add); touchSettings() end
          r.ImGui_PopID(ctx)
        end
        if removeAt then table.remove(S.bangs, removeAt); touchSettings() end
        if r.ImGui_Button(ctx, "Add scope") then S.bangs[#S.bangs + 1] = { key = "new", kind = "all", value = "", flags = {} }; touchSettings() end
        r.ImGui_EndTabItem(ctx)
      end

      -- Shortcuts -------------------------------------------------------
      if r.ImGui_BeginTabItem(ctx, "Shortcuts") then
        r.ImGui_Dummy(ctx, 1, 2)
        r.ImGui_TextWrapped(ctx, "Click a shortcut, then press the new key combination. Esc cancels. " ..
          "Letters, digits and punctuation need Ctrl or Alt. Shortcuts work while the browser window is focused.")
        r.ImGui_Dummy(ctx, 1, 2)
        if st.capture then KB.capture(st.capture) end
        local count = {}
        for _, a in ipairs(KB.actions) do local t = KB.name(a.id); count[t] = (count[t] or 0) + 1 end
        for _, a in ipairs(KB.actions) do
          r.ImGui_PushID(ctx, a.id)
          r.ImGui_AlignTextToFramePadding(ctx); r.ImGui_Text(ctx, a.label)
          r.ImGui_SameLine(ctx, 320)
          local label = (st.capture == a.id) and "Press keys..." or KB.name(a.id)
          if r.ImGui_Button(ctx, label .. "##cap", 150) then st.capture = a.id; st.capture_err = nil end
          r.ImGui_SameLine(ctx)
          if r.ImGui_SmallButton(ctx, "Reset") then S.keys[a.id] = nil; touchSettings() end
          if (count[KB.name(a.id)] or 0) > 1 then r.ImGui_SameLine(ctx); r.ImGui_TextColored(ctx, C.red, "conflict") end
          r.ImGui_PopID(ctx)
        end
        if st.capture_err then r.ImGui_TextColored(ctx, C.warn, st.capture_err) end
        r.ImGui_Dummy(ctx, 1, 4)
        confirmBtn("Reset all shortcuts", "Reset every keyboard shortcut to its default?", function() S.keys = {}; touchSettings() end)
        r.ImGui_EndTabItem(ctx)
      end

      -- Launchers -------------------------------------------------------
      if r.ImGui_BeginTabItem(ctx, "Launchers") then
        r.ImGui_Dummy(ctx, 1, 2)
        r.ImGui_TextWrapped(ctx, "A launcher is a small script that appears in REAPER's Action list (Actions > Show action list > filter " ..
          "\"FX Browser\") so you can give it a keyboard shortcut. It opens the browser straight into a scope and can close it after " ..
          "an insert. If the browser is already open it is reused.")
        r.ImGui_Dummy(ctx, 1, 2)
        local bangOpts = { { "", "(no scope)" } }
        for _, bg in ipairs(S.bangs) do bangOpts[#bangOpts + 1] = { bg.key, bg.key .. "  (" .. kindLabel(bg.kind) .. ")" } end
        local removeAt
        for i, l in ipairs(S.launchers) do
          r.ImGui_PushID(ctx, "l" .. i)
          r.ImGui_SetNextItemWidth(ctx, 190)
          local rn, nm = r.ImGui_InputTextWithHint(ctx, "##name", "launcher name", l.name or "")
          if rn then l.name = nm; touchSettings() end
          r.ImGui_SameLine(ctx)
          local disp = (l.bang and l.bang ~= "") and l.bang or "(no scope)"
          local nb = autoCombo("lbang", 150, l.bang or "", bangOpts, disp)
          if nb then l.bang = nb; touchSettings() end
          r.ImGui_SameLine(ctx)
          local rvi, inv = r.ImGui_Checkbox(ctx, "Inverted", l.inv or false)
          if rvi then l.inv = inv; touchSettings() end
          tip("Same as typing !key + Tab")
          local rvf, fl = r.ImGui_Checkbox(ctx, "Fluent mode", l.fluent or false)
          if rvf then l.fluent = fl; touchSettings() end
          r.ImGui_SameLine(ctx, 0, 16)
          local rvc, cl = r.ImGui_Checkbox(ctx, "Close after insert", l.close or false)
          if rvc then l.close = cl; touchSettings() end
          r.ImGui_SameLine(ctx, 0, 16)
          if r.ImGui_Button(ctx, l.file and "Update action" or "Create action") then LAUNCH.write(l) end
          r.ImGui_SameLine(ctx)
          confirmBtn("Remove", "Remove the launcher '" .. (l.name or "") .. "' and its action script?", function()
            for k, x in ipairs(S.launchers) do
              if x == l then LAUNCH.remove(x); table.remove(S.launchers, k); break end
            end
            touchSettings()
          end)
          if l.file then r.ImGui_TextColored(ctx, C.faint, "Action: FX Browser - " .. (l.name or "")) end
          r.ImGui_Separator(ctx)
          r.ImGui_PopID(ctx)
        end
        if removeAt then LAUNCH.remove(S.launchers[removeAt]); table.remove(S.launchers, removeAt); touchSettings() end
        if r.ImGui_Button(ctx, "Add launcher") then
          S.launchers[#S.launchers + 1] = { name = "", bang = "", inv = false, fluent = false, close = false }; touchSettings()
        end
        if not MAIN_PATH then r.ImGui_TextColored(ctx, C.warn, "This script's file path could not be detected; launchers cannot be created.") end
        r.ImGui_EndTabItem(ctx)
      end

      -- Database --------------------------------------------------------
      if r.ImGui_BeginTabItem(ctx, "Database") then
        r.ImGui_Dummy(ctx, 1, 2)
        if not st.rep then st.rep = DB.report() end
        r.ImGui_TextWrapped(ctx, st.rep.summary)
        r.ImGui_Dummy(ctx, 1, 2)
        if r.ImGui_Button(ctx, "Rescan") then DB.build(); status("FX list refreshed") end
        r.ImGui_SameLine(ctx)
        if r.ImGui_Button(ctx, "Copy diagnostics") then r.ImGui_SetClipboardText(ctx, st.rep.full) end
        tip("Copies a report of what was parsed from the REAPER .ini files")

        r.ImGui_SeparatorText(ctx, "Dead plugin cleanup")
        if st.dead == nil then st.dead = DB.dead() or false end
        if st.dead == false then
          r.ImGui_TextColored(ctx, C.faint, "The plugin list is empty. Rescan first.")
        else
          local d = st.dead
          if #d == 0 then
            r.ImGui_TextColored(ctx, C.green, "No stale entries: every plugin with metadata or history is still installed.")
          else
            r.ImGui_TextWrapped(ctx, #d .. " metadata / history entries belong to plugins that are no longer installed " ..
              "(removed, renamed, or not scanned).")
            if r.ImGui_BeginChild(ctx, "##deadlist", 0, 120, KC.ChildFlags_Border) then
              for _, k in ipairs(d) do r.ImGui_TextColored(ctx, C.muted, k) end
              r.ImGui_EndChild(ctx)
            end
            if r.ImGui_Button(ctx, "Clean up " .. #d .. " entries...") then r.ImGui_OpenPopup(ctx, "Confirm cleanup") end
            if r.ImGui_BeginPopupModal(ctx, "Confirm cleanup", true, KC.WindowFlags_AlwaysAutoResize) then
              r.ImGui_Text(ctx, "Remove " .. #d .. " stale entries?")
              r.ImGui_TextColored(ctx, C.muted, "A backup of your metadata is saved first (Data/FXBrowser/meta.backup-*.lua).")
              if r.ImGui_Button(ctx, "Clean up") then DB.cleanDead(d); r.ImGui_CloseCurrentPopup(ctx) end
              r.ImGui_SameLine(ctx)
              if r.ImGui_Button(ctx, "Cancel") then r.ImGui_CloseCurrentPopup(ctx) end
              r.ImGui_EndPopup(ctx)
            end
          end
          r.ImGui_SameLine(ctx)
          if r.ImGui_Button(ctx, "Re-check") then st.dead = nil end
        end
        r.ImGui_EndTabItem(ctx)
      end

      r.ImGui_EndTabBar(ctx)
    end
    r.ImGui_End(ctx)
  end
  if not open then st.settings_open = false; st.capture = nil end
end

-------------------------------------------------------------------------------
-- Keyboard
-------------------------------------------------------------------------------
local function setFluent(on)
  st.fluent = on; st.fl_h = nil
  if not on then st.fl_restore = true end
  st.focus = true; st.dirty = true
end

local function moveCursor(delta, extend)
  local n = #st.results; if n == 0 then return end
  local c = math.max(1, math.min(n, st.cursor + delta))
  if extend then selectRange(st.anchor, c) else selectOnly(c) end
  st.scroll = true
end

local function autocomplete()
  local f, v = st.text:lower():match("(%a+):([^%s]*)$")
  local map = { dev = DB.f.dev, d = DB.f.dev, developer = DB.f.dev, fmt = DB.f.fmt, format = DB.f.fmt, type = DB.f.fmt,
    cat = DB.f.cat, c = DB.f.cat, category = DB.f.cat, folder = DB.f.fold, f = DB.f.fold }
  if f and map[f] then
    for _, name in ipairs(map[f].names) do
      if name:lower():find(v, 1, true) == 1 then
        local rep = name:find("%s") and ('"' .. name .. '"') or name
        setText(st.text:sub(1, #st.text - #v) .. rep); return
      end
    end
  end
  local top = st.results[1]
  if top then setText(top.name) end
end

local function handleKeys(focused)
  if not focused then return end
  local ctrl, shift = KB.mods()
  local function pressed(k, rep) return r.ImGui_IsKeyPressed(ctx, KC[k], rep or false) end

  if KB.hit("fluent") then setFluent(not st.fluent); return end
  if KB.hit("meta") then openInfo(selList()) end
  if KB.hit("bulk") then openBulk(selList()) end
  if KB.hit("panel") then S.side = not S.side; touchSettings() end
  if KB.hit("clear_filters") then Act.clearFilters() end
  if KB.hit("deselect") then Act.deselect() end
  if KB.hit("side_mode") then
    S.side_mode = (S.side_mode == "info") and "filters" or "info"; S.side = true; touchSettings()
  end
  if KB.hit("refresh") then Act.refresh() end
  for n = 0, 5 do
    if KB.hit("rate" .. n) then Act.setRating(selList(), n) end
  end

  if pressed("Key_Escape") then
    if st.bang then st.bang = nil; setText("")
    elseif st.text ~= "" then setText("")
    elseif st.fluent then setFluent(false) end
  end
  if pressed("Key_Tab") then
    if not st.bang then
      local t = trim(st.text:lower())
      local inv = false
      if t:sub(1, 1) == "!" then inv = true; t = t:sub(2) end   -- "!key" + Tab = inverted bang
      local hit
      for _, b in ipairs(S.bangs) do if b.key ~= "" and b.key == t then hit = b end end
      if hit then activateBang(hit, inv) else autocomplete() end
    else autocomplete() end
  end

  local list
  local function sel() list = list or selList(); return list end
  if KB.hit("ins_track") then local l = sel(); if #l > 0 then Act.toTracks(l) end end
  if KB.hit("ins_take") then local l = sel(); if #l > 0 then Act.toTakes(l) end end
  if KB.hit("open_track") then local l = sel(); if #l > 0 then Act.toTracks(l, false, true) end end
  if KB.hit("open_take") then local l = sel(); if #l > 0 then Act.toTakes(l, true) end end

  if pressed("Key_DownArrow", true) then moveCursor(1, shift) end
  if pressed("Key_UpArrow", true) then moveCursor(-1, shift) end
  if pressed("Key_PageDown", true) then moveCursor(10, shift) end
  if pressed("Key_PageUp", true) then moveCursor(-10, shift) end
  if pressed("Key_Home") and ctrl then moveCursor(-1e9, shift) end
  if pressed("Key_End") and ctrl then moveCursor(1e9, shift) end
  if ctrl and pressed("Key_A") then
    st.sel = {}; st.seq = {}
    for _, p in ipairs(st.results) do markSel(p) end
  end
end

-------------------------------------------------------------------------------
-- Main frame
-------------------------------------------------------------------------------
local function hintMain() return "Search plugins...  (Tab: scopes · " .. KB.name("fluent") .. ": fluent)" end
local TIP_SEARCH = "Type to search. Operators: && (and), || (or), -word (not), \"phrase\"\n" ..
    "Fields: dev: fmt: cat: folder: kw: is:paid|free|net|early|inst|32|notes|rated rating:>=4 cpu:<5\n" ..
    "Scope: type its key then Tab. Esc leaves the scope."

local function toolbar(fluent)
  local bh = r.ImGui_GetFrameHeight(ctx)
  local avail = r.ImGui_GetContentRegionAvail(ctx)
  local gap = 6
  local nbtn = fluent and 0 or 4
  local boxW = avail - nbtn * (bh + gap)
  local x, y = r.ImGui_GetCursorScreenPos(ctx)
  local dl = r.ImGui_GetWindowDrawList(ctx)
  r.ImGui_DrawList_AddRectFilled(dl, x, y, x + boxW, y + bh, C.input, 6)
  r.ImGui_DrawList_AddRect(dl, x, y, x + boxW, y + bh, st.bang and C.accent or C.border, 6, 0, 1)
  local prefixW = 0
  if st.bang then
    local kw = (st.bang.invert and "!" or "") .. st.bang.key
    local kwW, th = r.ImGui_CalcTextSize(ctx, kw)
    r.ImGui_DrawList_AddText(dl, x + 12, y + (bh - th) / 2, C.accent, kw)
    local sx = x + 12 + kwW + 8
    r.ImGui_DrawList_AddLine(dl, sx, y + 6, sx, y + bh - 6, C.border, 1)
    prefixW = 12 + kwW + 8 + 2
  end
  r.ImGui_SetCursorScreenPos(ctx, x + prefixW, y)
  r.ImGui_SetNextItemWidth(ctx, boxW - prefixW - 4)
  if st.focus then r.ImGui_SetKeyboardFocusHere(ctx); st.focus = false end
  r.ImGui_PushStyleColor(ctx, KC.Col_FrameBg, 0x00000000)
  r.ImGui_PushStyleColor(ctx, KC.Col_FrameBgHovered, 0x00000000)
  r.ImGui_PushStyleColor(ctx, KC.Col_FrameBgActive, 0x00000000)
  local hint = st.bang and bangHint(st.bang) or hintMain()
  local rv, txt = r.ImGui_InputTextWithHint(ctx, "##query" .. st.qver, hint, st.text)
  r.ImGui_PopStyleColor(ctx, 3)
  if rv then st.text = txt; st.dirty = true; st.cursor = 1; st.anchor = 1; st.sel = {}; st.scroll = true end
  tip(TIP_SEARCH)

  if not fluent then
    local bx = x + boxW + gap
    local function nextBtn() r.ImGui_SetCursorScreenPos(ctx, bx, y); bx = bx + bh + gap end
    nextBtn(); if iconBtn("refresh", "refresh", "Refresh FX list (" .. KB.name("refresh") .. ")") then DB.build(); status("FX list refreshed") end
    nextBtn(); if iconBtn("fluent", "fluent", "Fluent search mode (" .. KB.name("fluent") .. ")") then setFluent(true) end
    nextBtn(); if iconBtn("dock", "dock", S.dock and "Docking on — click to disable" or "Docking off — click to allow docking", S.dock) then
      S.dock = not S.dock; if not S.dock then st.undock = true end; touchSettings()
    end
    nextBtn(); if iconBtn("settings", "settings", "Settings", st.settings_open) then st.settings_open = not st.settings_open end
  end
  r.ImGui_SetCursorScreenPos(ctx, x, y + bh + gap)
  r.ImGui_Dummy(ctx, 1, 1)
end

local function footerHint(maxw)
  local tries = {
    KB.name("ins_track") .. ": track · " .. KB.name("ins_take") .. ": take · " .. KB.name("open_track") .. ": insert & open · Drag to insert",
    KB.name("ins_track") .. ": track · " .. KB.name("ins_take") .. ": take",
  }
  for _, t in ipairs(tries) do if (r.ImGui_CalcTextSize(ctx, t)) <= maxw then return t end end
  return ""
end

local function frame()
  local pc, pv = pushTheme()
  local pfu = FONT.push(FONT.ui, S.fs_ui)
  local flags = KC.WindowFlags_NoCollapse | KC.WindowFlags_NoScrollbar | KC.WindowFlags_NoScrollWithMouse
  if (not S.dock) or st.fluent then flags = flags | KC.WindowFlags_NoDocking end
  if st.fluent then flags = flags | KC.WindowFlags_NoTitleBar end
  if st.undock then r.ImGui_SetNextWindowDockID(ctx, 0, KC.Cond_Always); st.undock = false end

  if KB.hit("close_window") then Act.closeWindow() end
  if st.dirty then Q.refresh() end
  local fline = Q.facetLine()
  if st.fluent then
    r.ImGui_SetNextWindowSizeConstraints(ctx, 360, 40, 8192, 8192)
    local fh = r.ImGui_GetFrameHeight(ctx)
    local show = st.text ~= "" or st.bang ~= nil or st.rfActive or fline ~= nil
    local want
    if not show then want = 20 + fh + 2
    else want = 20 + fh + 13 + (fline and (r.ImGui_GetTextLineHeight(ctx) + 6) or 0)
      + math.max(1, math.min(#st.results, S.fluent_max)) * rowHeight() + 8 end
    want = math.floor(want)
    if st.fl_h ~= want or st.fl_w ~= S.fluent_w then r.ImGui_SetNextWindowSize(ctx, S.fluent_w, want, KC.Cond_Always); st.fl_h = want; st.fl_w = S.fluent_w end
  else
    r.ImGui_SetNextWindowSizeConstraints(ctx, 560, 320, 8192, 8192)
    if st.fl_restore then r.ImGui_SetNextWindowSize(ctx, st.nw, st.nh, KC.Cond_Always); st.fl_restore = false
    else r.ImGui_SetNextWindowSize(ctx, 900, 560, KC.Cond_FirstUseEver) end
  end
  if st.want_focus then r.ImGui_SetNextWindowFocus(ctx); st.want_focus = false end

  local vis, open = r.ImGui_Begin(ctx, "FX Browser###fxb", true, flags)
  if vis then
    st.wx, st.wy = r.ImGui_GetWindowPos(ctx)
    st.mw, st.mh = r.ImGui_GetWindowSize(ctx)
    local focused = r.ImGui_IsWindowFocused(ctx, KC.FocusedFlags_RootAndChildWindows)
    handleKeys(focused)
    if st.dirty then Q.refresh() end
    if not st.fluent then st.nw, st.nh = r.ImGui_GetWindowSize(ctx) end

    toolbar(st.fluent)
    if st.fluent and fline then
      r.ImGui_TextColored(ctx, C.accent, fline)
      tip("Side-panel filters are active. " .. KB.name("clear_filters") .. " clears them.")
    end

    if not st.fluent or st.text ~= "" or st.bang ~= nil or st.rfActive or fline ~= nil then
      local aw, ah = r.ImGui_GetContentRegionAvail(ctx)
      local footerH = st.fluent and 0 or 22
      local bodyH = ah - footerH - (st.fluent and 0 or 6)
      if st.fluent then
        resultsList(aw, bodyH, false)
      else
        local gap = S.side and 8 or 0
        local sideW = S.side and math.max(150, math.min(S.side_w or 190, aw - 300)) or 0
        local resW = aw - sideW - gap
        local ox = r.ImGui_GetCursorScreenPos(ctx)
        local function splitter(left)
          r.ImGui_InvisibleButton(ctx, "##split", gap, bodyH)
          local act = r.ImGui_IsItemActive(ctx)
          if r.ImGui_IsItemHovered(ctx) or act then
            if hasConst("MouseCursor_ResizeEW") then r.ImGui_SetMouseCursor(ctx, KC.MouseCursor_ResizeEW) end
            local sx, sy = r.ImGui_GetItemRectMin(ctx)
            r.ImGui_DrawList_AddRectFilled(r.ImGui_GetWindowDrawList(ctx), sx + gap / 2 - 1, sy + 6, sx + gap / 2 + 1, sy + bodyH - 6, C.accent, 1)
          end
          if act then
            local mx = r.ImGui_GetMousePos(ctx)
            local nw = left and (mx - ox - gap / 2) or (ox + aw - mx - gap / 2)
            S.side_w = math.max(150, math.min(aw - 300, math.floor(nw)))
          end
          if r.ImGui_IsItemDeactivated(ctx) then touchSettings() end
        end
        if S.side and S.sidepos == "left" then
          sidePanel(sideW, bodyH); r.ImGui_SameLine(ctx, 0, 0); splitter(true); r.ImGui_SameLine(ctx, 0, 0)
          resultsList(resW, bodyH, true)
        elseif S.side then
          resultsList(resW, bodyH, true); r.ImGui_SameLine(ctx, 0, 0); splitter(false); r.ImGui_SameLine(ctx, 0, 0)
          sidePanel(sideW, bodyH)
        else
          resultsList(aw, bodyH, true)
        end
        -- footer
        local n, sc = #st.results, selCount()
        local left = n .. " result" .. (n == 1 and "" or "s") .. (sc > 0 and (" · " .. sc .. " selected") or "")
        if st.rfActive then left = (S.rf_mode == "recent" and "Recent" or S.rf_mode == "frequent" and "Frequent" or "Recent & frequent") .. " · " .. n end
        r.ImGui_TextColored(ctx, C.muted, left)
        local right
        if r.time_precise() - st.status_t < 4 and st.status ~= "" then right = st.status
        else right = footerHint(aw - (r.ImGui_CalcTextSize(ctx, left)) - 30) end
        local tw = r.ImGui_CalcTextSize(ctx, right)
        r.ImGui_SameLine(ctx, aw - tw)
        r.ImGui_TextColored(ctx, (right == st.status) and C.accent or C.faint, right)
      end
    end

    -- drag & drop onto REAPER
    if st.drag then
      local list = selList()
      if r.ImGui_BeginTooltip(ctx) then
        r.ImGui_Text(ctx, "Insert " .. #list .. " FX — drop on a track or item")
        r.ImGui_EndTooltip(ctx)
      end
      if r.ImGui_IsMouseReleased(ctx, 0) then
        local wx, wy = r.ImGui_GetWindowPos(ctx)
        local ww, wh = r.ImGui_GetWindowSize(ctx)
        local x1, y1 = r.ImGui_PointConvertNative(ctx, wx, wy, true)
        local x2, y2 = r.ImGui_PointConvertNative(ctx, wx + ww, wy + wh, true)
        local mx, my = r.GetMousePosition()
        local inside = mx >= math.min(x1, x2) and mx <= math.max(x1, x2) and my >= math.min(y1, y2) and my <= math.max(y1, y2)
        if not inside then Act.dropAt(list) end
        st.drag = false
      elseif not r.ImGui_IsMouseDown(ctx, 0) then st.drag = false end
    end
    r.ImGui_End(ctx)
  end

  infoWindows()
  bulkWindow()
  settingsWindow()
  confirmWindow()
  if pfu then r.ImGui_PopFont(ctx) end
  r.ImGui_PopStyleVar(ctx, pv)
  r.ImGui_PopStyleColor(ctx, pc)
  return open
end

-------------------------------------------------------------------------------
-- Run: single instance + launch requests
-------------------------------------------------------------------------------
-- A launcher script writes a request ("bang=ch;inv=0;fluent=1;close=1") to ExtState and runs this file. If a
-- browser window is already open it picks the request up; otherwise the new instance takes over.
local function applyLaunch(spec)
  local t = {}
  for k, v in spec:gmatch("(%w+)=([^;]*)") do t[k] = v end
  if t.close ~= nil then st.autoclose = (t.close == "1") end
  if t.fluent == "1" and not st.fluent then setFluent(true)
  elseif t.fluent == "0" and st.fluent then setFluent(false) end
  if t.bang and t.bang ~= "" then
    local hit
    for _, b in ipairs(S.bangs) do if b.key == t.bang then hit = b end end
    if hit then activateBang(hit, t.inv == "1") else status("Scope '" .. t.bang .. "' not found") end
  elseif t.fluent ~= nil and st.bang then
    st.bang = nil; setText("")
  end
  st.focus = true; st.want_focus = true; st.dirty = true
end

local function loop()
  st.frame = st.frame + 1
  r.SetExtState("FXBrowser", "alive", string.format("%.3f", r.time_precise()), false)
  local req = r.GetExtState("FXBrowser", "launch")
  if req ~= "" then r.DeleteExtState("FXBrowser", "launch", false); applyLaunch(req) end
  if st.fonts_dirty then FONT.rebuild(); st.fonts_dirty = false end
  local open = frame()
  if (settings_dirty or meta_dirty or usage_dirty or seen_dirty) and r.time_precise() - dirty_since > 1.5 then flushSaves() end
  if open and not st.quit then r.defer(loop) else flushSaves(); r.DeleteExtState("FXBrowser", "alive", false) end
end

local function start()
  DB.build()
  Q.refresh()
  local req = r.GetExtState("FXBrowser", "launch")
  if req ~= "" then r.DeleteExtState("FXBrowser", "launch", false); applyLaunch(req) end
  r.atexit(function() flushSaves(); r.DeleteExtState("FXBrowser", "alive", false) end)
  r.defer(loop)
end

local function instanceAlive()
  local t = tonumber(r.GetExtState("FXBrowser", "alive"))
  return t ~= nil and (r.time_precise() - t) < 0.5
end

if instanceAlive() then
  if r.GetExtState("FXBrowser", "launch") == "" then r.SetExtState("FXBrowser", "launch", "focus=1", false) end
  local t0 = r.time_precise()
  local function wait()
    if r.GetExtState("FXBrowser", "launch") == "" then return end        -- the open window picked it up
    if r.time_precise() - t0 > 0.6 then start(); return end              -- nobody answered: take over
    r.defer(wait)
  end
  r.defer(wait)
else
  start()
end
