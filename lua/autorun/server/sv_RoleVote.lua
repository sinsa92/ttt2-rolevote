local enabled = CreateConVar("rolevote_enabled", 1, {FCVAR_ARCHIVE, FCVAR_NOTIFY}, "Enable/Disable RoleVote"):GetBool()
local minPlayers = CreateConVar("rolevote_min_players", 7, {FCVAR_ARCHIVE, FCVAR_NOTIFY}, "Sets the minimum players that have to be online for RoleVote being active", 1):GetInt()
local voteban = CreateConVar("rolevote_voteban", 1, {FCVAR_ARCHIVE, FCVAR_NOTIFY}, "0: The players vote the roles that get activated 1: The players vote the roles that get banned"):GetBool()
local count = CreateConVar("rolevote_count", 1, {FCVAR_ARCHIVE, FCVAR_NOTIFY}, "Sets how many roles will be banned/activated", 1):GetInt()
local role_cooldown = CreateConVar("rolevote_role_cooldown", 1, {FCVAR_ARCHIVE, FCVAR_NOTIFY}, "Sets how many times a role can't be voted on after it has won a vote.", 0):GetInt()

util.AddNetworkString("RoleVote_open")
util.AddNetworkString("RoleVote_client_ready")
util.AddNetworkString("RoleVote_vote")
util.AddNetworkString("RoleVote_refresh_buttons")
util.AddNetworkString("RoleVote_msg")

if not sql.TableExists("rolevote") then
    sql.Query("CREATE TABLE rolevote(roles TEXT)")
end
local cd = {}
for _, v in pairs(sql.Query("SELECT * FROM rolevote")) do
    table.Add(cd, util.JSONToTable(v.roles))
end

local votes = {}

local function EnoughPlayers()
    local ready = 0
    local plys = player.GetAll()

    for i = 1, #plys do
        local ply = plys[i]
        if not IsValid(ply) or not ply:ShouldSpawn() then continue end
        ready = ready + 1
    end

    return ready >= minPlayers
end

local function EndVote()
    local function GetWinningKey(tbl)
        local highest = -math.huge
        local winner = nil

        for k, v in RandomPairs(tbl) do
            if (#v > highest) then
                winner = k
                highest = #v
            end
        end

        return winner
    end

    local winners = {}

    for i = 1, count do
        local r = GetWinningKey(votes)
        if votes[r] == nil or #votes[r] <= 0 then continue end
        table.insert(winners, string.lower(r))
        votes[r] = nil
    end

    if #winners <= 0 then return end
    sql.Query("INSERT INTO rolevote(roles) VALUES('" .. util.TableToJSON(winners) .. "')")

    while (tonumber(sql.Query("SELECT COUNT(*) FROM rolevote")[1]["COUNT(*)"]) > role_cooldown) do
        sql.Query("DELETE FROM rolevote WHERE rowid IN (SELECT rowid FROM rolevote LIMIT 1);")
    end

    hook.Add("TTT2RoleNotSelectable", "RoleVote_TTT2RoleNotSelectable", function(r)
        if voteban then
            return table.KeyFromValue(winners, r.name) ~= nil or nil
        else
            return table.KeyFromValue(winners, r.name) == nil or nil
        end
    end)
end

local function PrepTimerFinished()
    if EnoughPlayers() then
        hook.Remove("TTTPrepareRound", "RoleVote_TTTPrepareRound")
        if not enabled then return end
        EndVote()
    else
        timer.Adjust("RoleVote_PrepTimer", GetConVar("ttt_preptime_seconds"):GetInt(), 1, PrepTimerFinished)
        timer.Stop("RoleVote_PrepTimer")
    end
end

-- use timer instead of TTTBeginRound hook so that function is called just before the round starts when the roles aren't yet selected
hook.Add("Initialize", "RoleVote_Initialize", function()
    if not TTT2 then return end
    timer.Create("RoleVote_PrepTimer", GetConVar("ttt_firstpreptime"):GetInt(), 1, PrepTimerFinished)
    timer.Stop("RoleVote_PrepTimer")

    hook.Add("TTTPrepareRound", "RoleVote_TTTPrepareRound", function()
        timer.Start("RoleVote_PrepTimer")
    end)
end)

net.Receive("RoleVote_client_ready", function(len, ply)
    if not enabled or minPlayers > #player.GetAll() then return end
    local roles = {}

    for _, role in pairs(GetRoles()) do
        if table.KeyFromValue(cd, role.name) == nil and role:IsSelectable(false) and role ~= INNOCENT and role ~= TRAITOR then
            local roleData = {
                name = string.SetChar(role.name, 1, string.upper(role.name[1])),
                color = role.color
            }

            table.insert(roles, roleData)
        end
    end

    net.Start("RoleVote_open")
    net.WriteBit(voteban)
    net.WriteTable(roles)
    net.Broadcast()
    net.Start("RoleVote_refresh_buttons")
    net.WriteTable(votes)
    net.Broadcast()
end)

net.Receive("RoleVote_vote", function(len, ply)
    local role = net.ReadString()
    votes[role] = votes[role] or {}

    -- remove old vote
    for _, plys in pairs(votes) do
        table.RemoveByValue(plys, ply:SteamID64())
    end

    -- add new vote
    table.insert(votes[role], ply:SteamID64())
    -- refresh vgui
    net.Start("RoleVote_refresh_buttons")
    net.WriteTable(votes)
    net.Broadcast()
end)

concommand.Add("getRoles", function(ply)
    local function addRoles(aktive, tbl)
        tbl = tbl or {}
        local i = 0

        for _, role in pairs(GetRoles()) do
            if aktive and role:IsSelectable(false) or not aktive and not role:IsSelectable(false) and not role.notSelectable then
                i = i + 1
                table.insert(tbl, role.color)
                table.insert(tbl, string.SetChar(role.name, 1, string.upper(role.name[1])) .. " \t")

                if string.len(role.name) < 7 then
                    table.insert(tbl, "\t")
                end

                if i % 5 == 0 then
                    table.insert(tbl, "\n")
                end
            end
        end

        table.insert(tbl, "\n\n")

        return i
    end

    local msg = {}
    table.insert(msg, Color(255, 255, 255))
    table.insert(msg, "Aktive Roles: \n")
    addRoles(true, msg)

    if addRoles(false) > 0 then
        table.insert(msg, Color(255, 255, 255))
        table.insert(msg, "Deactivated Roles: \n")
        addRoles(false, msg)
    end

    net.Start("RoleVote_msg")
    net.WriteTable(msg)
    net.Send(ply)
end)