CC ?= gcc
CFLAGS ?= -Wall -Wextra -O2 -std=c11 -D_FORTIFY_SOURCE=2 -fstack-protector-strong -Wformat -Wformat-security -MMD -MP
LDFLAGS ?= -static

STATUS_SRCS = main.c drm.c fb.c input.c status.c
STATUS_OBJS = $(STATUS_SRCS:.c=.o)

DNS_SRCS = dns-forwarder.c
DNS_OBJS = $(DNS_SRCS:.c=.o)

ALL_SRCS = $(STATUS_SRCS) $(DNS_SRCS)
DEPS = $(ALL_SRCS:.c=.d)

TARGETS = phx-statusd dns-forwarder

all: $(TARGETS)

phx-statusd: $(STATUS_OBJS)
	$(CC) $(CFLAGS) -o $@ $(STATUS_OBJS) $(LDFLAGS)

dns-forwarder: $(DNS_OBJS)
	$(CC) $(CFLAGS) -o $@ $(DNS_OBJS) $(LDFLAGS)

%.o: %.c
	$(CC) $(CFLAGS) -c $< -o $@

-include $(DEPS)

format:
	clang-format -i $(ALL_SRCS) *.h

check-format:
	clang-format --dry-run -Werror $(ALL_SRCS) *.h

tidy:
	clang-tidy $(ALL_SRCS) -- -I . -std=c11 -D_GNU_SOURCE

clean:
	rm -f $(STATUS_OBJS) $(DNS_OBJS) $(DEPS) $(TARGETS)

.PHONY: all clean format check-format tidy
