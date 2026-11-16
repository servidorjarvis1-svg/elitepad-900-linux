# Build sgx-ident: freestanding i386, the kernel's nolibc, no libc.

NOLIBC ?= $HOME/elitepad-dev/linux-6.12.117/tools/include/nolibc
CC ?= gcc

CFLAGS = -m32 -static -nostdlib -fno-pic -fno-stack-protector -Os \
	 -I$(NOLIBC) -include $(NOLIBC)/nolibc.h -Wall -Wextra

all: sgx-ident

sgx-ident: sgx-ident.c
	$(CC) $(CFLAGS) -o $@ $<

# The identity parsing and the verdict, on fake sysfs and a fake window: no
# hardware, no /dev/mem. Not part of `all`.
check: sgx-ident.c
	@set -e; \
	python3 -c "import struct;d=bytearray(64);struct.pack_into('<HH',d,0,0x8086,0x08cf);struct.pack_into('<I',d,0x10,0xff200000);open('/tmp/sgx-fake-config','wb').write(d)"; \
	python3 -c "import struct;b=0x1000;f=bytearray(0x4000);w=lambda o,v:struct.pack_into('<I',f,b+o,v);w(0x1c,0x01150202);w(0x20,0x0001000f);w(0x8,0x21);open('/tmp/sgx-fake-mem','wb').write(f)"; \
	$(CC) $(CFLAGS) '-DCONFIG_PATH="/tmp/sgx-fake-config"' \
		'-DDEVMEM_PATH="/tmp/sgx-fake-mem"' -o /tmp/sgx-ident-check $<; \
	/tmp/sgx-ident-check 0x1000 | grep -q "SGX545 confirmed"; \
	/tmp/sgx-ident-check --dry-run | grep -q "0xff280000"; \
	echo "check: ok"

clean:
	rm -f sgx-ident

.PHONY: all check clean
