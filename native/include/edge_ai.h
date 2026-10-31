#ifndef EDGE_AI_H
#define EDGE_AI_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define EDGE_AI_ABI_VERSION 5

typedef struct edge_ai_handle edge_ai_handle;

typedef enum edge_ai_status {
    EDGE_AI_OK = 0,
    EDGE_AI_ERR_INVALID_ARGUMENT = 1,
    EDGE_AI_ERR_NOT_LOADED = 2,
    EDGE_AI_ERR_BUSY = 3,
    EDGE_AI_ERR_OUT_OF_MEMORY = 4,
    EDGE_AI_ERR_CONTEXT_OVERFLOW = 5,
    EDGE_AI_ERR_BACKEND = 6,
    EDGE_AI_ERR_CANCELLED = 7,
    EDGE_AI_ERR_IO = 8,
    EDGE_AI_ERR_UNSUPPORTED = 9,
    EDGE_AI_ERR_BUFFER_TOO_SMALL = 10,
    EDGE_AI_ERR_INTERNAL = 11,
} edge_ai_status;

typedef enum edge_ai_backend_kind {
    EDGE_AI_BACKEND_AUTO = 0,
    EDGE_AI_BACKEND_VULKAN = 1,
    EDGE_AI_BACKEND_CPU = 2,
} edge_ai_backend_kind;

typedef enum edge_ai_stop_reason {
    EDGE_AI_STOP_NONE = 0,
    EDGE_AI_STOP_EOS = 1,
    EDGE_AI_STOP_MAX_TOKENS = 2,
    EDGE_AI_STOP_SEQUENCE = 3,
    EDGE_AI_STOP_CANCELLED = 4,
    EDGE_AI_STOP_ERROR = 5,
} edge_ai_stop_reason;

typedef struct edge_ai_config {
    uint32_t struct_size;
    const char * model_path;

    int32_t backend;            // edge_ai_backend
    int32_t n_gpu_layers;       // -1: derive from backend
    int32_t n_ctx;              // 0: auto from memory budget
    int32_t n_batch;
    int32_t n_ubatch;
    int32_t n_threads;
    int32_t n_threads_batch;
    int32_t flash_attn;         // -1 auto, 0 off, 1 on
    int32_t use_mmap;
    int32_t use_mlock;
    int32_t allow_cpu_fallback;
    int32_t strict_memory;      // 1: fail instead of reducing ctx
    int32_t kv_type_k;          // 0: f16, otherwise ggml_type
    int32_t kv_type_v;

    uint64_t memory_budget_bytes;   // 0: use available system memory
    uint64_t memory_reserve_bytes;  // 0: default reserve
    int32_t min_ctx;
    int32_t max_ctx;
} edge_ai_config;

typedef struct edge_ai_model_info {
    uint32_t struct_size;

    int32_t n_ctx;
    int32_t n_ctx_train;
    int32_t n_batch;
    int32_t n_ubatch;
    int32_t n_threads;
    int32_t n_layer;
    int32_t n_head;
    int32_t n_head_kv;
    int32_t n_embd;
    int32_t n_vocab;
    int32_t n_gpu_layers;
    int32_t is_gpu;
    int32_t recommended_ctx;

    uint64_t n_params;
    uint64_t model_bytes;
    uint64_t kv_bytes_per_token;
    uint64_t kv_bytes;
    uint64_t compute_margin_bytes;
    uint64_t total_ram;
    uint64_t avail_ram;
    uint64_t rss_bytes;
    uint64_t peak_rss_bytes;
    uint64_t budget_bytes;
    uint64_t reserve_bytes;

    char desc[256];
    char backend[256];
    char arch[64];
} edge_ai_model_info;

typedef struct edge_ai_chat_message {
    const char * role;
    const char * content;
} edge_ai_chat_message;

typedef struct edge_ai_chat_message_v3 {
    const char * role;
    const char * content;
    const char * image_path;
} edge_ai_chat_message_v3;

typedef struct edge_ai_chat_message_v4 {
    const char * role;
    const char * content;
    const char * const * image_paths;
    int32_t n_image_paths;
    int32_t reserved;
} edge_ai_chat_message_v4;

typedef struct edge_ai_chat_plan {
    uint32_t struct_size;
    int32_t prompt_tokens;
    int32_t max_output_tokens;
    int32_t n_ctx;
    int32_t dropped_messages;
    int32_t total_messages;
    int32_t fits;
    int32_t prompt_bytes;
} edge_ai_chat_plan;

