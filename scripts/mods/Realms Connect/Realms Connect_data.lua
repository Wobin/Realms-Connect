local mod = get_mod("Realms Connect")

return {
	name = "Realms Connect",
	description = mod:localize("mod_description"),
	is_togglable = true,
	options = {
		widgets = {
			{
				setting_id = "rc_open_lobby",
				type = "button",
				button_text = "rc_open_lobby_button",
				function_name = "rc_open_lobby_pressed",
				tooltip = "rc_open_lobby_tooltip",
			},
			{
				setting_id = "rc_manual_address",
				type = "text",
				default_value = "",
				max_length = 21,
				placeholder_text = "manual_address_placeholder",
				tooltip = "manual_address_tooltip",
			},
			{
				setting_id = "rc_port_mapping",
				type = "checkbox",
				default_value = true,
				tooltip = "port_mapping_tooltip",
			},
			{
				setting_id = "rc_advertise_mode",
				type = "dropdown",
				default_value = "friends",
				tooltip = "advertise_mode_tooltip",
				options = {
					{ text = "advertise_mode_off", value = "off" },
					{ text = "advertise_mode_friends", value = "friends" },
					{ text = "advertise_mode_open", value = "open" },
				},
			},
			{
				setting_id = "rc_saved_codes",
				type = "text",
				default_value = "",
				max_length = 120,
				placeholder_text = "saved_codes_placeholder",
				tooltip = "saved_codes_tooltip",
			},
			{
				setting_id = "rc_auto_accept_friends",
				type = "checkbox",
				default_value = true,
				tooltip = "auto_accept_friends_tooltip",
			},
			{
				setting_id = "rc_auto_accept_friends_in_mission",
				type = "checkbox",
				default_value = true,
				tooltip = "auto_accept_friends_in_mission_tooltip",
			},
			{
				setting_id = "rc_mask_addresses",
				type = "checkbox",
				default_value = false,
				tooltip = "mask_addresses_tooltip",
			},
			{
				setting_id = "rc_diag_redaction",
				type = "dropdown",
				default_value = "masked",
				tooltip = "diag_redaction_tooltip",
				options = {
					{ text = "diag_redaction_masked", value = "masked" },
					{ text = "diag_redaction_full", value = "full" },
				},
			},
			{
				setting_id = "rc_debug_mode",
				type = "checkbox",
				default_value = false,
				tooltip = "debug_mode_tooltip",
			},
		},
	},
}
