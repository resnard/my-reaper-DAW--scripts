-- REAPER 7 - Marker Template Manager Pro
-- Clean toolbar, tooltips, import/export, search filter, focus mode
-- Prompt Author: Res
-- Code Author: Deep Seek AI
-- Description: Manage marker templates with color, name, navigation, import/export,
--              search, and focus mode. Double‑click to edit, use [ ] to cycle markers.

local SCRIPT_NAME = "Marker Template Manager by Res"
local ctx = reaper.ImGui_CreateContext(SCRIPT_NAME)

--------------------------------------------------------
-- CONSTANTS & GLOBALS
--------------------------------------------------------

-- Convert RGB (0-255) to REAPER marker color format.
-- Format: (R + 256*G + 65536*B) | 0x1000000
local function rgb_to_marker_color(r, g, b)
  return (r + 256 * g + 65536 * b) | 0x1000000
end

-- Predefined color palette (RGB values 0-255)
local RGB_COLORS = {
  DEFAULT = {255, 0, 0},      -- Red
  GREEN   = {0, 255, 0},
  BLUE    = {0, 0, 255},
  YELLOW  = {255, 255, 0},
  CYAN    = {0, 255, 255},
  MAGENTA = {255, 0, 255},
  ORANGE  = {255, 165, 0},
  PURPLE  = {128, 0, 255}
}

-- File where templates are saved (Lua table format)
local DATA_FILE = reaper.GetResourcePath() .. "/Scripts/MarkerTemplates.dat"

-- Main data model
local Model = {
  templates = {},        -- each template: { name, r, g, b }
  focus_mode = false,    -- if true, show only the templates stored in focus_set
  locked = false,        -- if true, prevent edits (double‑click, etc.)
  dirty = false,         -- true when unsaved changes exist
  ui_scale = 1.0         -- user interface scaling factor
}

-- State variables
local selected_indices = {}      -- indices of currently selected templates
local editing_color_idx = nil    -- index of template being color‑edited (popup)
local editing_name_idx = nil     -- index of template being name‑edited (popup)
local name_edit_buffer = ""      -- temporary buffer for name editing
local confirm_delete = nil       -- stores { indices, count } for delete confirmation
local block_warning = nil        -- stores { idx, type } when edit is blocked by existing markers
local search_filter = ""         -- current search string
local focus_set = {}             -- indices to show when focus_mode is on (captured at focus-on)

--------------------------------------------------------
-- PERSISTENCE
--------------------------------------------------------

-- Save all templates and settings to DATA_FILE
local function save_model()
  local f = io.open(DATA_FILE, "w")
  if not f then return end

  -- Build a Lua table string that can be loaded later
  local str = "return {\n"
  str = str .. "  locked = " .. tostring(Model.locked) .. ",\n"
  str = str .. "  focus_mode = " .. tostring(Model.focus_mode) .. ",\n"
  str = str .. "  ui_scale = " .. string.format("%.2f", Model.ui_scale) .. ",\n"
  str = str .. "  templates = {\n"

  for _, t in ipairs(Model.templates) do
    str = str .. string.format(
      '    { name = %q, r = %d, g = %d, b = %d },\n',
      t.name or "Unnamed",
      t.r or RGB_COLORS.DEFAULT[1],
      t.g or RGB_COLORS.DEFAULT[2],
      t.b or RGB_COLORS.DEFAULT[3]
    )
  end

  str = str .. "  }\n"
  str = str .. "}"

  f:write(str)
  f:close()
  Model.dirty = false
end

