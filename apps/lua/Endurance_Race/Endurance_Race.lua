local classGap                    = 3.0
local classDistanceGap            = 300.0
local maxLeaderboardRows         = 10
local leaderboardDisplayMode     = 2
local autoScrollInterval         = 5.0
local autoScrollTimer            = 0.0
local autoScrollIndex            = 1
local scrollOffset               = 0.0

local driverCount                 = 0
local allDriversStartingPos       = {}
local raceHasStarted              = false
local raceComplete                = false
local releaseTimer                = 0
local sessionTimer                = 0
local firstFrame                  = true
local leaderboardOpened           = false
local lastSessionIndex            = nil
local lastSessionStarted          = nil

local driverClass                 = {}
local classOrder                  = {}
local classToIndex                = {}
local classNames                  = {}
local classFirstPos               = {}
local classLastPos                = {}
local classStartTime              = {}
local classFirstDriver            = {}
local classGreen                  = {}
local classGreenTime              = {}
local nonClassGreen               = false
local releaseClasses              = {}
local manualDriverClass           = {}
local classAddInput               = ""
local classAddError               = nil
local carClassCache               = {}
local uiSourceCache               = {}

local storedSettings              = ac.storage({ classGap = 3.0, classDistanceGap = 300.0, maxLeaderboardRows = 10, leaderboardDisplayMode = 2, autoScrollInterval = 5.0, enduranceEnabled = true })

local classGapInput               = tostring(classGap)
local classDistanceGapInput       = tostring(classDistanceGap)
local maxLeaderboardRowsInput     = tostring(maxLeaderboardRows)
local autoScrollIntervalInput    = tostring(autoScrollInterval)
local enduranceEnabled           = true

local mFloor, mAbs, mMin, mMax = math.floor, math.abs, math.min, math.max
local sFormat = string.format
local getCar = ac.getCar
local setAITopSpeed = physics.setAITopSpeed
local setAICaution = physics.setAICaution
local setAIThrottleLimit = physics.setAIThrottleLimit

local DEBUG_ENABLED = false
local debugLogFile = nil
local function Log(msg)
  if not DEBUG_ENABLED then return end
  pcall(function()
    if not debugLogFile then
      debugLogFile = io.open("D:/Class Leaderboard/debug.log", "a")
    end
    if debugLogFile then
      debugLogFile:write(msg .. "\n")
      debugLogFile:flush()
    end
  end)
end

local function LogTrunc(msg)
  pcall(function()
    local f = io.open("D:/Class Leaderboard/debug.log", "w")
    if f then
      f:write(msg .. "\n")
      f:flush()
      f:close()
    end
    debugLogFile = nil
  end)
end

local function SaveCarClass(carID, cls)
  if not carID then return end
  pcall(function()
    ac.storage["carclass_" .. carID] = cls or ""
  end)
end

local function LoadCarClass(carID)
  if not carID then return nil end
  local ok, v = pcall(function()
    return ac.storage["carclass_" .. carID]
  end)
  if ok and v and v ~= "" then
    return v
  end
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
      SaveCarClass(ac.getCarID and ac.getCarID(i), n)
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
      SaveCarClass(ac.getCarID and ac.getCarID(i), "")
    end
  end
  classAddError = nil
  SaveClassNames()
  BuildClassInfo()
end

