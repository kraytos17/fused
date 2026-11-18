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
PJD_GROUPS    ?= chmod mkdir rename
COLLECTIONS   := -collection:src=$(SRC_DIR)
THREAD_COUNT  := $(or $(THREAD_COUNT),4)
FUSE_LINK     := -extra-linker-flags:"-lfuse3 -lpthread"
COMMON_BUILD  := -debug -o:none -warnings-as-errors \
                 -no-threaded-checker \
                 -thread-count:$(THREAD_COUNT)

BASE_DEBUG    := $(COMMON_BUILD) -use-separate-modules
FULL_BUILD    := $(COMMON_BUILD) -use-single-module
TEST_FLAGS    := $(BASE_DEBUG) -define:ODIN_TEST_THREADS=1 -define:ODIN_MOUNTER_TEST=true -define:ODIN_TEST_FAIL_ON_BAD_MEMORY=true
VET_FLAGS     := -vet -vet-shadowing -strict-style -vet-tabs -disallow-do -vet-atomic-access
SHOW_TIMINGS  := $(or $(SHOW_TIMINGS),)
TIMING_FLAG   := $(if $(SHOW_TIMINGS),-show-timings,)
ODIN_VERSION  := $(shell $(ODIN) version 2>&1 | head -1)
HARNESS       := PYTHONPATH=$(TEST_DIR) bash $(TEST_DIR)/run_in_namespace.sh
FUSE_FLAGS    := --fused=$(BUILD_DIR)/$(BINARY) --mount=$(MOUNTPOINT) --logs=$(LOGS_DIR)
PYTEST_FUSE   := uv run pytest -v --tb=short $(FUSE_FLAGS)

.PHONY: all build build-tsan format imgdump check-tool \
        create-image mount unmount \
        test pytest check check-all audit vet ci ci-nightly doctor \
        gen-trace check-trace clean-logs conformance fsx fsstress golden bench-gate model fuzz fuzz-smoke \
        sanitize tsan-smoke-mt \
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

build-tsan:
	@mkdir -p $(BUILD_DIR) $(LOGS_DIR)
	$(ODIN) build $(MOUNTER_DIR) $(COLLECTIONS) -out:$(BUILD_DIR)/$(BINARY)-tsan $(BASE_DEBUG) -sanitize:thread $(FUSE_LINK) $(TIMING_FLAG)

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

check-all:
	@$(ODIN) check src/fs src/fuse3 src/mounter src/logflags $(COLLECTIONS) -workspace -no-entry-point
	@$(ODIN) check cmd/mount cmd/format cmd/dump cmd/check tools/audit tools/gen_trace_wrappers $(COLLECTIONS) -workspace
	@$(ODIN) check $(TEST_DIR) $(COLLECTIONS) -workspace -no-entry-point -define:ODIN_MOUNTER_TEST=true

ci: build create-image imgdump
	@PYTHONPATH=$(TEST_DIR) python3 tests/ci.py

fuzz: build format check-tool imgdump
	@$(HARNESS) 1500 uv run python tests/fuzz/fuzz_image.py --iterations 300 --live --timeout 30

fuzz-smoke: build format check-tool imgdump
	@$(HARNESS) 600 uv run python tests/fuzz/fuzz_image.py --iterations 50 --live --timeout 20

ci-nightly: build create-image imgdump check-tool
	PJD_GROUPS="chflags chmod chown ftruncate granular link mkdir mkfifo mknod open posix_fallocate rename rmdir symlink truncate unlink utimensat" $(MAKE) --no-print-directory conformance
	@$(MAKE) --no-print-directory fsx
	@$(MAKE) --no-print-directory fsstress
	@$(MAKE) --no-print-directory bench-gate
	@$(MAKE) --no-print-directory tsan-smoke-mt
	@$(MAKE) --no-print-directory fuzz

bench-gate: build
	@rm -f bench.img bench.new.json
	@$(BUILD_DIR)/format --force --output=bench.img --size=16M
	@$(HARNESS) 300 python3 -m fused_test.suites.bench $(FUSE_FLAGS) --image=bench.img --size=4 --json-out=bench.new.json
	@rm -f bench.img
	@python3 tests/conformance/bench_gate.py bench/baseline.json bench.new.json --tolerance=0.15
	@rm -f bench.new.json

sanitize: create-image clean-logs
	$(ODIN) test $(TEST_DIR) $(COLLECTIONS) $(TEST_FLAGS) -sanitize:address $(TIMING_FLAG)

tsan-smoke-mt: build-tsan create-image
	@$(HARNESS) 300 python3 -m fused_test.suites.stress --fused=$(BUILD_DIR)/$(BINARY)-tsan --mount=$(MOUNTPOINT) --logs=$(LOGS_DIR) --image=$(IMAGE) --duration=15

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

conformance: build format
	@$(HARNESS) 300 bash tests/conformance/pjdfstest.sh $(PJD_GROUPS); \
	python3 tests/conformance/pjdfstest_check.py --groups="$(PJD_GROUPS)"

model: build create-image
	@$(HARNESS) 300 $(PYTEST_FUSE) tests/fuse/test_model.py --image=$(IMAGE)

golden:
	@$(ODIN) run tools/gen_golden $(COLLECTIONS) -define:ODIN_MOUNTER_TEST=true

fsx: build format check-tool
	@$(HARNESS) 300 bash tests/conformance/fsx.sh fsx

fsstress: build format check-tool
	@$(HARNESS) 300 bash tests/conformance/fsx.sh fsstress

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
	@echo "  sanitize           Odin unit tests under AddressSanitizer"
	@echo "  tsan-smoke-mt      TSan daemon + multi-threaded stress (isolated ns)"
	@echo "  clean-logs       remove logs/ + shm test image"
	@echo "  smoke            basic FUSE ops (pytest, isolated ns)"
	@echo "  smoke-rw         read-write + persistence (pytest, isolated ns)"
	@echo "  smoke-errors     error path tests (pytest, isolated ns)"
	@echo "  smoke-crash      kill -9 crash tests (pytest, isolated ns)"
	@echo "  smoke-mt         multi-threaded stress (isolated ns)"
	@echo "  bench            throughput benchmark (bench.py)"
	@echo '  conformance      pjdfstest groups (PJD_GROUPS="chmod mkdir", isolated ns)'
	@echo '  golden             regenerate tests/golden compat fixtures'
	@echo '  model              differential model test vs host reference (T-04)'
	@echo '  fuzz               structure-aware image fuzzing (offline + live)'
	@echo '  fuzz-smoke         50-iter fuzz subset for PR CI'
	@echo '  bench-gate         bench median vs baseline.json (15% tolerance)'
	@echo '  ci-nightly         full conformance + fsx/fsstress + bench-gate + tsan (long)'
	@echo '  fsx                fsx-linux content oracle x3 (isolated ns)'
	@echo '  fsstress           seeded metadata stress x3 seeds (isolated ns)'
	@echo "  ci               full CI pipeline"
	@echo "  doctor           audit + vet + image coherence check"
	@echo ""
	@echo "Vet:"
	@echo "  vet              type-check + strict-style"
	@echo "  check-all        fast multi-package odin check (no link)"
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
