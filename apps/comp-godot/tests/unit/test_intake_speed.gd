extends TestCase

const T := {"request": "/Shared/Intake/Speed/Request", "state": "/Shared/Intake/Speed/State"}

var link: FakeControlLink


func before_each() -> void:
	link = FakeControlLink.new()


func test_slider_publishes_rounded_and_persists() -> void:
	var c := IntakeSpeed.new(link, T)
	var seen: Array = []
	c.requested_changed.connect(func(v: Variant) -> void: seen.append(v))
	c.set_speed(0.4249)
	check_eq(link.last(T["request"]), 0.42, "rounded to 0.01")
	c.set_speed(1.7)
	check_eq(link.last(T["request"]), 1.0, "clamped to 1")
	c.set_speed(-0.2)
	check_eq(link.last(T["request"]), 0.0, "clamped to 0")
	check_eq(seen, [0.42, 1.0, 0.0])
	check_eq(link.count(T["request"]), 3, "every change publishes")


func test_stored_value_republished_on_every_connect() -> void:
	var c := IntakeSpeed.new(link, T, 0.37)
	c.update()
	check_eq(link.count(T["request"]), 0)
	link.up = true
	c.update()
	c.update()
	check_eq(link.count(T["request"]), 1)
	check_eq(link.last(T["request"]), 0.37)
	link.up = false
	c.update()
	link.up = true
	c.update()
	check_eq(link.count(T["request"]), 2, "re-published after a reconnect")


func test_no_override_publishes_nothing_on_connect() -> void:
	var c := IntakeSpeed.new(link, T)
	link.up = true
	c.update()
	check_eq(link.count(T["request"]), 0)


func test_reset_publishes_sentinel_and_clears() -> void:
	var c := IntakeSpeed.new(link, T, 0.6)
	var seen: Array = []
	c.requested_changed.connect(func(v: Variant) -> void: seen.append(v))
	c.reset()
	check_eq(link.last(T["request"]), -1.0)
	check_eq(c.requested, null)
	check_eq(seen, [null])
	link.up = true
	c.update()
	check_eq(link.count(T["request"]), 1, "nothing stored to re-publish after a reset")


func test_status_texts_and_slider_value() -> void:
	var c := IntakeSpeed.new(link, T)
	check_eq(c.status(), "Robot not connected - value is sent when it reconnects")
	check_eq(c.slider_value(), 0.15, "fallback before anything is known")
	link.up = true
	link.values[T["state"]] = 0.5
	check_eq(c.status(), "Using the robot's compiled constant")
	check_eq(c.slider_value(), 0.5, "robot value when nothing is requested")
	c.set_speed(0.42)
	check_eq(c.status(), "Waiting for the robot to confirm")
	link.values[T["state"]] = 0.424
	check_eq(c.status(), "Robot confirmed this speed", "within 0.005")
	link.values[T["state"]] = 0.426
	check_eq(c.status(), "Waiting for the robot to confirm", "outside 0.005")
	link.values[T["state"]] = NAN
	check_eq(c.robot_speed(), null, "non-finite State is unusable")
	check_eq(c.slider_value(), 0.42)
	link.up = false
	check_eq(c.status(), "Robot not connected - value is sent when it reconnects")


func test_settings_normalize_controls() -> void:
	check_eq(AppSettings.normalize_controls(null), {"selected_auto": "", "intake_speed": null})
	check_eq(AppSettings.normalize_controls({"selected_auto": " Stay And Shoot ", "intake_speed": 0.456}),
		{"selected_auto": "Stay And Shoot", "intake_speed": 0.46})
	check_eq(AppSettings.normalize_controls({"selected_auto": 3, "intake_speed": "0.4"}), {"selected_auto": "", "intake_speed": null})
	check_eq(AppSettings.normalize_controls({"intake_speed": 4.0})["intake_speed"], 1.0)
