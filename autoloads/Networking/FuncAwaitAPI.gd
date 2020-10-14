extends Reference

var _key_generator = IntKeyGeneratorClass.new()
var _ongoing_func_keys = []
var _ongoing_keys_to_abandon = []
var _completed_func_keys_to_info = {}
func get_add_key():
	var key = _key_generator.generate_key()
	_ongoing_func_keys.push_back(key)
	return key
func remove_key(key):
	_ongoing_func_keys.erase(key)
func is_func_ongoing(func_key):
	return _ongoing_func_keys.has(func_key)
func get_info_for_completed_func(func_key):
	if _completed_func_keys_to_info.has(func_key):
		var info = _completed_func_keys_to_info[func_key]
		_completed_func_keys_to_info.erase(func_key)
		return info
func abandon_awaiting_func_completion(func_key):
	if _ongoing_func_keys.has(func_key):
		_ongoing_keys_to_abandon.push_back(func_key)
	elif _completed_func_keys_to_info.has(func_key):
		_completed_func_keys_to_info.erase(func_key)
func set_info_for_completed_func(func_key, info):
	_ongoing_func_keys.erase(func_key)
	if _ongoing_keys_to_abandon.has(func_key):
		_ongoing_keys_to_abandon.erase(func_key)
		return true
	else:
		_completed_func_keys_to_info[func_key] = info
		return false
		

class IntKeyGeneratorClass extends Reference:
	var _unique_key_tracker = int(abs(rand_seed(OS.get_unix_time())[1])) % 10000
	
	func generate_key():
		var key = _unique_key_tracker
		_unique_key_tracker += 1
		#overflow
		if _unique_key_tracker < 0:
			_unique_key_tracker = 0
		return key
