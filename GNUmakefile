
LUA := lua

PACKAGE.PATH := $(PWD)/lib/?.lua;$(PWD)/lib/?/init.lua
PACKAGE.CPATH :=

test:
	$(LUA)                                      \
		-e "package.cpath = '$(PACKAGE.CPATH)'" \
		-e "package.path = '$(PACKAGE.PATH)'"   \
		test/test.lua

join-test:
	$(LUA)                                      \
		-e "package.cpath = '$(PACKAGE.CPATH)'" \
		-e "package.path = '$(PACKAGE.PATH)'"   \
		test/join.lua
