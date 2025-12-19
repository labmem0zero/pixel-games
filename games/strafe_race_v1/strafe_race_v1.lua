--[[
    Название: Strafe Race
    Автор: OpenAI ChatGPT
    Описание механики:
        Игрок управляет одной машиной, закрепленной по оси X. Машина двигается только по оси Y:
        клик слева от машины смещает ее вверх, клик справа — вниз. Вражеские машины появляются
        на правой границе и плывут к X=0. Игрок избегает столкновений и зарабатывает очки за
        пройденные препятствия.
]]
math.randomseed(os.time())
require("avonlib")

local CLog = require("log")
local CHelp = require("help")
local CJson = require("json")
local CTime = require("time")
local CAudio = require("audio")
local CColors = require("colors")

local tGame = {
    Cols = 24,
    Rows = 15,
    Buttons = {},
}
local tConfig = {}

local GAMESTATE_SETUP = 1
local GAMESTATE_GAME = 2
local GAMESTATE_POSTGAME = 3
local GAMESTATE_FINISH = 4

local bGamePaused = false
local iGameState = GAMESTATE_SETUP
local iPrevTickTime = 0
local iStageStartTime = nil

local tGameStats = {
    StageLeftDuration = 0,
    StageTotalDuration = 0,
    CurrentStars = 0,
    TotalStars = 0,
    CurrentLives = 0,
    TotalLives = 0,
    Players = {
        { Score = 0, Lives = 0, Color = CColors.CYAN },
        { Score = 0, Lives = 0, Color = CColors.NONE },
        { Score = 0, Lives = 0, Color = CColors.NONE },
        { Score = 0, Lives = 0, Color = CColors.NONE },
        { Score = 0, Lives = 0, Color = CColors.NONE },
        { Score = 0, Lives = 0, Color = CColors.NONE },
    },
    TargetScore = 0,
    StageNum = 1,
    TotalStages = 1,
    TargetColor = CColors.NONE,
    ScoreboardVariant = 6,
}

local tGameResults = {
    Won = false,
    AfterDelay = false,
    PlayersCount = 1,
    Score = 0,
    Color = CColors.CYAN,
}

local tFloor = {}
local tButtons = {}

local tFloorStruct = {
    iColor = CColors.NONE,
    iBright = CColors.BRIGHT0,
    bClick = false,
    bDefect = false,
    iWeight = 0,
}
local tButtonStruct = {
    bClick = false,
    bDefect = false,
}

local tPlayer = { x = 3, y = 8, alive = true, color = CColors.CYAN }
local tObstacles = {}
local iSpawnTimer = 0
local iQueuedDirection = 0

local iBackgroundBright = CColors.BRIGHT15
local iGridBright = CColors.BRIGHT30
local iLaneColor = CColors.BLACK
local iObstacleColor = CColors.RED
local fObstacleSpeed = 6 -- cells per second
local iSpawnIntervalMs = 800
local iPlayerStep = 1
local iCountdownSeconds = 3

local function ClampY(iY)
    return math.max(tGame.iMinY + 1, math.min(tGame.iMaxY - 1, iY))
end

local function ResetFloor()
    for iX = 1, tGame.Cols do
        for iY = 1, tGame.Rows do
            tFloor[iX][iY].iColor = CColors.GREEN
            if (iX + iY) % 2 == 0 then
                tFloor[iX][iY].iBright = iBackgroundBright
            else
                tFloor[iX][iY].iBright = iGridBright
            end
        end
    end
end

local function DrawBorders()
    for iX = tGame.iMinX, tGame.iMaxX do
        tFloor[iX][tGame.iMinY].iColor = iLaneColor
        tFloor[iX][tGame.iMinY].iBright = CColors.BRIGHT70
        tFloor[iX][tGame.iMaxY].iColor = iLaneColor
        tFloor[iX][tGame.iMaxY].iBright = CColors.BRIGHT70
    end

    for iY = tGame.iMinY, tGame.iMaxY do
        tFloor[tGame.iMinX][iY].iColor = iLaneColor
        tFloor[tGame.iMinX][iY].iBright = CColors.BRIGHT70
        tFloor[tGame.iMaxX][iY].iColor = iLaneColor
        tFloor[tGame.iMaxX][iY].iBright = CColors.BRIGHT70
    end
