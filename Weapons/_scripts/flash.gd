extends OmniLight3D

var delay_time = 0.075


func _ready():
	start_timer()

func start_timer():
	var timer = Timer.new()
	timer.one_shot = true
	timer.wait_time = delay_time
	timer.connect("timeout", Callable(self, "_on_timer_timeout"))
	add_child(timer)
	timer.start()

func _on_timer_timeout():
	self.visible = false
