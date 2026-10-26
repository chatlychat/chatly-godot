##
## The suite.
##
##     godot --headless --path packages/sdk-godot --script tests/run_tests.gd
##
## Exits 0 on green, 1 on any failure. `--headless` is enough: nothing here
## renders, and the live protocol suite (`tests/live/run_live.gd`) is separate
## because it needs a Node server.
##
## ── Why this runner prints what it prints ─────────────────────────────
##
## It names every FILE and every TEST it ran, and the count of assertions. A
## green line whose number is the number of things the runner managed to find
## — rather than the number of things that exist — is a failure mode this
## repository has hit twice, so the output is explicit enough to notice when
## a file stops being discovered.
##
## It also fails on an EMPTY run. A runner that finds no tests and exits 0 is
## the single most expensive kind of broken gate: it is indistinguishable from
## a pass in every log.
##
extends SceneTree

const TestCase = preload("res://tests/lib/test_case.gd")

## Listed by hand rather than globbed, deliberately. A glob that silently
## stops matching (a renamed directory, an `include` pattern that cannot match
## `.tsx`, an exported project with no `tests/` folder) shrinks the audited set
## without failing — which is exactly how every mobile screen in this
## repository was structurally untestable for months while the suite was green.
## A missing file here is a hard error below.
const SUITES := [
	"res://tests/test_engineio.gd",
	"res://tests/test_request_shapes.gd",
	"res://tests/test_realtime_handshake.gd",
	"res://tests/test_client.gd",
]

## A floor, for the same reason `check-trigger-publishers.mjs` holds one: if
## the discovered test count drops below what the suite is known to contain,
## something stopped being found and the right outcome is red, not a smaller
## green number.
const MINIMUM_TESTS := 40

var _failures: Array[String] = []
var _total_tests: int = 0
var _total_assertions: int = 0
var _done: bool = false


func _initialize() -> void:
	_run()


## Frames have to keep ticking while `_run` is suspended: the handshake tests
## await `process_frame` to let a fire-and-forget coroutine finish, and nothing
## would resume them from `_initialize` alone.
func _process(_delta: float) -> bool:
	return _done


func _run() -> void:
	print("── chatly / godot ───────────────────────────────────────────")
	for path: String in SUITES:
		await _run_suite(path)

	print("")
	if _total_tests < MINIMUM_TESTS:
		_failures.append(
			"only %d tests were discovered, below the floor of %d — a suite stopped being found"
			% [_total_tests, MINIMUM_TESTS]
		)

	if _failures.is_empty():
		print("PASS  %d tests, %d assertions" % [_total_tests, _total_assertions])
		_finish(0)
	else:
		print("FAIL  %d of %d tests, %d assertions" % [_failures.size(), _total_tests, _total_assertions])
		for f: String in _failures:
			print("  ✗ ", f)
		_finish(1)


func _run_suite(path: String) -> void:
	if not ResourceLoader.exists(path):
		# Hard, not skipped. A suite that quietly vanishes is the failure this
		# runner is shaped to prevent.
		_failures.append("%s: the suite file does not exist" % path)
		print("  ✗ ", path, " — MISSING")
		return

	var script: GDScript = load(path)
	# A script that fails to PARSE still loads as an object; it just cannot be instantiated. Godot 4.7 tightened
	# type inference and one suite stopped compiling while the run printed PASS, so this is a hard failure.
	if script == null or not script.can_instantiate():
		_failures.append("%s: the suite does not compile" % path)
		print("  ✗ ", path, " — DOES NOT COMPILE")
		return
	var case: ChatlyTestCase = script.new()
	var names := case.discover_tests()
	if names.is_empty():
		_failures.append("%s: no test_* methods" % path)
		print("  ✗ ", path, " — no tests")
		return

	print("  ", path.get_file(), "  (", names.size(), " tests)")
	for test_name: String in names:
		# A fresh instance per test, so one test's state cannot reach the next.
		var instance: ChatlyTestCase = script.new()
		instance.begin(test_name)
		var before := instance.failures.size()
		await instance.call(test_name)
		_total_tests += 1
		_total_assertions += instance.assertions
		if instance.failures.size() > before:
			for f: String in instance.failures:
				_failures.append("%s / %s" % [path.get_file(), f])
			print("      ✗ ", test_name)
		else:
			print("      ✓ ", test_name)


func _finish(code: int) -> void:
	_done = true
	quit(code)
