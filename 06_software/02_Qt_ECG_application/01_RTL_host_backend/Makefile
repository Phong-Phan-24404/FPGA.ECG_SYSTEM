# Builds the coherent-buffer module and the user-space runner.
obj-m := pl_dmabuf.o
KDIR  ?= /lib/modules/$(shell uname -r)/build

all: module cnn_run

module:
	$(MAKE) -C $(KDIR) M=$(CURDIR) modules

cnn_run: cnn_run.c
	$(CC) -O2 -Wall -Wextra -o $@ $<

clean:
	$(MAKE) -C $(KDIR) M=$(CURDIR) clean
	rm -f cnn_run

.PHONY: all module clean
