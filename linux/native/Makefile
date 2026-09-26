# darpan-capture: build-time headers are vendored in third_party/ (X11 protocol headers,
# NVIDIA's MIT-licensed nv-codec-headers, Khronos' Vulkan headers), so no -dev packages are needed.
# At runtime it links only against the X11 client libraries every desktop has; Vulkan, CUDA and
# NVENC are dlopen'ed.
CC      ?= gcc
CFLAGS  ?= -O2 -g0 -pipe
CFLAGS  += -std=c11 -Wall -Wextra -Wno-unused-parameter -Wno-missing-field-initializers \
           -D_FORTIFY_SOURCE=2 -fstack-protector-strong -fPIE -Ithird_party/include
LDFLAGS += -pie -Wl,-z,relro,-z,now -Wl,--as-needed
LDLIBS  := -l:libX11.so.6 -l:libXext.so.6 -l:libXdamage.so.1 -ldl

darpan-capture: capture.c vkenc.c vkenc.h rgb2nv12.h
	$(CC) $(CFLAGS) -o $@ capture.c vkenc.c $(LDFLAGS) $(LDLIBS)
	strip --strip-unneeded $@

# The conversion shader, compiled into rgb2nv12.h (checked in, so building needs no glslang).
shader: rgb2nv12.comp
	glslangValidator -V --target-env vulkan1.3 --vn rgb2nv12_spv -o rgb2nv12.h $<

clean:
	rm -f darpan-capture
.PHONY: clean shader
