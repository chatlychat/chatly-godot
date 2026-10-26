##
## The editor plugin. It registers nothing and that is deliberate.
##
## Every class in this addon declares `class_name`, so `ChatlyClient`,
## `ChatlyRestClient` and the rest are already global identifiers the moment
## the project parses them — with or without the plugin enabled. There is no
## custom node type to add, no autoload to install and no editor dock.
##
## `plugin.cfg` exists so the addon appears in Project Settings → Plugins,
## which is where a Godot developer looks to confirm something is installed.
## An addon that works but cannot be seen reads as an addon that did not
## install.
##
@tool
extends EditorPlugin
