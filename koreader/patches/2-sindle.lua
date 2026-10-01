--[[
SINdle - a hidden private library for KOReader
-----------------------------------------------
A boring-looking decoy book in your normal library is the way in. Opening it asks
for your code (or shows a fake "could not load" error with a secret double-tap).
Then KOReader's library switches to a private folder (default: koreader/system).

* Private books never show up in history, Continue (for the normal library),
  reading statistics, or the file browser while locked.
* Locks on: power button / sleep, Home, opening a normal book, "Lock now",
  restarting KOReader, and optionally when closing a private book.
* Settings: top menu -> gear tab -> Privacy (only visible while unlocked).
* Code and settings: koreader/settings/private-code (delete to reset).lua
  Delete that file from a computer to reset a forgotten code.
* Works with or without the Zen UI plugin.

Install: copy this file to koreader/patches/ and restart KOReader.
Remove:  delete this file and restart KOReader.
License: MIT (c) 2026 idkrandombuilds - see LICENSE.
Every hook is wrapped in pcall: if anything fails, KOReader keeps working and the
decoy simply opens as an ordinary (boring) book.
--]]

local ok_patch, patch_err = pcall(function()

local lfs        = require("libs/libkoreader-lfs")
local ffiUtil    = require("ffi/util")
local logger     = require("logger")
local UIManager  = require("ui/uimanager")
local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")
local userpatch  = require("userpatch")

local DECOY_MATCH   = "Extensive Analysis of the"   -- survives Calibre's filename shortening
local PIN_TITLE     = "DEV SETTINGS: WARNING CAN BRICK DEVICE"

-- ---------------------------------------------------------------- paths
local function realpath(p)
    if type(p) ~= "string" or p == "" then return p end
    return ffiUtil.realpath(p) or p
end

local DATA_DIR = DataStorage:getFullDataDir()
local DEFAULT_PRIVATE_DIR = realpath(DATA_DIR .. "/system")

local function strip_mount(p)
    p = p:gsub("/+$", "")
    p = p:gsub("^/mnt/base%-us/", "/mnt/us/")
    return p
end
local function key_of(p) return strip_mount(realpath(p)) end
local function is_under(p, dir_key)
    if type(p) ~= "string" or p == "" or not dir_key then return false end
    local k = key_of(p)
    return k == dir_key or k:sub(1, #dir_key + 1) == dir_key .. "/"
end

local function home_dir()
    local h = G_reader_settings:readSetting("home_dir")
    if not h or lfs.attributes(h, "mode") ~= "directory" then
        h = require("device").home_dir
    end
    return h
end

local function basename(p) return (type(p) == "string" and p:match("([^/]+)$")) or "" end

-- ---------------------------------------------------------------- state
-- Code, toggles and the chosen private folder live in a clearly named file in
-- koreader/settings. Deleting it from a computer resets the code AND the folder
-- (back to koreader/system).
local STATE_FILE = DATA_DIR .. "/settings/private-code (delete to reset).lua"
local settings
local function S()
    if not settings then
        settings = LuaSettings:open(STATE_FILE)
    end
    return settings
end

-- The private folder (configurable in Privacy -> Private library folder).
local private_dir, private_key, private_parent_key, private_name
local function set_private_dir(p)
    private_dir = realpath(p)
    private_key = strip_mount(private_dir)
    private_parent_key = private_key:match("^(.*)/[^/]+$")
    private_name = basename(private_key)
end
do
    local chosen = S():readSetting("private_dir")
    if type(chosen) == "string" and lfs.attributes(chosen, "mode") == "directory" then
        set_private_dir(chosen)
    else
        set_private_dir(DEFAULT_PRIVATE_DIR)
    end
end

local function is_private(p) return is_under(p, private_key) end
local function is_private_parent(p)
    return type(p) == "string" and private_parent_key ~= nil and key_of(p) == private_parent_key
end

local unlocked     = false   -- memory only: every restart starts locked
local public_last  = nil     -- public "lastfile" saved while unlocked
local pending_lock = false   -- extra security: lock on next file-browser show

local function first_public_history_file()
    local ok, ReadHistory = pcall(require, "readhistory")
    if not ok then return nil end
    for _, v in ipairs(ReadHistory.hist or {}) do
        if v.file and not is_private(v.file) and lfs.attributes(v.file, "mode") == "file" then
            return v.file
        end
    end
end

-- ---------------------------------------------------------------- lock / unlock
-- Move the file browser off the private folder and make Zen rebuild its Library
-- page (Zen keeps a pre-built copy and would otherwise re-show the private list).
local function reset_browser_to_home()
    local FileManager = require("apps/filemanager/filemanager")
    local fm = FileManager.instance
    local fc = fm and fm.file_chooser
    if not fc then return end
    if fc.path and is_private(fc.path) then
        fc:changeToPath(home_dir())
    end
    fc._zen_home_retained_library = nil
    fc._zen_idle_materialized_library = nil
    fc._zen_needs_full_listing = true
end

-- While unlocked, KOReader's home folder IS the private folder, so KOReader and Zen
-- treat it as "the library" natively (Library tab, Home, cover view). The real home
-- folder is saved in the state file and restored on lock - and at startup, in case
-- the device restarted while unlocked.
local function set_private_home()
    local cur = G_reader_settings:readSetting("home_dir")
    if cur and is_private(cur) then return end
    S():saveSetting("public_home_dir", cur or false) -- false = "no home folder was set"
    S():flush()
    G_reader_settings:saveSetting("home_dir", private_dir)
end
local function restore_public_home()
    local cur = G_reader_settings:readSetting("home_dir")
    if not (cur and is_private(cur)) then return end
    local saved = S():readSetting("public_home_dir")
    if type(saved) == "string" and saved ~= "" and not is_private(saved) then
        G_reader_settings:saveSetting("home_dir", saved)
    else
        G_reader_settings:delSetting("home_dir")
    end
end

-- Make Zen rebuild its Library page from the (new) home folder next time it's shown.
local function mark_library_stale()
    local fm = require("apps/filemanager/filemanager").instance
    local fc = fm and fm.file_chooser
    if not fc then return end
    fc._zen_home_retained_library = nil
    fc._zen_idle_materialized_library = nil
    fc._zen_needs_full_listing = true
end

-- The "Privacy" entry in the file browser's settings (gear) tab only exists while
-- unlocked. KOReader builds its menu only once (a second build fails), so the entry
-- is inserted into / removed from the already-built gear tab instead.
local sync_privacy_menu -- assigned in the settings-menu section below
local function refresh_menu()
    if not sync_privacy_menu then return end
    local fm = require("apps/filemanager/filemanager").instance
    if fm and fm.menu then pcall(sync_privacy_menu, fm.menu) end
    local rui = require("apps/reader/readerui").instance
    if rui and rui.menu then pcall(sync_privacy_menu, rui.menu) end
end

-- Same, but without navigating: used when Zen's Home screen is about to cover the
-- browser. A real changeToPath() here would make Zen jump to its Library tab and hide
-- the Home screen. Zen rebuilds the Library tab from home the next time it is opened,
-- thanks to _zen_needs_full_listing.
local function quiet_reset_browser()
    local FileManager = require("apps/filemanager/filemanager")
    local fm = FileManager.instance
    local fc = fm and fm.file_chooser
    if not fc then return end
    if fc.path and is_private(fc.path) then fc.path = home_dir() end
    fc._zen_home_retained_library = nil
    fc._zen_idle_materialized_library = nil
    fc._zen_needs_full_listing = true
end

local function lock(go_home)
    if not unlocked then return end
    unlocked = false
    pending_lock = false
    pcall(restore_public_home)
    pcall(mark_library_stale)
    pcall(refresh_menu)
    local cur = G_reader_settings:readSetting("lastfile")
    if cur and is_private(cur) then
        S():saveSetting("last_private_file", cur)
        S():flush()
    end
    local restore = public_last
    if not restore or is_private(restore) then restore = first_public_history_file() end
    if restore then
        G_reader_settings:saveSetting("lastfile", restore)
    else
        G_reader_settings:delSetting("lastfile")
    end
    public_last = nil
    local ld = G_reader_settings:readSetting("lastdir")
    if ld and is_private(ld) then
        G_reader_settings:saveSetting("lastdir", home_dir())
    end
    if go_home then reset_browser_to_home() end
end

-- Lock from anywhere (used on sleep): close a private book if one is open.
local function lock_now()
    if not unlocked then return end
    local ReaderUI = require("apps/reader/readerui")
    local rui = ReaderUI.instance
    if rui and rui.document and is_private(rui.document.file) then
        lock(false)
        rui:onClose()
        rui:showFileManager(nil)
        reset_browser_to_home()
    else
        lock(true)
    end
end

-- Home ends the private session if "Home button returns to the public library" is on
-- (default) or Extra security is on.
local function home_should_lock()
    return unlocked and (S():isTrue("extra_security") or not S():isTrue("home_stays_private"))
end
local function lock_for_home()
    if home_should_lock() then
        pcall(lock, false)
        pcall(quiet_reset_browser)
    end
end

local wrapped_home_modules = setmetatable({}, { __mode = "k" })
local our_home_wrappers = setmetatable({}, { __mode = "k" })
local function hook_zen_home_view()
    -- Zen's Home tab shows its home screen without changing folders; lock first.
    for _, mod in pairs(package.loaded) do
        if type(mod) == "table" and not wrapped_home_modules[mod]
                and type(rawget(mod, "showHomeView")) == "function" then
            wrapped_home_modules[mod] = true
            for _, name in ipairs({ "showHomeView", "resumeActive" }) do
                local fn = rawget(mod, name)
                if type(fn) == "function" then
                    mod[name] = function(...)
                        lock_for_home()
                        return fn(...)
                    end
                end
            end
        end
    end
    -- The "go home" action (Zen's top-menu home icon / Home key -> default tab, or
    -- KOReader's FileManager:onHome without Zen). Re-checked on every call because
    -- Zen may re-assign these; our own wrappers are recognised and not wrapped twice.
    local open_default = rawget(_G, "__ZEN_UI_NAVBAR_OPEN_DEFAULT_TAB")
    if type(open_default) == "function" and not our_home_wrappers[open_default] then
        local w = function(...)
            lock_for_home()
            return open_default(...)
        end
        our_home_wrappers[w] = true
        _G.__ZEN_UI_NAVBAR_OPEN_DEFAULT_TAB = w
    end
    local FileManager = require("apps/filemanager/filemanager")
    local on_home = FileManager.onHome
    if type(on_home) == "function" and not our_home_wrappers[on_home] then
        local w = function(...)
            lock_for_home()
            return on_home(...)
        end
        our_home_wrappers[w] = true
        FileManager.onHome = w
    end
end

local function open_private_folder()
    local FileManager = require("apps/filemanager/filemanager")
    local fm = FileManager.instance
    if not (fm and fm.file_chooser) then
        FileManager:showFiles(private_dir)
        return
    end
    local open_folder = rawget(_G, "__ZEN_UI_NAVBAR_OPEN_FOLDER")
    if type(open_folder) == "function" then
        pcall(open_folder, private_dir)
    end
    if not is_private(fm.file_chooser.path) then
        fm.file_chooser:changeToPath(private_dir)
    end
end

local function unlock()
    if not unlocked then
        unlocked = true
        pending_lock = false
        pcall(set_private_home)
        pcall(mark_library_stale)
        public_last = G_reader_settings:readSetting("lastfile")
        local lp = S():readSetting("last_private_file")
        if lp and lfs.attributes(lp, "mode") == "file" then
            G_reader_settings:saveSetting("lastfile", lp)
        else
            G_reader_settings:delSetting("lastfile")
        end
        pcall(hook_zen_home_view)
        pcall(refresh_menu)
    end
    open_private_folder()
end

-- ---------------------------------------------------------------- PIN
local sha256 = require("ffi/sha2").sha256

-- Codes: 4-8 letters/digits, letters case-insensitive (Kindle keyboard Shift is easy to miss).
local function norm_code(s) return type(s) == "string" and s:gsub("%s", ""):lower() or "" end

local function hash_pin(pin)
    return sha256((S():readSetting("salt") or "") .. norm_code(pin))
end

local function valid_pin(pin)
    local s = norm_code(pin)
    return #s >= 4 and #s <= 8 and s:match("^%w+$") ~= nil
end

local function pin_dialog(hint, on_done)
    local InputDialog = require("ui/widget/inputdialog")
    local dialog
    dialog = InputDialog:new{
        title = PIN_TITLE,
        input_hint = hint,
        text_type = "password",
        buttons = {{
            { text = "Cancel", id = "close", callback = function() UIManager:close(dialog) end },
            { text = "OK", is_enter_default = true, callback = function()
                local pin = dialog:getInputText()
                UIManager:close(dialog)
                on_done(pin)
            end },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

local function set_new_pin(after)
    pin_dialog("Choose a code: 4-8 letters/numbers", function(pin1)
        if not valid_pin(pin1) then
            UIManager:show(require("ui/widget/infomessage"):new{ text = "Use 4-8 letters or numbers.", timeout = 2 })
            return
        end
        pin_dialog("Repeat the code", function(pin2)
            if norm_code(pin1) ~= norm_code(pin2) then
                UIManager:show(require("ui/widget/infomessage"):new{ text = "Codes did not match.", timeout = 2 })
                return
            end
            S():saveSetting("salt", tostring(os.time()) .. tostring(math.random(100000, 999999)))
            S():saveSetting("pin_hash", hash_pin(pin1))
            S():flush()
            if after then after() end
        end)
    end)
end

local function code_required() return not S():isTrue("code_disabled") end

-- Last gate before the private library: the code (if "Require code" is on).
local function enter_private()
    if unlocked then unlock() return end
    if not code_required() then unlock() return end
    if not S():readSetting("pin_hash") then
        set_new_pin(unlock)
        return
    end
    pin_dialog("Enter access code", function(pin)
        if valid_pin(pin) and hash_pin(pin) == S():readSetting("pin_hash") then
            unlock()
        end
        -- wrong code: dialog already closed, nothing else happens
    end)
end

-- "Show fake error" mode: looks like a normal KOReader error box.
--   X (top-left), OK (bottom) or a tap outside: close.
--   Two quick taps on the empty top-right corner of the box: on_secret().
local function show_fake_error(on_secret)
    local Blitbuffer      = require("ffi/blitbuffer")
    local ButtonTable     = require("ui/widget/buttontable")
    local CenterContainer = require("ui/widget/container/centercontainer")
    local Device          = require("device")
    local Font            = require("ui/font")
    local FrameContainer  = require("ui/widget/container/framecontainer")
    local Geom            = require("ui/geometry")
    local GestureRange    = require("ui/gesturerange")
    local HorizontalGroup = require("ui/widget/horizontalgroup")
    local HorizontalSpan  = require("ui/widget/horizontalspan")
    local IconButton      = require("ui/widget/iconbutton")
    local IconWidget      = require("ui/widget/iconwidget")
    local InputContainer  = require("ui/widget/container/inputcontainer")
    local OverlapGroup    = require("ui/widget/overlapgroup")
    local Size            = require("ui/size")
    local TextBoxWidget   = require("ui/widget/textboxwidget")
    local VerticalGroup   = require("ui/widget/verticalgroup")
    local VerticalSpan    = require("ui/widget/verticalspan")
    local time            = require("ui/time")
    local Screen          = Device.screen

    local box = InputContainer:new{ modal = true }
    local function close() UIManager:close(box) end

    -- Compact, roughly square box: icon on top, centred text (wraps onto 2 lines).
    local inner_w = math.floor(math.min(Screen:getWidth(), Screen:getHeight()) * 0.42)
    local icon = IconWidget:new{ icon = "notice-warning", alpha = true }
    local content = VerticalGroup:new{
        align = "center",
        CenterContainer:new{ dimen = Geom:new{ w = inner_w, h = icon:getSize().h }, icon },
        VerticalSpan:new{ width = Size.padding.large },
        TextBoxWidget:new{
            text = "Error, could not load book",
            face = Font:getFace("infofont"),
            width = inner_w,
            alignment = "center",
        },
    }
    local close_size = Screen:scaleBySize(28)
    local close_btn = IconButton:new{
        icon = "close",
        width = close_size,
        height = close_size,
        padding = Size.padding.small,
        callback = close,
        show_parent = box,
    }
    local top_h = close_btn:getSize().h
    local top_row = OverlapGroup:new{ dimen = Geom:new{ w = inner_w, h = top_h }, close_btn } -- X on the left, right side empty
    local buttons = ButtonTable:new{
        width = inner_w,
        buttons = {{ { text = "OK", callback = close } }},
        zero_sep = true,
        show_parent = box,
    }
    local frame = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        radius = Size.radius.window,
        padding = Size.padding.default,
        padding_bottom = 0,
        VerticalGroup:new{
            align = "left",
            top_row,
            content,
            VerticalSpan:new{ width = Size.padding.large * 2 },
            buttons,
        },
    }
    box[1] = CenterContainer:new{ dimen = Screen:getSize(), frame }

    -- Buttons get taps first; anything they don't handle lands here.
    box.ges_events = {
        TapAny = { GestureRange:new{ ges = "tap",
            range = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() } } },
    }
    local last_secret_tap
    function box:onTapAny(_, ges)
        local f = frame.dimen
        if not f or ges.pos:notIntersectWith(f) then
            close() -- tap outside: behaves like any dismissable popup
            return true
        end
        local hot_x = f.x + math.floor(f.w * 0.6)
        local hotspot = Geom:new{ x = hot_x, y = f.y, w = f.x + f.w - hot_x, h = top_h + Size.padding.default }
        if ges.pos:intersectWith(hotspot) then
            local now = time.now()
            if last_secret_tap and now - last_secret_tap < time.s(1.5) then
                close()
                on_secret()
            else
                last_secret_tap = now
            end
        else
            last_secret_tap = nil
        end
        return true
    end
    function box:onShow()
        UIManager:setDirty(self, function() return "ui", frame.dimen end)
    end
    function box:onCloseWidget()
        UIManager:setDirty(nil, function() return "ui", frame.dimen end)
    end
    UIManager:show(box)
end

-- Tapping the decoy book.
local function on_decoy_tap()
    if unlocked then unlock() return end
    if S():isTrue("fake_error") then
        show_fake_error(enter_private)
    else
        enter_private()
    end
end

-- Which book is the decoy: a chosen file (Privacy -> Decoy book), else the default
-- brown book matched by its filename.
local function is_decoy(file)
    if type(file) ~= "string" then return false end
    local dp = S():readSetting("decoy_path")
    if type(dp) == "string" and dp ~= "" and lfs.attributes(dp, "mode") == "file" then
        return key_of(file) == key_of(dp)
    end
    return basename(file):find(DECOY_MATCH, 1, true) ~= nil
end

-- ---------------------------------------------------------------- settings menu
-- Gear tab -> "Privacy" (file browser only, and only while unlocked).
-- ---------------------------------------------------------------- private folder setting
local function info(text, timeout)
    UIManager:show(require("ui/widget/infomessage"):new{ text = text, timeout = timeout })
end

local function short_path(p)
    return (p:gsub("^/mnt/base%-us/", ""):gsub("^/mnt/us/", ""))
end

-- Returns a reason string if the folder can't be the private library, else nil.
local function folder_problem(p)
    local k = key_of(p)
    if k == "" or k == "/" or k == "/mnt/us" then
        return "Pick a folder, not the whole storage."
    end
    if k == key_of(DATA_DIR) then
        return "Pick a folder, not the koreader folder itself."
    end
    local public_home = G_reader_settings:readSetting("home_dir")
    if unlocked then public_home = S():readSetting("public_home_dir") end
    if type(public_home) ~= "string" or public_home == "" then
        public_home = require("device").home_dir
    end
    if public_home then
        local hk = key_of(public_home)
        if is_under(p, hk) then
            return "That folder is inside your normal library, so its books would show up there."
        end
        if is_under(public_home, k) then
            return "Your normal library is inside that folder."
        end
    end
end

local function change_private_dir(p, create)
    if type(p) ~= "string" then return end
    p = p:gsub("^%s+", ""):gsub("%s+$", ""):gsub("/+$", "")
    if p == "" then return end
    if lfs.attributes(p, "mode") ~= "directory" and create then
        pcall(require("util").makePath, p)
    end
    if lfs.attributes(p, "mode") ~= "directory" then
        info("Folder not found and could not be created:\n" .. p)
        return
    end
    local problem = folder_problem(p)
    if problem then info(problem) return end
    S():saveSetting("private_dir", realpath(p))
    S():delSetting("last_private_file")
    S():flush()
    set_private_dir(p)
    if unlocked then
        G_reader_settings:saveSetting("home_dir", private_dir)
        G_reader_settings:delSetting("lastfile")
        pcall(mark_library_stale)
        pcall(open_private_folder)
    end
    info("Private library folder:\n" .. short_path(private_dir), 3)
end

-- A KOReader PathChooser shown as a plain file list (this picker only).
-- Cover Browser swaps these display functions on every FileChooser; giving this one
-- instance the standard Menu versions leaves the library's cover view untouched.
local function show_plain_picker(opts)
    local FileChooser = require("ui/widget/filechooser")
    local PathChooser = require("ui/widget/pathchooser")
    local Menu = require("ui/widget/menu")
    local prev_hidden = FileChooser.show_hidden
    if opts.show_hidden then FileChooser.show_hidden = true end
    local pc = PathChooser:new{
        title = true, -- "Long-press ... to choose it"
        select_directory = opts.select_directory,
        select_file = opts.select_file,
        show_files = opts.select_file,
        path = opts.path,
        updateItems = Menu.updateItems,
        _recalculateDimen = Menu._recalculateDimen,
        onCloseWidget = function(this, ...)
            FileChooser.show_hidden = prev_hidden
            return Menu.onCloseWidget(this, ...)
        end,
        onConfirm = function(p)
            FileChooser.show_hidden = prev_hidden
            opts.on_choose(p)
        end,
    }
    UIManager:show(pc)
end

local function browse_private_dir()
    show_plain_picker{
        select_directory = true,
        select_file = false,
        show_hidden = true, -- dot-folders visible in this picker only
        path = private_dir:match("^(.*)/[^/]+$") or "/",
        on_choose = function(dir) change_private_dir(dir, false) end,
    }
end

-- ---------------------------------------------------------------- decoy book setting
local function public_home()
    local h = unlocked and S():readSetting("public_home_dir") or G_reader_settings:readSetting("home_dir")
    if type(h) ~= "string" or h == "" then h = require("device").home_dir end
    return h
end

local function decoy_label()
    local dp = S():readSetting("decoy_path")
    if type(dp) == "string" and dp ~= "" and lfs.attributes(dp, "mode") == "file" then
        return basename(dp):gsub("%.[^.]+$", "")
    end
    return "The Extensive Analysis of the Color Brown (default)"
end

local function choose_decoy()
    show_plain_picker{
        select_directory = false,
        select_file = true,
        path = public_home(),
        on_choose = function(file)
            if is_private(file) then
                info("The decoy must be in your normal library, not the private one.")
                return
            end
            S():saveSetting("decoy_path", realpath(file))
            S():flush()
            info("Decoy book:\n" .. basename(file), 3)
        end,
    }
end

-- "Require code" and "Show fake error" are mutually exclusive: one protection at a
-- time (or neither). Both toggles live only in the unlocked Privacy menu.
local function confirm(text, ok_text, on_ok)
    UIManager:show(require("ui/widget/confirmbox"):new{ text = text, ok_text = ok_text, ok_callback = on_ok })
end

local function set_protection(code_on, fake_on)
    S():saveSetting("code_disabled", not code_on)
    S():saveSetting("fake_error", fake_on)
    S():flush()
end

local function toggle_code_required(touchmenu)
    local function refresh() if touchmenu then touchmenu:updateItems() end end
    if code_required() then
        confirm("Turn off the code?\n\nAnyone who opens the decoy book will get into your private library.",
            "Turn off", function() set_protection(false, false); refresh() end)
    elseif not S():readSetting("pin_hash") then
        set_new_pin(function() set_protection(true, false); refresh() end)
    else
        set_protection(true, false) -- code on: fake error off
        refresh()
    end
end

local function toggle_fake_error(touchmenu)
    local function refresh() if touchmenu then touchmenu:updateItems() end end
    if S():isTrue("fake_error") then
        confirm("Turn off the fake error?\n\nThe code is also off, so anyone who opens the decoy book will get into your private library. (Turn on \"Require code\" instead to keep it protected.)",
            "Turn off", function() set_protection(false, false); refresh() end)
    else
        confirm("Turn on the fake error?\n\nThis turns off the code: the secret double-tap on the error box will open your private library directly.",
            "Turn on", function() set_protection(false, true); refresh() end)
    end
end

local function type_private_dir()
    local InputDialog = require("ui/widget/inputdialog")
    local d
    d = InputDialog:new{
        title = "Private library folder",
        input = private_dir,
        description = "Full path. Folders whose name starts with a dot (e.g. /mnt/us/.private) are hidden. The folder is created if it doesn't exist.",
        buttons = {{
            { text = "Cancel", id = "close", callback = function() UIManager:close(d) end },
            { text = "Use this folder", is_enter_default = true, callback = function()
                local t = d:getInputText()
                UIManager:close(d)
                change_private_dir(t, true)
            end },
        }},
    }
    UIManager:show(d)
    d:onShowKeyboard()
end

local function privacy_menu_item()
    return {
        text = "Privacy",
        sub_item_table = {
            {
                text = "Require code",
                checked_func = code_required,
                check_callback_updates_menu = true, -- turning it off asks first
                callback = function(touchmenu) toggle_code_required(touchmenu) end,
            },
            {
                text = "Show fake error when the decoy is opened",
                help_text = "Instead of a code: opening the decoy shows \"Error, could not load book\". X, OK or tapping outside closes it. Tap the empty top-right corner of the box twice quickly to open the private library. Turning this on turns the code off, and vice versa.",
                checked_func = function() return S():isTrue("fake_error") end,
                check_callback_updates_menu = true, -- asks first
                callback = function(touchmenu) toggle_fake_error(touchmenu) end,
            },
            {
                text_func = function() return "Decoy book: " .. decoy_label() end,
                sub_item_table = {
                    { text = "Choose a book... (long-press it)", callback = choose_decoy },
                    { text = "Reset to default (The Extensive Analysis of the Color Brown)", callback = function()
                        S():delSetting("decoy_path"); S():flush()
                        info("Decoy book: The Extensive Analysis of the Color Brown", 3)
                    end },
                },
                separator = true,
            },
            {
                text = "Extra security: lock when closing a book",
                checked_func = function() return S():isTrue("extra_security") end,
                callback = function()
                    S():flipNilOrFalse("extra_security"); S():flush()
                end,
            },
            {
                text = "Home button returns to the public library",
                help_text = "On: Home locks the private library and takes you to your normal Home/library. Off: Home keeps you in the private library (unless Extra security is on).",
                checked_func = function() return not S():isTrue("home_stays_private") end,
                callback = function()
                    S():flipNilOrFalse("home_stays_private"); S():flush()
                end,
            },
            {
                text = "Lock on power button / sleep",
                checked_func = function() return not S():isTrue("power_lock_disabled") end,
                callback = function()
                    S():flipNilOrFalse("power_lock_disabled"); S():flush()
                end,
            },
            {
                text = "Show Privacy inside private books",
                checked_func = function() return S():isTrue("privacy_in_books") end,
                callback = function()
                    S():flipNilOrFalse("privacy_in_books"); S():flush()
                    refresh_menu()
                end,
                separator = true,
            },
            {
                text_func = function() return "Private library folder: " .. short_path(private_dir) end,
                sub_item_table = {
                    { text = "Browse... (hidden folders shown)", callback = browse_private_dir },
                    { text = "Type a path...", callback = type_private_dir },
                    { text = "Reset to default (koreader/system)", callback = function()
                        change_private_dir(DEFAULT_PRIVATE_DIR, true)
                    end },
                },
                separator = true,
            },
            {
                text = "Change code",
                callback = function()
                    set_new_pin(function()
                        UIManager:show(require("ui/widget/infomessage"):new{ text = "Code changed.", timeout = 2 })
                    end)
                end,
            },
            {
                text = "Lock now", -- inside a private book: closes it and goes to the normal library
                callback = function() UIManager:nextTick(lock_now) end, -- after the menu closes
            },
        },
    }
end

local privacy_item -- one shared table, so it can be found and removed again
-- Library menu: shown whenever unlocked. Reader menu: only inside a private book,
-- while unlocked, and only if "Show Privacy inside private books" is on.
sync_privacy_menu = function(menu)
    if not (menu and type(menu.tab_item_table) == "table") then return end
    local doc = menu.ui and menu.ui.document
    local want
    if doc then
        want = unlocked and S():isTrue("privacy_in_books") and is_private(doc.file)
    else
        want = unlocked
    end
    local tab
    for _, t in ipairs(menu.tab_item_table) do
        if type(t) == "table" and t.id == "setting" then tab = t break end
    end
    if not tab then return end
    if not privacy_item then
        privacy_item = privacy_menu_item()
        privacy_item.separator = true
    end
    local idx
    for i, it in ipairs(tab) do if it == privacy_item then idx = i break end end
    if want and not idx then
        table.insert(tab, 1, privacy_item)
    elseif not want and idx then
        table.remove(tab, idx)
    end
end

-- ---------------------------------------------------------------- hooks
local function safe_wrap(tbl, name, make)
    if type(tbl) ~= "table" or type(tbl[name]) ~= "function" then
        logger.warn("SINdle: cannot hook", name)
        return
    end
    local orig = tbl[name]
    tbl[name] = make(orig)
end

-- Opening files: decoy -> PIN, settings file -> settings, private while locked -> refuse.
local ReaderUI = require("apps/reader/readerui")
safe_wrap(ReaderUI, "showReader", function(orig)
    return function(self, file, ...)
        local handled = false
        local ok, err = pcall(function()
            if is_decoy(file) then
                handled = true
                on_decoy_tap()
            elseif is_private(file) then
                if not unlocked then
                    handled = true -- e.g. stale "continue"; never open while locked
                else
                    pending_lock = false -- moving between private books
                end
            elseif unlocked then
                -- Opening a normal book ends the private session first; the normal
                -- book then behaves exactly as without this patch.
                lock(false)
                quiet_reset_browser()
            end
        end)
        if not ok then logger.warn("SINdle showReader:", err) end
        if handled then
            -- Zen shows an "Opening" banner as soon as a book is tapped and removes it
            -- when the book has opened. This book never opens, so cancel it now
            -- (otherwise it lingers ~10 s). No-op without Zen.
            local cancel_banner = rawget(_G, "__ZEN_UI_CANCEL_OPENING_BANNER")
            if type(cancel_banner) == "function" then pcall(cancel_banner, true) end
            return
        end
        return orig(self, file, ...)
    end
end)

-- Extra security: closing a private book locks before the library is shown again.
safe_wrap(ReaderUI, "onClose", function(orig)
    return function(self, ...)
        local was_private = false
        pcall(function() was_private = self.document and is_private(self.document.file) end)
        local r = orig(self, ...)
        if was_private and unlocked and S():isTrue("extra_security") then
            pending_lock = true
        end
        return r
    end
end)

-- History: private books are never recorded; they update the private "last book".
local ReadHistory = require("readhistory")
safe_wrap(ReadHistory, "addItem", function(orig)
    return function(self, file, ts, no_flush)
        if is_private(file) then
            if unlocked and not ts then
                G_reader_settings:saveSetting("lastfile", file)
                S():saveSetting("last_private_file", file)
                S():flush()
            end
            return
        end
        return orig(self, file, ts, no_flush)
    end
end)
safe_wrap(ReadHistory, "ensureLastFile", function(orig)
    return function(self, ...)
        if unlocked then
            local lp = S():readSetting("last_private_file")
            if lp then G_reader_settings:saveSetting("lastfile", lp) end
            return
        end
        orig(self, ...)
        local lf = G_reader_settings:readSetting("lastfile")
        if lf and is_private(lf) then
            G_reader_settings:saveSetting("lastfile", first_public_history_file())
        end
    end
end)
safe_wrap(ReadHistory, "updateLastBookTime", function(orig)
    return function(self, ...)
        local rui = ReaderUI.instance
        if rui and rui.document and is_private(rui.document.file) then return end
        return orig(self, ...)
    end
end)

-- Reading statistics: skip private books entirely.
userpatch.registerPatchPluginFunc("statistics", function(plugin)
    if plugin.__private_library_patched then return end
    plugin.__private_library_patched = true
    local orig = plugin.onReaderReady
    plugin.onReaderReady = function(self, config, ...)
        if self.document and is_private(self.document.file) then return end
        return orig(self, config, ...)
    end
end)

-- File browser: lock when leaving the private folder; never show it while locked.
local FileManager = require("apps/filemanager/filemanager")
safe_wrap(FileManager, "showFiles", function(orig)
    return function(self, path, focused_file, selected_files)
        if unlocked then pcall(hook_zen_home_view) end
        pcall(function()
            if pending_lock then
                lock(false)
                path, focused_file = home_dir(), nil
            elseif not unlocked and path and is_private(path) then
                path, focused_file = home_dir(), nil
            end
        end)
        local r = orig(self, path, focused_file, selected_files)
        -- Zen re-assigns its "go home" action while the library screen is being
        -- created, so hook again afterwards.
        if unlocked then pcall(hook_zen_home_view) end
        return r
    end
end)

-- When KOReader builds a file-browser menu (once per menu), add "Privacy" to the gear
-- tab if currently unlocked. Zen wraps setUpdateItemTable around this and keeps working.
local FileManagerMenu = require("apps/filemanager/filemanagermenu")
safe_wrap(FileManagerMenu, "setUpdateItemTable", function(orig)
    return function(self, ...)
        local r = orig(self, ...)
        pcall(sync_privacy_menu, self)
        return r
    end
end)
-- Same for the in-book menu (built once per opened book).
local ReaderMenu = require("apps/reader/modules/readermenu")
safe_wrap(ReaderMenu, "setUpdateItemTable", function(orig)
    return function(self, ...)
        local r = orig(self, ...)
        pcall(sync_privacy_menu, self)
        return r
    end
end)

local FileChooser = require("ui/widget/filechooser")
safe_wrap(FileChooser, "changeToPath", function(orig)
    return function(self, path, focused_path)
        if unlocked then pcall(hook_zen_home_view) end
        pcall(function()
            -- Lock rules apply to the library browser only, not to folder pickers
            -- (e.g. Privacy -> Private library folder -> Browse).
            local is_library = self.name == "filemanager"
            if pending_lock and is_library then
                lock(false)
                path, focused_path = home_dir(), nil
            elseif unlocked and is_library and path and not is_private(path) then
                lock(false) -- leaving the private folder (its home is the private folder) locks
            elseif not unlocked and path and is_private(path) then
                path, focused_path = home_dir(), nil
            end
        end)
        return orig(self, path, focused_path)
    end
end)

local listing_path
safe_wrap(FileChooser, "getPathList", function(orig)
    return function(self, path, ...)
        local prev = listing_path
        listing_path = path
        local ok, err = pcall(orig, self, path, ...)
        listing_path = prev
        if not ok then error(err) end
    end
end)
safe_wrap(FileChooser, "show_dir", function(orig)
    return function(self, dirname, ...)
        if not unlocked and dirname == private_name and listing_path and is_private_parent(listing_path) then
            return false
        end
        return orig(self, dirname, ...)
    end
end)

-- Sleep / power button: lock before the screensaver is set up.
local Screensaver = require("ui/screensaver")
safe_wrap(Screensaver, "setup", function(orig)
    return function(self, ...)
        if unlocked and not S():isTrue("power_lock_disabled") then
            local ok, err = pcall(lock_now)
            if not ok then logger.warn("SINdle lock on sleep:", err) end
        end
        return orig(self, ...)
    end
end)

-- Startup: never start pointing at a private book or folder (e.g. if the device
-- restarted while unlocked). Restore the real home folder first.
pcall(function()
    -- Code and fake error are mutually exclusive; if the settings file somehow has
    -- both on (e.g. edited by hand), keep the code (the safer one).
    if S():isTrue("fake_error") and not S():isTrue("code_disabled") then
        S():saveSetting("fake_error", false)
        S():flush()
    end
    restore_public_home()
    local lf = G_reader_settings:readSetting("lastfile")
    if lf and is_private(lf) then
        G_reader_settings:saveSetting("lastfile", first_public_history_file())
    end
    local ld = G_reader_settings:readSetting("lastdir")
    if ld and is_private(ld) then
        G_reader_settings:saveSetting("lastdir", home_dir())
    end
end)

end)

if not ok_patch then
    require("logger").warn("SINdle patch failed to load:", patch_err)
end
