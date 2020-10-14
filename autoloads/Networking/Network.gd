extends Node

"""
Hosts just keeps trying to ping handshake server- you can drop it at any time
Handshake server drops host after waiting too long for contact.
Host faulties client after waiting too long for ping reply.
Client faulties host after no contact for too long
If a send_message.... times out, we faulty that connection

messages dont have order, but the sender can 
easily yield until everyone gets it.
"""

"""
todo:
	* move RESEND_INTERVAL_SECS from udp socket to net details
	* test on lan with >2 people
	* test on wan with >2 people
	* documentation
	* transer_to_enet function
"""
signal session_terminated()
signal host_infos_request_completed(info_or_null_on_error)
signal misc_request_completed(info_or_null_on_error)


#this is emitted when a connection becomes deemed faulty
#call decision_to_keep_trying_faulties_made and pass
#whether or not to keep trying. this allows the user
#to decide whether a conection has really timed out
#although beware, too long between packets and NAT will shut port
#if no one is connnected to this signal, the connection is dropped
signal faulty_connection(player_name)
#signal _answer_ready_for_faulty_connection()
signal connection_restored(player_name)
#automatically terminate if player_name was host
signal player_joined(player_name)
signal player_dropped(player_name)
#this is only emitted on the player that sent the message.
#they'll either have received it, or been dropped.
#Example:
#var func_key = Network.send_message(message_input_field.text)
#while Network.fapi.is_func_ongoing(func_key):
#	yield(Network, 'sent_message_received_by_all')
signal sent_message_received_by_all()
#to_players will include this user but maybe others
signal message_received(from_player_name, to_players, message)
signal _send_to_connected_faulty_if_no_reply_completed()
signal _sent_message_received_by_all()

#note that in reply to an autojoin, the handshake 
#server will send either info for a host or
#confirmation of registration (or error). After that
#point, registering/joining is carried out as normal,
#so the success/error signals appropriate to that method
#will fire. This signal is for errors that occur before that
#when the user is neither registering nor joining
signal auto_connect_failed(reason)

#host only
signal handshake_joined()
#works same as faulty_connection
signal handshake_faulty()
signal handshake_connection_restored(client_name)
#does not automatically terminate session
signal handshake_dropped()
signal register_host_failed(reason)
signal registered_as_host(host_name, handshake_address)
#emitted BEFORE player_joined
signal client_joined(client_name, address, extra_info) 
signal client_dropped(client_name)

#client only
signal host_dropped()#player_dropped also gets called
signal host_details_received_from_handshake()
signal join_host_failed(reason)
signal joined_to_host(host_name, address)


const CHARS = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789'
const HANDSHAKE_SERVER_PLAYER_NAME = "<Handshake Server>"
const CUSTOM_UDP_WRAPPER_SCRIPT = preload("./UDPSocketWrapper.gd")
var key_generator = KeyGenerator.new()
var fapi = preload('./FuncAwaitAPI.gd').new()

var _player_is_host
var _host_player_name
var _my_player_name
var _is_accepting_new_clients
var _is_resetting = false

#after each yield in a yielding function,
#_net_id is checked. if it has changed since the funciton
#began, the function knows the network has been reset
#and exits
onready var _net_id = 0
onready var _unique_id = key_generator.generate_key()
onready var _idx = "%s|%s" % [_unique_id, _net_id]
var _is_networking = false
var _udp_socket

#note that in the host, this does not include the host name
#while in the clients, their own names are included.
#It's just easier that way. I add the host to 
#Network.get_player_names() in the host
var _player_name_to_connection = {}
var _player_names_no_handshake = []

var _faulty_connections = []
var _give_up_on_faulty_connections = null#null=undecided

var _packets_to_process_once_joined_to_host = []
#for host
var _initing_client_unique_id_to_info = {}

#for clients
var _packets_to_process_once_name_joined = {}
var _packets_to_process_once_name_dropped = {}

var _host_address
var _attempting_to_join_host = false

var _sent_message_ids_not_received_by_all = []
var _sent_message_id_keeper = 0



#func_name should take one argument, which is
#the extra_info sent by the client.
#(I already check whether name is free in host.)
#Should return null if OK, or the reason as a string
var _node_and_func_for_client_reject_reason = [weakref(null), null]
func set_get_client_reject_reason_func(node, func_name):
	_node_and_func_for_client_reject_reason[0] = weakref(node)
	_node_and_func_for_client_reject_reason[1] = func_name
func _get_client_reject_reason(extra_info):
	var func_info = _node_and_func_for_client_reject_reason
	if func_info[0].get_ref() == null:
		return null
	return func_info[0].get_ref().callv(func_info[1], [extra_info])




################################
#    Changeable Network Details
################################
enum {
	DETAILS_KEY_HANDSHAKE_PORT,
	DETAILS_KEY_HANDSHAKE_IP,
	DETAILS_KEY_LOCAL_IPS,#note: use get_local_ips instead of get_network_detail
	DETAILS_KEY_LOCAL_PORT,
	DETAILS_KEY_UDP_TIMEOUT_SECS,
	DETAILS_KEY_PING_INTERVAL_SECS,
	DETAILS_KEY_MAX_SECS_WITHOUT_CONTACT_FROM_HOST_BEFORE_FAULTY
}
var _network_details = {
	DETAILS_KEY_HANDSHAKE_PORT: 5111,
	DETAILS_KEY_HANDSHAKE_IP: '127.0.0.1',
	DETAILS_KEY_LOCAL_IPS: 'auto', #if 'auto', will attempt them all
	DETAILS_KEY_LOCAL_PORT: 5141,
	DETAILS_KEY_UDP_TIMEOUT_SECS: 10,
	DETAILS_KEY_PING_INTERVAL_SECS: 8,
	DETAILS_KEY_MAX_SECS_WITHOUT_CONTACT_FROM_HOST_BEFORE_FAULTY: 20
}
#pass a dict with DETAILS_KEY_... entries
func set_network_details(info):
	for key in info:
		if _network_details.has(key):
			_network_details[key] = info[key]
func get_network_detail(key):
	return _network_details[key]

func get_handshake_address():
	if _player_name_to_connection.has(HANDSHAKE_SERVER_PLAYER_NAME):
		return _player_name_to_connection[HANDSHAKE_SERVER_PLAYER_NAME]['player-address']
	return [get_network_detail(DETAILS_KEY_HANDSHAKE_IP),
			get_network_detail(DETAILS_KEY_HANDSHAKE_PORT)]
