local addonName, addon = ...

-- ---------------------------------------------------------------------------
-- CenterStage
-- ---------------------------------------------------------------------------
-- Blizzard's UIPanel manager lays the system windows (character pane, map,
-- LFG, merchant, ...) out between two boundaries, stored as attributes on
-- UIParent on Classic Era, TBC Anniversary and retail through 12.0.x, and on
-- UIPanelLayoutFrame on retail from 12.1 and on WoW Forever:
--
--   LEFT_OFFSET (16px)        -- the origin every layout pass anchors from;
--                                CENTER_OFFSET / RIGHT_OFFSET derive from it.
--   RIGHT_OFFSET_BUFFER (80px) -- reserve at the right edge; GetMaxUIPanelsWidth
--                                (UIParent right minus this) is what every
--                                "does another window fit" capacity check
--                                (CanShowRightUIPanel / CanShowCenterUIPanel /
--                                CanShowUIPanels) compares against.
--
-- On ultrawide monitors those defaults pin every window to the far left and
-- let the dock sprawl across the entire width. CenterStage moves both
-- boundaries to confine the dock to a centered band of configurable width,
-- defaulting to the center 16:9 slice of the screen (50% on 32:9, ~74% on
-- 21:9). Blizzard's secure FramePositionDelegate keeps
-- doing 100% of the layout itself -- spacing, pushing, sliding, replacing,
-- auto-close, auto-minimize AND the capacity decisions all behave exactly as
-- in the default UI, just measured inside the configured band.
--
-- Both attributes are written from a SecureHandlerAttributeTemplate snippet
-- (the same technique Ultrawide Fix uses to resize UIParent): the addon only
-- sets an attribute on its own handler frame, and the restricted-environment
-- snippet performs the actual attribute writes on the layout host, so the
-- values Blizzard's secure layout code reads are never tainted by addon code.
-- The host is resolved when offsets are applied, not when this file loads;
-- see ResolveLayoutHost for why.
--
-- The bag windows are not UIPanels and never see those boundaries; the "Bag
-- windows" section below slides them into the band with a post-hook on
-- Blizzard's own bag layout function. EllesmereUI's replacement bag and bank
-- windows are covered by the "EllesmereUI windows" section under the same
-- option.

-- Aspect ratio at or above which CenterStage enables itself by default on a
-- resolution that has no saved profile yet (21:9 = 2.33, 32:9 = 3.56;
-- 16:9 = 1.78 stays disabled unless the user opts in).
local DEFAULT_ENABLE_ASPECT_RATIO = 2.0

local SIXTEEN_NINE_ASPECT = 16 / 9

local function GetAspectRatio()
    local physicalWidth, physicalHeight = GetPhysicalScreenSize()
    return physicalWidth / physicalHeight
end

-- Default band width for a resolution with no saved profile yet: the
-- centered 16:9 slice of the screen ((16/9)/aspect), so windows land where
-- they would on a regular 16:9 monitor. 50% on 32:9, ~74% on 21:9
-- (3440x1440), and 100% (= Blizzard default) at 16:9 and narrower, where
-- the addon is disabled by default anyway.
local function DefaultCenterPercent()
    local percent = (SIXTEEN_NINE_ASPECT / GetAspectRatio()) * 100
    return math.floor(math.min(percent, 100) + 0.5)
end

-- ---------------------------------------------------------------------------
-- SavedVariables / per-resolution profiles
-- ---------------------------------------------------------------------------
local function InitializeSettings()
    if not CenterStageDB then
        CenterStageDB = {}
    end
    if not CenterStageDB.profiles then
        CenterStageDB.profiles = {}
    end
end

local function GetResolutionKey()
    local physicalWidth, physicalHeight = GetPhysicalScreenSize()
    return string.format("%dx%d", physicalWidth, physicalHeight)
end

local function IsUltrawide()
    return GetAspectRatio() >= DEFAULT_ENABLE_ASPECT_RATIO
end

local function GetCurrentProfile()
    local profile = CenterStageDB and CenterStageDB.profiles
        and CenterStageDB.profiles[GetResolutionKey()]
    local merged = {}
    if profile and profile.centerPercent ~= nil then
        merged.centerPercent = profile.centerPercent
    else
        merged.centerPercent = DefaultCenterPercent()
    end
    if profile and profile.enabled ~= nil then
        merged.enabled = profile.enabled
    else
        merged.enabled = IsUltrawide()
    end
    if profile and profile.bags ~= nil then
        merged.bags = profile.bags
    else
        merged.bags = true
    end
    return merged
