--[[-------------------------------------------------------------------
  IRC  -  Instance Reset Counter   (TurtleWoW / 1.12)
  ------------------------------------------------------------------
  Tracks instance resets against the server's limit of 5 per hour.

  * Up to 5 timers, each counting down from 60:00 (MM:SS).
  * Reset 1 is always the OLDEST reset (shortest time left). When it
    reaches 0 it clears, the rest shift up, and slot 5 goes blank.
  * Each run tracks the raw coin looted during it; a "Lockout Total"
    line sums the coin across all five active timers.
  * Timers (and their coin) are stored as absolute clock timestamps,
    so they stay correct across logout / disconnect; if a timer
    should have expired while offline it shows "cleared" on login.
  * A timer is recorded only when a reset ACTUALLY succeeds (the game
    prints "<Instance> has been reset."), so a failed reset (someone
    still inside) starts no timer.
  * Sound + minimap flash when a reset slot frees up or the cap is hit.
  * Optionally announces resets to party/raid when you are the leader.
  * Everything runs from a minimap button - no slash commands.
---------------------------------------------------------------------]]

-- Guard against this file being executed more than once in a session (e.g. a
-- duplicate/backup addon folder in Interface\AddOns). A second load would
-- register a second set of handlers and double-count every reset and coin loot.
if IRC_LOADED then return end
IRC_LOADED = true

local RESET_DURATION = 3600   -- one hour, in seconds
local MAX_RESETS     = 5      -- server allows 5 resets per hour
local COALESCE       = 6      -- seconds; reset messages this close = one reset
local IRC_DEBUG      = true   -- TEMP: echoes any message containing "reset" to find the reset event

local GOLD_W   = GOLD   or "Gold"
local SILVER_W = SILVER or "Silver"
local COPPER_W = COPPER or "Copper"

IRC = {}
local LF = IRC
LF.rows = {}
LF.lastActive = nil           -- last known active-timer count (for alerts)

------------------------------------------------------------------
-- Data
------------------------------------------------------------------
local function EnsureDB()
  if not IRCDB then IRCDB = {} end
  if not IRCDB.resets then IRCDB.resets = {} end
  if not IRCDB.minimap then IRCDB.minimap = {} end
  if IRCDB.alerts == nil then IRCDB.alerts = true end
  if IRCDB.announce == nil then IRCDB.announce = true end
end

-- Reset entries are tables {t = timestamp, name = instanceName, coin = copper}.
-- Tolerate legacy numeric entries just in case.
local function tsOf(e)   if type(e) == "table" then return e.t else return e end end
local function nameOf(e) if type(e) == "table" then return e.name end return nil end
local function coinOf(e) if type(e) == "table" and e.coin then return e.coin else return 0 end end

-- Remove expired stamps, keep ascending order (oldest first), cap at MAX.
local function Prune()
  EnsureDB()
  local now = time()
  local kept = {}
  local src = IRCDB.resets
  for i = 1, table.getn(src) do
    if now - tsOf(src[i]) < RESET_DURATION then
      table.insert(kept, src[i])
    end
  end
  table.sort(kept, function(a, b) return tsOf(a) < tsOf(b) end)
  while table.getn(kept) > MAX_RESETS do
    table.remove(kept, 1)
  end
  IRCDB.resets = kept
  return kept
end

-- Returns true if a new reset was recorded, false if it duplicates the SAME
-- instance already logged within the last COALESCE seconds. De-dup is keyed on
-- the instance name so that one ResetInstances() call which resets several
-- different instances (e.g. LBRS and BWL) records each of them, while a repeated
-- message for the same instance is still ignored.
local function AddReset(name)
  EnsureDB()
  local list = IRCDB.resets
  local now = time()
  for i = 1, table.getn(list) do
    local e = list[i]
    if nameOf(e) == name and (now - tsOf(e)) < COALESCE then
      return false
    end
  end
  table.insert(list, { t = now, name = name, coin = 0 })
  Prune()
  return true
end

