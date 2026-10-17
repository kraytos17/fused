PROJECT       := fused
BINARY        := $(PROJECT)
SRC_DIR       := src
MOUNTER_DIR   := cmd/mount
FORMAT_DIR    := cmd/format
IMGDUMP_DIR   := cmd/dump
CHECK_DIR     := cmd/check
TEST_DIR      := tests
BUILD_DIR     := $(or $(BUILD_DIR),build)
LOGS_DIR      := $(or $(LOGS_DIR),logs)
ODIN          := $(or $(ODIN),odin)
MOUNTPOINT    := $(or $(MOUNTPOINT),mnt)
IMAGE         := $(or $(IMAGE),fused.img)
COLLECTIONS   := -collection:src=$(SRC_DIR)
THREAD_COUNT  := $(or $(THREAD_COUNT),4)
FUSE_LINK     := -extra-linker-flags:"-lfuse3 -lpthread"
COMMON_BUILD  := -debug -o:none -warnings-as-errors \
                 -no-threaded-checker \
                 -thread-count:$(THREAD_COUNT)

BASE_DEBUG    := $(COMMON_BUILD) -use-separate-modules
FULL_BUILD    := $(COMMON_BUILD) -use-single-module
TEST_FLAGS    := $(BASE_DEBUG) -define:ODIN_TEST_THREADS=1 -define:ODIN_MOUNTER_TEST=true
VET_FLAGS     := -vet -vet-shadowing -strict-style -vet-tabs -disallow-do
SHOW_TIMINGS  := $(or $(SHOW_TIMINGS),)
TIMING_FLAG   := $(if $(SHOW_TIMINGS),-show-timings,)
ODIN_VERSION  := $(shell $(ODIN) version 2>&1 | head -1)
HARNESS       := PYTHONPATH=$(TEST_DIR) bash $(TEST_DIR)/run_in_namespace.sh
FUSE_FLAGS    := --fused=$(BUILD_DIR)/$(BINARY) --mount=$(MOUNTPOINT) --logs=$(LOGS_DIR)
PYTEST_FUSE   := uv run pytest -v --tb=short $(FUSE_FLAGS)

.PHONY: all build format imgdump check-tool \
        create-image mount unmount \
        test pytest check audit vet ci doctor \
        gen-trace check-trace clean-logs \
        smoke smoke-rw smoke-mt smoke-errors smoke-crash bench \
        clean help

all:
	@echo "==> Full build (Odin: $(ODIN_VERSION))"
	@mkdir -p $(BUILD_DIR) $(LOGS_DIR)
	$(ODIN) build $(MOUNTER_DIR) $(COLLECTIONS) -out:$(BUILD_DIR)/$(BINARY) $(FULL_BUILD) $(FUSE_LINK) $(TIMING_FLAG)
	$(ODIN) build $(FORMAT_DIR) $(COLLECTIONS) -out:$(BUILD_DIR)/format $(FULL_BUILD) $(TIMING_FLAG)
	$(ODIN) build $(IMGDUMP_DIR) $(COLLECTIONS) -out:$(BUILD_DIR)/imgdump $(FULL_BUILD) $(TIMING_FLAG)
	$(ODIN) build $(CHECK_DIR) $(COLLECTIONS) -out:$(BUILD_DIR)/check $(FULL_BUILD) $(TIMING_FLAG)
	@./$(BUILD_DIR)/format --force --size=1M --output=$(IMAGE)
	$(ODIN) test $(TEST_DIR) $(COLLECTIONS) $(TEST_FLAGS) $(TIMING_FLAG)

build:
	@mkdir -p $(BUILD_DIR) $(LOGS_DIR)
	$(ODIN) build $(MOUNTER_DIR) $(COLLECTIONS) -out:$(BUILD_DIR)/$(BINARY) $(BASE_DEBUG) $(FUSE_LINK) $(TIMING_FLAG)

