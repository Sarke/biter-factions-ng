require("util")

--define some parameters, will move these to mod settings parameters at some point.
local factionCount = 5 -- number of biter factions to distribute evenly among each new chunk generated and the biters which spawn on it.
local attackWaveChance = 0.10 --baseline chance for sending an attack to nearest detected units of an enemy faction.
local playerAttackChanceReduction = 0.25 -- modifier to units' chance of attack if the detected nearest enemy is player' forces. 25% less likely to launch an attack against a player than against other forces.
local attackWavePeriod = 3000 -- baseline attack period/cooldown, to then check attack chances.
local evoPeriodModifier = 0.5 -- adjustment to attack wave period/frequency, based on evolution percent. current evo * modifier = REDUCTION of attack cooldown period.
local evoChanceModifier = 0.1 -- additional chance based on evolution percent.  current evo % * modifier = additional chance to send attack.
local periodDither = 600 --random amount to dither each faction's next attack by, so they don't all line up on the same tick.
local tickSpreading = 10 -- amount to spread the tick processing for chunk processing.

function debugPrint(msg)
	if settings.global["biter-factions-debug-mode"].value then
		game.print(msg)
	end
end

function initHandler(event)
	game.print("Running Biter Factions Init handler!")
	storage.factionList = storage.factionList or {}
	storage.nextAttackTick = storage.nextAttackTick or {}
	storage.nests = storage.nests or {}
	createForces()
	storage.initOnNextTick = 1
end

--generates the biter action forces, with generic names, based on the factioncount parameter. inits them with the current state of the 'enemy' force.
function createForces()
	game.print("Creating forces!")
	local enemy = game.forces["enemy"]
	for i = 1, factionCount do
		local force_name = "biter_faction_" .. i
		local force = game.forces[force_name]

		if not force then
			force = game.create_force(force_name)
			debugPrint("Created biter faction: " .. force.name)
		else
			game.print("Got into a wierd situation - force exists but storage was not init with them!")
			debugPrint("Found existing biter faction: " .. force.name)
		end

		storage.factionList[i] = force
		storage.nests[i] = {}
		force.ai_controllable = true
		force.set_evolution_factor(enemy.get_evolution_factor())
		force.set_evolution_factor_by_pollution(enemy.get_evolution_factor_by_pollution())
		force.set_evolution_factor_by_time(enemy.get_evolution_factor_by_time())
		force.set_evolution_factor_by_killing_spawners(enemy.get_evolution_factor_by_killing_spawners())

		--init the values for last attack tick and the next expected attack ticks, with no modifiers used yet.
		storage.nextAttackTick[i] = game.tick + attackWavePeriod + math.random(periodDither)
	end
end


--handles converting any "enemy" entities to one of the random factions when a chunk is generated (for the first time) or charted by radar.
--note this means there will basically never be an "enemy" force entities in the game map after this has run on all existing chunks and any new ones
--generated
function chunkGenHandler(event)
	local chunkarea = event.area
	local surface = event.surface

	if not surface then
		surface = game.get_surface(event.surface_index) --means it was an on-charted event
	end

	if not surface then
		return
	end

	getChunkNestsAndAllocate(chunkarea, surface)
end