typedef struct edge_ai_gen_params {
    uint32_t struct_size;

    int32_t max_tokens;
    int32_t top_k;
    int32_t repeat_last_n;
    int32_t ignore_eos;

    uint32_t seed;

    float temperature;
    float top_p;
    float min_p;
    float repeat_penalty;
    float frequency_penalty;
    float presence_penalty;

    const char * const * stop_sequences;
    int32_t n_stop_sequences;
} edge_ai_gen_params;

typedef struct edge_ai_generation_stats {
    uint32_t struct_size;
    int32_t prompt_tokens;
    int32_t generated_tokens;
    int32_t stop_reason;
    double prefill_ms;
    double decode_ms;
    double load_ms;
    double tokens_per_second;
} edge_ai_generation_stats;

uint32_t edge_ai_abi_version(void);
const char * edge_ai_status_string(int32_t status);
const char * edge_ai_stop_reason_string(int32_t reason);

void edge_ai_config_defaults(edge_ai_config * config);

edge_ai_status edge_ai_create_ex(const edge_ai_config * config,
                                 edge_ai_handle ** out_handle,
                                 char * err, int32_t err_len);

edge_ai_status edge_ai_destroy(edge_ai_handle * handle);
edge_ai_status edge_ai_unload(edge_ai_handle * handle);

edge_ai_status edge_ai_get_model_info(edge_ai_handle * handle,
                                      edge_ai_model_info * info);

edge_ai_status edge_ai_prepare_chat(edge_ai_handle * handle,
                                    const edge_ai_chat_message * messages,
                                    int32_t n_messages,
                                    int32_t max_output_tokens,
                                    int32_t enable_thinking,
                                    char * out, int32_t out_cap,
                                    edge_ai_chat_plan * plan);

edge_ai_status edge_ai_start_ex(edge_ai_handle * handle,
                                const char * prompt,
                                const edge_ai_gen_params * params,
                                char * err, int32_t err_len);

edge_ai_status edge_ai_load_mmproj(edge_ai_handle * handle,
                                   const char * mmproj_path,
                                   char * err, int32_t err_len);

edge_ai_status edge_ai_has_vision(edge_ai_handle * handle, int32_t * out_has_vision);

edge_ai_status edge_ai_prepare_chat_v3(edge_ai_handle * handle,
                                       const edge_ai_chat_message_v3 * messages,
                                       int32_t n_messages,
                                       int32_t max_output_tokens,
                                       int32_t enable_thinking,
                                       char * out, int32_t out_cap,
                                       edge_ai_chat_plan * plan);

edge_ai_status edge_ai_start_chat_v3(edge_ai_handle * handle,
                                     const edge_ai_chat_message_v3 * messages,
                                     int32_t n_messages,
                                     const edge_ai_gen_params * params,
                                     char * err, int32_t err_len);

edge_ai_status edge_ai_prepare_chat_v4(edge_ai_handle * handle,
                                       const edge_ai_chat_message_v4 * messages,
                                       int32_t n_messages,
                                       int32_t max_output_tokens,
                                       int32_t enable_thinking,
                                       char * out, int32_t out_cap,
                                       edge_ai_chat_plan * plan);

edge_ai_status edge_ai_start_chat_v4(edge_ai_handle * handle,
                                     const edge_ai_chat_message_v4 * messages,
                                     int32_t n_messages,
                                     const edge_ai_gen_params * params,
                                     char * err, int32_t err_len);

edge_ai_status edge_ai_state_get_size(edge_ai_handle * handle, uint64_t * out_bytes);
edge_ai_status edge_ai_state_save(edge_ai_handle * handle, const char * path,
                                  char * err, int32_t err_len);
edge_ai_status edge_ai_state_load(edge_ai_handle * handle, const char * path,
                                  char * err, int32_t err_len);
edge_ai_status edge_ai_state_clear(edge_ai_handle * handle);

edge_ai_status edge_ai_next_ex(edge_ai_handle * handle,
                               char * out, int32_t out_cap,
                               int32_t * out_len,
                               int32_t * stop_reason,
                               char * err, int32_t err_len);

edge_ai_status edge_ai_cancel(edge_ai_handle * handle);

edge_ai_status edge_ai_get_stats(edge_ai_handle * handle,
                                 edge_ai_generation_stats * stats);

#ifdef __cplusplus
}
#endif

#endif // EDGE_AI_H
