local addonName, addon = ...

-- ---------------------------------------------------------------------------
-- CenterStage
-- ---------------------------------------------------------------------------
-- Blizzard's UIPanel manager lays the system windows (character pane, map,
-- LFG, merchant, ...) out between two boundaries on UIParent:
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
-- snippet performs the actual UIParent writes, so the values Blizzard's
-- secure layout code reads are never tainted by addon code.

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
-- Capture Blizzard's original values before we ever change them, so
-- disabling the addon restores the default UI exactly.
local originalLeftOffset = UIParent:GetAttribute("LEFT_OFFSET") or 16
local originalRightBuffer = UIParent:GetAttribute("RIGHT_OFFSET_BUFFER") or 80

local driver = CreateFrame("Frame", "CenterStageSecureDriver", nil,
    "SecureHandlerAttributeTemplate")
driver:SetFrameRef("uiparent", UIParent)
driver:SetAttribute("_onattributechanged", [=[
    if name == "cs-offsets" then
        local left, buffer = strsplit(",", value)
        local ui = self:GetFrameRef("uiparent")
        ui:SetAttribute("LEFT_OFFSET", tonumber(left))
        ui:SetAttribute("RIGHT_OFFSET_BUFFER", tonumber(buffer))
    end
]=])

-- ---------------------------------------------------------------------------
-- Applying the offsets
-- ---------------------------------------------------------------------------
local pendingApply = false
local lastApplied

local function DesiredOffsets()
    local profile = GetCurrentProfile()
    local uiWidth = UIParent:GetWidth() or 0
    if not profile.enabled or uiWidth <= 0 then
        return originalLeftOffset, originalRightBuffer
    end

    local bandWidth = uiWidth * (profile.centerPercent / 100)
    local minBand = (UIParent:GetAttribute("DEFAULT_FRAME_WIDTH") or 384) + 32
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

local function ApplyOffsets()
    -- Attribute writes on secure handler frames are locked during combat;
    -- queue and re-apply on PLAYER_REGEN_ENABLED.
    if InCombatLockdown() then
        pendingApply = true
        return
    end
    pendingApply = false

    local left, buffer = DesiredOffsets()
    local key = string.format("%.1f,%.1f", left, buffer)
    if key == lastApplied then
        return
    end
    lastApplied = key

    driver:SetAttribute("cs-offsets", key)
    -- Reflow any open panels immediately from the new boundaries. This is
    -- the same insecure-callable entry point addons have always used; the
    -- actual repositioning runs in Blizzard's secure delegate.
    UpdateUIPanelPositions()
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
        end
    elseif event == "PLAYER_REGEN_ENABLED" then
        if pendingApply then
            ApplyOffsets()
        end
    else
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
