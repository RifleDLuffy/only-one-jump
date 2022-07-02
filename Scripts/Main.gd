extends Node2D

class_name Main

var scene_manager: SceneManager = SceneManager.new(self)

var online_game = false
var player_name = ""
var network_data = {}
var stored_IP = ""
var game_started: bool = false
var disconnection_container = null
remotesync var world_str = ""
remotesync var world_details = ""

var peer = null
const SERVER_PORT = 9658
const MAX_PLAYERS = 2
const LOCAL_HOST = "127.0.0.1"
# Dictionary mapping player names ("host", "guest") to network ids
var players = {}

# If player index = 0 and the game is online, then that means the first player
# object in players_for_level_main belongs is associated with this instance of the game.
remote var player_index
# Contains the player objects
var players_for_level_main = [null, null]

remotesync func change_to_select_mon_scene(scene_str, _world_str, _world_details):
	rset("world_str", _world_str)
	rset("world_details", _world_details)
	var scene = scene_manager._load_scene(scene_str)
	scene_manager._replace_scene(scene)

func get_other_player_network_id():
	var player_keys = players.keys()
	player_keys.erase(player_name)
	return players[player_keys[0]]

func _ready():
	# The event that triggers when a player connects to this instance of the game
	get_tree().connect("network_peer_connected", self, "_player_connected")
	get_tree().connect("network_peer_disconnected", self, "_player_disconnected")
	get_tree().connect("server_disconnected", self, "_server_disconnected")
	$CL/Popup/CloseButton.connect("button_down", self, "close_popup")
	
	var scene = scene_manager._load_scene("Levels/Level 1")
	scene_manager._replace_scene(scene)

func load_level(level_num: int):
	var scene = scene_manager._load_scene("Levels/Level %d"%level_num)
	scene_manager._replace_scene(scene)

# Register a player to a dictionary that contains player names and player ids
remote func register_player(_player_name, id):	
	players[_player_name] = id
	create_notification(_player_name + " has connected")
	# Remove the back button for the host once the guest has connected
	get_children()[0].get_node("TextureButton").visible = false
	
	if _player_name == "guest" and player_name == "host":
		all_players_connected()

func sync_rng_seed():
	rpc_id(players['guest'], "set_rng_seed", Utils.rng.seed, Utils.rng.state)

remote func set_rng_seed(_seed, _state):
	Utils.rng.seed = _seed
	Utils.rng.state = _state

# A function that is trigggered when all players are connected
func all_players_connected():
	var scene = scene_manager._load_scene("UI/Level Select")
	scene_manager._replace_scene(scene)
	
	if online_game:
		var first_player = Utils.select_random(["host", "guest"])
		if first_player == "host":
			create_notification("You are player 1.")
			rpc_id(players["guest"], "create_notification", "You are player 2.")
			player_index = 0
			rset_id(players["guest"], "player_index", 1)
		else:
			create_notification("You are player 2.")
			rpc_id(players["guest"], "create_notification", "You are player 1.")
			player_index = 1
			rset_id(players["guest"], "player_index", 0)
	else:
		create_notification("Pick between the two of you who goes first.")
		player_index = 0

# General purpose notification system
####### 
var notifications = []

remote func create_notification(notification_str, duration=3, alignment=Label.ALIGN_LEFT):
	var notification = Label.new()
	notification.autowrap = true
	notification.text = notification_str
	notification.align = alignment
	notification.add_font_override("font", load("res://Assets/Fonts/Font_50.tres"))
	notification.add_stylebox_override("normal", load("res://Assets/label_background.tres"))
	if alignment == Label.ALIGN_LEFT:
		$CL/HBox/VBoxLeft.add_child(notification)
	elif alignment == Label.ALIGN_RIGHT:
		$CL/HBox/VBoxRight.add_child(notification)
	else:
		printerr("Invalid alignment received")
		assert(false)
	
	notifications.append(notification)
	get_tree().create_timer(duration).connect("timeout", self, "delete_last_notification")

