PROJECT       := fused
BINARY        := $(PROJECT)
SRC_DIR       := src
MOUNTER_DIR   := cmd/mount
FORMAT_DIR    := cmd/format
IMGDUMP_DIR   := cmd/dump
TEST_DIR      := tests
BUILD_DIR     := $(or $(BUILD_DIR),build)
LOGS_DIR      := $(or $(LOGS_DIR),logs)
ODIN          := $(or $(ODIN),odin)
MOUNTPOINT    := $(or $(MOUNTPOINT),mnt)
IMAGE         := $(or $(IMAGE),fused.img)
COLLECTIONS   := -collection:src=$(SRC_DIR)
THREAD_COUNT  := $(or $(THREAD_COUNT),4)
FUSE_LINK     := -extra-linker-flags:"-lfuse3 -lpthread"

BASE_DEBUG    := -debug -o:none -warnings-as-errors \
                 -use-separate-modules \
                 -no-threaded-checker \
                 -thread-count:$(THREAD_COUNT)

FULL_BUILD    := -debug -o:none -warnings-as-errors \
                 -use-single-module \
                 -no-threaded-checker \
                 -thread-count:$(THREAD_COUNT)
TEST_FLAGS    := $(BASE_DEBUG) -define:ODIN_TEST_THREADS=1
VET_FLAGS     := -vet -vet-shadowing -strict-style
SHOW_TIMINGS  := $(or $(SHOW_TIMINGS),)
TIMING_FLAG   := $(if $(SHOW_TIMINGS),-show-timings,)
ODIN_VERSION  := $(shell $(ODIN) version 2>&1 | head -1)
HARNESS       := PYTHONPATH=$(TEST_DIR) bash $(TEST_DIR)/run_in_namespace.sh

.PHONY: all build format imgdump \
        create-image mount unmount \
        test pytest check audit vet ci \
        smoke smoke-rw smoke-mt smoke-errors \
        clean help

all:
	@echo "==> Full build (Odin: $(ODIN_VERSION))"
	@mkdir -p $(BUILD_DIR) $(LOGS_DIR)
	$(ODIN) build $(MOUNTER_DIR) $(COLLECTIONS) -out:$(BUILD_DIR)/$(BINARY) $(FULL_BUILD) $(FUSE_LINK) $(TIMING_FLAG)
	$(ODIN) build $(FORMAT_DIR) $(COLLECTIONS) -out:$(BUILD_DIR)/format $(FULL_BUILD) $(TIMING_FLAG)
	$(ODIN) build $(IMGDUMP_DIR) $(COLLECTIONS) -out:$(BUILD_DIR)/imgdump $(FULL_BUILD) $(TIMING_FLAG)
	@./$(BUILD_DIR)/format --force --size=1M --output=fused.img
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

create-image: format
	@$(BUILD_DIR)/format --force --size=1M --output=fused.img

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
	@$(ODIN) test $(TEST_DIR) $(COLLECTIONS) -define:ODIN_TEST_NAMES=tests.test_struct_sizes -o:none -debug 2>&1 | grep -E "^\[(INFO|ERROR|PASS|FAIL)" || true

audit:
	@odin run tools/audit/ -collection:src=src -file

vet:
	@for d in cmd/format cmd/mount; do \
		$(ODIN) build $$d $(COLLECTIONS) -warnings-as-errors $(VET_FLAGS) -out:/dev/null || exit 1; \
	done

ci: build create-image imgdump
	@PYTHONPATH=$(TEST_DIR) python3 tests/ci.py

smoke: build create-image
	@$(HARNESS) 60 uv run pytest tests/test_basic.py tests/test_errors.py \
		-v --tb=short \
		--fused=build/fused --image=fused.img --mount=$(MOUNTPOINT) --logs=$(LOGS_DIR)

smoke-rw: build create-image
	@$(HARNESS) 120 uv run pytest tests/test_rw.py \
		-v --tb=short \
		--fused=build/fused --image=fused.img --mount=$(MOUNTPOINT) --logs=$(LOGS_DIR)

smoke-mt: build create-image
	@$(HARNESS) 120 python3 -m fused_test.suites.stress \
		--fused=build/fused --image=fused.img --mount=$(MOUNTPOINT) --logs=$(LOGS_DIR) --stress-duration=15

smoke-errors: build create-image
	@$(HARNESS) 60 uv run pytest tests/test_errors.py \
		-v --tb=short \
		--fused=build/fused --image=fused.img --mount=$(MOUNTPOINT) --logs=$(LOGS_DIR)

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
	@echo "  create-image     format 1MB test image    -> fused.img"
	@echo "  mount            build + mount in foreground"
	@echo "  clean            remove build/ logs/ mnt/ fused.img"
	@echo ""
	@echo "Tests:"
	@echo "  test             Odin unit tests (63)"
	@echo "  pytest           Python integration tests (48)"
	@echo "  check            struct size cross-check"
	@echo "  audit            verify begin_op usage (35 callbacks)"
	@echo "  smoke            basic FUSE ops (pytest, isolated ns)"
	@echo "  smoke-rw         read-write + persistence (pytest, isolated ns)"
	@echo "  smoke-errors     error path tests (pytest, isolated ns)"
	@echo "  smoke-mt         multi-threaded stress (isolated ns)"
	@echo "  ci               full CI pipeline"
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