end

local function SetCurrentProfileValue(settingKey, value)
    local key = GetResolutionKey()
    if not CenterStageDB.profiles then
        CenterStageDB.profiles = {}
    end
    if type(CenterStageDB.profiles[key]) ~= "table" then
        CenterStageDB.profiles[key] = {}
    end
    CenterStageDB.profiles[key][settingKey] = value
end

-- ---------------------------------------------------------------------------
-- Secure attribute writer
-- ---------------------------------------------------------------------------
-- Blizzard's layout code reads the boundary attributes from UIParent on
-- Classic Era, TBC Anniversary and retail through 12.0.x; on retail from 12.1
-- and on WoW Forever it reads them from the dedicated UIPanelLayoutFrame
-- (Blizzard_UIParentPanelManager/Shared/UIPanelLayoutFrame.lua, via
-- GetUIPanelLayoutAttribute). That frame is created in Lua when
-- Blizzard_UIParentPanelManager loads, which is not guaranteed to happen
-- before this file runs, so the host cannot be captured at load time: on a
-- 12.1 client where our file ran first, a load-time lookup finds nil, falls
-- back to UIParent, and every write silently goes to attributes nobody reads
-- anymore. Resolve the host at apply time instead (all addons are loaded by
-- the time PLAYER_ENTERING_WORLD fires) and re-point the secure writer at it
-- whenever it changes.
local layoutHost
local originalLeftOffset = 16
local originalRightBuffer = 80

local driver = CreateFrame("Frame", "CenterStageSecureDriver", nil,
    "SecureHandlerAttributeTemplate")
driver:SetAttribute("_onattributechanged", [=[
    if name == "cs-offsets" then
        local left, buffer = strsplit(",", value)
        local host = self:GetFrameRef("layouthost")
        host:SetAttribute("LEFT_OFFSET", tonumber(left))
        host:SetAttribute("RIGHT_OFFSET_BUFFER", tonumber(buffer))
    end
]=])

-- Returns the frame Blizzard's layout code reads its boundaries from on this
-- client, binding the secure writer to it on first use or when it changes.
-- Blizzard's original values are captured from the host before we ever write
-- to it, so disabling the addon restores the default UI exactly. Binding
-- writes a handler attribute, which is locked in combat; in that case the
-- bind is left for the next out-of-combat apply (ApplyOffsets never writes
-- in combat, so nothing can reach an unbound host).
local function ResolveLayoutHost()
    local host = UIPanelLayoutFrame or UIParent
    if host ~= layoutHost and not InCombatLockdown() then
        layoutHost = host
        originalLeftOffset = host:GetAttribute("LEFT_OFFSET") or 16
        originalRightBuffer = host:GetAttribute("RIGHT_OFFSET_BUFFER") or 80
        driver:SetFrameRef("layouthost", host)
    end
    return host
end

-- ---------------------------------------------------------------------------
-- Applying the offsets
-- ---------------------------------------------------------------------------
local pendingApply = false
local lastApplied

local function DesiredOffsets()
    local host = ResolveLayoutHost()
    local profile = GetCurrentProfile()
    local uiWidth = UIParent:GetWidth() or 0
    if not profile.enabled or uiWidth <= 0 then
        return originalLeftOffset, originalRightBuffer
    end

    local bandWidth = uiWidth * (profile.centerPercent / 100)
    local minBand = (host:GetAttribute("DEFAULT_FRAME_WIDTH") or 384) + 32
    bandWidth = math.max(bandWidth, minBand)

    local left = math.max(originalLeftOffset, (uiWidth - bandWidth) / 2)

    -- The capacity checks compare offsets measured from UIParent's left edge
    -- against GetMaxUIPanelsWidth() = UIParent:GetRight() - buffer, so the
    -- buffer for a desired boundary is GetRight() minus that boundary (using
    -- GetRight, not width, keeps this correct if UIParent itself is inset,
    -- e.g. by Ultrawide Fix). Never reserve less than Blizzard's original
    -- minimap buffer.
    local boundary = left + bandWidth
    local buffer = (UIParent:GetRight() or uiWidth) - boundary
    buffer = math.max(originalRightBuffer, buffer)

    return left, buffer
end