func get_local_ips():
	var local_ips = get_network_detail(DETAILS_KEY_LOCAL_IPS)
	if local_ips == 'auto':
		local_ips = []
		var local_ips_temp = IP.get_local_addresses()
		for local_ip in local_ips_temp:
			if local_ip.find(':') == -1 and not local_ip.begins_with('127.0.'):
				local_ips.push_front(local_ip)
	return local_ips

func get_player_names(include_handshake = false):
	var names = _player_name_to_connection.keys().duplicate()
	if not include_handshake and names.has(HANDSHAKE_SERVER_PLAYER_NAME):
		names.erase(HANDSHAKE_SERVER_PLAYER_NAME)
	if _player_is_host:
		names.push_back(_my_player_name)
	return names
func get_other_player_names(include_handshake = false):
	var names = _player_name_to_connection.keys().duplicate()
	names.erase(_my_player_name)
	if not include_handshake and names.has(HANDSHAKE_SERVER_PLAYER_NAME):
		names.erase(HANDSHAKE_SERVER_PLAYER_NAME)
	if _player_is_host:
		names.push_back(_my_player_name)
	return names
func is_player_host():
	return _player_is_host

func get_player_name():
	return _my_player_name

func is_networking():
	return _is_networking

func stop_accepting_new_client():
	_is_accepting_new_clients = false

#############################################
#       Registering, Joining, Misc and _ready
#############################################


func _ready():
	_udp_socket = CUSTOM_UDP_WRAPPER_SCRIPT.new()
	add_child(_udp_socket)
	_udp_socket.connect('packet_received', self, '_udp_packet_received')


func get_session_id():
	return _net_id

func reset():
	if not _is_networking or _is_resetting:
		return
	_is_resetting = true
	for connection in _player_name_to_connection.values():
		#false no emit signals, yes send dropme, yes coming from reset
		_drop_connection(connection, false, true, true)
	_udp_socket.stop_listening()
	_udp_socket.clear()
	
	_net_id += 1
	_idx = "%s|%s" % [_unique_id, _net_id]

	_is_networking = false
	_attempting_to_join_host = false
	_host_address = null
	_host_player_name = null
	_my_player_name = null
	_player_is_host = null
	_is_accepting_new_clients = null
	_packets_to_process_once_joined_to_host.clear()
	_initing_client_unique_id_to_info.clear()
	_packets_to_process_once_name_dropped.clear()
	_packets_to_process_once_name_joined.clear()
	_player_name_to_connection.clear()
	_player_names_no_handshake.clear()
	_faulty_connections.clear()
	_give_up_on_faulty_connections = null
	_sent_message_ids_not_received_by_all.clear()
	_sent_message_id_keeper = 0
	emit_signal('session_terminated')
	_is_resetting = false

func test_addresses_equal(address_a, address_b):
	return address_a[0] == address_b[0] and address_a[1] == address_b[1]

#does not test the semantics, just the data types
func test_address_valid_data_format(address):
	return (typeof(address) == TYPE_ARRAY
		and address.size() == 2
		and test_ip_valid_data_format(address[0])
		and test_port_valid_data_format(address[1])
	)

func test_ip_valid_data_format(ip):
	 return typeof(ip) == TYPE_STRING and ip.is_valid_ip_address()

func test_port_valid_data_format(port):
	return (typeof(port) == TYPE_REAL
			or typeof(port) == TYPE_INT
		) and str(int(port)) == str(port)



func register_as_host(player_name, extra_info=null):
	reset()
	var last_known_net_id = _net_id
	_is_networking = true
	
	var local_ips = get_local_ips()
	var local_port = get_network_detail(DETAILS_KEY_LOCAL_PORT)
	var handshake_address = get_handshake_address()
	
	if player_name == HANDSHAKE_SERVER_PLAYER_NAME:
		emit_signal('register_host_failed', 'Invalid player name.')
	_udp_socket.init(local_port,
		get_network_detail(DETAILS_KEY_UDP_TIMEOUT_SECS),
		{'_idx': _idx}, _UDP_SOCKET_MINIMISATION_KEYS
	)
	if _udp_socket.start_listening() != OK:
		emit_signal('register_host_failed',
			"Error initting udp socket to listen at %s" % local_port
		)
		reset()
		return
	
	var init_handshake = false
	if handshake_address[0] == ""  or handshake_address[0] == '127.0.0.1':
		init_handshake = true
	elif local_ips.has(handshake_address[0]):
		init_handshake = true
	if init_handshake:
		if not Handshake.is_running():
			Handshake.init()
	
	self._player_is_host = true
	self._my_player_name = player_name
	self._host_player_name = player_name
	
	var reg_data = Handshake._make_host_registration_data(
		_my_player_name, local_ips, local_port, extra_info
	)
	var func_key = _udp_socket.send_data_wait_for_reply( 
		reg_data, handshake_address
	)
	while _udp_socket.fapi.is_func_ongoing(func_key):
		yield(_udp_socket, 'send_data_await_reply_completed')
	var func_result = _udp_socket.fapi.get_info_for_completed_func(func_key)
	if last_known_net_id != _net_id:
		return
	
	if func_result['timed-out']:
		emit_signal('register_host_failed', 'Handshake server unreachable.')
		reset()
		return
	var reply_data = func_result['reply-data']
	if reply_data.has('error'):
		emit_signal('register_host_failed', reply_data['error'])
		reset()
		return
	
	_add_connection_to_handshake(func_result['address'])
	_is_accepting_new_clients = true
	emit_signal('handshake_joined')
	emit_signal('registered_as_host', _my_player_name, get_handshake_address())
	emit_signal('player_joined', _my_player_name)
	