------------------------------------------------------------------
-- Helpers
------------------------------------------------------------------
local function FormatTime(sec)
  if sec < 0 then sec = 0 end
  local m = math.floor(sec / 60)
  local s = math.floor(math.mod(sec, 60))
  return string.format("%02d:%02d", m, s)
end

-- Copper -> "Xg YYs ZZc" (silver/copper zero-padded), coloured.
local function MoneyGSC(c)
  c = c or 0
  local g  = math.floor(c / 10000)
  local s  = math.floor(math.mod(c, 10000) / 100)
  local cc = math.mod(c, 100)
  return string.format("|cffffd700%dg|r |cffc7c7cf%02ds|r |cffeda55f%02dc|r", g, s, cc)
end

-- Pull a coin total (in copper) out of a CHAT_MSG_MONEY line.
local function ParseMoney(msg)
  local _, _, g = string.find(msg, "(%d+) " .. GOLD_W)
  local _, _, s = string.find(msg, "(%d+) " .. SILVER_W)
  local _, _, c = string.find(msg, "(%d+) " .. COPPER_W)
  return (tonumber(g) or 0) * 10000 + (tonumber(s) or 0) * 100 + (tonumber(c) or 0)
end

function LF:SetStatus(text)
  if text and text ~= "" then
    DEFAULT_CHAT_FRAME:AddMessage("|cff66ccffIRC:|r " .. text)
  end
end

------------------------------------------------------------------
-- Alerts (sound + minimap flash)
------------------------------------------------------------------
function LF:FlashButton()
  local mb = LF.minimapBtn
  if not mb then return end
  if not mb.flash then
    local f = mb:CreateTexture(nil, "OVERLAY")
    f:SetTexture("Interface\\Buttons\\CheckButtonHilight")
    f:SetBlendMode("ADD")
    f:SetWidth(34); f:SetHeight(34)
    f:SetPoint("CENTER", mb, "CENTER", 0, 0)
    mb.flash = f
  end
  if UIFrameFlash then
    UIFrameFlash(mb.flash, 0.3, 0.3, 2.4, false, 0, 0.3)
  end
end

