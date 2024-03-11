local modname = minetest.get_current_modname()
local S = minetest.get_translator(modname)

local has_mcl_wip = minetest.get_modpath("mcl_wip")

mcl_minecarts = {}
mcl_minecarts.modpath = minetest.get_modpath(modname)
mcl_minecarts.speed_max = 10
mcl_minecarts.check_float_time = 15
local max_step_distance = 0.5
local friction = 0.1

dofile(mcl_minecarts.modpath.."/functions.lua")
dofile(mcl_minecarts.modpath.."/rails.lua")

local LOGGING_ON = minetest.settings:get_bool("mcl_logging_minecarts", false)
local DEBUG = false
local function mcl_log(message)
	if LOGGING_ON then
		mcl_util.mcl_log(message, "[Minecarts]", true)
	end
end

local function handle_cart_enter(self,pos)
	local node = minetest.get_node(pos)

	-- Handle track behaviors
	local node_def = minetest.registered_nodes[node.name]
	if node_def._mcl_minecarts_on_enter then
		node_def._mcl_minecarts_on_enter(pos, cart)
	end

	-- Handle above-track behaviors (to ensure hoppers can transfer at least one item)
	local above_pos = pos + vector.new(0,1,0)
	local node = minetest.get_node(above_pos)
	if node_def._mcl_minecarts_on_enter_below then
		node_def._mcl_minecarts_on_enter_below(above_pos, cart)
	end

	-- Handle cart-specific behaviors
	if self._mcl_minecarts_on_enter then
		self._mcl_minecarts_on_enter(self, pos)
	end
end

local function handle_cart_leave(pos)
	local node_name = minetest.get_node(pos).name
	local node_def = minetest.registered_nodes[node_name]
	if node_def._mcl_minecarts_on_leave then
		node_def._mcl_minecarts_on_leave(pos, self)
	end
end

local function update_cart_orientation(self,staticdata)
	-- constants
	local _2_pi = math.pi * 2
	local pi = math.pi
	local dir = staticdata.dir

	-- Calculate an angle from the x,z direction components
	local rot_y = math.atan2( dir.x, dir.z ) + ( staticdata.rot_adjust or 0 )
	if rot_y < 0 then
		rot_y = rot_y + _2_pi
	end

	-- Check if the rotation is a 180 flip and don't change if so
	local rot = self.object:get_rotation()
	local diff = math.abs((rot_y - ( rot.y + pi ) % _2_pi) )
	if diff < 0.001 or diff > _2_pi - 0.001 then
		-- Update rotation adjust and recalculate the rotation
		staticdata.rot_adjust = ( ( staticdata.rot_adjust or 0 ) + pi ) % _2_pi
		rot.y = math.atan2( dir.x, dir.z ) + ( staticdata.rot_adjust or 0 )
	else
		rot.y = rot_y
	end

	-- Forward/backwards tilt (pitch)
	if dir.y < 0 then
		rot.x = -0.25 * pi
	elseif dir.y > 0 then
		rot.x = 0.25 * pi
	else
		rot.x = 0
	end

	if ( staticdata.rot_adjust or 0 ) < 0.01 then
		rot.x = -rot.x
	end

	self.object:set_rotation(rot)
end

local function do_movement_step(self, remaining_distance)
	local staticdata = self._staticdata

	local pos = staticdata.connected_at

	if not pos then return remaining_distance end
	if staticdata.velocity < 0.1 then return remaining_distance end

	local remaining_in_block = 1 - ( staticdata.distance or 0 )
	local dinstance = 0
	if remaining_in_block > remaining_distance then
		distance = remaining_distance
		staticdata.distance = ( staticdata.distance or 0 ) + distance
		pos = pos + staticdata.dir * staticdata.distance
	else
		distance = remaining_in_block
		staticdata.distance = 0

		-- Leave the old node
		handle_cart_leave(pos)

		-- Anchor at the next node
		pos = pos + staticdata.dir
		staticdata.connected_at = pos

		-- Enter the new node
		handle_cart_enter(self, pos)

		-- check for hopper under the rail
		local under_pos = pos - vector.new(0,1,0)
		local under_node_name = minetest.get_node(under_pos).name
		local under_node_def = minetest.registered_nodes[under_node_name]
		if DEBUG then print( "under_node_name="..under_node_name..", hopper="..tostring(under_node_def.groups.hopper)) end
		if under_node_def and under_node_def.groups.hopper ~= 0 then
			if DEBUG then print( "Attempt pull_from_minecart" ) end
			if mcl_hoppers.pull_from_minecart( self, under_pos, self._inv_size or 0 ) then
				staticdata.delay = 1.5
			end
		end

		-- Get the next direction
		local next_dir,_ = mcl_minecarts:get_rail_direction(pos, staticdata.dir, nil, nil, staticdata.railtype)
		if DEBUG and next_dir ~= staticdata.dir then
			print( "Changing direction from "..tostring(staticdata.dir).." to "..tostring(next_dir))
		end

		-- Handle end of track
		if next_dir == staticdata.dir * -1 then
			if DEBUG then print("Stopping cart at "..tostring(pos)) end
			staticdata.velocity = 0
			distence = remaining_distance
		end

		-- Update cart direction
		staticdata.dir = next_dir
	end

	self.object:move_to(pos)

	-- Update cart orientation
	update_cart_orientation(self,staticdata)

	-- Report distance traveled
	return distance
