local validators = {}

LOG_LEVEL = {
    INFO = "INFO",
    WARNING = "WARNING",
    UNRANKABLE = "UNRANKABLE"
}

function getColorForLogLevel(level)
    if level == LOG_LEVEL.INFO then
        return {0.4, 0.6, 1.0, 1.0}
    elseif level == LOG_LEVEL.WARNING then
        return {1.0, 0.85, 0.2, 1.0}
    elseif level == LOG_LEVEL.UNRANKABLE then
        return {1.0, 0.3, 0.3, 1.0}
    else
        return {1.0, 1.0, 1.0, 1.0}
    end
end

local standardDiffNames = {
    "Beginner", "Easy", "Normal", "Hard", "Insane", "Expert"
}

local selectedDiff = state.GetValue("selectedDiff") or "None"
local lastResults = state.GetValue("validationResults") or {}

function getAllMappedTimes()
    local activeTimes = {}

    for _, obj in ipairs(map.HitObjects) do
        table.insert(activeTimes, obj.StartTime)
        table.insert(activeTimes, obj.EndTime and obj.EndTime or obj.StartTime)
    end

    table.sort(activeTimes)
    return activeTimes
end

function registerValidator(func)
    table.insert(validators, func)
end

function runValidation(diff)
    local results = {}

    if not map or not map.HitObjects then
        table.insert(results, { message = "No map loaded.", level = LOG_LEVEL.INFO })
        return results
    end

    for _, validator in ipairs(validators) do
        local validatorResults = validator(diff)
        for _, res in ipairs(validatorResults) do
            table.insert(results, res)
        end
    end

    return results
end

registerValidator(function(diff)
    local issues = {}
    local laneObjects = {}

    for _, obj in ipairs(map.HitObjects) do
        local lane = obj.Lane
        if not laneObjects[lane] then
            laneObjects[lane] = {}
        end
        table.insert(laneObjects[lane], {
            start = obj.StartTime,
            finish = obj.EndTime and obj.EndTime or obj.StartTime,
            raw = obj
        })
    end

    for lane, objects in pairs(laneObjects) do
        table.sort(objects, function(a, b)
            return a.start < b.start
        end)

        for i = 1, #objects - 1 do
            local a = objects[i]
            local b = objects[i + 1]

            if a.start == b.start and a.finish == b.finish then
                table.insert(issues, {
                    message = string.format("Duplicate notes in lane %d at %dms", lane, a.start),
                    level = LOG_LEVEL.UNRANKABLE,
                    goToAction = a.start
                })
            elseif a.finish > b.start then
                table.insert(issues, {
                    message = string.format("Overlapping notes in lane %d at %dms", lane, b.start),
                    level = LOG_LEVEL.UNRANKABLE,
                    goToAction = b.start
                })
            end
        end
    end

    return issues
end)

registerValidator(function(diff)
    local issues = {}

    if not map or #map.HitObjects == 0 then
        table.insert(issues, {
            message = "No hit objects found.",
            level = LOG_LEVEL.UNRANKABLE
        })
        return issues
    end

    local songLength = map.TrackLength
    local activeTimes = getAllMappedTimes()
    local pauseThreshold = 3000

    local uniqueTimes = {}
    local lastSeen = nil

    for _, t in ipairs(activeTimes) do
        if t ~= lastSeen then
            table.insert(uniqueTimes, t)
            lastSeen = t
        end
    end

    local totalMappedTime = 0
    local last = uniqueTimes[1]

    for i = 2, #uniqueTimes do
        local current = uniqueTimes[i]
        local gap = current - last

        if gap <= pauseThreshold then
            totalMappedTime = totalMappedTime + gap
        end

        last = current
    end

    local percent = (totalMappedTime / songLength) * 100

    table.insert(issues, {
        message = string.format("Mapped activity: %.2f%%%% (%dms of %dms)", percent, totalMappedTime, songLength),
        level = LOG_LEVEL.INFO
    })

    if percent < 75 then
        table.insert(issues, {
            message = string.format("Less than 75%%%% of the song contains active mapping (%.2f%%%%)", percent),
            level = LOG_LEVEL.UNRANKABLE
        })
    end

    return issues
end)

registerValidator(function(diff)
    local issues = {}
    local lanesUsed = {}

    for _, obj in ipairs(map.HitObjects or {}) do
        lanesUsed[obj.Lane] = true
    end

    for lane = 1, 4 do
        if not lanesUsed[lane] then
            table.insert(issues, {
                message = string.format("No notes placed in required column %d", lane),
                level = LOG_LEVEL.UNRANKABLE
            })
        end
    end

    for lane = 5, 7 do
        if not lanesUsed[lane] then
            table.insert(issues, {
                message = string.format("Column %d is unused. If this is a 7K map, consider placing notes here. Otherwise it's unrankable.", lane),
                level = LOG_LEVEL.WARNING
            })
        end
    end

    return issues
end)

registerValidator(function(diff)
    local issues = {}

    local minLengthMs = 45000
    local trackLength = map.TrackLength or 0

    if trackLength < minLengthMs then
        table.insert(issues, {
            message = string.format("Map sound is too short: %.2fs (minimum is 45s)", trackLength / 1000),
            level = LOG_LEVEL.UNRANKABLE
        })
    end

    return issues
end)

registerValidator(function(diff)
    local issues = {}
    local mappedTimes = getAllMappedTimes()
    local breakUnrankableThreshold = 30000
    local breakWarningThreshold = 20000

    if #mappedTimes < 2 then return issues end

    local last = mappedTimes[1]

    for i = 2, #mappedTimes do
        local current = mappedTimes[i]
        local gap = current - last

        if gap >= breakUnrankableThreshold then
            table.insert(issues, {
                message = string.format("Break too long: %.2fs gap between %dms and %dms", gap / 1000, last, current),
                level = LOG_LEVEL.UNRANKABLE,
            })
        elseif gap >= breakWarningThreshold and gap < breakUnrankableThreshold then
            table.insert(issues, {
                message = string.format("Break is very long: %.2fs gap between %dms and %dms", gap / 1000, last, current),
                level = LOG_LEVEL.WARNING,
            })
        end

        last = current
    end

    return issues
end)

function draw()
    imgui.Begin("Single Map AutoMod")

    imgui.Text("Run validations as:")

    for _, diff in ipairs(standardDiffNames) do
        imgui.SameLine()
        if imgui.Button(diff) then
            selectedDiff = diff
            state.SetValue("selectedDiff", selectedDiff)
            lastResults = runValidation(diff)
            state.SetValue("validationResults", lastResults)
        end
    end

    imgui.Separator()
    imgui.Text("Selected Diff: " .. selectedDiff)

    if #lastResults == 0 then
        imgui.TextColored({0.2, 0.8, 0.2, 1.0}, "No issues found. Everything looks good!")
    else
        for _, res in ipairs(lastResults) do
            local color = getColorForLogLevel(res.level)
            imgui.TextColored(color, string.format("[%s] %s", res.level, res.message))

            if res.goToAction then
                imgui.SameLine()
                if imgui.Button("Go To") then
                    actions.GoToObjects(res.goToAction)
                end
            end
        end
    end

    imgui.End()
end
