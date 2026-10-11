# Build with an OpenWrt SDK toolchain matching the target architecture.
CC ?= cc
CFLAGS ?= -O2 -Wall -Wextra -Werror
LDLIBS = -lnftables

offload-owner: offload-owner.c

.PHONY: clean
clean:
	rm -f offload-owner
