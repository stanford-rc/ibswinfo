CC ?= cc
CFLAGS ?= -O2 -Wall -Wextra
PREFIX ?= /usr/local
bindir ?= $(PREFIX)/bin
LDLIBS += -libmad -libumad

.PHONY: all install clean
all: ibsetnd

ibsetnd: ibsetnd.c

install: ibsetnd
	install -d $(DESTDIR)$(bindir)
	install -m 755 ibswinfo.sh ibsetnd $(DESTDIR)$(bindir)/

clean:
	rm -f ibsetnd
