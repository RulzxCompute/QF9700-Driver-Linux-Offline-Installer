# QF9700 USB2NET driver — kernel module Makefile
#
# Upstream: https://github.com/pgquiles/qf9700
# This Makefile builds the same qf9700.c source on Ubuntu 22.04
# (kernel 5.15 GA and 6.x HWE) using the running kernel's build tree.
#
# Offline use:
#   make            # build qf9700.ko for $(uname -r)
#   make clean      # remove build artefacts
#   KVER=5.15.0-91-generic make   # build for a specific installed kernel
#
# The installer script (../../install.sh) calls this Makefile, it does
# NOT download anything.

KVER ?= $(shell uname -r)
KDIR ?= /lib/modules/$(KVER)/build
PWD  := $(shell pwd)

MODULE_NAME := qf9700
obj-m := $(MODULE_NAME).o

all:
	@echo "Building QF9700 USB2NET chip driver for kernel $(KVER)..."
	@echo "KDIR=$(KDIR)"
	@test -d "$(KDIR)" || (echo "ERROR: kernel build tree not found: $(KDIR)" >&2; \
		echo "HINT: install matching linux-headers-$(KVER) from packages/ bundle." >&2; \
		echo "      Check: ls /lib/modules/$(KVER)/ ; ls /usr/src/ | grep $(KVER)" >&2; exit 1)
	$(MAKE) -C $(KDIR) M=$(PWD) modules

clean:
	@if test -d "$(KDIR)"; then \
		$(MAKE) -C $(KDIR) M=$(PWD) clean; \
	else \
		rm -f *.o *.ko *.mod.c *.mod.o Module.symvers Module.markers modules.order .*.cmd .*.o.d; \
		rm -rf .tmp_versions; \
	fi

install-module:
	@echo "Use ../../install.sh instead of 'make install' (it handles depmod/modprobe/persistence)."

.PHONY: all clean install-module