-- ---------------------------------------------------------------------------
-- Bag windows
-- ---------------------------------------------------------------------------
-- The bag windows are not UIPanels. ContainerFrame.lua lays them out itself
-- in UpdateContainerFrameAnchors: the first shown bag is anchored to its
-- parent's BOTTOMRIGHT, offset left by the width of the right action bars,
-- and the others chain off it (WoW Forever and retail chain every further
-- column off the first bag; Classic Era and TBC anchor every column head to
-- the parent). Nothing in there reads the layout boundaries, so on an
-- ultrawide the bags stay glued to the far right while the dock sits in the
-- band.
--
-- Blizzard reruns that function on every bag open/close, resolution change,
-- bank open/close and from its secure frame manager (action bar and Edit
-- Mode changes), so we post-hook it: whenever the band's right limit lies
-- left of where Blizzard put the stack, every bag anchored to the parent is
-- slid left by the difference and the chained bags follow. The combined bag
-- (parented to UIParent) and the individual bags (parented to
-- ContainerFrameContainer on Forever/retail, UIParent on Classic Era/TBC)
-- all anchor to their parent's BOTTOMRIGHT, so one rule covers both modes.
-- The frames are not protected, so this is ordinary SetPoint work that is
-- allowed in combat too.

local function ForEachShownBag(callback)
    if ContainerFrameCombinedBags and ContainerFrameCombinedBags:IsShown() then
        callback(ContainerFrameCombinedBags)
    end
    for i = 1, NUM_CONTAINER_FRAMES or 13 do
        local bag = _G["ContainerFrame" .. i]
        if bag and bag:IsShown() then
            callback(bag)
        end
    end
end

-- Returns the bag's anchor offsets if Blizzard anchored it to its parent's
-- BOTTOMRIGHT (the anchor UpdateContainerFrameAnchors gives the first bag and
-- every column head); nil for bags chained to another bag or re-anchored by
-- a window mover, which are left alone.
local function GetParentAnchor(bag)
    local point, relativeTo, relativePoint, x, y = bag:GetPoint(1)
    if point == "BOTTOMRIGHT" and relativePoint == "BOTTOMRIGHT"
        and (relativeTo == nil or relativeTo == bag:GetParent()) then
        return x, y
    end
end

-- Anchor offsets and edge coordinates are expressed in a frame's own
-- effective scale (Blizzard shrinks tall bag stacks); the band is measured
-- in UIParent units.
local function UIParentUnitsPerUnit(frame)
    return frame:GetEffectiveScale() / UIParent:GetEffectiveScale()
end

local function ShiftBagAnchors()
    local profile = GetCurrentProfile()
    if not profile.enabled or not profile.bags then
        return
    end

    -- Blizzard's own distance from the screen's right edge is that of the
    -- rightmost parent-anchored bag; also note the stack's left edge for the
    -- bank clearance below.
    local blizzardOffset, stackLeft
    ForEachShownBag(function(bag)
        local x = GetParentAnchor(bag)
        if x then
            local offset = -x * UIParentUnitsPerUnit(bag)
            if not blizzardOffset or offset < blizzardOffset then
                blizzardOffset = offset
            end
        end
        local left = bag:GetLeft()
        if left then
            left = left * UIParentUnitsPerUnit(bag)
            if not stackLeft or left < stackLeft then
                stackLeft = left
            end
        end
    end)
    if not blizzardOffset then
        return
    end

    -- Put the stack's right edge on the band's right limit, never further
    -- right than Blizzard's own position next to the right action bars.
    local _, buffer = DesiredOffsets()
    local shift = buffer - blizzardOffset

    -- Blizzard shrinks the stack rather than let it cover an open bank
    -- window (its left edge must stay at BankFrame:GetRight() - 25 or
    -- beyond). That check is measured from the real screen edge, so cap the
    -- shift to keep the same clearance.
    if BankFrame and BankFrame:IsShown() and stackLeft then
        local bankRight = BankFrame:GetRight()
        if bankRight then
            bankRight = bankRight * UIParentUnitsPerUnit(BankFrame)
            shift = math.min(shift, stackLeft - (bankRight - 25))
        end
    end
    if shift <= 0 then
        return
    end

    ForEachShownBag(function(bag)
        local x, y = GetParentAnchor(bag)
        if x then
            bag:SetPoint("BOTTOMRIGHT", bag:GetParent(), "BOTTOMRIGHT",
                x - shift / UIParentUnitsPerUnit(bag), y)
        end
    end)
