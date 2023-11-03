local PWSAbsorb = Grid2.statusPrototype:new("pws-absorb", false)

local Grid2 = Grid2
--local Grid2Options = Grid2Options
local UnitInRaid = UnitInRaid
local UnitInParty = UnitInParty
local UnitHealth = UnitHealth
local UnitHealthMax = UnitHealthMax
local GetSpellBonusHealing = GetSpellBonusHealing
local GetTalentInfo = GetTalentInfo
local UnitName = UnitFullName
local UnitGUID = UnitGUID
local select = select
local fmt = string.format
local contains = tContains

local RELATIVE_PERCENT = true
local ROSTER_UPDATE_EVENT = setmetatable( { 
	"GROUP_ROSTER_UPDATE", 
	"RAID_ROSTER_UPDATE", 
	"PLAYER_ENTERING_WORLD", 
	"PLAYER_UNGHOST", 
	"ENCOUNTER_END", 
	"GROUP_JOINED", 
	"GROUP_FORMED", 
	"PLAYER_TALENT_UPDATE"
}, {__index = function() return 0 end} )
local PWS_SKILL_POWER = {
	[48066] = { base = 2230, multi = 1 }, 
	[48065] = { base = 1951, multi = 1 }, 
	[25218] = { base = 1286, multi = 0.8 },
	[25217] = { base = 1144, multi = 0.55 }, 
	[10901] = { base = 964, multi = 0.35 }, 
	[10900] = { base = 783, multi = 0.05 }, 
	[10899] = { base = 622, multi = 0 }, 
	[10898] = { base = 499, multi = 0 }, 
	[6066] = { base = 394, multi = 0 }, 
	[6065] = { base = 313, multi = 0 }, 
	[3747] = { base = 244, multi = 0 }, 
	[600] = { base = 166, multi = 0 },
	[592] = { base = 94, multi = 0 },
	[17] = { base = 48, multi = 0 }	
}

local COMM_PREFIX = "G2PWS"
C_ChatInfo.RegisterAddonMessagePrefix(COMM_PREFIX)

----------------------------------------------------
-- Event handlers and addon comm
----------------------------------------------------
local RegisterEvent, UnregisterEvent, SendMessage
do
	local frame
	local delegate = {}
	function RegisterEvent(event, func)
		if not frame then
			frame = CreateFrame("Frame", "GRID2PWSFRAME")
			frame:SetScript( "OnEvent",  function(_, event, ...) delegate[event](...) end )
		end
		if not delegate[event] then frame:RegisterEvent(event) end
		delegate[event] = func
	end
	function UnregisterEvent(...)
		if frame then
			for i=select("#",...),1,-1 do
				local event = select(i,...)
				if delegate[event] then
					frame:UnregisterEvent( event )
					delegate[event] = nil
				end
			end
		end
	end
	function SendMessage(message, channel)
		ChatThrottleLib:SendAddonMessage("BULK", COMM_PREFIX, message, channel);
	end
end

