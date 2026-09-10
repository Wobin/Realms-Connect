return {
	mod_description = {
		en = "Friend-code matchmaking and NAT traversal for Realms servers.",
	},
	command_diag_description = {
		en = "Run a Realms Connect network diagnostic sweep and report the result.",
	},
	command_report_description = {
		en = "Write a full Realms Connect diagnostic snapshot to the console log.",
	},
	rc_report_written = {
		en = "Realms Connect: snapshot written to the console log. Send the log file to whoever is helping you.",
	},
	rc_diag_started = {
		en = "Realms Connect: running the diagnostic sweep, this can take a few seconds...",
	},
	rc_diag_already_running = {
		en = "Realms Connect: a diagnostic sweep is already running.",
	},
	rc_diag_failed = {
		en = "Realms Connect: the diagnostic sweep failed. See the log for details.",
	},
	join_manual_succeeded = {
		en = "Realms Connect: connected to the manually entered address.",
	},
	join_manual_failed = {
		en = "Realms Connect: could not connect to the manually entered address",
	},
	rc_open_lobby = {
		en = "Open this lobby",
	},
	rc_open_lobby_button = {
		en = "Open",
	},
	rc_open_lobby_tooltip = {
		en = "Broadcast this Realm for two minutes so friends can find it with \"Check friends for open lobbies\". It closes itself again afterwards. You do not need this for someone joining with your friend code, and it works anywhere, including the Mourningstar and the Psykhanium.",
	},
	rc_open_lobby_echo = {
		en = "Realms Connect: lobby open {seconds}s.",
	},
	rc_manual_address = {
		en = "Manual address",
	},
	join_needs_vox_manifold = {
		en = "Realms Connect: Vox Manifold 2.2 or newer is required and was not found. Install the Vox Manifold folder from the same zip and add it to mod_load_order.txt above Realms Connect. A direct ip:port still works without it.",
	},
	join_needs_a_session = {
		en = "Realms Connect: wait until you are in the Mourningstar. Joining from the title screen is not possible.",
	},
	manual_address_placeholder = {
		en = "203.0.113.9:27015",
	},
	saved_codes_placeholder = {
		en = "Friend code, friend code",
	},
	manual_address_tooltip = {
		en = "An ip:port of your OWN that you have already forwarded on your router. It is advertised ahead of everything the mod works out for itself, so people joining you try it first. This is not a dial-out box: to connect straight to somebody, type their ip:port into the friend code field on the join screen.",
	},
	rc_port_mapping = {
		en = "Router port mapping",
	},
	port_mapping_tooltip = {
		en = "While you are hosting, ask your router over UPnP IGD to forward the port Realms is listening on. This is the most reliable way to be reachable and is the only one that helps a symmetric NAT. If the router refuses, the mod falls back to a mutual NAT punch on its own.",
	},
	lobby_reach_mapped = {
		en = "Reachable: your router is forwarding {address}",
	},
	lobby_reach_punch = {
		en = "Reachable by NAT punch. Your router would not forward a port, so joiners are let in one at a time.",
	},
	lobby_reach_cgnat = {
		en = "Carrier-grade NAT: only a NAT punch can let people in, and it often fails. Joining others still works.",
	},
	lobby_reach_working = {
		en = "Working out how reachable you are...",
	},
	chat_reach_no_upnp = {
		en = "Realms Connect: no port mapped, UPnP and NAT-PMP both refused. Public {public}. {detail}",
	},
	chat_reach_cgnat = {
		en = "Realms Connect: carrier-grade NAT. Your provider shares one address between many homes, so no port can be forwarded to you and hosting will usually fail. Ask the other person to host instead. Public {public}. {detail}",
	},
	chat_join_no_answer = {
		en = "Realms Connect: {host} did not answer in 30s.",
	},
	chat_join_unreachable = {
		en = "Realms Connect: {host} answered, no address reachable: {reason}",
	},
	chat_listen_over_capacity = {
		en = "Realms Connect: {count} friends online, too many to watch at once. Some may not reach you.",
	},
	lobby_reach_no_upnp = {
		en = "NOT reachable: your router did not answer UPnP. Turn UPnP on, or forward a port and set Manual address.",
	},
	join_host_unreachable = {
		en = "they answered, but none of their addresses could be reached",
	},
	lobby_reach_no_native = {
		en = "Reachable by NAT punch only: the native component is not installed, so the router was never asked.",
	},
	lobby_reach_off = {
		en = "Reachable by NAT punch. Router port mapping is switched off in the mod settings.",
	},
	rc_advertise_mode = {
		en = "Advertise mode",
	},
	advertise_mode_tooltip = {
		en = "Who is allowed to knock and get an automatic ack: Off refuses everyone, Friends allows your saved codes and platform friends, Open allows anyone whose account you are already watching. Open reveals your public address and a punch target to that wider set, so only use it if you understand that trade-off.",
	},
	advertise_mode_off = {
		en = "Off",
	},
	advertise_mode_friends = {
		en = "Friends",
	},
	advertise_mode_open = {
		en = "Open",
	},
	rc_saved_codes = {
		en = "Saved friend codes",
	},
	saved_codes_tooltip = {
		en = "Friend codes to keep an eye on, comma separated. Bounded by the Vox Manifold watch cap.",
	},
	rc_auto_accept_friends = {
		en = "Auto-accept friends",
	},
	auto_accept_friends_tooltip = {
		en = "Knocks from friends skip the confirmation prompt.",
	},
	rc_auto_accept_friends_in_mission = {
		en = "Let friends join mid-mission",
	},
	auto_accept_friends_in_mission_tooltip = {
		en = "Friends who knock while you are in a mission join straight away. You cannot be asked during a mission, so with this off their knock is refused instead.",
	},
	lobby_reach_copy_unavailable = {
		en = "No public address has been worked out yet, so there is nothing to copy.",
	},
	lobby_reach_copied = {
		en = "Your public address was copied to your clipboard.",
	},
	lobby_reach_copy_hint = {
		en = "click to copy",
	},
	rc_mask_addresses = {
		en = "Hide my address and code on screen",
	},
	mask_addresses_tooltip = {
		en = "For streaming. Hides every public address on screen as x.x.x.x and your friend code as xxxx-xxxx. Click either to copy the real one. Local addresses stay readable. The log is untouched, so failures can still be diagnosed.",
	},
	rc_diag_redaction = {
		en = "Diagnostic report redaction",
	},
	diag_redaction_tooltip = {
		en = "How much /rc_diag reveals. Masked hides public IP addresses; full is for sharing directly with the mod author.",
	},
	diag_redaction_masked = {
		en = "Masked",
	},
	diag_redaction_full = {
		en = "Full",
	},
	rc_debug_mode = {
		en = "Debug logging",
	},
	debug_mode_tooltip = {
		en = "Log extra detail about the join state machine to the DMF log.",
	},
	join_view_title = {
		en = "Join a Realm",
	},
	join_view_code_label = {
		en = "Friend code",
	},
	join_view_code_placeholder = {
		en = "Friend code, or ip:port",
	},
	join_view_connect = {
		en = "Connect",
	},
	join_view_own_code_label = {
		en = "Your code:",
	},
	join_view_own_code_unavailable = {
		en = "Your code is not available yet",
	},
	join_view_own_code_copy_hint = {
		en = "Click your code to copy it.",
	},
	join_view_own_code_copied = {
		en = "Copied to your clipboard.",
	},
	join_view_own_code_copy_failed = {
		en = "The clipboard refused the copy. Read the code above and type it out instead.",
	},
	join_view_own_code_copy_unavailable = {
		en = "This build of the game exposes no clipboard. Read the code above and type it out instead.",
	},
	join_view_status_idle = {
		en = "Enter a friend code and press Connect.",
	},
	join_view_status_working = {
		en = "Working",
	},
	join_view_state_locating = {
		en = "finding your address",
	},
	join_view_status_done = {
		en = "Connected.",
	},
	join_already_in_session = {
		en = "You are already in a Realms session. Leave it before joining another.",
	},
	join_view_status_failed = {
		en = "Join failed",
	},
	join_no_candidates_no_dll = {
		en = "Realms Connect: the native component is not installed, so no address could be gathered to knock with. Set a manual address instead.",
	},
	join_no_candidates_stun_pending = {
		en = "Realms Connect: still gathering your address, try Connect again in a moment.",
	},
	join_no_candidates_stun_failed = {
		en = "Realms Connect: could not determine an address to knock with. Set a manual address instead.",
	},
	join_no_candidates_generic = {
		en = "Realms Connect: no usable address was found to knock with.",
	},
	join_channel_busy = {
		en = "Realms Connect: busy answering another player's knock right now, try Connect again in a moment.",
	},
	join_host_not_running_the_mod = {
		en = "that account is online but is not running Realms Connect, so nothing was there to answer",
	},
	join_realms_version_mismatch = {
		en = "You and the host are running different versions of Realms, so Realms refused the connection. You must both use the same version. Check yours in Esc -> Mods.",
	},
	join_host_incompatible = {
		en = "that account is running a version of Realms Connect this one cannot talk to",
	},
	join_host_running_but_silent = {
		en = "that account is running Realms Connect but did not answer; they may have advertising switched off, or the punch was blocked",
	},
	join_view_scan = {
		en = "Check friends for open lobbies",
	},
	join_view_skip = {
		en = "Skip",
	},
	join_view_scanning = {
		en = "Checking...",
	},
	join_panel_title = {
		en = "Realms Connect",
	},
	join_panel_code_label = {
		en = "Their friend code, or a direct ip:port",
	},
	scan_idle = {
		en = "Press Scan friends to see which of your online friends are hosting a Realm.",
	},
	scan_enumerating = {
		en = "Looking up your friends list...",
	},
	scan_checking = {
		en = "Checking friends...",
	},
	scan_none_hosting = {
		en = "None of your online friends are hosting a Realm right now.",
	},
	scan_password_needed = {
		en = "This Realm needs a password. Type it in the Password box above, then Connect.",
	},
	scan_no_friends_online = {
		en = "None of your friends are online right now.",
	},
	scan_busy = {
		en = "A friends scan is already running.",
	},
	scan_failed_no_session = {
		en = "The friends scan only works once you are in the Mourningstar.",
	},
	scan_failed_no_social = {
		en = "The game's social service is not available, so your friends list could not be read.",
	},
	scan_failed_no_presence = {
		en = "Vox Manifold is not available, so friends cannot be checked.",
	},
	scan_failed_fetch = {
		en = "Your friends list could not be read. Try again in a moment.",
	},
	scan_failed_timeout = {
		en = "Your friends list did not come back in time. Try again in a moment.",
	},
	scan_failed_session_ended = {
		en = "The scan stopped because you left the Mourningstar.",
	},
	scan_row_hosting = {
		en = "hosting",
	},
	join_panel_password_label = {
		en = "Password for this Realm",
	},
	join_view_password_placeholder = {
		en = "Password",
	},
	join_card_position = {
		en = "Open Realm {index} of {total}",
	},
	join_card_from_code = {
		en = "From the friend code you entered",
	},
	join_card_looking_up = {
		en = "Looking up that friend code...",
	},
	join_card_gone = {
		en = "That Realm is no longer listed. Scan again.",
	},
	join_card_back = {
		en = "Back",
	},
	join_card_skip = {
		en = "Skip",
	},
	join_card_look_up = {
		en = "Look Up",
	},
	scan_row_mission_unknown = {
		en = "a Realm",
	},
	scan_row_locked = {
		en = "(password)",
	},
	scan_row_in_progress = {
		en = "(mission under way)",
	},
	scan_row_in_progress_closed = {
		en = "(mission under way, closed)",
	},
	scan_row_not_hosting = {
		en = "running Realms Connect, not hosting",
	},
	scan_row_incompatible = {
		en = "running an incompatible version of Realms Connect",
	},
	scan_row_not_running = {
		en = "not running Realms Connect",
	},
	scan_row_unchecked_cap = {
		en = "not checked, the scan limit was reached",
	},
	scan_row_unchecked_no_watch = {
		en = "not checked, no temporary watch was available",
	},
	scan_row_unchecked_aborted = {
		en = "not checked, the scan stopped early",
	},
	scan_more_rows = {
		en = "... and this many more friends, not shown:",
	},
	join_view_status_awaiting = {
		en = "They are running Realms Connect and have been asked to let you in. Waiting for them to answer.",
	},
	accept_prompt_title = {
		en = "Someone wants to join your Realm",
	},
	accept_prompt_description = {
		en = "Accepting reveals your address to them so the connection can be made. Declining tells them nothing.",
	},
	lobby_tab_requests = {
		en = "Requests",
	},
	lobby_tab_mission = {
		en = "Mission",
	},
	lobby_mission_no_details = {
		en = "This Realm's mission has no circumstance or side mission to report.",
	},
	lobby_not_hosting = {
		en = "You are not hosting this Realm, so nobody can join through you. The host handles join requests.",
	},
	lobby_request_expired = {
		en = "Expired before it was answered:",
	},
	lobby_queue_full = {
		en = "The request queue is full, further knocks are turned away.",
	},
	lobby_more_waiting = {
		en = "Answer these to see the others still waiting:",
	},
	lobby_request_waiting_turn = {
		en = "Waiting: {position}",
	},
	lobby_broadcast_start = {
		en = "Open this lobby",
	},
	lobby_broadcast_stop = {
		en = "Stop broadcasting",
	},
	lobby_broadcast_started = {
		en = "Open. Anyone you can see may ask to join.",
	},
	lobby_broadcast_stopped = {
		en = "The lobby is no longer broadcasting.",
	},
	lobby_broadcast_failed = {
		en = "The lobby could not be opened.",
	},
	lobby_accept = {
		en = "Accept",
	},
	lobby_deny = {
		en = "Deny",
	},
	accept_none = {
		en = "No one is asking to join right now.",
	},
	accept_request_gone = {
		en = "That join request is no longer waiting.",
	},
	accept_seconds_left = {
		en = "Expires in",
	},
	accept_seconds_suffix = {
		en = "s",
	},
	accept_prompt_accept = {
		en = "Let them in",
	},
	accept_prompt_decline = {
		en = "Refuse",
	},
	accept_prompt_friend = {
		en = "Friend",
	},
	accept_prompt_stranger = {
		en = "Stranger",
	},
	accept_prompt_version_compatible = {
		en = "Version",
	},
	accept_prompt_version_incompatible = {
		en = "Version mismatch",
	},
	accept_prompt_version_unknown = {
		en = "Version unknown",
	},
	knock_notification_body = {
		en = "{name} - {relationship}",
	},
	knock_notification_accept = {
		en = "{accept} Let them in    {decline} Refuse",
	},
	knock_notification_echo = {
		en = "Realms Connect: {name} wants in. {accept} accept, {decline} refuse.",
	},
}
