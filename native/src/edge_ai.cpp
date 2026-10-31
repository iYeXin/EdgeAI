#include "edge_ai.h"

#include "llama.h"
#include "ggml-backend.h"
#include "ggml.h"
#include "chat.h"
#include "mtmd.h"
#include "mtmd-helper.h"

#include <android/log.h>
#include <sys/system_properties.h>
#include <sys/stat.h>
#include <unistd.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <memory>
#include <mutex>
#include <random>
#include <string>
#include <vector>

#define LOG_TAG "EdgeAI"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, LOG_TAG, __VA_ARGS__)
#define LOGW(...) __android_log_print(ANDROID_LOG_WARN, LOG_TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)

struct edge_ai_handle {
    llama_model * model = nullptr;
    llama_context * ctx = nullptr;
    llama_sampler * sampler = nullptr;
    const llama_vocab * vocab = nullptr;
    mtmd_context * mtmd_ctx = nullptr;
    bool vision = false;
    common_chat_templates_ptr templates;

    std::mutex mutex;
    std::atomic<bool> cancel{false};

    bool loaded = false;
    bool generating = false;
    bool done = true;

    int n_ctx = 0;
    int n_ctx_train = 0;
    int n_batch = 512;
    int n_ubatch = 512;
    int n_threads = 4;
    int n_gpu_layers = 0;
    int32_t kv_type_k = GGML_TYPE_F16;
    int32_t kv_type_v = GGML_TYPE_F16;

    uint64_t model_bytes = 0;
    uint64_t kv_bytes_per_token = 0;
    uint64_t kv_bytes = 0;
    uint64_t budget_bytes = 0;
    uint64_t reserve_bytes = 0;
    uint64_t compute_margin_bytes = 0;
    int32_t recommended_ctx = 0;

    std::string backend;
    std::string desc;
    std::string arch;
    std::string last_error;

    double load_ms = 0.0;
    double prefill_ms = 0.0;
    double decode_ms = 0.0;
    int prompt_tokens = 0;
    int generated_tokens = 0;
    int max_tokens = 0;
    llama_pos n_past = 0;
    int32_t stop_reason = EDGE_AI_STOP_NONE;

    std::vector<std::string> stop_sequences;
    std::string pending;
    size_t holdback = 0;
    bool ignore_eos = false;
    std::vector<llama_token> state_tokens;
    std::vector<llama_pos> state_positions;
    std::vector<std::string> state_image_ids;
    llama_pos state_n_past = 0;
    bool state_loaded = false;
    std::chrono::steady_clock::time_point last_sample_time;
};

namespace {

constexpr uint64_t MB = 1024ull * 1024ull;
constexpr uint64_t GB = 1024ull * MB;
constexpr uint64_t kDefaultReserve = 768ull * MB;
constexpr int kDefaultMaxCtx = 8192;
constexpr int kWarmupTokens = 128;
constexpr int kMaxPromptBytes = 64 * 1024 * 1024;

struct MemInfo {
    uint64_t total = 0;
    uint64_t avail = 0;
};

void set_error(char * err, int32_t err_len, const char * msg) {
    if (err && err_len > 0) {
        std::snprintf(err, static_cast<size_t>(err_len), "%s", msg ? msg : "");
    }
}

void set_error(edge_ai_handle * h, char * err, int32_t err_len, const char * msg) {
    if (h) h->last_error = msg ? msg : "";
    set_error(err, err_len, msg);
}

bool read_meminfo(MemInfo & info) {
    std::ifstream file("/proc/meminfo");
    if (!file) return false;
    std::string key;
    uint64_t value = 0;
    std::string unit;
    while (file >> key >> value >> unit) {
        if (key == "MemTotal:") info.total = value * 1024ull;
        else if (key == "MemAvailable:") info.avail = value * 1024ull;
    }
    return info.total > 0;
}

uint64_t read_rss_bytes() {
    std::ifstream file("/proc/self/statm");
    uint64_t total_pages = 0;
    uint64_t resident_pages = 0;
    if (!(file >> total_pages >> resident_pages)) return 0;
    const long page = sysconf(_SC_PAGESIZE);
    return resident_pages * static_cast<uint64_t>(page > 0 ? page : 4096);
}

uint64_t read_peak_rss_bytes() {
    std::ifstream file("/proc/self/status");
    std::string key;
    while (file >> key) {
        if (key == "VmHWM:") {
            uint64_t kb = 0;
            std::string unit;
            file >> kb >> unit;
            return kb * 1024ull;
        }
        std::string rest;
        std::getline(file, rest);
    }
    return 0;
}

bool is_mediatek_soc() {
    char manufacturer[PROP_VALUE_MAX] = {0};
    if (__system_property_get("ro.soc.manufacturer", manufacturer) > 0) {
        if (std::strstr(manufacturer, "Mediatek") || std::strstr(manufacturer, "MediaTek")) {
            return true;
        }
    }
    return false;
}

std::string dev_label(ggml_backend_dev_t dev) {
    const char * name = ggml_backend_dev_name(dev);
    const char * desc = ggml_backend_dev_description(dev);
    const char * type = "other";
    switch (ggml_backend_dev_type(dev)) {
        case GGML_BACKEND_DEVICE_TYPE_CPU:  type = "cpu";  break;
        case GGML_BACKEND_DEVICE_TYPE_GPU:  type = "gpu";  break;
        case GGML_BACKEND_DEVICE_TYPE_IGPU: type = "igpu"; break;
        case GGML_BACKEND_DEVICE_TYPE_ACCEL:type = "accel";break;
        default: break;
    }
    std::string out = name ? name : "unknown";
    out += ": ";
    out += desc ? desc : "unknown";
    out += " [";
    out += type;
    out += "]";
    return out;
}

std::string device_list() {
    std::string out;
    const size_t count = ggml_backend_dev_count();
    for (size_t i = 0; i < count; ++i) {
        if (!out.empty()) out += ", ";
        out += dev_label(ggml_backend_dev_get(i));
    }
    return out;
}

std::string active_device(int n_gpu_layers) {
    const size_t count = ggml_backend_dev_count();
    for (size_t i = 0; i < count; ++i) {
        ggml_backend_dev_t dev = ggml_backend_dev_get(i);
        const auto type = ggml_backend_dev_type(dev);
        const bool gpu = type == GGML_BACKEND_DEVICE_TYPE_GPU || type == GGML_BACKEND_DEVICE_TYPE_IGPU;
        if (n_gpu_layers > 0 && gpu) return dev_label(dev);
        if (n_gpu_layers <= 0 && type == GGML_BACKEND_DEVICE_TYPE_CPU) return dev_label(dev);
    }
    return device_list();
}

ggml_type parse_kv_type(int32_t value) {
    if (value <= 0) return GGML_TYPE_F16;
    if (value >= GGML_TYPE_COUNT) return GGML_TYPE_F16;
    return static_cast<ggml_type>(value);
}

uint64_t kv_bytes_per_token(const llama_model * model, ggml_type type_k, ggml_type type_v) {
    const int n_layer = llama_model_n_layer(model);
    const int n_head = std::max(1, llama_model_n_head(model));
    const int n_head_kv = std::max(1, llama_model_n_head_kv(model));
    const int n_embd = llama_model_n_embd(model);
    const int head_dim = std::max(1, n_embd / n_head);

    const uint64_t bytes_k = ggml_type_size(type_k) / std::max<uint64_t>(1, ggml_blck_size(type_k));
    const uint64_t bytes_v = ggml_type_size(type_v) / std::max<uint64_t>(1, ggml_blck_size(type_v));

    return static_cast<uint64_t>(n_layer) * n_head_kv * head_dim * (bytes_k + bytes_v);
}

int count_tokens(const llama_vocab * vocab, const std::string & text) {
    if (text.empty()) return 0;
    int32_t n = llama_tokenize(vocab, text.data(), static_cast<int32_t>(text.size()), nullptr, 0, false, true);
    if (n < 0) n = -n;
    return n;
}

bool ends_with(const std::string & value, const std::string & suffix) {
    return suffix.size() <= value.size() &&
           value.compare(value.size() - suffix.size(), suffix.size(), suffix) == 0;
}

int clamp_ctx(int value, int min_value, int max_value) {
    if (max_value < min_value) max_value = min_value;
    return std::max(min_value, std::min(value, max_value));
}

} // namespace