end

local function DrawPlayer()
    if not tPlayer.alive then return end
    local iX = tPlayer.x
    local iY = tPlayer.y
    tFloor[iX][iY].iColor = tPlayer.color
    tFloor[iX][iY].iBright = CColors.BRIGHT70
    if tFloor[iX][iY - 1] then
        tFloor[iX][iY - 1].iColor = tPlayer.color
        tFloor[iX][iY - 1].iBright = CColors.BRIGHT45
    end
    if tFloor[iX][iY + 1] then
        tFloor[iX][iY + 1].iColor = tPlayer.color
        tFloor[iX][iY + 1].iBright = CColors.BRIGHT45
    end
end

local function DrawObstacles()
    for _, tObs in ipairs(tObstacles) do
        local iX = math.floor(tObs.x + 0.5)
        local iY = tObs.y
        for dx = -1, 0 do
            if tFloor[iX + dx] and tFloor[iX + dx][iY] then
                tFloor[iX + dx][iY].iColor = iObstacleColor
                tFloor[iX + dx][iY].iBright = CColors.BRIGHT70
            end
        end
    end
end

local function SpawnObstacle()
    local iY = math.random(tGame.iMinY + 1, tGame.iMaxY - 1)
    table.insert(tObstacles, { x = tGame.iMaxX - 1, y = iY, scored = false })
end

local function HandlePlayerMove()
    if iQueuedDirection == 0 then return end
    tPlayer.y = ClampY(tPlayer.y + iQueuedDirection * iPlayerStep)
    iQueuedDirection = 0
end

local function HandleObstacles(iDeltaMs)
    local fDelta = iDeltaMs / 1000
    for i = #tObstacles, 1, -1 do
        local tObs = tObstacles[i]
        tObs.x = tObs.x - fObstacleSpeed * fDelta

        if math.abs(tObs.x - tPlayer.x) < 0.6 and tObs.y == tPlayer.y and tPlayer.alive then
            tPlayer.alive = false
            CAudio.PlaySystemAsync(CAudio.LOSE)
            iGameState = GAMESTATE_POSTGAME
        elseif tObs.x < tPlayer.x and not tObs.scored then
            tObs.scored = true
            tGameStats.Players[1].Score = tGameStats.Players[1].Score + 1
        end

        if tObs.x <= tGame.iMinX then
            table.remove(tObstacles, i)
        end
    end
end

local function UpdateTimers(iDeltaMs)
    iSpawnTimer = iSpawnTimer - iDeltaMs
    if iSpawnTimer <= 0 then
        SpawnObstacle()
        iSpawnTimer = iSpawnIntervalMs
    end
end

local function UpdateStageTimers()
    if not iStageStartTime then return end
    local iLeft = math.max(0, math.ceil(tGameStats.StageTotalDuration - (CTime.unix() - iStageStartTime)))
    tGameStats.StageLeftDuration = iLeft
    if iLeft <= 0 and iGameState == GAMESTATE_GAME then
        iGameState = GAMESTATE_POSTGAME
        tGameResults.Won = true
    end
end

