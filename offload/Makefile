# Use the matching OpenWrt musl toolchain, never a host compiler for deployment.
CC ?= cc
CFLAGS ?= -Os -Wall -Wextra -Werror
LDLIBS = -ldl

getdomains-offload-owner: getdomains-offload-owner.c

.PHONY: clean
clean:
	rm -f getdomains-offload-owner
