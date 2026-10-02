--[[
SINdle - a hidden private library for KOReader
-----------------------------------------------
A boring-looking decoy book in your normal library is the way in. Opening it asks
for your passcode (or shows a fake "could not load" error with a secret double-tap).
Then KOReader's library switches to a private folder (default: koreader/system).

* Private books never show up in history, Continue (for the normal library),
  reading statistics, or the file browser while locked.
* Locks on: power button / sleep, Home, "Lock now", restarting KOReader,
  and optionally when closing a private book. "Lock now" is also a gesture /
  quick menu action.
* First run: if your library has no decoy book yet, one is created for you
  ("The Extensive Analysis of the Color Brown", with its cover).
* Settings: top menu -> gear tab -> Privacy (only visible while unlocked, in the
  library and inside private books).
* Passcode and settings: koreader/settings/private-code (delete to reset).lua
  Delete that file from a computer to reset a forgotten passcode.
* Works with the ZenOS/Zen UI and Bookshelf plugins, and without them.

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

-- ---------------------------------------------------------------- Bookshelf plugin
-- Bookshelf replaces the library screen with its own shelf view, built from the home
-- folder (so while unlocked its main shelf IS the private library). It keeps its own
-- folder drill-down, current-book card and caches, so on every lock/unlock those are
-- reset here. Nothing in Bookshelf itself is changed; all of this is a no-op without it.
local BS_WIDGET = "lib/bookshelf_widget"
local BS_REPO   = "lib/bookshelf_book_repository"
local BS_PARK   = "lib/bookshelf_reader_park"
local BS_TABS   = "lib/bookshelf_tab_model"
local bs_defer  = false -- a book is about to open: refresh the shelf when it is shown again

local function bs_live()
    local BW = package.loaded[BS_WIDGET]
    local w = type(BW) == "table" and BW.live or nil
    if w and UIManager:isWidgetShown(w) then return w end
end

-- Is the shelf actually visible (not covered by an open book)?
local function bs_visible(w)
    local stack = UIManager._window_stack
    if not (w and type(stack) == "table") then return false end
    local rui = require("apps/reader/readerui").instance
    local w_idx, r_idx
    for i, entry in ipairs(stack) do
        if entry.widget == w then w_idx = i end
        if rui and entry.widget == rui then r_idx = i end
    end
    return w_idx ~= nil and (r_idx == nil or w_idx > r_idx)
end

-- Cheap test first: a path can only be private if it contains the folder's name.
local function maybe_private(p)
    return type(p) == "string" and private_name ~= nil and p:find(private_name, 1, true) ~= nil
        and is_private(p)
end

-- Back to the top of the shelf, forget everything cached about the old library.
-- to_home_tab: also switch to Bookshelf's "Home" tab (used on unlock, so the private
-- library is what appears).
local function bookshelf_sync(to_home_tab)
    local Repo = package.loaded[BS_REPO]
    if type(Repo) == "table" and type(Repo.invalidateWalkCache) == "function" then
        pcall(Repo.invalidateWalkCache)
    end
    local BW = package.loaded[BS_WIDGET]
    if type(BW) ~= "table" then return end
    local w = BW.live
    if not w then
        BW.go_home_pending = true -- the next shelf starts at the top, not in a saved folder
        return
    end
    w._drilldown_path = {}
    w._pending_restore_drill = nil
    w._preview_book = nil
    w._hero_current_memo = nil
    w._hero_book_cache = nil
    w._spine_fetch_cache = nil -- the spine view's own shelf list (kept ~30 s)
    w._cursor = 1
    if to_home_tab then
        local ok, TabModel = pcall(require, BS_TABS)
        local tab = ok and type(TabModel) == "table" and TabModel.getById and TabModel.getById("all")
        if tab and tab.enabled ~= false then w.chip = "all" end
    end
    if w._syncPageFromCursor then pcall(w._syncPageFromCursor, w) end
    if not bs_defer and UIManager:isWidgetShown(w) and bs_visible(w) then
        w.__sindle_stale = nil
        local ok, err = pcall(w._rebuild, w)
        if not ok then logger.warn("SINdle: shelf rebuild failed:", err) end
        UIManager:setDirty(w, "ui")
    else
        w.__sindle_stale = true
    end
end

-- A tap on the decoy (or a refused private book) never opens a reader, but Bookshelf
-- has already started its "opening" animation and paused its clock: undo both.
local function bookshelf_after_refused_open()
    local w = bs_live()
    if not (w and bs_visible(w)) then return end
    w._opened_book = false
    w._seamless_open_full_pending = nil
    if w._startStatusTimer then pcall(w._startStatusTimer, w) end
    UIManager:setDirty(w, "ui")
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
        if bs_live() then
            -- Under Bookshelf the browser is hidden; navigating it would make the
            -- shelf drill into that folder. Just point it home.
            fc.path = home_dir()
        else
            fc:changeToPath(home_dir())
        end
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
    pcall(bookshelf_sync, false)
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
    if bs_live() then
        -- Bookshelf: its main shelf now shows the (private) home folder.
        if fm and fm.file_chooser then fm.file_chooser.path = private_dir end
        bookshelf_sync(true)
        return
    end
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
    pin_dialog("Choose a passcode: 4-8 letters/numbers", function(pin1)
        if not valid_pin(pin1) then
            UIManager:show(require("ui/widget/infomessage"):new{ text = "Use 4-8 letters or numbers.", timeout = 2 })
            return
        end
        pin_dialog("Repeat the passcode", function(pin2)
            if norm_code(pin1) ~= norm_code(pin2) then
                UIManager:show(require("ui/widget/infomessage"):new{ text = "Passcodes did not match.", timeout = 2 })
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

-- Last gate before the private library: the passcode (if "Require passcode" is on).
local function enter_private()
    if unlocked then unlock() return end
    if not code_required() then unlock() return end
    if not S():readSetting("pin_hash") then
        set_new_pin(unlock)
        return
    end
    pin_dialog("Enter passcode", function(pin)
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

-- "Require passcode" and "Show fake error" are mutually exclusive: one protection at a
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
        confirm("Turn off the passcode?\n\nAnyone who opens the decoy book will get into your private library.",
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
        confirm("Turn off the fake error?\n\nThe passcode is also off, so anyone who opens the decoy book will get into your private library. (Turn on \"Require passcode\" instead to keep it protected.)",
            "Turn off", function() set_protection(false, false); refresh() end)
    else
        confirm("Turn on the fake error?\n\nThis turns off the passcode: the secret double-tap on the error box will open your private library directly.",
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

local function privacy_menu_items()
    local items = {
        {
            text = "Require passcode",
            checked_func = code_required,
            check_callback_updates_menu = true, -- turning it off asks first
            callback = function(touchmenu) toggle_code_required(touchmenu) end,
        },
        {
            text = "Show fake error when the decoy is opened",
            help_text = "Instead of a passcode: opening the decoy shows \"Error, could not load book\". X, OK or tapping outside closes it. Tap the empty top-right corner of the box twice quickly to open the private library. Turning this on turns the passcode off, and vice versa.",
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
            text = "Lock on power button / sleep",
            checked_func = function() return not S():isTrue("power_lock_disabled") end,
            callback = function()
                S():flipNilOrFalse("power_lock_disabled"); S():flush()
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
            text = "Change passcode",
            callback = function()
                set_new_pin(function()
                    UIManager:show(require("ui/widget/infomessage"):new{ text = "Passcode changed.", timeout = 2 })
                end)
            end,
        },
        {
            text = "Lock now", -- inside a private book: closes it and goes to the normal library
            callback = function() UIManager:nextTick(lock_now) end, -- after the menu closes
        },
    }
    -- Bookshelf has no Home button, so the Home setting is only shown without it.
    if not bs_live() then
        table.insert(items, 5, { -- after "Extra security"
            text = "Home button returns to the public library",
            help_text = "On: Home locks the private library and takes you to your normal Home/library. Off: Home keeps you in the private library (unless Extra security is on).",
            checked_func = function() return not S():isTrue("home_stays_private") end,
            callback = function()
                S():flipNilOrFalse("home_stays_private"); S():flush()
            end,
        })
    end
    return items
end

local function privacy_menu_item()
    return { text = "Privacy", sub_item_table_func = privacy_menu_items }
end

local privacy_item -- one shared table, so it can be found and removed again
-- Library menu: shown whenever unlocked. Reader menu: only inside a private book,
-- while unlocked.
sync_privacy_menu = function(menu)
    if not (menu and type(menu.tab_item_table) == "table") then return end
    local doc = menu.ui and menu.ui.document
    local want
    if doc then
        want = unlocked and is_private(doc.file)
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
-- Plugin event handlers are callable tables (KOReader wraps them to catch errors).
local function callable(v)
    if type(v) == "function" then return true end
    local mt = type(v) == "table" and getmetatable(v)
    return type(mt) == "table" and mt.__call ~= nil
end

local function safe_wrap(tbl, name, make)
    if type(tbl) ~= "table" or not callable(tbl[name]) then
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
                bs_defer = true
                lock(false)
                bs_defer = false
                quiet_reset_browser()
            end
        end)
        bs_defer = false
        if not ok then logger.warn("SINdle showReader:", err) end
        if handled then
            -- Zen shows an "Opening" banner as soon as a book is tapped and removes it
            -- when the book has opened. This book never opens, so cancel it now
            -- (otherwise it lingers ~10 s). No-op without Zen.
            local cancel_banner = rawget(_G, "__ZEN_UI_CANCEL_OPENING_BANNER")
            if type(cancel_banner) == "function" then pcall(cancel_banner, true) end
            pcall(bookshelf_after_refused_open)
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

-- Bookshelf plugin (see "Bookshelf plugin" above). Its modules load lazily, so each is
-- hooked once, as soon as it is available.
local function hook_bookshelf_modules()
    local BW = package.loaded[BS_WIDGET]
    if type(BW) == "table" and not rawget(BW, "__sindle") then
        rawset(BW, "__sindle", true)
        -- Never restore a saved drill-down into the private folder while locked
        -- (Bookshelf remembers the folder it showed across restarts).
        safe_wrap(BW, "_restoreDrillPath", function(orig)
            return function(self, saved, ...)
                if not unlocked and type(saved) == "table" then
                    local kept = {}
                    for _, e in ipairs(saved) do
                        if type(e) == "table" and maybe_private(e.path) then break end
                        kept[#kept + 1] = e
                    end
                    saved = kept
                end
                return orig(self, saved, ...)
            end
        end)
        safe_wrap(BW, "_expandFolder", function(orig)
            return function(self, folder, ...)
                if not unlocked and type(folder) == "table" and maybe_private(folder.path) then return end
                return orig(self, folder, ...)
            end
        end)
        -- Last line of defence: nothing private on any shelf while locked.
        safe_wrap(BW, "_fetchChipItems", function(orig)
            return function(self, ...)
                local items, hint = orig(self, ...)
                if not unlocked and type(items) == "table" then
                    local kept = {}
                    for _, it in ipairs(items) do
                        local p = type(it) == "table" and (it.filepath or (it.kind == "folder" and it.path))
                        if not maybe_private(p) then kept[#kept + 1] = it end
                    end
                    items = kept
                end
                return items, hint
            end
        end)
        safe_wrap(BW, "_openBook", function(orig)
            return function(self, book, ...)
                if not unlocked and type(book) == "table" and maybe_private(book.filepath) then return end
                return orig(self, book, ...)
            end
        end)
        -- After a lock/unlock that happened while a book covered the shelf, the
        -- quick refresh on return is not enough: rebuild from the top.
        safe_wrap(BW, "softRefresh", function(orig)
            return function(self, ...)
                if self.__sindle_stale then
                    self.__sindle_stale = nil
                    self:_rebuild()
                    UIManager:setDirty(self, "ui")
                    return
                end
                return orig(self, ...)
            end
        end)
        BW.onSINdleLockNow = function() pcall(lock_now) return true end
    end
    local Repo = package.loaded[BS_REPO]
    if type(Repo) == "table" and not rawget(Repo, "__sindle") then
        rawset(Repo, "__sindle", true)
        -- The big "current book" card follows lastfile; never a private one while locked.
        safe_wrap(Repo, "currentFilepath", function(orig)
            return function(...)
                local fp = orig(...)
                if not unlocked and maybe_private(fp) then return nil end
                return fp
            end
        end)
    end
    local Park = package.loaded[BS_PARK]
    if type(Park) == "table" and not rawget(Park, "__sindle") then
        rawset(Park, "__sindle", true)
        -- "Hot parking" keeps a closed book open under the shelf for a quick return.
        -- Never for a private book: it is really closed, so it can't come back after a lock.
        safe_wrap(Park, "park", function(orig)
            return function(plugin, ...)
                local doc = type(plugin) == "table" and plugin.ui and plugin.ui.document
                if doc and is_private(doc.file) then return false end
                return orig(plugin, ...)
            end
        end)
    end
end

userpatch.registerPatchPluginFunc("bookshelf", function(plugin)
    pcall(require, BS_PARK)
    pcall(hook_bookshelf_modules)
    if rawget(plugin, "__sindle") then return end
    rawset(plugin, "__sindle", true)
    -- The shelf's widget module loads on first show: hook it before it is used.
    safe_wrap(plugin, "show", function(orig)
        return function(self, ...)
            pcall(require, BS_WIDGET)
            pcall(require, BS_REPO)
            pcall(hook_bookshelf_modules)
            return orig(self, ...)
        end
    end)
    -- "Bookshelf: go to home screen" counts as Home.
    safe_wrap(plugin, "onBookshelfGoHome", function(orig)
        return function(self, ...)
            lock_for_home()
            return orig(self, ...)
        end
    end)
end)

-- "Lock now" as an action for gestures / the quick menu (works with any home screen).
pcall(function()
    require("dispatcher"):registerAction("sindle_lock_now", {
        category = "none",
        event    = "SINdleLockNow",
        title    = "Lock now",
        general  = true,
    })
end)
local function on_lock_now_event() pcall(lock_now) return true end

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
FileManager.onSINdleLockNow = on_lock_now_event
ReaderUI.onSINdleLockNow = on_lock_now_event

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

-- ---------------------------------------------------------------- decoy book
-- Installing the patch alone (e.g. from Storefront) brings no decoy book, so on first
-- run SINdle writes one into the normal library: "The Extensive Analysis of the Color
-- Brown" as an FB2 file, with its cover embedded below as base64 image data.
-- Done once only; never if a decoy already exists or a custom decoy is chosen.
local DECOY_FILENAME = "The Extensive Analysis of the Color Brown - H. R. Umber.fb2"
local DECOY_CHAPTERS = { -- { title, paragraph, times repeated }
    { "Preface",
      "This volume is the first of four. It concerns itself solely with the color brown, and in particular with the many shades that lie between tan and umber. No illustrations are included, at the request of the publisher, who felt that the reader would benefit from imagining each shade unaided.", 6 },
    { "Chapter One: On the Definition of Brown",
      "Brown is a composite color. It may be produced by combining red, yellow, and black, or by darkening orange. The author has spent some years considering whether brown should properly be called a color at all, or merely a condition of other colors. The conclusion, set out over the following two hundred pages, is that it should.", 6 },
    { "Chapter Two: Umber, Raw and Burnt",
      "Raw umber is a natural earth pigment containing iron oxide and manganese oxide. When heated, it becomes burnt umber, which is warmer and more reddish. The difference between the two is subtle and will be discussed at considerable length, beginning with the composition of the soils of central Italy.", 6 },
    { "Chapter Three: Sepia",
      "Sepia was originally obtained from the ink sac of the cuttlefish. Its tone is cooler than umber. Several pages that follow compare sepia samples collected over a period of eleven years; the differences recorded are, the author admits, very small.", 6 },
    { "Chapter Four: Brown in Furniture",
      "Most furniture is brown. This chapter catalogues, in alphabetical order, the varieties of wood stain commercially available in the year of writing, together with notes on their drying times.", 6 },
}
-- Decoy cover: 600x900 JPEG, base64 (image data, not code)
local DECOY_COVER_B64 = [[
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
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAB/9k=
]]

local function build_decoy_fb2()
    local esc = function(s)
        return (s:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"))
    end
    local out = {
        '<?xml version="1.0" encoding="UTF-8"?>',
        '<FictionBook xmlns="http://www.gribuser.ru/xml/fictionbook/2.0" xmlns:l="http://www.w3.org/1999/xlink">',
        "<description><title-info>",
        "<genre>sci_tech</genre>",
        "<author><first-name>H. R.</first-name><last-name>Umber</last-name></author>",
        "<book-title>The Extensive Analysis of the Color Brown: The Non-Illustrated Edition</book-title>",
        "<annotation><p>Volume I of IV. Concerned solely with the color brown.</p></annotation>",
        '<coverpage><image l:href="#cover.jpg"/></coverpage>',
        "<lang>en</lang>",
        "</title-info><document-info>",
        "<author><nickname>H. R. Umber</nickname></author>",
        "<date>2000-01-01</date><id>the-extensive-analysis-of-the-color-brown-1</id><version>1.0</version>",
        "</document-info></description>",
        "<body><title><p>The Extensive Analysis of the Color Brown</p></title>",
    }
    for _, ch in ipairs(DECOY_CHAPTERS) do
        out[#out + 1] = "<section><title><p>" .. esc(ch[1]) .. "</p></title>"
        for _ = 1, ch[3] do
            out[#out + 1] = "<p>" .. esc(ch[2]) .. "</p>"
        end
        out[#out + 1] = "</section>"
    end
    out[#out + 1] = "</body>"
    out[#out + 1] = '<binary id="cover.jpg" content-type="image/jpeg">' .. DECOY_COVER_B64 .. "</binary>"
    out[#out + 1] = "</FictionBook>"
    return table.concat(out, "\n")
end

-- Is there already a decoy (default name) in the library? Looks two folders deep.
local function find_existing_decoy(dir, depth)
    local ok, iter, dir_obj = pcall(lfs.dir, dir)
    if not ok then return false end
    for name in iter, dir_obj do
        if name ~= "." and name ~= ".." and name:sub(1, 1) ~= "." and not name:match("%.sdr$") then
            local full = dir .. "/" .. name
            local mode = lfs.attributes(full, "mode")
            if mode == "file" and name:find(DECOY_MATCH, 1, true) then
                return true
            elseif mode == "directory" and depth > 0 and not is_private(full)
                    and find_existing_decoy(full, depth - 1) then
                return true
            end
        end
    end
    return false
end

local function ensure_decoy_book()
    if S():isTrue("decoy_installed") then return end
    local home = home_dir()
    if not home or lfs.attributes(home, "mode") ~= "directory" or is_private(home) then return end
    local custom = S():readSetting("decoy_path")
    if not ((type(custom) == "string" and lfs.attributes(custom, "mode") == "file")
            or find_existing_decoy(home, 2)) then
        local fh = io.open(home .. "/" .. DECOY_FILENAME, "wb")
        if not fh then return end
        fh:write(build_decoy_fb2())
        fh:close()
    end
    S():saveSetting("decoy_installed", true)
    S():flush()
end

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

-- First run: make sure a decoy book exists in the normal library.
pcall(ensure_decoy_book)

end)

if not ok_patch then
    require("logger").warn("SINdle patch failed to load:", patch_err)
end
