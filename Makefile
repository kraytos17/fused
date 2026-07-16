PROJECT       := fused
BINARY        := $(PROJECT)
SRC_DIR       := src
MOUNTER_DIR    := src/mounter
DISKER_DIR     := src/disker
IMGDUMP_DIR    := tools/imgdump
TEST_DIR       := tests
BUILD_DIR     := $(or $(BUILD_DIR),build)
LOGS_DIR      := $(or $(LOGS_DIR),logs)
ODIN          := $(or $(ODIN),odin)
MOUNTPOINT    := $(or $(MOUNTPOINT),mnt)
IMAGE         := $(or $(IMAGE),fused.img)
COLLECTIONS   := -collection:src=$(SRC_DIR)

# Parallelism — Odin's internal thread count for a single compilation.
# Lower when running make -jN concurrently; higher for single-target builds.
# Check CPU count: `nproc`; set half or less to avoid memory pressure.
THREAD_COUNT  := $(or $(THREAD_COUNT),4)

# FUSE3 linkage: the `foreign import libfuse3 "system:fuse3"` in
# src/fuse3/foreign.odin drives the link via pkg-config. The
# -extra-linker-flags below is a fallback in case the
# pkg-config integration ever drops on a toolchain update.
FUSE_LINK_FLAGS := -extra-linker-flags:"-lfuse3 -lpthread"

# Base flags shared by all debug builds.
# -no-threaded-checker skips the race-detector pass (compiles faster).
# -thread-count controls Odin's internal parallelism.
BASE_DEBUG    := -debug -o:none -warnings-as-errors \
                 -use-separate-modules \
                 -no-threaded-checker \
                 -thread-count:$(THREAD_COUNT)

# Debug (incremental build — separate modules cache interfaces)
DEBUG_FLAGS   := $(BASE_DEBUG)

# Full clean build — single module is faster when nothing is cached.
FULL_BUILD    := -debug -o:none -warnings-as-errors \
                 -use-single-module \
                 -no-threaded-checker \
                 -thread-count:$(THREAD_COUNT)

# Release build — optimized, no debug info, single-module for speed.
RELEASE_FLAGS := -o:aggressive \
                 -no-bounds-check \
                 -no-type-assert \
                 -disable-assert \
                 -microarch:native \
                 -lto:thin \
                 -source-code-locations:none \
                 -use-single-module \
                 -no-threaded-checker \
                 -thread-count:$(THREAD_COUNT)

# Test — single-threaded test runner to avoid shared-image corruption.
TEST_FLAGS    := $(BASE_DEBUG) \
                 -define:ODIN_TEST_THREADS=1

VET_FLAGS     := -vet -vet-shadowing -strict-style
CHECK_FLAGS   := -warnings-as-errors

# Set SHOW_TIMINGS=1 to print compile-time breakdown per target.
SHOW_TIMINGS  := $(or $(SHOW_TIMINGS),)
TIMING_FLAG   := $(if $(SHOW_TIMINGS),-show-timings,)
ODIN_VERSION  := $(shell $(ODIN) version 2>&1 | head -1)

.PHONY: all build release disker run-disker imgdump \
        test check smoke smoke-harness smoke-rw smoke-rw-harness smoke-mt smoke-mt-harness ci ci-full \
        disker-test audit mount unmount \
        verify verify-full clean clean-logs rebuild help \
        vet vet-all vet-shadowing vet-unused vet-style vet-cast \
        check-requires check-versions

