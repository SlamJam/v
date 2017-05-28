.DEFAULT_GOAL := all

.PHONY: all
all:

.PHONY: test
test:
	find tests -type f | xargs -I{} bash -x -e {}
