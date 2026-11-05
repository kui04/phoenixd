CC ?= gcc
CFLAGS ?= -Wall -Wextra -O2 -std=c11 -D_FORTIFY_SOURCE=2 -fstack-protector-strong -Wformat -Wformat-security -MMD -MP
LDFLAGS ?= -static

TARGET = dns-forwarder
SRCS = dns-forwarder.c
OBJS = $(SRCS:.c=.o)
DEPS = $(SRCS:.c=.d)

all: $(TARGET)

$(TARGET): $(OBJS)
	$(CC) $(CFLAGS) -o $@ $(OBJS) $(LDFLAGS)

%.o: %.c
	$(CC) $(CFLAGS) -c $< -o $@

-include $(DEPS)

format:
	clang-format -i $(SRCS)

check-format:
	clang-format --dry-run -Werror $(SRCS)

tidy:
	clang-tidy $(SRCS) -- -I . -std=c11 -D_GNU_SOURCE

clean:
	rm -f $(OBJS) $(DEPS) $(TARGET)

.PHONY: all clean format check-format tidy