# Use FULL_BUILD (single-module) for the first build after clean.
# Subsequent incremental builds use DEBUG_FLAGS (separate-modules) via the
# individual targets.
all: clean
	@echo "==> Full build (single-module for speed) (Odin: $(ODIN_VERSION))"
	@mkdir -p $(BUILD_DIR) $(LOGS_DIR)
	$(ODIN) build $(MOUNTER_DIR) $(COLLECTIONS) -out:$(BUILD_DIR)/$(BINARY) $(FULL_BUILD) $(FUSE_LINK_FLAGS) $(TIMING_FLAG)
	$(ODIN) build $(DISKER_DIR) $(COLLECTIONS) -out:$(BUILD_DIR)/disker $(FULL_BUILD) $(TIMING_FLAG)
	$(ODIN) build $(IMGDUMP_DIR) $(COLLECTIONS) -out:$(BUILD_DIR)/imgdump $(FULL_BUILD) $(TIMING_FLAG)
	$(ODIN) test $(TEST_DIR) $(COLLECTIONS) $(TEST_FLAGS) $(TIMING_FLAG)
	@echo "==> Running disker (default 1 MB image → fused.img)"
	@./$(BUILD_DIR)/disker --force --size=1M --output=fused.img

build:
	@echo "==> Building debug $(BINARY) (Odin: $(ODIN_VERSION))"
	@mkdir -p $(BUILD_DIR) $(LOGS_DIR)
	$(ODIN) build $(MOUNTER_DIR) $(COLLECTIONS) -out:$(BUILD_DIR)/$(BINARY) $(DEBUG_FLAGS) $(FUSE_LINK_FLAGS) $(TIMING_FLAG)

disker:
	@echo "==> Building disker (Odin: $(ODIN_VERSION))"
	@mkdir -p $(BUILD_DIR)
	$(ODIN) build $(DISKER_DIR) $(COLLECTIONS) -out:$(BUILD_DIR)/disker $(DEBUG_FLAGS) $(TIMING_FLAG)

run-disker: disker
	@echo "==> Running disker (default 1 MB image → fused.img)"
	@./$(BUILD_DIR)/disker --force --size=1M --output=fused.img

imgdump:
	@echo "==> Building imgdump (Odin: $(ODIN_VERSION))"
	@mkdir -p $(BUILD_DIR)
	$(ODIN) build $(IMGDUMP_DIR) $(COLLECTIONS) -out:$(BUILD_DIR)/imgdump $(DEBUG_FLAGS) $(TIMING_FLAG)

rebuild: clean build

release:
	@echo "==> Building release $(BINARY) (Odin: $(ODIN_VERSION))"
	@echo "    flags: $(RELEASE_FLAGS)"
	@mkdir -p $(BUILD_DIR)
	$(ODIN) build $(MOUNTER_DIR) $(COLLECTIONS) -out:$(BUILD_DIR)/$(BINARY)_release $(RELEASE_FLAGS) $(FUSE_LINK_FLAGS) $(TIMING_FLAG)

clean:
	@echo "==> Cleaning build artifacts"
	@rm -rf $(BUILD_DIR) $(LOGS_DIR)
	@fusermount3 -u $(MOUNTPOINT) 2>/dev/null || true

clean-logs:
	@rm -rf $(LOGS_DIR) /dev/shm/fused_test.img 2>/dev/null || true

mount: build
	@echo "==> Mounting $(BUILD_DIR)/$(BINARY) $(IMAGE) on $(MOUNTPOINT) (foreground, debug)"
	@mkdir -p $(MOUNTPOINT)
	@./$(BUILD_DIR)/$(BINARY) $(IMAGE) -f -d $(MOUNTPOINT)

unmount:
	@echo "==> Unmounting $(MOUNTPOINT)"
	@fusermount3 -u $(MOUNTPOINT) 2>/dev/null || true

test: run-disker
	@echo "==> Running all tests"
	$(ODIN) test $(TEST_DIR) $(COLLECTIONS) $(TEST_FLAGS) $(TIMING_FLAG)

check:
	@echo "==> C vs Odin struct size cross-check"
	@bash $(TEST_DIR)/check_sizes.sh

audit:
	@echo "==> Auditing \"c\" proc callbacks for context restoration"
	@bash $(TEST_DIR)/check_context.sh

smoke: build run-disker
	@echo "==> End-to-end smoke test (mount + ls + cat + stat + write + unmount)"
	@bash $(TEST_DIR)/smoke.sh