format:
	@mkdir -p $(BUILD_DIR)
	$(ODIN) build $(FORMAT_DIR) $(COLLECTIONS) -out:$(BUILD_DIR)/format $(BASE_DEBUG) $(TIMING_FLAG)

imgdump:
	@mkdir -p $(BUILD_DIR)
	$(ODIN) build $(IMGDUMP_DIR) $(COLLECTIONS) -out:$(BUILD_DIR)/imgdump $(BASE_DEBUG) $(TIMING_FLAG)

check-tool:
	@mkdir -p $(BUILD_DIR)
	$(ODIN) build $(CHECK_DIR) $(COLLECTIONS) -out:$(BUILD_DIR)/check $(BASE_DEBUG) $(TIMING_FLAG)

create-image: format
	@$(BUILD_DIR)/format --force --size=1M --output=$(IMAGE)

mount: build
	@mkdir -p $(MOUNTPOINT)
	@$(BUILD_DIR)/$(BINARY) $(IMAGE) -f -d $(MOUNTPOINT)

unmount:
	@fusermount3 -u $(MOUNTPOINT) 2>/dev/null || true

test: create-image clean-logs
	$(ODIN) test $(TEST_DIR) $(COLLECTIONS) $(TEST_FLAGS) $(TIMING_FLAG)

pytest: imgdump
	@uv run pytest tests/ -v --tb=short $(ARGS)

check:
	@mkdir -p $(BUILD_DIR)
	@$(ODIN) test $(TEST_DIR) $(COLLECTIONS) -define:ODIN_TEST_NAMES=tests.test_struct_sizes -o:none -debug > $(BUILD_DIR)/check.log 2>&1; \
	rc=$$?; grep -E "^\[(INFO|ERROR|PASS|FAIL)" $(BUILD_DIR)/check.log || true; exit $$rc

audit:
	@$(ODIN) run tools/audit/ -collection:src=src -file -- $(AUDIT_FLAGS)

gen-trace:
	@mkdir -p $(BUILD_DIR)
	@$(ODIN) run tools/gen_trace_wrappers $(COLLECTIONS) > $(BUILD_DIR)/trace_wrappers.odin
	@cp $(BUILD_DIR)/trace_wrappers.odin src/mounter/trace_wrappers.odin
	@echo "regenerated src/mounter/trace_wrappers.odin"

check-trace:
	@mkdir -p $(BUILD_DIR)
	@$(ODIN) run tools/gen_trace_wrappers $(COLLECTIONS) > $(BUILD_DIR)/trace_wrappers.check.odin
	@if diff -q src/mounter/trace_wrappers.odin $(BUILD_DIR)/trace_wrappers.check.odin > /dev/null; then \
		echo "trace_wrappers.odin: current"; \
		rm -f $(BUILD_DIR)/trace_wrappers.check.odin; \
	else \
		echo "trace_wrappers.odin: STALE - run 'make gen-trace'"; \
		diff src/mounter/trace_wrappers.odin $(BUILD_DIR)/trace_wrappers.check.odin | head -20; \
		rm -f $(BUILD_DIR)/trace_wrappers.check.odin; \
		exit 1; \
	fi

vet:
	@for d in cmd/format cmd/mount cmd/dump cmd/check; do \
		$(ODIN) build $$d $(COLLECTIONS) -warnings-as-errors $(VET_FLAGS) -out:/dev/null || exit 1; \
	done

ci: build create-image imgdump
	@PYTHONPATH=$(TEST_DIR) python3 tests/ci.py

doctor: build create-image check-tool
	@echo "==> doctor: audit --strict + vet + trace freshness + free_sectors coherence"
	@$(MAKE) --no-print-directory audit AUDIT_FLAGS=--strict
	@$(MAKE) --no-print-directory vet check check-trace
	@echo "==> doctor: image check (fused.img)"
	@./$(BUILD_DIR)/check fused.img --log-level=warn || (echo "doctor: image check FAILED"; exit 1)
	@echo "doctor: ok — image coherent"

