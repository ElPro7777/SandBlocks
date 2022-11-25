local S = minetest.get_translator(minetest.get_current_modname())

-- Fish Buckets
local fish_names = {
	["cod"] = "Cod",
	["salmon"] = "Salmon",
	["tropical_fish"] = "Tropical Fish",
	["axolotl"] = "Axolotl",
	--["pufferfish"] = "Pufferfish", --FIXME add pufferfish
}

local fishbucket_prefix = "mcl_buckets:bucket_"

local function on_place_fish(itemstack, placer, pointed_thing)
	local pos = pointed_thing.above or pointed_thing.under
	if not pos then return end
	local n = minetest.get_node_or_nil(pos)
	if n.name and minetest.registered_nodes[n.name].buildable_to or n.name == "mcl_portals:portal" then
		local fish = itemstack:get_name():gsub(fishbucket_prefix,"")
		if fish_names[fish] then
			local o = minetest.add_entity(pos, "mobs_mc:" .. fish)
			local props = itemstack:get_meta():get_string("properties")
			if props ~= "" then
				o:set_properties(minetest.deserialize(props))
			end
			minetest.set_node(pos,{name = "mcl_core:water_source"})
			if not minetest.is_creative_enabled(placer:get_player_name()) then
				itemstack:set_name("mcl_buckets:bucket_empty")
			end
		end
	end
	return itemstack
end

for techname, fishname in pairs(fish_names) do
	minetest.register_craftitem(fishbucket_prefix .. techname, {
		description = S("Bucket of @1", S(fishname)),
		_doc_items_longdesc = S("This bucket is filled with water and @1.", S(fishname)),
		_doc_items_usagehelp = S("Place it to empty the bucket and place a @1. Obtain by right clicking on a @2 with a bucket of water.", S(fishname), S(fishname)),
		_tt_help = S("Places a water source and a @1.", S(fishname)),
		inventory_image = techname .. "_bucket.png",
		stack_max = 1,
		groups = {bucket = 1, fish_bucket = 1},
		liquids_pointable = false,
		on_place = on_place_fish,
		on_secondary_use = on_place_fish,
		_on_dispense = function(stack, pos, droppos, dropnode, dropdir)
			local buildable = registered_nodes[dropnode.name].buildable_to or dropnode.name == "mcl_portals:portal"
			if not buildable then return stack end
			local result, take_bucket = get_extra_check(def.extra_check, droppos, nil)
			if result then -- Fail placement of liquid if result is false
				place_liquid(droppos, get_node_place(def.source_place, droppos))
			end
			if take_bucket then
				stack:set_name("mcl_buckets:bucket_empty")
			end
			return stack
		end,
	})

	minetest.register_alias("mcl_fishing:bucket_" .. techname, "mcl_buckets:bucket_" .. techname)
end