-- Load templates and settings from DATA_FILE, or create defaults if missing.
local function load_model()
  local f = loadfile(DATA_FILE)
  if not f then
    -- First run: create default templates
    Model.templates = {
      { name = "Intro", r = 255, g = 0, b = 0 },
      { name = "Verse", r = 0, g = 255, b = 0 },
      { name = "Chorus", r = 0, g = 0, b = 255 },
      { name = "Bridge", r = 255, g = 255, b = 0 },
      { name = "Outro", r = 255, g = 0, b = 255 },
      { name = "Solo", r = 255, g = 165, b = 0 },
      { name = "Break", r = 128, g = 0, b = 255 }
    }
    Model.locked = false
    Model.focus_mode = false
    Model.ui_scale = 1.0
    selected_indices = { 1 }
    return
  end

  local success, data = pcall(f)
  if success and type(data) == "table" then
    Model.templates = data.templates or {}
    Model.locked = data.locked or false
    Model.focus_mode = data.focus_mode or false
    Model.ui_scale = data.ui_scale or 1.0
    selected_indices = #Model.templates > 0 and { 1 } or {}

    -- Ensure each template has r,g,b fields (convert from old format if needed)
    for _, t in ipairs(Model.templates) do
      if not t.r then
        if t.color then
          t.r = (t.color >> 16) & 0xFF
          t.g = (t.color >> 8) & 0xFF
          t.b = t.color & 0xFF
        else
          t.r, t.g, t.b = 255, 0, 0
        end
      end
    end
  else
    -- Fallback if file is corrupt
    Model.templates = { { name = "Marker", r = 255, g = 0, b = 0 } }
    selected_indices = { 1 }
  end
end

--------------------------------------------------------
-- COLOR UTILITIES
--------------------------------------------------------

-- Get REAPER‑format marker color from a template
local function get_marker_color(template)
  return rgb_to_marker_color(template.r, template.g, template.b)
end

-- Get 32‑bit ARGB color for ImGui buttons (opaque alpha)
local function get_display_color(template)
  return (template.r << 24) | (template.g << 16) | (template.b << 8) | 0xFF
end

--------------------------------------------------------
-- MARKER UTILITIES
--------------------------------------------------------