extern "C" {

uint32_t edge_ai_abi_version(void) {
    return EDGE_AI_ABI_VERSION;
}

const char * edge_ai_status_string(int32_t status) {
    switch (status) {
        case EDGE_AI_OK: return "ok";
        case EDGE_AI_ERR_INVALID_ARGUMENT: return "invalid argument";
        case EDGE_AI_ERR_NOT_LOADED: return "model not loaded";
        case EDGE_AI_ERR_BUSY: return "busy";
        case EDGE_AI_ERR_OUT_OF_MEMORY: return "out of memory";
        case EDGE_AI_ERR_CONTEXT_OVERFLOW: return "context overflow";
        case EDGE_AI_ERR_BACKEND: return "backend error";
        case EDGE_AI_ERR_CANCELLED: return "cancelled";
        case EDGE_AI_ERR_IO: return "io error";
        case EDGE_AI_ERR_UNSUPPORTED: return "unsupported";
        case EDGE_AI_ERR_BUFFER_TOO_SMALL: return "buffer too small";
        case EDGE_AI_ERR_INTERNAL: return "internal error";
        default: return "unknown";
    }
}

const char * edge_ai_stop_reason_string(int32_t reason) {
    switch (reason) {
        case EDGE_AI_STOP_NONE: return "none";
        case EDGE_AI_STOP_EOS: return "eos";
        case EDGE_AI_STOP_MAX_TOKENS: return "max_tokens";
        case EDGE_AI_STOP_SEQUENCE: return "stop_sequence";
        case EDGE_AI_STOP_CANCELLED: return "cancelled";
        case EDGE_AI_STOP_ERROR: return "error";
        default: return "unknown";
    }
}

void edge_ai_config_defaults(edge_ai_config * config) {
    if (!config) return;
    std::memset(config, 0, sizeof(*config));
    config->struct_size = sizeof(edge_ai_config);
    config->backend = EDGE_AI_BACKEND_AUTO;
    config->n_gpu_layers = -1;
    config->n_ctx = 0;
    config->n_batch = 512;
    config->n_ubatch = 512;
    config->n_threads = 4;
    config->n_threads_batch = 0;
    config->flash_attn = -1;
    config->use_mmap = 1;
    config->use_mlock = 0;
    config->allow_cpu_fallback = 1;
    config->strict_memory = 0;
    config->kv_type_k = 0;
    config->kv_type_v = 0;
    config->min_ctx = 512;
    config->max_ctx = kDefaultMaxCtx;
}

static edge_ai_status load_model(edge_ai_handle * h, const edge_ai_config & config, char * err, int32_t err_len);
static edge_ai_status create_context(edge_ai_handle * h, int chosen_ctx, char * err, int32_t err_len);
static void clear_model(edge_ai_handle * h);

edge_ai_status edge_ai_create_ex(const edge_ai_config * config,
                                 edge_ai_handle ** out_handle,
                                 char * err, int32_t err_len) {
    if (!config || !out_handle) {
        set_error(err, err_len, "config or output handle is null");
        return EDGE_AI_ERR_INVALID_ARGUMENT;
    }
    if (config->struct_size < sizeof(edge_ai_config)) {
        set_error(err, err_len, "config struct_size is too small");
        return EDGE_AI_ERR_INVALID_ARGUMENT;
    }
    if (!config->model_path || config->model_path[0] == '\0') {
        set_error(err, err_len, "model path is empty");
        return EDGE_AI_ERR_INVALID_ARGUMENT;
    }

    static std::once_flag backend_once;
    std::call_once(backend_once, [] {
        if (is_mediatek_soc() && std::getenv("GGML_VK_DISABLE_COOPMAT") == nullptr) {
            setenv("GGML_VK_DISABLE_COOPMAT", "1", 0);
            LOGI("MediaTek GPU detected: GGML_VK_DISABLE_COOPMAT=1");
        }
        llama_log_set([](enum ggml_log_level level, const char * text, void *) {
            int prio = ANDROID_LOG_INFO;
            if (level == GGML_LOG_LEVEL_ERROR) prio = ANDROID_LOG_ERROR;
            else if (level == GGML_LOG_LEVEL_WARN) prio = ANDROID_LOG_WARN;
            else if (level == GGML_LOG_LEVEL_DEBUG) prio = ANDROID_LOG_DEBUG;
            __android_log_write(prio, "llama", text);
        }, nullptr);
        llama_backend_init();
        LOGI("llama.cpp %s", llama_version());
        LOGI("devices: %s", device_list().c_str());
    });

    auto * h = new (std::nothrow) edge_ai_handle();
    if (!h) {
        set_error(err, err_len, "cannot allocate engine handle");
        return EDGE_AI_ERR_OUT_OF_MEMORY;
    }

    std::lock_guard<std::mutex> lock(h->mutex);
    const edge_ai_status status = load_model(h, *config, err, err_len);
    if (status != EDGE_AI_OK) {
        clear_model(h);
        delete h;
        return status;
    }
    *out_handle = h;
    return EDGE_AI_OK;
}

static edge_ai_status load_model(edge_ai_handle * h, const edge_ai_config & config, char * err, int32_t err_len) {
    const auto t0 = std::chrono::steady_clock::now();

    int n_gpu_layers = config.n_gpu_layers;
    if (config.backend == EDGE_AI_BACKEND_CPU) {
        n_gpu_layers = 0;
    } else if (n_gpu_layers < 0) {
        n_gpu_layers = 99;
    }

    if (n_gpu_layers > 0 &&
        ggml_backend_dev_by_type(GGML_BACKEND_DEVICE_TYPE_GPU) == nullptr &&
        ggml_backend_dev_by_type(GGML_BACKEND_DEVICE_TYPE_IGPU) == nullptr) {
        LOGW("no Vulkan GPU device available, using CPU");
        n_gpu_layers = 0;
    }

    const ggml_type type_k = parse_kv_type(config.kv_type_k);
    const ggml_type type_v = parse_kv_type(config.kv_type_v);

    h->n_gpu_layers = n_gpu_layers;
    h->n_batch = config.n_batch > 0 ? config.n_batch : 512;
    h->n_ubatch = config.n_ubatch > 0 ? config.n_ubatch : h->n_batch;
    h->n_threads = config.n_threads > 0 ? config.n_threads : 4;
    h->kv_type_k = type_k;
    h->kv_type_v = type_v;

    auto load_attempt = [&](int ngl) -> bool {
        llama_model_params mparams = llama_model_default_params();
        mparams.n_gpu_layers = ngl;
        mparams.main_gpu = 0;
        mparams.split_mode = LLAMA_SPLIT_MODE_NONE;
        if (config.use_mlock) {
            mparams.load_mode = LLAMA_LOAD_MODE_MMAP_MLOCK;
        } else if (config.use_mmap) {
            mparams.load_mode = LLAMA_LOAD_MODE_MMAP;
        } else {
            mparams.load_mode = LLAMA_LOAD_MODE_NONE;
        }

        static ggml_backend_dev_t cpu_only_devices[2] = {nullptr, nullptr};
        if (ngl <= 0) {
            cpu_only_devices[0] = ggml_backend_dev_by_type(GGML_BACKEND_DEVICE_TYPE_CPU);
            if (cpu_only_devices[0] != nullptr) mparams.devices = cpu_only_devices;
        }

        mparams.progress_callback = [](float progress, void * user_data) {
            auto * handle = static_cast<edge_ai_handle *>(user_data);
            static thread_local int last = -1;
            const int pct = static_cast<int>(progress * 100.0f);
            if (pct / 10 != last) {
                last = pct / 10;
                LOGI("load %d%%", pct);
            }
            return handle ? !handle->cancel.load() : true;
        };
        mparams.progress_callback_user_data = h;

        LOGI("loading model: %s (ngl=%d)", config.model_path, ngl);
        h->model = llama_model_load_from_file(config.model_path, mparams);
        if (!h->model) return false;

        h->n_gpu_layers = ngl;
        h->n_ctx_train = llama_model_n_ctx_train(h->model);
        h->model_bytes = llama_model_size(h->model);
        h->kv_bytes_per_token = kv_bytes_per_token(h->model, type_k, type_v);
        h->desc = "unknown";
        char desc[256] = {0};
        if (llama_model_desc(h->model, desc, sizeof(desc)) > 0) h->desc = desc;
        char arch[64] = {0};
        if (llama_model_meta_val_str(h->model, "general.architecture", arch, sizeof(arch)) > 0) {
            h->arch = arch;
        }
        h->backend = active_device(ngl);
        return true;
    };

    MemInfo mem0;
    read_meminfo(mem0);
    h->reserve_bytes = config.memory_reserve_bytes > 0
                           ? config.memory_reserve_bytes
                           : std::max<uint64_t>(kDefaultReserve, mem0.total / 16);
    h->budget_bytes = config.memory_budget_bytes > 0
                          ? std::min<uint64_t>(config.memory_budget_bytes,
                                               mem0.total > 0 ? mem0.total : config.memory_budget_bytes)
                          : (mem0.avail > 0 ? mem0.avail : mem0.total);

    struct stat st {};
    if (stat(config.model_path, &st) == 0 && st.st_size > 0 &&
        static_cast<uint64_t>(st.st_size) + h->reserve_bytes > h->budget_bytes) {
        set_error(h, err, err_len, "model does not fit in the memory budget");
        return EDGE_AI_ERR_OUT_OF_MEMORY;
    }

    if (!load_attempt(n_gpu_layers)) {
        if (n_gpu_layers > 0 && config.allow_cpu_fallback) {
            LOGW("GPU model load failed, retrying on CPU");
            h->model = nullptr;
            n_gpu_layers = 0;
            if (!load_attempt(0)) {
                set_error(h, err, err_len, "failed to load model on GPU and CPU");
                return EDGE_AI_ERR_OUT_OF_MEMORY;
            }
        } else {
            set_error(h, err, err_len, "failed to load model");
            return EDGE_AI_ERR_IO;
        }
    }

    MemInfo mem;
    read_meminfo(mem);

    if (h->model_bytes + h->reserve_bytes > h->budget_bytes) {
        set_error(h, err, err_len, "model weights exceed the memory budget");
        return EDGE_AI_ERR_OUT_OF_MEMORY;
    }

    const int max_ctx_limit = config.max_ctx > 0
                                  ? std::min(config.max_ctx, h->n_ctx_train > 0 ? h->n_ctx_train : config.max_ctx)
                                  : std::min(h->n_ctx_train > 0 ? h->n_ctx_train : kDefaultMaxCtx, kDefaultMaxCtx);
    const int min_ctx = std::max(64, config.min_ctx > 0 ? config.min_ctx : 512);

    const uint64_t fixed = h->model_bytes + h->reserve_bytes;
    uint64_t usable = h->budget_bytes > fixed ? h->budget_bytes - fixed : 0;
    // Leave room for graph/compute buffers and allocator fragmentation.
    // The last few percent are where "fits exactly" turns into a failed load.
    const uint64_t kv_safety = std::max<uint64_t>(64ull << 20, usable / 20);
    usable = usable > kv_safety ? usable - kv_safety : 0;
    const int kv_ctx = h->kv_bytes_per_token > 0
                           ? static_cast<int>(std::min<uint64_t>(usable / h->kv_bytes_per_token, 1u << 20))
                           : max_ctx_limit;
    h->recommended_ctx = clamp_ctx(kv_ctx, min_ctx, max_ctx_limit);
    h->compute_margin_bytes = h->reserve_bytes;

    int chosen_ctx = h->recommended_ctx;
    if (config.n_ctx > 0) {
        chosen_ctx = std::min(config.n_ctx, max_ctx_limit);
        if (chosen_ctx > h->recommended_ctx) {
            if (config.strict_memory) {
                set_error(h, err, err_len, "requested context exceeds memory budget");
                return EDGE_AI_ERR_OUT_OF_MEMORY;
            }
            LOGW("reducing n_ctx from %d to %d to fit memory budget", chosen_ctx, h->recommended_ctx);
            chosen_ctx = h->recommended_ctx;
        }
    }

    if (chosen_ctx < min_ctx) {
        set_error(h, err, err_len, "memory budget too small for minimum context");
        return EDGE_AI_ERR_OUT_OF_MEMORY;
    }

    while (chosen_ctx >= min_ctx) {
        if (create_context(h, chosen_ctx, err, err_len) == EDGE_AI_OK) break;
        chosen_ctx /= 2;
        if (chosen_ctx < min_ctx) break;
        LOGW("context creation failed, retrying with n_ctx=%d", chosen_ctx);
    }

    if (!h->ctx) {
        if (h->n_gpu_layers > 0 && config.allow_cpu_fallback) {
            LOGW("GPU context failed, falling back to CPU");
            clear_model(h);
            n_gpu_layers = 0;
            h->n_gpu_layers = 0;
            if (!load_attempt(0) || create_context(h, std::min(h->recommended_ctx, max_ctx_limit), err, err_len) != EDGE_AI_OK) {
                set_error(h, err, err_len, "failed to create context on GPU and CPU");
                return EDGE_AI_ERR_OUT_OF_MEMORY;
            }
        } else {
            set_error(h, err, err_len, "failed to create context");
            return EDGE_AI_ERR_OUT_OF_MEMORY;
        }
    }

    h->vocab = llama_model_get_vocab(h->model);
    h->n_ctx = static_cast<int>(llama_n_ctx(h->ctx));
    h->kv_bytes = h->kv_bytes_per_token * static_cast<uint64_t>(h->n_ctx);
    h->loaded = true;
    h->done = true;

    try {
        h->templates = common_chat_templates_init(h->model, "");
    } catch (const std::exception & ex) {
        LOGW("chat template init failed: %s", ex.what());
    }

    if (h->n_gpu_layers > 0) {
        const auto w0 = std::chrono::steady_clock::now();
        llama_token warm_token = 0;
        if (llama_tokenize(h->vocab, "Hello", 5, &warm_token, 1, false, false) <= 0) warm_token = 0;
        const int warm_n = std::min(kWarmupTokens, h->n_ctx);
        std::vector<llama_token> warm(static_cast<size_t>(warm_n), warm_token);
        bool warm_ok = true;
        for (int i = 0; i < warm_n; i += 512) {
            llama_batch batch = llama_batch_get_one(warm.data() + i, std::min(512, warm_n - i));
            if (llama_decode(h->ctx, batch) != 0) {
                warm_ok = false;
                break;
            }
        }
        llama_synchronize(h->ctx);
        llama_memory_clear(llama_get_memory(h->ctx), true);
        const auto w1 = std::chrono::steady_clock::now();
        LOGI("warmup prefill %d tokens: %.0f ms (%s)", warm_n,
             std::chrono::duration<double, std::milli>(w1 - w0).count(), warm_ok ? "ok" : "failed");
    }

    const auto t1 = std::chrono::steady_clock::now();
    h->load_ms = std::chrono::duration<double, std::milli>(t1 - t0).count();
    LOGI("model ready: ctx=%d, load=%.0f ms, backend=%s", h->n_ctx, h->load_ms, h->backend.c_str());
    return EDGE_AI_OK;
}

static edge_ai_status create_context(edge_ai_handle * h, int chosen_ctx, char * err, int32_t err_len) {
    llama_context_params cparams = llama_context_default_params();
    cparams.n_ctx = static_cast<uint32_t>(chosen_ctx);
    cparams.n_batch = static_cast<uint32_t>(h->n_batch);
    cparams.n_ubatch = static_cast<uint32_t>(h->n_ubatch);
    cparams.n_threads = h->n_threads;
    cparams.n_threads_batch = h->n_threads;
    cparams.flash_attn_type = LLAMA_FLASH_ATTN_TYPE_AUTO;
    cparams.type_k = static_cast<ggml_type>(h->kv_type_k);
    cparams.type_v = static_cast<ggml_type>(h->kv_type_v);
    cparams.offload_kqv = h->n_gpu_layers > 0;
    cparams.op_offload = h->n_gpu_layers > 0;
    cparams.no_perf = true;

    h->ctx = llama_init_from_model(h->model, cparams);
    if (!h->ctx) {
        set_error(h, err, err_len, "llama_init_from_model failed (out of memory)");
        return EDGE_AI_ERR_OUT_OF_MEMORY;
    }
    h->n_ctx = static_cast<int>(llama_n_ctx(h->ctx));
    h->kv_bytes = h->kv_bytes_per_token * static_cast<uint64_t>(h->n_ctx);
    return EDGE_AI_OK;
}

static void clear_model(edge_ai_handle * h) {
    if (!h) return;
    if (h->sampler) {
        llama_sampler_free(h->sampler);
        h->sampler = nullptr;
    }
    if (h->mtmd_ctx) {
        mtmd_free(h->mtmd_ctx);
        h->mtmd_ctx = nullptr;
    }
    h->vision = false;
    if (h->ctx) {
        llama_free(h->ctx);
        h->ctx = nullptr;
    }
    h->templates.reset();
    if (h->model) {
        llama_model_free(h->model);
        h->model = nullptr;
    }
    h->vocab = nullptr;
    h->state_tokens.clear();
    h->state_positions.clear();
    h->state_image_ids.clear();
    h->state_n_past = 0;
    h->state_loaded = false;
    h->loaded = false;
    h->generating = false;
    h->done = true;
}

edge_ai_status edge_ai_unload(edge_ai_handle * h) {
    if (!h) return EDGE_AI_ERR_INVALID_ARGUMENT;
    std::lock_guard<std::mutex> lock(h->mutex);
    if (h->generating) return EDGE_AI_ERR_BUSY;
    clear_model(h);
    return EDGE_AI_OK;
}

edge_ai_status edge_ai_state_get_size(edge_ai_handle * h, uint64_t * out_bytes) {
    if (!h || !out_bytes) return EDGE_AI_ERR_INVALID_ARGUMENT;
    std::lock_guard<std::mutex> lock(h->mutex);
    if (!h->loaded || !h->ctx) return EDGE_AI_ERR_NOT_LOADED;
    if (h->generating) return EDGE_AI_ERR_BUSY;
    *out_bytes = static_cast<uint64_t>(llama_state_get_size(h->ctx));
    return EDGE_AI_OK;
}

static bool write_state_meta(const std::string & path, const edge_ai_handle * h) {
    std::ofstream out(path, std::ios::binary | std::ios::trunc);
    if (!out) return false;
    const uint32_t magic = 0x45414953;
    const uint32_t version = 1;
    out.write(reinterpret_cast<const char *>(&magic), sizeof(magic));
    out.write(reinterpret_cast<const char *>(&version), sizeof(version));
    const uint64_t n_past = static_cast<uint64_t>(h->state_n_past);
    out.write(reinterpret_cast<const char *>(&n_past), sizeof(n_past));
    const uint32_t n_images = static_cast<uint32_t>(h->state_image_ids.size());
    out.write(reinterpret_cast<const char *>(&n_images), sizeof(n_images));
    for (const auto & id : h->state_image_ids) {
        const uint32_t len = static_cast<uint32_t>(id.size());
        out.write(reinterpret_cast<const char *>(&len), sizeof(len));
        out.write(id.data(), len);
    }
    const uint32_t n_tokens = static_cast<uint32_t>(h->state_tokens.size());
    out.write(reinterpret_cast<const char *>(&n_tokens), sizeof(n_tokens));
    out.write(reinterpret_cast<const char *>(h->state_tokens.data()),
              sizeof(llama_token) * h->state_tokens.size());
    out.write(reinterpret_cast<const char *>(h->state_positions.data()),
              sizeof(llama_pos) * h->state_positions.size());
    return out.good();
}

static bool read_state_meta(const std::string & path, edge_ai_handle * h) {
    std::ifstream in(path, std::ios::binary);
    if (!in) return false;
    uint32_t magic = 0, version = 0;
    in.read(reinterpret_cast<char *>(&magic), sizeof(magic));
    in.read(reinterpret_cast<char *>(&version), sizeof(version));
    if (!in || magic != 0x45414953 || version != 1) return false;
    uint64_t n_past = 0;
    in.read(reinterpret_cast<char *>(&n_past), sizeof(n_past));
    uint32_t n_images = 0;
    in.read(reinterpret_cast<char *>(&n_images), sizeof(n_images));
    if (!in || n_images > 64) return false;
    std::vector<std::string> ids;
    ids.reserve(n_images);
    for (uint32_t i = 0; i < n_images; ++i) {
        uint32_t len = 0;
        in.read(reinterpret_cast<char *>(&len), sizeof(len));
        if (!in || len > 4096) return false;
        std::string id(len, '\0');
        in.read(id.data(), len);
        if (!in) return false;
        ids.push_back(std::move(id));
    }
    uint32_t n_tokens = 0;
    in.read(reinterpret_cast<char *>(&n_tokens), sizeof(n_tokens));
    if (!in || n_tokens > static_cast<uint32_t>(h->n_ctx)) return false;
    std::vector<llama_token> tokens(n_tokens);
    in.read(reinterpret_cast<char *>(tokens.data()), sizeof(llama_token) * n_tokens);
    if (!in) return false;
    std::vector<llama_pos> positions(n_tokens);
    in.read(reinterpret_cast<char *>(positions.data()), sizeof(llama_pos) * n_tokens);
    if (!in) return false;
    h->state_tokens = std::move(tokens);
    h->state_positions = std::move(positions);
    h->state_image_ids = std::move(ids);
    h->state_n_past = static_cast<llama_pos>(n_past);
    return true;
}

edge_ai_status edge_ai_state_save(edge_ai_handle * h, const char * path,
                                  char * err, int32_t err_len) {
    if (!h || !path || path[0] == '\0') return EDGE_AI_ERR_INVALID_ARGUMENT;
    std::lock_guard<std::mutex> lock(h->mutex);
    if (!h->loaded || !h->ctx) return EDGE_AI_ERR_NOT_LOADED;
    if (h->generating) return EDGE_AI_ERR_BUSY;
    if (h->state_tokens.empty()) {
        set_error(h, err, err_len, "no state tokens to save");
        return EDGE_AI_ERR_INVALID_ARGUMENT;
    }
    const std::string tmp = std::string(path) + ".tmp";
    if (!llama_state_save_file(h->ctx, tmp.c_str(), h->state_tokens.data(), h->state_tokens.size())) {
        set_error(h, err, err_len, "llama_state_save_file failed");
        return EDGE_AI_ERR_IO;
    }
    const std::string meta_tmp = std::string(path) + ".meta.tmp";
    if (!write_state_meta(meta_tmp, h)) {
        set_error(h, err, err_len, "write state meta failed");
        std::remove(tmp.c_str());
        std::remove(meta_tmp.c_str());
        return EDGE_AI_ERR_IO;
    }
    std::remove(path);
    if (std::rename(tmp.c_str(), path) != 0) {
        set_error(h, err, err_len, "rename state file failed");
        std::remove(tmp.c_str());
        std::remove(meta_tmp.c_str());
        return EDGE_AI_ERR_IO;
    }
    const std::string meta_path = std::string(path) + ".meta";
    std::remove(meta_path.c_str());
    if (std::rename(meta_tmp.c_str(), meta_path.c_str()) != 0) {
        set_error(h, err, err_len, "rename state meta failed");
        std::remove(meta_tmp.c_str());
        return EDGE_AI_ERR_IO;
    }
    LOGI("state saved: %s (%zu text tokens, %zu images, n_past=%d)",
         path, h->state_tokens.size(), h->state_image_ids.size(), h->state_n_past);
    return EDGE_AI_OK;
}

edge_ai_status edge_ai_state_load(edge_ai_handle * h, const char * path,
                                  char * err, int32_t err_len) {
    if (!h || !path || path[0] == '\0') return EDGE_AI_ERR_INVALID_ARGUMENT;
    std::lock_guard<std::mutex> lock(h->mutex);
    if (!h->loaded || !h->ctx) return EDGE_AI_ERR_NOT_LOADED;
    if (h->generating) return EDGE_AI_ERR_BUSY;
    std::vector<llama_token> tokens(static_cast<size_t>(h->n_ctx));
    size_t n_token_count = 0;
    llama_memory_clear(llama_get_memory(h->ctx), true);
    h->state_tokens.clear();
    h->state_positions.clear();
    h->state_image_ids.clear();
    h->state_n_past = 0;
    h->state_loaded = false;
    if (!llama_state_load_file(h->ctx, path, tokens.data(), tokens.size(), &n_token_count)) {
        set_error(h, err, err_len, "llama_state_load_file failed");
        return EDGE_AI_ERR_IO;
    }
    if (n_token_count == 0 || n_token_count > static_cast<size_t>(h->n_ctx)) {
        set_error(h, err, err_len, "invalid state token count");
        return EDGE_AI_ERR_IO;
    }
    h->state_tokens.assign(tokens.begin(), tokens.begin() + n_token_count);
    h->state_n_past = static_cast<llama_pos>(n_token_count);
    read_state_meta(std::string(path) + ".meta", h);
    if (h->state_positions.size() != h->state_tokens.size()) {
        h->state_positions.resize(h->state_tokens.size());
        for (size_t i = 0; i < h->state_positions.size(); ++i) {
            h->state_positions[i] = static_cast<llama_pos>(i);
        }
    }
    h->state_loaded = true;
    h->n_past = h->state_n_past;
    LOGI("state loaded: %s (%zu text tokens, %zu images, n_past=%d)",
         path, h->state_tokens.size(), h->state_image_ids.size(), h->state_n_past);
    return EDGE_AI_OK;
}

edge_ai_status edge_ai_state_clear(edge_ai_handle * h) {
    if (!h) return EDGE_AI_ERR_INVALID_ARGUMENT;
    std::lock_guard<std::mutex> lock(h->mutex);
    if (h->ctx) llama_memory_clear(llama_get_memory(h->ctx), true);
    h->state_tokens.clear();
    h->state_positions.clear();
    h->state_image_ids.clear();
    h->state_n_past = 0;
    h->state_loaded = false;
    return EDGE_AI_OK;
}

edge_ai_status edge_ai_destroy(edge_ai_handle * h) {    if (!h) return EDGE_AI_OK;
    h->cancel.store(true);
    std::lock_guard<std::mutex> lock(h->mutex);
    clear_model(h);
    delete h;
    return EDGE_AI_OK;
}

edge_ai_status edge_ai_get_model_info(edge_ai_handle * h, edge_ai_model_info * info) {
    if (!h || !info || info->struct_size < sizeof(edge_ai_model_info)) {
        return EDGE_AI_ERR_INVALID_ARGUMENT;
    }
    std::lock_guard<std::mutex> lock(h->mutex);
    if (!h->loaded) return EDGE_AI_ERR_NOT_LOADED;

    std::memset(info, 0, sizeof(*info));
    info->struct_size = sizeof(edge_ai_model_info);
    info->n_ctx = h->n_ctx;
    info->n_ctx_train = h->n_ctx_train;
    info->n_batch = h->n_batch;
    info->n_ubatch = h->n_ubatch;
    info->n_threads = h->n_threads;
    info->n_layer = llama_model_n_layer(h->model);
    info->n_head = llama_model_n_head(h->model);
    info->n_head_kv = llama_model_n_head_kv(h->model);
    info->n_embd = llama_model_n_embd(h->model);
    info->n_vocab = llama_vocab_n_tokens(h->vocab);
    info->n_gpu_layers = h->n_gpu_layers;
    info->is_gpu = h->backend.find("Vulkan") != std::string::npos ? 1 : 0;
    info->recommended_ctx = h->recommended_ctx;
    info->n_params = llama_model_n_params(h->model);
    info->model_bytes = h->model_bytes;
    info->kv_bytes_per_token = h->kv_bytes_per_token;
    info->kv_bytes = h->kv_bytes;
    info->compute_margin_bytes = h->compute_margin_bytes;

    MemInfo mem;
    read_meminfo(mem);
    info->total_ram = mem.total;
    info->avail_ram = mem.avail;
    info->rss_bytes = read_rss_bytes();
    info->peak_rss_bytes = read_peak_rss_bytes();
    info->budget_bytes = h->budget_bytes;
    info->reserve_bytes = h->reserve_bytes;

    std::snprintf(info->desc, sizeof(info->desc), "%s", h->desc.c_str());
    std::snprintf(info->backend, sizeof(info->backend), "%s", h->backend.c_str());
    std::snprintf(info->arch, sizeof(info->arch), "%s", h->arch.c_str());
    return EDGE_AI_OK;
}

edge_ai_status edge_ai_prepare_chat(edge_ai_handle * h,
                                    const edge_ai_chat_message * messages,
                                    int32_t n_messages,
                                    int32_t max_output_tokens,
                                    int32_t enable_thinking,
                                    char * out, int32_t out_cap,
                                    edge_ai_chat_plan * plan) {
    if (!h || !messages || n_messages <= 0 || !plan || plan->struct_size < sizeof(edge_ai_chat_plan)) {
        return EDGE_AI_ERR_INVALID_ARGUMENT;
    }
    std::lock_guard<std::mutex> lock(h->mutex);
    if (!h->loaded) return EDGE_AI_ERR_NOT_LOADED;
    if (h->generating) return EDGE_AI_ERR_BUSY;
    if (!h->templates) return EDGE_AI_ERR_UNSUPPORTED;

    const int max_output = std::max(1, max_output_tokens > 0 ? max_output_tokens : 256);

    std::vector<common_chat_msg> chat;
    chat.reserve(static_cast<size_t>(n_messages));
    for (int32_t i = 0; i < n_messages; ++i) {
        if (!messages[i].role || !messages[i].content) return EDGE_AI_ERR_INVALID_ARGUMENT;
        common_chat_msg msg;
        msg.role = messages[i].role;
        msg.content = messages[i].content;
        chat.push_back(std::move(msg));
    }
    const int total_messages = static_cast<int>(chat.size());
    int dropped = 0;
    std::string prompt;
    int prompt_tokens = 0;
    int adjusted_output = max_output;

    auto apply_template = [&](const std::vector<common_chat_msg> & msgs, std::string & result, int & tokens) -> bool {
        try {
            common_chat_templates_inputs inputs;
            inputs.messages = msgs;
            inputs.add_generation_prompt = true;
            inputs.use_jinja = true;
            inputs.enable_thinking = enable_thinking != 0;
            const auto params = common_chat_templates_apply(h->templates.get(), inputs);
            result = params.prompt.str();
            tokens = count_tokens(h->vocab, result);
            return true;
        } catch (const std::exception & ex) {
            LOGW("chat template apply failed: %s", ex.what());
            return false;
        }
    };

    if (!apply_template(chat, prompt, prompt_tokens)) {
        return EDGE_AI_ERR_UNSUPPORTED;
    }

    const int min_output = std::max(1, std::min(max_output, 32));
    while (prompt_tokens + min_output > h->n_ctx) {
        int drop_index = -1;
        // Never drop the final message: it is the current user turn.
        for (size_t i = 0; i + 1 < chat.size(); ++i) {
            if (chat[i].role != "system") {
                drop_index = static_cast<int>(i);
                break;
            }
        }
        if (drop_index < 0) break;
        chat.erase(chat.begin() + drop_index);
        ++dropped;
        if (!apply_template(chat, prompt, prompt_tokens)) return EDGE_AI_ERR_UNSUPPORTED;
    }

    plan->struct_size = sizeof(edge_ai_chat_plan);
    plan->prompt_tokens = prompt_tokens;
    plan->n_ctx = h->n_ctx;
    plan->dropped_messages = dropped;
    plan->total_messages = total_messages;
    plan->prompt_bytes = static_cast<int32_t>(prompt.size());

    if (prompt_tokens >= h->n_ctx) {
        plan->fits = 0;
        plan->max_output_tokens = 0;
        return EDGE_AI_ERR_CONTEXT_OVERFLOW;
    }
    adjusted_output = std::min(max_output, h->n_ctx - prompt_tokens);
    if (adjusted_output <= 0) {
        plan->fits = 0;
        plan->max_output_tokens = 0;
        return EDGE_AI_ERR_CONTEXT_OVERFLOW;
    }
    plan->fits = 1;
    plan->max_output_tokens = adjusted_output;

    if (!out || out_cap <= static_cast<int32_t>(prompt.size())) {
        return EDGE_AI_ERR_BUFFER_TOO_SMALL;
    }
    std::memcpy(out, prompt.data(), prompt.size());
    out[prompt.size()] = '\0';
    return EDGE_AI_OK;
}

static bool format_chat_v3(edge_ai_handle * h,
                           const edge_ai_chat_message_v3 * messages,
                           int32_t n_messages,
                           int32_t enable_thinking,
                           std::string & prompt,
                           std::vector<std::string> & images) {
    if (!h->templates) return false;
    std::vector<common_chat_msg> chat;
    chat.reserve(static_cast<size_t>(n_messages));
    for (int32_t i = 0; i < n_messages; ++i) {
        if (!messages[i].role || !messages[i].content) return false;
        std::string content = messages[i].content;
        if (messages[i].image_path && messages[i].image_path[0] != '\0') {
            content = std::string(mtmd_default_marker()) + "\n" + content;
            images.emplace_back(messages[i].image_path);
        }
        common_chat_msg msg;
        msg.role = messages[i].role;
        msg.content = std::move(content);
        chat.push_back(std::move(msg));
    }
    try {
        common_chat_templates_inputs inputs;
        inputs.messages = std::move(chat);
        inputs.add_generation_prompt = true;
        inputs.use_jinja = true;
        inputs.enable_thinking = enable_thinking != 0;
        const auto params = common_chat_templates_apply(h->templates.get(), inputs);
        prompt = params.prompt.str();
        return true;
    } catch (const std::exception & ex) {
        LOGW("v3 chat template apply failed: %s", ex.what());
        return false;
    }
}

static edge_ai_status make_mtmd_chunks(edge_ai_handle * h,
                                       const std::string & prompt,
                                       const std::vector<std::string> & images,
                                       bool placeholder,
                                       mtmd_input_chunks ** out_chunks,
                                       size_t * out_tokens,
                                       char * err, int32_t err_len) {
    *out_chunks = nullptr;
    *out_tokens = 0;
    if (!h->mtmd_ctx) {
        set_error(h, err, err_len, "vision projector is not loaded");
        return EDGE_AI_ERR_UNSUPPORTED;
    }

    const std::string marker = mtmd_default_marker();
    std::vector<std::string> segments;
    size_t start = 0;
    size_t pos = 0;
    while ((pos = prompt.find(marker, start)) != std::string::npos) {
        segments.push_back(prompt.substr(start, pos - start));
        start = pos + marker.size();
    }
    segments.push_back(prompt.substr(start));
    if (segments.size() != images.size() + 1) {
        set_error(h, err, err_len, "image marker count does not match images");
        return EDGE_AI_ERR_INVALID_ARGUMENT;
    }

    std::vector<mtmd_helper_bitmap_wrapper> wrappers;
    wrappers.reserve(images.size());
    const auto opt = mtmd_helper_init_opt_default();
    for (const auto & path : images) {
        auto wrapper = mtmd_helper_bitmap_init_from_file(h->mtmd_ctx, path.c_str(), placeholder, opt);
        if (!wrapper.bitmap) {
            for (auto & w : wrappers) {
                if (w.bitmap) mtmd_bitmap_free(w.bitmap);
            }
            set_error(h, err, err_len, "failed to decode input image");
            return EDGE_AI_ERR_IO;
        }
        wrappers.push_back(wrapper);
    }

    std::vector<mtmd_input_text> texts(segments.size());
    std::vector<mtmd_input_part> parts;
    parts.reserve(segments.size() * 2);
    for (size_t i = 0; i < segments.size(); ++i) {
        texts[i] = {segments[i].data(), segments[i].size(), false, true};
        parts.push_back({&texts[i], nullptr});
        if (i < wrappers.size()) {
            parts.push_back({nullptr, wrappers[i].bitmap});
        }
    }
    std::vector<const mtmd_input_part *> part_ptrs;
    part_ptrs.reserve(parts.size());
    for (const auto & part : parts) part_ptrs.push_back(&part);

    mtmd_input_chunks * chunks = mtmd_input_chunks_init();
    const int32_t rc = mtmd_tokenize_from_parts(h->mtmd_ctx, chunks, part_ptrs.data(), part_ptrs.size(), false);
    for (auto & wrapper : wrappers) {
        if (wrapper.bitmap) mtmd_bitmap_free(wrapper.bitmap);
    }
    if (rc != 0) {
        mtmd_input_chunks_free(chunks);
        set_error(h, err, err_len, "failed to tokenize multimodal prompt");
        return EDGE_AI_ERR_INTERNAL;
    }
    *out_chunks = chunks;
    *out_tokens = mtmd_helper_get_n_tokens(chunks);
    return EDGE_AI_OK;
}

edge_ai_status edge_ai_load_mmproj(edge_ai_handle * h,
                                   const char * mmproj_path,
                                   char * err, int32_t err_len) {
    if (!h || !mmproj_path || mmproj_path[0] == '\0') {
        return EDGE_AI_ERR_INVALID_ARGUMENT;
    }
    std::lock_guard<std::mutex> lock(h->mutex);
    if (!h->loaded) return EDGE_AI_ERR_NOT_LOADED;
    if (h->generating) return EDGE_AI_ERR_BUSY;
    if (h->mtmd_ctx) {
        mtmd_free(h->mtmd_ctx);
        h->mtmd_ctx = nullptr;
        h->vision = false;
    }
    auto params = mtmd_context_params_default();
    params.use_gpu = h->n_gpu_layers > 0;
    params.n_threads = h->n_threads;
    params.print_timings = false;
    params.warmup = false;
    params.image_max_tokens = 1024;
    h->mtmd_ctx = mtmd_init_from_file(mmproj_path, h->model, params);
    if (!h->mtmd_ctx) {
        set_error(h, err, err_len, "failed to load vision projector");
        return EDGE_AI_ERR_BACKEND;
    }
    h->vision = mtmd_support_vision(h->mtmd_ctx);
    if (!h->vision) {
        mtmd_free(h->mtmd_ctx);
        h->mtmd_ctx = nullptr;
        set_error(h, err, err_len, "projector does not support vision");
        return EDGE_AI_ERR_UNSUPPORTED;
    }
    LOGI("vision projector loaded");
    return EDGE_AI_OK;
}

edge_ai_status edge_ai_has_vision(edge_ai_handle * h, int32_t * out_has_vision) {
    if (!h || !out_has_vision) return EDGE_AI_ERR_INVALID_ARGUMENT;
    std::lock_guard<std::mutex> lock(h->mutex);
    *out_has_vision = h->vision ? 1 : 0;
    return EDGE_AI_OK;
}

static bool format_chat_v4(edge_ai_handle * h,
                           const edge_ai_chat_message_v4 * messages,
                           int32_t n_messages,
                           int32_t enable_thinking,
                           std::string & prompt,
                           std::vector<std::string> & images) {
    if (!h->templates) return false;
    std::vector<common_chat_msg> chat;
    chat.reserve(static_cast<size_t>(n_messages));
    for (int32_t i = 0; i < n_messages; ++i) {
        if (!messages[i].role || !messages[i].content) return false;
        if (messages[i].n_image_paths < 0) return false;
        if (messages[i].n_image_paths > 0 && !messages[i].image_paths) return false;
        std::string content;
        for (int32_t j = 0; j < messages[i].n_image_paths; ++j) {
            const char * path = messages[i].image_paths[j];
            if (path && path[0] != '\0') {
                content += mtmd_default_marker();
                content += '\n';
                images.emplace_back(path);
            }
        }
        content += messages[i].content;
        common_chat_msg msg;
        msg.role = messages[i].role;
        msg.content = std::move(content);
        chat.push_back(std::move(msg));
    }
    try {
        common_chat_templates_inputs inputs;
        inputs.messages = std::move(chat);
        inputs.add_generation_prompt = true;
        inputs.use_jinja = true;
        inputs.enable_thinking = enable_thinking != 0;
        const auto params = common_chat_templates_apply(h->templates.get(), inputs);
        prompt = params.prompt.str();
        return true;
    } catch (const std::exception & ex) {
        LOGW("v4 chat template apply failed: %s", ex.what());
        return false;
    }
}

edge_ai_status edge_ai_prepare_chat_v3(edge_ai_handle * h,                                       const edge_ai_chat_message_v3 * messages,
                                       int32_t n_messages,
                                       int32_t max_output_tokens,
                                       int32_t enable_thinking,
                                       char * out, int32_t out_cap,
                                       edge_ai_chat_plan * plan) {
    if (!h || !messages || n_messages <= 0 || !plan || plan->struct_size < sizeof(edge_ai_chat_plan)) {
        return EDGE_AI_ERR_INVALID_ARGUMENT;
    }
    std::lock_guard<std::mutex> lock(h->mutex);
    if (!h->loaded) return EDGE_AI_ERR_NOT_LOADED;
    if (h->generating) return EDGE_AI_ERR_BUSY;

    std::string prompt;
    std::vector<std::string> images;
    if (!format_chat_v3(h, messages, n_messages, enable_thinking, prompt, images)) {
        return EDGE_AI_ERR_UNSUPPORTED;
    }
    const int max_output = std::max(1, max_output_tokens > 0 ? max_output_tokens : 256);
    int prompt_tokens = count_tokens(h->vocab, prompt);
    if (!images.empty()) {
        mtmd_input_chunks * chunks = nullptr;
        size_t n_tokens = 0;
        char err[256] = {0};
        const auto status = make_mtmd_chunks(h, prompt, images, true, &chunks, &n_tokens, err, sizeof(err));
        if (status != EDGE_AI_OK) return status;
        prompt_tokens = static_cast<int>(n_tokens);
        mtmd_input_chunks_free(chunks);
    }

    plan->struct_size = sizeof(edge_ai_chat_plan);
    plan->prompt_tokens = prompt_tokens;
    plan->n_ctx = h->n_ctx;
    plan->dropped_messages = 0;
    plan->total_messages = n_messages;
    plan->prompt_bytes = static_cast<int32_t>(prompt.size());
    plan->fits = prompt_tokens < h->n_ctx ? 1 : 0;
    plan->max_output_tokens = plan->fits
        ? std::max(0, std::min(max_output, h->n_ctx - prompt_tokens))
        : 0;
    if (!plan->fits) return EDGE_AI_ERR_CONTEXT_OVERFLOW;
    if (plan->max_output_tokens <= 0) {
        plan->fits = 0;
        return EDGE_AI_ERR_CONTEXT_OVERFLOW;
    }
    if (!out || out_cap <= static_cast<int32_t>(prompt.size())) {
        return EDGE_AI_ERR_BUFFER_TOO_SMALL;
    }
    std::memcpy(out, prompt.data(), prompt.size());
    out[prompt.size()] = '\0';
    return EDGE_AI_OK;
}

edge_ai_status edge_ai_start_chat_v3(edge_ai_handle * h,
                                     const edge_ai_chat_message_v3 * messages,
                                     int32_t n_messages,
                                     const edge_ai_gen_params * params,
                                     char * err, int32_t err_len) {
    if (!h || !messages || n_messages <= 0) return EDGE_AI_ERR_INVALID_ARGUMENT;
    std::lock_guard<std::mutex> lock(h->mutex);
    if (!h->loaded) return EDGE_AI_ERR_NOT_LOADED;
    if (h->generating) return EDGE_AI_ERR_BUSY;

    std::string prompt;
    std::vector<std::string> images;
    if (!format_chat_v3(h, messages, n_messages, 0, prompt, images)) {
        set_error(h, err, err_len, "chat template is not available");
        return EDGE_AI_ERR_UNSUPPORTED;
    }
    if (!images.empty() && !h->vision) {
        set_error(h, err, err_len, "vision projector is not loaded");
        return EDGE_AI_ERR_UNSUPPORTED;
    }

    mtmd_input_chunks * chunks = nullptr;
    size_t n_tokens = 0;
    edge_ai_status status = make_mtmd_chunks(h, prompt, images, false, &chunks, &n_tokens, err, err_len);
    if (status != EDGE_AI_OK) return status;
    if (n_tokens >= static_cast<size_t>(h->n_ctx)) {
        mtmd_input_chunks_free(chunks);
        set_error(h, err, err_len, "multimodal prompt does not fit in context");
        return EDGE_AI_ERR_CONTEXT_OVERFLOW;
    }

    edge_ai_gen_params defaults;
    std::memset(&defaults, 0, sizeof(defaults));
    defaults.struct_size = sizeof(edge_ai_gen_params);
    defaults.max_tokens = 256;
    defaults.top_k = 40;
    defaults.repeat_last_n = 64;
    defaults.temperature = 0.7f;
    defaults.top_p = 0.95f;
    defaults.min_p = 0.05f;
    defaults.repeat_penalty = 1.1f;
    defaults.seed = 0;
    const edge_ai_gen_params & gp = params ? *params : defaults;
    const int max_tokens = std::max(1, std::min(gp.max_tokens > 0 ? gp.max_tokens : 256,
                                                h->n_ctx - static_cast<int>(n_tokens)));

    h->cancel.store(false);
    h->done = false;
    h->generating = true;
    h->stop_reason = EDGE_AI_STOP_NONE;
    h->prompt_tokens = static_cast<int>(n_tokens);
    h->generated_tokens = 0;
    h->max_tokens = max_tokens;
    h->prefill_ms = 0;
    h->decode_ms = 0;
    h->n_past = 0;
    h->state_loaded = false;
    h->state_tokens.clear();
    h->pending.clear();
    h->stop_sequences.clear();
    h->ignore_eos = gp.ignore_eos != 0;
    if (gp.stop_sequences && gp.n_stop_sequences > 0) {
        for (int32_t i = 0; i < gp.n_stop_sequences; ++i) {
            if (gp.stop_sequences[i] && gp.stop_sequences[i][0] != '\0') {
                const size_t len = std::strlen(gp.stop_sequences[i]);
                if (len <= 512) h->stop_sequences.emplace_back(gp.stop_sequences[i]);
            }
        }
    }
    h->holdback = 0;
    for (const auto & stop : h->stop_sequences) h->holdback = std::max(h->holdback, stop.size());
    if (h->holdback > 0) --h->holdback;

    llama_memory_clear(llama_get_memory(h->ctx), true);
    const auto t0 = std::chrono::steady_clock::now();
    llama_pos new_n_past = 0;
    const int32_t eval_rc = mtmd_helper_eval_chunks(h->mtmd_ctx, h->ctx, chunks, 0, 0, h->n_batch, true, &new_n_past);
    mtmd_input_chunks_free(chunks);
    if (eval_rc != 0) {
        h->generating = false;
        h->done = true;
        set_error(h, err, err_len, "multimodal prefill failed");
        return EDGE_AI_ERR_INTERNAL;
    }
    llama_synchronize(h->ctx);
    h->n_past = new_n_past;
    const auto t1 = std::chrono::steady_clock::now();
    h->prefill_ms = std::chrono::duration<double, std::milli>(t1 - t0).count();

    if (h->sampler) {
        llama_sampler_free(h->sampler);
        h->sampler = nullptr;
    }
    h->sampler = llama_sampler_chain_init(llama_sampler_chain_default_params());
    llama_sampler_chain_add(h->sampler, llama_sampler_init_penalties(
        llama_vocab_n_tokens(h->vocab),
        std::max(0, gp.repeat_last_n),
        gp.repeat_penalty > 0.f ? gp.repeat_penalty : 1.1f,
        gp.frequency_penalty,
        gp.presence_penalty));
    llama_sampler_chain_add(h->sampler, llama_sampler_init_top_k(gp.top_k > 0 ? gp.top_k : 40));
    llama_sampler_chain_add(h->sampler, llama_sampler_init_top_p(gp.top_p > 0.f ? gp.top_p : 0.95f, 1));
    llama_sampler_chain_add(h->sampler, llama_sampler_init_min_p(gp.min_p > 0.f ? gp.min_p : 0.05f, 1));
    llama_sampler_chain_add(h->sampler, llama_sampler_init_temp(gp.temperature > 0.f ? gp.temperature : 0.7f));
    llama_sampler_chain_add(h->sampler, llama_sampler_init_dist(gp.seed != 0 ? gp.seed : std::random_device{}()));
    h->last_sample_time = std::chrono::steady_clock::now();
    h->last_error.clear();
    LOGI("multimodal generation start: %zu prompt tokens, max %d", n_tokens, max_tokens);
    return EDGE_AI_OK;
}

edge_ai_status edge_ai_prepare_chat_v4(edge_ai_handle * h,
                                       const edge_ai_chat_message_v4 * messages,
                                       int32_t n_messages,
                                       int32_t max_output_tokens,
                                       int32_t enable_thinking,
                                       char * out, int32_t out_cap,
                                       edge_ai_chat_plan * plan) {
    if (!h || !messages || n_messages <= 0 || !plan || plan->struct_size < sizeof(edge_ai_chat_plan)) {
        return EDGE_AI_ERR_INVALID_ARGUMENT;
    }
    std::lock_guard<std::mutex> lock(h->mutex);
    if (!h->loaded) return EDGE_AI_ERR_NOT_LOADED;
    if (h->generating) return EDGE_AI_ERR_BUSY;

    std::string prompt;
    std::vector<std::string> images;
    if (!format_chat_v4(h, messages, n_messages, enable_thinking, prompt, images)) {
        return EDGE_AI_ERR_UNSUPPORTED;
    }
    const int max_output = std::max(1, max_output_tokens > 0 ? max_output_tokens : 256);
    int prompt_tokens = count_tokens(h->vocab, prompt);
    if (!images.empty()) {
        mtmd_input_chunks * chunks = nullptr;
        size_t n_tokens = 0;
        char err[256] = {0};
        const auto status = make_mtmd_chunks(h, prompt, images, true, &chunks, &n_tokens, err, sizeof(err));
        if (status != EDGE_AI_OK) return status;
        prompt_tokens = static_cast<int>(n_tokens);
        mtmd_input_chunks_free(chunks);
    }

    plan->struct_size = sizeof(edge_ai_chat_plan);
    plan->prompt_tokens = prompt_tokens;
    plan->n_ctx = h->n_ctx;
    plan->dropped_messages = 0;
    plan->total_messages = n_messages;
    plan->prompt_bytes = static_cast<int32_t>(prompt.size());
    plan->fits = prompt_tokens < h->n_ctx ? 1 : 0;
    plan->max_output_tokens = plan->fits
        ? std::max(0, std::min(max_output, h->n_ctx - prompt_tokens))
        : 0;
    if (!plan->fits) return EDGE_AI_ERR_CONTEXT_OVERFLOW;
    if (plan->max_output_tokens <= 0) {
        plan->fits = 0;
        return EDGE_AI_ERR_CONTEXT_OVERFLOW;
    }
    if (!out || out_cap <= static_cast<int32_t>(prompt.size())) {
        return EDGE_AI_ERR_BUFFER_TOO_SMALL;
    }
    std::memcpy(out, prompt.data(), prompt.size());
    out[prompt.size()] = '\0';
    return EDGE_AI_OK;
}

edge_ai_status edge_ai_start_chat_v4(edge_ai_handle * h,
                                     const edge_ai_chat_message_v4 * messages,
                                     int32_t n_messages,
                                     const edge_ai_gen_params * params,
                                     char * err, int32_t err_len) {
    if (!h || !messages || n_messages <= 0) return EDGE_AI_ERR_INVALID_ARGUMENT;
    std::lock_guard<std::mutex> lock(h->mutex);
    if (!h->loaded) return EDGE_AI_ERR_NOT_LOADED;
    if (h->generating) return EDGE_AI_ERR_BUSY;

    std::string prompt;
    std::vector<std::string> images;
    if (!format_chat_v4(h, messages, n_messages, 0, prompt, images)) {
        set_error(h, err, err_len, "chat template is not available");
        return EDGE_AI_ERR_UNSUPPORTED;
    }
    if (!images.empty() && !h->vision) {
        set_error(h, err, err_len, "vision projector is not loaded");
        return EDGE_AI_ERR_UNSUPPORTED;
    }

    mtmd_input_chunks * chunks = nullptr;
    size_t n_tokens = 0;
    edge_ai_status status = make_mtmd_chunks(h, prompt, images, false, &chunks, &n_tokens, err, err_len);
    if (status != EDGE_AI_OK) return status;
    if (n_tokens >= static_cast<size_t>(h->n_ctx)) {
        mtmd_input_chunks_free(chunks);
        set_error(h, err, err_len, "multimodal prompt does not fit in context");
        return EDGE_AI_ERR_CONTEXT_OVERFLOW;
    }

    std::vector<llama_token> new_text_tokens;
    std::vector<llama_pos> new_text_positions;
    std::vector<std::string> new_image_ids;
    llama_pos position = 0;
    const size_t n_chunks = mtmd_input_chunks_size(chunks);
    for (size_t i = 0; i < n_chunks; ++i) {
        const mtmd_input_chunk * chunk = mtmd_input_chunks_get(chunks, i);
        if (mtmd_input_chunk_get_type(chunk) == MTMD_INPUT_CHUNK_TYPE_TEXT) {
            size_t n_text = 0;
            const llama_token * text = mtmd_input_chunk_get_tokens_text(chunk, &n_text);
            if (text) {
                for (size_t j = 0; j < n_text; ++j) {
                    new_text_tokens.push_back(text[j]);
                    new_text_positions.push_back(position++);
                }
            }
        } else {
            const char * id = mtmd_input_chunk_get_id(chunk);
            new_image_ids.emplace_back(id ? id : "");
            position += mtmd_input_chunk_get_n_pos(chunk);
        }
    }

    size_t common_text = 0;
    if (h->state_loaded &&
        h->state_image_ids.size() == new_image_ids.size() &&
        h->state_image_ids == new_image_ids) {
        const size_t limit = std::min(h->state_tokens.size(), new_text_tokens.size());
        while (common_text < limit &&
               h->state_tokens[common_text] == new_text_tokens[common_text]) {
            ++common_text;
        }
    }
    bool reused = common_text > 0 && common_text < new_text_tokens.size();
    llama_pos common_pos = reused
        ? (h->state_positions.size() >= common_text ? h->state_positions[common_text - 1] + 1
                                                    : static_cast<llama_pos>(common_text))
        : 0;
    size_t cached_text_count = reused ? common_text : 0;

    edge_ai_gen_params defaults;
    std::memset(&defaults, 0, sizeof(defaults));
    defaults.struct_size = sizeof(edge_ai_gen_params);
    defaults.max_tokens = 256;
    defaults.top_k = 40;
    defaults.repeat_last_n = 64;
    defaults.temperature = 0.7f;
    defaults.top_p = 0.95f;
    defaults.min_p = 0.05f;
    defaults.repeat_penalty = 1.1f;
    defaults.seed = 0;
    const edge_ai_gen_params & gp = params ? *params : defaults;
    const int max_tokens = std::max(1, std::min(gp.max_tokens > 0 ? gp.max_tokens : 256,
                                                h->n_ctx - static_cast<int>(n_tokens)));

    h->cancel.store(false);
    h->done = false;
    h->generating = true;
    h->stop_reason = EDGE_AI_STOP_NONE;
    h->prompt_tokens = static_cast<int>(n_tokens);
    h->generated_tokens = 0;
    h->max_tokens = max_tokens;
    h->prefill_ms = 0;
    h->decode_ms = 0;
    h->pending.clear();
    h->stop_sequences.clear();
    h->ignore_eos = gp.ignore_eos != 0;
    if (gp.stop_sequences && gp.n_stop_sequences > 0) {
        for (int32_t i = 0; i < gp.n_stop_sequences; ++i) {
            if (gp.stop_sequences[i] && gp.stop_sequences[i][0] != '\0') {
                const size_t len = std::strlen(gp.stop_sequences[i]);
                if (len <= 512) h->stop_sequences.emplace_back(gp.stop_sequences[i]);
            }
        }
    }
    h->holdback = 0;
    for (const auto & stop : h->stop_sequences) h->holdback = std::max(h->holdback, stop.size());
    if (h->holdback > 0) --h->holdback;

    if (!reused) {
        h->state_tokens.clear();
        h->state_positions.clear();
        h->state_image_ids.clear();
        h->state_n_past = 0;
        h->state_loaded = false;
        h->n_past = 0;
        llama_memory_clear(llama_get_memory(h->ctx), true);
    } else {
        if (!llama_memory_seq_rm(llama_get_memory(h->ctx), 0, common_pos, -1)) {
            LOGW("multimodal state cache trim failed, falling back to full prefill");
            reused = false;
            cached_text_count = 0;
            common_pos = 0;
            h->state_tokens.clear();
            h->state_positions.clear();
            h->state_image_ids.clear();
            h->state_n_past = 0;
            h->state_loaded = false;
            h->n_past = 0;
            llama_memory_clear(llama_get_memory(h->ctx), true);
        } else {
            h->n_past = common_pos;
            LOGI("multimodal state cache prefix hit: %zu/%zu text tokens, n_past=%d",
                 cached_text_count, new_text_tokens.size(), h->n_past);
        }
    }

    const auto t0 = std::chrono::steady_clock::now();
    llama_pos new_n_past = reused ? common_pos : 0;
    int32_t eval_rc = 0;
    if (reused) {
        const size_t suffix_count = new_text_tokens.size() - cached_text_count;
        for (size_t i = 0; i < suffix_count; i += static_cast<size_t>(h->n_batch)) {
            const int chunk = static_cast<int>(std::min<size_t>(static_cast<size_t>(h->n_batch), suffix_count - i));
            llama_batch batch = llama_batch_init(chunk, 0, 1);
            for (int j = 0; j < chunk; ++j) {
                batch.token[j] = new_text_tokens[cached_text_count + i + static_cast<size_t>(j)];
                batch.pos[j] = new_text_positions[cached_text_count + i + static_cast<size_t>(j)];
                batch.n_seq_id[j] = 1;
                batch.seq_id[j][0] = 0;
                batch.logits[j] = (i + static_cast<size_t>(j) == suffix_count - 1) ? 1 : 0;
            }
            batch.n_tokens = chunk;
            eval_rc = llama_decode(h->ctx, batch);
            llama_batch_free(batch);
            if (eval_rc != 0) break;
            new_n_past = new_text_positions[cached_text_count + i + static_cast<size_t>(chunk) - 1] + 1;
        }
    } else {
        eval_rc = mtmd_helper_eval_chunks(h->mtmd_ctx, h->ctx, chunks, 0, 0, h->n_batch, true, &new_n_past);
    }
    mtmd_input_chunks_free(chunks);
    if (eval_rc != 0) {
        h->generating = false;
        h->done = true;
        h->state_loaded = false;
        h->state_tokens.clear();
        h->state_positions.clear();
        set_error(h, err, err_len, "multimodal prefill failed");
        return EDGE_AI_ERR_INTERNAL;
    }
    llama_synchronize(h->ctx);
    h->n_past = new_n_past;
    h->state_tokens = new_text_tokens;
    h->state_positions = new_text_positions;
    h->state_image_ids = new_image_ids;
    h->state_n_past = h->n_past;
    h->state_loaded = true;
    const auto t1 = std::chrono::steady_clock::now();
    h->prefill_ms = std::chrono::duration<double, std::milli>(t1 - t0).count();

    if (h->sampler) {
        llama_sampler_free(h->sampler);
        h->sampler = nullptr;
    }
    h->sampler = llama_sampler_chain_init(llama_sampler_chain_default_params());
    llama_sampler_chain_add(h->sampler, llama_sampler_init_penalties(
        llama_vocab_n_tokens(h->vocab),
        std::max(0, gp.repeat_last_n),
        gp.repeat_penalty > 0.f ? gp.repeat_penalty : 1.1f,
        gp.frequency_penalty,
        gp.presence_penalty));
    llama_sampler_chain_add(h->sampler, llama_sampler_init_top_k(gp.top_k > 0 ? gp.top_k : 40));
    llama_sampler_chain_add(h->sampler, llama_sampler_init_top_p(gp.top_p > 0.f ? gp.top_p : 0.95f, 1));
    llama_sampler_chain_add(h->sampler, llama_sampler_init_min_p(gp.min_p > 0.f ? gp.min_p : 0.05f, 1));
    llama_sampler_chain_add(h->sampler, llama_sampler_init_temp(gp.temperature > 0.f ? gp.temperature : 0.7f));
    llama_sampler_chain_add(h->sampler, llama_sampler_init_dist(gp.seed != 0 ? gp.seed : std::random_device{}()));
    h->last_sample_time = std::chrono::steady_clock::now();
    h->last_error.clear();
    LOGI("multimodal v4 generation start: %zu prompt tokens, %zu images, max %d",
         n_tokens, images.size(), max_tokens);
    return EDGE_AI_OK;
}

edge_ai_status edge_ai_start_ex(edge_ai_handle * h,
                                const char * prompt,
                                const edge_ai_gen_params * params,
                                char * err, int32_t err_len) {
    if (!h || !prompt) return EDGE_AI_ERR_INVALID_ARGUMENT;
    std::lock_guard<std::mutex> lock(h->mutex);
    if (!h->loaded) return EDGE_AI_ERR_NOT_LOADED;
    if (h->generating) return EDGE_AI_ERR_BUSY;

    const int prompt_len = static_cast<int>(std::strlen(prompt));
    if (prompt_len <= 0 || prompt_len > kMaxPromptBytes) {
        set_error(h, err, err_len, "prompt length out of range");
        return EDGE_AI_ERR_INVALID_ARGUMENT;
    }

    int32_t need = llama_tokenize(h->vocab, prompt, prompt_len, nullptr, 0, false, true);
    if (need < 0) need = -need;
    if (need <= 0) {
        set_error(h, err, err_len, "failed to tokenize prompt");
        return EDGE_AI_ERR_INVALID_ARGUMENT;
    }
    if (need >= h->n_ctx) {
        set_error(h, err, err_len, "prompt does not fit in context");
        return EDGE_AI_ERR_CONTEXT_OVERFLOW;
    }
    std::vector<llama_token> tokens(static_cast<size_t>(need));
    if (llama_tokenize(h->vocab, prompt, prompt_len, tokens.data(), need, false, true) < 0) {
        set_error(h, err, err_len, "failed to tokenize prompt");
        return EDGE_AI_ERR_INTERNAL;
    }

    edge_ai_gen_params defaults;
    std::memset(&defaults, 0, sizeof(defaults));
    defaults.struct_size = sizeof(edge_ai_gen_params);
    defaults.max_tokens = 256;
    defaults.top_k = 40;
    defaults.repeat_last_n = 64;
    defaults.temperature = 0.7f;
    defaults.top_p = 0.95f;
    defaults.min_p = 0.05f;
    defaults.repeat_penalty = 1.1f;
    defaults.seed = 0;
    const edge_ai_gen_params & gp = params ? *params : defaults;
    const int max_tokens = std::max(1, std::min(gp.max_tokens > 0 ? gp.max_tokens : 256, h->n_ctx - need));

    h->cancel.store(false);
    h->done = false;
    h->generating = true;
    h->stop_reason = EDGE_AI_STOP_NONE;
    h->prompt_tokens = need;
    h->generated_tokens = 0;
    h->max_tokens = max_tokens;
    h->prefill_ms = 0;
    h->decode_ms = 0;
    int common = 0;
    if (h->state_loaded && !h->state_tokens.empty() && !tokens.empty()) {
        const size_t limit = std::min(h->state_tokens.size(), tokens.size());
        while (static_cast<size_t>(common) < limit &&
               tokens[static_cast<size_t>(common)] == h->state_tokens[static_cast<size_t>(common)]) {
            ++common;
        }
    }
    h->n_past = common;
    h->pending.clear();
    h->stop_sequences.clear();
    h->ignore_eos = gp.ignore_eos != 0;

    if (gp.stop_sequences && gp.n_stop_sequences > 0) {
        for (int32_t i = 0; i < gp.n_stop_sequences; ++i) {
            if (gp.stop_sequences[i] && gp.stop_sequences[i][0] != '\0') {
                const size_t len = std::strlen(gp.stop_sequences[i]);
                if (len <= 512) h->stop_sequences.emplace_back(gp.stop_sequences[i]);
            }
        }
    }
    h->holdback = 0;
    for (const auto & stop : h->stop_sequences) h->holdback = std::max(h->holdback, stop.size());
    if (h->holdback > 0) --h->holdback;

    if (common == 0) {
        h->state_loaded = false;
        h->state_tokens.clear();
        llama_memory_clear(llama_get_memory(h->ctx), true);
    } else {
        // Keep the longest common prefix and drop everything after it. This is
        // what makes state reuse effective across turns even when the cached
        // generation prompt differs from the next turn's chat template.
        if (common == need && need > 0) {
            llama_memory_seq_rm(llama_get_memory(h->ctx), 0, need - 1, -1);
            common = need - 1;
        } else if (!llama_memory_seq_rm(llama_get_memory(h->ctx), 0, common, -1)) {
            h->state_loaded = false;
            h->state_tokens.clear();
            common = 0;
            llama_memory_clear(llama_get_memory(h->ctx), true);
        }
        h->n_past = common;
        if (common > 0) {
            LOGI("state cache prefix hit: %d/%d tokens", common, need);
        }
    }

    const auto t0 = std::chrono::steady_clock::now();
    for (int i = common; i < need; i += h->n_batch) {
        const int chunk = std::min(h->n_batch, need - i);
        llama_batch batch = llama_batch_init(chunk, 0, 1);
        for (int j = 0; j < chunk; ++j) {
            batch.token[j] = tokens[static_cast<size_t>(i + j)];
            batch.pos[j] = i + j;
            batch.n_seq_id[j] = 1;
            batch.seq_id[j][0] = 0;
            batch.logits[j] = (i + j == need - 1) ? 1 : 0;
        }
        batch.n_tokens = chunk;
        const int decode_rc = llama_decode(h->ctx, batch);
        llama_batch_free(batch);
        if (decode_rc != 0) {
            h->generating = false;
            h->done = true;
            h->state_loaded = false;
            h->state_tokens.clear();
            set_error(h, err, err_len, "prompt decode failed");
            return EDGE_AI_ERR_INTERNAL;
        }
    }
    llama_synchronize(h->ctx);
    h->n_past = need;
    h->state_tokens.assign(tokens.begin(), tokens.end());
    h->state_positions.resize(h->state_tokens.size());
    for (size_t i = 0; i < h->state_positions.size(); ++i) {
        h->state_positions[i] = static_cast<llama_pos>(i);
    }
    h->state_image_ids.clear();
    h->state_n_past = h->n_past;
    h->state_loaded = true;
    const auto t1 = std::chrono::steady_clock::now();
    h->prefill_ms = std::chrono::duration<double, std::milli>(t1 - t0).count();

    if (h->sampler) {
        llama_sampler_free(h->sampler);
        h->sampler = nullptr;
    }
    h->sampler = llama_sampler_chain_init(llama_sampler_chain_default_params());
    llama_sampler_chain_add(h->sampler, llama_sampler_init_penalties(
        llama_vocab_n_tokens(h->vocab),
        std::max(0, gp.repeat_last_n),
        gp.repeat_penalty > 0.f ? gp.repeat_penalty : 1.1f,
        gp.frequency_penalty,
        gp.presence_penalty));
    llama_sampler_chain_add(h->sampler, llama_sampler_init_top_k(gp.top_k > 0 ? gp.top_k : 40));
    llama_sampler_chain_add(h->sampler, llama_sampler_init_top_p(gp.top_p > 0.f ? gp.top_p : 0.95f, 1));
    llama_sampler_chain_add(h->sampler, llama_sampler_init_min_p(gp.min_p > 0.f ? gp.min_p : 0.05f, 1));
    llama_sampler_chain_add(h->sampler, llama_sampler_init_temp(gp.temperature > 0.f ? gp.temperature : 0.7f));
    const uint32_t seed = gp.seed != 0 ? gp.seed : std::random_device{}();
    llama_sampler_chain_add(h->sampler, llama_sampler_init_dist(seed));

    h->last_sample_time = std::chrono::steady_clock::now();
    h->last_error.clear();
    LOGI("generation start: %d prompt tokens, max %d", need, max_tokens);
    return EDGE_AI_OK;
}

static edge_ai_status flush_pending(edge_ai_handle * h, char * out, int32_t out_cap,
                                    int32_t * out_len, bool final) {
    *out_len = 0;
    if (h->pending.empty()) return EDGE_AI_OK;

    size_t emit = final ? h->pending.size() : 0;
    if (!final) {
        if (h->pending.size() > h->holdback) {
            emit = h->pending.size() - h->holdback;
        }
    }
    if (emit == 0) return EDGE_AI_OK;
    if (emit > static_cast<size_t>(out_cap)) return EDGE_AI_ERR_BUFFER_TOO_SMALL;

    std::memcpy(out, h->pending.data(), emit);
    h->pending.erase(0, emit);
    *out_len = static_cast<int32_t>(emit);
    return EDGE_AI_OK;
}

static edge_ai_status finalize(edge_ai_handle * h, int32_t reason, char * out, int32_t out_cap,
                               int32_t * out_len) {
    h->done = true;
    h->generating = false;
    h->stop_reason = reason;
    return flush_pending(h, out, out_cap, out_len, true);
}

edge_ai_status edge_ai_next_ex(edge_ai_handle * h,
                               char * out, int32_t out_cap,
                               int32_t * out_len,
                               int32_t * stop_reason,
                               char * err, int32_t err_len) {
    if (!h || !out || out_cap <= 0 || !out_len) return EDGE_AI_ERR_INVALID_ARGUMENT;
    std::lock_guard<std::mutex> lock(h->mutex);
    *out_len = 0;
    if (stop_reason) *stop_reason = h->stop_reason;
    if (!h->loaded) return EDGE_AI_ERR_NOT_LOADED;

    if (!h->generating) {
        if (h->done) {
            if (stop_reason) *stop_reason = h->stop_reason;
            return EDGE_AI_OK;
        }
        return EDGE_AI_ERR_NOT_LOADED;
    }

    for (;;) {
        if (h->cancel.load()) {
            return finalize(h, EDGE_AI_STOP_CANCELLED, out, out_cap, out_len);
        }
        if (h->generated_tokens >= h->max_tokens) {
            return finalize(h, EDGE_AI_STOP_MAX_TOKENS, out, out_cap, out_len);
        }

        const llama_token id = llama_sampler_sample(h->sampler, h->ctx, -1);
        const auto sample_time = std::chrono::steady_clock::now();
        h->decode_ms += std::chrono::duration<double, std::milli>(sample_time - h->last_sample_time).count();
        h->last_sample_time = sample_time;

        if (!h->ignore_eos && llama_vocab_is_eog(h->vocab, id)) {
            return finalize(h, EDGE_AI_STOP_EOS, out, out_cap, out_len);
        }

        char piece[512];
        int piece_len = llama_token_to_piece(h->vocab, id, piece, sizeof(piece), 0, false);
        if (piece_len < 0) piece_len = 0;

        llama_batch batch = llama_batch_init(1, 0, 1);
        batch.n_tokens = 1;
        batch.token[0] = id;
        batch.pos[0] = h->n_past;
        batch.n_seq_id[0] = 1;
        batch.seq_id[0][0] = 0;
        batch.logits[0] = 1;
        const int decode_rc = llama_decode(h->ctx, batch);
        llama_batch_free(batch);
        if (decode_rc != 0) {
            h->generating = false;
            h->done = true;
            h->stop_reason = EDGE_AI_STOP_ERROR;
            if (stop_reason) *stop_reason = h->stop_reason;
            set_error(h, err, err_len, "decode failed");
            return EDGE_AI_ERR_INTERNAL;
        }
        ++h->n_past;
        ++h->state_n_past;
        ++h->generated_tokens;
        if (h->state_loaded) {
            h->state_tokens.push_back(id);
            h->state_positions.push_back(h->n_past - 1);
        }
        if (piece_len > 0) h->pending.append(piece, static_cast<size_t>(piece_len));

        int32_t matched = -1;
        for (size_t i = 0; i < h->stop_sequences.size(); ++i) {
            if (ends_with(h->pending, h->stop_sequences[i])) {
                matched = static_cast<int32_t>(i);
                break;
            }
        }
        if (matched >= 0) {
            h->pending.erase(h->pending.size() - h->stop_sequences[matched].size());
            return finalize(h, EDGE_AI_STOP_SEQUENCE, out, out_cap, out_len);
        }

        if (h->pending.size() > h->holdback) {
            const edge_ai_status status = flush_pending(h, out, out_cap, out_len, false);
            if (status != EDGE_AI_OK) return status;
            if (*out_len > 0) {
                if (stop_reason) *stop_reason = h->stop_reason;
                return EDGE_AI_OK;
            }
        }
    }
}

edge_ai_status edge_ai_cancel(edge_ai_handle * h) {
    if (!h) return EDGE_AI_ERR_INVALID_ARGUMENT;
    h->cancel.store(true);
    return EDGE_AI_OK;
}

edge_ai_status edge_ai_get_stats(edge_ai_handle * h, edge_ai_generation_stats * stats) {
    if (!h || !stats || stats->struct_size < sizeof(edge_ai_generation_stats)) {
        return EDGE_AI_ERR_INVALID_ARGUMENT;
    }
    std::lock_guard<std::mutex> lock(h->mutex);
    std::memset(stats, 0, sizeof(*stats));
    stats->struct_size = sizeof(edge_ai_generation_stats);
    stats->prompt_tokens = h->prompt_tokens;
    stats->generated_tokens = h->generated_tokens;
    stats->stop_reason = h->stop_reason;
    stats->prefill_ms = h->prefill_ms;
    stats->decode_ms = h->decode_ms;
    stats->load_ms = h->load_ms;
    stats->tokens_per_second = h->decode_ms > 0.0
                                   ? h->generated_tokens * 1000.0 / h->decode_ms
                                   : 0.0;
    return EDGE_AI_OK;
}

// ---------------------------------------------------------------------------
// Legacy ABI (kept so older clients keep working during migration).
// ---------------------------------------------------------------------------

void * edge_ai_create(const char * model_path, int n_gpu_layers, int n_ctx, int n_threads,
                      char * err, int err_len) {
    edge_ai_config config;
    edge_ai_config_defaults(&config);
    config.model_path = model_path;
    config.backend = n_gpu_layers > 0 ? EDGE_AI_BACKEND_VULKAN : EDGE_AI_BACKEND_CPU;
    config.n_gpu_layers = n_gpu_layers;
    config.n_ctx = n_ctx;
    config.n_threads = n_threads;
    config.n_threads_batch = n_threads;
    config.min_ctx = std::min(n_ctx > 0 ? n_ctx : 512, 512);
    config.max_ctx = n_ctx > 0 ? n_ctx : kDefaultMaxCtx;
    edge_ai_handle * handle = nullptr;
    if (edge_ai_create_ex(&config, &handle, err, err_len) != EDGE_AI_OK) return nullptr;
    return handle;
}

void edge_ai_free(void * handle) {
    if (handle) edge_ai_destroy(static_cast<edge_ai_handle *>(handle));
}

void edge_ai_backend(void * handle, char * out, int out_len) {
    if (!handle || !out || out_len <= 0) return;
    edge_ai_model_info info;
    info.struct_size = sizeof(info);
    if (edge_ai_get_model_info(static_cast<edge_ai_handle *>(handle), &info) == EDGE_AI_OK) {
        std::snprintf(out, static_cast<size_t>(out_len), "%s", info.backend);
    }
}

void edge_ai_model_desc(void * handle, char * out, int out_len) {
    if (!handle || !out || out_len <= 0) return;
    edge_ai_model_info info;
    info.struct_size = sizeof(info);
    if (edge_ai_get_model_info(static_cast<edge_ai_handle *>(handle), &info) == EDGE_AI_OK) {
        std::snprintf(out, static_cast<size_t>(out_len), "%s", info.desc);
    }
}

int edge_ai_model_params(void * handle, char * out, int out_len) {
    if (!handle || !out || out_len <= 0) return 0;
    edge_ai_model_info info;
    info.struct_size = sizeof(info);
    if (edge_ai_get_model_info(static_cast<edge_ai_handle *>(handle), &info) != EDGE_AI_OK) return 0;
    std::snprintf(out, static_cast<size_t>(out_len),
                  "params=%llu|size_mb=%.0f|ctx=%d|ngl=%d|gpu_offload=%d",
                  static_cast<unsigned long long>(info.n_params),
                  info.model_bytes / 1024.0 / 1024.0,
                  info.n_ctx,
                  info.n_gpu_layers,
                  info.is_gpu);
    return 1;
}

int edge_ai_start(void * handle, const char * prompt, int max_tokens,
                  float temperature, float top_p, int top_k, float repeat_penalty,
                  char * err, int err_len) {
    edge_ai_gen_params params;
    std::memset(&params, 0, sizeof(params));
    params.struct_size = sizeof(params);
    params.max_tokens = max_tokens;
    params.temperature = temperature;
    params.top_p = top_p;
    params.top_k = top_k;
    params.repeat_penalty = repeat_penalty;
    params.repeat_last_n = 64;
    if (edge_ai_start_ex(static_cast<edge_ai_handle *>(handle), prompt, &params, err, err_len) != EDGE_AI_OK) {
        return -1;
    }
    edge_ai_generation_stats stats;
    stats.struct_size = sizeof(stats);
    if (edge_ai_get_stats(static_cast<edge_ai_handle *>(handle), &stats) == EDGE_AI_OK) {
        return stats.prompt_tokens;
    }
    return 0;
}

int edge_ai_next(void * handle, char * out, int out_len) {
    int32_t got = 0;
    int32_t reason = EDGE_AI_STOP_NONE;
    char err[256];
    const edge_ai_status status = edge_ai_next_ex(static_cast<edge_ai_handle *>(handle),
                                                  out, out_len, &got, &reason, err, sizeof(err));
    if (status != EDGE_AI_OK) return -1;
    return got;
}

int edge_ai_stats(void * handle, char * out, int out_len) {
    if (!handle || !out || out_len <= 0) return 0;
    edge_ai_generation_stats stats;
    stats.struct_size = sizeof(stats);
    edge_ai_model_info info;
    info.struct_size = sizeof(info);
    if (edge_ai_get_stats(static_cast<edge_ai_handle *>(handle), &stats) != EDGE_AI_OK) return 0;
    if (edge_ai_get_model_info(static_cast<edge_ai_handle *>(handle), &info) != EDGE_AI_OK) return 0;
    std::snprintf(out, static_cast<size_t>(out_len),
                  "load_ms=%.0f|prefill_ms=%.0f|decode_ms=%.0f|tokens=%d|tok_s=%.2f|ctx=%d|backend=%s",
                  stats.load_ms, stats.prefill_ms, stats.decode_ms, stats.generated_tokens,
                  stats.tokens_per_second, info.n_ctx, info.backend);
    return 1;
}

} // extern "C"