smoke-harness: build run-disker
	@bash $(TEST_DIR)/fuse_harness.sh --timeout=60 $(TEST_DIR)/smoke.sh

smoke-rw: build run-disker
	@echo "==> Read-write smoke test (create + write + mkdir + unlink + remount)"
	@bash $(TEST_DIR)/smoke_rw.sh

smoke-rw-harness: build run-disker
	@bash $(TEST_DIR)/fuse_harness.sh --timeout=90 $(TEST_DIR)/smoke_rw.sh

smoke-mt: build run-disker
	@echo "==> Multi-threaded stress test (concurrent read/write/delete)"
	@bash $(TEST_DIR)/fuse_harness.sh --timeout=120 $(TEST_DIR)/smoke_mt.sh

smoke-mt-harness: build run-disker
	@bash $(TEST_DIR)/fuse_harness.sh --timeout=120 $(TEST_DIR)/smoke_mt.sh

ci: build run-disker
	@bash $(TEST_DIR)/ci.sh

ci-full: build run-disker
	@bash $(TEST_DIR)/ci.sh --no-tool-tests

disker-test: build disker imgdump run-disker
	@echo "==> Running disker + imgdump integration tests"
	@bash $(TEST_DIR)/disker_test.sh

verify: check audit
	@echo
	@echo "==> All non-FUSE verifications passed."

verify-full: verify smoke-harness smoke-rw-harness

VET_DIRS := src/disker src/mounter

vet:
	@echo "==> Vet on $(VET_DIRS)"
	@for d in $(VET_DIRS); do \
		$(ODIN) check $$d $(COLLECTIONS) $(CHECK_FLAGS) $(VET_FLAGS) || exit 1; \
	done

vet-all: run-disker
	@echo "==> Comprehensive vet (build + test, LLVM)"
	@for d in $(VET_DIRS); do \
		$(ODIN) build $$d $(COLLECTIONS) $(CHECK_FLAGS) $(VET_FLAGS) -out:/dev/null || exit 1; \
	done
	$(ODIN) test $(TEST_DIR) $(COLLECTIONS) $(TEST_FLAGS) $(TIMING_FLAG)

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
	@echo "  test            Odin test suite"
	@echo "  disker-test     disker + imgdump integration tests"
	@echo "  check           C vs Odin struct size cross-check"
	@echo "  audit           audit \"c\" callbacks for context + logger restoration"
	@echo "  smoke           mount + ls + cat + stat + write + unmount"
	@echo "  smoke-harness   smoke via fuse_harness (isolated namespace, timed)"
	@echo "  smoke-rw        read-write test (create + write + mkdir + unlink + remount)"
	@echo "  smoke-rw-harness smoke-rw via fuse_harness (isolated namespace, timed)"
	@echo "  ci              build + check + audit + test + smoke-harness"
	@echo "  ci-full         all the above + tool integration tests + smoke-rw"
	@echo "  verify          check + audit (no FUSE needed)"
	@echo ""
	@echo "Vet:"
	@echo "  vet             type-check + vet + strict-style"
	@echo "  vet-all         type-check + build + test (LLVM)"
	@echo "  vet-shadowing   variable shadowing check"
	@echo "  vet-unused      unused declarations check"
	@echo "  vet-style       code style check"
	@echo "  vet-cast        redundant cast check"
	@echo ""
	@echo "Environment:"
	@echo "  check-requires  verify Odin, fusermount3, pkg-config, /dev/fuse"
	@echo "  check-versions  print Odin + libfuse3 versions"
	@echo ""
	@echo "Variables:"
	@echo "  MOUNTPOINT=$(MOUNTPOINT)  BUILD_DIR=$(BUILD_DIR)  IMAGE=$(IMAGE)"
	@echo "  LOGS_DIR=$(LOGS_DIR)  ODIN=$(ODIN)  THREAD_COUNT=$(THREAD_COUNT)"
	@echo "  SHOW_TIMINGS=$(SHOW_TIMINGS)  (set to 1 for compile-time breakdown)"
