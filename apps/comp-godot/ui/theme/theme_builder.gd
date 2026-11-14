class_name ThemeBuilder
extends RefCounted

## Builds the one Theme both window roots use, in code, from Tokens.

static var _theme: Theme


static func build() -> Theme:
	if _theme != null:
		return _theme
	var t := Theme.new()
	t.default_font = Tokens.inter(400)
	t.default_font_size = Tokens.FONT_TEXT_BASE
	t.set_color("font_color", "Label", Tokens.TEXT)
	t.set_font("font", "Label", Tokens.inter(400))
	t.set_type_variation("MonoLabel", "Label")
	t.set_font("font", "MonoLabel", Tokens.mono(400))
	t.set_type_variation("MediumLabel", "Label")
	t.set_font("font", "MediumLabel", Tokens.inter(500))
	_theme = t
	return t
