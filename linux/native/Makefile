# porthole-capture: build-time headers are vendored in third_party/ (X11 protocol headers and
# NVIDIA's MIT-licensed nv-codec-headers), so no -dev packages are needed. At runtime it
# links only against the X11 client libraries every desktop has; CUDA/NVENC are dlopen'ed.
CC      ?= gcc
CFLAGS  ?= -O2 -g0 -pipe
CFLAGS  += -std=c11 -Wall -Wextra -Wno-unused-parameter -Wno-missing-field-initializers \
           -D_FORTIFY_SOURCE=2 -fstack-protector-strong -fPIE -Ithird_party/include
LDFLAGS += -pie -Wl,-z,relro,-z,now -Wl,--as-needed
LDLIBS  := -l:libX11.so.6 -l:libXext.so.6 -l:libXdamage.so.1 -ldl

porthole-capture: capture.c
	$(CC) $(CFLAGS) -o $@ $< $(LDFLAGS) $(LDLIBS)
	strip --strip-unneeded $@

clean:
	rm -f porthole-capture
.PHONY: clean