-- Return a sorted list of time positions where markers matching the template exist.
local function find_markers(template)
  local markers = {}
  local _, num_markers, num_regions = reaper.CountProjectMarkers(0)
  local total = num_markers + num_regions
  local target_color = get_marker_color(template)

  for i = 0, total - 1 do
    local retval, isrgn, pos, _, name, _, color = reaper.EnumProjectMarkers3(0, i)
    if not isrgn and name == template.name and color == target_color then
      markers[#markers + 1] = pos
    end
  end

  table.sort(markers)
  return markers
end

-- Move edit cursor to the next/previous marker of the given template.
local function cycle_marker(index, direction)
  local template = Model.templates[index]
  if not template then return end
  local markers = find_markers(template)
  if #markers == 0 then return end
  local current = reaper.GetCursorPosition()
  local idx = 1
  for i, pos in ipairs(markers) do
    if pos >= current then
      idx = i
      break
    end
  end
  if direction < 0 then
    idx = idx - 1
    if idx < 1 then idx = #markers end
  else
    if markers[idx] <= current then
      idx = idx + 1
    end
    if idx > #markers then idx = 1 end
  end
  reaper.SetEditCurPos(markers[idx], true, true)
end

-- Insert a new marker at edit/play position using the template's name and color.
local function insert_marker(index)
  local template = Model.templates[index]
  if not template then return end
  local is_playing = reaper.GetPlayState() ~= 0
  local pos = is_playing and reaper.GetPlayPosition() or reaper.GetCursorPosition()
  reaper.Undo_BeginBlock()
  local marker_color = get_marker_color(template)
  reaper.AddProjectMarker2(0, false, pos, 0, template.name, -1, marker_color)
  reaper.Undo_EndBlock("Insert marker: " .. template.name, -1)
end

-- Check whether any project marker already uses the same name and color as the template.
-- Used to guard editing of templates that are already in use.
local function template_has_markers(template)
  local _, num_markers, num_regions = reaper.CountProjectMarkers(0)
  local total = num_markers + num_regions
  local target_color = get_marker_color(template)
  for i = 0, total - 1 do
    local retval, isrgn, pos, _, name, _, color = reaper.EnumProjectMarkers3(0, i)
    if not isrgn and name == template.name and color == target_color then
      return true
    end
  end
  return false
end

--------------------------------------------------------
-- EXPORT SELECTED AS ACTION (single‑script export)
--------------------------------------------------------

-- For each selected template, create a standalone Lua script that inserts a marker.
local function export_templates(indices)
  if #indices == 0 then return end
  for _, idx in ipairs(indices) do
    local t = Model.templates[idx]
    if t then
      local safe = t.name:gsub("%W+", "_")
      local file = reaper.GetResourcePath() .. "/Scripts/Insert_" .. safe .. ".lua"
      local f = io.open(file, "w")
      if f then
        local marker_color = get_marker_color(t)
        local script = string.format([[
-- Insert %s marker
local name = %q
local marker_color = %d

local pos = reaper.GetPlayState() ~= 0 and reaper.GetPlayPosition() or reaper.GetCursorPosition()

reaper.Undo_BeginBlock()
reaper.AddProjectMarker2(0, false, pos, 0, name, -1, marker_color)
reaper.Undo_EndBlock("Insert %s marker", -1)
]], t.name, t.name, marker_color, t.name)

        f:write(script)
        f:close()
        reaper.AddRemoveReaScript(true, 0, file, true)
      end
    end
  end
end

--------------------------------------------------------
-- IMPORT / EXPORT FULL LIST
--------------------------------------------------------

-- Save all templates to a user‑chosen text file (tab‑separated: name R G B)
-- Export all templates to a user‑chosen text file
local function export_all_templates()
  -- Use JS_Dialog_BrowseForSaveFile (requires js_ReaScriptAPI)
  if not reaper.APIExists("JS_Dialog_BrowseForSaveFile") then
    reaper.ShowConsoleMsg("Error: js_ReaScriptAPI extension is required for export.\n")
    return
  end

  local retval, path = reaper.JS_Dialog_BrowseForSaveFile(
    "Save Templates",           -- title
    reaper.GetResourcePath(),   -- initial folder
    "Templates",                -- default filename (without extension)
    "Text file (*.txt)\0*.txt\0\0"  -- file filter
  )

  if not retval or path == "" then return end

  -- Ensure .txt extension
  if not path:match("%.txt$") then
    path = path .. ".txt"
  end

  local f, err = io.open(path, "w")
  if not f then
    reaper.ShowConsoleMsg("Error saving: " .. (err or "unknown error") .. "\n")
    return
  end

  for _, t in ipairs(Model.templates) do
    f:write(string.format("%s\t%d\t%d\t%d\n", t.name, t.r, t.g, t.b))
  end
  f:close()
  reaper.ShowConsoleMsg("Templates exported to " .. path .. "\n")
end

-- Load templates from a user‑chosen text file and append them to the current list.
local function import_templates()
  -- Correct signature: GetUserFileNameForRead(title, defaultName, extensionList)
  local retval, path = reaper.GetUserFileNameForRead(
    "Import Templates",           -- title
    "",                           -- default filename (none)
    ".txt" -- file filter (double null terminated)
  )
  if not retval or path == "" then return end

  local f, err = io.open(path, "r")
  if not f then
    reaper.ShowConsoleMsg("Error reading: " .. (err or "unknown error") .. "\n")
    return
  end
  local count = 0
  for line in f:lines() do
    local name, r, g, b = line:match("([^\t]+)\t(%d+)\t(%d+)\t(%d+)")
    if name and r and g and b then
      table.insert(Model.templates, {
        name = name,
        r = tonumber(r),
        g = tonumber(g),
        b = tonumber(b)
      })
      count = count + 1
    end
  end
  f:close()
  if count > 0 then
    Model.dirty = true
    reaper.ShowConsoleMsg("Imported " .. count .. " templates.\n")
  else
    reaper.ShowConsoleMsg("No valid templates found in file.\n")
  end
end

--------------------------------------------------------
-- GUI – Toolbar
--------------------------------------------------------
local function draw_toolbar()
  -- Add button – disabled during focus mode to avoid index shifts.
  local add_enabled = not Model.focus_mode
  if not add_enabled then reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_Alpha(), 0.5) end
  if reaper.ImGui_Button(ctx, "Add##add") and add_enabled then
    local def = RGB_COLORS.DEFAULT
    table.insert(Model.templates, {
      name = "New Marker " .. (#Model.templates + 1),
      r = def[1], g = def[2], b = def[3]
    })
    selected_indices = { #Model.templates }
    Model.dirty = true
  end
  if not add_enabled then reaper.ImGui_PopStyleVar(ctx) end
  reaper.ImGui_SetItemTooltip(ctx, add_enabled and "Add new template" or "Disabled in focus mode")

  reaper.ImGui_SameLine(ctx)

  -- Insert button – inserts markers for selected templates.
  if #selected_indices > 0 then
    if reaper.ImGui_Button(ctx, "Insert (" .. #selected_indices .. ")##insert") then
      for _, idx in ipairs(selected_indices) do
        insert_marker(idx)
      end
    end
    reaper.ImGui_SetItemTooltip(ctx, "Insert marker(s) at cursor")
  else
    reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_Alpha(), 0.5)
    reaper.ImGui_Button(ctx, "Insert##insert_disabled")
    reaper.ImGui_PopStyleVar(ctx)
    reaper.ImGui_SetItemTooltip(ctx, "Select templates first")
  end

  reaper.ImGui_SameLine(ctx)

  -- Delete marker at cursor – native REAPER action.
  if reaper.ImGui_Button(ctx, "Del Marker##del_marker") then
    reaper.Main_OnCommand(40613, 0)
  end
  reaper.ImGui_SetItemTooltip(ctx, "Delete marker at edit cursor")

  reaper.ImGui_SameLine(ctx)

  -- Tools dropdown – export/import and UI scale.
  if reaper.ImGui_Button(ctx, "Tools##tools") then
    reaper.ImGui_OpenPopup(ctx, "ToolsMenu")
  end
  reaper.ImGui_SetItemTooltip(ctx, "Import/export, UI scale")

  if reaper.ImGui_BeginPopup(ctx, "ToolsMenu") then
    if reaper.ImGui_MenuItem(ctx, "Export Selected as Action") then
      export_templates(selected_indices)
    end
    if reaper.ImGui_MenuItem(ctx, "Export All Templates") then
      export_all_templates()
    end
    if reaper.ImGui_MenuItem(ctx, "Import Templates") then
      import_templates()
    end
    reaper.ImGui_Separator(ctx)
    reaper.ImGui_EndPopup(ctx)
  end

  reaper.ImGui_SameLine(ctx)
  reaper.ImGui_Text(ctx, "   ")

  reaper.ImGui_SameLine(ctx)

  -- Focus mode toggle – when turning on, capture current selection into focus_set.
  if reaper.ImGui_Button(ctx, Model.focus_mode and "Focus On##focus" or "Focus##focus") then
    if not Model.focus_mode then
      focus_set = {}
      for _, idx in ipairs(selected_indices) do
        table.insert(focus_set, idx)
      end
    else
      focus_set = {}
    end
    Model.focus_mode = not Model.focus_mode
    Model.dirty = true
  end
  reaper.ImGui_SetItemTooltip(ctx, Model.focus_mode and "Focus mode active (freeze set)" or "Show only selected templates")

  reaper.ImGui_SameLine(ctx)

  -- Lock toggle – prevents editing via double‑click, etc.
  if reaper.ImGui_Button(ctx, Model.locked and "Locked##lock" or "Unlocked##lock") then
    Model.locked = not Model.locked
    Model.dirty = true
  end
  reaper.ImGui_SetItemTooltip(ctx, "Lock/unlock editing")

  reaper.ImGui_Separator(ctx)
end

--------------------------------------------------------
-- GUI – Main List (Table)
--------------------------------------------------------
local function draw_list()
  -- Search bar – always visible, but its effect is disabled during focus mode.
  reaper.ImGui_AlignTextToFramePadding(ctx)
  reaper.ImGui_Text(ctx, "Search:")
  reaper.ImGui_SameLine(ctx)
  reaper.ImGui_PushItemWidth(ctx, 200)
  local filter_changed, new_filter = reaper.ImGui_InputText(ctx, "##search", search_filter)
  if filter_changed then
    search_filter = new_filter
  end
  reaper.ImGui_PopItemWidth(ctx)

  -- Hint when focus mode is active.
  if Model.focus_mode then
    reaper.ImGui_SameLine(ctx)
    reaper.ImGui_TextDisabled(ctx, "(disabled in focus mode)")
  end

  reaper.ImGui_Separator(ctx)

  -- Build the list of templates to display based on focus mode, search, and selection.
  local visible_items, visible_indices = {}, {}
  for i, t in ipairs(Model.templates) do
    if Model.focus_mode then
      -- Focus mode: show only the captured focus set.
      if table.find(focus_set, i) then
        table.insert(visible_items, t)
        table.insert(visible_indices, i)
      end
    else
      -- Normal mode: show items that match search OR are selected.
      local is_selected = table.find(selected_indices, i)
      local matches_search = search_filter == "" or t.name:lower():find(search_filter:lower())
      if matches_search or is_selected then
        table.insert(visible_items, t)
        table.insert(visible_indices, i)
      end
    end
  end

  -- Calculate table height dynamically so status bar always fits.
  local window_height = reaper.ImGui_GetWindowHeight(ctx)
  local current_y = reaper.ImGui_GetCursorPosY(ctx)
  local status_height = 20   -- accounts for search bar and separator
  local table_height = window_height - current_y - status_height - 10
  if table_height < 100 then table_height = 100 end

  -- Scrollable child region for the table.
  if reaper.ImGui_BeginChild(ctx, "TableScroll", 0, table_height, 0) then
    if reaper.ImGui_BeginTable(ctx, "TemplatesTable", 3,
         reaper.ImGui_TableFlags_Borders() |
         reaper.ImGui_TableFlags_RowBg() |
         reaper.ImGui_TableFlags_ScrollY() |
         reaper.ImGui_TableFlags_SizingFixedFit()) then

      reaper.ImGui_TableSetupColumn(ctx, "Color", reaper.ImGui_TableColumnFlags_WidthFixed(), 40)
      reaper.ImGui_TableSetupColumn(ctx, "Name", reaper.ImGui_TableColumnFlags_WidthStretch())
      reaper.ImGui_TableSetupColumn(ctx, "Nav", reaper.ImGui_TableColumnFlags_WidthFixed(), 120)
      reaper.ImGui_TableHeadersRow(ctx)

      for row, template in ipairs(visible_items) do
        local real_idx = visible_indices[row]
        local is_selected = table.find(selected_indices, real_idx)

        reaper.ImGui_TableNextRow(ctx)

        -- Column 0: Color swatch (non‑selectable)
        reaper.ImGui_TableSetColumnIndex(ctx, 0)
        local display_color = get_display_color(template)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(), display_color)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), display_color)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(), display_color)
        reaper.ImGui_Button(ctx, "  ##color" .. real_idx)
        reaper.ImGui_PopStyleColor(ctx, 3)

        -- Double‑click to edit color (with guard)
        if not Model.locked and reaper.ImGui_IsItemHovered(ctx) and reaper.ImGui_IsMouseDoubleClicked(ctx, 0) then
          if template_has_markers(template) then
            block_warning = { idx = real_idx, type = "color" }
          else
            editing_color_idx = real_idx
          end
        end

        -- Column 1: Name selectable (handles selection)
        reaper.ImGui_TableSetColumnIndex(ctx, 1)
        local clicked = reaper.ImGui_Selectable(ctx, template.name, is_selected, 0)

        if clicked then
          local ctrl = reaper.ImGui_GetKeyMods(ctx) & reaper.ImGui_Mod_Ctrl() ~= 0
          local shift = reaper.ImGui_GetKeyMods(ctx) & reaper.ImGui_Mod_Shift() ~= 0

          if shift and #selected_indices > 0 then
            -- Range select
            local new_sel = {}
            local last = selected_indices[#selected_indices]
            for i = math.min(last, real_idx), math.max(last, real_idx) do
              table.insert(new_sel, i)
            end
            selected_indices = new_sel
          elseif ctrl then
            -- Toggle selection
            if is_selected then
              for i = #selected_indices, 1, -1 do
                if selected_indices[i] == real_idx then
                  table.remove(selected_indices, i)
                end
              end
            else
              table.insert(selected_indices, real_idx)
              table.sort(selected_indices)
            end
          else
            -- Single selection
            selected_indices = { real_idx }
          end
          Model.dirty = true
        end

        -- Double‑click to edit name (with guard)
        if not Model.locked and reaper.ImGui_IsItemHovered(ctx) and reaper.ImGui_IsMouseDoubleClicked(ctx, 0) then
          if template_has_markers(template) then
            block_warning = { idx = real_idx, type = "name" }
          else
            editing_name_idx = real_idx
            name_edit_buffer = template.name
          end
        end

        -- Column 2: Navigation – always show marker count, buttons only if selected.
        reaper.ImGui_TableSetColumnIndex(ctx, 2)
        local markers = find_markers(template)
        local count = #markers
        if count > 0 then
          if reaper.ImGui_Button(ctx, "◀##prev" .. real_idx) then
            cycle_marker(real_idx, -1)
          end
          reaper.ImGui_SameLine(ctx)
          reaper.ImGui_Text(ctx, "[" .. count .. "]")
          reaper.ImGui_SameLine(ctx)
          if reaper.ImGui_Button(ctx, "▶##next" .. real_idx) then
            cycle_marker(real_idx, 1)
          end
        else
          reaper.ImGui_Text(ctx, "[" .. count .. "]")
        end
      end
      reaper.ImGui_EndTable(ctx)
    end
    reaper.ImGui_EndChild(ctx)
  end

  -- Confirmation popup for deletion
  if confirm_delete then
    reaper.ImGui_OpenPopup(ctx, "Confirm Delete")
    if reaper.ImGui_BeginPopupModal(ctx, "Confirm Delete", nil, reaper.ImGui_WindowFlags_AlwaysAutoResize()) then
      local msg = "Delete " .. confirm_delete.count .. " selected template"
      if confirm_delete.count > 1 then msg = msg .. "s?" else msg = msg .. "?" end
      reaper.ImGui_Text(ctx, msg)

      if reaper.ImGui_Button(ctx, "Delete") then
        -- Perform deletion (iterate backwards because indices shift)
        for i = #confirm_delete.indices, 1, -1 do
          table.remove(Model.templates, confirm_delete.indices[i])
        end
        selected_indices = {}
        
        Model.dirty = true
        confirm_delete = nil
        reaper.ImGui_CloseCurrentPopup(ctx)
      end
      reaper.ImGui_SameLine(ctx)
      if reaper.ImGui_Button(ctx, "Cancel") then
        confirm_delete = nil
        reaper.ImGui_CloseCurrentPopup(ctx)
      end
      reaper.ImGui_EndPopup(ctx)
    else
      confirm_delete = nil
    end
  end

  -- Color picker popup (modal)
  if editing_color_idx then
    local t = Model.templates[editing_color_idx]
    if t then
      reaper.ImGui_OpenPopup(ctx, "Edit Color")
      if reaper.ImGui_BeginPopupModal(ctx, "Edit Color", nil, reaper.ImGui_WindowFlags_AlwaysAutoResize()) then
        local packed = (t.r << 16) | (t.g << 8) | t.b
        local flags = reaper.ImGui_ColorEditFlags_NoAlpha()
        local changed, new_packed = reaper.ImGui_ColorPicker4(ctx, "##colorpicker", packed, flags)

        if changed then
          t.r = (new_packed >> 16) & 0xFF
          t.g = (new_packed >> 8) & 0xFF
          t.b = new_packed & 0xFF
          Model.dirty = true
        end

        if reaper.ImGui_Button(ctx, "Close") then
          editing_color_idx = nil
          reaper.ImGui_CloseCurrentPopup(ctx)
        end
        reaper.ImGui_EndPopup(ctx)
      else
        editing_color_idx = nil
      end
    else
      editing_color_idx = nil
    end
  end

  -- Name edit popup (modal)
  if editing_name_idx then
    local t = Model.templates[editing_name_idx]
    if t then
      reaper.ImGui_OpenPopup(ctx, "Edit Name")
      if reaper.ImGui_BeginPopupModal(ctx, "Edit Name", nil, reaper.ImGui_WindowFlags_AlwaysAutoResize()) then
        reaper.ImGui_Text(ctx, "Enter new name:")
        local changed, new_name = reaper.ImGui_InputText(ctx, "##name_edit", name_edit_buffer, 256)

        if changed then
          name_edit_buffer = new_name
        end

        if reaper.ImGui_Button(ctx, "OK") then
          t.name = name_edit_buffer
          Model.dirty = true
          editing_name_idx = nil
          reaper.ImGui_CloseCurrentPopup(ctx)
        end
        reaper.ImGui_SameLine(ctx)
        if reaper.ImGui_Button(ctx, "Cancel") then
          editing_name_idx = nil
          reaper.ImGui_CloseCurrentPopup(ctx)
        end

        reaper.ImGui_EndPopup(ctx)
      else
        editing_name_idx = nil
      end
    else
      editing_name_idx = nil
    end
  end

  -- Block warning popup (shown when trying to edit a template that already has markers)
  if block_warning then
    reaper.ImGui_OpenPopup(ctx, "Edit Blocked")
    if reaper.ImGui_BeginPopupModal(ctx, "Edit Blocked", nil, reaper.ImGui_WindowFlags_AlwaysAutoResize()) then
      reaper.ImGui_Text(ctx, "Cannot edit template because it is already used by existing marker(s).")
      if reaper.ImGui_Button(ctx, "OK") then
        block_warning = nil
        reaper.ImGui_CloseCurrentPopup(ctx)
      end
      reaper.ImGui_EndPopup(ctx)
    else
      block_warning = nil
    end
  end
end

--------------------------------------------------------
-- GUI – Status Bar
--------------------------------------------------------
local function draw_status()
  reaper.ImGui_Separator(ctx)

  local _, num_markers, _ = reaper.CountProjectMarkers(0)
  reaper.ImGui_Text(ctx, string.format("%d templates • %d markers", #Model.templates, num_markers))

  if Model.focus_mode then
    -- Show size of frozen focus set (not current selection)
    reaper.ImGui_SameLine(ctx, 200)
    reaper.ImGui_Text(ctx, "Focus set: " .. #focus_set .. " items")
  elseif #selected_indices > 0 then
    reaper.ImGui_SameLine(ctx, 200)
    reaper.ImGui_Text(ctx, #selected_indices .. " selected")
  end

  reaper.ImGui_SameLine(ctx, 300)
  reaper.ImGui_TextDisabled(ctx, "[ ] to cycle")
end

--------------------------------------------------------
-- KEYBOARD SHORTCUTS
--------------------------------------------------------
local function handle_shortcuts()
  if reaper.ImGui_IsAnyItemActive(ctx) then return end

  -- [ and ] cycle through markers of the first selected template
  if #selected_indices > 0 then
    if reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_LeftBracket(), false) then
      cycle_marker(selected_indices[1], -1)
    end
    if reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_RightBracket(), false) then
      cycle_marker(selected_indices[1], 1)
    end
  end

  -- Enter inserts markers for all selected templates
  if #selected_indices > 0 and not Model.locked and
     reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Enter(), false) then
    for _, idx in ipairs(selected_indices) do
      insert_marker(idx)
    end
  end

  local ctrl = reaper.ImGui_GetKeyMods(ctx) & reaper.ImGui_Mod_Ctrl() ~= 0

  -- Ctrl+N: add new template (disabled in focus mode)
  if ctrl and reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_N(), false) and not Model.locked and not Model.focus_mode then
    local def = RGB_COLORS.DEFAULT
    table.insert(Model.templates, {
      name = "New Marker " .. (#Model.templates + 1),
      r = def[1], g = def[2], b = def[3]
    })
    selected_indices = { #Model.templates }
    Model.dirty = true
  end

  -- Ctrl+E: export selected as action
  if ctrl and reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_E(), false) and #selected_indices > 0 then
    export_templates(selected_indices)
  end

  -- Ctrl+A: select all
  if ctrl and reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_A(), false) then
    selected_indices = {}
    for i = 1, #Model.templates do
      table.insert(selected_indices, i)
    end
    Model.dirty = true
  end

  -- Delete key: ask for confirmation (disabled in focus mode)
  if not Model.locked and not Model.focus_mode and #selected_indices > 0 and
     reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Delete(), false) then
    local indices = {}
    for _, idx in ipairs(selected_indices) do
      table.insert(indices, idx)
    end
    confirm_delete = {
      indices = indices,
      count = #indices
    }
  end
end

-- Utility: find value in a table (linear search)
function table.find(tbl, value)
  for i, v in ipairs(tbl) do
    if v == value then return i end
  end
  return nil
end

--------------------------------------------------------
-- MAIN LOOP
--------------------------------------------------------
local function loop()
  local visible, open = reaper.ImGui_Begin(ctx, SCRIPT_NAME .. "###Main", true,
    reaper.ImGui_WindowFlags_NoCollapse())

  if visible then
  
    handle_shortcuts()
    draw_toolbar()
    draw_list()
    draw_status()
  end

  reaper.ImGui_End(ctx)

  if Model.dirty then save_model() end

  if open then reaper.defer(loop) end
end

--------------------------------------------------------
-- START
--------------------------------------------------------
load_model()
local flt_min, flt_max = reaper.ImGui_NumericLimits_Float()
reaper.ImGui_SetNextWindowSize(ctx, 300, 700, reaper.ImGui_Cond_FirstUseEver())
reaper.ImGui_SetNextWindowPos(ctx, 100, 100, reaper.ImGui_Cond_FirstUseEver())
reaper.ImGui_SetNextWindowSizeConstraints(ctx, 400, 250, flt_max, flt_max)
reaper.defer(loop)
