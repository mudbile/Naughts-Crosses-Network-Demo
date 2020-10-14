extends Node

const CUSTOM_UDP_WRAPPER_SCRIPT = preload("./UDPSocketWrapper.gd")

const MAX_NUM_HOST_INFOS_TO_GIVE = 10
#func_name should take two arguments: the first
#is the extra_info sent and updated by the host. 
#The second is the info passed by the client 
# in Network.get_host_infos_from_handshake or 
# Network.auto_connect for example
#Should return an integer ranking for the matching. 
#Return 0 for incompatible infos.
#This is called to check the rank of host and potential
#client when a potential client is autoconnecting
#or to get most fitting host infos when client requets them
var _node_and_func_for_host_rank = [weakref(null), null]
func set_node_and_func_for_host_rank(node, func_name):
	_node_and_func_for_host_rank[0] = weakref(node)
	_node_and_func_for_host_rank[1] = func_name
func _get_host_rank(host_info, client_info):
	var func_info = _node_and_func_for_host_rank
	if func_info[0].get_ref() == null:
		return 1 #0 rank means incompatible
	return func_info[0].get_ref().callv(func_info[1], [host_info, client_info])
#func_name should take one argument: the
#extra_info sent by the requestee. 
var _node_and_func_for_misc_request = [weakref(null), null]
func set_node_and_func_for_misc_request(node, func_name):
	_node_and_func_for_misc_request[0] = weakref(node)
	_node_and_func_for_misc_request[1] = func_name
func _get_misc_data(extra_info):
	var func_info = _node_and_func_for_misc_request
	if func_info[0].get_ref() == null:
		return {}
	return func_info[0].get_ref().callv(func_info[1], [extra_info])




var _host_name_to_registration = {}
var _host_unique_id_to_registration = {}
var _udp_socket
var _is_running = false


func is_running():
	return _is_running


func init():
	var port = Network.get_network_detail(Network.DETAILS_KEY_HANDSHAKE_PORT)
	if _udp_socket == null:
		_udp_socket = CUSTOM_UDP_WRAPPER_SCRIPT.new()
		add_child(_udp_socket)
		_udp_socket.init(
			Network.get_network_detail(Network.DETAILS_KEY_UDP_TIMEOUT_SECS),
			null,
			Network._UDP_SOCKET_MINIMISATION_KEYS
		)
		
		_udp_socket.connect('packet_received', self, '_udp_packet_received')
		_udp_socket.connect('any_packet_received', self, '_udp_any_packet_received')
	if _udp_socket.start_listening(port) != OK:
		print("Error initting handshake at port %s" % port)
		reset()
		return
	_is_running = true
	print('Running as handshake server at port %s' % port)
	

#does not reset _node_and_func_for_host_rank etc.
func reset():
	_host_name_to_registration.clear()
	_host_unique_id_to_registration.clear()
	if _udp_socket != null:
		_udp_socket.stop_listening()
	_is_running = false




func _udp_any_packet_received(data, sender_address, packet_id):
	if (data == null 
	or not data.has('_idx')
	or not typeof(data['_idx']) == TYPE_STRING):
		return
	var sender_id = data['_idx'].split('|')[0]
	if _host_unique_id_to_registration.has(sender_id):
		_host_unique_id_to_registration[sender_id]['timeout'] = Network.get_network_detail(Network.DETAILS_KEY_MAX_SECS_WITHOUT_CONTACT_FROM_HOST_BEFORE_FAULTY)