func delete_last_notification():
	if not notifications:
		return
	var notification = notifications.pop_front()
	if notification.align == Label.ALIGN_LEFT:
		$CL/HBox/VBoxLeft.remove_child(notification)
	elif notification.align == Label.ALIGN_RIGHT:
		$CL/HBox/VBoxRight.remove_child(notification)
	else:
		printerr("Invalid alignment received")
		assert(false)
	notification.queue_free()

func clear_all_notifications():
	while notifications:
		delete_last_notification()
#######

# Popup system
#######
func popup_organism(organism):
	open_popup(organism.oname, organism.get_combined_ability_description())

func open_popup(title, details):
	$CL/Popup.visible = true
	print(title)
	$CL/Popup/Title.text = title
	$CL/Popup/Details.text = details

func close_popup():
	$CL/Popup.visible = false
####### 

# Create a server and set the network peer to the peer you created
func host():
	peer = NetworkedMultiplayerENet.new()
	peer.create_server(SERVER_PORT, MAX_PLAYERS)
	get_tree().network_peer = peer
	
	# Adding yourself to the list of players
	if online_game:
		register_player(player_name, get_tree().get_network_unique_id())

func guest(server_IP):
	save_used_IP(server_IP)
	# Default of 127.0.0.1
	if not server_IP:
		server_IP = LOCAL_HOST
	# Create a client and set the network peer to the peer you created
	peer = NetworkedMultiplayerENet.new()
	peer.create_client(server_IP, SERVER_PORT)
	get_tree().network_peer = peer
	
	# Adding yourself to the list of players 
	register_player(player_name, get_tree().get_network_unique_id())

func load_save(save_dict):
	# Setting up the game
	rpc("load_level", "Levels/Level Main", save_dict["world"])
	
	# Setting up curr_player and curr_player_index
	var main = get_children()[0]
	main.curr_player = main.players[save_dict["curr_player"]]
	
	#TODO
	# Load in the organisms from the save file and attach them to the players
	# Give the players their berries, and health
	
	if online_game:
		main.Sync.synchronize_all(players["guest"])
	main.update_labels()

# NETWORKING CALLBACKS
#######
# Callback from SceneTree.
func _player_connected(id):
	# Registering the new player that connected
	rpc_id(id, "register_player", player_name, get_tree().get_network_unique_id())

# Callback from SceneTree, only for clients (not server).
func _server_disconnected():
	disconnection_routine("The guest has disconnected.\nStart a new game.\nOr start a new game and load the last save.")

# Callback from SceneTree.
func _player_disconnected(id):
	disconnection_routine("The host has disconnected.\nStart a new game.\nOr start a new game and load the last save.")

func disconnection_routine(message_str):
	var notification = Label.new()
	notification.text = message_str
	notification.add_font_override("font", load("res://Assets/Fonts/Font_50.tres"))
	notification.add_stylebox_override("normal", load("res://Assets/label_background.tres"))
	
	var button = Button.new()
	button.text = "Start a new game"
	button.connect("button_down", self, "hard_reboot") 
	button.add_font_override("font", load("res://Assets/Fonts/Font_50.tres"))
	
	disconnection_container = CanvasLayer.new()
	add_child(disconnection_container)
	
	var centerbox = CenterContainer.new()
	centerbox.rect_size = Vector2(1920,1080)
	disconnection_container.add_child(centerbox)
	
	var vbox = VBoxContainer.new()
	centerbox.add_child(vbox)
	vbox.add_child(notification)
	vbox.add_child(button)
	
	if game_started:
		scene_manager._get_curr_scene().stop_game()

# Send the player to the first relevant UI menu and nuke game data
func hard_reboot():
	scene_manager.reset()
	var scene = scene_manager._load_scene("UI/Local Online")
	scene_manager._replace_scene(scene)
	remove_child(disconnection_container)
	disconnection_container.queue_free()
	disconnection_container = null
#######

# IP Saving
#######
# Loading the previously used IP address
func get_last_used_IP():
	var file = File.new()
	file.open("user://last_ip.dat", File.READ)
	var text = file.get_as_text()
	file.close()
	return text

# Store the entered IP address
func save_used_IP(server_IP):
	var file = File.new()
	file.open("user://last_ip.dat", File.WRITE)
	file.store_string(server_IP)
	file.close()
#######