local function DrawCountdown()
    for iY = tGame.iMinY + 2, tGame.iMaxY - 2 do
        tFloor[tGame.iMaxX - 1][iY].iColor = CColors.WHITE
        tFloor[tGame.iMaxX - 1][iY].iBright = CColors.BRIGHT30
    end
    local iCenterY = tGame.CenterY or math.floor((tGame.iMaxY - tGame.iMinY) / 2)
    local iCount = CGameMode.iCountdown
    if iCount >= 0 then
        local tDigits = {
            [3] = { {0,0},{1,0},{2,0},{0,1},{1,1},{2,1},{0,2},{1,2},{2,2} },
            [2] = { {0,0},{1,0},{2,0},{2,1},{0,1},{0,2},{1,2},{2,2} },
            [1] = { {1,0},{1,1},{1,2} },
            [0] = { {0,0},{2,0},{0,2},{2,2},{0,1},{1,1},{2,1} },
        }
        for _, pos in ipairs(tDigits[iCount] or {}) do
            local iX = tGame.iMaxX - 2 + pos[1]
            local iY = iCenterY + pos[2] - 1
            if tFloor[iX] and tFloor[iX][iY] then
                tFloor[iX][iY].iColor = CColors.WHITE
                tFloor[iX][iY].iBright = CColors.BRIGHT70
            end
        end
    end
end

function StartGame(gameJson, gameConfigJson)
    tGame = CJson.decode(gameJson)
    tConfig = CJson.decode(gameConfigJson)

    for iX = 1, tGame.Cols do
        tFloor[iX] = {}
        for iY = 1, tGame.Rows do
            tFloor[iX][iY] = CHelp.ShallowCopy(tFloorStruct)
        end
    end

    for _, iId in pairs(tGame.Buttons) do
        tButtons[iId] = CHelp.ShallowCopy(tButtonStruct)
    end

    iPrevTickTime = CTime.unix()

    if AL.RoomHasNFZ(tGame) then
        AL.LoadNFZInfo()
    end

    tGame.iMinX = 1
    tGame.iMinY = 1
    tGame.iMaxX = tGame.Cols
    tGame.iMaxY = tGame.Rows
    if AL.NFZ.bLoaded then
        tGame.iMinX = AL.NFZ.iMinX
        tGame.iMinY = AL.NFZ.iMinY
        tGame.iMaxX = AL.NFZ.iMaxX
        tGame.iMaxY = AL.NFZ.iMaxY
    end
    tGame.CenterX = math.floor((tGame.iMaxX - tGame.iMinX + 1) / 2)
    tGame.CenterY = math.ceil((tGame.iMaxY - tGame.iMinY + 1) / 2)

    tPlayer.x = math.max(tGame.iMinX + 2, 3)
    tPlayer.y = ClampY(tGame.CenterY)
    tPlayer.color = tConfig.PlayerColor or tPlayer.color
    iBackgroundBright = tConfig.BackgroundBright or iBackgroundBright
    iGridBright = tConfig.GridBright or iGridBright
    iObstacleColor = tConfig.ObstacleColor or iObstacleColor
    fObstacleSpeed = tConfig.ObstacleSpeed or fObstacleSpeed
    iSpawnIntervalMs = tConfig.SpawnIntervalMs or iSpawnIntervalMs
    iPlayerStep = tConfig.PlayerStep or iPlayerStep
    iCountdownSeconds = tConfig.CountdownSeconds or iCountdownSeconds

    tGameStats.StageTotalDuration = tConfig.TimeLimit or 60
    tGameStats.StageLeftDuration = tGameStats.StageTotalDuration
    tGameResults.Color = tPlayer.color
    tGameResults.Score = 0
    tGameResults.Won = false

    CGameMode.InitGameMode()
    CGameMode.StartCountDown(iCountdownSeconds)
end

function NextTick()
    if iGameState == GAMESTATE_SETUP then
        GameSetupTick()
    end

    if iGameState == GAMESTATE_GAME then
        GameTick()
    end

    if iGameState == GAMESTATE_POSTGAME then
        PostGameTick()
        if not tGameResults.AfterDelay then
            tGameResults.AfterDelay = true
            return tGameResults
        end
    end

    if iGameState == GAMESTATE_FINISH then
        tGameResults.AfterDelay = false
        return tGameResults
    end

    AL.CountTimers((CTime.unix() - iPrevTickTime) * 1000)
    iPrevTickTime = CTime.unix()
end