func _udp_packet_received(data, sender_address, packet_id):
	if (data == null 
	or not data.has('_idx')
	or not typeof(data['_idx']) == TYPE_STRING):
		return
	var sender_id = data['_idx'].split('|')[0]
	
	#host registration
	#ignore ill-formatted data- they'll send it again
	if data.has('host-registration') and _verify_host_registration_data_format(data):
		_attempt_register_host(data['host-registration'], sender_id, sender_address, packet_id)
	
	elif data.has('join-request') and _verify_client_join_request_data_format(data):
		_attempt_send_handshake_packets(data['join-request'], sender_address, packet_id)
	
	elif data.has('auto-connect-request') and _verify_auto_connect_data_format(data):
		_attempt_auto_connect(data['auto-connect-request'], sender_address, sender_id, packet_id)
			
	elif data.has('update-info') and _verify_host_update_data_format(data):
		_attempt_update_host_info(data['update-info'], sender_address, sender_id, packet_id)
	
	elif data.has('info-request') and typeof(data['info-request']) == TYPE_DICTIONARY:
		var registrations = _host_name_to_registration.values().duplicate()
		var reg_to_rank = _rank_quick_sort(registrations, data['info-request'])
		var host_infos = {}
		for registration in registrations:
			if reg_to_rank[registration] == 0:
				break
			host_infos[registration['host-name']] = registration['extra-info']
			if host_infos.size() == MAX_NUM_HOST_INFOS_TO_GIVE:
				break
		_udp_socket.send_data(host_infos, sender_address, packet_id)
	
	elif data.has('misc-request') and typeof(data['misc-request']) == TYPE_DICTIONARY:
		var reply_data = _get_misc_data(data['misc-request'])
		_udp_socket.send_data(reply_data, sender_address, packet_id)
	
	
	
	elif data.has('ping'):
		var host_name = data['ping']
		if (_host_name_to_registration.has(host_name)
		and _host_name_to_registration[host_name]['unique-id'] == sender_id):
			_udp_socket.send_data({}, sender_address, packet_id)
		else:
			var msg = 'Host does not exist or is not you.'
			_udp_socket.send_data({'error':msg}, sender_address, packet_id)
	
	elif data.has('drop-me') and typeof(data['drop-me']) == TYPE_STRING:
		var host_name = data['drop-me']
		_attempt_drop_host(host_name, sender_address, sender_id)
	











func _make_host_registration_data(host_name, local_ips, local_port, extra_info):
	var data =  {'host-registration': [host_name,  local_ips, local_port, extra_info]}
	return data
func _verify_host_registration_data_format(data):
	var valid = (
		data.has('host-registration') and typeof(data['host-registration']) == TYPE_ARRAY
		and data['host-registration'].size() == 4
		and typeof(data['host-registration'][0]) == TYPE_STRING
		and typeof(data['host-registration'][1]) == TYPE_ARRAY
		and typeof(data['host-registration'][3]) == TYPE_DICTIONARY
	)
	if valid:
		for ip in data['host-registration'][1]:
			if not Network.test_ip_valid_data_format(ip):
				valid = false
				break
	if valid:
		if not Network.test_port_valid_data_format(data['host-registration'][2]):
			valid = false
	return valid
	
	
func _attempt_register_host(details, host_id, global_address, packet_id):
	var host_name = details[0]
	var local_ips = details[1]
	var local_port = details[2]
	var extra_info = details[3]
	var err = OK
	
	var host_names_to_remove = []
	for existing_host_name in _host_name_to_registration:
		var existing_entry = _host_name_to_registration[existing_host_name]
		var existing_global_address = existing_entry['global-address']
		if host_name == existing_host_name:
			if host_id == existing_entry['unique-id']:
				host_names_to_remove.push_back(existing_host_name)
			else:
				err = ERR_CANT_CREATE
				break
		if Network.test_addresses_equal(global_address, existing_global_address):
			if not host_names_to_remove.has(existing_host_name):
				host_names_to_remove.push_back(existing_host_name)
	
	if err == OK:
		for existing_host_name in host_names_to_remove:
			_host_unique_id_to_registration.erase(_host_name_to_registration[existing_host_name]['unique-id'])
			_host_name_to_registration.erase(existing_host_name)
			
		
		_host_name_to_registration[host_name] = {
			'unique-id': host_id,
			'host-name': host_name,
			'global-address': global_address,
			'local-ips': local_ips,
			'local-port': local_port,
			'extra-info': extra_info,
			'last-update-id': 0,
			'timeout': Network.get_network_detail(Network.DETAILS_KEY_MAX_SECS_WITHOUT_CONTACT_FROM_HOST_BEFORE_FAULTY)
		}
		_host_unique_id_to_registration[host_id] = _host_name_to_registration[host_name]
		print('registered host %s at %s' % [host_name, global_address])
		_udp_socket.send_data({'host-registered': host_name}, global_address, packet_id)
	else:
		var msg = 'Host name is already taken.'
		_udp_socket.send_data({'error':msg}, global_address, packet_id)











func _make_client_join_request_data(client_name, host_name, local_ips, local_port):
	return {'join-request': [client_name, host_name, local_ips, local_port]}

