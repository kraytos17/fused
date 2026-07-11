PROJECT       := fused
BINARY        := $(PROJECT)
SRC_DIR       := src
MOUNTER_DIR    := src/mounter
DISKER_DIR     := src/disker
IMGDUMP_DIR    := tools/imgdump
TEST_DIR       := tests
BUILD_DIR     := $(or $(BUILD_DIR),build)
ODIN          := $(or $(ODIN),odin)
MOUNTPOINT    := $(or $(MOUNTPOINT),/tmp/mnt)
COLLECTIONS   := -collection:src=$(SRC_DIR)

# FUSE3 linkage: the `foreign import libfuse3 "system:fuse3"` in
# src/fuse3/foreign.odin drives the link via pkg-config. The
# -extra-linker-flags below is a fallback in case the
# pkg-config integration ever drops on a toolchain update.
FUSE_LINK_FLAGS := -extra-linker-flags:"-lfuse3 -lpthread"
DEBUG_FLAGS   := -debug -o:none -warnings-as-errors \
                 -use-separate-modules

RELEASE_FLAGS := -o:aggressive \
                 -no-bounds-check \
                 -no-type-assert \
                 -disable-assert \
                 -microarch:native \
                 -lto:thin \
                 -source-code-locations:none \
                 -use-separate-modules

TEST_FLAGS    := -debug -o:none -warnings-as-errors \
                 -use-separate-modules \
                 -define:ODIN_TEST_THREADS=1

VET_FLAGS     := -vet -vet-shadowing -strict-style
CHECK_FLAGS   := -warnings-as-errors

ODIN_VERSION  := $(shell $(ODIN) version 2>&1 | head -1)

.PHONY: all build release disker run-disker imgdump \
        test check smoke audit mount unmount \
        verify vet vet-all vet-shadowing vet-unused vet-style vet-cast \
        check-vet check-requires check-versions clean rebuild help

all: clean disker build imgdump run-disker test vet

build:
	@echo "==> Building debug $(BINARY) (Odin: $(ODIN_VERSION))"
	@mkdir -p $(BUILD_DIR)
	$(ODIN) build $(MOUNTER_DIR) $(COLLECTIONS) -out:$(BUILD_DIR)/$(BINARY) $(DEBUG_FLAGS) $(FUSE_LINK_FLAGS)

disker:
	@echo "==> Building disker (Odin: $(ODIN_VERSION))"
	@mkdir -p $(BUILD_DIR)
	$(ODIN) build $(DISKER_DIR) $(COLLECTIONS) -out:$(BUILD_DIR)/disker $(DEBUG_FLAGS)

run-disker: disker
	@echo "==> Running disker (default 1 MB image → fused.img)"
	@./$(BUILD_DIR)/disker --size=1M --output=fused.img

imgdump:
	@echo "==> Building imgdump (Odin: $(ODIN_VERSION))"
	@mkdir -p $(BUILD_DIR)
	$(ODIN) build $(IMGDUMP_DIR) $(COLLECTIONS) -out:$(BUILD_DIR)/imgdump $(DEBUG_FLAGS)

rebuild: clean build

release:
	@echo "==> Building release $(BINARY) (Odin: $(ODIN_VERSION))"
	@echo "    flags: $(RELEASE_FLAGS)"
	@mkdir -p $(BUILD_DIR)
	$(ODIN) build $(MOUNTER_DIR) $(COLLECTIONS) -out:$(BUILD_DIR)/$(BINARY)_release $(RELEASE_FLAGS) $(FUSE_LINK_FLAGS)

clean:
	@echo "==> Cleaning build artifacts"
	@rm -rf $(BUILD_DIR)
	@rm -f myfs myfs_release
	@fusermount3 -u $(MOUNTPOINT) 2>/dev/null || true

rebuild: clean build

IMAGE := $(or $(IMAGE),fused.img)

mount: build
	@echo "==> Mounting $(BUILD_DIR)/$(BINARY) $(IMAGE) on $(MOUNTPOINT) (foreground, debug)"
	@mkdir -p $(MOUNTPOINT)
	@./$(BUILD_DIR)/$(BINARY) $(IMAGE) -f -d $(MOUNTPOINT)

unmount:
	@echo "==> Unmounting $(MOUNTPOINT)"
	@fusermount3 -u $(MOUNTPOINT) 2>/dev/null || true

test: run-disker
	@echo "==> Running all tests"
	$(ODIN) test $(TEST_DIR) $(COLLECTIONS) $(TEST_FLAGS)

check:
	@echo "==> C vs Odin struct size cross-check"
	@bash $(TEST_DIR)/check_sizes.sh

audit:
	@echo "==> Auditing \"c\" proc callbacks for context restoration"
	@bash $(TEST_DIR)/check_context.sh

smoke: build run-disker
	@echo "==> End-to-end smoke test (mount + ls + cat + stat + write-reject + unmount)"
	@bash $(TEST_DIR)/smoke.sh

verify: check audit smoke
	@echo
	@echo "==> All verifications passed."

VET_DIRS := src/disker src/mounter

vet:
	@echo "==> Fast vet on $(VET_DIRS)"
	@for d in $(VET_DIRS); do \
		$(ODIN) check $$d $(COLLECTIONS) $(CHECK_FLAGS) $(VET_FLAGS) || exit 1; \
	done