----------------------------------------------------
-- PWS Functionality
----------------------------------------------------
local PWSEnable, PWSDisable, PWSIsActive, PWSGetPercent, PWSGetText
do
	local cache_absorb = {}
	local cache_talent = {}
	local currentRoster = {}
	local addonMessageDist = "GUILD"
	
	----------------------------------------------------
	-- Calculate max absorb from skill level and talents
	----------------------------------------------------
	local function GetTalentMultiplier(page, id)
		if cache_talent[page * id] ~= nil then return cache_talent[id] end
		
		local _, _, _, _, rank = GetTalentInfo(page, id)
		cache_talent[page * id] = rank
		return rank
	end
	
	local function GetMaxAbsorb(spellId)
		local setMulti = 1
		if (PWSAbsorb.dbx.t10Bonus) then
			setMulti = 1.05
		end
		
		local SP = GetSpellBonusHealing(2)
		local BT = GetTalentMultiplier(1, 14) * 0.08
		local TD = GetTalentMultiplier(1, 25) * 0.01
		local FP = GetTalentMultiplier(1, 16) * 0.02
		local IPW = GetTalentMultiplier(1, 5) * 0.05
		local SH = GetTalentMultiplier(2, 5) * 0.02
		local spell = PWS_SKILL_POWER[spellId]
		
		return math.floor(
			(spell.base + ((0.8068 + BT) * spell.multi) * SP) *
			(1 + IPW) *
			(1 + FP + TD + SH) *
			setMulti
		)
	end
	
	----------------------------------------------------
	-- Add absorb to unit
	----------------------------------------------------
	local function AddAbsorb(casterGUID, playerGUID, amount)
		local player = currentRoster[playerGUID]
		
		cache_absorb[player] = {
			["max"] = amount,
			["current"] = amount,
			["caster"] = casterGUID,
			["name"] = playerGUID
		}
		
		PWSAbsorb:UpdateIndicators(player)
	end
	
	local function AddAbsorbLocal(playerGUID, spellId)
		local maxAbsorb = GetMaxAbsorb(spellId) 
		local addonMessage = ("A"..":"..UnitGUID("player")..":"..playerGUID..":"..maxAbsorb);
		SendMessage(addonMessage, addonMessageDist);
		
		AddAbsorb(UnitGUID("player"), playerGUID, maxAbsorb)
	end
	
	----------------------------------------------------
	-- Drop absorb values from unit (let unit remain)
	----------------------------------------------------
	local function RemoveAbsorb(player) 
		if cache_absorb == nil or cache_absorb[player] == nil then return end
		cache_absorb[player].max = 0
		cache_absorb[player].current = 0
		PWSAbsorb:UpdateIndicators(player)
	end

	----------------------------------------------------
	-- Subtract absorb values
	----------------------------------------------------
	local function SubtractAbsorb(player, amount)
		if cache_absorb == nil or cache_absorb[player] == nil then return end
		cache_absorb[player].current = cache_absorb[player].current - amount
		PWSAbsorb:UpdateIndicators(player)
	end
	
	----------------------------------------------------
	-- Update current roster, for combat log exclusion. Bound to events through constant ROSTER_UPDATE_EVENT.
	----------------------------------------------------
	local function UPDATE_ACTIVE_ROSTER_LISTENER()
		local inRaid = UnitInRaid("player") ~= nil
		local inParty = UnitInParty("player")
		local pLen = inRaid and 40 or 4
		currentRoster = {}
		cache_talent = {}
		
		if inRaid or inParty then
			addonMessageDist = inRaid and "RAID" or "PARTY"
		
			for i=1,pLen do 
				local pId = inRaid and ("raid"..i) or ("party"..i)
				local guid = UnitGUID(pId)
				if guid ~= nil then
					currentRoster[guid] = pId
					if (cache_absorb[pId] ~= nil) then
						cache_absorb[pId].max = 0
						cache_absorb[pId].current = 0
					end
				end
				
				pId = inRaid and ("raidpet"..i) or ("partypet"..i)
				guid = UnitGUID(pId)
				if guid ~= nil then
					currentRoster[guid] = pId
					if (cache_absorb[pId] ~= nil) then
						cache_absorb[pId].max = 0
						cache_absorb[pId].current = 0
					end
				end
			end
			
			if inRaid then return end
		end
		
		currentRoster[UnitGUID("player")] = "player"
	end
	
	--local function UPDATE_PET(...) 
	--	local inRaid = UnitInRaid("player") ~= nil
	--	local inParty = UnitInParty("player")
	--	local pLen = inRaid and 40 or 4
	--	
	--	if inRaid or inParty then
	--		addonMessageDist = inRaid and "RAID" or "PARTY"
	--	
	--		for i=1,pLen do 
	--			local pId = inRaid and ("raidpet"..i) or ("partypet"..i)
	--			local guid = UnitGUID(pId)
	--			if guid ~= nil and currentRoster[guid] ~= nil then
	--				currentRoster[guid] = pId
	--				if (cache_absorb[pId] ~= nil) then
	--					cache_absorb[pId].max = 0
	--					cache_absorb[pId].current = 0
	--				end
	--			end
	--		end
	--	end
	--end
		
	----------------------------------------------------
	-- Tracking combat events for current roster (solo, party, raid)
	----------------------------------------------------
	local function COMBAT_LOG_EVENT_UNFILTERED_HANDLER(...)
		local timestamp, subEvent, _, sourceGUID, sourceName, sourceFlags, sourceRaidFlags, destGUID, destName, destFlags, destRaidFlags, spellId, spellName, _, _, _, _, _, amount = ...
		local player = currentRoster[destGUID]
		local sourcePlayer = currentRoster[sourceGUID]
		
		-- Make sure current player is in roster
		if player == nil then return end
		
		-- Subtract abosrb values on physical of spell damage
		if (subEvent == "SPELL_ABSORBED") then
			local casterGUID, meleeSpellId, meleeSpellName, _, extraSpellId, extraSpellName, _, spellAmount = select(15, ...)
			-- If none of the absorbs come from PWS, dont subtract (IE Divine Aegis, ...)
			local rSpellId = (casterGUID ~= UnitGUID("PLAYER")) and meleeSpellId or extraSpellId
			if (PWS_SKILL_POWER[rSpellId] == nil) then return end
			
			SubtractAbsorb(player, spellAmount ~= nil and spellAmount or amount)
			return
		end
		
		if (PWS_SKILL_POWER[spellId] == nil) then return end
		
		-- Reset absorb values when spell drops off
		if (subEvent == "SPELL_AURA_REMOVED") then
			RemoveAbsorb(player)
			return
		end
		
		-- Add absorb values when YOU cast a shield
		if ((subEvent == "SPELL_CAST_SUCCESS" or subEvent == "SPELL_AURA_APPLIED" or subEvent == "SPELL_AURA_REFRESH") and sourceGUID == UnitGUID("PLAYER")) then
			AddAbsorbLocal(destGUID, spellId)
		end
	end
	
	local function COMBAT_LOG_EVENT_UNFILTERED_LISTENER()
		COMBAT_LOG_EVENT_UNFILTERED_HANDLER(CombatLogGetCurrentEventInfo())
	end
	
	----------------------------------------------------
	-- For receiving addon messages and handling events from other players with the addon
	----------------------------------------------------
	local function ADDON_MESSAGE_HANDLER(prefix, message)
		if (prefix ~= COMM_PREFIX) then return end
		local event, caster, target, amount = strsplit(":", message)
		
		if (caster == UnitGUID("player")) then return end
		if (event == "A") then
			AddAbsorb(caster, target, tonumber(amount))
		end
	end
	
	----------------------------------------------------
	-- Exposed functions
	----------------------------------------------------
	function PWSEnable()
		for k,v in pairs(ROSTER_UPDATE_EVENT) do
			RegisterEvent(v, UPDATE_ACTIVE_ROSTER_LISTENER)
		end
		--RegisterEvent("UNIT_PET", UPDATE_PET)
		RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED", COMBAT_LOG_EVENT_UNFILTERED_LISTENER)
		RegisterEvent("CHAT_MSG_ADDON", ADDON_MESSAGE_HANDLER)
	end
	
	function PWSDisable()
		for k,v in pairs(ROSTER_UPDATE_EVENT) do
			UnregisterEvent(v)
		end
		UnregisterEvent("COMBAT_LOG_EVENT_UNFILTERED", "CHAT_MSG_ADDON")
	end
	
	function PWSIsActive(_,unit)
		if (cache_absorb == nil or cache_absorb[unit] == nil) then return false end
		return cache_absorb[unit] ~= nil and cache_absorb[unit].current ~= nil and cache_absorb[unit].current > 0
	end
	
	function PWSGetPercent(_,unit)
		if (PWSAbsorb.dbx.relativePercent) then
			local h = UnitHealthMax(unit)
			return cache_absorb[unit].current / h
		end
		return cache_absorb[unit].current / cache_absorb[unit].max
	end
	
	function PWSGetText(_,unit)
		return fmt("%.f", cache_absorb[unit].current)
	end