func _verify_client_join_request_data_format(data):
	var valid = (
		data.has('join-request') and typeof(data['host-registration']) == TYPE_ARRAY
		and data['join-request'].size() == 4
		and typeof(data['join-request'][0]) == TYPE_STRING
		and typeof(data['join-request'][1]) == TYPE_STRING
		and typeof(data['join-request'][2]) == TYPE_ARRAY
	)
	if valid:
		for ip in data['join-request'][2]:
			if not Network.test_ip_valid_data_format(ip):
				valid = false
				break
	if valid:
		if not Network.test_port_valid_data_format(data['join-request'][3]):
			valid = false
	return valid

func _attempt_send_handshake_packets(details, client_global_address, client_packet_id):
	var client_name = details[0]
	var host_name = details[1]
	var client_local_ips = details[2]
	var client_local_port = details[3]
	
	if not _host_name_to_registration.has(host_name):
		var msg = 'Host unavailable.'
		_udp_socket.send_data({'error':msg}, client_global_address, client_packet_id)
		return
	
	var host_details = _host_name_to_registration[host_name]
	var host_local_ips = host_details['local-ips']
	var host_local_port = host_details['local-port']
	var host_global_address = host_details['global-address']
	var host_extra_info = host_details['extra-info']
	
	var data_for_host = {
		'join-requested': client_name,
		'global-address': client_global_address,
		'local-ips': client_local_ips,
		'local-port': client_local_port,
	}
	#global-address is the one we received their registration on
	var func_key = _udp_socket.send_data_wait_for_reply(data_for_host, host_global_address)
	while _udp_socket.fapi.is_func_ongoing(func_key):
		yield(_udp_socket, 'send_data_await_reply_completed')
	var func_result = _udp_socket.fapi.get_info_for_completed_func(func_key)
	if func_result['timed-out']:
		var msg = 'Could not reach host.'
		_udp_socket.send_data({'error':msg}, client_global_address, client_packet_id)
	elif func_result['reply-data'].has('drop-me'):
		_attempt_drop_host(host_name, host_global_address, host_details['unique-id'])
		var msg = 'Host unavailable.'
		_udp_socket.send_data({'error':msg}, client_global_address, client_packet_id)
	else:
		var data_for_client = {
			'global-address': host_global_address,
			'local-ips': host_local_ips,
			'local-port': host_local_port,
			'extra-info': host_extra_info,
			'handshake-info-for-client': host_name
		}
		#global-address is the one we received their request on
		func_key = _udp_socket.send_data_wait_for_reply(data_for_client, client_global_address, client_packet_id)
		_udp_socket.abandon_send_data_wait_for_reply(func_key)





func _make_auto_connect_data(player_name, local_ips, local_port, extra_host_info, extra_client_info):
	return {'auto-connect-request': [player_name, local_ips, local_port, extra_host_info, extra_client_info]}

func _verify_auto_connect_data_format(data):
	var valid = (
		data.has('auto-connect-request') and typeof(data['auto-connect-request']) == TYPE_ARRAY
		and data['auto-connect-request'].size() == 5
		and typeof(data['auto-connect-request'][0]) == TYPE_STRING
		and typeof(data['auto-connect-request'][1]) == TYPE_ARRAY
		and typeof(data['auto-connect-request'][3]) == TYPE_DICTIONARY
		and typeof(data['auto-connect-request'][4]) == TYPE_DICTIONARY
	)
	if valid:
		for ip in data['auto-connect-request'][1]:
			if not Network.test_ip_valid_data_format(ip):
				valid = false
				break
	if valid:
		if not Network.test_port_valid_data_format(data['auto-connect-request'][2]):
			valid = false
	return valid

func _attempt_auto_connect(details, global_address, unique_id, packet_id):
	var player_name = details[0]
	var local_ips = details[1]
	var local_port = details[2]
	var extra_host_info = details[3]
	var extra_client_info = details[4]
	var registrations = _host_name_to_registration.values().duplicate()
	var reg_to_rank = _rank_quick_sort(registrations, extra_client_info)
	var best_registration = null
	for registration in registrations:
		if reg_to_rank[registration] == 0:
			break
		if registration['host-name'] != player_name:
			if not Network.test_addresses_equal(global_address, registration['global-address']):
				best_registration = registration
				break
	if best_registration != null:
		var handshake_details = _make_client_join_request_data(
			player_name, best_registration['host-name'], local_ips, local_port
		)['join-request']
		_attempt_send_handshake_packets(
			handshake_details, global_address, packet_id
		)
	else:
		var reg_details = _make_host_registration_data(
			player_name, local_ips, local_port, extra_host_info
		)['host-registration']
		_attempt_register_host(details, unique_id, global_address, packet_id)







