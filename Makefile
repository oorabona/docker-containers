SHELL := /bin/bash
.DEFAULT_GOAL := all
.ONESHELL: ;
DIR = $(abspath .)
SOURCES ?= $(wildcard */docker-compose.yml)
OPERATION ?= Build
_OP = $(shell echo $(OPERATION) | tr A-Z a-z)
SKIP = push clean distclean
# NEWGOALS=$(shell echo $(MAKECMDGOALS) | sed "s/$(_OP)//")
NEWGOALS=$(filter-out $(SKIP),$(MAKECMDGOALS))

# Since (pat)subst is quite limited on substitutions, sed provides the functionality
# of using regular expressions to help us with.
# E.g. : sites/blah_sites.txt sites/foo_sites.txt => blah foo
CONTAINERS = $(shell echo $(patsubst %/docker-compose.yml,%,$(SOURCES)))

.PHONY: all $(SKIP) $(CONTAINERS)

.SILENT: ;               # no need for @

.EXPORT_ALL_VARIABLES:

all: $(NEWGOALS)

define do_it
ifeq ($(NEWGOALS),$(MAKECMDGOALS))
$(1): $(DIR)/$(1)/docker-compose.yml ; @echo "$(OPERATION)-ing $$@ using $$< configuration"
	pushd $$@
	docker-compose -f $$< $(2)
	popd
endif
endef

$(foreach container,$(CONTAINERS),$(eval $(call do_it,$(container),$(_OP))))

test: OUT_DIR=/tmp/domain-name
test: DRY_RUN=1
test: $(CONTAINERS) check clean

check:
	echo CONTAINERS=$(CONTAINERS)
	echo SOURCES=$(SOURCES)
	echo NEWGOALS=$(NEWGOALS)

push:
	make $(NEWGOALS) OPERATION=Push

clean:
	make $(NEWGOALS) OPERATION=Rm