end

-- Re-lays the open bags out from the current band. Always goes through
-- Blizzard's function so the stack is rebuilt from its default position
-- first and the hook applies the shift exactly once; calling
-- ShiftBagAnchors on its own would pile shifts up.
local function RefreshBagAnchors()
    if not UpdateContainerFrameAnchors then
        return
    end
    local anyShown = false
    ForEachShownBag(function() anyShown = true end)
    if anyShown then
        UpdateContainerFrameAnchors()
    end
end

local bagHookInstalled = false

local function InstallBagHook()
    if bagHookInstalled or not UpdateContainerFrameAnchors then
        return
    end
    bagHookInstalled = true
    hooksecurefunc("UpdateContainerFrameAnchors", ShiftBagAnchors)
end

-- ---------------------------------------------------------------------------
-- EllesmereUI windows
-- ---------------------------------------------------------------------------
-- EllesmereUI replaces Blizzard's bags with its own bag window
-- (EUI_MainBagFrame) and bank window (EUI_BankFrame), neither of which is a
-- UIPanel. EllesmereUIBags.lua anchors the bag window once, half a second
-- after login, to the bottom-right corner of the screen, and
-- EllesmereUIBags_Bank.lua re-anchors the bank window to the top-left corner
-- every time a bank opens; a window the player has dragged is saved in
-- EllesmereUI's profile and restored to that spot instead, with a
-- differently shaped anchor. The detached reagent bag, the bag-slot strip
-- and the bank's bag-slot window hang off those two frames and follow them.
--
-- Under the same "Include bag windows" option, that automatic placement is
-- measured from the band instead of the screen: the bag window opens against
-- the band's right edge and the bank window against its left edge. Only a
-- window still carrying EllesmereUI's default anchor, or the one we gave it,
-- is moved; a dragged window no longer matches and keeps its saved spot, and
-- should EllesmereUI ever change its defaults this simply stops matching.
-- The windows are placed from an OnShow hook on each (EllesmereUI anchors
-- both before showing them) and again on every band change. They are plain
-- unprotected frames, so this is ordinary SetPoint work that is allowed in
-- combat too. EllesmereUIBags is an optional dependency, so its frames exist
-- by the time this file runs; on clients where EllesmereUI stands down they
-- are never created and all of this is a no-op.

local ELLESMERE_WINDOWS = {
    -- EllesmereUIBags.lua, StartAddon:
    --   EUI_Bags:SetPoint("BOTTOMRIGHT", UIParent, "BOTTOMRIGHT", -50, 50)
    { global = "EUI_MainBagFrame", point = "BOTTOMRIGHT", defaultX = -50, edge = "right" },
    -- EllesmereUIBags_Bank.lua, BANKFRAME_OPENED:
    --   EUI_Bank:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 15, -100)
    { global = "EUI_BankFrame", point = "TOPLEFT", defaultX = 15, edge = "left" },
}

-- The x offset we last gave each window, so a band change recognises a
-- window we placed and moves it again.
local ellesmerePlaced = {}