func _rank_quick_sort(host_reg_array, client_info, entry_to_rank=null, low_i=null, high_i=null):
	if entry_to_rank == null:
		entry_to_rank = {}
		if host_reg_array.size() == 1:
			var r = _get_host_rank(host_reg_array[0]['extra-info'], client_info)
			entry_to_rank[host_reg_array[0]] = r
			return entry_to_rank

	if low_i == null:
		low_i = 0
	if high_i == null:
		high_i =  host_reg_array.size() - 1
	if low_i < high_i: 
		var pi = __custom_partition(host_reg_array, client_info, entry_to_rank, low_i, high_i) 
		_rank_quick_sort(host_reg_array, client_info, entry_to_rank, low_i, pi-1) 
		_rank_quick_sort(host_reg_array, client_info, entry_to_rank, pi+1, high_i) 
	return entry_to_rank
func __custom_partition(array, client_info, entry_to_rank, low_i, high_i): 
	var i = low_i - 1
	var pivot_val = _get_host_rank(array[high_i]['extra-info'], client_info)
	if not entry_to_rank.has(array[high_i]):
		entry_to_rank[array[high_i]] = pivot_val
	for j in range(low_i , high_i): 
		var r = _get_host_rank(array[j]['extra-info'], client_info)
		if not entry_to_rank.has(array[j]):
			entry_to_rank[array[j]] = r
		if r > pivot_val: 
			i = i + 1 
			var temp = array[i]; 
			array[i] = array[j]; 
			array[j] = temp; 
	var temp = array[i+1]; 
	array[i+1] = array[high_i]; 
	array[high_i] = temp; 
	return i + 1 










var __num_updates_sent_from_this_machine = 0
func _make_update_info_data(host_name, extra_info):
	var update_id = __num_updates_sent_from_this_machine
	__num_updates_sent_from_this_machine += 1
	var data =  {'update-info': [host_name, update_id, extra_info]}
	return data
func _verify_host_update_data_format(data):
	return (
		data.has('update-info') and typeof(data['update-info']) == TYPE_ARRAY
		and data['update-info'].size() == 3
		and typeof(data['update-info'][0]) == TYPE_STRING
		and typeof(data['update-info'][2]) == TYPE_DICTIONARY
	)
func _attempt_update_host_info(details, sender_address, sender_id, packet_id):
		var host_name = details[0]
		var update_id = details[1]
		var info = details[2]
		if _host_name_to_registration.has(host_name):
			var registration = _host_name_to_registration[host_name]
			if registration['unique-id'] == sender_id:
				if update_id > registration['last-update-id']:
					registration['last-update-id'] = update_id
					registration['extra-info'] = info
				_udp_socket.send_data({}, sender_address, packet_id)









func _attempt_drop_host(host_name, host_address, sender_id):
	var host_names_to_remove = []
	for existing_host_name in _host_name_to_registration:
		var existing_entry = _host_name_to_registration[existing_host_name]
		if host_name == existing_host_name:
			if sender_id == existing_entry['unique-id']:
				host_names_to_remove.push_back(existing_host_name)
		if Network.test_addresses_equal(host_address, existing_entry['global-address']):
			if not host_names_to_remove.has(existing_host_name):
				host_names_to_remove.push_back(existing_host_name)
	for existing_host_name in host_names_to_remove:
		print('dropping host %s' % host_name)
		_host_unique_id_to_registration.erase(_host_name_to_registration[existing_host_name]['unique-id'])
		_host_name_to_registration.erase(existing_host_name)
	var data = {
		'drop-handshake': Network.HANDSHAKE_SERVER_PLAYER_NAME, 
		'drop-player-id': sender_id
	}
	_udp_socket.send_data(data, host_address)














func _process(delta):
	var hosts_to_remove = []
	for host_name in _host_name_to_registration:
		var registration = _host_name_to_registration[host_name]
		registration['timeout'] -= delta
		if registration['timeout'] < 0:
			hosts_to_remove.push_back(host_name)
	for host_name in hosts_to_remove:
		var registration = _host_name_to_registration[host_name]
		_attempt_drop_host(host_name, registration['global-address'], registration['unique-id'])
	