BuildClassInfo = function()
  Log(sFormat("BuildClassInfo: dc=%d entries=%d", driverCount, #manualDriverClass))
  driverClass = {}
  classOrder = {}
  classToIndex = {}
  classNames = {}
  classFirstPos = {}
  classLastPos = {}
  classStartTime = {}
  classFirstDriver = {}
  classGreen = {}
  classGreenTime = {}
  nonClassGreen = false

  if driverCount == 0 then return end

  local classMinPos = {}
  local classMaxPos = {}
  local classFirstDriverIdx = {}

  for i = 0, driverCount - 1 do
    local raw = manualDriverClass[i]
    local key
    if raw and raw ~= "" then
      key = "class" .. string.lower(raw)
      if not classNames[key] then
        classNames[key] = raw
      end
    end

    driverClass[i] = key

    if key then
      local pos = allDriversStartingPos[i] or (i + 1)
      if not classMinPos[key] or pos < classMinPos[key] then
        classMinPos[key] = pos
        classFirstDriverIdx[key] = i
      end
      if not classMaxPos[key] or pos > classMaxPos[key] then
        classMaxPos[key] = pos
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

  for idx, key in ipairs(classOrder) do
    classToIndex[key] = idx - 1
    classFirstPos[key] = classMinPos[key]
    classLastPos[key] = classMaxPos[key] or classMinPos[key]
    classFirstDriver[key] = classFirstDriverIdx[key]
  end

  local lastClassEndTime = 0
  for idx, key in ipairs(classOrder) do
    if idx == 1 then
      classStartTime[key] = 0
    else
      classStartTime[key] = lastClassEndTime + classGap
    end
    lastClassEndTime = classStartTime[key]
  end
  Log(sFormat("BuildClassInfo DONE: %d classes order={%s}", #classOrder, table.concat(classOrder, ",")))

end

local function GetClassGapFromLeader(driverIdx, leaderIdx)
  if leaderIdx == nil then return nil end
  local myKey = driverClass[driverIdx]
  local leadKey = driverClass[leaderIdx]
  if not myKey or not leadKey or myKey == leadKey then return nil end
  local myIdx = classToIndex[myKey]
  local leadIdx = classToIndex[leadKey]
  if myIdx and leadIdx and myIdx > leadIdx then
    return classDistanceGap
  end
  return nil
end

local function LoadManualClassesFromStorage()
  Log(sFormat("LoadManualClassesFromStorage: START driverCount=%d", driverCount))
  releaseClasses = {}
  local seen = {}
  local anyLoaded = false
  for i = 0, driverCount - 1 do
    local okID, carID = pcall(function() return ac.getCarID and ac.getCarID(i) end)
    if okID and carID then
      local cls = LoadCarClass(carID)
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
    else
      Log(sFormat("LoadManualClassesFromStorage: car %d ac.getCarID failed okID=%s carID=%s", i, tostring(okID), tostring(carID)))
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
            SaveCarClass(ac.getCarID and ac.getCarID(i), name)
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
  if storedSettings.classGap ~= nil then
    classGap = storedSettings.classGap
    classGapInput = tostring(classGap)
  end
  if storedSettings.classDistanceGap ~= nil then
    classDistanceGap = storedSettings.classDistanceGap
    classDistanceGapInput = tostring(classDistanceGap)
  end
  if storedSettings.maxLeaderboardRows ~= nil then
    maxLeaderboardRows = storedSettings.maxLeaderboardRows
    maxLeaderboardRowsInput = tostring(maxLeaderboardRows)
  end
  if storedSettings.leaderboardDisplayMode ~= nil then
    leaderboardDisplayMode = storedSettings.leaderboardDisplayMode
  end
  if storedSettings.autoScrollInterval ~= nil then
    autoScrollInterval = storedSettings.autoScrollInterval
    autoScrollIntervalInput = tostring(autoScrollInterval)
  end
  if storedSettings.enduranceEnabled ~= nil then
    enduranceEnabled = storedSettings.enduranceEnabled
  end
  BuildClassInfo()
end

local function FindReleaseClassIndex(name)
  local lower = string.lower(name or "")
  for ci = 1, #releaseClasses do
    if string.lower(releaseClasses[ci]) == lower then
      return ci
    end
  end
  return nil
end

local function IsCarReleased(driverIdx)
  local gridPos = allDriversStartingPos[driverIdx]
  if not gridPos then return true end
  local cls = driverClass[driverIdx]
  if cls then
    local startTime = classStartTime[cls]
    if startTime then
      return releaseTimer >= startTime
    end
  end
  local releaseGroup = mFloor((gridPos - 1) / 2)
  return releaseTimer >= releaseGroup * 1.5
end

local function HasNonClassDrivers()
  for i = 0, driverCount - 1 do
    if not driverClass[i] then
      return true
    end
  end
  return false
end

local function IsDriverGreen(driverIdx)
  local cls = driverClass[driverIdx]
  if cls then
    return classGreen[cls] == true
  end
  return nonClassGreen
end

local function UpdateClassGreenStates()
  for idx, key in ipairs(classOrder) do
    if not classGreen[key] then
      local fd = classFirstDriver[key]
      if fd ~= nil then
        local car = getCar(fd)
        if car and car.sessionLapCount > 0 then
          classGreen[key] = true
          classGreenTime[key] = sessionTimer
        end
      end
    end
  end

  if #classOrder > 0 then
    local lastKey = classOrder[#classOrder]
    if classGreen[lastKey] then
      nonClassGreen = true
    end
  end
end

local function HasAnyDriverCompletedLap1()
  for i = 0, driverCount - 1 do
    local car = getCar(i)
    if car and car.sessionLapCount > 0 then
      return true
    end
  end
  return false
end

local function AllCarsGreen()
  if #classOrder == 0 then
    return HasAnyDriverCompletedLap1()
  end
  for idx, key in ipairs(classOrder) do
    if not classGreen[key] then
      return false
    end
  end
  if HasNonClassDrivers() and not nonClassGreen then
    return false
  end
  return true
end

local function GetSessionNameLower()
  local sim = ac.getSim()
  local ok, name = pcall(function() return ac.getSessionName(sim.currentSessionIndex) end)
  if not ok or not name then return "" end
  return string.lower(name)
end

local function IsRaceMode()
  return GetSessionNameLower():find("race") ~= nil
end

local function IsEnduranceMode()
  return enduranceEnabled and IsRaceMode()
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
  if raceComplete then return end

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

  releaseTimer = releaseTimer + dt

  for i = 0, driverCount - 1 do
    local car = getCar(i)
    if car and i ~= 0 then
      if IsDriverGreen(i) or IsCarReleased(i) then
        setAITopSpeed(i, 999999.0)
        setAIThrottleLimit(i, 1.0)
        setAICaution(i, 1.0)
        physics.setAIStopCounter(i, 0.0)
      else
        setAITopSpeed(i, 0.0)
        setAIThrottleLimit(i, 0.0)
        physics.setAIStopCounter(i, 0.5)
      end
    end
  end

  UpdateClassGreenStates()

  if AllCarsGreen() and not raceComplete then
    raceComplete = true
    ReleaseAllCars()
  end
end

local function LeaderboardProgress(carIndex)
  local car = getCar(carIndex)
  if not car then return 0 end
  return (car.sessionLapCount or 0) + (car.splinePosition or 0)
end

local function GapToCar(meIdx, otherIdx, trackLength)
  local me = getCar(meIdx)
  local other = getCar(otherIdx)
  local d = (LeaderboardProgress(otherIdx) - LeaderboardProgress(meIdx)) * trackLength
  local speedMps = mMax(me and me.speedKmh or 0, other and other.speedKmh or 0) / 3.6
  if speedMps < 2 then return 0 end
  return d / speedMps
end

local function FormatLeaderboardGap(seconds, distM, trackLength)
  local sign = (seconds < 0) and "-" or "+"
  local v = math.abs(seconds)
  if v < 0.05 then return "-" end
  local laps = mFloor((distM + 0.001 * trackLength) / trackLength)
  if laps >= 1 then
    return sFormat("%s%dL", sign, laps)
  end
  if v >= 60 then
    local m = math.floor(v / 60)
    local s = math.floor(v - m * 60 + 0.5)
    if s >= 60 then m = m + 1; s = 0 end
    return sFormat("%s%d:%02d", sign, m, s)
  end
  return sFormat("%s%.1fs", sign, v)
end

local function FormatBestLap(lapTime)
  if not lapTime or lapTime <= 0 then return "-" end
  local m = mFloor(lapTime / 60)
  local s = lapTime - m * 60
  return sFormat("%d:%06.3f", m, s)
end

local function FormatQualifyingGap(seconds)
  if seconds == nil then return "-" end
  if seconds < 0.001 then return "-" end
  if seconds >= 60 then
    local m = mFloor(seconds / 60)
    local s = seconds - m * 60
    return sFormat("+%d:%06.3f", m, s)
  end
  return sFormat("+%.3f", seconds)
end

local function TruncateText(text, maxW)
  if ui.measureText(text).x <= maxW then return text end
  local ellipsis = "..."
  while #text > 1 do
    text = text:sub(1, -2)
    if ui.measureText(text .. ellipsis).x <= maxW then
      return text .. ellipsis
    end
  end
  return ellipsis
end

local function GetLeaderboardSections()
  local sections = {}
  local trackLength = ac.getSim().trackLengthM
  local MAX_ROWS_PER_CLASS = mMax(1, maxLeaderboardRows or 10)

  Log(sFormat("GetLeaderboardSections: classOrder=%d driverClass[0]='%s' releaseClasses=%d", #classOrder, driverClass[0] or "nil", #releaseClasses))

  local function addSection(title, drivers)
    local rows = {}
    for _, i in ipairs(drivers) do
      local car = getCar(i)
      if car then
        local prog = LeaderboardProgress(i)
        local ui = GetCarUISource(i)
        rows[#rows + 1] = {
          idx    = i,
          car    = ac.getCarName and ac.getCarName(i) or sFormat("Car %d", i + 1),
          team   = ac.getDriverTeam and ac.getDriverTeam(i) or "",
          driver = ac.getDriverName and ac.getDriverName(i) or "",
          badge  = ui.badge,
          lap    = car.sessionLapCount or 0,
          gap    = 0,
          prog   = prog
        }
      end
    end
    table.sort(rows, function(a, b)
      if a.prog ~= b.prog then return a.prog > b.prog end
      return a.idx < b.idx
    end)
    for ri, row in ipairs(rows) do
      row.pos = ri
    end
    for ri, row in ipairs(rows) do
      local ahead = rows[ri - 1]
      local behind = rows[ri + 1]
      local gapAhead = ahead and GapToCar(row.idx, ahead.idx, trackLength) or math.huge
      local gapBehind = behind and (-GapToCar(row.idx, behind.idx, trackLength)) or math.huge
      if gapAhead <= gapBehind then
        row.gap = gapAhead
        row.gapDist = ahead and ((ahead.prog - row.prog) * trackLength) or 0
      else
        row.gap = -gapBehind
        row.gapDist = behind and ((row.prog - behind.prog) * trackLength) or 0
      end
    end

    local displayed = rows
    if #rows > MAX_ROWS_PER_CLASS then
      local playerRank = nil
      for ri, row in ipairs(rows) do
        if row.idx == 0 then
          playerRank = ri
          break
        end
      end
      displayed = {}
      for i = 1, MAX_ROWS_PER_CLASS - 1 do
        displayed[#displayed + 1] = rows[i]
      end
      if playerRank and playerRank > MAX_ROWS_PER_CLASS - 1 then
        displayed[#displayed + 1] = rows[playerRank]
      else
        displayed[#displayed + 1] = rows[MAX_ROWS_PER_CLASS]
      end
    end

    sections[#sections + 1] = { title = title, rows = displayed, total = #rows }
  end

  if enduranceEnabled and #classOrder > 0 then
    for _, key in ipairs(classOrder) do
      local drivers = {}
      for i = 0, driverCount - 1 do
        if driverClass[i] == key then
          drivers[#drivers + 1] = i
        end
      end
      if #drivers > 0 then
        addSection(classNames[key] or key, drivers)
      end
    end
    local unassigned = {}
    for i = 0, driverCount - 1 do
      if not driverClass[i] then
        unassigned[#unassigned + 1] = i
      end
    end
    if #unassigned > 0 then
      addSection("Unassigned", unassigned)
    end
  else
    local drivers = {}
    for i = 0, driverCount - 1 do
      drivers[#drivers + 1] = i
    end
    if #drivers > 0 then
      addSection("All Cars", drivers)
    end
  end

  return sections, trackLength
end

local function GetTimeBasedLeaderboardSections()
  local sections = {}
  local ok, trackLen = pcall(function() return ac.getSim().trackLengthM end)
  local trackLength = ok and trackLen or 0
  local MAX_ROWS_PER_CLASS = mMax(1, maxLeaderboardRows or 10)

  local function addSection(title, drivers)
    local rows = {}
    local bestTime = nil
    for _, i in ipairs(drivers) do
      local okCar, car = pcall(getCar, i)
      if okCar and car then
        local okBt, btMs = pcall(function() return car.bestLapTimeMs end)
        if not okBt then btMs = nil end
        local bt = nil
        if btMs and type(btMs) == "number" and btMs > 0 then
          bt = btMs / 1000
        end
        local hasTime = bt ~= nil
        if hasTime and (bestTime == nil or bt < bestTime) then
          bestTime = bt
        end
        local okUi, uiSrc = pcall(GetCarUISource, i)
        if not okUi then uiSrc = { badge = nil } end
        local okName, carName = pcall(function() return ac.getCarName and ac.getCarName(i) end)
        if not okName then carName = nil end
        local okTeam, team = pcall(function() return ac.getDriverTeam and ac.getDriverTeam(i) end)
        if not okTeam then team = nil end
        local okDrv, driver = pcall(function() return ac.getDriverName and ac.getDriverName(i) end)
        if not okDrv then driver = nil end
        local okLap, lapCount = pcall(function() return car.sessionLapCount end)
        if not okLap then lapCount = 0 end
        rows[#rows + 1] = {
          idx     = i,
          car     = carName or sFormat("Car %d", i + 1),
          team    = team or "",
          driver  = driver or "",
          badge   = uiSrc.badge,
          bestLap = bt,
          hasTime = hasTime,
          lap     = lapCount or 0,
        }
      end
    end

    table.sort(rows, function(a, b)
      if a.hasTime and b.hasTime then
        if a.bestLap ~= b.bestLap then return a.bestLap < b.bestLap end
        return a.idx < b.idx
      end
      if a.hasTime then return true end
      if b.hasTime then return false end
      return a.idx < b.idx
    end)

    for ri, row in ipairs(rows) do
      row.pos = ri
      if row.hasTime and bestTime then
        row.gap = row.bestLap - bestTime
      else
        row.gap = nil
      end
    end

    local displayed = rows
    if #rows > MAX_ROWS_PER_CLASS then
      local playerRank = nil
      for ri, row in ipairs(rows) do
        if row.idx == 0 then
          playerRank = ri
          break
        end
      end
      displayed = {}
      for i = 1, MAX_ROWS_PER_CLASS - 1 do
        displayed[#displayed + 1] = rows[i]
      end
      if playerRank and playerRank > MAX_ROWS_PER_CLASS - 1 then
        displayed[#displayed + 1] = rows[playerRank]
      else
        displayed[#displayed + 1] = rows[MAX_ROWS_PER_CLASS]
      end
    end

    sections[#sections + 1] = { title = title, rows = displayed, total = #rows }
  end

  if enduranceEnabled and #classOrder > 0 then
    for _, key in ipairs(classOrder) do
      local drivers = {}
      for i = 0, driverCount - 1 do
        if driverClass[i] == key then
          drivers[#drivers + 1] = i
        end
      end
      addSection(classNames[key] or key, drivers)
    end
    local unassigned = {}
    for i = 0, driverCount - 1 do
      if not driverClass[i] then
        unassigned[#unassigned + 1] = i
      end
    end
    if #unassigned > 0 then
      addSection("Unassigned", unassigned)
    end
  else
    local drivers = {}
    for i = 0, driverCount - 1 do
      drivers[#drivers + 1] = i
    end
    if #drivers > 0 then
      addSection("All Cars", drivers)
    end
  end

  return sections, trackLength
end

local function GetFilteredLeaderboardSections()
  local sections, trackLength
  if IsRaceMode() then
    local ok, s, t = pcall(GetLeaderboardSections)
    if ok then sections, trackLength = s, t else sections, trackLength = {}, 0 end
  else
    local ok, s, t = pcall(GetTimeBasedLeaderboardSections)
    if ok then sections, trackLength = s, t else sections, trackLength = {}, 0 end
  end

  if leaderboardDisplayMode == 1 then
    local playerClass = driverClass[0]
    if playerClass then
      local playerClassName = classNames[playerClass]
      local filtered = {}
      for _, section in ipairs(sections) do
        if section.title:lower() == (playerClassName or ""):lower() then
          filtered[#filtered + 1] = section
        end
      end
      if #filtered > 0 then
        return filtered, trackLength
      end
    end
    return sections, trackLength
  elseif leaderboardDisplayMode == 3 then
    if #sections > 0 then
      if autoScrollIndex > #sections then autoScrollIndex = 1 end
      local single = { sections[autoScrollIndex] }
      return single, trackLength
    end
    return sections, trackLength
  end

  return sections, trackLength
end

function script.clLeaderboard(dt)
  local w = ui.windowWidth()
  local h = ui.windowHeight()
  local pad = 16

  ui.drawRectFilled(vec2(0, 0), vec2(w, h), rgbm(0.02, 0.03, 0.05, 0.82), 0)
  ui.drawRect(vec2(0, 0), vec2(w, h), rgbm(0.3, 0.3, 0.36, 0.7), 0, nil, 1.5)

  local raceMode = IsRaceMode()
  local totalSections = 0
  if leaderboardDisplayMode == 3 then
    local rawOk, rawSections, rawTrack
    if raceMode then
      rawOk, rawSections, rawTrack = pcall(GetLeaderboardSections)
    else
      rawOk, rawSections, rawTrack = pcall(GetTimeBasedLeaderboardSections)
    end
    if rawOk and rawSections then totalSections = #rawSections end
  end

  if leaderboardDisplayMode == 3 and totalSections > 0 then
    autoScrollTimer = autoScrollTimer + dt
    if autoScrollTimer >= autoScrollInterval then
      autoScrollTimer = autoScrollTimer - autoScrollInterval
      autoScrollIndex = autoScrollIndex + 1
      if autoScrollIndex > totalSections then autoScrollIndex = 1 end
      scrollOffset = w
    end
    if scrollOffset > 0.5 then
      local slideSpeed = w * 1.2
      scrollOffset = scrollOffset - slideSpeed * dt
      if scrollOffset < 0.5 then scrollOffset = 0 end
    end
  end

  local sections, trackLength = GetFilteredLeaderboardSections()
  if #sections == 0 then
    ui.setCursor(vec2(pad, 12))
    ui.text("No cars on the grid.")
    return
  end

  local rowH = 20
  local padX = 16
  local cursorScreenPos = ui.cursorScreenPos or ui.getCursorScreenPos
  if cursorScreenPos and ui.windowPos then
    local diff = cursorScreenPos().x - ui.windowPos().x
    if diff and diff > 0 and diff < w * 0.5 then padX = diff end
  end
  local contentW = w - 2 * padX
  local colPosRight = pad + 40
  local colCar = pad + 72
  local colGapRight = contentW - pad
  local colLapRight = colGapRight - 56
  local colDriverRight = colLapRight - 16
  local halfFlex = mMax(40, math.floor((colDriverRight - 12 - colCar) / 2))
  local carTextRight = colCar + halfFlex
  local colDriver = colDriverRight - halfFlex
  local totalY = 0

  local sx = (leaderboardDisplayMode == 3) and scrollOffset or 0

  ui.pushFont(ui.Font.Title)
  ui.setCursor(vec2(pad, 8))
  ui.text(raceMode and "Leaderboard" or "Standings")
  ui.popFont()
  local y = ui.getCursor().y + 6
  totalY = y

  ui.drawLine(vec2(pad, y), vec2(w - pad, y), rgbm(0.35, 0.35, 0.42, 0.6), 1)
  y = y + 6

  for _, section in ipairs(sections) do
    local barH = 26
    ui.drawRectFilled(vec2(pad + sx, y + 2), vec2(w - pad + sx, y + 2 + barH), rgbm(0.15, 0.17, 0.23, 0.95), 2)
    ui.drawRectFilled(vec2(pad + sx, y + 2), vec2(pad + 4 + sx, y + 2 + barH), rgbm(0.35, 0.65, 0.95, 1), 0)
    ui.pushFont(ui.Font.Title)
    local titleStr = section.title:upper()
    local titleW = ui.measureText(titleStr).x
    ui.setCursor(vec2(pad + sx + (w - 2 * pad - titleW) / 2, y + 2))
    ui.text(titleStr)
    ui.popFont()
    y = ui.getCursor().y + 6
    totalY = mMax(totalY, y)

    ui.pushStyleColor(ui.StyleColor.Text, rgbm(0.7, 0.7, 0.8, 1))
    ui.setCursor(vec2(colPosRight - ui.measureText("Pos").x + sx, y))
    ui.text("Pos")
    ui.setCursor(vec2(colCar + sx, y))
    ui.text("Car")
    ui.setCursor(vec2(colDriver + sx, y))
    ui.text("Driver")
    local lapHeader = raceMode and "Lap" or "Best"
    ui.setCursor(vec2(colLapRight - ui.measureText(lapHeader).x + sx, y))
    ui.text(lapHeader)
    ui.setCursor(vec2(colGapRight - ui.measureText("Gap").x + sx, y))
    ui.text("Gap")
    ui.popStyleColor()
    y = ui.getCursor().y + 3
    totalY = mMax(totalY, y)

    for _, row in ipairs(section.rows) do
      ui.drawLine(vec2(pad + sx, y), vec2(w - pad + sx, y), rgbm(0.25, 0.25, 0.3, 0.5), 1)
      if row.ellipsis then
        ui.pushStyleColor(ui.StyleColor.Text, rgbm(0.55, 0.55, 0.6, 1))
        ui.setCursor(vec2(colCar + sx, y + 2))
        ui.text("...")
        ui.popStyleColor()
      else
        local isPlayer = (row.idx == 0)
        if isPlayer then
          ui.drawRectFilled(vec2(pad + sx, y), vec2(w - pad + sx, y + rowH), rgbm(0.15, 0.55, 0.3, 0.4), 0)
        end
        if row.badge then
          ui.drawImage(row.badge, vec2(colCar - 26 + sx, y + 3), vec2(colCar - 6 + sx, y + 17), rgbm(1, 1, 1, 1))
        end
        ui.pushStyleColor(ui.StyleColor.Text, isPlayer and rgbm(0.35, 0.95, 0.45, 1) or rgbm(0.9, 0.9, 0.95, 1))
        local posText = sFormat("P%d", row.pos)
        ui.setCursor(vec2(colPosRight - ui.measureText(posText).x + sx, y + 2))
        ui.text(posText)
        local carText = TruncateText(row.team ~= "" and row.team or row.car, carTextRight - colCar)
        ui.setCursor(vec2(colCar + sx, y + 2))
        ui.text(carText)
        local driverText = TruncateText(row.driver ~= "" and row.driver or row.car, colDriverRight - colDriver)
        ui.setCursor(vec2(colDriver + sx, y + 2))
        ui.text(driverText)
        local lapText
        local gapText
        if raceMode then
          lapText = sFormat("L%d", row.lap)
          gapText = FormatLeaderboardGap(row.gap, row.gapDist, trackLength)
        else
          lapText = row.hasTime and FormatBestLap(row.bestLap) or "-"
          gapText = row.hasTime and FormatQualifyingGap(row.gap) or "-"
        end
        ui.setCursor(vec2(colLapRight - ui.measureText(lapText).x + sx, y + 2))
        ui.text(lapText)
        ui.setCursor(vec2(colGapRight - ui.measureText(gapText).x + sx, y + 2))
        ui.text(gapText)
        ui.popStyleColor()
      end
      y = ui.getCursor().y + 4
      totalY = mMax(totalY, y)
    end
    ui.drawLine(vec2(pad + sx, y), vec2(w - pad + sx, y), rgbm(0.25, 0.25, 0.3, 0.5), 1)
    y = y + 8
    totalY = mMax(totalY, y)
  end

  ui.setCursor(vec2(0, totalY))
  ui.dummy(vec2(0, 1))
end

function script.update(dt)
  local sim = ac.getSim()
  driverCount = sim.carsCount or 0

  local sessionChanged = false
  if lastSessionIndex ~= nil and lastSessionIndex ~= sim.currentSessionIndex then
    sessionChanged = true
  end
  if lastSessionStarted ~= nil and lastSessionStarted == true and sim.isSessionStarted == false then
    sessionChanged = true
  end
  if lastSessionStarted ~= nil and lastSessionStarted == false and sim.isSessionStarted == true and lastSessionIndex ~= nil then
    sessionChanged = true
  end
  if sessionChanged then
    firstFrame = true
    carClassCache = {}
    uiSourceCache = {}
  end
  lastSessionIndex = sim.currentSessionIndex
  lastSessionStarted = sim.isSessionStarted

  if firstFrame then
    Log(sFormat("FIRSTFRAME: idx=%s race=%s dc=%d rc=%d", tostring(sim.currentSessionIndex), tostring(IsRaceMode()), driverCount, #releaseClasses))
    raceComplete     = false
    leaderboardOpened = false
    releaseTimer     = 0
    sessionTimer     = 0
    raceHasStarted   = false
    allDriversStartingPos = {}
    if driverCount > 0 then
      LoadManualClassesFromStorage()
      if IsEnduranceMode() then
        RecordStartingPositions()
        ReorderGridByClass()
        ReleaseAllCars()
      end
    end
    firstFrame = false
    Log(sFormat("FIRSTFRAME DONE: rc=%d classes={%s}", #releaseClasses, table.concat(releaseClasses, ",")))
  end

  if #releaseClasses == 0 and driverCount > 0 then
    LoadManualClassesFromStorage()
    if #releaseClasses > 0 then
      BuildClassInfo()
      if IsEnduranceMode() then
        RecordStartingPositions()
        ReorderGridByClass()
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

  if IsEnduranceMode() and not sim.isSessionStarted then
    for i = 0, driverCount - 1 do
      local car = getCar(i)
      if car then
        allDriversStartingPos[i] = car.racePosition
      end
    end
    ReorderGridByClass()
  end

  sessionTimer = sessionTimer + dt

  if IsEnduranceMode() then
    ManageAIClassRelease(dt)
  end
end

function script.clConfig()
  local valid, err = CheckSessionValidity()
  local sim = ac.getSim()
  local w = ui.windowWidth()
  local h = ui.windowHeight()

  local colW = (w - 48 - 16) / 2
  local colX = 24
  local rx = 24 + colW + 16

  ui.pushStyleVar(ui.StyleVar.FramePadding, vec2(6, 6))

  ui.drawRectFilled(vec2(0, 0), vec2(w, h), rgbm(0.04, 0.05, 0.07, 0.85), 0)
  ui.drawRect(vec2(0, 0), vec2(w, h), rgbm(0.18, 0.18, 0.20, 0.6), 0, nil, 1)

  if valid then
    local raceMode = IsRaceMode()
    ui.pushFont(ui.Font.Title)
    local titleText = "Endurance Race Configuration"
    local titleSize = ui.measureText(titleText)
    local titleX = (w - titleSize.x) / 2
    ui.setCursor(vec2(titleX, 12))
    ui.text(titleText)
    ui.popFont()

    local separatorY = ui.getCursor().y + 10
    ui.drawLine(vec2(colX, separatorY), vec2(w - 24, separatorY), rgbm(0.25, 0.25, 0.28, 0.5), 1)
    ui.setCursor(vec2(colX, separatorY + 12))

    if ui.checkbox("Enable Endurance Race", enduranceEnabled) then
      enduranceEnabled = not enduranceEnabled
      storedSettings.enduranceEnabled = enduranceEnabled
    end

    if enduranceEnabled then

    local colTop = ui.getCursor().y + 4

    ui.setCursor(vec2(colX, ui.getCursor().y + 16))
    ui.text("Max Cars Per Class in Leaderboard:")
    ui.setCursor(vec2(colX, ui.getCursor().y + 6))
    ui.pushItemWidth(colW - 48)
    local maxRowsChanged
    maxLeaderboardRowsInput, maxRowsChanged = ui.inputText("##Max Leaderboard Rows Input", maxLeaderboardRowsInput or tostring(maxLeaderboardRows))
    if maxRowsChanged then
      local rowsVal = tonumber(maxLeaderboardRowsInput)
      if rowsVal and rowsVal >= 1 and rowsVal <= 100 then
        maxLeaderboardRows = math.floor(rowsVal)
        storedSettings.maxLeaderboardRows = maxLeaderboardRows
      end
    end
    ui.popItemWidth()
    local rowsCheck = tonumber(maxLeaderboardRowsInput)
    if not (rowsCheck and rowsCheck >= 1 and rowsCheck <= 100) then
      ui.setCursor(vec2(colX, ui.getCursor().y + 4))
      ui.pushFont(ui.Font.Small)
      ui.textColored("Invalid value. Enter a number from 1 to 100.", rgbm.colors.red)
      ui.popFont()
    end

    ui.setCursor(vec2(colX, ui.getCursor().y + 16))
    ui.text("Leaderboard Display:")
    ui.setCursor(vec2(colX + 8, ui.getCursor().y + 8))
    if ui.checkbox("Player Class Only", leaderboardDisplayMode == 1) then
      leaderboardDisplayMode = 1
      storedSettings.leaderboardDisplayMode = 1
      autoScrollTimer = 0
      autoScrollIndex = 1
      scrollOffset = 0
    end
    if ui.itemHovered() then
      ui.setTooltip("Only shows the leaderboard section for your car's class.")
    end
    ui.setCursor(vec2(colX + 8, ui.getCursor().y + 4))
    if ui.checkbox("All Classes", leaderboardDisplayMode == 2) then
      leaderboardDisplayMode = 2
      storedSettings.leaderboardDisplayMode = 2
      autoScrollTimer = 0
      scrollOffset = 0
    end
    if ui.itemHovered() then
      ui.setTooltip("Shows all class sections stacked vertically.")
    end
    ui.setCursor(vec2(colX + 8, ui.getCursor().y + 4))
    if ui.checkbox("Auto-Scroll", leaderboardDisplayMode == 3) then
      leaderboardDisplayMode = 3
      storedSettings.leaderboardDisplayMode = 3
      autoScrollTimer = 0
    end
    if ui.itemHovered() then
      ui.setTooltip("Shows one class at a time, cycling through all classes with a slide animation.")
    end

    if leaderboardDisplayMode == 3 then
      ui.setCursor(vec2(colX + 28, ui.getCursor().y + 8))
      ui.text("Seconds per class:")
      ui.setCursor(vec2(colX + 28, ui.getCursor().y + 4))
      ui.pushItemWidth(colW - 76)
      local intervalChanged
      autoScrollIntervalInput, intervalChanged = ui.inputText("##AutoScrollInterval", autoScrollIntervalInput or tostring(autoScrollInterval))
      if intervalChanged then
        local val = tonumber(autoScrollIntervalInput)
        if val and val >= 1 and val <= 60 then
          autoScrollInterval = val
          storedSettings.autoScrollInterval = val
        end
      end
      ui.popItemWidth()
      local intervalVal = tonumber(autoScrollIntervalInput)
      if not (intervalVal and intervalVal >= 1 and intervalVal <= 60) then
        ui.setCursor(vec2(colX + 28, ui.getCursor().y + 4))
        ui.pushFont(ui.Font.Small)
        ui.textColored("Invalid. Enter a number from 1 to 60.", rgbm.colors.red)
        ui.popFont()
      end
    end

    if raceMode then
      ui.setCursor(vec2(colX, ui.getCursor().y + 16))
      ui.text("Class Gap (Time Between Classes):")
      ui.setCursor(vec2(colX, ui.getCursor().y + 6))
      ui.pushItemWidth(colW - 48)
      local classGapChanged
      classGapInput, classGapChanged = ui.inputText("##Class Gap Input", classGapInput or tostring(classGap))
      if classGapChanged then
        local val = tonumber(classGapInput)
        if val and val >= 0 and val <= 60 then
          classGap = val
          storedSettings.classGap = val
          if driverCount > 0 then
            BuildClassInfo()
          end
        end
      end
      ui.popItemWidth()
      local classGapVal = tonumber(classGapInput)
      if not (classGapVal and classGapVal >= 0 and classGapVal <= 60) then
        ui.setCursor(vec2(colX, ui.getCursor().y + 4))
        ui.pushFont(ui.Font.Small)
        ui.textColored("Invalid value. Enter a number from 0 to 60.", rgbm.colors.red)
        ui.popFont()
      else
        ui.setCursor(vec2(colX, ui.getCursor().y + 4))
        ui.textDisabled("Seconds between each class release.")
      end

      ui.setCursor(vec2(colX, ui.getCursor().y + 16))
      ui.text("Minimum Distance Between Classes (m):")
      ui.setCursor(vec2(colX, ui.getCursor().y + 6))
      ui.pushItemWidth(colW - 48)
      local classDistGapChanged
      classDistanceGapInput, classDistGapChanged = ui.inputText("##Class Distance Gap Input", classDistanceGapInput or tostring(classDistanceGap))
      if classDistGapChanged then
        local distVal = tonumber(classDistanceGapInput)
        if distVal and distVal >= 0 and distVal <= 500 then
          classDistanceGap = distVal
          storedSettings.classDistanceGap = distVal
        end
      end
      ui.popItemWidth()
      local classDistGapVal = tonumber(classDistanceGapInput)
      if not (classDistGapVal and classDistGapVal >= 0 and classDistGapVal <= 500) then
        ui.setCursor(vec2(colX, ui.getCursor().y + 4))
        ui.pushFont(ui.Font.Small)
        ui.textColored("Invalid value. Enter a number from 0 to 500.", rgbm.colors.red)
        ui.popFont()
      else
        ui.setCursor(vec2(colX, ui.getCursor().y + 4))
        ui.textDisabled("Min gap (meters) between classes.")
      end
    end

      ui.setCursor(vec2(rx, colTop))
      local rightColX = rx

      if driverCount > 0 then
        ui.setCursor(vec2(rightColX, ui.getCursor().y))
        ui.text("Add Class (auto-assign by car tag):")
        ui.setCursor(vec2(rightColX, ui.getCursor().y + 4))
        ui.pushItemWidth(colW - 48)
        classAddInput = ui.inputText("##NewReleaseClass", classAddInput or "")
        ui.popItemWidth()
        ui.setCursor(vec2(rightColX, ui.getCursor().y + 6))
        if ui.button("Add Class", vec2(colW - 48, 28)) then
          local addOk, addErr = pcall(function()
            AddReleaseClass(classAddInput)
          end)
          if not addOk then
            classAddError = "Error adding class: " .. tostring(addErr)
          end
        end
        ui.setCursor(vec2(rightColX, ui.getCursor().y + 6))
        if ui.button("Verify", vec2(colW - 48, 28)) then
          pcall(VerifyClassAssignments)
        end
        if ui.itemHovered() then
          ui.setTooltip("Use 'Add Class' first to assign cars by tag, then 'Verify' to check every car belongs to an added class.")
        end

        if classAddError then
          ui.setCursor(vec2(rightColX, ui.getCursor().y + 8))
          ui.pushFont(ui.Font.Small)
          ui.textColored(classAddError, rgbm.colors.red)
          ui.popFont()
        end

        if #releaseClasses > 0 then
          ui.setCursor(vec2(rightColX, ui.getCursor().y + 12))
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
            ui.setCursor(vec2(rightColX + 8, ui.getCursor().y + 2))
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

        if raceMode then
          if #classOrder > 1 then
            ui.setCursor(vec2(rightColX, ui.getCursor().y + 12))
            ui.text("Release Order:")
            if ui.itemHovered() then
              ui.setTooltip(sFormat("Entire class is released at once. Each class starts %.1fs after the previous class has been released.", classGap))
            end
            for i = 1, #classOrder do
              local key = classOrder[i]
              local name = classNames[key] or key
              local startTime = classStartTime[key] or 0
              ui.setCursor(vec2(rightColX + 8, ui.getCursor().y + 2))
              if i == 1 then
                ui.text(sFormat("1. %s (starts at 0s)", name))
              else
                ui.text(sFormat("%d. %s (starts at %.1fs)", i, name, startTime))
              end
              local rci = FindReleaseClassIndex(name)
              if rci then
                ui.sameLine()
                ui.pushStyleVar(ui.StyleVar.FramePadding, vec2(6, 2))
                ui.pushStyleVar(ui.StyleVar.ButtonTextAlign, vec2(0.5, 0.5))
                if ui.button("Remove##rmorder" .. i, vec2(64, 20)) then
                  RemoveReleaseClass(rci)
                end
                ui.popStyleVar(2)
              end
            end
          elseif #classOrder == 1 then
            ui.setCursor(vec2(rightColX, ui.getCursor().y + 12))
            ui.text(sFormat("Single class: %s", classNames[classOrder[1]] or classOrder[1]))
            local rci1 = FindReleaseClassIndex(classNames[classOrder[1]] or classOrder[1])
            if rci1 then
              ui.sameLine()
              ui.pushStyleVar(ui.StyleVar.FramePadding, vec2(6, 2))
              ui.pushStyleVar(ui.StyleVar.ButtonTextAlign, vec2(0.5, 0.5))
              if ui.button("Remove##rmsingle", vec2(64, 20)) then
                RemoveReleaseClass(rci1)
              end
              ui.popStyleVar(2)
            end
          end
        end
      else
        ui.setCursor(vec2(rightColX, ui.getCursor().y))
        ui.pushFont(ui.Font.Small)
        ui.textColored("Waiting for car data to load...", rgbm(0.6, 0.7, 0.9, 1))
        ui.popFont()
      end

    ui.dummy(vec2(0, 8))
    end

  else
    ui.pushFont(ui.Font.Title)
    local errTitle = "Endurance Race Disabled"
    local errTitleSize = ui.measureText(errTitle)
    local errTitleX = (w - errTitleSize.x) / 2
    ui.setCursor(vec2(errTitleX, 12))
    ui.text(errTitle)
    ui.popFont()

    local separatorY = ui.getCursor().y + 10
    ui.drawLine(vec2(24, separatorY), vec2(w - 24, separatorY), rgbm(0.25, 0.25, 0.28, 0.5), 1)
    ui.setCursor(vec2(24, separatorY + 16))

    ui.pushItemWidth(w - 48)
    ui.textWrapped(err or "Class release cannot be enabled under current conditions!")
    ui.popItemWidth()
    ui.dummy(vec2(0, 8))
  end

  ui.popStyleVar()
end

ac.onSessionStart(function()
  firstFrame          = true
  raceHasStarted      = false
  raceComplete        = false
  releaseTimer        = 0
  sessionTimer        = 0
  carClassCache       = {}
  allDriversStartingPos = {}
  uiSourceCache       = {}
  autoScrollTimer     = 0
  autoScrollIndex     = 1
  scrollOffset        = 0
  Log("onSessionStart: firstFrame=true")
end)

Log("=== APP LOADED ===")
