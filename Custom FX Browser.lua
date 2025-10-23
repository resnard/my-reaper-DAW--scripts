-- @description QuickFX Browser — Rewritten Portable Prototype (v1.65)
-- @version 1.65
-- @author Resnard Lapiz (With assistance from open AI's Chat GPT)
-- @about Portable FX browser: universal wildcard search, custom plugin folder creation, folder tree view, folder-local search,
-- context menu (add to track/new track/add to folder/edit note), bottom notes, load FXChains, sensible keyboard shortcuts.
-- Requirements: REAPER + ReaImGui (cfillion)
-- For the best compatibility please install SWS Extenstion or Reapack
-- Feel free to edit this script however you like, no need to acknowledge me nor put credits. Enjoy this script and happy music production!

local r = reaper

-- sanity check ReaImGui binding
if not r.ImGui_CreateContext then
    r.ShowMessageBox("ReaImGui binding not found. Install cfillion's ReaImGui.", "Missing dependency", 0)
    return
end

local ctx = r.ImGui_CreateContext("QuickFX Browser")
if not ctx then
    r.ShowMessageBox("Failed to create ImGui context.", "Error", 0)
    return
end

-- paths
local script_dir = debug.getinfo(1, "S").source:match("^@?(.*[\\/])") or (r.GetResourcePath() .. "/Scripts/")
local sep = package.config:sub(1,1)
local data_dir = script_dir .. "QuickFX_Browser_Data"
if r.RecursiveCreateDirectory then r.RecursiveCreateDirectory(data_dir, 0) end
local FOLDERS_FILE = data_dir .. sep .. "folders.lua"
local NOTES_FILE   = data_dir .. sep .. "notes.lua"
local note_modal_open = false
local note_modal_just_opened = false
local editing_fx_list = {}
local FXCHAINS_DIR = r.GetResourcePath() .. sep .. "FXChains" .. sep

-- safe serializer / loader
local function serialize(val, depth)
    depth = depth or 0
    local pad = string.rep(" ", depth)
    if type(val) == "table" then
        local parts = {}
        for k,v in pairs(val) do
            local key
            if type(k) == "number" then key = "["..k.."]"
            elseif tostring(k):match("^[_%a][%w_]*$") then key = k
            else key = "['"..tostring(k):gsub("'", "\\'").."']" end
            parts[#parts+1] = pad .. "  " .. key .. " = " .. serialize(v, depth+2)
        end
        return "{\n" .. table.concat(parts, ",\n") .. "\n" .. pad .. "}"
    elseif type(val) == "string" then
        return string.format("%q", val)
    elseif type(val) == "number" or type(val) == "boolean" then
        return tostring(val)
    else
        return "nil"
    end
end

local function table_to_string(t) return serialize(t) end
local function string_to_table(s)
    if not s or s == "" then return nil end
    local f, err = load("return " .. s)
    if not f then return nil end
    local ok, res = pcall(f)
    if not ok then return nil end
    return res
end

local function write_table(path, tbl)
    local f, err = io.open(path, "w")
    if not f then return false, err end
    f:write(table_to_string(tbl))
    f:close()
    return true
end

local function read_table(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local s = f:read("*a")
    f:close()
    return string_to_table(s)
end

-- data model
local DATA = {
    folders = {},       -- same
    notes = {},         -- keyed by fx.display for now
    selected_fx = {},   -- list of display names currently selected
    fx_index = {}       -- NEW: maps display name → true, or holds metadata if needed
}

local p = read_table(FOLDERS_FILE)
if p and p.folders then DATA.folders = p.folders end
local pn = read_table(NOTES_FILE)
if pn and pn.notes then DATA.notes = pn.notes end

local function persist_all()
    write_table(FOLDERS_FILE, { folders = DATA.folders })
    write_table(NOTES_FILE,   { notes = DATA.notes })
end

-- Master FX list builder (EnumInstalledFX is documented in ReaScript)
local function build_master_fx_list()
    local out = {}
    for i = 0, math.huge do
        local ok, name, ident = r.EnumInstalledFX(i)
        if not ok then break end
        local fx = {
            display = name,       -- for UI display
            name = name,          -- actual plugin name (for TrackFX_AddByName)
            ident = ident,        -- internal REAPER ID
            path = nil,           -- not needed for normal FX
            is_fxchain = false,
        }
        out[#out + 1] = fx
        DATA.fx_index[fx.display] = fx -- register for instant lookup
    end
    return out
end


-- FX Chain list builder (.RfxChain files)
local function build_fxchain_list()
    local out = {}
    local i = 0
    while true do
        local file = r.EnumerateFiles(FXCHAINS_DIR, i)
        if not file then break end
        if file:lower():match("%.rfxchain$") then
            local base = file:gsub("%.RfxChain$", "")
            local fx = {
                display = "CHAIN: " .. base,  -- for UI
                name = base,                  -- stripped name
                rawname = file,               -- filename
                path = FXCHAINS_DIR .. file,  -- absolute file path
                is_fxchain = true,
            }
            out[#out + 1] = fx
            DATA.fx_index[fx.display] = fx -- register in global index
        end
        i = i + 1
    end
    return out
end

local function build_fx_index(all_fx, all_fxchains)
    local index = {}
    for _, fx in ipairs(all_fx or {}) do
        index[fx.display] = fx
    end
    for _, chain in ipairs(all_fxchains or {}) do
        index[chain.display] = chain
    end
    return index
end


-- Build both lists and register them globally

ALL_FX = build_master_fx_list()
ALL_FXCHAINS = build_fxchain_list()
DATA.fx_index = build_fx_index(ALL_FX, ALL_FXCHAINS)

-- initialize id counter (runtime only)
DATA._next_folder_id = DATA._next_folder_id or 1

-- ensure every node in a tree has a unique runtime id (_id)
local function ensure_folder_ids(tbl)
    for _, v in ipairs(tbl) do
        if not v._id then
            v._id = DATA._next_folder_id
            DATA._next_folder_id = DATA._next_folder_id + 1
        end
        v.sub = v.sub or {}
        ensure_folder_ids(v.sub)
    end
end

-- call once after loading data to guarantee ids
ensure_folder_ids(DATA.folders)





-- helper: priority by plugin type (patterns used in Sexan parser)
local function fx_priority(name)
    if name:match("^VST3:") then return 1 end
    if name:match("^VSTi:") or name:match("^VSTi ") then return 2 end
    if name:match("^VST:") then return 3 end
    if name:match("^JS:") then return 4 end
    if name:match("^CLAP") then return 5 end
    if name:match("^AU") then return 6 end
    if name:match("^LV2") then return 7 end
    return 8
end

local function wildcard_to_pattern(s)
    if not s or s == "" then return nil end
    -- escape pattern chars, convert '*' -> '.*'
    local esc = s:gsub("([%%%^%$%(%)%.%[%]%+%-%?])", "%%%1")
    esc = esc:gsub("%*", ".*")
    return esc:lower()
end

-- folder helpers
local function find_folder(path_table)
    if not path_table then return nil end
    local cur = DATA.folders
    local node = nil
    for i = 1, #path_table do
        local name = path_table[i]
        node = nil
        for _,f in ipairs(cur) do if f.name == name then node = f; break end end
        if not node then return nil end
        cur = node.sub or {}
    end
    return node
end

-- find parent_table, index, node by path-of-names (keeps backward compat when needed)
local function find_parent_and_index(root_tbl, path)
    if not path or #path == 0 then return nil end
    local cur_tbl = root_tbl
    for depth = 1, #path do
        local name = path[depth]
        local found_idx, found_node = nil, nil
        for i = 1, #cur_tbl do
            if cur_tbl[i].name == name then found_idx = i; found_node = cur_tbl[i]; break end
        end
        if not found_node then return nil end
        if depth == #path then
            return cur_tbl, found_idx, found_node
        end
        cur_tbl = found_node.sub or {}
    end
    return nil
end

-- find by runtime id (safer); returns parent_table, index, node (or nil)
local function find_parent_and_index_by_id(root_tbl, id)
    if not id then return nil end
    local function recurse(tbl)
        for i = 1, #tbl do
            if tbl[i]._id == id then return tbl, i, tbl[i] end
            if tbl[i].sub and #tbl[i].sub > 0 then
                local parent, idx, node = recurse(tbl[i].sub)
                if parent then return parent, idx, node end
            end
        end
        return nil
    end
    return recurse(root_tbl)
end

-- ---------- updated add_folder (ensures ids) ----------
local function add_folder(name, parent_path)
    if not name or name == "" then return end
    local newnode = { name = name, sub = {}, fx = {}, _id = DATA._next_folder_id }
    DATA._next_folder_id = DATA._next_folder_id + 1
    if not parent_path then
        DATA.folders[#DATA.folders + 1] = newnode
    else
        local parent = find_folder(parent_path)
        if parent then parent.sub = parent.sub or {}; parent.sub[#parent.sub + 1] = newnode end
    end
    persist_all()
end

local function add_fx_to_folder(fxname, folder_path)
    local folder = find_folder(folder_path)
    if not folder then return false end
    folder.fx = folder.fx or {}
    for _,v in ipairs(folder.fx) do if v == fxname then return true end end
    folder.fx[#folder.fx+1] = fxname
    persist_all()
    return true
end

-- UI state
local universal_search = ""
local local_search = ""
local selected_folder_path = nil -- array of names
local selected_plugin = nil
local note_modal_open = false
local note_buffer = ""
local filtered_global = {}
local last_clicked_index = nil
local CURRENT_DRAG_PAYLOAD = nil


-- compute filtered global list
local function compute_global()
    filtered_global = {}
    local pat = wildcard_to_pattern(universal_search)

    -- Unified filtering (works for both FX and FXChains)
    for _, fx in ipairs(ALL_FXCHAINS) do
        local low = fx.display:lower()
        if not pat or low:match(pat) then
            filtered_global[#filtered_global+1] = fx
        end
    end

    for _, fx in ipairs(ALL_FX) do
        local low = fx.display:lower()
        if not pat or low:match(pat) then
            filtered_global[#filtered_global+1] = fx
        end
    end

    -- Sort: FXChains first, then by type priority and name
    table.sort(filtered_global, function(a, b)
        if a.is_fxchain ~= b.is_fxchain then
            return a.is_fxchain  -- FXChains first
        end
        local pa, pb = fx_priority(a.display), fx_priority(b.display)
        if pa ~= pb then return pa < pb end
        if #a.display ~= #b.display then return #a.display < #b.display end
        return a.display:lower() < b.display:lower()
    end)
end


local function folder_list_items()
    if not selected_folder_path then return {} end
    local folder = find_folder(selected_folder_path)
    if not folder then return {} end
    local out = {}
    for _, display in ipairs(folder.fx or {}) do
        -- try to resolve to a full object (FX or chain); if not resolvable, store as plain display
        local resolved = nil
        for _, v in ipairs(ALL_FXCHAINS) do if v.display == display then resolved = v; break end end
        if not resolved then
            for _, v in ipairs(ALL_FX) do if v.display == display or v.name == display then resolved = v; break end end
        end
        if resolved then
            out[#out+1] = resolved
        else
            out[#out+1] = { display = display, name = display, is_fxchain = false }
        end
    end
    -- apply local search filter
    if not local_search or local_search == "" then return out end
    local pat = wildcard_to_pattern(local_search)
    local res = {}
    for _, it in ipairs(out) do
        if (it.display or it.name or ""):lower():match(pat) then res[#res+1] = it end
    end
    return res
end


-- add plugin helpers
local function add_to_selected_track(name)
    local tr = r.GetSelectedTrack(0,0)
    if not tr then r.Main_OnCommand(40001,0); tr = r.GetSelectedTrack(0,0) end
    if tr then r.TrackFX_AddByName(tr, name, false, -1000) end
end

local function add_to_new_track(name)
    r.Main_OnCommand(40001,0)
    local tr = r.GetSelectedTrack(0,0)
    if tr then r.TrackFX_AddByName(tr, name, false, -1000) end
end

-- small wrappers for ImGui InputText style usage
local function im_input_text(id, buf)
    if not r.ImGui_InputText then return buf end
    local changed, newbuf = r.ImGui_InputText(ctx, id, buf)
    if changed then return newbuf end
    return buf
end

local function im_input_text_multiline(id, buf, height)
    if not r.ImGui_InputTextMultiline then return buf end
    local changed, newbuf = r.ImGui_InputTextMultiline(ctx, id, buf, -1, height)
    if changed then return newbuf end
    return buf
end

local function draw_plugin_context(item)
    if not item then return end

    local fx_display = item.display or item.name or tostring(item)

    -- small helper that reads the resolved object quickly
    local function get_resolved(display)
        if not display or not DATA.fx_index then return nil end
        return DATA.fx_index[display]
    end

    if r.ImGui_BeginPopupContextItem(ctx) then
        -- Determine current FX selection (defaults to clicked item)
        local sel_fx = (#DATA.selected_fx > 0) and DATA.selected_fx or { fx_display }

        -- Helper: add single display entry to a given track
        local function add_fx_to_track(tr, fx_disp)
            if not tr or not fx_disp then return end
            local resolved = get_resolved(fx_disp)
            if not resolved then
                r.ShowConsoleMsg("[QuickFX] Unknown FX when adding: " .. tostring(fx_disp) .. "\n")
                return
            end
            if resolved.is_fxchain then
                -- prefer rawname (REAPER knows FXChains folder) but check path if needed
                if resolved.rawname then
                    r.TrackFX_AddByName(tr, resolved.rawname, false, 1)
                else
                    r.TrackFX_AddByName(tr, resolved.path, false, 1)
                end
            else
                r.TrackFX_AddByName(tr, resolved.name or fx_disp, false, -1000)
            end
        end

        -- Add to selected track
        if r.ImGui_Selectable(ctx, "Add to selected track") then
            local tr = r.GetSelectedTrack(0, 0)
            if not tr then
                r.ShowMessageBox("No track selected.", "Info", 0)
            else
                for _, fx_disp in ipairs(sel_fx) do
                    add_fx_to_track(tr, fx_disp)
                end
            end
        end

        -- Add to new track (single selection)
        if #sel_fx == 1 then
            if r.ImGui_Selectable(ctx, "Add to new track") then
                r.Main_OnCommand(40001, 0) -- insert new track
                local tr = r.GetSelectedTrack(0, 0)
                add_fx_to_track(tr, sel_fx[1])
            end

        -- Add multiple: one new track / one per new track
        elseif #sel_fx > 1 then
            if r.ImGui_Selectable(ctx, "Add all to a single new track") then
                r.Main_OnCommand(40001, 0)
                local tr = r.GetSelectedTrack(0, 0)
                for _, fx_disp in ipairs(sel_fx) do add_fx_to_track(tr, fx_disp) end
            end

            if r.ImGui_Selectable(ctx, "Add each to its own new track") then
                for _, fx_disp in ipairs(sel_fx) do
                    r.Main_OnCommand(40001, 0)
                    local tr = r.GetSelectedTrack(0, 0)
                    add_fx_to_track(tr, fx_disp)
                end
            end
        end

        -- Add to selected folder
        if r.ImGui_Selectable(ctx, "Add to selected folder") then
            if not selected_folder_path then
                r.ShowMessageBox("Select a folder in the left panel first.", "Info", 0)
            else
                for _, fx_disp in ipairs(sel_fx) do add_fx_to_folder(fx_disp, selected_folder_path) end
            end
        end

        -- Remove from folder if present
        local folder = selected_folder_path and find_folder(selected_folder_path)
        if folder and folder.fx then
            local any_in_folder = false
            for _, fx_disp in ipairs(sel_fx) do
                for _, f in ipairs(folder.fx) do if f == fx_disp then any_in_folder = true; break end end
                if any_in_folder then break end
            end
            if any_in_folder and r.ImGui_Selectable(ctx, "Remove from selected folder") then
                for _, fx_disp in ipairs(sel_fx) do
                    for i = #folder.fx, 1, -1 do if folder.fx[i] == fx_disp then table.remove(folder.fx, i) end end
                end
                persist_all()
            end
        end

        -- Add / Edit note
        if #sel_fx == 1 then
            if r.ImGui_Selectable(ctx, "Add / Edit note") then
                editing_fx_list = sel_fx
                note_buffer = DATA.notes[fx_display] or ""
                note_modal_open = true
                note_modal_just_opened = true
            end
        end

        r.ImGui_EndPopup(ctx)
    end
end





-- ---------- folder ID helpers & robust drag/drop helpers ----------

-- remove node by id and return parent, index, node (or nil)
local function remove_node_by_id(root_tbl, id)
    local p, idx, node = find_parent_and_index_by_id(root_tbl, id)
    if not (p and idx and node) then return nil end
    table.remove(p, idx)
    return p, idx, node
end

-- check whether candidate is inside subtree of node (by id)
local function is_descendant(node, candidate_id)
    if not node or not node.sub then return false end
    local function recurse(tbl)
        for i = 1, #tbl do
            if tbl[i]._id == candidate_id then return true end
            if tbl[i].sub and recurse(tbl[i].sub) then return true end
        end
        return false
    end
    return recurse(node.sub)
end

-- insert node into parent_table at index (nil/invalid → append)
-- insert node into parent_table at index (nil/invalid → append)
local function insert_node_into(parent_table, index, node)
    if not parent_table then
        -- fallback to root table
        parent_table = DATA.folders
    end

    -- ensure parent_table exists (important for subfolders)
    if type(parent_table) ~= "table" then
        parent_table = {}
    end

    if not index or index < 1 or index > #parent_table + 1 then
        parent_table[#parent_table + 1] = node
    else
        table.insert(parent_table, index, node)
    end
end


-- ---------- improved draw_folders() ----------
local function draw_folders()
    -- local indent_size = 12

    -- recursive renderer: list = table being iterated, path = array of names for current node, parent_table = the table that contains 'list'
    local function draw_nodes(list, path, parent_table)
        parent_table = parent_table or DATA.folders

        for idx, node in ipairs(list) do
            -- ensure runtime id exists (safe guard for nodes created elsewhere)
            if not node._id then node._id = DATA._next_folder_id; DATA._next_folder_id = DATA._next_folder_id + 1 end

            local curpath = { table.unpack(path) }
            curpath[#curpath + 1] = node.name

            -- selection highlight
            local is_selected = false
            if selected_folder_path and #selected_folder_path == #curpath then
                is_selected = true
                for i = 1, #curpath do if selected_folder_path[i] ~= curpath[i] then is_selected = false; break end end
            end

            -- push id to avoid ImGui id collisions (use unique runtime id)
            r.ImGui_PushID(ctx, node._id)
            -- r.ImGui_Indent(ctx, #path * indent_size)
            if r.ImGui_Selectable(ctx, node.name, is_selected) then
                selected_folder_path = { table.unpack(curpath) }
            end

                -- If double-clicked, clear universal search (focus on folder content)
    if r.ImGui_IsMouseDoubleClicked(ctx, 0) then
        universal_search = ""
        compute_global()  -- refresh global list
    end

            -- item rect and mouse pos (all in screen coords)
            local minx, miny = r.ImGui_GetItemRectMin(ctx)
            local maxx, maxy = r.ImGui_GetItemRectMax(ctx)
            local mx, my = r.ImGui_GetMousePos(ctx)

            local hovering = (mx >= minx and mx <= maxx and my >= miny and my <= maxy)
            local midpoint_y = (miny + maxy) * 0.5
            local insert_above = (my < midpoint_y)
            local insert_side = (mx >= (maxx - 28)) and "right" or "left"

            -- indicator (only when dragging and hovering)
            if CURRENT_DRAG_PAYLOAD and hovering then
                local draw_list = r.ImGui_GetWindowDrawList(ctx)
                local line_y = insert_above and (miny - 1) or (maxy + 1)
                r.ImGui_DrawList_AddLine(draw_list, minx, line_y, maxx, line_y, 0xFF00C0FF, 3)
                if insert_side == "right" then
                    local cx = maxx - 12
                    local cy = (miny + maxy) * 0.5
                    r.ImGui_DrawList_AddTriangleFilled(draw_list,
                        cx - 6, cy - 6,
                        cx - 6, cy + 6,
                        cx + 4, cy,
                        0xFF00C0FF)
                end
            end

            -- DRAG SOURCE: use runtime id as payload (store globally and send a type-only payload)
            if r.ImGui_BeginDragDropSource(ctx) then
                CURRENT_DRAG_PAYLOAD = node._id
                r.ImGui_SetDragDropPayload(ctx, "FOLDER_MOVE", 0)
                r.ImGui_Text(ctx, "Move: " .. node.name)
                r.ImGui_EndDragDropSource(ctx)
            end

            -- DRAG TARGET: accept payload only when hovering
            if r.ImGui_BeginDragDropTarget(ctx) and hovering then
                if r.ImGui_AcceptDragDropPayload(ctx, "FOLDER_MOVE") then
                    local payload_id = CURRENT_DRAG_PAYLOAD
                    CURRENT_DRAG_PAYLOAD = nil

                    if payload_id then
                        -- find the source node by id
                        local src_parent, src_idx, moved_node = find_parent_and_index_by_id(DATA.folders, payload_id)
                         r.ShowConsoleMsg(string.format("[QuickFX] Source index (parent=%s) (index=%s) (movednode=%s).\n", tostring(payload_id), tostring(src_idx), tostring(moved_node)))
                        if not (src_parent and src_idx and moved_node) then
                            r.ShowConsoleMsg(string.format("[QuickFX] Source not found for move (id=%s).\n", tostring(payload_id)))
                        else
                            -- guard: do not move into its own descendant
                            if moved_node._id == node._id or is_descendant(moved_node, node._id) then
                                r.ShowConsoleMsg(string.format("[QuickFX] Can't move '%s' into itself/descendant.\n", moved_node.name))
                                -- no change
                            else
                                -- remove source (keeps moved_node reference)
                                table.remove(src_parent, src_idx)

                                -- if dropping on right-side -> make child (insert into node.sub)
                                if insert_side == "right" then
                                    node.sub = node.sub or {}
                                    local child_insert_pos = insert_above and 1 or (#node.sub + 1)
                                    table.insert(node.sub, child_insert_pos, moved_node)
                                    r.ShowConsoleMsg(string.format("[QuickFX] '%s' → child of '%s'\n", moved_node.name, node.name))
                                else
                                  -- left side: insert as sibling
local target_parent, target_idx, target_node = find_parent_and_index_by_id(DATA.folders, node._id)
local insert_pos = insert_above and target_idx or (target_idx + 1)

if target_parent then
    -- adjust for movement within same parent
    if src_parent == target_parent and src_idx < insert_pos then insert_pos = insert_pos - 1 end
    insert_node_into(target_parent, insert_pos, moved_node)
    r.ShowConsoleMsg(string.format("[QuickFX] '%s' → sibling of '%s' (parent: %s)\n",
        moved_node.name, node.name, tostring(target_parent)))
else
    -- fallback to root (only if node is top-level)
    local root_insert_pos = insert_above and idx or (idx + 1)
    if src_parent == DATA.folders and src_idx < root_insert_pos then root_insert_pos = root_insert_pos - 1 end
    insert_node_into(DATA.folders, root_insert_pos, moved_node)
    r.ShowConsoleMsg(string.format("[QuickFX] '%s' → sibling in root of '%s'\n",
        moved_node.name, node.name))
end



                                    -- r.ShowConsoleMsg(string.format("[QuickFX] Moved '%s' to position %d in parent\n", moved_node.name, insert_pos))
                                end

                                persist_all()
                            end
                        end
                    end
                end
                r.ImGui_EndDragDropTarget(ctx)
            end

            -- context menu: Add subfolder (assign id), Rename, Delete
            if r.ImGui_BeginPopupContextItem(ctx) then
                if r.ImGui_Selectable(ctx, "Add subfolder") then
                    node.sub = node.sub or {}
                    local newsub = { name = "New Subfolder", sub = {}, fx = {}, _id = DATA._next_folder_id }
                    DATA._next_folder_id = DATA._next_folder_id + 1
                    node.sub[#node.sub + 1] = newsub
                    persist_all()
                end
                if r.ImGui_Selectable(ctx, "Rename") then
                    local ok, newn = r.GetUserInputs("Rename folder", 1, "Name:", node.name)
                    if ok and newn ~= "" then node.name = newn; persist_all() end
                end
                if r.ImGui_Selectable(ctx, "Delete") then
                    local function remove(tbl, tgt)
                        for i = #tbl, 1, -1 do
                            if tbl[i] == tgt then table.remove(tbl, i); return true end
                            if tbl[i].sub and remove(tbl[i].sub, tgt) then return true end
                        end
                        return false
                    end
                    remove(DATA.folders, node)
                    persist_all()
                end
                r.ImGui_EndPopup(ctx)
            end

            -- recurse into subfolders; pass the current 'list' as the parent_table for children
            if node.sub and #node.sub > 0 then
                  r.ImGui_Indent(ctx, 12)
                draw_nodes(node.sub, curpath, list)
                  r.ImGui_Unindent(ctx, 12)
            end

            -- r.ImGui_Unindent(ctx, #path * indent_size)
            r.ImGui_PopID(ctx)
        end

        -- --- append drop zone (after the last item) so user can drop to append to this parent ---
        -- This handles "append to root / append to a specific parent" explicitly
        -- Render a tiny dummy and accept drops there
         local dummy_h = 6
        local cur_y = r.ImGui_GetCursorPosY(ctx)
        r.ImGui_SetCursorPosY(ctx, cur_y + 2) -- correct signature: ctx, y
        r.ImGui_InvisibleButton(ctx, "##append_zone", -1, dummy_h)
        local minx, miny = r.ImGui_GetItemRectMin(ctx)
        local maxx, maxy = r.ImGui_GetItemRectMax(ctx)
        local mx, my = r.ImGui_GetMousePos(ctx)
        local hovering_append = (mx >= minx and mx <= maxx and my >= miny and my <= maxy)

        if CURRENT_DRAG_PAYLOAD and hovering_append then
            local draw_list = r.ImGui_GetWindowDrawList(ctx)
            r.ImGui_DrawList_AddRectFilled(draw_list, minx + 2, miny, maxx - 2, maxy, 0x2000C0FF)
            r.ImGui_DrawList_AddLine(draw_list, minx + 2, (miny + maxy) * 0.5, maxx - 2, (miny + maxy) * 0.5, 0xFF00C0FF, 3)
        end

        if r.ImGui_BeginDragDropTarget(ctx) and hovering_append then
            if r.ImGui_AcceptDragDropPayload(ctx, "FOLDER_MOVE") then
                local payload_id = CURRENT_DRAG_PAYLOAD
                CURRENT_DRAG_PAYLOAD = nil
                if payload_id then
                    local src_parent, src_idx, moved_node = find_parent_and_index_by_id(DATA.folders, payload_id)
                    if not (src_parent and src_idx and moved_node) then
                        r.ShowConsoleMsg(string.format("[QuickFX] Source not found for append move (id=%s).\n", tostring(payload_id)))
                    else
                        -- guard: avoid moving into its own descendant (append to same table is ok)
                        -- remove source
                        table.remove(src_parent, src_idx)
                        -- if source was inside this parent_table and earlier index, then nothing else to do (we append at end)
                        insert_node_into(parent_table or DATA.folders, nil, moved_node)
                        persist_all()
                        r.ShowConsoleMsg(string.format("[QuickFX] Appended '%s' to parent\n", moved_node.name))
                    end
                end
            end
            r.ImGui_EndDragDropTarget(ctx)
        end
    end

    -- ensure runtime ids exist for all nodes (safe guard for nodes added externally)
    ensure_folder_ids(DATA.folders)
    draw_nodes(DATA.folders, {}, nil)
end





-- main UI draw
local function draw_ui()
    ----------------------------------------------------------------------
    -- Search Bars
    ----------------------------------------------------------------------
    r.ImGui_PushItemWidth(ctx, -1)
    universal_search = im_input_text("##universal_search", universal_search)
    r.ImGui_PopItemWidth(ctx)
    r.ImGui_Separator(ctx)

    ----------------------------------------------------------------------
    -- Table Layout
    ----------------------------------------------------------------------
    local flags = (r.ImGui_TableFlags_Resizable and r.ImGui_TableFlags_Resizable() or 0)
                | (r.ImGui_TableFlags_BordersInnerV and r.ImGui_TableFlags_BordersInnerV() or 0)

    if r.ImGui_BeginTable(ctx, "main_split", 2, flags) then
        ------------------------------------------------------------------
        -- LEFT COLUMN (Folders)
        ------------------------------------------------------------------
        r.ImGui_TableNextColumn(ctx)
        r.ImGui_Text(ctx, "Folders")

        if r.ImGui_Button(ctx, "Add Folder") then
            local ok, name = r.GetUserInputs("New folder name", 1, "Name:", "")
            if ok and name and name ~= "" then add_folder(name) end
        end

        r.ImGui_SameLine(ctx)

        if r.ImGui_Button(ctx, "Save Data") then
            persist_all()
            r.ShowMessageBox("Saved folders & notes.", "Saved", 0)
        end

        r.ImGui_Separator(ctx)

        if r.ImGui_BeginChild(ctx, "folder_child", -1, 350, 0, 0) then
            draw_folders()
            r.ImGui_EndChild(ctx)
        end

        ------------------------------------------------------------------
        -- RIGHT COLUMN (FX List)
        ------------------------------------------------------------------
        r.ImGui_TableNextColumn(ctx)
        r.ImGui_Text(ctx, "Plugins")

        r.ImGui_PushItemWidth(ctx, -1)
        local_ok, local_search = pcall(function()
            return im_input_text("##local_search", local_search)
        end)
        r.ImGui_PopItemWidth(ctx)
        r.ImGui_Separator(ctx)

        ------------------------------------------------------------------
        -- Build Display List
        ------------------------------------------------------------------
        local list = {}

        if universal_search and universal_search ~= "" then
            compute_global()
            for _, v in ipairs(filtered_global) do list[#list + 1] = v end
        else
            local fl = folder_list_items()
            for _, v in ipairs(fl) do list[#list + 1] = v end
        end

        ------------------------------------------------------------------
        -- FX List UI
        ------------------------------------------------------------------
        if r.ImGui_BeginChild(ctx, "plugins_child", -1, 350, 0, 0) then
            for i, item in ipairs(list) do
                local label = item.display or item.name or tostring(item)
                local selected = false

                -- check selection
                for _, fx in ipairs(DATA.selected_fx) do
                    if fx == label then selected = true break end
                end

                if r.ImGui_Selectable(ctx, label, selected, r.ImGui_SelectableFlags_AllowDoubleClick()) then
                    local mods = r.ImGui_GetKeyMods(ctx)

                    if mods & r.ImGui_Mod_Shift() ~= 0 and last_clicked_index then
                        -- shift-select range
                        local start_i = math.min(last_clicked_index, i)
                        local end_i = math.max(last_clicked_index, i)
                        DATA.selected_fx = {}
                        for j = start_i, end_i do
                            table.insert(DATA.selected_fx, list[j].display or list[j].name)
                        end
                    elseif mods & r.ImGui_Mod_Ctrl() ~= 0 then
                        -- ctrl toggles selection
                        if selected then
                            for k, v in ipairs(DATA.selected_fx) do
                                if v == label then table.remove(DATA.selected_fx, k) break end
                            end
                        else
                            table.insert(DATA.selected_fx, label)
                        end
                    else
                        -- single select
                        DATA.selected_fx = { label }
                    end

                    last_clicked_index = i
                end

                draw_plugin_context(item)

                -- notes tooltip
                if r.ImGui_IsItemHovered(ctx) then
                    local note = DATA.notes[label]
                    if note and note ~= "" then r.ImGui_SetTooltip(ctx, note) end
                end
            end
            r.ImGui_EndChild(ctx)
        end

        ------------------------------------------------------------------
        -- Refresh FX list
        ------------------------------------------------------------------
        if r.ImGui_Button(ctx, "Refresh FX list") then
            ALL_FX = build_master_fx_list()
            ALL_FXCHAINS = build_fxchain_list()
            compute_global()
            DATA.fx_index = build_fx_index(ALL_FX, ALL_FXCHAINS)
            r.ShowMessageBox("Refreshed FX and FX Chains.", "Refreshed", 0)
        end

        r.ImGui_EndTable(ctx)
    end

    ----------------------------------------------------------------------
    -- Bottom Status / Selection Display
    ----------------------------------------------------------------------
    r.ImGui_Separator(ctx)
    local sel_text = (#DATA.selected_fx > 0) and table.concat(DATA.selected_fx, ", ") or "None"
    r.ImGui_Text(ctx, "Selected: " .. sel_text)
end


 -- Unified resolver: find any FX or FXChain by display name
 local function resolve_fx_item(display)
    if not display or not DATA.fx_index then return nil end
    local fx = DATA.fx_index[display]
    if not fx then
        -- fallback: try a name match just in case some entries aren't indexed
        for _, v in ipairs(ALL_FX or {}) do
            if v.name == display then fx = v break end
        end
        for _, v in ipairs(ALL_FXCHAINS or {}) do
            if v.name == display then fx = v break end
        end
    end
    return fx
end


-- keyboard shortcuts (Ctrl+S, Ctrl+F)
local function check_shortcuts()
    local mods = r.ImGui_GetKeyMods(ctx)
        -- Detect Enter key pressed once (outside the loop)
    local enter_pressed = r.ImGui_IsKeyPressed(ctx, r.ImGui_Key_Enter())
   -- Ctrl+A: select all in current plugin list
    if mods & r.ImGui_Mod_Ctrl() ~= 0 and r.ImGui_IsKeyPressed(ctx, r.ImGui_Key_A()) then
        local list = {}
        if universal_search and universal_search ~= "" then
            compute_global()
            for _,v in ipairs(filtered_global) do list[#list+1] = v.name end
        else
            local fl = folder_list_items()
            for _,v in ipairs(fl) do list[#list+1] = v.name end
        end
        DATA.selected_fx = list
    end

    -- Ctrl+D: deselect all
    if mods & r.ImGui_Mod_Ctrl() ~= 0 and r.ImGui_IsKeyPressed(ctx, r.ImGui_Key_D()) then
        DATA.selected_fx = {}
    end

    -- Handle Enter key AFTER loop to avoid duplicate insert calls
 -- Handle Enter key
if enter_pressed then
    -- If nothing is selected, abort early
    if not DATA.selected_fx or #DATA.selected_fx == 0 then return end

    -- Ensure there’s at least one selected track, or create one
    local sel_tracks = r.CountSelectedTracks(0)
    if sel_tracks == 0 then
        r.InsertTrackAtIndex(r.CountTracks(0), true)
        r.TrackList_AdjustWindows(false)
        r.SetOnlyTrackSelected(r.GetTrack(0, r.CountTracks(0)-1)) -- focus new track
        sel_tracks = 1
    end

    for t = 0, sel_tracks - 1 do
        local tr = r.GetSelectedTrack(0, t)
        if tr then
            for _, fx_display in ipairs(DATA.selected_fx) do
                -- Resolve via fx_index (fast lookup)
                local item = DATA.fx_index and DATA.fx_index[fx_display]
                if not item then
                    r.ShowConsoleMsg(string.format("[QuickFX] Unknown FX: %s\n", tostring(fx_display)))
                else
                    if item.is_fxchain then
                        -- Add FX Chain
                        r.TrackFX_AddByName(tr, item.rawname, false, 1)
                        --  r.ShowConsoleMsg(string.format("[QuickFX] ITEM PATH: %s\n", tostring(item.rawname)))
                    else
                        -- Add Individual FX
                        r.TrackFX_AddByName(tr, item.name or fx_display, false, -1000)
                    end
                end
            end
        end
    end
end





        end

-- initial compute
compute_global()

--------------------------------------------------
-- Note editor modal
--------------------------------------------------
local function draw_note_modal()
    -- If a note edit was triggered, open the modal next frame
    if note_modal_open then
        r.ImGui_OpenPopup(ctx, "Note Editor")
        note_modal_open = false
        note_modal_just_opened = true
    end

    if r.ImGui_BeginPopupModal(ctx, "Note Editor", true, r.ImGui_WindowFlags_AlwaysAutoResize()) then
        -- Only reinitialize once when opened
        if note_modal_just_opened then
            note_modal_just_opened = false
            if editing_fx_list and #editing_fx_list > 0 then
                -- Load the current note of the first selected FX
                local fxname = editing_fx_list[1]
                note_buffer = DATA.notes[fxname] or ""
            else
                note_buffer = ""
            end
        end

        local fxnames = table.concat(editing_fx_list, ", ")
        r.ImGui_Text(ctx, "Editing note for: " .. fxnames)

        -- Draw input field with the current note
        local changed, buf = r.ImGui_InputTextMultiline(ctx, "##note_input", note_buffer, 400, 200)
        if changed then note_buffer = buf end

        -- Save button
        if r.ImGui_Button(ctx, "Save") then
            for _, fx in ipairs(editing_fx_list) do
                DATA.notes[fx] = note_buffer
            end
            persist_all()
            r.ImGui_CloseCurrentPopup(ctx)
        end

        r.ImGui_SameLine(ctx)
        if r.ImGui_Button(ctx, "Cancel") then
            r.ImGui_CloseCurrentPopup(ctx)
        end

        r.ImGui_EndPopup(ctx)
    end
end

-- main loop (Begin/End pairing preserved)
local function loop()
    r.ImGui_SetNextWindowSize(ctx, 430, 540, r.ImGui_Cond_FirstUseEver())
    local visible, open = r.ImGui_Begin(ctx, "QuickFX Browser", true)
     if visible then
        draw_ui()
        draw_note_modal()
    end
    r.ImGui_End(ctx) -- always call End
    check_shortcuts()
    if open then r.defer(loop) end
end

r.defer(loop)
persist_all()
