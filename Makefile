# Everything the package manifest can say, it says. This file exists for the one thing it cannot:
# link-time optimisation. Three routes were tried before settling for a Makefile, and the reason
# none of them works is structural — LTO changes which artifacts the build produces and how the
# link consumes them, so the build system has to know about it, which is why it is a flag to
# `swift build` and not a setting on a target. It is not even in `swift build --help`; it takes
# `--help-hidden` to find it.
#
#   -lto=llvm-full in swiftSettings.unsafeFlags     compiles to a single bitcode module, then the
#                                                   link fails hunting for the per-file .o files
#                                                   that no longer exist
#   -lto=llvm-full in linkerSettings.unsafeFlags    links without complaint and does nothing at
#                                                   all: the objects are not bitcode, so there is
#                                                   nothing to optimise. Byte-for-byte the size of
#                                                   a build with no LTO, which is the only way to
#                                                   tell — it reports success either way
#   a PackageDescription API                        does not exist. No LTO and no optimisation
#                                                   level anywhere in SwiftSetting or LinkerSetting
#
# So `make release` is the build to ship. Be clear about what it is worth, because it is not
# speed: 2013 KiB against 2159 KiB, and no measurable difference in run time. Measured over 60
# dry runs each, both orderings, LTO came out at 3.78s and 3.86s of user CPU against 3.72s and
# 3.77s without — a spread within each build as wide as the gap between them. That is the
# expected answer rather than a disappointing one. A whole dry run is 62ms of CPU, the module is
# already whole-module optimised, and LTO cannot inline into Foundation or Dispatch because those
# arrive as prebuilt dylibs. On a run that is three quarters device I/O there is nothing here for
# it to win.
#
# Those two sizes were 589 KiB and 647 KiB before swift-argument-parser came in, so the library
# is 1.4 MiB of the binary and the tool's own code is under a third of it. Nothing to do about
# that short of dropping the dependency — it is a static link of a general-purpose library into a
# tool that uses one command and eight options — and at a couple of megabytes for something
# installed once it is not worth doing. Recorded here because the figures above would otherwise
# read as though the code had tripled in size. The gap LTO closes did grow with it, from 58 KiB
# to 146 KiB, which is the one thing here the dependency made better: there is now a module
# boundary for it to work across.
#
# It also made a clean `make release` noisy. The link emits 53 copies of "overriding the module
# target triple with arm64-apple-macosx26.3.0 [-Woverride-module]", one per bitcode module in the
# dependency, because the manifest's macOS floor is applied to a graph whose other half records a
# lower one. Nothing to silence it with from this side, and a plain `swift build -c release` does
# not do it. The two warnings about debug symbols predate all this and come from LTO itself.
#
# Xcode, opening Package.swift directly, has no way to pass the flag either, and neither does a
# plain `swift build -c release`. Both produce the larger no-LTO binary. That is fine for editing
# and debugging, and worth knowing before quoting a size from one.
#
# Cross-module optimisation was tried here too and is deliberately absent. When it was measured
# there was no boundary for it to cross — one target, no dependencies, exactly one Swift module in
# the build — and it showed: -enable-cmo-everything and -package-cmo both produced binaries
# byte-identical to the baseline, and -cross-module-optimization produced 72 bytes more code for
# 4.03s of user CPU over 60 dry runs against 3.92s without, its own spread across passes three
# times that gap.
#
# swift-argument-parser gave it a boundary, so that reasoning no longer holds, but the conclusion
# does and for a different reason: what CMO does is make a module's SIL available for another
# module to inline from, and it is the *producing* module that has to be built with it. That is
# the dependency, whose manifest is not ours to set. LTO reaches across the same boundary from
# this side without needing anyone's permission, which is what the 146 KiB above is. Worth
# revisiting only if a dependency ever ships with it enabled.

BIN := .build/release/fatrabbit

PREFIX ?= /usr/local
BINDIR := $(DESTDIR)$(PREFIX)/bin

.PHONY: all release debug run clean install uninstall linux linux-sync linux-shell

all: release

# The shipping build: -O and whole-module from the release configuration, -Ounchecked from the
# manifest, full LTO from here.
release:
	swift build -c release --experimental-lto-mode=full

debug:
	swift build

# Where `make release` leaves the binary, for scripts that would rather ask than hardcode it.
run: release
	@echo $(abspath $(BIN))

# Only the copy escalates, never the build. `sudo make install` would rebuild the whole package as
# root and leave a .build tree your own account can no longer write to, so the escalation is here
# rather than on the command line: build as you, then sudo the one command that needs it, and only
# when it needs it. That last part is the whole bug — /usr/local/bin is group-writable by admin on
# macOS and root-only on Linux, so the plain `install` succeeded on one and not the other.
# Override PREFIX or DESTDIR to land somewhere you already own and no sudo happens at all.
install: release
	@if [ -w "$(BINDIR)" ]; then \
	    install -m 0755 $(BIN) "$(BINDIR)/fatrabbit"; \
	else \
	    echo "$(BINDIR) is not writable, asking for sudo"; \
	    sudo install -d -m 0755 "$(BINDIR)" && sudo install -m 0755 $(BIN) "$(BINDIR)/fatrabbit"; \
	fi
	@echo "installed $(BINDIR)/fatrabbit"

uninstall:
	@if [ -w "$(BINDIR)" ]; then rm -f "$(BINDIR)/fatrabbit"; else sudo rm -f "$(BINDIR)/fatrabbit"; fi

# The Linux side. A container rather than a cross-compilation SDK, because cross-compiling proves
# only that it builds — and the errors worth catching here were not build errors. The image is
# pinned to the same 6.3.3 the Mac runs, so a diagnostic can only mean a platform difference and
# never a toolchain one. Colima mounts $HOME and nothing else, so the tree has to be reachable from
# there; SRC below is that path, and `linux-sync` refreshes it.
LINUX_IMAGE := swift:6.3.3
LINUX_SRC   := $(HOME)/.fatrabbit-linux

linux-sync:
	@mkdir -p $(LINUX_SRC)
	@rsync -a --delete --exclude '.build*' --exclude '.git' --exclude '.swiftpm' \
	       --exclude '*.img' ./ $(LINUX_SRC)/

linux: linux-sync
	docker run --rm -v $(LINUX_SRC):/src -w /src $(LINUX_IMAGE) \
	    swift build --scratch-path .build-linux

# Needs --privileged for losetup, which is the only way to exercise the mount check for real:
# imageDevices reads /sys/class/block/loop*/loop/backing_file, and without a loop device there is
# nothing there to read.
linux-shell: linux-sync
	docker run --rm -it --privileged -v $(LINUX_SRC):/src -w /src $(LINUX_IMAGE) bash

clean:
	swift package clean
	rm -rf .build .build-linux
