std = "luajit"
cache = true

globals = {
	"vim",
}

ignore = {
	"212", -- Unused argument (callbacks frequently ignore params)
	"213", -- Unused loop variable
	"631", -- Line is too long
}

files["tests/"] = {
	globals = {
		"describe",
		"it",
		"before_each",
		"after_each",
		"assert",
		"pending",
		"setup",
		"teardown",
	},
}