func join_host(player_name, host_player_name, extra_info_for_host=null):
	reset()
	var last_known_net_id = _net_id
	_is_networking = true
	
	var local_ips = get_local_ips()
	var local_port = get_network_detail(DETAILS_KEY_LOCAL_PORT)
	var handshake_address = get_handshake_address()
	
	if player_name == HANDSHAKE_SERVER_PLAYER_NAME:
		emit_signal('join_host_failed', 'Invalid player name.')
		return
	
	_udp_socket.init(
		local_port,
		get_network_detail(DETAILS_KEY_UDP_TIMEOUT_SECS),
		{'_idx': _idx}, _UDP_SOCKET_MINIMISATION_KEYS
	)
	if _udp_socket.start_listening() != OK:
		emit_signal(
			'join_host_failed',
			"Error initting udp socket to listen at %s" % local_port
		)
		reset()
		return
	 
	self._player_is_host = false
	self._my_player_name = player_name
	self._host_player_name = host_player_name
	
	_attempting_to_join_host = true
	
	var req_data = Handshake._make_client_join_request_data(
		_my_player_name, _host_player_name, local_ips, local_port
	)
	var func_key = _udp_socket.send_data_wait_for_reply( 
		req_data, handshake_address
	)
	while _udp_socket.fapi.is_func_ongoing(func_key):
		yield(_udp_socket, 'send_data_await_reply_completed')
	var func_result = _udp_socket.fapi.get_info_for_completed_func(func_key)
	if last_known_net_id != _net_id:
		return
	
	if func_result['timed-out']:
		emit_signal('join_host_failed', 'Handshake server unreachable.')
		reset()
		return
	var reply_data = func_result['reply-data']
	if reply_data.has('error'):
		emit_signal('join_host_failed', reply_data['error'])
		reset()
		return
	
	#note: we don't reply to handshake because atm
	#it would be pointless. #todo we could though, 
	#and make the handshake wait before send to client?
	var host_details = func_result['reply-data']
	var host_local_ips = host_details['local-ips']
	var host_local_port = host_details['local-port']
	var host_global_address = host_details['global-address']
	_deal_with_handshake_info_for_join(player_name,
		host_details, host_local_ips, host_local_port, host_global_address,
		extra_info_for_host
	)










func auto_connect(player_name=null, extra_host_info={}, extra_client_info={}):
	reset()
	if player_name == null:
		player_name = ''
		for i in 25:
			player_name += CHARS[randi() % CHARS.length()]
	var last_known_net_id = _net_id
	_is_networking = true
	
	var local_ips = get_local_ips()
	var local_port = get_network_detail(DETAILS_KEY_LOCAL_PORT)
	var handshake_address = get_handshake_address()
	
	if player_name == HANDSHAKE_SERVER_PLAYER_NAME:
		emit_signal('auto_connect_failed', 'Invalid player name.')
	_udp_socket.init(local_port,
		get_network_detail(DETAILS_KEY_UDP_TIMEOUT_SECS),
		{'_idx': _idx}, _UDP_SOCKET_MINIMISATION_KEYS
	)
	if _udp_socket.start_listening() != OK:
		emit_signal('auto_connect_failed',
			"Error initting udp socket to listen at %s" % local_port
		)
		reset()
		return
	
	var init_handshake = false
	if handshake_address[0] == ""  or handshake_address[0] == '127.0.0.1':
		init_handshake = true
	elif local_ips.has(handshake_address[0]):
		init_handshake = true
	if init_handshake:
		if not Handshake.is_running():
			Handshake.init()
	
	var req_data = Handshake._make_auto_connect_data(
		player_name, local_ips, local_port, extra_host_info, extra_client_info
	)
	var func_key = _udp_socket.send_data_wait_for_reply( 
		req_data, handshake_address
	)
	while _udp_socket.fapi.is_func_ongoing(func_key):
		yield(_udp_socket, 'send_data_await_reply_completed')
	var func_result = _udp_socket.fapi.get_info_for_completed_func(func_key)
	if last_known_net_id != _net_id:
		return
	
	if func_result['timed-out']:
		emit_signal('auto_connect_failed', 'Handshake server unreachable.')
		reset()
		return
	var reply_data = func_result['reply-data']
	if reply_data.has('error'):
		emit_signal('auto_connect_failed', reply_data['error'])
		reset()
		return
	
	if reply_data.has('host-registered'):
		self._player_is_host = true
		self._my_player_name = player_name
		self._host_player_name = reply_data['host-registered']
		_add_connection_to_handshake(func_result['address'])
		_is_accepting_new_clients = true
		emit_signal('handshake_joined')
		emit_signal('registered_as_host', _my_player_name, get_handshake_address())
		emit_signal('player_joined', _my_player_name)
	elif reply_data.has('handshake-info-for-client'):
		self._player_is_host = false
		self._my_player_name = player_name
		self._host_player_name = reply_data['handshake-info-for-client']
		_attempting_to_join_host = true
		var host_details = func_result['reply-data']
		var host_local_ips = host_details['local-ips']
		var host_local_port = host_details['local-port']
		var host_global_address = host_details['global-address']
		_deal_with_handshake_info_for_join(player_name,
			host_details, host_local_ips, host_local_port, host_global_address,
			extra_client_info
		)
	else:
		emit_signal('auto_connect_failed',reply_data['error'])
		








func _deal_with_handshake_info_for_join(player_name, host_details,
host_local_ips, host_local_port, host_global_address, extra_info):
	var last_known_net_id = _net_id
	emit_signal('host_details_received_from_handshake')
	
	var my_local_ips = get_local_ips()
	var func_keys = []
	for host_local_ip in host_local_ips:
		if host_local_ip != '127.0.0.1' and not my_local_ips.has(host_local_ip):
			var host_local_address = [[host_local_ip], host_local_port]
			func_keys.push_back(_udp_socket.send_data_wait_for_reply({
					'extra-info': extra_info,
					'used-local': true,
					'client-name': player_name
				}, host_local_address
			))
	
	func_keys.push_back(_udp_socket.send_data_wait_for_reply({
			'extra-info': extra_info,
			'used-local': false,
			'client-name': player_name
		},
		host_global_address
	))
	
	var first_func_key_completed
	while true:
		for func_key in func_keys:
			if not _udp_socket.fapi.is_func_ongoing(func_key):
				first_func_key_completed = func_key
				break
		if first_func_key_completed != null:
			break
		else:
			yield(_udp_socket, 'send_data_await_reply_completed')
	var func_result = _udp_socket.fapi.get_info_for_completed_func(first_func_key_completed)
	for func_key in func_keys:
		_udp_socket.abandon_send_data_wait_for_reply(func_key)
	_attempting_to_join_host = false
	
	if last_known_net_id != _net_id:
		return
	if func_result['timed-out']:#yeah i know, but if this one timed out screw it...
		emit_signal('join_host_failed', 'Host unreachable.')
		reset()
		return
	var reply_data = func_result['reply-data']
	if reply_data.has('error'):
		emit_signal('join_host_failed', reply_data['error'])
		reset()
		return
	
	_host_address = func_result['address']
	var func_key = _udp_socket.send_data_wait_for_reply( 
		{'players-inited':true}, _host_address
	)
	_udp_socket.fapi.abandon_awaiting_func_completion(func_key)
	
	var players = reply_data['init-players']
	var host_idx = reply_data['_idx']
	_add_connection_to_host(_host_player_name, _host_address, host_idx)
	emit_signal("joined_to_host", _host_player_name, _host_address)
	emit_signal('player_joined', _host_player_name)
	
	for player_name in reply_data['init-players']:
		var player_id = reply_data['init-players'][player_name]
		if not _player_name_to_connection.has(player_name):
			_add_psuedo_connection(player_name, player_id)
			emit_signal('player_joined', player_name)
	
	var packet_infos = _packets_to_process_once_joined_to_host
	_packets_to_process_once_joined_to_host = []
	for packet_info in packet_infos:
		var p_data = packet_info['data']
		var p_sender_address = packet_info['sender-address']
		var p_id = packet_info['packet-id']
		var p_conn = _get_connection_for_packet(p_data, p_sender_address)
		if p_conn != null:
			_packet_from_connected(p_data, p_id, p_sender_address, p_conn)






