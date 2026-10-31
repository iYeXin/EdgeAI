#include "edge_ai.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

int main(int argc, char ** argv) {
    if (argc < 4) {
        std::fprintf(stderr, "usage: %s <model.gguf> <mmproj.gguf> <image>\n", argv[0]);
        return 2;
    }

    edge_ai_config config;
    edge_ai_config_defaults(&config);
    config.model_path = argv[1];
    config.backend = EDGE_AI_BACKEND_CPU;
    config.n_ctx = 4096;
    config.min_ctx = 512;
    config.max_ctx = 4096;
    config.n_threads = 4;
    config.memory_budget_bytes = 0;
    config.memory_reserve_bytes = 2ull * 1024 * 1024 * 1024;

    edge_ai_handle * handle = nullptr;
    char err[1024] = {0};
    auto status = edge_ai_create_ex(&config, &handle, err, sizeof(err));
    std::printf("create=%d %s\n", status, err);
    if (status != EDGE_AI_OK) return 1;

    status = edge_ai_load_mmproj(handle, argv[2], err, sizeof(err));
    std::printf("load_mmproj=%d %s\n", status, err);
    if (status != EDGE_AI_OK) return 1;

    int32_t has_vision = 0;
    edge_ai_has_vision(handle, &has_vision);
    std::printf("has_vision=%d\n", has_vision);

    edge_ai_model_info info;
    info.struct_size = sizeof(info);
    edge_ai_get_model_info(handle, &info);
    std::printf("ctx=%d train=%d model=%.2f GiB kv/token=%llu\n",
                info.n_ctx, info.n_ctx_train,
                info.model_bytes / 1024.0 / 1024.0 / 1024.0,
                static_cast<unsigned long long>(info.kv_bytes_per_token));

    std::vector<const char *> image_paths;
    for (int i = 3; i < argc; ++i) image_paths.push_back(argv[i]);

    edge_ai_chat_message_v4 messages[2];
    messages[0] = {"system", "You are a concise assistant.", nullptr, 0, 0};
    messages[1] = {"user", "Describe these images in one short sentence.", image_paths.data(),
                   static_cast<int32_t>(image_paths.size()), 0};

    edge_ai_chat_plan plan;
    plan.struct_size = sizeof(plan);
    std::vector<char> prompt(1024 * 1024);
    status = edge_ai_prepare_chat_v4(handle, messages, 2, 64, 0, prompt.data(),
                                     static_cast<int32_t>(prompt.size()), &plan);
    std::printf("prepare=%d tokens=%d max_out=%d fits=%d prompt_bytes=%d\n",
                status, plan.prompt_tokens, plan.max_output_tokens, plan.fits, plan.prompt_bytes);
    if (status != EDGE_AI_OK) return 1;

    edge_ai_gen_params params;
    std::memset(&params, 0, sizeof(params));
    params.struct_size = sizeof(params);
    params.max_tokens = 64;
    params.temperature = 0.2f;
    params.top_p = 0.9f;
    params.top_k = 20;
    params.repeat_penalty = 1.05f;
    params.repeat_last_n = 32;

    status = edge_ai_start_chat_v4(handle, messages, 2, &params, err, sizeof(err));
    std::printf("start=%d %s\n", status, err);
    if (status != EDGE_AI_OK) return 1;

    std::string output;
    char buffer[4096];
    int32_t reason = EDGE_AI_STOP_NONE;
    for (;;) {
        int32_t len = 0;
        status = edge_ai_next_ex(handle, buffer, sizeof(buffer), &len, &reason, err, sizeof(err));
        if (status != EDGE_AI_OK) {
            std::printf("next=%d %s\n", status, err);
            break;
        }
        output.append(buffer, static_cast<size_t>(len));
        if (len == 0) break;
    }
    std::printf("output:\n%s\n", output.c_str());

    edge_ai_generation_stats stats;
    stats.struct_size = sizeof(stats);
    edge_ai_get_stats(handle, &stats);
    std::printf("stats: prompt=%d generated=%d prefill=%.1fms decode=%.1fms tok/s=%.2f reason=%d\n",
                stats.prompt_tokens, stats.generated_tokens, stats.prefill_ms, stats.decode_ms,
                stats.tokens_per_second, stats.stop_reason);

    edge_ai_destroy(handle);
    return 0;
}