function GameSetupTick()
    ResetFloor()
    DrawBorders()
    DrawCountdown()
end

function GameTick()
    if not iStageStartTime then
        iStageStartTime = CTime.unix()
    end
    local iNow = CTime.unix()
    local iDeltaMs = (iNow - iPrevTickTime) * 1000

    if bGamePaused then
        ResetFloor()
        DrawBorders()
        DrawObstacles()
        DrawPlayer()
        return
    end

    ResetFloor()
    DrawBorders()
    HandlePlayerMove()
    HandleObstacles(iDeltaMs)
    UpdateTimers(iDeltaMs)
    UpdateStageTimers()
    DrawObstacles()
    DrawPlayer()

    if iGameState == GAMESTATE_POSTGAME then
        tGameResults.Score = tGameStats.Players[1].Score
        tGameResults.PlayersCount = 1
    end
end

function PostGameTick()
    ResetFloor()
    DrawBorders()
    DrawObstacles()
    DrawPlayer()
    tGameResults.Score = tGameStats.Players[1].Score
    if not tGameResults.AfterDelay then
        AL.NewTimer(1500, function()
            iGameState = GAMESTATE_FINISH
        end)
    end
end

function RangeFloor(setPixel, setButton)
    for iX = 1, tGame.Cols do
        for iY = 1, tGame.Rows do
            setPixel(iX , iY, tFloor[iX][iY].iColor, tFloor[iX][iY].iBright)
        end
    end

    for i, tButton in pairs(tButtons) do
        setButton(i, tButton.iColor, tButton.iBright)
    end
end

function SwitchStage()
end

CGameMode = {}
CGameMode.iCountdown = 0
CGameMode.bCountDownStarted = false

CGameMode.InitGameMode = function()
    CGameMode.bCountDownStarted = false
    CGameMode.iCountdown = 0
end

CGameMode.StartCountDown = function(iCountDownTime)
    CGameMode.bCountDownStarted = true
    CGameMode.iCountdown = iCountDownTime

    AL.NewTimer(1000, function()
        if CGameMode.iCountdown <= 0 then
            CGameMode.StartGame()
            return nil
        else
            CAudio.PlayLeftAudio(CGameMode.iCountdown)
            CGameMode.iCountdown = CGameMode.iCountdown - 1
            return 1000
        end
    end)
end

CGameMode.StartGame = function()
    CAudio.PlayVoicesSync(CAudio.START_GAME)
    CAudio.PlayRandomBackground()
    iGameState = GAMESTATE_GAME
    iStageStartTime = CTime.unix()
    iSpawnTimer = 0
    tObstacles = {}
    tPlayer.alive = true
    tGameResults.AfterDelay = false
    tGameResults.Won = false
end

function GetStats()
    return tGameStats
end

function PauseGame()
    bGamePaused = true
end

function ResumeGame()
    bGamePaused = false
    iPrevTickTime = CTime.unix()
end

function PixelClick(click)
    if bGamePaused then return end
    if not (tFloor[click.X] and tFloor[click.X][click.Y]) then return end

    if iGameState == GAMESTATE_SETUP then
        return
    end

    if click.Click then
        if click.X < tPlayer.x then
            iQueuedDirection = -1
        elseif click.X > tPlayer.x then
            iQueuedDirection = 1
        end
    end
end

function DefectPixel(defect)
    if tFloor[defect.X] and tFloor[defect.X][defect.Y] then
        tFloor[defect.X][defect.Y].bDefect = defect.Defect
    end
end

function ButtonClick(click)
    if tButtons[click.Button] == nil or bGamePaused or tButtons[click.Button].bDefect then return end
    tButtons[click.Button].bClick = click.Click
end

function DefectButton(defect)
    if tButtons[defect.Button] == nil then return end
    tButtons[defect.Button].bDefect = defect.Defect

    if defect.Defect then
        tButtons[defect.Button].iColor = CColors.NONE
        tButtons[defect.Button].iBright = CColors.BRIGHT0
    end
end
