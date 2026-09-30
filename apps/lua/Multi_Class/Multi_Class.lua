local driverCount                 = 0
local allDriversStartingPos       = {}
local raceHasStarted              = false
local firstFrame                  = true
local leaderboardOpened           = false
local lastSessionIndex            = nil
local lastSessionStarted          = nil
local playerStoppedState          = false
local raceDisplayStable           = nil
local raceDisplayPending          = nil
local RACE_POS_STABLE_FRAMES      = 2
local gridReordered               = false
local classReloadAttempted        = false

local driverClass                 = {}
local displayClass                = {}
local classOrder                  = {}
local releaseClasses              = {}
local manualDriverClass           = {}
local classAddInput               = ""
local classAddError               = nil
local carClassCache               = {}
local uiSourceCache               = {}

local storedSettings              = ac.storage({ enduranceEnabled = true, resultExportEnabled = true, resultFolder = "" })

local enduranceEnabled           = true

local resultExportEnabled        = true
local resultFolder               = ""
local resultExportStatus         = ""
local exportedSessionKey         = nil
local nextExportRetryAt          = 0
local EXPORT_RETRY_SECONDS       = 2
local resultResetAfterExport     = false
local lastExportDiagnostic       = nil
local lastExportCaptureError     = nil
local lastExportUpdateDiagnostic = nil
local lastExportTransitionError  = nil

-- Snapshot of the session that is currently running. It is captured every frame while
-- the session is alive because by the time the session has ended Assetto Corsa has
-- already discarded the display name, the session index and the lap count, and the car
-- may have been moved back to the pits. The result is therefore written from this
-- snapshot, never from whatever the live state happens to be at the end.
local liveSessionType            = nil
local liveSessionKey             = nil
local liveTrackName              = ""
local liveTotalLaps              = 0
local liveSessionPending         = false
local liveSessionCars            = {}
local liveSessionCarCount        = 0
local liveSessionTimeLeft        = nil
local liveSessionHadCountdown    = false

-- The dashboard watches these subfolders and derives the session type from the
-- folder name, so every file must be named exactly yyMMdd-HHmmss.json.
local SUBFOLDER_PRACTICE         = "practice"
local SUBFOLDER_QUALIFYING       = "qualifying"
local SUBFOLDER_RACE             = "race"

-- ac.StateSession.type and ac.SimState.raceSessionType are ac.SessionType enums, which
-- survive the end of a session. The session *name* does not, which is why the export
-- used to fail whenever the car returned to the pits. Values are hardcoded as a fallback
-- for CSP builds that do not expose the enum table.
local SESSION_TYPE_PRACTICE      = (ac.SessionType and ac.SessionType.Practice) or 1
local SESSION_TYPE_QUALIFY       = (ac.SessionType and ac.SessionType.Qualify) or 2
local SESSION_TYPE_RACE          = (ac.SessionType and ac.SessionType.Race) or 3
local SESSION_TYPE_HOTLAP        = (ac.SessionType and ac.SessionType.Hotlap) or 4

local mMin = math.min
local sFormat = string.format
local getCar = ac.getCar
local setAITopSpeed = physics.setAITopSpeed
local setAICaution = physics.setAICaution
local setAIThrottleLimit = physics.setAIThrottleLimit

local DEBUG_ENABLED = true
local debugLogFile = nil
local function Log(msg)
  if not DEBUG_ENABLED then return end
  pcall(function()
    if not debugLogFile then
      local path = "debug.log"
      if type(ac.dirname) == "function" then
        path = ac.dirname() .. "/debug.log"
      elseif type(io.relative) == "function" then
        path = io.relative("debug.log")
      end
      debugLogFile = io.open(path, "a")
    end
    if debugLogFile then
      debugLogFile:write(msg .. "\n")
      debugLogFile:flush()
    end
  end)
end

-- Storage key resolution. Primary key is the car's AC ID; when that is unavailable we
-- fall back to the grid index so a class added in one session is not silently lost.
local function carClassKey(carID, carIndex)
  if carID and carID ~= "" then
    return "carclass_" .. tostring(carID)
  end
  if carIndex ~= nil then
    return "carclass_idx_" .. tostring(carIndex)
  end
  return nil
end

local function SaveCarClass(carID, cls, carIndex)
  local key = carClassKey(carID, carIndex)
  if not key then
    Log("SaveCarClass ABORT: no carID and no carIndex - value NOT persisted")
    return false
  end
  local ok = pcall(function()
    ac.storage[key] = cls or ""
  end)
  Log(sFormat("SaveCarClass: key=%s cls='%s' idx=%s ok=%s", key, tostring(cls), tostring(carIndex), tostring(ok)))
  return ok
end

local function LoadCarClass(carID, carIndex)
  local key = carClassKey(carID, carIndex)
  if not key then
    Log("LoadCarClass ABORT: no carID and no carIndex")
    return nil
  end
  local ok, v = pcall(function()
    return ac.storage[key]
  end)
  if ok and v and v ~= "" then
    Log(sFormat("LoadCarClass: key=%s -> '%s' idx=%s", key, tostring(v), tostring(carIndex)))
    return v
  end
  Log(sFormat("LoadCarClass: key=%s -> (empty) idx=%s", key, tostring(carIndex)))
  return nil
end

local function NormalizeClassName(name)
  local n = (name or ""):gsub("^%s+", ""):gsub("%s+$", ""):gsub("[=\n]", " ")
  if n:sub(1, 1) == "#" then
    n = n:sub(2):gsub("^%s+", ""):gsub("%s+$", "")
  end
  return n
end

