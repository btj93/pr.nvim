.PHONY: test lint format format-check

# Run plenary.busted spec files under tests/.
# PLENARY_DIR is honoured by tests/minimal_init.lua; defaults to /tmp/plenary.nvim.
test:
	nvim --headless --noplugin -u tests/minimal_init.lua \
		-c "PlenaryBustedDirectory tests/ {minimal_init = 'tests/minimal_init.lua', sequential = true}" \
		-c "qa!"

lint:
	luacheck lua/ plugin/ tests/

format:
	stylua lua/ plugin/ tests/

format-check:
	stylua --check lua/ plugin/ tests/