#only call in host
func kick_player(player_name):
	if not _player_is_host:
		print('Error: only host can kick player')
		return
	if not _player_names_no_handshake.has(player_name):
		print('Error: player does not exist to kick: %s' % player_name)
		return
	var connection = _player_name_to_connection[player_name]
	_drop_connection(connection)


func drop_handshake():
	if not _player_is_host:
		print('Error: only host can drop handshake')
		return
	if _player_name_to_connection.has(HANDSHAKE_SERVER_PLAYER_NAME):
		var connection = _player_name_to_connection[HANDSHAKE_SERVER_PLAYER_NAME]
		_drop_connection(connection)



func update_handhake_host_info(new_extra_info):
	if not _player_is_host:
		return
	if not _player_name_to_connection.has(HANDSHAKE_SERVER_PLAYER_NAME):
		return
	var data = Handshake._make_update_info_data(
		_my_player_name, new_extra_info
	)
	var fk = _send_to_connected_faulty_if_no_reply(data, HANDSHAKE_SERVER_PLAYER_NAME)
	fapi.abandon_awaiting_func_completion(fk)


#note that the handshake addres here could be different
#to the set network details
#the function result will contain info or null if the 
#request failed. extra_info is passed to the handshake
#to narrow down the hosts about which info should be sent back
func get_host_infos_from_handshake(handshake_address, extra_info={}):
	var key = fapi.get_add_key()
	_get_host_infos_from_handshake(key, handshake_address, extra_info)
	return key

func _get_host_infos_from_handshake(f_key, handshake_address, extra_info):
	var last_known_net_id = _net_id
	if not _udp_socket.is_inited():
		_udp_socket.init(get_network_detail(DETAILS_KEY_LOCAL_PORT),
			get_network_detail(DETAILS_KEY_UDP_TIMEOUT_SECS),
			{'_idx': _idx}, _UDP_SOCKET_MINIMISATION_KEYS
		)
	_udp_socket.start_listening()
	
	var func_key = _udp_socket.send_data_wait_for_reply( 
		{'info-request':extra_info}, handshake_address
	)
	while _udp_socket.fapi.is_func_ongoing(func_key):
		yield(_udp_socket, 'send_data_await_reply_completed')
	_udp_socket.stop_listening()
	if last_known_net_id != _net_id:
		fapi.abandon_awaiting_func_completion(f_key)
	var func_result = _udp_socket.fapi.get_info_for_completed_func(func_key)
	fapi.set_info_for_completed_func(f_key, func_result)
	emit_signal('host_infos_request_completed', func_result)



#note that the handshake addres here could be different
#to the set network details
#the function result will contain info or null if the 
#request failed.
func get_misc_from_handshake(handshake_address, extra_info={}):
	var key = fapi.get_add_key()
	_get_misc_from_handshake(key, handshake_address, extra_info)
	return key

func _get_misc_from_handshake(f_key, handshake_address, extra_info):
	var last_known_net_id = _net_id
	if not _udp_socket.is_inited():
		_udp_socket.init(get_network_detail(DETAILS_KEY_LOCAL_PORT),
			get_network_detail(DETAILS_KEY_UDP_TIMEOUT_SECS),
			{'_idx': _idx}, _UDP_SOCKET_MINIMISATION_KEYS
		)
	_udp_socket.start_listening()
	
	var func_key = _udp_socket.send_data_wait_for_reply( 
		{'misc-request':extra_info}, handshake_address
	)
	while _udp_socket.fapi.is_func_ongoing(func_key):
		yield(_udp_socket, 'send_data_await_reply_completed')
	_udp_socket.stop_listening()
	if last_known_net_id != _net_id:
		fapi.abandon_awaiting_func_completion(f_key)
	var func_result = _udp_socket.fapi.get_info_for_completed_func(func_key)
	fapi.set_info_for_completed_func(f_key, func_result)
	emit_signal('misc_request_completed', func_result)




################################
#    Process Packets and Messages
################################