smoke: build create-image
	@$(HARNESS) 60 $(PYTEST_FUSE) tests/fuse/test_basic.py tests/fuse/test_errors.py --image=$(IMAGE)

smoke-rw: build create-image
	@$(HARNESS) 120 $(PYTEST_FUSE) tests/fuse/test_rw.py --image=$(IMAGE)

smoke-mt: build create-image
	@$(HARNESS) 120 python3 -m fused_test.suites.stress $(FUSE_FLAGS) --image=$(IMAGE) --duration=15

smoke-errors: build create-image
	@$(HARNESS) 60 $(PYTEST_FUSE) tests/fuse/test_errors.py --image=$(IMAGE)

smoke-crash: build create-image
	@$(HARNESS) 120 $(PYTEST_FUSE) tests/fuse/test_crash.py --image=$(IMAGE)

bench: build
	@rm -f bench.img
	@$(BUILD_DIR)/format --force --output=bench.img --size=16M
	@$(HARNESS) 120 python3 -m fused_test.suites.bench $(FUSE_FLAGS) --image=bench.img --size=4
	@rm -f bench.img

clean:
	@rm -rf $(BUILD_DIR) $(LOGS_DIR) $(MOUNTPOINT) $(IMAGE) /dev/shm/fused_test.img
	@fusermount3 -u $(MOUNTPOINT) 2>/dev/null || true

clean-logs:
	@rm -rf $(LOGS_DIR) /dev/shm/fused_test.img 2>/dev/null || true

help:
	@echo "fused — libfuse3 Odin FUSE daemon"
	@echo ""
	@echo "Build:"
	@echo "  all              full build + test"
	@echo "  build            debug fused binary       -> build/fused"
	@echo "  format           image formatter          -> build/format"
	@echo "  imgdump          image inspector          -> build/imgdump"
	@echo "  check-tool       image check (fsck-like)  -> build/check"
	@echo "  gen-trace        regenerate traced wrappers -> src/mounter/trace_wrappers.odin"
	@echo "  create-image     format 1MB test image    -> fused.img"
	@echo "  mount            build + mount in foreground"
	@echo "  clean            remove build/ logs/ mnt/ fused.img"
	@echo ""
	@echo "Tests:"
	@echo "  test             Odin unit tests"
	@echo "  pytest           Python integration tests"
	@echo "  check            struct size cross-check"
	@echo "  audit            verify begin_op + attribute audits"
	@echo "  check-trace      verify generated wrappers are current"
	@echo "  clean-logs       remove logs/ + shm test image"
	@echo "  smoke            basic FUSE ops (pytest, isolated ns)"
	@echo "  smoke-rw         read-write + persistence (pytest, isolated ns)"
	@echo "  smoke-errors     error path tests (pytest, isolated ns)"
	@echo "  smoke-crash      kill -9 crash tests (pytest, isolated ns)"
	@echo "  smoke-mt         multi-threaded stress (isolated ns)"
	@echo "  bench            throughput benchmark (bench.py)"
	@echo "  ci               full CI pipeline"
	@echo "  doctor           audit + vet + image coherence check"
	@echo ""
	@echo "Vet:"
	@echo "  vet              type-check + strict-style"
	@echo ""
	@echo "Logging (mount, smoke):"
	@echo "  --log-file=<path>     write logs to file (append)"
	@echo "  --log-level=<level>   filter: debug, info, warn, error (default: debug)"
	@echo "  --log-format=<fmt>    output: long (default), short, full"
	@echo ""
	@echo "Variables:"
	@echo "  MOUNTPOINT=$(MOUNTPOINT)  BUILD_DIR=$(BUILD_DIR)  IMAGE=$(IMAGE)"
	@echo "  THREAD_COUNT=$(THREAD_COUNT)  SHOW_TIMINGS=$(SHOW_TIMINGS)"
	@echo "  ARGS='...'         extra pytest args, e.g. -m 'tool or fuse'"
	@echo "  AUDIT_FLAGS='...'  extra audit flags, e.g. --strict"
