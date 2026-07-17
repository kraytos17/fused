PROJECT       := fused
BINARY        := $(PROJECT)
SRC_DIR       := src
MOUNTER_DIR   := src/mounter
DISKER_DIR    := src/disker
IMGDUMP_DIR   := tools/imgdump
TEST_DIR      := tests
BUILD_DIR     := $(or $(BUILD_DIR),build)
LOGS_DIR      := $(or $(LOGS_DIR),logs)
ODIN          := $(or $(ODIN),odin)
MOUNTPOINT    := $(or $(MOUNTPOINT),mnt)
IMAGE         := $(or $(IMAGE),fused.img)
COLLECTIONS   := -collection:src=$(SRC_DIR)
THREAD_COUNT  := $(or $(THREAD_COUNT),4)
FUSE_LINK     := -extra-linker-flags:"-lfuse3 -lpthread"
PYTHON_RUN    := PYTHONPATH=$(TEST_DIR) python3 -m

BASE_DEBUG    := -debug -o:none -warnings-as-errors \
                 -use-separate-modules \
                 -no-threaded-checker \
                 -thread-count:$(THREAD_COUNT)

FULL_BUILD    := -debug -o:none -warnings-as-errors \
                 -use-single-module \
                 -no-threaded-checker \
                 -thread-count:$(THREAD_COUNT)
RELEASE_FLAGS := -o:aggressive -no-bounds-check -no-type-assert -disable-assert \
                 -microarch:native -lto:thin -source-code-locations:none \
                 -use-single-module -no-threaded-checker -thread-count:$(THREAD_COUNT)
TEST_FLAGS    := $(BASE_DEBUG) -define:ODIN_TEST_THREADS=1
VET_FLAGS     := -vet -vet-shadowing -strict-style
CHECK_FLAGS   := -warnings-as-errors

SHOW_TIMINGS  := $(or $(SHOW_TIMINGS),)
TIMING_FLAG   := $(if $(SHOW_TIMINGS),-show-timings,)
ODIN_VERSION  := $(shell $(ODIN) version 2>&1 | head -1)
VET_DIRS      := src/disker src/mounter

.PHONY: all build release disker run-disker imgdump \
        test check audit smoke smoke-rw smoke-mt smoke-errors \
        ci disker-test mount unmount \
        verify verify-full clean clean-logs rebuild help \
        vet vet-all vet-shadowing vet-unused vet-style vet-cast \
        check-requires check-versions

all: clean
	@echo "==> Full build (Odin: $(ODIN_VERSION))"
	@mkdir -p $(BUILD_DIR) $(LOGS_DIR)
	$(ODIN) build $(MOUNTER_DIR) $(COLLECTIONS) -out:$(BUILD_DIR)/$(BINARY) $(FULL_BUILD) $(FUSE_LINK) $(TIMING_FLAG)
	$(ODIN) build $(DISKER_DIR) $(COLLECTIONS) -out:$(BUILD_DIR)/disker $(FULL_BUILD) $(TIMING_FLAG)
	$(ODIN) build $(IMGDUMP_DIR) $(COLLECTIONS) -out:$(BUILD_DIR)/imgdump $(FULL_BUILD) $(TIMING_FLAG)
	@echo "==> Creating default image (1 MB → fused.img)"
	@./$(BUILD_DIR)/disker --force --size=1M --output=fused.img
	@echo "==> Running all tests"
	$(ODIN) test $(TEST_DIR) $(COLLECTIONS) $(TEST_FLAGS) $(TIMING_FLAG)

build:
	@echo "==> Building debug $(BINARY) (Odin: $(ODIN_VERSION))"
	@mkdir -p $(BUILD_DIR) $(LOGS_DIR)
	$(ODIN) build $(MOUNTER_DIR) $(COLLECTIONS) -out:$(BUILD_DIR)/$(BINARY) $(BASE_DEBUG) $(FUSE_LINK) $(TIMING_FLAG)

disker:
	@echo "==> Building disker (Odin: $(ODIN_VERSION))"
	@mkdir -p $(BUILD_DIR)
	$(ODIN) build $(DISKER_DIR) $(COLLECTIONS) -out:$(BUILD_DIR)/disker $(BASE_DEBUG) $(TIMING_FLAG)