#only packets that are not replies come through here
func _udp_packet_received(data, sender_address, packet_id):
	if not data.has('_idx'):
		#this handles handshake server, basically
		var conn = _get_connection_for_packet(data, sender_address)
		if conn != null:
			_packet_from_connected(data, packet_id, sender_address, conn)
		else:
			pass#probably handshake telling us to drop it
		return
	
	
	if data.has('players-inited'):
		var client_idx = data['_idx']
		var client_unique_id = client_idx.split("|")[0]
		var client_net_id = client_idx.split("|")[1]
		if _initing_client_unique_id_to_info.has(client_unique_id):
			var info = _initing_client_unique_id_to_info[client_unique_id]
			if info['net-id'] == client_net_id:
				_initing_client_unique_id_to_info.erase(client_unique_id)
				var extra_info = info['extra-info']
				var client_name = info['client-name']
			
				var client_connection = _add_connection_to_client(
					client_name, sender_address, client_idx
				)
				emit_signal('client_joined', client_name, sender_address, extra_info)
				emit_signal('player_joined', client_name)
				
				var join_data = {
					'add-player': client_name,
					'add-player-idx': client_idx
				}
				for player_name in _player_names_no_handshake:
					if player_name == client_name:
						pass
					else:
						var fk = _send_to_connected_faulty_if_no_reply(join_data, player_name)
						fapi.abandon_awaiting_func_completion(fk)
				
				_packet_from_connected(data, packet_id, sender_address, client_connection)
				return
			
	#two sent from potential client to host's addresses
	if data.has('used-local'):
		var last_known_net_id = _net_id
		var client_name = data['client-name']
		var client_idx = data['_idx']
		var client_unique_id = client_idx.split("|")[0]
		var client_net_id = client_idx.split("|")[1]
		var extra_info = data['extra-info']
		var client_exists = false
		for connection in _player_name_to_connection.values():
			if connection['unique-id'] == client_unique_id:
				if client_net_id == connection['net-id']:
					client_exists = true
				elif client_net_id > connection['net-id']:
					_restore_connection(connection)
					connection['valid-send-func-keys'].clear()
					connection['player-name'] = client_name
					connection['idx'] = client_idx
					connection['net-id'] = client_net_id
					client_exists = true
					if _initing_client_unique_id_to_info.has(client_unique_id):
						_initing_client_unique_id_to_info[client_unique_id]['net-id'] = client_net_id
		
		if not client_exists:
			if not _is_accepting_new_clients:
				_udp_socket.send_data(
					{'error': 'Host is not accepting new clients.'},
					sender_address, packet_id
				)
				return
			if (_player_name_to_connection.has(client_name)
			or client_name == _my_player_name):
				_udp_socket.send_data(
					{'error': 'Name already exists in host.'},
					sender_address, packet_id
				)
				return
			
			var reject_reason = _get_client_reject_reason(extra_info)
			if reject_reason != null: 
				_udp_socket.send_data(
					{'error': reject_reason},
					sender_address, packet_id
				)
				return
				
			_initing_client_unique_id_to_info[client_unique_id] = {
				'net-id': client_net_id,
				'client-name': client_name,
				'extra-info': extra_info
			}
			
		var players = {}
		for player in _player_names_no_handshake:
			players[player] = _player_name_to_connection[player]['idx']
		players[client_name] = client_idx
		_udp_socket.send_data( 
			{'init-players': players}, sender_address, packet_id
		)
		
		
		
					
	
	elif (_attempting_to_join_host and _host_address != null
	and test_addresses_equal(sender_address,_host_address)):
			#we'll send a reply (if we do) when it
			#actually gets processed
			_packets_to_process_once_joined_to_host.push_back({
				'data': data, 'sender-address': sender_address,
				'packet-id': packet_id
			})
	else:
		var conn = _get_connection_for_packet(data, sender_address)
		if conn != null:
			_packet_from_connected(data, packet_id, sender_address, conn)
			return


#checks address and idx for non-handshakes, which is added
#to every packet (set when udp socket is inited)
func _get_connection_for_packet(data, sender_address):
	for connection in _player_name_to_connection.values():
		if connection['player-address'] == null:
			continue
		if test_addresses_equal(connection['player-address'], sender_address):
			if connection['is-handshake']:
				return connection
			elif data['_idx'] == connection['idx']:
				return connection
			else:
				return null