local function GetCarUISource(carIndex)
  local cached = uiSourceCache[carIndex]
  if cached then return cached end
  local out = { tags = {}, class = nil, badge = nil }
  local okId, carID = pcall(function()
    return ac.getCarID and ac.getCarID(carIndex)
  end)
  local folder = nil
  local okFolder = pcall(function()
    folder = ac.getFolder and ac.getFolder(ac.FolderID and ac.FolderID.ContentCars)
  end)
  if okId and carID and okFolder and folder and folder ~= "" then
    local uiDir = folder .. "/" .. carID .. "/ui"
    local path = uiDir .. "/ui_car.json"
    local data = nil
    local okLoad = pcall(function()
      data = io.load and io.load(path)
    end)
    if okLoad and data and type(data) == "string" and #data > 0 then
      local cls = data:match('"class"%s*:%s*"([^"]*)"')
      if cls then
        out.class = cls
      end
      local tagsSection = data:match('"tags"%s*:%s*%[(.-)%]')
      if tagsSection then
        for q in tagsSection:gmatch('"([^"]*)"') do
          out.tags[#out.tags + 1] = q
        end
      end
    end
    local okBadge = pcall(function()
      local files = io.scanDir and io.scanDir(uiDir, "badge*")
      if files and #files > 0 then
        out.badge = uiDir .. "/" .. files[1]
      end
    end)
  end
  uiSourceCache[carIndex] = out
  return out
end

local function GetCarTags(carIndex)
  local ok, tags = pcall(function()
    return ac.getCarTags and ac.getCarTags(carIndex)
  end)
  if not ok then tags = nil end
  local out = {}
  local function collect(t)
    if type(t) ~= "table" then return end
    for _, val in ipairs(t) do
      if type(val) == "string" then
        local tt = val:gsub("^%s+", ""):gsub("%s+$", "")
        if tt:sub(1, 1) == "#" then
          tt = tt:sub(2)
        end
        if tt ~= "" then
          out[#out + 1] = tt
        end
      end
    end
  end
  if tags then
    collect(tags)
  end
  collect(GetCarUISource(carIndex).tags)
  return out
end

local GetCarClassCached

GetCarClassCached = function(carIndex)
  local cached = carClassCache[carIndex]
  if cached ~= nil then
    return (cached ~= "") and cached or nil
  end
  local cls = nil
  local ui = GetCarUISource(carIndex)
  if ui.class then
    local v = ui.class:gsub("^%s+", ""):gsub("%s+$", "")
    if v ~= "" then
      cls = v
    end
  end
  if not cls then
    local ok, config = pcall(function()
      return ac.INIConfig and ac.INIConfig.carData(carIndex, 'car.ini')
    end)
    if ok and config then
      local ok2, val = pcall(function()
        return config:get('BASIC', 'CLASS', '')
      end)
      if ok2 and type(val) == "string" then
        local v = val:gsub("^%s+", ""):gsub("%s+$", "")
        if v ~= "" then
          cls = v
        end
      end
    end
  end
  carClassCache[carIndex] = cls or ""
  return cls
end

local function TagMatchesWord(lowerTag, lowerClass)
  if lowerClass == "" then return false end
  if lowerTag == lowerClass then return true end
  local esc = lowerClass:gsub("([^%w])", "%%%1")
  if lowerTag:find("^" .. esc .. "%f[%A]") then return true end
  if lowerTag:find("%f[%w]" .. esc .. "%f[%A]") then return true end
  if lowerTag:find("%f[%w]" .. esc .. "$") then return true end
  return false
end

local function EditDistance(a, b)
  local m, n = #a, #b
  if m == 0 then return n end
  if n == 0 then return m end
  local d = {}
  for i = 0, m do
    d[i * (n + 1)] = i
  end
  for j = 0, n do
    d[j] = j
  end
  for i = 1, m do
    for j = 1, n do
      local cost = (a:sub(i, i) == b:sub(j, j)) and 0 or 1
      local row = i * (n + 1)
      d[row + j] = mMin(d[row - (n + 1) + j] + 1, d[row + j - 1] + 1, d[row - (n + 1) + j - 1] + cost)
    end
  end
  return d[m * (n + 1) + n]
end

local function CarMatchesClass(carIndex, lowerClass)
  for _, tt in ipairs(GetCarTags(carIndex)) do
    if TagMatchesWord(string.lower(tt), lowerClass) then
      return true
    end
  end
  local cc = GetCarClassCached(carIndex)
  if cc and TagMatchesWord(string.lower(cc), lowerClass) then
    return true
  end
  local carName = ac.getCarName and ac.getCarName(carIndex)
  if carName and string.lower(carName:gsub("^%s+", ""):gsub("%s+$", "")) == lowerClass then
    return true
  end
  local carID = ac.getCarID and ac.getCarID(carIndex)
  if carID and string.lower(carID:gsub("^%s+", ""):gsub("%s+$", "")) == lowerClass then
    return true
  end
  return false
end

local function GetAvailableClassNames()
  local out = {}
  local seen = {}
  for i = 0, driverCount - 1 do
    for _, tt in ipairs(GetCarTags(i)) do
      local k = string.lower(tt)
      if not seen[k] then
        seen[k] = true
        out[#out + 1] = tt
      end
    end
    local cc = GetCarClassCached(i)
    if cc then
      local k = string.lower(cc)
      if not seen[k] then
        seen[k] = true
        out[#out + 1] = cc
      end
    end
  end
  return out
end

local VerifyClassAssignments
local BuildClassInfo
local RemoveReleaseClass

local function SaveClassNames()
  pcall(function()
    ac.storage["releaseClassNames"] = table.concat(releaseClasses, "|")
  end)
end

local function LoadClassNames()
  local ok, v = pcall(function()
    return ac.storage["releaseClassNames"]
  end)
  if ok and type(v) == "string" and v ~= "" then
    return v
  end
  return nil
end

local function AddReleaseClass(name)
  local n = NormalizeClassName(name)
  Log(sFormat("AddReleaseClass: name='%s' normalized='%s' driverCount=%d", tostring(name), n, driverCount))
  if n == "" then
    classAddError = "Enter a class name first."
    return
  end

  local lower = string.lower(n)
  for i = 1, #releaseClasses do
    if string.lower(releaseClasses[i]) == lower then
      classAddError = "Class '" .. n .. "' is already added."
      return
    end
  end

  local matched = 0
  for i = 0, driverCount - 1 do
    local m
    local ok = pcall(function()
      m = CarMatchesClass(i, lower)
    end)
    if not ok then m = false end
    if m then
      manualDriverClass[i] = n
      local okSave, carID = pcall(function() return ac.getCarID and ac.getCarID(i) end)
      if not okSave then carID = nil end
      local saved = SaveCarClass(carID, n, i)
      if not saved then
        Log(sFormat("AddReleaseClass WARN: car %d class '%s' assigned in memory but NOT persisted", i, n))
      end
      matched = matched + 1
    end
  end

  if matched == 0 then
    local avail = GetAvailableClassNames()
    local availText = (#avail > 0) and table.concat(avail, ", ") or "(none)"
    local suggestion = nil
    local bestDist = 3
    for _, an in ipairs(avail) do
      local dist = EditDistance(string.lower(an), lower)
      if dist < bestDist then
        bestDist = dist
        suggestion = an
      end
    end
    Log(sFormat("AddReleaseClass FAIL: matched=0 driverCount=%d avail=%d tags_sample={}", driverCount, #avail))
    classAddError = "No cars match '" .. n .. "'. Available tags/classes: " .. availText .. " (case is ignored). [debug: driverCount=" .. driverCount .. "]"
    if suggestion then
      classAddError = classAddError .. " Did you mean '" .. suggestion .. "'?"
    end
    return
  end

  releaseClasses[#releaseClasses + 1] = n
  classAddError = nil
  classAddInput = ""
  SaveClassNames()
  BuildClassInfo()
  Log(sFormat("AddReleaseClass DONE: '%s' matched=%d releaseClasses={%s}", n, matched, table.concat(releaseClasses, ",")))
  VerifyClassAssignments()
end

VerifyClassAssignments = function()
  local cars = {}
  local tlist = {}
  for i = 0, driverCount - 1 do
    local cls = manualDriverClass[i]
    if not cls or cls == "" then
      local carName = ac.getCarName and ac.getCarName(i)
      local carID = ac.getCarID and ac.getCarID(i)
      cars[#cars + 1] = carName or carID or sFormat("Car %d", i + 1)
      local tags = GetCarTags(i)
      tlist[#tlist + 1] = (#tags > 0) and table.concat(tags, ", ") or "(no tag)"
    end
  end

  if #cars == 0 then
    ui.toast(ui.Icons.Play, sFormat("All %d car(s) on the grid belong to an added class.", driverCount))
  else
    local details = {}
    for j = 1, #cars do
      details[#details + 1] = cars[j] .. " (" .. tlist[j] .. ")"
    end
    ui.toast(ui.Icons.Warning, sFormat("%d car(s) are not assigned to any class: %s", #cars, table.concat(details, ", ")))
  end
end

RemoveReleaseClass = function(idx)
  local n = releaseClasses[idx]
  if not n then return end
  table.remove(releaseClasses, idx)
  for i = 0, driverCount - 1 do
    if manualDriverClass[i] == n then
      manualDriverClass[i] = ""
      local okID, carID = pcall(function() return ac.getCarID and ac.getCarID(i) end)
      if not okID then carID = nil end
      SaveCarClass(carID, "", i)
    end
  end
  classAddError = nil
  SaveClassNames()
  BuildClassInfo()
end

BuildClassInfo = function()
  Log(sFormat("BuildClassInfo: dc=%d entries=%d", driverCount, #manualDriverClass))
  driverClass = {}
  displayClass = {}
  classOrder = {}

  if driverCount == 0 then return end

  local classMinPos = {}

  for i = 0, driverCount - 1 do
    local raw = manualDriverClass[i]
    local key
    if raw and raw ~= "" then
      key = "class" .. string.lower(raw)
    end

    driverClass[i] = key

    -- Display-only fallback: used exclusively by the leaderboard CLASS panel so that
    -- unassigned cars still get a sensible class position. This map must never feed
    -- VerifyClassAssignments or ReorderGridByClass, otherwise unadded classes would
    -- be reported as added ones.
    local dkey = key
    if not dkey then
      local detected = GetCarClassCached(i)
      if detected and detected ~= "" then
        dkey = "class" .. string.lower(detected)
      end
    end
    displayClass[i] = dkey

    if key then
      local pos = allDriversStartingPos[i] or (i + 1)
      if not classMinPos[key] or pos < classMinPos[key] then
        classMinPos[key] = pos
      end
    end
  end

  for key, _ in pairs(classMinPos) do
    classOrder[#classOrder + 1] = key
  end

  local classBestLapMs = {}
  for _, key in ipairs(classOrder) do
    local best = nil
    for i = 0, driverCount - 1 do
      if driverClass[i] == key then
        local ok, car = pcall(getCar, i)
        if ok and car then
          local okBt, btMs = pcall(function() return car.bestLapTimeMs end)
          if okBt and btMs and type(btMs) == "number" and btMs > 0 then
            if best == nil or btMs < best then
              best = btMs
            end
          end
        end
      end
    end
    classBestLapMs[key] = best
  end

  table.sort(classOrder, function(a, b)
    if classBestLapMs[a] and classBestLapMs[b] then
      return classBestLapMs[a] < classBestLapMs[b]
    end
    if classBestLapMs[a] then return true end
    if classBestLapMs[b] then return false end
    return classMinPos[a] < classMinPos[b]
  end)

  Log(sFormat("BuildClassInfo DONE: %d classes order={%s}", #classOrder, table.concat(classOrder, ",")))

end

-- Defined before LoadManualClassesFromStorage uses it. Previously this lived further
-- down the file, so the call resolved to a nil global and threw every frame, which
-- aborted the rest of session setup (including BuildClassInfo).
local function NormalizePath(p)
  if type(p) ~= "string" or p == "" then return p or "" end
  return p:gsub("\\", "/")
end

local function LoadManualClassesFromStorage()
  Log(sFormat("LoadManualClassesFromStorage: START driverCount=%d", driverCount))
  releaseClasses = {}
  local seen = {}
  local anyLoaded = false
  for i = 0, driverCount - 1 do
    local okID, carID = pcall(function() return ac.getCarID and ac.getCarID(i) end)
    if not okID then carID = nil end
    local cls = LoadCarClass(carID, i)
    if type(cls) == "string" and cls ~= "" then
      manualDriverClass[i] = cls
      anyLoaded = true
      if not seen[cls] then
        seen[cls] = true
        releaseClasses[#releaseClasses + 1] = cls
      end
    else
      manualDriverClass[i] = ""
    end
  end
  Log(sFormat("LoadManualClassesFromStorage: DONE anyLoaded=%s releaseClasses=%d classes={%s}", tostring(anyLoaded), #releaseClasses, table.concat(releaseClasses, ",")))
  if not anyLoaded then
    local savedNames = LoadClassNames()
    if savedNames and savedNames ~= "" then
      Log(sFormat("LoadManualClassesFromStorage: per-car storage empty, re-detecting from saved class names: %s", savedNames))
      for name in savedNames:gmatch("[^|]+") do
        local lower = string.lower(name)
        local matched = 0
        for i = 0, driverCount - 1 do
          local m
          local ok = pcall(function() m = CarMatchesClass(i, lower) end)
          if not ok then m = false end
          if m then
            manualDriverClass[i] = name
            local okID2, carID2 = pcall(function() return ac.getCarID and ac.getCarID(i) end)
            if not okID2 then carID2 = nil end
            SaveCarClass(carID2, name, i)
            matched = matched + 1
          end
        end
        if matched > 0 then
          releaseClasses[#releaseClasses + 1] = name
        end
        Log(sFormat("LoadManualClassesFromStorage: re-detected class '%s' matched %d cars", name, matched))
      end
    end
  end
  -- Restoring settings must never be able to abort class loading, so it is isolated.
  local okSettings, settingsErr = pcall(function()
    if storedSettings.enduranceEnabled ~= nil then
      enduranceEnabled = storedSettings.enduranceEnabled
    end
    -- Probe legacy settings independently: ac.storage rejects undeclared keys, and a
    -- failed legacy lookup must not abort restoration of the current settings below.
    local legacyEnabledOk, legacyEnabled = pcall(function()
      return storedSettings.qualiSaveEnabled
    end)
    local legacyFolderOk, legacyFolder = pcall(function()
      return storedSettings.qualiSaveFolder
    end)

    if legacyEnabledOk and legacyEnabled ~= nil then
      resultExportEnabled = legacyEnabled
      storedSettings.resultExportEnabled = legacyEnabled
    elseif storedSettings.resultExportEnabled ~= nil then
      resultExportEnabled = storedSettings.resultExportEnabled
    end

    if legacyFolderOk and legacyFolder ~= nil then
      resultFolder = NormalizePath(legacyFolder or "")
      storedSettings.resultFolder = resultFolder
    elseif storedSettings.resultFolder ~= nil then
      resultFolder = NormalizePath(storedSettings.resultFolder or "")
    end

    if legacyEnabledOk then
      pcall(function() storedSettings.qualiSaveEnabled = nil end)
    end
    if legacyFolderOk then
      pcall(function() storedSettings.qualiSaveFolder = nil end)
    end
  end)
  if not okSettings then
    Log("LoadManualClassesFromStorage: settings restore FAILED err=" .. tostring(settingsErr))
  end

  local okBuild, buildErr = pcall(BuildClassInfo)
  if not okBuild then
    Log("LoadManualClassesFromStorage: BuildClassInfo FAILED err=" .. tostring(buildErr))
  end
end

local function GetSessionNameLower(sim)
  sim = sim or ac.getSim()
  local ok, name = pcall(function() return ac.getSessionName(sim.currentSessionIndex) end)
  if not ok or not name then return "" end
  return string.lower(name)
end

local function IsRaceMode(sim)
  return GetSessionNameLower(sim):find("race") ~= nil
end

local function IsEnduranceMode()
  return enduranceEnabled and IsRaceMode()
end

local function IsQualiPracticeMode(sim)
  local sn = GetSessionNameLower(sim)
  return sn:find("qualifying") ~= nil or sn:find("practice") ~= nil
end

-- The dashboard derives the session type from the subfolder the result lands in, so these
-- three names are a contract with Services/LuaResultPaths.cs.
--
-- Resolved from the ac.SessionType enum rather than the session display name: the name is
-- already gone by the time the session ends and the car returns to the pits, which made
-- the export silently produce nothing. Hotlap is a practice-style session, so it is
-- reported as practice instead of being dropped.
local function SessionTypeToFolder(sessionType)
  if type(sessionType) ~= "number" then return nil end
  if sessionType == SESSION_TYPE_RACE then return SUBFOLDER_RACE end
  if sessionType == SESSION_TYPE_QUALIFY then return SUBFOLDER_QUALIFYING end
  if sessionType == SESSION_TYPE_PRACTICE or sessionType == SESSION_TYPE_HOTLAP then
    return SUBFOLDER_PRACTICE
  end
  return nil
end

-- Reads the live session type from the session object, falling back to the sim's
-- raceSessionType. Only valid while the session is still running.
local function ReadLiveSessionType(sim)
  sim = sim or ac.getSim()

  if ac.getSession then
    local okSession, session = pcall(ac.getSession, sim.currentSessionIndex)
    if okSession and session then
      local okType, sessionType = pcall(function() return session.type end)
      if okType and type(sessionType) == "number" then return sessionType end
    end
  end

  local okRace, raceType = pcall(function() return sim.raceSessionType end)
  if okRace and type(raceType) == "number" then return raceType end

  return nil
end

-- Only used as a fallback when the app starts while results are already on screen, where
-- the enum is unavailable and the display name is all there is.
local function GetExportSessionType()
  if IsRaceMode() then return SUBFOLDER_RACE end
  if not IsQualiPracticeMode() then return nil end
  if GetSessionNameLower():find("qualifying") ~= nil then return SUBFOLDER_QUALIFYING end
  return SUBFOLDER_PRACTICE
end

local function GetTrackNameSafe()
  if ac.getTrackName then
    local ok, name = pcall(ac.getTrackName)
    if ok and type(name) == "string" and name ~= "" then return name end
  end
  return ""
end

local function GetCurrentSessionKey(sim)
  sim = sim or ac.getSim()
  local name = ""
  local ok, n = pcall(function() return ac.getSessionName(sim.currentSessionIndex) end)
  if ok and type(n) == "string" then name = n end
  return sFormat("%s:%s", tostring(sim.currentSessionIndex), name)
end

-- ac.StateSession.isOver and sim.isLookingAtSessionResults are the two documented
-- "this session is done" signals; either one means the result is final.
local function IsSessionFinished(sim)
  sim = sim or ac.getSim()
  if sim.isInMainMenu == true then return false end

  local okResults, showingResults = pcall(function() return sim.isLookingAtSessionResults end)
  if okResults and showingResults == true then return true end

  if ac.getSession then
    local okSession, session = pcall(ac.getSession, sim.currentSessionIndex)
    if okSession and session then
      local okOver, isOver = pcall(function() return session.isOver end)
      if okOver and isOver == true then return true end
    end
  end

  return false
end

local function FormatLapMs(ms)
  if type(ms) ~= "number" or ms <= 0 then return "--:--.---" end
  local minutes = math.floor(ms / 60000)
  local rest = ms % 60000
  local seconds = math.floor(rest / 1000)
  local milli = rest % 1000
  return sFormat("%02d:%02d.%03d", minutes, seconds, milli)
end

local function JsonEscape(s)
  s = tostring(s or "")
  -- Control characters must be escaped too: a driver name containing a raw newline
  -- or tab would otherwise produce invalid JSON.
  s = s:gsub("\\", "\\\\"):gsub('"', '\\"')
  s = s:gsub("\n", "\\n"):gsub("\r", "\\r"):gsub("\t", "\\t")
  s = s:gsub("[\1-\31]", function(c) return sFormat("\\u%04x", string.byte(c)) end)
  return s
end

local function ResultDefaultFolder()
  -- Matches the dashboard default (Services/LuaResultPaths.cs) so the common case
  -- needs no configuration on either side.
  local okDocs, docs = pcall(function() return ac.getFolder(ac.FolderID.Documents) end)
  if okDocs and type(docs) == "string" and docs ~= "" then
    return NormalizePath(docs .. "/Assetto Corsa/mcr-results")
  end

  local candidates = {}

  local ok1, d1 = pcall(function() return ac.dirname() end)
  if ok1 and type(d1) == "string" and d1 ~= "" then
    candidates[#candidates + 1] = d1
  end

  local ok2, d2 = pcall(function() return ac.getFolder(ac.FolderID.ExtLua) end)
  if ok2 and type(d2) == "string" and d2 ~= "" then
    candidates[#candidates + 1] = d2
  end

  for _, c in ipairs(candidates) do
    local n = NormalizePath(c)
    if n ~= "" then
      return n
    end
  end
  return ""
end

local function ResultFolderWritable(folder)
  if folder == "" then return false, "no folder" end
  pcall(function()
    if type(io.createDir) == "function" then io.createDir(folder) end
  end)
  if type(io.dirExists) == "function" then
    local okE, exists = pcall(io.dirExists, folder)
    if okE and exists == false then
      return false, "folder does not exist"
    end
  end
  if type(io.save) ~= "function" then
    return true, nil
  end
  local probe = folder .. "/.mcr_write_test.tmp"
  local okW = pcall(function()
    if not io.save(probe, "") then
      error("io.save returned false")
    end
  end)
  pcall(function()
    if type(io.deleteFile) == "function" then io.deleteFile(probe) end
  end)
  if not okW then
    return false, "folder is not writable"
  end
  return true, nil
end

local function ResultEffectiveFolder()
  if resultFolder and resultFolder ~= "" then
    return resultFolder
  end
  return ResultDefaultFolder()
end

local function GetCarIdentity(i)
  local identity = { driver = "", car = "", skin = "" }

  local okD, d = pcall(function() return ac.getDriverName and ac.getDriverName(i) end)
  if okD and type(d) == "string" then identity.driver = d end

  local okC, c = pcall(function() return ac.getCarID and ac.getCarID(i) end)
  if okC and type(c) == "string" then identity.car = c end

  local okS, s = pcall(function() return ac.getCarSkinID and ac.getCarSkinID(i) end)
  if okS and type(s) == "string" then identity.skin = s end

  return identity
end

local function GetCarLapData(i)
  local data = {
    available = false,
    lapCount = 0,
    bestMs = 0,
    position = 0,
    inPit = nil,
    inPitlane = nil,
  }
  local okCar, car = pcall(getCar, i)
  if not okCar or not car then return data end
  data.available = true

  local okL, lc = pcall(function() return car.lapCount end)
  if okL and type(lc) == "number" and lc > 0 then data.lapCount = lc end

  local okB, bt = pcall(function() return car.bestLapTimeMs end)
  if okB and type(bt) == "number" and bt > 0 then data.bestMs = bt end

  local okP, p = pcall(function() return car.racePosition end)
  if okP and type(p) == "number" and p > 0 then data.position = p end

  local okPit, inPit = pcall(function() return car.isInPit end)
  if okPit and type(inPit) == "boolean" then data.inPit = inPit end

  local okPitlane, inPitlane = pcall(function() return car.isInPitlane end)
  if okPitlane and type(inPitlane) == "boolean" then data.inPitlane = inPitlane end

  return data
end

-- Keep a recent copy of every car's identity and result data while AC still exposes the
-- grid. `sim.carsCount` can become zero as soon as a timed session ends, so export must
-- never depend on live car objects after that transition.
local function CaptureLiveCarResults()
  if driverCount <= 0 then return end

  local cars = {}
  local availableCars = 0
  for i = 0, driverCount - 1 do
    local identity = GetCarIdentity(i)
    local lapData = GetCarLapData(i)
    cars[#cars + 1] = {
      index = i,
      driver = identity.driver,
      car = identity.car,
      skin = identity.skin,
      lapCount = lapData.lapCount,
      bestMs = lapData.bestMs,
      position = lapData.position,
      inPit = lapData.inPit,
      inPitlane = lapData.inPitlane,
    }
    if lapData.available or identity.driver ~= "" or identity.car ~= "" then
      availableCars = availableCars + 1
    end
  end

  -- Keep the last good copy if AC briefly reports a grid before populating its car data.
  if availableCars > 0 then
    liveSessionCars = cars
    liveSessionCarCount = #cars
  end
end

-- Snapshots everything the result needs while the session is still alive. Called every
-- frame while sim.isSessionStarted is true, so the last successful call before the
-- session ends holds metadata and car results even after AC reports zero cars.
local function CaptureLiveSession(sim)
  sim = sim or ac.getSim()
  if sim.isSessionStarted ~= true then return end

  local folder = SessionTypeToFolder(ReadLiveSessionType(sim))
  if folder == nil then return end

  local laps = 0
  if ac.getSession then
    local okSession, session = pcall(ac.getSession, sim.currentSessionIndex)
    if okSession and session then
      local okLaps, sessionLaps = pcall(function() return session.laps end)
      if okLaps and type(sessionLaps) == "number" and sessionLaps > 0 then laps = sessionLaps end
    end
  end

  liveSessionType    = folder
  liveSessionKey     = GetCurrentSessionKey(sim)
  liveTrackName      = GetTrackNameSafe()
  liveTotalLaps      = laps
  local okTimeLeft, timeLeft = pcall(function() return sim.sessionTimeLeft end)
  if okTimeLeft and type(timeLeft) == "number" then
    liveSessionTimeLeft = timeLeft
    if timeLeft > 0 then liveSessionHadCountdown = true end
  end
  CaptureLiveCarResults()
end

-- Called when a session ends, to arm the export. The result is written from the snapshot
-- on the next frame, outside the session-validity check and without requiring live cars.
local function ArmSessionEnded()
  if liveSessionType == nil then return end
  if exportedSessionKey ~= nil and exportedSessionKey == liveSessionKey then return end
  local wasPending = liveSessionPending
  liveSessionPending = true
  if not wasPending then
    Log("EXPORT: session ended, pending export for " .. tostring(liveSessionType) ..
        " key=" .. tostring(liveSessionKey) .. " cars=" .. tostring(liveSessionCarCount))
  end
end

-- Called when a new session starts, so a previous session's snapshot cannot leak into it.
local function ClearLiveSession()
  liveSessionType     = nil
  liveSessionKey      = nil
  liveTrackName       = ""
  liveTotalLaps       = 0
  liveSessionPending  = false
  liveSessionCars     = {}
  liveSessionCarCount = 0
  liveSessionTimeLeft = nil
  liveSessionHadCountdown = false
end

-- Practice / Qualifying: a bare array of best laps, read by
-- RaceService.ImportSessionResultAsync.
local function BuildSessionResultJson()
  local entries = {}

  for _, carData in ipairs(liveSessionCars) do
    if carData.bestMs > 0 then
      entries[#entries + 1] = {
        driver = JsonEscape(carData.driver),
        car = JsonEscape(carData.car),
        skin = JsonEscape(carData.skin),
        best = FormatLapMs(carData.bestMs)
      }
    end
  end

  local out = { "[" }
  for k, e in ipairs(entries) do
    out[#out + 1] = "    {"
    out[#out + 1] = sFormat('        "driver": "%s",', e.driver)
    out[#out + 1] = sFormat('        "car": "%s",', e.car)
    out[#out + 1] = sFormat('        "skin": "%s",', e.skin)
    out[#out + 1] = sFormat('        "bestLapTimeMs": "%s"', e.best)
    out[#out + 1] = (k < #entries) and "    }," or "    }"
  end
  out[#out + 1] = "]"
  return table.concat(out, "\n")
end

-- Race: a Content Manager compatible session file, read by
-- RaceService.ImportRaceResultAsync. Emitting the same shape means the existing
-- importer, class classification and points award all work unchanged.
local function BuildRaceResultJson(trackName, totalLaps)
  local players = {}
  local lapsTotal = {}
  local bestLaps = {}
  local order = {}

  for _, carData in ipairs(liveSessionCars) do
    players[#players + 1] = sFormat(
      '    { "name": "%s", "car": "%s", "skin": "%s" }',
      JsonEscape(carData.driver),
      JsonEscape(carData.car),
      JsonEscape(carData.skin))

    lapsTotal[#lapsTotal + 1] = tostring(carData.lapCount)

    if carData.bestMs > 0 then
      bestLaps[#bestLaps + 1] = sFormat(
        '    { "car": %d, "lap": %d, "time": %d }',
        carData.index,
        carData.lapCount,
        carData.bestMs)
    end

    order[#order + 1] = {
      index = carData.index,
      position = carData.position > 0 and carData.position or (carData.index + 1),
    }
  end

  table.sort(order, function(a, b)
    if a.position == b.position then return a.index < b.index end
    return a.position < b.position
  end)

  local raceResult = {}
  for k, entry in ipairs(order) do
    raceResult[k] = tostring(entry.index)
  end

  local out = { "{" }
  out[#out + 1] = sFormat('  "track": "%s",', JsonEscape(trackName or ""))
  out[#out + 1] = '  "numberOfSessions": 1,'
  out[#out + 1] = '  "players": ['
  out[#out + 1] = table.concat(players, ",\n")
  out[#out + 1] = '  ],'
  out[#out + 1] = '  "sessions": ['
  out[#out + 1] = '    {'
  out[#out + 1] = '      "event": 0,'
  out[#out + 1] = '      "name": "Race",'
  out[#out + 1] = '      "type": 3,'
  out[#out + 1] = sFormat('      "lapsCount": %d,', totalLaps)
  out[#out + 1] = '      "duration": 0,'
  out[#out + 1] = '      "laps": [],'
  out[#out + 1] = '      "lapsTotal": [' .. table.concat(lapsTotal, ", ") .. '],'
  out[#out + 1] = '      "bestLaps": ['
  out[#out + 1] = table.concat(bestLaps, ",\n")
  out[#out + 1] = '      ],'
  out[#out + 1] = '      "raceResult": [' .. table.concat(raceResult, ", ") .. ']'
  out[#out + 1] = '    }'
  out[#out + 1] = '  ]'
  out[#out + 1] = "}"
  return table.concat(out, "\n")
end

-- Write to a temporary name and rename, so the dashboard can never pick up a
-- partially written result file.
local function WriteResultFile(targetPath, contents)
  local tempPath = targetPath .. ".tmp"

  if not io.save(tempPath, contents) then
    error("io.save returned false")
  end

  if type(os.rename) == "function" then
    pcall(function() os.rename(tempPath, targetPath) end)

    local exists = true
    if type(io.fileExists) == "function" then
      local ok, result = pcall(io.fileExists, targetPath)
      exists = ok and result == true
    end

    if exists then
      pcall(function()
        if type(io.deleteFile) == "function" then io.deleteFile(tempPath) end
      end)
      return true
    end
  end

  pcall(function()
    if type(io.deleteFile) == "function" then io.deleteFile(tempPath) end
  end)

  if not io.save(targetPath, contents) then
    error("io.save returned false")
  end

  return true
end

-- Writes the result from the snapshot taken while the session was running. sessionKey is
-- remembered on success so the same session can never be written twice.
local function ExportSessionResult(sessionType, sessionKey, trackName, totalLaps, silent, force)
  -- A failed export is retried rather than abandoned, but the results screen can sit for
  -- minutes and each attempt probes the folder and rebuilds the JSON, so the retries are
  -- throttled instead of running on every frame.
  if not force and type(os.time) == "function" then
    local now = os.time()
    if now < nextExportRetryAt then return end
    nextExportRetryAt = now + EXPORT_RETRY_SECONDS
  end

  if sessionType == nil then return end

  local root = ResultEffectiveFolder()
  if root == "" then
    local msg = "No result folder available - choose one with 'Choose result folder...'"
    if resultExportStatus ~= msg then
      resultExportStatus = msg
      Log("EXPORT: " .. msg)
      if not silent then ui.toast(ui.Icons.Warning, msg) end
    end
    return
  end

  local targetDir = root .. "/" .. sessionType
  local writable, why = ResultFolderWritable(targetDir)
  if not writable then
    local msg = "Cannot save session result: " .. tostring(why) .. " (" .. targetDir .. ")"
    if resultExportStatus ~= msg then
      resultExportStatus = msg
      Log("EXPORT: " .. msg)
      if not silent then ui.toast(ui.Icons.Warning, msg) end
    end
    return
  end

  if type(os.date) ~= "function" then
    local msg = "os.date is unavailable on this CSP version - cannot name the result file."
    if resultExportStatus ~= msg then
      resultExportStatus = msg
      Log("EXPORT: " .. msg)
      if not silent then ui.toast(ui.Icons.Warning, msg) end
    end
    return
  end

  local fileName = os.date("%y%m%d-%H%M%S") .. ".json"
  local targetPath = targetDir .. "/" .. fileName
  local contents = (sessionType == SUBFOLDER_RACE)
      and BuildRaceResultJson(trackName, totalLaps)
      or BuildSessionResultJson()

  Log("EXPORT: writing " .. targetPath)
  local ok, err = pcall(function()
    WriteResultFile(targetPath, contents)
  end)

  if ok then
    exportedSessionKey = sessionKey
    liveSessionPending = false
    resultExportStatus = sFormat(
      "Saved %s result at %s -> %s/%s",
      sessionType,
      os.date("%H:%M:%S"),
      sessionType,
      fileName)
    if not silent then ui.toast(ui.Icons.Play, "Session result saved") end
    Log("EXPORT: wrote " .. targetPath)
  else
    -- exportedSessionKey is left unset so the next frame retries rather than
    -- silently losing the session result.
    local msg = "Failed to save session result: " .. tostring(err)
    if resultExportStatus ~= msg then
      resultExportStatus = msg
      if not silent then ui.toast(ui.Icons.Warning, msg) end
    end
    Log("EXPORT: FAILED err=" .. tostring(err))
  end
end

-- Called once per frame from script.update. Writes at most once per session.
--
-- The primary trigger is the armed end-of-session flag, not the results screen: when the
-- car returns to the pits the results screen may never appear and the session name is
-- already gone. The results-screen check is kept as a secondary trigger for the case
-- where the app starts while results are already on screen.
local function CheckForFinishedSession(sim)
  if not resultExportEnabled then return end
  if liveSessionType == nil then return end
  if liveSessionCarCount <= 0 then return end
  if liveSessionPending == false and not IsSessionFinished(sim) then return end
  if exportedSessionKey ~= nil and exportedSessionKey == liveSessionKey then return end

  ExportSessionResult(liveSessionType, liveSessionKey, liveTrackName, liveTotalLaps)
end

-- Only called when a new session begins. Resetting on the end of a session instead would
-- clear the guard that stops the result being written twice.
local function ResetResultExport()
  exportedSessionKey = nil
  nextExportRetryAt = 0
  ClearLiveSession()
end

local function CaptureLiveSessionSafely(sim)
  local ok, err = pcall(CaptureLiveSession, sim)
  if ok then
    lastExportCaptureError = nil
  else
    local message = tostring(err)
    if message ~= lastExportCaptureError then
      Log("EXPORT: live-session capture failed: " .. message)
      lastExportCaptureError = message
    end
  end
end

local function CheckForFinishedSessionSafely(sim)
  local ok, err = pcall(CheckForFinishedSession, sim)
  if not ok then
    Log("EXPORT: finish check failed: " .. tostring(err))
  end
end

local function IsPlayerInPit()
  local okCar, car = pcall(getCar, 0)
  if okCar and car then
    local observed = false
    local okPit, inPit = pcall(function() return car.isInPit end)
    if okPit and type(inPit) == "boolean" then
      observed = true
      if inPit then return true end
    end
    local okPitlane, inPitlane = pcall(function() return car.isInPitlane end)
    if okPitlane and type(inPitlane) == "boolean" then
      observed = true
      if inPitlane then return true end
    end
    if observed then return false end
  end

  -- AC can remove car objects at session teardown. Use the last live observation in that
  -- case; the live session snapshot is refreshed every frame until the grid disappears.
  local playerSnapshot = liveSessionCars[1]
  if playerSnapshot then
    if playerSnapshot.inPit == true or playerSnapshot.inPitlane == true then return true end
    if playerSnapshot.inPit == false and playerSnapshot.inPitlane == false then return false end
  end
  return nil
end

local function ExportExpiredSessionOnRelease()
  local currentTimeLeft = liveSessionTimeLeft
  local okSim, sim = pcall(ac.getSim)
  if okSim and sim then
    local okTime, timeLeft = pcall(function() return sim.sessionTimeLeft end)
    if okTime and type(timeLeft) == "number" then currentTimeLeft = timeLeft end
  end

  Log(sFormat(
    "EXPORT: release check enabled=%s type=%s key=%s snapshotCars=%d hadCountdown=%s leftMs=%s exported=%s",
    tostring(resultExportEnabled), tostring(liveSessionType), tostring(liveSessionKey),
    liveSessionCarCount, tostring(liveSessionHadCountdown), tostring(currentTimeLeft),
    tostring(exportedSessionKey == liveSessionKey)))

  if not resultExportEnabled then return end
  if liveSessionType == nil or liveSessionCarCount <= 0 then return end
  if not liveSessionHadCountdown or type(currentTimeLeft) ~= "number" or currentTimeLeft > 0 then return end
  if exportedSessionKey ~= nil and exportedSessionKey == liveSessionKey then return end

  liveSessionPending = true
  local ok, err = pcall(
    ExportSessionResult,
    liveSessionType,
    liveSessionKey,
    liveTrackName,
    liveTotalLaps,
    true,
    true)
  if not ok then
    Log("EXPORT: release fallback failed: " .. tostring(err))
  end
end

-- Emit one diagnostic line whenever AC's export-relevant state changes. This makes it
-- possible to distinguish a missed end transition from a missing session type, empty car
-- snapshot, disabled setting, or an actual write failure without logging every frame.
local function LogExportState(sim, sessionEnded, sessionBegan, sessionSwitched)
  local sessionType = ReadLiveSessionType(sim)
  local sessionTimeLeft = nil
  local okTimeLeft, timeLeft = pcall(function() return sim.sessionTimeLeft end)
  if okTimeLeft and type(timeLeft) == "number" then sessionTimeLeft = timeLeft end
  local playerInPit = IsPlayerInPit()
  local sessionTimeBucket = sessionTimeLeft and math.floor(sessionTimeLeft / 1000) or nil
  local capturedTimeBucket = liveSessionTimeLeft and math.floor(liveSessionTimeLeft / 1000) or nil
  local sessionOver = nil
  if ac.getSession then
    local okSession, session = pcall(ac.getSession, sim.currentSessionIndex)
    if okSession and session then
      local okOver, over = pcall(function() return session.isOver end)
      if okOver then sessionOver = over end
    end
  end
  local resultsVisible = nil
  local okResults, results = pcall(function() return sim.isLookingAtSessionResults end)
  if okResults then resultsVisible = results end
  local sessionName = ""
  local okName, name = pcall(function() return ac.getSessionName(sim.currentSessionIndex) end)
  if okName and type(name) == "string" then sessionName = name end

  local parts = {
    tostring(sim.isSessionStarted),
    tostring(lastSessionStarted),
    tostring(sim.currentSessionIndex),
    tostring(lastSessionIndex),
    tostring(driverCount),
    tostring(sessionName),
    tostring(sessionType),
    tostring(sim.raceSessionType),
    tostring(sessionTimeBucket),
    tostring(playerInPit),
    tostring(capturedTimeBucket),
    tostring(liveSessionHadCountdown),
    tostring(sessionOver),
    tostring(resultsVisible),
    tostring(sessionEnded),
    tostring(sessionBegan),
    tostring(sessionSwitched),
    tostring(liveSessionType),
    tostring(liveSessionKey),
    tostring(liveSessionCarCount),
    tostring(liveSessionPending),
    tostring(resultResetAfterExport),
    tostring(resultExportEnabled),
  }
  local signature = table.concat(parts, "|")
  if signature ~= lastExportDiagnostic then
    lastExportDiagnostic = signature
    Log(sFormat(
      "EXPORT: state started=%s prevStarted=%s index=%s prevIndex=%s cars=%d name='%s' " ..
      "sessionType=%s raceType=%s leftMs=%s playerInPit=%s capturedLeftMs=%s hadCountdown=%s " ..
      "over=%s results=%s ended=%s began=%s switched=%s liveType=%s liveKey=%s " ..
      "snapshotCars=%d pending=%s deferredReset=%s enabled=%s",
      tostring(sim.isSessionStarted), tostring(lastSessionStarted),
      tostring(sim.currentSessionIndex), tostring(lastSessionIndex), driverCount,
      sessionName, tostring(sessionType), tostring(sim.raceSessionType),
      tostring(sessionTimeLeft), tostring(playerInPit), tostring(liveSessionTimeLeft),
      tostring(liveSessionHadCountdown), tostring(sessionOver), tostring(resultsVisible),
      tostring(sessionEnded), tostring(sessionBegan), tostring(sessionSwitched),
      tostring(liveSessionType), tostring(liveSessionKey), liveSessionCarCount,
      tostring(liveSessionPending), tostring(resultResetAfterExport),
      tostring(resultExportEnabled)))
  end
end

-- Process the export-related session transitions in one place so their ordering is
-- testable. If the session ends on the same frame that AC switches to its pit/garage
-- session, retain and export the ended session snapshot instead of clearing it as a new
-- session. A later session begin/switch still resets the previous export state.
local function UpdateResultExportFrame(sim)
  local sessionSwitched = lastSessionIndex ~= nil
                        and lastSessionIndex ~= sim.currentSessionIndex
  local currentSessionKey = GetCurrentSessionKey(sim)
  local currentSessionFolder = SessionTypeToFolder(ReadLiveSessionType(sim))
  local sessionTimeLeft = nil
  local okTimeLeft, timeLeft = pcall(function() return sim.sessionTimeLeft end)
  if okTimeLeft and type(timeLeft) == "number" then sessionTimeLeft = timeLeft end
  local playerInPit = IsPlayerInPit()
  local switchedAwayFromTrackedSession = sessionSwitched
                        and liveSessionType ~= nil
                        and liveSessionKey ~= nil
                        and currentSessionKey ~= liveSessionKey
  local sessionName = GetSessionNameLower(sim)
  local lostTrackedSessionData = driverCount <= 0
                        and liveSessionType ~= nil
                        and liveSessionCarCount > 0
                        and (currentSessionFolder == nil or sessionName == "")
  local timedSessionExpiredInPit = liveSessionType ~= nil
                        and liveSessionHadCountdown
                        and sessionTimeLeft ~= nil
                        and sessionTimeLeft <= 0
                        and playerInPit == true
  local endSignal = (lastSessionStarted == true and sim.isSessionStarted ~= true)
                        or switchedAwayFromTrackedSession
                        or lostTrackedSessionData
                        or timedSessionExpiredInPit
  local sessionNeedsExport = liveSessionType ~= nil
                        and (liveSessionPending or exportedSessionKey ~= liveSessionKey)
  local sessionEnded = endSignal and sessionNeedsExport
  local sessionBegan = lastSessionStarted ~= nil and lastSessionStarted == false
                        and sim.isSessionStarted == true and lastSessionIndex ~= nil
  local newlyEnded = sessionEnded and not liveSessionPending
  local sessionChanged = newlyEnded or sessionBegan or sessionSwitched

  LogExportState(sim, sessionEnded, sessionBegan, sessionSwitched)

  if sessionEnded then
    -- Refresh the old snapshot only if AC is still showing that same session. If the
    -- index already moved, the live cars belong to the incoming state (or are gone).
    if not sessionSwitched and driverCount > 0 then
      local ok, err = pcall(CaptureLiveCarResults)
      if not ok then Log("EXPORT: final car snapshot failed: " .. tostring(err)) end
    end
    ArmSessionEnded()
    if sessionSwitched or sessionBegan then
      resultResetAfterExport = true
    end
    CheckForFinishedSessionSafely(sim)
  elseif sessionBegan or sessionSwitched then
    if liveSessionPending then
      -- Don't discard a result that still needs retries just because AC began its next
      -- session. Finish exporting the previous snapshot first.
      resultResetAfterExport = true
      CheckForFinishedSessionSafely(sim)
    else
      ResetResultExport()
      resultResetAfterExport = false
      CaptureLiveSessionSafely(sim)
    end
  elseif resultResetAfterExport then
    CheckForFinishedSessionSafely(sim)
  else
    CaptureLiveSessionSafely(sim)
    CheckForFinishedSessionSafely(sim)
  end

  if resultResetAfterExport and not liveSessionPending then
    ResetResultExport()
    resultResetAfterExport = false
    if sim.isSessionStarted == true then
      CaptureLiveSessionSafely(sim)
    end
  end

  lastSessionIndex = sim.currentSessionIndex
  lastSessionStarted = sim.isSessionStarted
  return sessionChanged, sessionEnded, sessionBegan, sessionSwitched
end

local function CheckSessionValidity()
  local sim = ac.getSim()

  if ac.getPatchVersionCode() < 3334 then
    return false, "Please update your Custom Shaders Patch (CSP) to version 0.2.7 or higher!"
  end

  local sn = GetSessionNameLower()
  if not (sn:find("race") or sn:find("practice") or sn:find("qualifying") or sn:find("hotlap")) then
    return false, "This app works in Race, Practice, or Qualifying sessions!"
  end

  if sim.isOnlineRace then
    return false, "This app only works for Offline/Single-player sessions!"
  end

  return true, nil
end

local function RecordStartingPositions()
  allDriversStartingPos = {}
  for i = 0, driverCount - 1 do
    local car = getCar(i)
    if car then
      allDriversStartingPos[i] = car.racePosition
    end
  end
  BuildClassInfo()
end

local function ReorderGridByClass()
  if #classOrder == 0 or driverCount == 0 then return end

  local function getBestLap(idx)
    local ok, car = pcall(getCar, idx)
    if ok and car then
      local okBt, bt = pcall(function() return car.bestLapTimeMs end)
      if okBt and bt and type(bt) == "number" and bt > 0 then return bt end
    end
    return 999999999
  end

  local classSlots = {}
  for ci, key in ipairs(classOrder) do
    classSlots[key] = {}
  end
  local noClass = {}

  for i = 0, driverCount - 1 do
    local cls = driverClass[i]
    if cls and classSlots[cls] then
      classSlots[cls][#classSlots[cls] + 1] = i
    else
      noClass[#noClass + 1] = i
    end
  end

  for _, key in ipairs(classOrder) do
    table.sort(classSlots[key], function(a, b)
      return getBestLap(a) < getBestLap(b)
    end)
  end
  table.sort(noClass, function(a, b)
    return getBestLap(a) < getBestLap(b)
  end)

  local ordered = {}
  for _, key in ipairs(classOrder) do
    for _, idx in ipairs(classSlots[key]) do
      ordered[#ordered + 1] = idx
    end
  end
  for _, idx in ipairs(noClass) do
    ordered[#ordered + 1] = idx
  end

  local pos = 1
  for _, idx in ipairs(ordered) do
    allDriversStartingPos[idx] = pos
    pos = pos + 1
  end

  Log(sFormat("ReorderGridByClass: reordered=%d drivers, classes={%s}", driverCount, table.concat(classOrder, ",")))
end

local function ReleaseAllCars()
  for i = 0, driverCount - 1 do
    setAITopSpeed(i, 999999.0)
    setAIThrottleLimit(i, 1.0)
    setAICaution(i, 1.0)
    physics.setAIStopCounter(i, 0.0)
  end
end

local function ManageAIClassRelease(dt)
  if not raceHasStarted then
    for i = 0, driverCount - 1 do
      local c = getCar(i)
      if c and c.speedKmh > 2.0 then
        raceHasStarted = true
        break
      end
    end
  end
  if not raceHasStarted then return end

  for i = 0, driverCount - 1 do
    local car = getCar(i)
    if car and i ~= 0 then
      setAITopSpeed(i, 999999.0)
      setAIThrottleLimit(i, 1.0)
      setAICaution(i, 1.0)
      physics.setAIStopCounter(i, 0.0)
    end
  end
end

local function LeaderboardProgress(carIndex)
  local car = getCar(carIndex)
  if not car then return 0 end
  return (car.sessionLapCount or 0) + (car.splinePosition or 0)
end

local function IsFinite(v)
  return type(v) == "number" and v == v and math.abs(v) ~= math.huge
end

local function GetCarBestLapMs(idx)
  local ok, car = pcall(getCar, idx)
  if ok and car then
    local okBt, bt = pcall(function() return car.bestLapTimeMs end)
    if okBt and type(bt) == "number" and bt > 0 then return bt end
  end
  return nil
end

local function GetCurrentLapInfo()
  local sim = ac.getSim()
  local playerCar = getCar(0)

  local totalLaps = 0
  local session = ac.getSession(sim.currentSessionIndex)
  if session then
    totalLaps = session.laps or 0
  end
  local lapRaw = 1
  if playerCar then
    lapRaw = playerCar.lapCount + 1
  end
  local currentLap = totalLaps > 0 and math.min(totalLaps, lapRaw) or lapRaw

  local speed = playerCar and (playerCar.speedKmh or 0) or 0
  if playerStoppedState then
    if speed > 8.0 then playerStoppedState = false end
  else
    if speed < 2.0 then playerStoppedState = true end
  end

  return currentLap, totalLaps, playerStoppedState
end

local function GetPlayerPositions()
  local sim = ac.getSim()
  local trackLength = sim.trackLengthM
  local playerCar = getCar(0)

  local currentLap, totalLaps, stopped = GetCurrentLapInfo()

  local overallPos = 1
  local classPos = 1
  local classTotal = 0
  local totalCars = 0
  local gapFront = nil
  local gapBehind = nil

  local playerClass = displayClass[0]

  local allCars = {}
  local classCars = {}

  for i = 0, driverCount - 1 do
    local car = getCar(i)
    if car then
      local prog = LeaderboardProgress(i)
      totalCars = totalCars + 1
      allCars[#allCars + 1] = { idx = i, prog = prog }

      -- playerClass can be nil when no class could be resolved; without this guard
      -- 'nil == nil' would match every car and inflate classTotal up to totalCars.
      if playerClass and displayClass[i] == playerClass then
        classTotal = classTotal + 1
        classCars[#classCars + 1] = { idx = i, prog = prog }
      end
    end
  end

  -- progSorter tolerates a missing prog (nil) so a sort can never abort clLeaderboard.
  -- Mirrors bestSorter: cars with a value sort ahead of those without, ties broken by idx.
  local function progSorter(a, b)
    if a.prog and b.prog then return a.prog > b.prog end
    if a.prog then return true end
    if b.prog then return false end
    return a.idx < b.idx
  end
  table.sort(allCars, progSorter)
  table.sort(classCars, progSorter)

  for i, car in ipairs(allCars) do
    if car.idx == 0 then
      overallPos = i
      break
    end
  end

  for i, car in ipairs(classCars) do
    if car.idx == 0 then
      classPos = i
      if i > 1 then
        local g = ac.getGapBetweenCars(0, classCars[i - 1].idx)
        if IsFinite(g) then gapFront = g end
      end
      if i < #classCars then
        local g = ac.getGapBetweenCars(0, classCars[i + 1].idx)
        if IsFinite(g) then gapBehind = g end
      end
      break
    end
  end

  if not sim.isSessionStarted then
    gapFront = nil
    gapBehind = nil
  end

  if stopped then
    gapFront = nil
    gapBehind = nil
  end

  -- CSP computes car.racePosition every frame; ac.getCarLeaderboardPosition() is the
  -- legacy Python leaderboard and returns a frozen classification, so it must not be used here.
  local function EnginePos(idx)
    local ok, p = pcall(function() return getCar(idx).racePosition end)
    if ok and type(p) == "number" and p > 0 then
      return p
    end
    return nil
  end

  local enginePos = EnginePos(0)
  if enginePos then
    local pendingPos = raceDisplayPending
    if pendingPos and pendingPos.value == enginePos then
      pendingPos.frames = pendingPos.frames + 1
    else
      pendingPos = { value = enginePos, frames = 1 }
      raceDisplayPending = pendingPos
    end

    local stable = enginePos
    if pendingPos.frames >= RACE_POS_STABLE_FRAMES then
      raceDisplayStable = enginePos
    elseif raceDisplayStable and raceDisplayStable > 0 then
      stable = raceDisplayStable
    end

    overallPos = stable
    classPos = 1
    for _, car in ipairs(classCars) do
      if car.idx ~= 0 then
        local rp = EnginePos(car.idx)
        if rp and rp < stable then
          classPos = classPos + 1
        end
      end
    end
  else
    -- Engine has no classification for this car (pre-start, pits, retired): keep showing
    -- the last known good position instead of snapping back to a progress-derived guess.
    if raceDisplayStable and raceDisplayStable > 0 then
      overallPos = raceDisplayStable
    end
  end

  return overallPos, totalCars, classPos, classTotal, gapFront, gapBehind, currentLap, totalLaps, stopped
end

local function GetPlayerPositionsQuali()
  local playerClass = displayClass[0]

  local allCars = {}
  local classCars = {}
  local totalCars = 0
  local classTotal = 0

  for i = 0, driverCount - 1 do
    local car = getCar(i)
    if car then
      local best = GetCarBestLapMs(i)
      totalCars = totalCars + 1
      allCars[#allCars + 1] = { idx = i, best = best }
      if playerClass and displayClass[i] == playerClass then
        classTotal = classTotal + 1
        classCars[#classCars + 1] = { idx = i, best = best }
      end
    end
  end

  local function bestSorter(a, b)
    if a.best and b.best then return a.best < b.best end
    if a.best then return true end
    if b.best then return false end
    return a.idx < b.idx
  end
  table.sort(allCars, bestSorter)
  table.sort(classCars, bestSorter)

  local overallPos = 1
  for i, c in ipairs(allCars) do
    if c.idx == 0 then
      overallPos = i
      break
    end
  end
  local classPos = 1
  for i, c in ipairs(classCars) do
    if c.idx == 0 then
      classPos = i
      break
    end
  end

  local classFastestMs = nil
  for _, c in ipairs(classCars) do
    if c.best then
      classFastestMs = c.best
      break
    end
  end

  local playerBestMs = GetCarBestLapMs(0)

  return overallPos, totalCars, classPos, classTotal, classFastestMs, playerBestMs
end

local hasDWrite = (type(ui.pushDWriteFont) == "function" and type(ui.dwriteText) == "function")

local function MeasureBoldText(text, fontSize)
  if hasDWrite then
    ui.pushDWriteFont("Segoe UI;Weight=Bold")
    local s = ui.measureDWriteText(text, fontSize)
    ui.popDWriteFont()
    return s
  end
  return ui.measureText(text)
end

local function DrawBoldText(text, centerX, centerY, fontSize, color)
  if not hasDWrite then
    local size = ui.measureText(text)
    ui.setCursor(vec2(centerX - size.x / 2, centerY - size.y / 2))
    if color then
      ui.textColored(text, color)
    else
      ui.text(text)
    end
    return size.y
  end
  ui.pushDWriteFont("Segoe UI;Weight=Bold")
  local size = ui.measureDWriteText(text, fontSize)
  ui.setCursor(vec2(centerX - size.x / 2, centerY - size.y / 2))
  if color then
    ui.dwriteText(text, fontSize, color)
  else
    ui.dwriteText(text, fontSize)
  end
  ui.popDWriteFont()
  return size.y
end

function script.clLeaderboard(dt)
  local sim = ac.getSim()
  local w = ui.windowWidth()
  local h = ui.windowHeight()

  local qualiMode = IsQualiPracticeMode()
  local overallPos, totalCars, classPos, classTotal, gapFront, gapBehind, currentLap, totalLaps, stopped
  local classFastestMs, playerBestMs = nil, nil
  if qualiMode then
    overallPos, totalCars, classPos, classTotal, classFastestMs, playerBestMs = GetPlayerPositionsQuali()
    currentLap, totalLaps, stopped = GetCurrentLapInfo()
    gapFront, gapBehind = nil, nil
  else
    overallPos, totalCars, classPos, classTotal, gapFront, gapBehind, currentLap, totalLaps, stopped = GetPlayerPositions()
  end

  local padX = 12
  local gap = 16
  local panelW = (w - 2 * padX - 2 * gap) / 3
  local panelTop = 8

  local gapPanelH = 46
  local gapPanelTop = h - 8 - gapPanelH

  local columnBottom = gapPanelTop - 10
  local panelH = columnBottom - panelTop

  local function DrawPanel(x, title, bigText, totalText, color)
    local cx = x + panelW / 2

    ui.drawRectFilled(vec2(x, panelTop), vec2(x + panelW, columnBottom), rgbm(0.08, 0.10, 0.15, 0.6), 8)
    ui.drawRect(vec2(x, panelTop), vec2(x + panelW, columnBottom), rgbm(0.3, 0.3, 0.36, 0.7), 8, nil, 1.5)

    DrawBoldText(title, cx, panelTop + 8 + MeasureBoldText(title, 13).y / 2, 13, rgbm(0.7, 0.7, 0.8, 1))

    local bigCy = panelTop + panelH * 0.42
    local bigSize = math.max(12, math.floor(panelH * 0.5))
    local bigW = MeasureBoldText(bigText, bigSize).x
    if bigW > panelW * 0.9 then
      bigSize = math.max(12, math.floor(bigSize * (panelW * 0.9) / bigW))
    end
    local bigH = MeasureBoldText(bigText, bigSize).y
    local bigMaxHalf = panelH * 0.22
    if bigH / 2 > bigMaxHalf then
      bigSize = math.max(12, math.floor(bigSize * bigMaxHalf / (bigH / 2)))
    end
    local drawnBigH = DrawBoldText(bigText, cx, bigCy, bigSize, color)

    local sepW = panelW * 0.5
    local sepY = bigCy + drawnBigH / 2 + 10
    ui.drawRectFilled(vec2(cx - sepW / 2, sepY), vec2(cx + sepW / 2, sepY + 2), rgbm(0.5, 0.5, 0.6, 0.9))

    if totalText then
      local totalSize = MeasureBoldText(totalText, 16)
      local totalCy = math.min(sepY + 8 + totalSize.y / 2, columnBottom - totalSize.y / 2 - 8)
      DrawBoldText(totalText, cx, totalCy, 16, rgbm(0.7, 0.7, 0.8, 1))
    end
  end

  local lapTotalText = (totalLaps or 0) > 0 and sFormat("%d", totalLaps) or nil
  DrawPanel(padX, "LAP", sFormat("%d", math.max(1, currentLap)), lapTotalText, rgbm(0.95, 0.95, 1, 1))
  DrawPanel(padX + panelW + gap, "OVERALL", sFormat("%d", overallPos), sFormat("%d", totalCars), rgbm(0.95, 0.95, 1, 1))
  if classTotal > 0 then
    DrawPanel(padX + 2 * (panelW + gap), "CLASS", sFormat("%d", classPos), sFormat("%d", classTotal), rgbm(0.35, 0.95, 0.45, 1))
  else
    DrawPanel(padX + 2 * (panelW + gap), "CLASS", "-", "add a class", rgbm(0.55, 0.55, 0.6, 1))
  end

  if qualiMode then
    local posY = gapPanelTop + gapPanelH / 2
    local gapPanelRight = w - padX
    ui.drawRectFilled(vec2(padX, gapPanelTop), vec2(gapPanelRight, h - 8), rgbm(0.08, 0.10, 0.15, 0.6), 8)
    ui.drawRect(vec2(padX, gapPanelTop), vec2(gapPanelRight, h - 8), rgbm(0.3, 0.3, 0.36, 0.7), 8, nil, 1.5)

    local fastLap = classFastestMs and FormatLapMs(classFastestMs) or "--:--.---"
    local myLap = playerBestMs and FormatLapMs(playerBestMs) or "--:--.---"

    local maxW = w - 2 * padX - 24
    local gFs = 15
    local fastRow = "FASTEST  " .. fastLap
    local myRow = "YOU      " .. myLap
    local need = math.max(MeasureBoldText(fastRow, gFs).x, MeasureBoldText(myRow, gFs).x)
    if need > maxW then
      gFs = math.max(12, math.floor(gFs * maxW / need))
    end

    DrawBoldText(fastRow, w / 2, posY - (math.floor(gFs / 2) + 1), gFs, rgbm(0.35, 0.95, 0.45, 1))
    DrawBoldText(myRow, w / 2, posY + (math.floor(gFs / 2) + 1), gFs, rgbm(0.95, 0.95, 1, 1))
  elseif classTotal > 1 then
    local gapStr = "--"
    local gapColor = rgbm(0.55, 0.55, 0.6, 0.9)
    if sim.isSessionStarted then
      if stopped then
        gapStr = "Car Stopped"
        gapColor = rgbm(1.0, 0.7, 0.35, 1)
      elseif gapFront and gapBehind then
        gapStr = sFormat("+%.1fs / -%.1fs", math.abs(gapFront), math.abs(gapBehind))
      elseif gapFront then
        gapStr = sFormat("+%.1fs", math.abs(gapFront))
      elseif gapBehind then
        gapStr = sFormat("-%.1fs", math.abs(gapBehind))
      end
    end

    local gapPanelRight = w - padX
    ui.drawRectFilled(vec2(padX, gapPanelTop), vec2(gapPanelRight, h - 8), rgbm(0.08, 0.10, 0.15, 0.6), 8)
    ui.drawRect(vec2(padX, gapPanelTop), vec2(gapPanelRight, h - 8), rgbm(0.3, 0.3, 0.36, 0.7), 8, nil, 1.5)

    local gFs = 20
    local gSize = MeasureBoldText(gapStr, gFs)
    if gSize.x > (w - 2 * padX - 24) then
      gFs = math.max(12, math.floor(gFs * (w - 2 * padX - 24) / gSize.x))
    end
    DrawBoldText(gapStr, w / 2, gapPanelTop + gapPanelH / 2, gFs, gapColor)
  end
end

function script.update(dt)
  local sim = ac.getSim()
  driverCount = sim.carsCount or 0

  -- Log the incoming state before any export-side API calls. If the transition handler
  -- encounters an AC/CSP state object that is no longer valid after cars disappear, this
  -- entry still records the zero-car state that led to the failure.
  local entryOk, entryLine = pcall(function()
    local sessionName = ""
    local okName, name = pcall(function() return ac.getSessionName(sim.currentSessionIndex) end)
    if okName and type(name) == "string" then sessionName = name end

    local sessionType, sessionOver = nil, nil
    if ac.getSession then
      local okSession, session = pcall(ac.getSession, sim.currentSessionIndex)
      if okSession and session then
        local okType, value = pcall(function() return session.type end)
        if okType then sessionType = value end
        local okOver, over = pcall(function() return session.isOver end)
        if okOver then sessionOver = over end
      end
    end

    local resultsVisible = nil
    local okResults, results = pcall(function() return sim.isLookingAtSessionResults end)
    if okResults then resultsVisible = results end
    local sessionTimeLeft = nil
    local okTimeLeft, timeLeft = pcall(function() return sim.sessionTimeLeft end)
    if okTimeLeft and type(timeLeft) == "number" then sessionTimeLeft = timeLeft end
    local sessionTimeBucket = sessionTimeLeft and math.floor(sessionTimeLeft / 1000) or nil
    local playerInPit = IsPlayerInPit()

    return sFormat(
      "EXPORT: update-entry started=%s prevStarted=%s index=%s prevIndex=%s cars=%d " ..
      "name='%s' sessionType=%s raceType=%s leftSec=%s playerInPit=%s over=%s results=%s",
      tostring(sim.isSessionStarted), tostring(lastSessionStarted),
      tostring(sim.currentSessionIndex), tostring(lastSessionIndex), driverCount,
      sessionName, tostring(sessionType), tostring(sim.raceSessionType),
      tostring(sessionTimeBucket), tostring(playerInPit),
      tostring(sessionOver), tostring(resultsVisible))
  end)
  if entryOk and entryLine ~= lastExportUpdateDiagnostic then
    lastExportUpdateDiagnostic = entryLine
    Log(entryLine)
  elseif not entryOk then
    Log("EXPORT: update-entry diagnostics failed: " .. tostring(entryLine))
  end

  local updateOk, sessionChanged = pcall(UpdateResultExportFrame, sim)
  if not updateOk then
    local message = tostring(sessionChanged)
    if message ~= lastExportTransitionError then
      Log("EXPORT: transition handler failed: " .. message)
      lastExportTransitionError = message
    end
    sessionChanged = false
  else
    lastExportTransitionError = nil
  end
  if sessionChanged then
    firstFrame = true
    carClassCache = {}
    uiSourceCache = {}
  end
  if firstFrame then
    -- Cleared before the work runs: if anything below throws, the flag stays false so a
    -- single failure cannot turn into a per-frame infinite loop.
    firstFrame = false
    Log(sFormat("FIRSTFRAME: idx=%s race=%s dc=%d rc=%d", tostring(sim.currentSessionIndex), tostring(IsRaceMode()), driverCount, #releaseClasses))
    leaderboardOpened = false
    raceHasStarted   = false
    playerStoppedState = false
    allDriversStartingPos = {}
    if driverCount > 0 then
      for i = 0, driverCount - 1 do
        local okID, carID = pcall(function() return ac.getCarID and ac.getCarID(i) end)
        if not okID then carID = nil end
        Log(sFormat("GRID: i=%d carID=%s name=%s", i, tostring(carID), tostring(ac.getCarName and ac.getCarName(i))))
      end
      local okLoad, loadErr = pcall(LoadManualClassesFromStorage)
      if not okLoad then
        Log("FIRSTFRAME: LoadManualClassesFromStorage FAILED err=" .. tostring(loadErr))
      end
      if IsEnduranceMode() then
        RecordStartingPositions()
        ReorderGridByClass()
        gridReordered = true
        ReleaseAllCars()
      end
    end
    Log(sFormat("FIRSTFRAME DONE: rc=%d classes={%s}", #releaseClasses, table.concat(releaseClasses, ",")))
  end

  -- Attempts at most once per session. Without this guard the block re-ran every frame
  -- whenever no class was assigned, reloading storage for the whole grid each time and
  -- starving the leaderboard.
  if not classReloadAttempted and #releaseClasses == 0 and driverCount > 0 then
    classReloadAttempted = true
    LoadManualClassesFromStorage()
    if #releaseClasses > 0 then
      BuildClassInfo()
      if IsEnduranceMode() then
        RecordStartingPositions()
        ReorderGridByClass()
        gridReordered = true
      end
    end
  end

  if sim.isInMainMenu == true then
    ac.setWindowOpen("cl_config", true)
  end

  local valid, _ = CheckSessionValidity()
  if not valid then return end

  if not leaderboardOpened and sim.isInMainMenu ~= true then
    ac.setWindowOpen("cl_leaderboard", true)
    leaderboardOpened = true
  end

  -- Runs once per session only. Previously this executed every frame while the session
  -- had not started, continuously rewriting the grid and starving the leaderboard.
  if IsEnduranceMode() and not sim.isSessionStarted and not gridReordered then
    for i = 0, driverCount - 1 do
      local car = getCar(i)
      if car then
        allDriversStartingPos[i] = car.racePosition
      end
    end
    local okReorder, reorderErr = pcall(ReorderGridByClass)
    if okReorder then
      gridReordered = true
      Log("PRE-START: grid reordered once by class")
    else
      Log("PRE-START: ReorderGridByClass FAILED err=" .. tostring(reorderErr))
    end
  end

  if IsEnduranceMode() then
    ManageAIClassRelease(dt)
  end
end

function script.clConfig()
  local valid, err = CheckSessionValidity()
  local sim = ac.getSim()
  local w = ui.windowWidth()
  local h = ui.windowHeight()

  local colX = 24

  ui.pushStyleVar(ui.StyleVar.FramePadding, vec2(6, 6))

  ui.drawRectFilled(vec2(0, 0), vec2(w, h), rgbm(0.04, 0.05, 0.07, 0.85), 0)
  ui.drawRect(vec2(0, 0), vec2(w, h), rgbm(0.18, 0.18, 0.20, 0.6), 0, nil, 1)

  ui.pushFont(ui.Font.Title)
  local titleText = "Multiple Class Race Configuration"
  local titleSize = ui.measureText(titleText)
  local titleX = (w - titleSize.x) / 2
  ui.setCursor(vec2(titleX, 12))
  ui.text(titleText)
  ui.popFont()

  local separatorY = ui.getCursor().y + 10
  ui.drawLine(vec2(colX, separatorY), vec2(w - 24, separatorY), rgbm(0.25, 0.25, 0.28, 0.5), 1)
  ui.setCursor(vec2(colX, separatorY + 12))

  -- Available in Race, Practice and Qualifying alike.
  if ui.checkbox("Auto-save session result when the session finishes", resultExportEnabled) then
    resultExportEnabled = not resultExportEnabled
    storedSettings.resultExportEnabled = resultExportEnabled
    if not resultExportEnabled then
      ResetResultExport()
    end
  end

  ui.setCursor(vec2(colX, ui.getCursor().y + 4))
  if ui.button("Choose result folder...", vec2(w - 48, 28)) then
    local dlgOk, dlgErr = pcall(function()
      if type(os.openFileDialog) ~= "function" then
        ui.toast(ui.Icons.Warning, "Folder dialog is not available on this CSP version.")
      else
        local defaultFolder = ac.getFolder and ac.getFolder(ac.FolderID.Documents) or ""
        os.openFileDialog({
          title = "Choose save folder for session results",
          defaultFolder = defaultFolder,
          folder = (resultFolder ~= "") and resultFolder or nil,
          flags = os.DialogFlags and bit.bor(os.DialogFlags.PickFolders, os.DialogFlags.PathMustExist) or nil
        }, function(err, path)
          if (not err or err == "") and path and path ~= "" then
            resultFolder = NormalizePath(path)
            storedSettings.resultFolder = resultFolder
            ui.toast(ui.Icons.Play, "Session result folder set")
          elseif err and err ~= "" then
            ui.toast(ui.Icons.Warning, "Error choosing folder: " .. err)
          end
        end)
      end
    end)
    if not dlgOk then
      ui.toast(ui.Icons.Warning, "Error opening folder dialog: " .. tostring(dlgErr))
    end
  end

  ui.setCursor(vec2(colX, ui.getCursor().y + 6))
  ui.pushFont(ui.Font.Small)
  if resultFolder ~= "" then
    ui.textWrapped("Result folder: " .. resultFolder)
    ui.setCursor(vec2(colX, ui.getCursor().y + 2))
    if ui.button("Reset to Default", vec2(230, 22)) then
      resultFolder = ""
      storedSettings.resultFolder = ""
    end
  else
    local resolved = ResultEffectiveFolder()
    if resolved ~= "" then
      ui.textColored("Result folder: " .. resolved .. " (default)", rgbm(0.6, 0.6, 0.7, 1))
      if ui.itemHovered() then
        ui.setTooltip("Documents\\Assetto Corsa\\mcr-results, which is also the dashboard default. Click 'Choose result folder...' to change it.")
      end
    else
      ui.textColored("Result folder: not resolved - please choose a folder", rgbm(1.0, 0.7, 0.35, 1))
    end
  end

  ui.setCursor(vec2(colX, ui.getCursor().y + 2))
  ui.textWrapped("Results are split into practice, qualifying and race subfolders. Point the dashboard's 'Lua App Result Path' at the same folder.")
  ui.setCursor(vec2(colX, ui.getCursor().y + 2))
  if resultExportStatus ~= "" then
    ui.textWrapped(resultExportStatus)
  else
    ui.textColored("No session result saved yet.", rgbm(0.6, 0.6, 0.7, 1))
  end
  ui.popFont()
  ui.dummy(vec2(0, 8))

  if valid then
    if ui.checkbox("Enable Multiple Class Race", enduranceEnabled) then
      enduranceEnabled = not enduranceEnabled
      storedSettings.enduranceEnabled = enduranceEnabled
    end

    if enduranceEnabled then

      if driverCount > 0 then
        ui.setCursor(vec2(colX, ui.getCursor().y))
        ui.text("Add Class (auto-assign by car tag):")
        ui.setCursor(vec2(colX, ui.getCursor().y + 4))
        ui.pushItemWidth(w - 48)
        classAddInput = ui.inputText("##NewReleaseClass", classAddInput or "")
        ui.popItemWidth()
        ui.setCursor(vec2(colX, ui.getCursor().y + 6))
        if ui.button("Add Class", vec2(w - 48, 28)) then
          local addOk, addErr = pcall(function()
            AddReleaseClass(classAddInput)
          end)
          if not addOk then
            classAddError = "Error adding class: " .. tostring(addErr)
          end
        end
        ui.setCursor(vec2(colX, ui.getCursor().y + 6))
        if ui.button("Verify", vec2(w - 48, 28)) then
          pcall(VerifyClassAssignments)
        end
        if ui.itemHovered() then
          ui.setTooltip("Use 'Add Class' first to assign cars by tag, then 'Verify' to check every car belongs to an added class.")
        end

        if classAddError then
          ui.setCursor(vec2(colX, ui.getCursor().y + 8))
          ui.pushFont(ui.Font.Small)
          ui.textColored(classAddError, rgbm.colors.red)
          ui.popFont()
        end

        if #releaseClasses > 0 then
          ui.setCursor(vec2(colX, ui.getCursor().y + 12))
          ui.text("Classes:")
          for ci = 1, #releaseClasses do
            local clsName = releaseClasses[ci]
            local carList = {}
            local count = 0
            for i = 0, driverCount - 1 do
              if manualDriverClass[i] == clsName then
                count = count + 1
                local cn = ac.getCarName and ac.getCarName(i) or sFormat("Car %d", i + 1)
                carList[#carList + 1] = cn
              end
            end
            ui.setCursor(vec2(colX + 8, ui.getCursor().y + 2))
            ui.text(sFormat("%s (%d car%s)", clsName, count, count == 1 and "" or "s"))
            if count > 0 then
              if ui.itemHovered() then
                ui.setTooltip("Cars: " .. table.concat(carList, ", "))
              end
            end
            ui.sameLine()
            ui.pushStyleVar(ui.StyleVar.FramePadding, vec2(6, 2))
            ui.pushStyleVar(ui.StyleVar.ButtonTextAlign, vec2(0.5, 0.5))
            if ui.button("Remove##removeclass" .. ci, vec2(64, 20)) then
              RemoveReleaseClass(ci)
            end
            ui.popStyleVar(2)
          end
        end

      else
        ui.setCursor(vec2(colX, ui.getCursor().y))
        ui.pushFont(ui.Font.Small)
        ui.textColored("Waiting for car data to load...", rgbm(0.6, 0.7, 0.9, 1))
        ui.popFont()
      end

    ui.dummy(vec2(0, 8))
    end

  else
    ui.setCursor(vec2(colX, ui.getCursor().y))
    ui.pushItemWidth(w - 48)
    ui.textWrapped(err or "Class-based mode cannot be enabled under current conditions!")
    ui.popItemWidth()
    ui.dummy(vec2(0, 8))
  end

  ui.popStyleVar()
end

ac.onSessionStart(function()
  firstFrame          = true
  raceHasStarted      = false
  playerStoppedState  = false
  raceDisplayStable   = nil
  raceDisplayPending  = nil
  gridReordered       = false
  classReloadAttempted = false
  carClassCache       = {}
  allDriversStartingPos = {}
  uiSourceCache       = {}
  if liveSessionPending then
    resultResetAfterExport = true
  else
    ResetResultExport()
    resultResetAfterExport = false
  end
  lastExportDiagnostic = nil
  Log("onSessionStart: firstFrame=true")
end)

if type(ac.onRelease) == "function" then
  local okRelease, releaseErr = pcall(ac.onRelease, ExportExpiredSessionOnRelease)
  if not okRelease then
    Log("EXPORT: failed to register release fallback: " .. tostring(releaseErr))
  end
end

Log("=== APP LOADED ===")
