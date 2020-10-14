extends PanelContainer

const LOCAL_PORTS = [5999, 6000]
const HANDSHAKE_IP = '192.168.1.54'
const HANDSHAKE_PORT = 5189
const IS_HANDSHAKE_SERVER = false #set true for server exports

enum MESSAGE_TYPE {GAME_START, MOVE, MOUSE_PRESSED_DOWN}

const TOKEN_TO_TEXTURE = {
	'naughts': preload("res://naught.png"),
	'crosses': preload("res://cross.png")
}

#taken from https://stackoverflow.com/a/24376236
const LAST_INDEX_TO_WIN_LINES = [
	[[1, 2], [4, 8], [3, 6]],
	[[0, 2], [4, 7]],
	[[0, 1], [4, 6], [5, 8]],
	[[4, 5], [0, 6]],
	[[3, 5], [0, 8], [2, 6], [1, 7]],
	[[3, 4], [2, 8]],
	[[7, 8], [2, 4], [0, 3]],
	[[6, 8], [1, 4]],
	[[6, 7], [0, 4], [2, 5]]
]

onready var _board = find_node("Board")
onready var _players_waiting_label = find_node("PlayersWaitingLabel")
onready var _status_label = find_node("StatusLabel")
onready var _connect_button = find_node("ConnectButton")
onready var _disconnect_button = find_node("DisconnectButton")

var _current_board
var _num_moves_made
var _player_token
var _is_my_turn
var _client_points = []
var _update_server_status_countdown = 0.5 if not IS_HANDSHAKE_SERVER else null

func _ready():
	_connect_button.connect("pressed", self, "_connect_pressed")
	_disconnect_button.connect("pressed", self, "_disconnect_pressed")
	randomize()
	
	Network.set_network_details({
		Network.DETAILS_KEY_LOCAL_PORTS: LOCAL_PORTS,
		Network.DETAILS_KEY_HANDSHAKE_IP: HANDSHAKE_IP,
		Network.DETAILS_KEY_HANDSHAKE_PORT: HANDSHAKE_PORT,
	})
	if IS_HANDSHAKE_SERVER:
		Handshake.init()
	Network.connect("auto_connect_failed", self, '_auto_connect_failed')
	Network.connect('registered_as_host', self, '_registered_as_host')
	Network.connect('register_host_failed', self, '_register_host_failed')
	Network.connect('joined_to_host', self, '_joined_to_host')
	Network.connect('join_host_failed', self, '_join_host_failed')
	Network.connect('client_joined', self, '_client_joined')
	Network.connect('player_dropped', self, '_player_dropped')
	Network.connect('message_received', self, '_message_received')
	Network.connect('session_terminated', self, '_session_terminated')
	

func _connect_pressed():
	_connect_button.disabled = true
	_connect_button.text = '. . .'
	Network.auto_connect()
	
func _disconnect_pressed():
	_disconnect_button.disabled = true
	Network.reset()

func _update_active_player(next_player):
	_is_my_turn = Network.get_player_name() == next_player
	_status_label.text = 'Your Turn!' if _is_my_turn else 'Their Turn!'

func _game_over(winning_token):
	if winning_token == null:
		_status_label.text = 'Draw'
	elif winning_token == _player_token:
		_status_label.text = 'You Win!'
	else:
		_status_label.text = 'You Lost!'
	var session_id = Network.get_session_id()
	yield(get_tree().create_timer(1.2), 'timeout')
	if not is_inside_tree():
		return
	if Network.is_networking() and Network.get_session_id() == session_id:
		Network.reset()


###################################
#        NETWORK SIGNALS          #
###################################

func _auto_connect_failed(reason):
	print('Failed to connect: %s' % reason)

func _registered_as_host(host_name, handshake_address):
	_status_label.text = 'Waiting for player 2...'
	_disconnect_button.visible = true
	_connect_button.visible = false
	_update_server_status_countdown = 0.1
	_client_points = []

func _register_host_failed(reason):
	print('Failed to register host: %s' % reason)

func _joined_to_host(host_name, address):
	_status_label.text = 'Connected!'
	_disconnect_button.visible = true
	_connect_button.visible = false
	_update_server_status_countdown = 0.1

func _join_host_failed(reason):
	print('Failed to join host: %s' % reason)

