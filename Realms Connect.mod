return {
	run = function()
		fassert(rawget(_G, "new_mod"), "`Realms Connect` encountered an error loading the Darktide Mod Framework.")

		new_mod("Realms Connect", {
			mod_script       = "Realms Connect/scripts/mods/Realms Connect/Realms Connect",
			mod_data         = "Realms Connect/scripts/mods/Realms Connect/Realms Connect_data",
			mod_localization = "Realms Connect/scripts/mods/Realms Connect/Realms Connect_localization",
		})
	end,
	load_after = { "Vox Manifold", "Realms" },
	require = { "Vox Manifold", "Realms" },
	packages = {},
}