-- Sound names for each alert (pcall-wrapped in case a name isn't valid here).
LF.SOUND_FREE = "TellMessage"
LF.SOUND_CAP  = "igQuestFailed"

-- Fire the effect unconditionally (used by both real alerts and the test button).
function LF:PlayAlert(kind)
  if kind == "cap" then
    pcall(PlaySound, LF.SOUND_CAP)
  else
    pcall(PlaySound, LF.SOUND_FREE)
  end
  LF:FlashButton()
end

function LF:Alert(kind)
  EnsureDB()
  if not IRCDB.alerts then return end
  LF:PlayAlert(kind)
  if kind == "free" then
    LF:SetStatus("|cff88ff88A reset slot is now free.|r")
  elseif kind == "cap" then
    LF:SetStatus("|cffffcc00Reset cap reached (" .. MAX_RESETS .. "/" .. MAX_RESETS .. ").|r")
  end
end

-- Manual preview from the menu; plays regardless of the Sound alerts toggle.
function LF:TestAlert()
  LF:PlayAlert("free")
  LF:SetStatus("Alert test - played sound \"" .. LF.SOUND_FREE .. "\" + flash. " ..
    "(Cap alert uses \"" .. LF.SOUND_CAP .. "\".) Heard nothing? Tell me and I'll swap the sound.")
end

------------------------------------------------------------------
-- Party/raid reset announcement (leader only)
------------------------------------------------------------------
function LF:Announce(name)
  EnsureDB()
  if not IRCDB.announce then return end
  local channel
  if GetNumRaidMembers() > 0 then
    if IsRaidLeader() or IsRaidOfficer() then channel = "RAID" end
  elseif GetNumPartyMembers() > 0 then
    if IsPartyLeader() then channel = "PARTY" end
  end
  if channel then
    SendChatMessage((name or "Instance") .. " was reset.", channel)
  end
end

------------------------------------------------------------------
-- Coin looted -> attribute to the newest (current) reset slot.
------------------------------------------------------------------
function LF:OnMoney(msg)
  if not msg then return end
  local amt = ParseMoney(msg)
  if amt <= 0 then return end
  -- If the client supports it, only count coin looted while inside an instance.
  if type(IsInInstance) == "function" and not IsInInstance() then return end
  local list = Prune()
  local n = table.getn(list)
  if n == 0 then return end
  local e = list[n]
  if type(e) == "table" then e.coin = (e.coin or 0) + amt end
  if LF.menu and LF.menu:IsShown() then LF:UpdateDisplay() end
end

------------------------------------------------------------------
-- Display
------------------------------------------------------------------
function LF:UpdateDisplay()
  if not LF.rows[1] then return end
  local list = Prune()
  local now = time()
  local count = table.getn(list)
  local total = 0
  for i = 1, MAX_RESETS do
    local fs = LF.rows[i]
    if i <= count then
      local e = list[i]
      local rem = RESET_DURATION - (now - tsOf(e))
      local coin = coinOf(e)
      total = total + coin
      fs:SetText("|cffffffffReset " .. i .. ":|r |cff33ff99" .. FormatTime(rem) .. "|r - " .. MoneyGSC(coin))
    else
      fs:SetText("|cff777777Reset " .. i .. ": cleared|r")
    end
  end
  if LF.totalText then
    LF.totalText:SetText("|cffffd100Lockout Total|r - " .. MoneyGSC(total))
  end
  if LF.alertsLabel then
    LF.alertsLabel:SetText((IRCDB.alerts and "|cff33ff99[x]|r " or "|cff777777[  ]|r ") .. "Sound alerts")
  end
  if LF.announceLabel then
    LF.announceLabel:SetText((IRCDB.announce and "|cff33ff99[x]|r " or "|cff777777[  ]|r ") .. "Announce resets")
  end
end

------------------------------------------------------------------
-- Actions
------------------------------------------------------------------
function LF:DoDungeonReset()
  local list = Prune()
  local count = table.getn(list)
  ResetInstances()
  if count >= MAX_RESETS then
    local nextFree = RESET_DURATION - (time() - tsOf(list[1]))
    LF:SetStatus("|cffff5555At " .. MAX_RESETS .. "/" .. MAX_RESETS .. ".|r Next: " .. FormatTime(nextFree))
  else
    LF:SetStatus("|cffcccc88Reset sent - awaiting confirm...|r")
  end
  LF:UpdateDisplay()
end

function LF:ResetAllTimers()
  EnsureDB()
  IRCDB.resets = {}
  LF.lastActive = 0
  LF:SetStatus("|cffcccc88All timers cleared.|r")
  LF:UpdateDisplay()
end

-- Watch the system channel for reset confirmation.
function LF:OnSystemMessage(msg)
  if not msg then return end
  if string.find(msg, "has been reset") then
    local _, _, nm = string.find(msg, "^(.+) has been reset")
    if AddReset(nm) then
      LF:Announce(nm)
      local label = nm or "Instance"
      LF:SetStatus("|cff88ff88" .. label .. " reset (" .. table.getn(IRCDB.resets) .. "/" .. MAX_RESETS .. ")|r")
      LF:UpdateDisplay()
    end
  elseif string.find(msg, "still inside") then
    LF:SetStatus("|cffff5555Reset failed:|r players still inside.")
  elseif string.find(msg, "currently in that instance") then
    LF:SetStatus("|cffff5555Reset failed:|r someone is in there.")
  end
end

------------------------------------------------------------------
-- Minimap button position
------------------------------------------------------------------
function LF:UpdateMinimapPosition()
  EnsureDB()
  local x = IRCDB.minimap.x or -69
  local y = IRCDB.minimap.y or -40
  if LF.minimapBtn then
    LF.minimapBtn:ClearAllPoints()
    LF.minimapBtn:SetPoint("CENTER", Minimap, "CENTER", x, y)
  end
end

------------------------------------------------------------------
-- Menu show / hide
------------------------------------------------------------------
function LF:ShowMenu()
  local m = LF.menu
  if not m then return end
  local mb = LF.minimapBtn
  local bx = mb:GetCenter()
  local sw = UIParent:GetWidth()
  m:ClearAllPoints()
  if bx and sw and bx > (sw / 2) then
    m:SetPoint("TOPRIGHT", mb, "TOPLEFT", -4, 4)
  else
    m:SetPoint("TOPLEFT", mb, "TOPRIGHT", 4, 4)
  end
  if LF.catcher then LF.catcher:Show() end
  m:Show()
  LF:UpdateDisplay()
end

function LF:HideMenu()
  if LF.menu then LF.menu:Hide() end
  if LF.catcher then LF.catcher:Hide() end
end

function LF:ToggleMenu()
  if LF.menu and LF.menu:IsShown() then LF:HideMenu() else LF:ShowMenu() end
end

------------------------------------------------------------------
-- UI construction
------------------------------------------------------------------
local function CreateUI()
  -- Full-screen click-catcher (closes the menu on an outside click)
  local catcher = CreateFrame("Frame", "IRCCatcher", UIParent)
  catcher:SetAllPoints(UIParent)
  catcher:SetFrameStrata("FULLSCREEN_DIALOG")
  catcher:EnableMouse(true)
  local ctex = catcher:CreateTexture(nil, "BACKGROUND")
  ctex:SetAllPoints(catcher)
  ctex:SetTexture(0, 0, 0, 0)
  catcher:Hide()
  catcher:SetScript("OnMouseDown", function() LF:HideMenu() end)
  LF.catcher = catcher

  -- Menu frame (dropdown / Dewdrop style)
  local m = CreateFrame("Frame", "IRCMenu", UIParent)
  m:SetWidth(180)
  m:SetHeight(300)
  m:SetFrameStrata("TOOLTIP")
  m:EnableMouse(true)
  m:SetBackdrop({
    bgFile   = "Interface\\Tooltips\\UI-Tooltip-Background",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true, tileSize = 16, edgeSize = 16,
    insets = { left = 5, right = 5, top = 5, bottom = 5 },
  })
  m:SetBackdropColor(0.06, 0.06, 0.08, 0.94)
  m:SetBackdropBorderColor(1, 0.85, 0.40)
  m:Hide()
  LF.menu = m

  local function Sep(yy)
    local t = m:CreateTexture(nil, "ARTWORK")
    t:SetTexture(0.55, 0.48, 0.28, 0.7)
    t:SetHeight(1)
    t:SetPoint("LEFT", m, "LEFT", 8, 0)
    t:SetPoint("RIGHT", m, "RIGHT", -8, 0)
    t:SetPoint("TOP", m, "TOP", 0, yy)
  end

  local function TextRow(yy, tmpl)
    local fs = m:CreateFontString(nil, "OVERLAY", tmpl or "GameFontHighlight")
    fs:SetJustifyH("LEFT")
    fs:SetPoint("LEFT", m, "LEFT", 14, 0)
    fs:SetPoint("RIGHT", m, "RIGHT", -8, 0)
    fs:SetPoint("TOP", m, "TOP", 0, yy)
    return fs
  end

  local function ActionRow(yy, label, fn)
    local b = CreateFrame("Button", nil, m)
    b:SetHeight(16)
    b:SetPoint("LEFT",  m, "LEFT",  6, 0)
    b:SetPoint("RIGHT", m, "RIGHT", -6, 0)
    b:SetPoint("TOP",   m, "TOP",  0, yy)
    b:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
    local hlt = b:GetHighlightTexture()
    if hlt then hlt:SetBlendMode("ADD"); hlt:SetVertexColor(1, 0.9, 0.4) end
    local fs = b:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    fs:SetPoint("LEFT", b, "LEFT", 8, 0)
    fs:SetText(label)
    b:SetScript("OnClick", fn)
    return b, fs
  end

  local cy = -9
  local title = m:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  title:SetPoint("TOP", m, "TOP", 0, cy)
  title:SetText("|cffffd100IRC|r")
  cy = cy - 20

  Sep(cy); cy = cy - 8

  for i = 1, MAX_RESETS do
    LF.rows[i] = TextRow(cy)
    LF.rows[i]:SetText("|cff777777Reset " .. i .. ": cleared|r")
    cy = cy - 16
  end

  LF.totalText = TextRow(cy - 1)
  LF.totalText:SetText("|cffffd100Lockout Total|r - " .. MoneyGSC(0))
  cy = cy - 20

  Sep(cy); cy = cy - 8

  local _, fsRD = ActionRow(cy, "Reset Dungeon",    function() LF:DoDungeonReset() end); cy = cy - 18
  local _, fsRA = ActionRow(cy, "Reset All Timers", function() LF:ResetAllTimers() end); cy = cy - 20

  Sep(cy); cy = cy - 8

  local _, fsAL = ActionRow(cy, "Sound alerts", function()
    IRCDB.alerts = not IRCDB.alerts; LF:UpdateDisplay()
  end); LF.alertsLabel = fsAL; cy = cy - 18

  -- Test alert button (disabled for now; uncomment this + the fsTS width line
  -- below to bring it back, and it will slot in above "Announce resets"):
  --local _, fsTS = ActionRow(cy, "Test alert", function() LF:TestAlert() end); cy = cy - 18

  local _, fsAN = ActionRow(cy, "Announce resets", function()
    IRCDB.announce = not IRCDB.announce; LF:UpdateDisplay()
  end); LF.announceLabel = fsAN; cy = cy - 20

  Sep(cy); cy = cy - 8

  local _, fsCL = ActionRow(cy, "Close", function() LF:HideMenu() end); cy = cy - 18

  -- Height from the running cursor.
  m:SetHeight((-cy) + 6)

  -- Width: size to the widest line so there's no wasted space.
  local maxw = 0
  local function fit(w) if w and w > maxw then maxw = w end end
  fit(title:GetStringWidth())
  local probe = m:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  probe:SetText("Reset 1: 00:00 - 999g 99s 99c"); fit(probe:GetStringWidth())
  probe:SetText("Lockout Total - 9999g 99s 99c"); fit(probe:GetStringWidth())
  probe:Hide()
  fit(fsRD:GetStringWidth()); fit(fsRA:GetStringWidth())
  fit(fsAL:GetStringWidth()) --; fit(fsTS:GetStringWidth())
  fit(fsAN:GetStringWidth()); fit(fsCL:GetStringWidth())
  local w = maxw + 26
  if w < 160 then w = 160 end
  m:SetWidth(w)

  -- Tick the countdown while the menu is open.
  local acc = 0
  m:SetScript("OnUpdate", function()
    acc = acc + arg1
    if acc >= 0.25 then acc = 0; LF:UpdateDisplay() end
  end)

  ----------------------------------------------------------------
  -- Minimap button
  ----------------------------------------------------------------
  local mb = CreateFrame("Button", "IRCMinimapButton", Minimap)
  mb:SetWidth(31); mb:SetHeight(31)
  mb:SetFrameStrata("MEDIUM")
  mb:SetFrameLevel(8)
  mb:RegisterForClicks("LeftButtonUp")
  mb:RegisterForDrag("LeftButton")
  mb:SetMovable(true)
  LF.minimapBtn = mb

  local icon = mb:CreateTexture(nil, "BACKGROUND")
  icon:SetTexture("Interface\\Icons\\Spell_Nature_NatureTouchGrow")
  icon:SetWidth(20); icon:SetHeight(20)
  icon:SetPoint("CENTER", mb, "CENTER", 0, 0)

  local overlay = mb:CreateTexture(nil, "OVERLAY")
  overlay:SetWidth(53); overlay:SetHeight(53)
  overlay:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
  overlay:SetPoint("TOPLEFT", mb, "TOPLEFT", 0, 0)

  local function DragUpdate()
    local px, py = GetCursorPosition()
    local scale = Minimap:GetEffectiveScale()
    px = px / scale
    py = py / scale
    local cx, cyy = Minimap:GetCenter()
    local dx, dy = px - cx, py - cyy
    local dist = math.sqrt(dx * dx + dy * dy)
    if dist < 1 then dist = 1 end
    local r = 80
    IRCDB.minimap.x = (dx / dist) * r
    IRCDB.minimap.y = (dy / dist) * r
    LF:UpdateMinimapPosition()
  end

  mb:SetScript("OnClick", function() LF:ToggleMenu() end)
  mb:SetScript("OnDragStart", function()
    LF:HideMenu()
    this:SetScript("OnUpdate", DragUpdate)
  end)
  mb:SetScript("OnDragStop", function()
    this:SetScript("OnUpdate", nil)
  end)
  mb:SetScript("OnEnter", function()
    if not (LF.menu and LF.menu:IsShown()) then
      GameTooltip:SetOwner(this, "ANCHOR_LEFT")
      GameTooltip:AddLine("IRC - Instance Reset Counter")
      GameTooltip:AddLine("Left-click: menu", 1, 1, 1)
      GameTooltip:AddLine("Drag: move button", 0.7, 0.7, 0.7)
      GameTooltip:Show()
    end
  end)
  mb:SetScript("OnLeave", function() GameTooltip:Hide() end)

  LF:UpdateMinimapPosition()
end

------------------------------------------------------------------
-- Event driver + alert ticker
------------------------------------------------------------------
local driver = CreateFrame("Frame")
driver:RegisterEvent("ADDON_LOADED")
driver:RegisterEvent("PLAYER_ENTERING_WORLD")
driver:RegisterEvent("CHAT_MSG_SYSTEM")
driver:RegisterEvent("CHAT_MSG_MONEY")
driver:SetScript("OnEvent", function()
  if event == "ADDON_LOADED" then
    if arg1 == "IRC" then
      EnsureDB()
      CreateUI()
      Prune()
      LF:UpdateDisplay()
    end
  elseif event == "PLAYER_ENTERING_WORLD" then
    local list = Prune()
    LF.lastActive = table.getn(list)   -- baseline; no alert for offline expiry
    LF:UpdateDisplay()
  elseif event == "CHAT_MSG_SYSTEM" then
    LF:OnSystemMessage(arg1)
  elseif event == "CHAT_MSG_MONEY" then
    LF:OnMoney(arg1)
  end
end)

-- ~1s ticker: prune, fire alerts on slot-free / cap transitions.
local tickAcc = 0
driver:SetScript("OnUpdate", function()
  tickAcc = tickAcc + arg1
  if tickAcc < 1 then return end
  tickAcc = 0
  local active = table.getn(Prune())
  if LF.lastActive ~= nil then
    if active < LF.lastActive then
      LF:Alert("free")
    elseif active > LF.lastActive and active >= MAX_RESETS then
      LF:Alert("cap")
    end
  end
  LF.lastActive = active
  if LF.menu and LF.menu:IsShown() then LF:UpdateDisplay() end
end)

------------------------------------------------------------------
-- TEMP diagnostic: echo any message containing "reset" with its event,
-- so we can see exactly how this client delivers the reset confirmation.
-- Remove (set IRC_DEBUG = false) once resets are confirmed recording.
------------------------------------------------------------------
if IRC_DEBUG then
  local dbg = CreateFrame("Frame")
  local events = {
    "CHAT_MSG_SYSTEM",
    "CHAT_MSG_RAID_WARNING",
    "CHAT_MSG_RAID_BOSS_EMOTE",
    "CHAT_MSG_MONSTER_EMOTE",
    "CHAT_MSG_MONSTER_YELL",
    "CHAT_MSG_MONSTER_SAY",
    "CHAT_MSG_CHANNEL_NOTICE",
    "UI_ERROR_MESSAGE",
  }
  for i = 1, table.getn(events) do
    pcall(function() dbg:RegisterEvent(events[i]) end)
  end
  dbg:SetScript("OnEvent", function()
    if arg1 and string.find(string.lower(arg1), "reset") then
      DEFAULT_CHAT_FRAME:AddMessage("|cffff9900IRC-DBG|r [" .. tostring(event) .. "] " .. arg1)
    end
  end)
end