func _packet_from_connected(data, packet_id, sender_address, connection):
	#connection is null is this is a message internally routed to self
	if connection != null and connection.has('no-contact-timer'):
		connection['no-contact-timer'] = get_network_detail(DETAILS_KEY_MAX_SECS_WITHOUT_CONTACT_FROM_HOST_BEFORE_FAULTY)
		if connection['faulty-for-lack-of-contact']:
			if connection['faulty-for-no-reply-to-f-keys'].empty():
				_restore_connection(connection)
	
	if not _player_is_host:
		pass
	
	var last_known_net_id = _net_id
	#from handshake to host with client details
	if data.has('join-requested'): 
		if not _is_accepting_new_clients:
			_udp_socket.send_data(
				{'drop-me': _my_player_name},
				sender_address, packet_id
			)
			return
		var client_name = data['join-requested']
		var local_port =  data['local-port']
		for local_ip in data['local-ips']:
			_udp_socket.send_data({}, [local_ip, local_port])
		_udp_socket.send_data({}, data['global-address'])
		#let handshake know it can send to client
		_udp_socket.send_data({}, sender_address, packet_id)

	#received by clients
	elif data.has('add-player'):
		_udp_socket.send_data({}, sender_address, packet_id)
		var player_name = data['add-player']
		var player_idx = data['add-player-idx']
		var player_id = player_idx.split('|')[0]
		var player_net_id =  player_idx.split('|')[1]
		
		var process_later = false
		if _player_name_to_connection.has(player_name):
			var conn = _player_name_to_connection[player_name]
			#we got a drop for a player who has yet to be readded for us
			if conn['unique-id'] == player_id:
				if conn['net-id'] < player_net_id:
					process_later = true
				elif conn['net-id'] > player_net_id:
					return #this was referring to an older player version
				#else proceed as usual- this is our guy
			else:
				process_later = true
		
		if process_later:
			var process_later_data = {
				'data': data, 'packet-id': packet_id, 'sender-address': sender_address
			}
			if not _packets_to_process_once_name_dropped.has(player_name):
				_packets_to_process_once_name_dropped[player_name] = []
			_packets_to_process_once_name_dropped[player_name].push_back(process_later_data)
			return
		
		_add_psuedo_connection(player_name, player_idx)
		emit_signal('player_joined', player_name)
		if _packets_to_process_once_name_joined.has(player_name):
			var packet_infos = _packets_to_process_once_name_joined[player_name]
			_packets_to_process_once_name_joined.erase(player_name)
			for packet_info in packet_infos:
				_udp_packet_received(packet_info['data'], packet_info['sender-address'], packet_info['packet-id'])
	
	
	elif data.has('drop-handshake'):
		if connection['is-handshake']:
			drop_handshake()
	
	#received by clients and host for client terminating
	elif data.has('drop-player'):
		
		_udp_socket.send_data({}, sender_address, packet_id)
		var player_name = data['drop-player']
		var player_idx = data['drop-player-idx']
		var player_id = player_idx.split('|')[0]
		var player_net_id = player_idx.split('|')[1]
		
		var process_later = false
		if not _player_name_to_connection.has(player_name):
			process_later = true
		else:
			var conn = _player_name_to_connection[player_name]
			#we got a drop for a player who has yet to be readded for us
			if conn['unique-id'] == player_id:
				if conn['net-id'] < player_net_id:
					process_later = true
				elif conn['net-id'] > player_net_id:
					return #this was referring to an older player version
				#else proceed as usual- this is our guy
			else:
				process_later = true
		if process_later:
			var process_later_data = {
				'data': data, 'packet-id': packet_id, 'sender-address': sender_address
			}
			if not _packets_to_process_once_name_joined.has(player_name):
				_packets_to_process_once_name_joined[player_name] = []
			_packets_to_process_once_name_joined[player_name].push_back(process_later_data)
			return
		
		var drop_player_connection = _player_name_to_connection[player_name]
		_drop_connection(drop_player_connection)
		if _packets_to_process_once_name_dropped.has(player_name):
			var packet_infos = _packets_to_process_once_name_dropped[player_name]
			_packets_to_process_once_name_dropped.erase(player_name)
			for packet_info in packet_infos:
				_udp_packet_received(packet_info['data'], packet_info['sender-address'], packet_info['packet-id'])

	
	#received by clients
	elif data.has('ping'):
		_udp_socket.send_data({}, sender_address, packet_id)
		

	
	
	elif data.has('ping-request'):
		if connection['ping-send-timer'] != null:#null=pinging
			connection['ping-send-timer'] = 0
	
	#received by host
	elif data.has('forward-message'):
		#null when host routes a send through here ;)
		if sender_address != null:
			_udp_socket.send_data({}, sender_address, packet_id)
		data['message'] = data['forward-message']
		data.erase('forward-message')
		var players_to_send_to = data['to'].duplicate()
		var me_included = players_to_send_to.has(_my_player_name)
		if me_included:
			players_to_send_to.erase(_my_player_name)
		
		var func_keys = []
		for player_name in players_to_send_to:
			if not _player_names_no_handshake.has(player_name):
				continue
			var func_key = _send_to_connected_faulty_if_no_reply(data, player_name)
			func_keys.push_back(func_key)
		if me_included:
			_packet_from_connected(data, null, null, null)
		var completed_keys = []
		while completed_keys.size() != func_keys.size():
			for key in func_keys:
				if not fapi.is_func_ongoing(key):
					completed_keys.push_back(key)
					fapi.abandon_awaiting_func_completion(key)
			if completed_keys.size() != func_keys.size():
				yield(self, '_send_to_connected_faulty_if_no_reply_completed')
				if last_known_net_id != _net_id:
					return
		var d = {
			'message-received-by-all': data['#']
		}
		if data['from'] == _my_player_name:
			_sent_message_ids_not_received_by_all.erase(data['#'])
			emit_signal('_sent_message_received_by_all')
		else:
			var func_key = _send_to_connected_faulty_if_no_reply(d, data['from'])
			fapi.abandon_awaiting_func_completion(func_key)
	
	
	elif data.has('message'):
		
		#null when host routes a send through here ;)
		if sender_address != null:
			_udp_socket.send_data({}, sender_address, packet_id)
		var from = data['from']
		#we receive a (forwarded) message from a player who has
		#received init-players, but we haven't received add-player
		#for them yet
		if not _player_is_host:
			if not _player_name_to_connection.has(from):
				var process_later_data = {
					'data': data, 'packet-id': packet_id, 'sender-address': sender_address
				}
				if not _packets_to_process_once_name_joined.has(from):
					_packets_to_process_once_name_joined[from] = []
				_packets_to_process_once_name_joined[from].push_back(process_later_data)
				return
			
		var to = data['to']
		var message = data['message']
		emit_signal('message_received', from, to, message)
	
	elif data.has('message-received-by-all'):
		_udp_socket.send_data({}, sender_address, packet_id)
		_sent_message_ids_not_received_by_all.erase(data['message-received-by-all'])
		emit_signal('_sent_message_received_by_all')
		

#func key returned will be over when all players got message
#yield for "sent_message_received_by_all"
func send_message_to_host(message):
	var specific_player_names = [_host_player_name]
	return send_message(message, specific_player_names)

#func key returned will be over when all players got message
#yield for "sent_message_received_by_all"
func send_message_to_all_but_self(message):
	var specific_player_names =  _player_names_no_handshake.duplicate()
	specific_player_names.erase(_my_player_name)
	return send_message(message, specific_player_names)

#func key returned will be over when all players got message
#yield for "sent_message_received_by_all"
func send_message(message, specific_player_names=null):
	if not _is_networking:
		return
	var func_key = fapi.get_add_key()
	_send_message(func_key, message, specific_player_names)
	return func_key
	
func _send_message(f_key, message, specific_player_names=null):
	var last_known_net_id = _net_id
	if specific_player_names == null:
		specific_player_names = _player_names_no_handshake.duplicate()
		if _player_is_host:
			specific_player_names.push_back(_my_player_name)
	else:
		var temp = []
		for player_name in _player_names_no_handshake:
			if specific_player_names.has(player_name):
				temp.push_back(player_name)
		if specific_player_names.has(_my_player_name):
			if _player_is_host:
				temp.push_back(_my_player_name)
		specific_player_names = temp
	
	var self_included = specific_player_names.has(_my_player_name)
	if self_included and specific_player_names.size() == 1:
		emit_signal('message_received', _my_player_name, [_my_player_name], message)
		fapi.abandon_awaiting_func_completion(f_key)
		emit_signal('sent_message_received_by_all')
		return
	
	_sent_message_id_keeper += 1
	var message_id = _sent_message_id_keeper 
	
	_sent_message_ids_not_received_by_all.push_back(message_id)
	var data = {
		'forward-message': message, 
		'to': specific_player_names,
		'from': _my_player_name,
		'#': message_id
	}
	
	if _player_is_host:
		_packet_from_connected(data, null, null, null)
	else:
		var func_key = _send_to_connected_faulty_if_no_reply(data, _host_player_name)
		fapi.abandon_awaiting_func_completion(func_key)
	
	while _sent_message_ids_not_received_by_all.has(message_id):
		yield(self, '_sent_message_received_by_all')
		if last_known_net_id != _net_id:
			return
	
	fapi.abandon_awaiting_func_completion(f_key)
	emit_signal('sent_message_received_by_all')



