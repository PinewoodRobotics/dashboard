extends TestCase

## Every test here must be reported as failed; run_unit.sh asserts that.


func test_script_error_before_await() -> void:
	var missing: Object = null
	missing.get_name()
	check(true)


func test_script_error_after_await() -> void:
	await next_frame()
	var missing: Object = null
	missing.get_name()
	check(true)


func test_push_error() -> void:
	push_error("deliberate engine error")