vet-all: run-disker
	@echo "==> Comprehensive vet on $(VET_DIRS) (build + test, LLVM)"
	@for d in $(VET_DIRS); do \
		$(ODIN) build $$d $(COLLECTIONS) $(CHECK_FLAGS) $(VET_FLAGS) -out:/dev/null || exit 1; \
	done
	$(ODIN) test $(TEST_DIR) $(COLLECTIONS) $(TEST_FLAGS)

vet-shadowing:
	@echo "==> Checking for variable shadowing"
	$(ODIN) build $(MOUNTER_DIR) $(COLLECTIONS) $(CHECK_FLAGS) -vet-shadowing -warnings-as-errors -out:/dev/null
	$(ODIN) test $(TEST_DIR) $(COLLECTIONS) $(TEST_FLAGS)

vet-unused:
	@echo "==> Checking for unused declarations"
	$(ODIN) build $(MOUNTER_DIR) $(COLLECTIONS) $(CHECK_FLAGS) -vet-unused -warnings-as-errors -out:/dev/null
	$(ODIN) test $(TEST_DIR) $(COLLECTIONS) $(TEST_FLAGS)

vet-style:
	@echo "==> Checking code style"
	$(ODIN) build $(MOUNTER_DIR) $(COLLECTIONS) $(CHECK_FLAGS) -vet-style -vet-semicolon -warnings-as-errors -out:/dev/null
	$(ODIN) test $(TEST_DIR) $(COLLECTIONS) $(TEST_FLAGS)

vet-cast:
	@echo "==> Checking for redundant casts"
	$(ODIN) build $(MOUNTER_DIR) $(COLLECTIONS) $(CHECK_FLAGS) -vet-cast -warnings-as-errors -out:/dev/null
	$(ODIN) test $(TEST_DIR) $(COLLECTIONS) $(TEST_FLAGS)

check-vet:
	@echo "==> parse + type check with comprehensive vet"
	$(ODIN) check $(MOUNTER_DIR) $(COLLECTIONS) $(CHECK_FLAGS) $(VET_FLAGS)

check-requires:
	@echo "==> Verifying FUSE3 environment"
	@command -v $(ODIN) >/dev/null || { echo "FAIL: $(ODIN) not on PATH" >&2; exit 1; }
	@command -v fusermount3 >/dev/null || { echo "FAIL: fusermount3 not on PATH (install fuse3)" >&2; exit 1; }
	@pkg-config --exists fuse3 || { echo "FAIL: pkg-config fuse3 not found (install fuse3-dev)" >&2; exit 1; }
	@pkg-config --modversion fuse3 | awk '{ printf "  libfuse3 runtime version: %s\n", $$1 }'
	@[ -e /dev/fuse ] || { echo "WARN: /dev/fuse missing; run: sudo modprobe fuse" >&2; }
	@lsmod 2>/dev/null | grep -q '^fuse ' || { echo "WARN: fuse kernel module not loaded; run: sudo modprobe fuse" >&2; }
	@echo "==> Environment OK."

check-versions:
	@echo "$(ODIN) version: $(ODIN_VERSION)"
	@echo "libfuse3 version: $(shell pkg-config --modversion fuse3 2>/dev/null || echo 'not found')"
	@echo "Build flags (debug):   $(DEBUG_FLAGS)"
	@echo "Build flags (release): $(RELEASE_FLAGS)"

help:
	@echo "fused — libfuse3 Odin FUSE daemon"
	@echo ""
	@echo "Build:"
	@echo "  all             clean + disker + build + imgdump + run-disker + test + vet"
	@echo "  build           debug build -> build/$(BINARY)"
	@echo "  release         aggressive-opt build -> build/$(BINARY)_release"
	@echo "  mount           build then run in foreground against $(MOUNTPOINT)"
	@echo "  unmount         fusermount3 -u $(MOUNTPOINT)"
	@echo "  clean           remove build/, kill any running mount"
	@echo "  rebuild         clean && build"
	@echo ""
	@echo "Tests:"
	@echo "  test            Odin test suite (struct size @test)"
	@echo "  check           C vs Odin struct size cross-check"
	@echo "  audit           audit \"c\" callbacks for context restoration"
	@echo "  smoke           mount + ls + cat + stat + write-reject + unmount"
	@echo "  verify          check + audit + smoke (full validation)"
	@echo ""
	@echo "Vet (comprehensive checks):"
	@echo "  vet             parse + type check + vet + strict-style"
	@echo "  vet-all         vet via build + test (LLVM)"
	@echo "  vet-shadowing   check variable shadowing"
	@echo "  vet-unused      check unused variables/imports"
	@echo "  vet-style       check style (trailing commas, semicolons)"
	@echo "  vet-cast        check redundant casts"
	@echo ""
	@echo "Environment:"
	@echo "  check-requires  verify $(ODIN), fusermount3, pkg-config fuse3, /dev/fuse"
	@echo "  check-versions  print $(ODIN) + libfuse3 versions + build flags"
	@echo ""
	@echo "Variables (override on command line or via env):"
	@echo "  MOUNTPOINT=$(MOUNTPOINT)  BUILD_DIR=$(BUILD_DIR)  ODIN=$(ODIN)"