imgdump:
	@echo "==> Building imgdump (Odin: $(ODIN_VERSION))"
	@mkdir -p $(BUILD_DIR)
	$(ODIN) build $(IMGDUMP_DIR) $(COLLECTIONS) -out:$(BUILD_DIR)/imgdump $(BASE_DEBUG) $(TIMING_FLAG)

release:
	@echo "==> Building release $(BINARY) (Odin: $(ODIN_VERSION))"
	@mkdir -p $(BUILD_DIR)
	$(ODIN) build $(MOUNTER_DIR) $(COLLECTIONS) -out:$(BUILD_DIR)/$(BINARY)_release $(RELEASE_FLAGS) $(FUSE_LINK) $(TIMING_FLAG)

rebuild: clean build

run-disker: disker
	@echo "==> Running disker (default 1 MB image → fused.img)"
	@./$(BUILD_DIR)/disker --force --size=1M --output=fused.img

mount: build
	@echo "==> Mounting $(BINARY) on $(MOUNTPOINT) (foreground, debug)"
	@mkdir -p $(MOUNTPOINT)
	@./$(BUILD_DIR)/$(BINARY) $(IMAGE) -f -d $(MOUNTPOINT)

unmount:
	@echo "==> Unmounting $(MOUNTPOINT)"
	@fusermount3 -u $(MOUNTPOINT) 2>/dev/null || true

check:
	@echo "==> C vs Odin struct size cross-check"
	@$(PYTHON_RUN) fused_test.suites.audit_sizes

audit:
	@echo "==> Auditing \"c\" proc callbacks for context + logger restoration"
	@$(PYTHON_RUN) fused_test.suites.audit_context

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
	$(ODIN) build $(MOUNTER_DIR) $(COLLECTIONS) -vet-shadowing -warnings-as-errors -out:/dev/null
	$(ODIN) test $(TEST_DIR) $(COLLECTIONS) $(TEST_FLAGS)

vet-unused:
	@echo "==> Checking for unused declarations"
	$(ODIN) build $(MOUNTER_DIR) $(COLLECTIONS) -vet-unused -warnings-as-errors -out:/dev/null
	$(ODIN) test $(TEST_DIR) $(COLLECTIONS) $(TEST_FLAGS)

vet-style:
	@echo "==> Checking code style"
	$(ODIN) build $(MOUNTER_DIR) $(COLLECTIONS) -vet-style -vet-semicolon -warnings-as-errors -out:/dev/null
	$(ODIN) test $(TEST_DIR) $(COLLECTIONS) $(TEST_FLAGS)

vet-cast:
	@echo "==> Checking for redundant casts"
	$(ODIN) build $(MOUNTER_DIR) $(COLLECTIONS) -vet-cast -warnings-as-errors -out:/dev/null
	$(ODIN) test $(TEST_DIR) $(COLLECTIONS) $(TEST_FLAGS)

test: run-disker
	@echo "==> Running all tests"
	$(ODIN) test $(TEST_DIR) $(COLLECTIONS) $(TEST_FLAGS) $(TIMING_FLAG)

HARNESS := PYTHONPATH=$(TEST_DIR) bash $(TEST_DIR)/run_in_namespace.sh

smoke: build run-disker
	@echo "==> Smoke test (basic FUSE ops)"
	@$(HARNESS) 60 python3 -m fused_test.suites.basic \
		--fused=build/fused --image=fused.img --mount=$(MOUNTPOINT) --logs=$(LOGS_DIR)

smoke-rw: build run-disker
	@echo "==> Smoke test (read-write + persistence)"
	@$(HARNESS) 120 python3 -m fused_test.suites.rw \
		--fused=build/fused --image=fused.img --mount=$(MOUNTPOINT) --logs=$(LOGS_DIR)

smoke-mt: build run-disker
	@echo "==> Smoke test (multi-threaded stress)"
	@$(HARNESS) 120 python3 -m fused_test.suites.stress \
		--fused=build/fused --image=fused.img --mount=$(MOUNTPOINT) --logs=$(LOGS_DIR)