end

local function process_acceleration(self, timestep)
	local staticdata = self._staticdata
	if not staticdata.connected_at then return end

	local acceleration = 0

	if DEBUG and staticdata.velocity > 0 then
		print( "    acceleration="..tostring(acceleration)..",velocity="..tostring(staticdata.velocity)..
		       ",timestep="..tostring(timestep)..
		       ",dir="..tostring(staticdata.dir))
	end

	local pos = staticdata.connected_at
	local node_name = minetest.get_node(pos).name
	local node_def = minetest.registered_nodes[node_name]
	local max_vel = mcl_minecarts.speed_max

	if self._go_forward then
		acceleration = 2
	elseif self._brake then
		acceleration = -1.5
	elseif self._punched then
		acceleration = 2
	elseif self._fueltime and self._fueltime > 0 then
		acceleration = 0.6
	elseif staticdata.velocity >= ( node_def._max_acceleration_velocity or max_vel ) then
		acceleration = 0
	else
		acceleration = node_def._rail_acceleration or -friction
	end

	if math.abs(acceleration) > (friction / 5) then
		staticdata.velocity = ( staticdata.velocity or 0 ) + acceleration * timestep
		if staticdata.velocity > max_vel then
			staticdata.velocity = max_vel
		elseif staticdata.velocity < 0.1 then
			staticdata.velocity = 0
		end
	end

	-- Factor in gravity after everything else
	local gravity_accel = 0
	local gravity_strength = friction + 0.2
	if staticdata.dir.y < 0 then
		gravity_accel = gravity_strength
	elseif staticdata.dir.y > 0 then
		gravity_accel = -gravity_strength
	end
	if DEBUG and gravity_accel ~= 0 then
		print("gravity_accel="..tostring(gravity_accel))
	end
	if gravity_accel ~= 0 then
		staticdata.velocity = (staticdata.velocity or 0) + gravity_accel
		if staticdata.velocity < 0 then
			if DEBUG then
				print("Gravity flipped direction")
			end

			-- Complete moving thru this block into the next, reverse direction, and put us back at the same position we were at
			staticdata.velocity = staticdata.velocity * -1
			next_dir = -staticdata.dir
			pos = pos + staticdata.dir
			staticdata.distance = 1 - staticdata.distance
			staticdata.connected_at = pos

			local next_dir,_ = mcl_minecarts:get_rail_direction(pos + staticdata.dir, next_dir, nil, nil, staticdata.railtype)
			staticdata.dir = next_dir

			update_cart_orientation(self,staticdata)
		end
	end

	-- Force the cart to stop if moving slowly enough
	if (staticdata.velocity or 0) < 0.1 then
		staticdata.velocity = 0
	end

	if DEBUG and staticdata.velocity > 0 then
		print( "    acceleration="..tostring(acceleration)..",velocity="..tostring(staticdata.velocity)..
		       ",timestep="..tostring(timestep)..
		       ",dir="..tostring(staticdata.dir))
	end
end

local function do_movement( self, dtime )
	local staticdata = self._staticdata

	-- Allow the carts to be delay for the rest of the world to react before moving again
	if ( staticdata.delay or 0 ) > dtime then
		staticdata.delay = staticdata.delay - dtime
		return
	else
		staticdata.delay = 0
	end

	local initial_velocity = 1
	if self._punched and statcdata.velocity < initial_velocity then
		staticdata.velocity = initial_velocity
	end

	-- Break long movements into fixed-size steps so that
	-- it is impossible to jump across gaps due to server lag
	-- causing large timesteps
	local total_distance = dtime * ( staticdata.velocity or 0 )
	local remaining_distance = total_distance

	process_acceleration(self,dtime * max_step_distance / total_distance)

	-- Skip processing stopped railcarts
	if not staticdata.velocity or math.abs(staticdata.velocity) < 0.05 then
		return
	end

	while remaining_distance > 0.1 do
		local step_distance = do_movement_step(self, remaining_distance)
		if step_distance > 0.1 then
			process_acceleration(self, dtime * step_distance / total_distance)
		end
		remaining_distance = remaining_distance - step_distance
	end

	-- Clear punched flag now that movement for this step has been completed
	self._punched = false
end

local function detach_driver(self)
	if not self._driver then
		return
	end
	mcl_player.player_attached[self._driver] = nil
	local player = minetest.get_player_by_name(self._driver)
	self._driver = nil
	self._start_pos = nil
	if player then
		player:set_detach()
		player:set_eye_offset(vector.new(0,0,0),vector.new(0,0,0))
		mcl_player.player_set_animation(player, "stand" , 30)
	end
end