-- Returns the window's anchor offsets if it carries the automatic placement
-- (EllesmereUI's default anchor, or the one we last set); nil for a window
-- the player dragged, which EllesmereUI anchors differently.
local function GetEllesmereAutoAnchor(window, spec)
    if window:GetNumPoints() ~= 1 then
        return
    end
    local point, relativeTo, relativePoint, x, y = window:GetPoint(1)
    if point ~= spec.point or relativePoint ~= spec.point
        or (relativeTo ~= nil and relativeTo ~= UIParent) then
        return
    end
    local placed = ellesmerePlaced[window]
    if math.abs(x - spec.defaultX) < 0.5
        or (placed and math.abs(x - placed) < 0.5) then
        return x, y
    end
end

-- Moves each automatically placed EllesmereUI window against the band's
-- edge, or back onto EllesmereUI's default when the option or the addon is
-- off. Only the horizontal offset changes; EllesmereUI's vertical placement
-- is kept.
local function PlaceEllesmereWindows()
    local profile = GetCurrentProfile()
    local active = profile.enabled and profile.bags
    local left, buffer
    if active then
        left, buffer = DesiredOffsets()
    end
    for _, spec in ipairs(ELLESMERE_WINDOWS) do
        local window = _G[spec.global]
        if window then
            local x, y = GetEllesmereAutoAnchor(window, spec)
            if x then
                local target = spec.defaultX
                if active then
                    -- Anchor offsets are in the window's own scale
                    -- (EllesmereUI scales its bags); the band is measured in
                    -- UIParent units. Never place a window further out than
                    -- EllesmereUI's own default.
                    local scale = UIParentUnitsPerUnit(window)
                    if spec.edge == "right" then
                        target = math.min(spec.defaultX, -buffer / scale)
                    else
                        target = math.max(spec.defaultX, left / scale)
                    end
                end
                if math.abs(target - x) >= 0.5 then
                    -- Same point as EllesmereUI's own anchor, so this
                    -- replaces it instead of adding a second one.
                    window:SetPoint(spec.point, UIParent, spec.point, target, y)
                end
                ellesmerePlaced[window] = active and target or nil
            end
        end
    end
end

local ellesmereHooked = {}

local function InstallEllesmereHooks()
    for _, spec in ipairs(ELLESMERE_WINDOWS) do
        local window = _G[spec.global]
        if window and not ellesmereHooked[window] then
            ellesmereHooked[window] = true
            -- Runs after EllesmereUI's own OnShow handlers, and so after it
            -- has anchored the window.
            window:HookScript("OnShow", PlaceEllesmereWindows)
        end
    end
end

local function ApplyOffsets()
    -- Attribute writes on secure handler frames are locked during combat;
    -- queue and re-apply on PLAYER_REGEN_ENABLED.
    if InCombatLockdown() then
        pendingApply = true
        return
    end
    pendingApply = false

    -- Key the dedupe on the host too: if the host changed since the last
    -- write (see ResolveLayoutHost), the same offsets must be written again.
    local left, buffer = DesiredOffsets()
    local key = string.format("%.1f,%.1f", left, buffer)
    local applied = tostring(layoutHost) .. ":" .. key
    if applied ~= lastApplied then
        lastApplied = applied
        driver:SetAttribute("cs-offsets", key)
        -- Reflow any open panels immediately from the new boundaries. This
        -- is the same insecure-callable entry point addons have always
        -- used; the actual repositioning runs in Blizzard's secure delegate.
        UpdateUIPanelPositions()
    end

    -- The bag placements depend on the enabled flag as well as the offsets,
    -- which a toggle on a 100% band leaves unchanged, so they run outside
    -- the dedupe; both are cheap no-ops while nothing is open.
    RefreshBagAnchors()
    PlaceEllesmereWindows()
end

-- ---------------------------------------------------------------------------
-- Band preview
-- ---------------------------------------------------------------------------
-- A translucent green rectangle showing the band while adjusting settings,
-- hidden again after a few seconds (same pattern as Ultrawide Fix's UI
-- bounds preview). Built from the applied values, so clamping is visible.
local previewFrame, previewTimer

local function ShowPreview()
    local profile = GetCurrentProfile()
    if not profile.enabled then
        if previewFrame then
            previewFrame:Hide()
        end
        return
    end

    if not previewFrame then
        previewFrame = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
        previewFrame:SetFrameStrata("TOOLTIP")
        previewFrame:SetBackdrop({
            bgFile = "Interface\\Buttons\\WHITE8x8",
            edgeFile = "Interface\\Buttons\\WHITE8x8",
            edgeSize = 2,
        })
        previewFrame:SetBackdropColor(0, 1, 0, 0.08) -- faint green interior
        previewFrame:SetBackdropBorderColor(0, 1, 0, 1) -- solid green borders
    end

    local left, buffer = DesiredOffsets()
    local right = (UIParent:GetRight() or UIParent:GetWidth()) - buffer
    previewFrame:ClearAllPoints()
    previewFrame:SetPoint("TOPLEFT", UIParent, "TOPLEFT", left, 0)
    previewFrame:SetPoint("BOTTOMRIGHT", UIParent, "BOTTOMLEFT", right, 0)
    previewFrame:Show()

    if previewTimer then
        previewTimer:Cancel()
    end
    previewTimer = C_Timer.NewTimer(3, function()
        previewFrame:Hide()
    end)
end

-- ---------------------------------------------------------------------------
-- Settings UI
-- ---------------------------------------------------------------------------
local settingsCategory

local function BuildSettingsMenu()
    local category = Settings.RegisterVerticalLayoutCategory("CenterStage")
    settingsCategory = category
    Settings.RegisterAddOnCategory(category)

    local enabledSetting = Settings.RegisterProxySetting(
        category,
        "CenterStage_Enabled",
        "boolean",
        "Enable on this resolution",
        IsUltrawide(),
        function() return GetCurrentProfile().enabled end,
        function(value)
            SetCurrentProfileValue("enabled", value)
            ApplyOffsets()
            ShowPreview()
        end
    )
    Settings.CreateCheckbox(category, enabledSetting,
        "Confine Blizzard's system windows to a band of the screen on this " ..
        "resolution. Settings are saved per resolution, so your 32:9 and " ..
        "16:9 monitors can each keep their own behavior. Defaults to on " ..
        "for aspect ratios of 18:9 and wider.")

    local centerSetting = Settings.RegisterProxySetting(
        category,
        "CenterStage_CenterPercent",
        "number",
        "Center area width",
        DefaultCenterPercent(),
        function() return GetCurrentProfile().centerPercent end,
        function(value)
            SetCurrentProfileValue("centerPercent", value)
            ApplyOffsets()
            ShowPreview()
        end
    )
    local centerOptions = Settings.CreateSliderOptions(20, 100, 1)
    if MinimalSliderWithSteppersMixin then
        centerOptions:SetLabelFormatter(MinimalSliderWithSteppersMixin.Label.Right,
            function(value) return value .. "%" end)
    end
    Settings.CreateSlider(category, centerSetting, centerOptions,
        "Width of the centered area windows are confined to, as a " ..
        "percentage of screen width. On a 32:9 screen, 50% is exactly the " ..
        "middle 16:9. 100% spans the full width (Blizzard default).")

    local bagsSetting = Settings.RegisterProxySetting(
        category,
        "CenterStage_Bags",
        "boolean",
        "Include bag windows",
        true,
        function() return GetCurrentProfile().bags end,
        function(value)
            SetCurrentProfileValue("bags", value)
            RefreshBagAnchors()
            PlaceEllesmereWindows()
            ShowPreview()
        end
    )
    Settings.CreateCheckbox(category, bagsSetting,
        "Open the bag windows (combined or individual) against the right " ..
        "edge of the band instead of the right edge of the screen. Blizzard " ..
        "still stacks, scales and wraps them; they are only slid left, and " ..
        "never further right than Blizzard's own position next to the right " ..
        "action bars. With EllesmereUI, its bag window opens against the " ..
        "right edge of the band and its bank window against the left edge, " ..
        "unless you have dragged them somewhere else.")
end

SLASH_CENTERSTAGE1 = "/centerstage"
SlashCmdList["CENTERSTAGE"] = function()
    if settingsCategory then
        Settings.OpenToCategory(settingsCategory:GetID())
    end
end

-- ---------------------------------------------------------------------------
-- Events
-- ---------------------------------------------------------------------------
local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:RegisterEvent("DISPLAY_SIZE_CHANGED")
frame:RegisterEvent("UI_SCALE_CHANGED")
frame:RegisterEvent("PLAYER_REGEN_ENABLED")

frame:SetScript("OnEvent", function(self, event, arg1)
    if event == "ADDON_LOADED" then
        if arg1 == addonName then
            InitializeSettings()
            BuildSettingsMenu()
            InstallBagHook()
            InstallEllesmereHooks()
        end
    elseif event == "PLAYER_REGEN_ENABLED" then
        if pendingApply then
            ApplyOffsets()
        end
    else
        if event == "PLAYER_ENTERING_WORLD" then
            -- Blizzard_UIPanels_Game and EllesmereUIBags normally load
            -- before us; make sure the hooks are in place once every addon
            -- is.
            InstallBagHook()
            InstallEllesmereHooks()
        end
        -- Resolution or scale changed (or fresh login): defer one frame so
        -- Blizzard finishes its own re-layout first, then re-apply since the
        -- percentages resolve against the new UIParent width.
        C_Timer.After(0, ApplyOffsets)
    end
end)

-- The percentages resolve against UIParent's size, which other addons can
-- change at runtime (e.g. Ultrawide Fix restricting the canvas). Re-resolve
-- whenever UIParent is resized; deferred a frame so we read settled geometry.
UIParent:HookScript("OnSizeChanged", function()
    C_Timer.After(0, ApplyOffsets)
end)

addon.ApplyOffsets = ApplyOffsets