smoke-errors: build run-disker
	@echo "==> Smoke test (FUSE error paths)"
	@$(HARNESS) 60 python3 -m fused_test.suites.errors \
		--fused=build/fused --image=fused.img --mount=$(MOUNTPOINT) --logs=$(LOGS_DIR)

ci: build run-disker imgdump
	@PYTHONPATH=$(TEST_DIR) python3 tests/ci.py

disker-test: run-disker
	@echo "==> Running disker + imgdump integration tests"
	@$(PYTHON_RUN) fused_test.suites.disker \
		--disker=$(BUILD_DIR)/disker --imgdump=$(BUILD_DIR)/imgdump

verify: check audit
	@echo
	@echo "==> All non-FUSE verifications passed."

verify-full: verify smoke smoke-rw

clean:
	@echo "==> Cleaning build artifacts, images, mounts, logs"
	@rm -rf $(BUILD_DIR) $(LOGS_DIR) $(MOUNTPOINT) $(IMAGE) /dev/shm/fused_test.img
	@fusermount3 -u $(MOUNTPOINT) 2>/dev/null || true

clean-logs:
	@rm -rf $(LOGS_DIR) /dev/shm/fused_test.img 2>/dev/null || true

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
	@echo "Build flags (debug):   $(BASE_DEBUG)"
	@echo "Build flags (release): $(RELEASE_FLAGS)"

help:
	@echo "fused — libfuse3 Odin FUSE daemon"
	@echo ""
	@echo "Build:"
	@echo "  all              clean + full build + test + image"
	@echo "  build            debug build -> build/$(BINARY)"
	@echo "  disker           build disker tool"
	@echo "  imgdump          build imgdump tool"
	@echo "  release          aggressive-opt build -> build/$(BINARY)_release"
	@echo "  mount            build then mount in foreground (debug, see below for flags)"
	@echo "  unmount          fusermount3 -u $(MOUNTPOINT)"
	@echo "  clean            remove build/, logs/, mnt/, fused.img, kill mount"
	@echo "  rebuild          clean && build"
	@echo ""
	@echo "Tests:"
	@echo "  test             Odin unit test suite (57 tests, requires image)"
	@echo "  disker-test      disker + imgdump integration tests (29 checks)"
	@echo "  check            C vs Odin struct size cross-check (11 structs)"
	@echo "  audit            audit \"c\" callbacks for context + logger restoration (35 callbacks)"
	@echo "  smoke            basic FUSE mount + ops test (18 checks, isolated namespace)"
	@echo "  smoke-rw         read-write + persistence test (37 checks, isolated namespace)"
	@echo "  smoke-mt         multi-threaded stress test (isolated namespace)"
	@echo "  smoke-errors     FUSE error path test (10 checks, isolated namespace)"
	@echo "  ci               build + check + audit + test + tools + all smoke tests"
	@echo "  verify           check + audit (no FUSE needed)"
	@echo "  verify-full      check + audit + all smoke tests"
	@echo ""
	@echo "Vet:"
	@echo "  vet              type-check + vet + strict-style"
	@echo "  vet-all          type-check + build + test (LLVM)"
	@echo "  vet-shadowing    variable shadowing check"
	@echo "  vet-unused       unused declarations check"
	@echo "  vet-style        code style check"
	@echo "  vet-cast         redundant cast check"
	@echo ""
	@echo "Environment:"
	@echo "  check-requires   verify Odin, fusermount3, pkg-config, /dev/fuse"
	@echo "  check-versions   print Odin + libfuse3 versions"
	@echo ""
	@echo "Logging (mount, smoke):"
	@echo "  --log-file=<path>     write logs to file (append)"
	@echo "  --log-level=<level>   filter: debug, info, warn, error (default: debug)"
	@echo "  --log-format=<fmt>    output: long (default), short, full"
	@echo ""
	@echo "Variables:"
	@echo "  MOUNTPOINT=$(MOUNTPOINT)  BUILD_DIR=$(BUILD_DIR)  IMAGE=$(IMAGE)"
	@echo "  LOGS_DIR=$(LOGS_DIR)  ODIN=$(ODIN)  THREAD_COUNT=$(THREAD_COUNT)"
	@echo "  SHOW_TIMINGS=$(SHOW_TIMINGS)  (set to 1 for compile-time breakdown)"