func decision_to_keep_trying_faulties_made(decision):
	if decision == null:
		_give_up_on_faulty_connections = null
	else:
		_give_up_on_faulty_connections = not decision
	if _give_up_on_faulty_connections == false:#FALSE, not null
		for connection in _faulty_connections:
			connection['emitted-faulty'] = false
			if not connection['send-pings']:
				connection['no-contact-timer'] = get_network_detail(DETAILS_KEY_UDP_TIMEOUT_SECS)
				_udp_socket.send_data(
					{'ping-request': null},
					connection['player-address']
				)
		_give_up_on_faulty_connections = null
	elif _give_up_on_faulty_connections == true:#TRUE, not null
		for connection in _faulty_connections:
			_drop_connection(connection)
		_give_up_on_faulty_connections = null
	else:
		pass

func get_names_of_faulty_connections():
	var ret = []
	for connection in _faulty_connections:
		ret.push_back(connection['player-name'])
	return ret

func _send_to_connected_faulty_if_no_reply(data, player_name, reply_to_id=null):
	var func_key = fapi.get_add_key()
	__send_to_connected_faulty_if_no_reply(func_key, data, player_name, reply_to_id)
	return func_key

func __send_to_connected_faulty_if_no_reply(f_key, data, player_name, reply_to_id):
	var last_known_net_id = _net_id
	var result = {
		'reply-data': null,
		'reply-id': null,
		'sent-id': null
	}
	
	var connection = _player_name_to_connection[player_name]
	
	var player_address = connection['player-address']
	var func_key = _udp_socket.send_data_wait_for_reply( 
		data, player_address, reply_to_id
	)
	connection['valid-send-func-keys'].push_back(f_key)
	#basically just resend until either we get a reply
	#or _give_up_on_faulty_connections is set true
	#or, of course, _net_id changes or the client is re-joined
	while true:
		while _udp_socket.fapi.is_func_ongoing(func_key):
			yield(_udp_socket, 'send_data_await_reply_completed')
		var func_result = _udp_socket.fapi.get_info_for_completed_func(func_key)
		if (last_known_net_id != _net_id 
		or connection['removed'] 
		or not connection['valid-send-func-keys'].has(f_key)):
			break
		
		if func_result['timed-out']:
			if not connection['faulty-for-no-reply-to-f-keys'].has(f_key):
				connection['faulty-for-no-reply-to-f-keys'].push_back(f_key)
			if not _faulty_connections.has(connection):
				_faulty_connections.push_back(connection)
			if not connection['emitted-faulty']:
				if connection['is-handshake']:
					if get_signal_connection_list('handshake_faulty').empty():
						_drop_connection(connection)
					else:
						emit_signal("handshake_faulty")
				else:
					if get_signal_connection_list('faulty_connection').empty():
						_drop_connection(connection)
					else:
						emit_signal(
							'faulty_connection',
							connection['player-name']
						)
				connection['emitted-faulty'] = true
			
			#this is null while user is deciding
			if _give_up_on_faulty_connections == true:
				break#connection will be dropped
			else:
				func_key = _udp_socket.send_data_wait_for_reply(
					data, player_address, reply_to_id
				)
		else:
			result['reply-data'] = func_result['reply-data']
			result['reply-id'] = func_result['reply-id']
			result['sent-id'] = func_result['sent-id']
			break
	
	if not connection['removed']:
		if connection['valid-send-func-keys'].has(f_key):
			if connection['faulty-for-no-reply-to-f-keys'].has(f_key):
				connection['faulty-for-no-reply-to-f-keys'].erase(f_key)
				if connection['faulty-for-no-reply-to-f-keys'].empty():
						_restore_connection(connection)
	
	var was_abandoned = fapi.set_info_for_completed_func(f_key, result)
	if not was_abandoned:
		emit_signal('_send_to_connected_faulty_if_no_reply_completed')




func _drop_connection(connection, no_signals=false, send_dropme=true, coming_from_reset=false):
	if (connection == null 
	or not _player_name_to_connection.values().has(connection)):
		return
	var net_id = _net_id
	
	var player_name = connection['player-name']
	_player_name_to_connection.erase(player_name)
	_player_names_no_handshake.erase(player_name)
	if _faulty_connections.has(connection):
		_faulty_connections.erase(connection)
	connection['removed'] = true
	
	if connection['is-handshake']:
		if send_dropme:
			_udp_socket.send_data(
				{'drop-me': _my_player_name}, connection['player-address']
			)
		if not no_signals:
			emit_signal('handshake_dropped')
		
	elif _player_is_host:
		if send_dropme:
			var dropme_data = _make_drop_data(_my_player_name, _idx)
			_udp_socket.send_data(dropme_data, connection['player-address'])
			var drophim_data = _make_drop_data(player_name, connection['idx'])
			for p_name in _player_names_no_handshake:
				var func_key = _send_to_connected_faulty_if_no_reply(drophim_data, p_name)
				fapi.abandon_awaiting_func_completion(func_key)
		
		if not no_signals:
			emit_signal('player_dropped', connection['player-name'])
			if net_id == _net_id:
				emit_signal('client_dropped', connection['player-name'])
			if net_id == _net_id:
				if _player_name_to_connection.empty():
					reset()
		
	else:
		if send_dropme:
			if player_name == _host_player_name:
				var dropme_data = _make_drop_data(_my_player_name, _idx)
				_udp_socket.send_data(dropme_data, connection['player-address'])
		if not no_signals:
			if player_name == _host_player_name:
				emit_signal('player_dropped', _my_player_name)
				if net_id == _net_id:
					emit_signal('player_dropped', _host_player_name)
				if net_id == _net_id:
					emit_signal("host_dropped", _host_player_name)
				if net_id == _net_id:
					if not coming_from_reset:
						reset()
			else:
				emit_signal('player_dropped', connection['player-name'])




func _make_drop_data(player_name, player_idx):
	return {'drop-player': player_name, 'drop-player-idx': player_idx}





