-- given input chunk area from generated/iterated chunk, find nests in the chunk and assign to random faction.
function getChunkNestsAndAllocate(chunkarea, surface)
	if not storage.factionList then
		game.print("error in getChunkNestsAndAllocate 1")
		return
	end
	if #storage.factionList < 1 then
		game.print("error in getChunkNestsAndAllocate 2")
		return
	end

	local factionIndex = math.random(#storage.factionList)

	if not factionIndex or not storage.factionList[factionIndex] then
		game.print("error in getChunkNestsAndAllocate 3 ")
		return
	end

	local force = storage.factionList[factionIndex] --random force index from 1 to factionlist length
	local entitiesList = surface.find_entities_filtered({area = chunkarea, force = "enemy"})

	local randVal = 0
	local destroyed = false

	local cullSetting = settings.global["Culling-Per-Chunk"].value --read in the settings from global because we are about to use it a lot
	debugPrint(string.format("culling setting is %f", cullSetting))
	debugPrint(string.format("number of entities in chunk %d", #entitiesList))
	for i, entity in pairs(entitiesList) do
		randVal = math.random()
		destroyed = false
		if entity and entity.valid then
			entity.force = force --change the entity's force. nest, worm, biters should all be affected.
			if randVal <= cullSetting then
				debugPrint(string.format("culling critter with name %s", entity.name))
				entity.destroy()
				destroyed = true
			end
			--if it's a spawner, add to the force's spawner list.
			if not destroyed and entity.type == "unit-spawner" then
				if not storage.nests[factionIndex] then
					storage.nests[factionIndex] = {}
				end
				storage.nests[factionIndex][entity.unit_number] = entity --store the entity by its unit number in the force's list.
				debugPrint("Faction " .. factionIndex .. " has " .. table_size(storage.nests[factionIndex]) .. " nests!")
			end

			--special case for big monsters mod, making ridiculously powerful worms. try to cut them down to 1% health to give a chance to kill them in civil wars.
			if not destroyed and script.active_mods["Big-Monsters"] and entity.type == "turret" then
				if string.find(entity.name, "worm") or string.find(entity.name, "Worm") then
					if entity.health then -- if it has a health field.
						--game.print("entity health: "..entity.health.." prototype max health: "..entity.max_health)
						entity.health = entity.health * 0.01 --set it  down to 5% health to give them a chance to kill eachother.
						--game.print("after damage... entity health: "..entity.health.." prototype max health: "..entity.max_health)
					end
				end
			end --end if special attention for ridiculously powerful worms from "big monsters" mod.
		end --end if entity is  valid
	end
end

--tick handler function, handles logic for all the tick-spreading features which would normally tank people's PCs.
--this runs logic to send waves of attacks from each biter factions base to nearby enemy units,  i.e other biter faction nests and the player's base, whichever is closer..
--once a biter faction becomes dominant, it will mostly send its armies to the player's base. Beware!
function runTickHandler(event)
	storage.factionList = storage.factionList or {}
	storage.nextAttackTick = storage.nextAttackTick or {}
	storage.nests = storage.nests or {}

	if not storage.factionList[1] or #storage.factionList < 1 then
		game.print("Detected empty or non-functional factionList... Creating Forces...")
		createForces()
		game.print("Preparing to boostrap nests... please wait until this completes!")
		for i, force in pairs(storage.factionList) do
			if not storage.nests[i] then
				storage.nests[i] = {}
			end
		end
		bootstrapNestTables()
	end

	if storage.initOnNextTick and storage.initOnNextTick == 1 then
		storage.initOnNextTick = 0
		bootstrapNestTables()
	end

	if (game.tick % tickSpreading == 0) then
		if storage.chunkProgress and storage.chunkIteratorLimit then
			if (storage.chunkProgress < storage.chunkIteratorLimit) then
				if (storage.chunkProgress % 100 == 0) then
					debugPrint("Biter Faction chunk processing progress... " .. storage.chunkProgress .. " out of " .. storage.chunkIteratorLimit)
				end
				local surface = game.get_surface(1)
				if not surface or not surface.valid then
					game.print("Surface nil or invalid! Cannot process")
					return
				end

				if not storage.chunksList[storage.chunkProgress] then
					game.print("Error accessing chunk list at index " .. storage.chunkProgress)
					storage.chunkProgress = storage.chunkIteratorLimit
					return
				end

				local chunk = storage.chunksList[storage.chunkProgress]
				--if not chunk or not chunk.valid then
				--    game.print("chunk nil or invalid! Cannot process")
				--    return
				--end


				getChunkNestsAndAllocate(chunk.area, surface)
				storage.chunkProgress = storage.chunkProgress + 1
			end
		end
	end


	-- check each force for if it's their time to send an attack. each force has its own evolution % which will affect its aggression.
	for i, force in pairs(storage.factionList) do
		--compare tick
		if not storage.nextAttackTick[i] then
			storage.nextAttackTick[i] = event.tick
		end
		if event.tick >= storage.nextAttackTick[i] then
			-- calculate chance of attack this time around
			-- if attack should go ahead, then trigger the attack flags for that faction and reset attack progress.

			local evoChanceAdj = evoChanceModifier * force.get_evolution_factor() --the chance of triggering an attack. the playerAttackChanceReduction is used later during targeting, as a chance to just not go ahead with the attack.
			local shouldAttack = math.random() <= (attackWaveChance + evoChanceAdj) -- random % value computed, if the generated % value is equal or less than the chance to trigger, it triggers.

			if shouldAttack then
				debugPrint("biter faction: " .. force.name .. " is launching an attack. Beware!")
				--do the attack launch code.


				--ensure there is a list of nests. if there isn't quickly generate one to get started..


				--check and init tables as needed, to schedule an attack for this faction.
				if not storage.scheduledAttack then
					storage.scheduledAttack = {}
				end
				storage.scheduledAttack[i] = 1 --set this faction's index to start an attack.

				if not storage.attackProgress then
					storage.attackProgress = {}
				end
				storage.attackProgress[i] = 0 --set this faction's attack progress to 0, so it can be incremented in the proceeding ticks.
			end --if should attack trigger

			--now calculate when this faction should check for another attack.
			local evoPeriodAdj = force.get_evolution_factor() * evoPeriodModifier
			storage.nextAttackTick[i] = event.tick + attackWavePeriod + math.random(periodDither) - evoPeriodAdj
		end --end of if next attack tick equal/exceeded

		--check for if attack is active for this faction, and initate the next wave of attacking nests.
		if (storage.scheduledAttack and storage.scheduledAttack[i] == 1) then
			local progress = 0

			if storage.nests[i] and (table_size(storage.nests[i]) > 0) then
				for key, nest in pairs(storage.nests[i]) do
					progress = progress + 1
					if nest.valid and progress == storage.attackProgress[i] then
						--find nearest enemy within 3k tiles.
						local enemy = nest.surface.find_nearest_enemy({position = nest.position, max_distance = 3000, force = nest.force})
						if enemy and enemy.valid then --if we found an enemy nearby.. should we attack it? ...
							local keepAttacking = 1
							if enemy.force.name == "player" then
								keepAttacking = math.random() <= playerAttackChanceReduction --if random returns less than or equal to the chance to avoid attacking if target is player, then call off the attack!
							end

							if keepAttacking then
								--get list of nearby entities of type "unit" to give attack orders.
								--alternatively... get the unit's owned directly from the spawner , regardless of position! :) Much more efficient.
								local unitList = nest.units --nest.surface.find_entities_filtered{area = chunkarea, force = force.name, type ="unit"}

								--give the attack command!
								for k, entity in pairs(unitList) do
									if entity.commandable then
										entity.commandable.set_command({type = defines.command.attack_area, destination = enemy.position, radius = 32, distraction = defines.distraction.by_anything})
									end
								end
							end
						end
					else
						if not nest.valid then
							storage.nests[i][key] = nil --wipe out this entry, it's dead/invalid now.
						end
						goto nextProgressDone
					end
				end
			end

			::nextProgressDone::

			--increment attack progress counter, and check for table end reached.
			storage.attackProgress[i] = storage.attackProgress[i] + 1
			local maxCount = 0
			if (storage.nests[i]) then
				maxCount = table_size(storage.nests[i])
			end
			if storage.attackProgress[i] >= maxCount then --if we've ticked up enough nests then we are done.
				debugPrint("Biter faction " .. i .. " finished attacking with " .. storage.attackProgress[i] .. " nests!")
				debugPrint("Biter faction has " .. maxCount .. " nests")
				storage.scheduledAttack[i] = 0
				storage.attackProgress[i] = 0
			end
		end
	end -- end for each faction in faction list.
end

function bootstrapNestTables()
	game.print("Bootstrapping factions to set up nest lists - this might take a while..")
	local surf = game.get_surface(1)

	storage.chunkProgress = 1 --reset chunk progress counter for starting new processing
	storage.chunksList = {} --clear the chunk list if there was one.

	for chunk in surf.get_chunks() do
		storage.chunksList[#storage.chunksList + 1] = chunk --insert the chunks to the list to be processed each tick.
	end

	local chunkListSize = table_size(storage.chunksList)
	storage.chunkIteratorLimit = chunkListSize --set the index at which we stop processing.
	game.print("Total of " .. chunkListSize .. " chunks to process!")
end

function expansionBaseHandler(event)
	local entity = event.entity
	debugPrint("Type of newly built expansion entity: " .. entity.prototype.type)
	if entity.prototype.type == "unit-spawner" then
		debugPrint("It's a spawner type entity!")
		local force = entity.force

		if storage.factionList and storage.nests then
			for i, force in pairs(storage.factionList) do
				if storage.nests[i] then
					storage.nests[i][entity.unit_number] = entity
				end
			end
		end
	end
end


script.on_init(initHandler)
script.on_event(defines.events.on_chunk_charted, chunkGenHandler)
script.on_event(defines.events.on_chunk_generated, chunkGenHandler)
script.on_event(defines.events.on_biter_base_built, expansionBaseHandler)
script.on_event(defines.events.on_tick, runTickHandler)