local function activate_tnt_minecart(self, timer)
	if self._boomtimer then
		return
	end
	self.object:set_armor_groups({immortal=1})
	if timer then
		self._boomtimer = timer
	else
		self._boomtimer = tnt.BOOMTIMER
	end
	self.object:set_properties({textures = {
		"mcl_tnt_blink.png",
		"mcl_tnt_blink.png",
		"mcl_tnt_blink.png",
		"mcl_tnt_blink.png",
		"mcl_tnt_blink.png",
		"mcl_tnt_blink.png",
		"mcl_minecarts_minecart.png",
	}})
	self._blinktimer = tnt.BLINKTIMER
	minetest.sound_play("tnt_ignite", {pos = self.object:get_pos(), gain = 1.0, max_hear_distance = 15}, true)
end

local activate_normal_minecart = detach_driver

local function hopper_take_item(self, dtime)
	local pos = self.object:get_pos()
	if not pos then return end

	if not self or self.name ~= "mcl_minecarts:hopper_minecart" then return end

	if mcl_util.check_dtime_timer(self, dtime, "hoppermc_take", 0.15) then
		--minetest.log("The check timer was triggered: " .. dump(pos) .. ", name:" .. self.name)
	else
		--minetest.log("The check timer was not triggered")
		return
	end

	--mcl_log("self.itemstring: ".. self.itemstring)

	local above_pos = vector.offset(pos, 0, 0.9, 0)
	--mcl_log("self.itemstring: ".. minetest.pos_to_string(above_pos))
	local objs = minetest.get_objects_inside_radius(above_pos, 1.25)

	if objs then

		mcl_log("there is an itemstring. Number of objs: ".. #objs)

		for k, v in pairs(objs) do
			local ent = v:get_luaentity()

			if ent and not ent._removed and ent.itemstring and ent.itemstring ~= "" then
				local taken_items = false

				mcl_log("ent.name: " .. tostring(ent.name))
				mcl_log("ent pos: " .. tostring(ent.object:get_pos()))

				local inv = mcl_entity_invs.load_inv(self, 5)
				if not inv then return false end

				local current_itemstack = ItemStack(ent.itemstring)

				mcl_log("inv. size: " .. self._inv_size)
				if inv:room_for_item("main", current_itemstack) then
					mcl_log("Room")
					inv:add_item("main", current_itemstack)
					ent.object:get_luaentity().itemstring = ""
					ent.object:remove()
					taken_items = true
				else
					mcl_log("no Room")
				end

				if not taken_items then
					local items_remaining = current_itemstack:get_count()

					-- This will take part of a floating item stack if no slot can hold the full amount
					for i = 1, self._inv_size, 1 do
						local stack = inv:get_stack("main", i)

						mcl_log("i: " .. tostring(i))
						mcl_log("Items remaining: " .. items_remaining)
						mcl_log("Name: " .. tostring(stack:get_name()))

						if current_itemstack:get_name() == stack:get_name() then
							mcl_log("We have a match. Name: " .. tostring(stack:get_name()))

							local room_for = stack:get_stack_max() - stack:get_count()
							mcl_log("Room for: " .. tostring(room_for))

							if room_for == 0 then
								-- Do nothing
								mcl_log("No room")
							elseif room_for < items_remaining then
								mcl_log("We have more items remaining than space")

								items_remaining = items_remaining - room_for
								stack:set_count(stack:get_stack_max())
								inv:set_stack("main", i, stack)
								taken_items = true
							else
								local new_stack_size = stack:get_count() + items_remaining
								stack:set_count(new_stack_size)
								mcl_log("We have more than enough space. Now holds: " .. new_stack_size)

								inv:set_stack("main", i, stack)
								items_remaining = 0

								ent.object:get_luaentity().itemstring = ""
								ent.object:remove()

								taken_items = true
								break
							end

							mcl_log("Count: " .. tostring(stack:get_count()))
							mcl_log("stack max: " .. tostring(stack:get_stack_max()))
							--mcl_log("Is it empty: " .. stack:to_string())
						end

						if i == self._inv_size and taken_items then
							mcl_log("We are on last item and still have items left. Set final stack size: " .. items_remaining)
							current_itemstack:set_count(items_remaining)
							--mcl_log("Itemstack2: " .. current_itemstack:to_string())
							ent.itemstring = current_itemstack:to_string()
						end
					end
				end

				--Add in, and delete
				if taken_items then
					mcl_log("Saving")
					mcl_entity_invs.save_inv(ent)
					return taken_items
				else
					mcl_log("No need to save")
				end

			end
		end
	end

	return false
end

-- Table for item-to-entity mapping. Keys: itemstring, Values: Corresponding entity ID
local entity_mapping = {}

local function make_staticdata( railtype, connected_at, dir )
	return {
		railtype = railtype,
		connected_at = connected_at,
		distance = 0,
		velocity = 0,
		dir = vector.new(dir),
	}
end

local function to_dirstring(dir)
	if dir.x == 0 then
		if dir.z == 1 then
			return "north"
		else
			return "south"
		end
	elseif dir.z == 0 then
		if dir.x == 1 then
			return " east"
		else
			return " west"
		end
	end
end

local function register_entity(entity_id, def)
	assert( def.drop, "drop is required parameter" )
	local cart = {
		initial_properties = {
			physical = false,
			collisionbox = {-10/16., -0.5, -10/16, 10/16, 0.25, 10/16},
			visual = "mesh",
			mesh = def.mesh,
			visual_size = {x=1, y=1},
			textures = def.textures,
		},

		on_rightclick = def.on_rightclick,
		on_activate_by_rail = def.on_activate_by_rail,
		_mcl_minecarts_on_enter = def._mcl_minecarts_on_enter,

		_driver = nil, -- player who sits in and controls the minecart (only for minecart!)
		_passenger = nil, -- for mobs
		_punched = false, -- used to re-send _velocity and position
		_start_pos = nil, -- Used to calculate distance for “On A Rail” achievement
		_last_float_check = nil, -- timestamp of last time the cart was checked to be still on a rail
		_fueltime = nil, -- how many seconds worth of fuel is left. Only used by minecart with furnace
		_boomtimer = nil, -- how many seconds are left before exploding
		_blinktimer = nil, -- how many seconds are left before TNT blinking
		_blink = false, -- is TNT blink texture active?
		_old_pos = nil,
		_staticdata = nil,
	}

	function cart:on_activate(staticdata, dtime_s)
		-- Initialize
		local data = minetest.deserialize(staticdata)
		if type(data) == "table" then
			-- Migrate old data
			if data._railtype then
				data.railtype = data._railtype
				data._railtype = nil
			end
			-- Fix up types
			data.dir = vector.new(data.dir)

			self._staticdata = data
		end
		self.object:set_armor_groups({immortal=1})

		-- Activate cart if on activator rail
		if self.on_activate_by_rail then
			local pos = self.object:get_pos()
			local node = minetest.get_node(vector.floor(pos))
			if node.name == "mcl_minecarts:activator_rail_on" then
				self:on_activate_by_rail()
			end
		end
	end

	function cart:on_punch(puncher, time_from_last_punch, tool_capabilities, direction)
		local staticdata = self._staticdata
		if not staticdata then
			staticdata = make_staticdata()
			self._staticdata = staticdata
		end

		local pos = staticdata.connected_at
		if not pos then
			pos = self.object:get_pos()
			-- Try to reattach
			local rounded_pos = vector.round(pos)
			if mcl_minecarts:is_rail(rounded_pos) and vector.distance(pos, rounded_pos) < 0.25 then
				-- Reattach
				staticdata.connected_at = rounded_pos
				pos = rounded_pos
			else
				print("TODO: handle detached cart behavior")
			end
		end

		-- Fix railtype field
		if not staticdata.railtype then
			local node = minetest.get_node(vector.floor(pos)).name
			staticdata.railtype = minetest.get_item_group(node, "connect_to_raillike")
		end

		-- Handle punches by something other than the player
		if not puncher or not puncher:is_player() then
			local cart_dir = mcl_minecarts:get_rail_direction(pos, vector.new(1,0,0), nil, nil, staticdata.railtype)
			if vector.equals(cart_dir, vector.new(0,0,0)) then
				return
			end

			staticdata.dir = cart_dir
			self._punched = true
			return
		end

		-- Punch+sneak: Pick up minecart (unless TNT was ignited)
		if puncher:get_player_control().sneak and not self._boomtimer then
			if self._driver then
				if self._old_pos then
					self.object:set_pos(self._old_pos)
				end
				detach_driver(self)
			end

			-- Disable detector rail
			local rou_pos = vector.round(pos)
			local node = minetest.get_node(rou_pos)
			if node.name == "mcl_minecarts:detector_rail_on" then
				local newnode = {name="mcl_minecarts:detector_rail", param2 = node.param2}
				minetest.swap_node(rou_pos, newnode)
				mesecon.receptor_off(rou_pos)
			end

			-- Drop items and remove cart entity
			local drop = def.drop
			if not minetest.is_creative_enabled(puncher:get_player_name()) then
				for d=1, #drop do
					minetest.add_item(self.object:get_pos(), drop[d])
				end
			elseif puncher and puncher:is_player() then
				local inv = puncher:get_inventory()
				for d=1, #drop do
					if not inv:contains_item("main", drop[d]) then
						inv:add_item("main", drop[d])
					end
				end
			end

			self.object:remove()
			return
		end

		-- Handle player punches
		local vel = self.object:get_velocity()
		if puncher:get_player_name() == self._driver then
			if math.abs(vel.x + vel.z) > 7 then
				return
			end
		end

		local punch_dir = mcl_minecarts:velocity_to_dir(puncher:get_look_dir())
		punch_dir.y = 0

		local cart_dir = mcl_minecarts:get_rail_direction(pos, punch_dir, nil, nil, self._staticdata.railtype)
		if vector.equals(cart_dir, vector.new(0,0,0)) then
			return
		end

		staticdata.dir = cart_dir

		time_from_last_punch = math.min(time_from_last_punch, tool_capabilities.full_punch_interval)
		local f = 3 * (time_from_last_punch / tool_capabilities.full_punch_interval)

		-- Perform acceleration here
		staticdata.velocity = (staticdata.velocity or 0 ) + f
		local max_vel = mcl_minecarts.speed_max
		if staticdata.velocity > max_vel then
			staticdata.velocity = max_vel
		end
	end

	local passenger_attach_position = vector.new(0, -1.75, 0)

	function cart:on_step(dtime)
		hopper_take_item(self, dtime)
		local staticdata = self._staticdata
		if not staticdata then
			staticdata = make_staticdata()
			self._staticdata = staticdata
		end
		if (staticdata.hopper_delay or 0) > 0 then
			staticdata.hopper_delay = staticdata.hopper_delay - dtime
		end

		local pos, rou_pos, node = self.object:get_pos()
		--local update = {}
		--local acceleration = 0

		-- Controls
		local ctrl, player = nil, nil
		if self._driver then
			player = minetest.get_player_by_name(self._driver)
			if player then
				ctrl = player:get_player_control()
				-- player detach
				if ctrl.sneak then
					detach_driver(self)
					return
				end

				-- Experimental controls
				--self._go_forward = ctrl.up
				--self._brake = ctrl.down
			end

			-- Give achievement when player reached a distance of 1000 nodes from the start position
			if vector.distance(self._start_pos, pos) >= 1000 then
				awards.unlock(self._driver, "mcl:onARail")
			end
		end

		do_movement(self, dtime)

		-- TODO: move this into do_movement_step
		-- Drop minecart if it collides with a cactus node
		local r = 0.6
		for _, node_pos in pairs({{r, 0}, {0, r}, {-r, 0}, {0, -r}}) do
			if minetest.get_node(vector.offset(pos, node_pos[1], 0, node_pos[2])).name == "mcl_core:cactus" then
				detach_driver(self)
				local drop = def.drop
				for d = 1, #drop do
					minetest.add_item(pos, drop[d])
				end
				self.object:remove()
				return
			end
		end

		-- Grab mob
		if math.random(1,20) > 15 and not self._passenger then
			if self.name == "mcl_minecarts:minecart" then
				local mobsnear = minetest.get_objects_inside_radius(self.object:get_pos(), 1.3)
				for n=1, #mobsnear do
					local mob = mobsnear[n]
					if mob then
						local entity = mob:get_luaentity()
						if entity and entity.is_mob then
							self._passenger = entity
							mob:set_attach(self.object, "", passenger_attach_position, vector.zero())
							break
						end
					end
				end
			end
		elseif self._passenger then
			local passenger_pos = self._passenger.object:get_pos()
			if not passenger_pos then
				self._passenger = nil
			end
		end

		-- Drop minecart if it isn't on a rail anymore
		if self._last_float_check == nil then
			self._last_float_check = 0
		else
			self._last_float_check = self._last_float_check + dtime
		end
		if self._last_float_check >= mcl_minecarts.check_float_time then
			pos = self.object:get_pos()
			rou_pos = vector.round(pos)
			node = minetest.get_node(rou_pos)
			local g = minetest.get_item_group(node.name, "connect_to_raillike")
			if g ~= self._staticdata.railtype and self._staticdata.railtype then
				-- Detach driver
				detach_driver(self)

				-- Explode if already ignited
				if self._boomtimer then
					self.object:remove()
					mcl_explosions.explode(pos, 4, { drop_chance = 1.0 })
					return
				end

				-- Do not drop minecart. It goes off the rails too frequently, and anyone using them for farms won't
				-- notice and lose their iron and not bother. Not cool until fixed.
			end
			self._last_float_check = 0
		end

		-- Update furnace stuff
		if self._fueltime and self._fueltime > 0 then
			self._fueltime = self._fueltime - dtime
			if self._fueltime <= 0 then
				self.object:set_properties({textures =
					{
					"default_furnace_top.png",
					"default_furnace_top.png",
					"default_furnace_front.png",
					"default_furnace_side.png",
					"default_furnace_side.png",
					"default_furnace_side.png",
					"mcl_minecarts_minecart.png",
				}})
				self._fueltime = 0
			end
		end
		local has_fuel = self._fueltime and self._fueltime > 0

		-- Update TNT stuff
		if self._boomtimer then
			-- Explode
			self._boomtimer = self._boomtimer - dtime
			local pos = self.object:get_pos()
			if self._boomtimer <= 0 then
				self.object:remove()
				mcl_explosions.explode(pos, 4, { drop_chance = 1.0 })
				return
			else
				tnt.smoke_step(pos)
			end
		end
		if self._blinktimer then
			self._blinktimer = self._blinktimer - dtime
			if self._blinktimer <= 0 then
				self._blink = not self._blink
				if self._blink then
					self.object:set_properties({textures =
					{
					"default_tnt_top.png",
					"default_tnt_bottom.png",
					"default_tnt_side.png",
					"default_tnt_side.png",
					"default_tnt_side.png",
					"default_tnt_side.png",
					"mcl_minecarts_minecart.png",
					}})
				else
					self.object:set_properties({textures =
					{
					"mcl_tnt_blink.png",
					"mcl_tnt_blink.png",
					"mcl_tnt_blink.png",
					"mcl_tnt_blink.png",
					"mcl_tnt_blink.png",
					"mcl_tnt_blink.png",
					"mcl_minecarts_minecart.png",
					}})
				end
				self._blinktimer = tnt.BLINKTIMER
			end
		end
	end

	function cart:get_staticdata()
		return minetest.serialize(self._staticdata or {})
	end

	minetest.register_entity(entity_id, cart)
end

-- Place a minecart at pointed_thing
function mcl_minecarts.place_minecart(itemstack, pointed_thing, placer)
	if not pointed_thing.type == "node" then
		return
	end

	local railpos, node
	if mcl_minecarts:is_rail(pointed_thing.under) then
		railpos = pointed_thing.under
		node = minetest.get_node(pointed_thing.under)
	elseif mcl_minecarts:is_rail(pointed_thing.above) then
		railpos = pointed_thing.above
		node = minetest.get_node(pointed_thing.above)
	else
		return
	end

	local entity_id = entity_mapping[itemstack:get_name()]
	local cart = minetest.add_entity(railpos, entity_id)
	local railtype = minetest.get_item_group(node.name, "connect_to_raillike")
	local cart_dir = mcl_minecarts:get_rail_direction(railpos, vector.new(1,0,0), nil, nil, railtype)
	cart:set_yaw(minetest.dir_to_yaw(cart_dir))

	-- Update static data
	local le = cart:get_luaentity()
	if le then
		le._staticdata = make_staticdata( railtype, railpos, cart_dir )
	end

	handle_cart_enter(le, railpos)

	local pname = ""
	if placer then
		pname = placer:get_player_name()
	end
	if not minetest.is_creative_enabled(pname) then
		itemstack:take_item()
	end
	return itemstack
end

local function dropper_place_minecart(dropitem, pos)
	local node = minetest.get_node(pos)
	local nodedef = minetest.registered_nodes[node.name]

	-- Don't try to place the minecart if pos isn't a rail
	if (nodedef.groups.rail or 0) == 0 then return false end

	mcl_minecarts.place_minecart(dropitem, {
		above = pos,
		under = vector.offset(pos,0,-1,0)
	})
	return true
end

local function register_craftitem(itemstring, entity_id, description, tt_help, longdesc, usagehelp, icon, creative)
	entity_mapping[itemstring] = entity_id

	local groups = { minecart = 1, transport = 1 }
	if creative == false then
		groups.not_in_creative_inventory = 1
	end
	local def = {
		stack_max = 1,
		_mcl_dropper_on_drop = dropper_place_minecart,
		on_place = function(itemstack, placer, pointed_thing)
			if not pointed_thing.type == "node" then
				return
			end

			-- Call on_rightclick if the pointed node defines it
			local node = minetest.get_node(pointed_thing.under)
			if placer and not placer:get_player_control().sneak then
				if minetest.registered_nodes[node.name] and minetest.registered_nodes[node.name].on_rightclick then
					return minetest.registered_nodes[node.name].on_rightclick(pointed_thing.under, node, placer, itemstack) or itemstack
				end
			end

			return mcl_minecarts.place_minecart(itemstack, pointed_thing, placer)
		end,
		_on_dispense = function(stack, pos, droppos, dropnode, dropdir)
			-- Place minecart as entity on rail. If there's no rail, just drop it.
			local placed
			if minetest.get_item_group(dropnode.name, "rail") ~= 0 then
				-- FIXME: This places minecarts even if the spot is already occupied
				local pointed_thing = { under = droppos, above = vector.new( droppos.x, droppos.y+1, droppos.z ) }
				placed = mcl_minecarts.place_minecart(stack, pointed_thing)
			end
			if placed == nil then
				-- Drop item
				minetest.add_item(droppos, stack)
			end
		end,
		groups = groups,
	}
	def.description = description
	def._tt_help = tt_help
	def._doc_items_longdesc = longdesc
	def._doc_items_usagehelp = usagehelp
	def.inventory_image = icon
	def.wield_image = icon
	minetest.register_craftitem(itemstring, def)
end

--[[
Register a minecart
* itemstring: Itemstring of minecart item
* entity_id: ID of minecart entity
* description: Item name / description
* longdesc: Long help text
* usagehelp: Usage help text
* mesh: Minecart mesh
* textures: Minecart textures table
* icon: Item icon
* drop: Dropped items after destroying minecart
* on_rightclick: Called after rightclick
* on_activate_by_rail: Called when above activator rail
* creative: If false, don't show in Creative Inventory
]]
local function register_minecart(def)
	register_entity(def.entity_id, def)
	register_craftitem(def.itemstring, def.entity_id, def.description, def.tt_help, def.longdesc, def.usagehelp, def.icon, def.creative)
	if minetest.get_modpath("doc_identifier") then
		doc.sub.identifier.register_object(def.entity_id, "craftitems", itemstring)
	end
end

-- Minecart
register_minecart({
	itemstring = "mcl_minecarts:minecart",
	entity_id = "mcl_minecarts:minecart",
	description = S("Minecart"),
	tt_helop = S("Vehicle for fast travel on rails"),
	long_descp = S("Minecarts can be used for a quick transportion on rails.") .. "\n" ..
		S("Minecarts only ride on rails and always follow the tracks. At a T-junction with no straight way ahead, they turn left. The speed is affected by the rail type."),
		S("You can place the minecart on rails. Right-click it to enter it. Punch it to get it moving.") .. "\n" ..
		S("To obtain the minecart, punch it while holding down the sneak key.") .. "\n" ..
		S("If it moves over a powered activator rail, you'll get ejected."),
	mesh = "mcl_minecarts_minecart.b3d",
	textures = {"mcl_minecarts_minecart.png"},
	icon = "mcl_minecarts_minecart_normal.png",
	drop = {"mcl_minecarts:minecart"},
	on_rightclick = function(self, clicker)
		local name = clicker:get_player_name()
		if not clicker or not clicker:is_player() then
			return
		end
		local player_name = clicker:get_player_name()
		if self._driver and player_name == self._driver then
			detach_driver(self)
		elseif not self._driver then
			self._driver = player_name
			self._start_pos = self.object:get_pos()
			mcl_player.player_attached[player_name] = true
			clicker:set_attach(self.object, "", vector.new(1,-1.75,-2), vector.new(0,0,0))
			mcl_player.player_attached[name] = true
			minetest.after(0.2, function(name)
				local player = minetest.get_player_by_name(name)
				if player then
					mcl_player.player_set_animation(player, "sit" , 30)
					player:set_eye_offset(vector.new(0,-5.5,0), vector.new(0,-4,0))
					mcl_title.set(clicker, "actionbar", {text=S("Sneak to dismount"), color="white", stay=60})
				end
			end, name)
		end
	end,
	on_activate_by_rail = activate_normal_minecart
})

-- Minecart with Chest
register_minecart({
	itemstring = "mcl_minecarts:chest_minecart",
	entity_id = "mcl_minecarts:chest_minecart",
	description = S("Minecart with Chest"),
	tt_help = nil,
	longdesc = nil,
	usagehelp = nil,
	mesh = "mcl_minecarts_minecart_chest.b3d",
	textures = {
		"mcl_chests_normal.png",
		"mcl_minecarts_minecart.png"
	},
	icon = "mcl_minecarts_minecart_chest.png",
	drop = {"mcl_minecarts:minecart", "mcl_chests:chest"},
	on_rightclick = nil,
	on_activate_by_rail = nil,
	creative = true
})
mcl_entity_invs.register_inv("mcl_minecarts:chest_minecart","Minecart",27,false,true)

-- Minecart with Furnace
register_minecart({
	itemstring = "mcl_minecarts:furnace_minecart",
	entity_id = "mcl_minecarts:furnace_minecart",
	description = S("Minecart with Furnace"),
	tt_help = nil,
	longdesc = S("A minecart with furnace is a vehicle that travels on rails. It can propel itself with fuel."),
	usagehelp = S("Place it on rails. If you give it some coal, the furnace will start burning for a long time and the minecart will be able to move itself. Punch it to get it moving.") .. "\n" ..
		S("To obtain the minecart and furnace, punch them while holding down the sneak key."),

	mesh = "mcl_minecarts_minecart_block.b3d",
	textures = {
		"default_furnace_top.png",
		"default_furnace_top.png",
		"default_furnace_front.png",
		"default_furnace_side.png",
		"default_furnace_side.png",
		"default_furnace_side.png",
		"mcl_minecarts_minecart.png",
	},
	icon = "mcl_minecarts_minecart_furnace.png",
	drop = {"mcl_minecarts:minecart", "mcl_furnaces:furnace"},
	on_rightclick = function(self, clicker)
		-- Feed furnace with coal
		if not clicker or not clicker:is_player() then
			return
		end
		if not self._fueltime then
			self._fueltime = 0
		end
		local held = clicker:get_wielded_item()
		if minetest.get_item_group(held:get_name(), "coal") == 1 then
			self._fueltime = self._fueltime + 180

			if not minetest.is_creative_enabled(clicker:get_player_name()) then
				held:take_item()
				local index = clicker:get_wield_index()
				local inv = clicker:get_inventory()
				inv:set_stack("main", index, held)
			end
			self.object:set_properties({textures =
			{
				"default_furnace_top.png",
				"default_furnace_top.png",
				"default_furnace_front_active.png",
				"default_furnace_side.png",
				"default_furnace_side.png",
				"default_furnace_side.png",
				"mcl_minecarts_minecart.png",
			}})
		end
	end,
	on_activate_by_rail = nil,
	creative = true
})

-- Minecart with Command Block
register_minecart({
	itemstring = "mcl_minecarts:command_block_minecart",
	entity_id = "mcl_minecarts:command_block_minecart",
	description = S("Minecart with Command Block"),
	tt_help = nil,
	loncdesc = nil,
	usagehelp = nil,
	mesh = "mcl_minecarts_minecart_block.b3d",
	textures = {
		"jeija_commandblock_off.png^[verticalframe:2:0",
		"jeija_commandblock_off.png^[verticalframe:2:0",
		"jeija_commandblock_off.png^[verticalframe:2:0",
		"jeija_commandblock_off.png^[verticalframe:2:0",
		"jeija_commandblock_off.png^[verticalframe:2:0",
		"jeija_commandblock_off.png^[verticalframe:2:0",
		"mcl_minecarts_minecart.png",
	},
	icon = "mcl_minecarts_minecart_command_block.png",
	drop = {"mcl_minecarts:minecart"},
	on_rightclick = nil,
	on_activate_by_rail = nil,
	creative = false
})

-- Minecart with Hopper
register_minecart({
	itemstring = "mcl_minecarts:hopper_minecart",
	entity_id = "mcl_minecarts:hopper_minecart",
	description = S("Minecart with Hopper"),
	tt_help = nil,
	longdesc = nil,
	usagehelp = nil,
	mesh = "mcl_minecarts_minecart_hopper.b3d",
	textures = {
		"mcl_hoppers_hopper_inside.png",
		"mcl_minecarts_minecart.png",
		"mcl_hoppers_hopper_outside.png",
		"mcl_hoppers_hopper_top.png",
	},
	icon = "mcl_minecarts_minecart_hopper.png",
	drop = {"mcl_minecarts:minecart", "mcl_hoppers:hopper"},
	on_rightclick = nil,
	on_activate_by_rail = nil,
	_mcl_minecarts_on_enter = function(self,pos)
		local staticdata = self._staticdata
		if (staticdata.hopper_delay or 0) > 0 then
			return
		end

		-- try to pull from containers into our inventory
		local inv = mcl_entity_invs.load_inv(self,5)
		local above_pos = pos + vector.new(0,1,0)
		mcl_util.hopper_pull_to_inventory(inv, 'main', above_pos)

		staticdata.hopper_delay =  (staticdata.hopper_delay or 0) + (1/20)
	end,
	creative = true
})
mcl_entity_invs.register_inv("mcl_minecarts:hopper_minecart", "Hopper Minecart", 5, false, true)

-- Minecart with TNT
register_minecart({
	itemstring = "mcl_minecarts:tnt_minecart",
	entity_id = "mcl_minecarts:tnt_minecart",
	description = S("Minecart with TNT"),
	tt_help = S("Vehicle for fast travel on rails").."\n"..S("Can be ignited by tools or powered activator rail"),
	longdesc = S("A minecart with TNT is an explosive vehicle that travels on rail."),
	usagehelp = S("Place it on rails. Punch it to move it. The TNT is ignited with a flint and steel or when the minecart is on an powered activator rail.") .. "\n" ..
		S("To obtain the minecart and TNT, punch them while holding down the sneak key. You can't do this if the TNT was ignited."),
	mesh = "mcl_minecarts_minecart_block.b3d",
	textures = {
		"default_tnt_top.png",
		"default_tnt_bottom.png",
		"default_tnt_side.png",
		"default_tnt_side.png",
		"default_tnt_side.png",
		"default_tnt_side.png",
		"mcl_minecarts_minecart.png",
	},
	icon = "mcl_minecarts_minecart_tnt.png",
	drop = {"mcl_minecarts:minecart", "mcl_tnt:tnt"},
	on_rightclick = function(self, clicker)
		-- Ingite
		if not clicker or not clicker:is_player() then
			return
		end
		if self._boomtimer then
			return
		end
		local held = clicker:get_wielded_item()
		if held:get_name() == "mcl_fire:flint_and_steel" then
			if not minetest.is_creative_enabled(clicker:get_player_name()) then
				held:add_wear(65535/65) -- 65 uses
				local index = clicker:get_wield_index()
				local inv = clicker:get_inventory()
				inv:set_stack("main", index, held)
			end
			activate_tnt_minecart(self)
		end
	end,
	on_activate_by_rail = activate_tnt_minecart,
	creative = true
})


minetest.register_craft({
	output = "mcl_minecarts:minecart",
	recipe = {
		{"mcl_core:iron_ingot", "", "mcl_core:iron_ingot"},
		{"mcl_core:iron_ingot", "mcl_core:iron_ingot", "mcl_core:iron_ingot"},
	},
})

minetest.register_craft({
	output = "mcl_minecarts:tnt_minecart",
	recipe = {
		{"mcl_tnt:tnt"},
		{"mcl_minecarts:minecart"},
	},
})

minetest.register_craft({
	output = "mcl_minecarts:furnace_minecart",
	recipe = {
		{"mcl_furnaces:furnace"},
		{"mcl_minecarts:minecart"},
	},
})

minetest.register_craft({
	output = "mcl_minecarts:hopper_minecart",
	recipe = {
		{"mcl_hoppers:hopper"},
		{"mcl_minecarts:minecart"},
	},
})


minetest.register_craft({
	output = "mcl_minecarts:chest_minecart",
	recipe = {
		{"mcl_chests:chest"},
		{"mcl_minecarts:minecart"},
	},
})


if has_mcl_wip then
	mcl_wip.register_wip_item("mcl_minecarts:chest_minecart")
	mcl_wip.register_wip_item("mcl_minecarts:furnace_minecart")
	mcl_wip.register_wip_item("mcl_minecarts:command_block_minecart")
end
