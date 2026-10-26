##
## A ~90-line test base, because adding GUT would be adding a dependency.
##
## CLAUDE.md §2 requires approval for a new dependency, and the alternative
## here is small: assertions that collect failures rather than aborting, so one
## broken expectation does not hide the nine after it. That matters more than
## usual in this package — the lesson these tests exist to encode is that a
## suite which stops before reporting is worse than a red one.
##
class_name ChatlyTestCase
extends RefCounted

var failures: Array[String] = []
var assertions: int = 0
var _current: String = ""


## Every `test_*` method on the subclass, in declaration order.
func discover_tests() -> Array[String]:
	var names: Array[String] = []
	for m: Dictionary in get_method_list():
		var n: String = m["name"]
		if n.begins_with("test_") and not names.has(n):
			names.append(n)
	return names


func begin(test_name: String) -> void:
	_current = test_name


func _fail(detail: String) -> void:
	failures.append("%s: %s" % [_current, detail])


func check(condition: bool, detail: String) -> bool:
	assertions += 1
	if not condition:
		_fail(detail)
	return condition


func equal(actual: Variant, expected: Variant, detail: String) -> bool:
	assertions += 1
	if actual != expected:
		_fail("%s — expected %s, got %s" % [detail, _show(expected), _show(actual)])
		return false
	return true


func not_equal(actual: Variant, forbidden: Variant, detail: String) -> bool:
	assertions += 1
	if actual == forbidden:
		_fail("%s — must not be %s" % [detail, _show(forbidden)])
		return false
	return true


## Asserts a key is ABSENT. Used far more than it looks like it should be:
## zod drops an unknown key silently, so a body carrying `mimeType` where the
## schema wants `contentType` is not a type error anywhere — it is a 400 at
## runtime and a green suite everywhere else.
func absent(container: Dictionary, key: String, detail: String) -> bool:
	assertions += 1
	if container.has(key):
		_fail("%s — key %s should be absent, found %s" % [detail, key, _show(container[key])])
		return false
	return true


func present(container: Dictionary, key: String, detail: String) -> bool:
	assertions += 1
	if not container.has(key):
		_fail("%s — key %s is missing from %s" % [detail, key, _show(container.keys())])
		return false
	return true


static func _show(v: Variant) -> String:
	match typeof(v):
		TYPE_DICTIONARY, TYPE_ARRAY:
			return JSON.stringify(v)
		TYPE_STRING:
			return '"%s"' % v
		_:
			return str(v)