func _client_joined(player_name, player_address, extra_info):
	var first_player = player_name if randf() < 0.5 else Network.get_player_name()
	Network.send_message({'type': MESSAGE_TYPE.GAME_START, 'next-player':first_player})
	Network.drop_handshake()
	_update_server_status_countdown = 0.1

func _player_dropped(player_name):
	print('Player dropped: %s' % player_name)
	Network.reset()

func _session_terminated():
	_connect_button.text = 'Connect'
	_connect_button.visible = true
	_connect_button.disabled = false
	_disconnect_button.disabled = false
	_disconnect_button.visible = false
	_status_label.text = 'Ready to Connect'
	_current_board = null
	_num_moves_made = null
	_player_token = null
	_is_my_turn = null
	_client_points.clear()
	update()

func _message_received(from_player_name, to_players, message):
	match message['type']:
		MESSAGE_TYPE.GAME_START:
			_num_moves_made = 0
			_current_board = []
			for i in 3*3:
				_current_board.push_back(null)
			_update_active_player(message['next-player'])
			_player_token = 'naughts' if _is_my_turn else 'crosses'
		
		MESSAGE_TYPE.MOVE:
			var token = message['token']
			var index = message['i']
			_current_board[index] = token
			_num_moves_made += 1
			update()
			for line in LAST_INDEX_TO_WIN_LINES[index]:
				if token == _current_board[line[0]] and token == _current_board[line[1]]:
					_game_over(token)
					return
			if _num_moves_made == 9:
				_game_over(null)
				return
			_update_active_player(message['next-player'])
			
		MESSAGE_TYPE.MOUSE_PRESSED_DOWN:
			_client_points.push_back(message['pos'])
			update()

###################################
###################################


func _process(delta):
	if Network.is_player_client():
		if Input.is_action_pressed("left_mouse"):
			Network.send_unreliable_message_to_host({
				'type': MESSAGE_TYPE.MOUSE_PRESSED_DOWN,
				'pos': get_global_mouse_position()
			})
	if _update_server_status_countdown != null:
		_update_server_status_countdown -= delta
		if _update_server_status_countdown < 0:
			_update_server_status()
	
	if _is_my_turn != null and _is_my_turn:
		if Input.is_action_just_pressed("left_mouse"):
			var board_global_rect = _board.get_global_rect()
			if board_global_rect.has_point(get_global_mouse_position()):
				var cell_size = board_global_rect.size / 3
				var coords = ((get_global_mouse_position() - board_global_rect.position) / cell_size).floor()
				var index = coords.x + 3 * coords.y
				if _current_board[index] == null:
					_current_board[index] = _player_token
					Network.send_message({
						'type': MESSAGE_TYPE.MOVE, 
						'i': index,
						'token': _player_token,
						'next-player': Network.get_other_player_names()[0]
					})
					_is_my_turn = null
					update()


func _update_server_status():
	_update_server_status_countdown = null
	var func_key = Network.get_host_infos_from_handshake([HANDSHAKE_IP, HANDSHAKE_PORT])
	while Network.fapi.is_func_ongoing(func_key):
		yield(Network, 'host_infos_request_completed')
	var result = Network.fapi.get_info_for_completed_func(func_key)
	if result != null and not result['timed-out']:
		var hosts = result['reply-data']
		_players_waiting_label.text = 'Players waiting: %s' % hosts.size()
	else:
		_players_waiting_label.text = 'Players waiting: 0' 
	_update_server_status_countdown = 10



func _draw():
	var board_global_rect = _board.get_global_rect()
	var cell_size = board_global_rect.size / 3
	
	for i in range(1,3):
		var x = board_global_rect.position.x + i * cell_size.x
		var y =  board_global_rect.position.y
		draw_line(Vector2(x,y), Vector2(x,y+board_global_rect.size.y),Color.white, 3)
		
		x = board_global_rect.position.x
		y = board_global_rect.position.y + i * cell_size.y
		draw_line(Vector2(x,y), Vector2(x+board_global_rect.size.x, y),Color.white, 3)
	
	if _current_board != null:
		for i in _current_board.size():
			var coord = Vector2(i % 3, i / 3)
			if _current_board[i] != null:
				var cell_pos = board_global_rect.position + coord * cell_size
				var texture = TOKEN_TO_TEXTURE[_current_board[i]]
				draw_texture_rect(texture, Rect2(cell_pos, cell_size),false)
	
	for point in _client_points:
		draw_rect(Rect2(point, Vector2(25,25)),Color.green,true)