############################
#     Pings and _process
############################
func _process(delta):
	for player_name in _player_name_to_connection:
		var connection = _player_name_to_connection[player_name]
		if connection.has('send-pings') and connection['send-pings']:
			if connection['ping-send-timer'] == null:#null when resending
				continue
			connection['ping-send-timer'] -= delta
			if connection['ping-send-timer'] < 0:
				#resend-timer is reset if ping received
				_send_ping(connection)

		elif connection.has('no-contact-timer'):
			if connection['no-contact-timer'] != null:
				connection['no-contact-timer'] -= delta
				if connection['no-contact-timer'] >= 0:
					continue
				connection['no-contact-timer'] = null
				connection['faulty-for-lack-of-contact'] = true
				if not _faulty_connections.has(connection):
					_faulty_connections.push_back(connection)
				if not connection['emitted-faulty']:
					if connection['is-handshake']:
						if get_signal_connection_list('handshake_faulty').empty():
							_drop_connection(connection)
						else:
							emit_signal('handshake_faulty')
					else:
						if get_signal_connection_list('faulty_connection').empty():
							_drop_connection(connection)
						else:
							emit_signal(
								'faulty_connection',
								connection['player-name']
							)
					connection['emitted-faulty'] = true


#there should only ever be one- that's to the host
func _add_connection_to_host(player_name, player_address, player_idx):
	var connection = __add_base_connection(player_name, player_address, player_idx)
	connection['send-pings'] = false
	connection['no-contact-timer'] = get_network_detail(DETAILS_KEY_MAX_SECS_WITHOUT_CONTACT_FROM_HOST_BEFORE_FAULTY)
	connection['faulty-for-lack-of-contact'] = false


func _add_psuedo_connection(player_name, player_idx):
	__add_base_connection(player_name, null, player_idx)


func __add_base_connection(player_name, player_address, player_idx, is_handshake=false):
	var connection = {
		'player-name': player_name,
		'player-address': player_address,
		'is-handshake': is_handshake,
		#unique id defines a user- it stays constant per user
		#net id defines a session, which increments each time the user
		#calls join_host, register_host or auto_join
		#idx, then, uniquely specifies a user's session
		'unique-id': player_idx.split('|')[0] if player_idx != null else null, 
		'net-id': player_idx.split('|')[1] if player_idx != null else null,
		'idx': player_idx,
		'valid-send-func-keys': [],
		'removed': false,
		#there's two ways a faulty can happen:
		#	a timed out send_to_connected_faulty...
		#	(on non-hosts) too long with no contact
		'faulty-for-no-reply-to-f-keys': [],
		'emitted-faulty': false,
	}
	_player_name_to_connection[player_name] = connection
	if not is_handshake:
		_player_names_no_handshake.push_back(player_name)
	return connection


func _add_connection_to_handshake(handshake_address):
	var connection = __add_base_connection(HANDSHAKE_SERVER_PLAYER_NAME, handshake_address, null, true)
	connection['send-pings'] = true
	connection['ping-send-timer'] = get_network_detail(DETAILS_KEY_PING_INTERVAL_SECS)

func _add_connection_to_client(player_name, player_address, player_idx):
	var connection = __add_base_connection(player_name, player_address, player_idx)
	connection['send-pings'] = true
	connection['ping-send-timer'] = get_network_detail(DETAILS_KEY_PING_INTERVAL_SECS)


func _send_ping(connection):
	var last_known_net_id = _net_id
	connection['ping-send-timer'] = null
	var start_time_ms = OS.get_ticks_msec()
	var ping_data
	if connection['is-handshake']:
		ping_data = {'ping': _my_player_name}
	else:
		ping_data = {'ping': null}
	#print('sendng ping to %s' % connection['player-name'])
	var func_key = _send_to_connected_faulty_if_no_reply(
		ping_data,
		connection['player-name']
	)
	while fapi.is_func_ongoing(func_key):
		yield(self, '_send_to_connected_faulty_if_no_reply_completed')
	var func_result = fapi.get_info_for_completed_func(func_key)
	if (last_known_net_id != _net_id 
	or connection['removed'] 
	or not connection['valid-send-func-keys'].has(func_key)):
		return
	if func_result['reply-data'].has('error'):
		_drop_connection(connection)
	else:
		#print('received ping reply from %s' % connection['player-name'])
		var time_taken = (OS.get_ticks_msec() - start_time_ms)/1000
		connection['ping-send-timer'] = get_network_detail(DETAILS_KEY_PING_INTERVAL_SECS)-time_taken


func _restore_connection(connection):
	if _faulty_connections.has(connection):
		connection['faulty-for-no-reply-to-f-keys'].clear()
	#if connection['emitted-faulty']:
		connection['emitted-faulty'] = false
		_faulty_connections.erase(connection)
		if not connection['send-pings']:
			connection['no-contact-timer'] = get_network_detail(DETAILS_KEY_MAX_SECS_WITHOUT_CONTACT_FROM_HOST_BEFORE_FAULTY)
			connection['faulty-for-lack-of-contact'] = false
		var player_name = connection['player-name']
		if connection['is-handshake']:
			emit_signal("handshake_connection_restored")
		else:
			emit_signal("connection_restored", player_name)
		_give_up_on_faulty_connections = false
		#emit_signal("_answer_ready_for_faulty_connection")




const _UDP_SOCKET_MINIMISATION_KEYS = {
	'local-address': '__a',
	'global-address': '__b',
	'extra-info': '__c',
	'ping': '__d',
	'ping-reply': '__e',
	'client-id': '__f',
	'client-name': '__g',
	'host-id': '__h',
	'host-name': '__i',
	'player-id': '__j',
	'used-local': '__k',
	'used-global': '__l',
	'join-request': '__m',
	'host-registration': '__n',
	'join-requested': '__o',
	'error': '__p',
	'drop-me': '__q',
	'drop-player': '__r',
	'join-players': '__s',
	'message': '__t',
	'specific-players': '__u',
}





class KeyGenerator extends Reference:
	const MAX = 1000000000000
	var _unique_key_tracker = int(int(abs(rand_seed(OS.get_unix_time())[1])) % MAX)
	func generate_key():
		var key = _unique_key_tracker
		_unique_key_tracker += 1
		if _unique_key_tracker % 25 == 0 and randf() < 0.5:
			_unique_key_tracker += randi() % 500
		if _unique_key_tracker > MAX:
			_unique_key_tracker = 0
		return '%X' % key