end

----------------------------------------------------
-- PWSAbsorb
-- Grid2 Status setup
----------------------------------------------------
PWSAbsorb.OnEnable = PWSEnable
PWSAbsorb.OnDisable = PWSDisable
PWSAbsorb.IsActive = PWSIsActive
PWSAbsorb.GetPercent = PWSGetPercent
PWSAbsorb.GetText = PWSGetText
PWSAbsorb.GetColor = Grid2.statusLibrary.GetColor

Grid2.setupFunc["pws-absorb"] = function(baseKey, dbx)
	Grid2:RegisterStatus(PWSAbsorb, {"color", "text", "percent"}, baseKey, dbx)
	return PWSAbsorb
end

Grid2:DbSetStatusDefaultValue("pws-absorb", {type = "pws-absorb", color1 = {r=1,g=1,b=1,a=1}})

local prev_LoadOptions = Grid2.LoadOptions
function Grid2:LoadOptions()
    Grid2Options:RegisterStatusOptions("pws-absorb", "misc", function(self, status, options)
		self:MakeStatusColorOptions(status, options, optionParams)
        options.relativePercent = {
			type  = "toggle",
			order = 10,
			width = "full",
			name  = "Relative percentage",
			desc  = "Calculate shield percentage against unit max health",
			get   = function ()	return status.dbx.relativePercent end,
			set   = function (_, v)
				status.dbx.relativePercent = v or nil
				status:UpdateDB()
				status:UpdateAllUnits()
			end,
		}
		options.t10Bonus = {
			type  = "toggle",
			order = 10,
			width = "full",
			name  = "T10 Bonus",
			desc  = "Do you have T10 4set bonus?",
			get   = function ()	return status.dbx.t10Bonus end,
			set   = function (_, v)
				status.dbx.t10Bonus = v or nil
				status:UpdateDB()
				status:UpdateAllUnits()
			end,
		}
    end, 
    {
        titleIcon = "Interface\\Icons\\Spell_holy_powerwordshield",
    })

    prev_LoadOptions(self)
end
