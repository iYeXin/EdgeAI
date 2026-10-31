#include "edge_ai.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

static const char * backend_name(int backend) {
    switch (backend) {
        case EDGE_AI_BACKEND_VULKAN: return "vulkan";
        case EDGE_AI_BACKEND_CPU: return "cpu";
        default: return "auto";
    }
}

int main(int argc, char ** argv) {
    if (argc < 2) {
        std::fprintf(stderr, "usage: %s <model.gguf> [vulkan|cpu] [n_ctx]\n", argv[0]);
        return 2;
    }

    edge_ai_config config;
    edge_ai_config_defaults(&config);
    config.model_path = argv[1];
    if (argc > 2) {
        config.backend = std::strcmp(argv[2], "cpu") == 0 ? EDGE_AI_BACKEND_CPU : EDGE_AI_BACKEND_VULKAN;
    } else {
        config.backend = EDGE_AI_BACKEND_VULKAN;
    }
    config.n_ctx = argc > 3 ? std::atoi(argv[3]) : 0;
    config.min_ctx = 512;
    config.max_ctx = 4096;

    edge_ai_handle * handle = nullptr;
    char err[1024] = {0};
    auto status = edge_ai_create_ex(&config, &handle, err, sizeof(err));
    std::printf("create=%d (%s) %s\n", status, edge_ai_status_string(status), err);
    if (status != EDGE_AI_OK) return 1;

    edge_ai_model_info info;
    info.struct_size = sizeof(info);
    status = edge_ai_get_model_info(handle, &info);
    std::printf("info=%d desc=%s backend=%s arch=%s ctx=%d train=%d recommended=%d\n",
                status, info.desc, info.backend, info.arch, info.n_ctx, info.n_ctx_train, info.recommended_ctx);
    std::printf("layers=%d heads=%d/%d embd=%d vocab=%d model=%.2f GiB kv/token=%llu B kv=%.1f MiB\n",
                info.n_layer, info.n_head, info.n_head_kv, info.n_embd, info.n_vocab,
                info.model_bytes / 1024.0 / 1024.0 / 1024.0,
                static_cast<unsigned long long>(info.kv_bytes_per_token),
                info.kv_bytes / 1024.0 / 1024.0);
    std::printf("ram total=%.1f GiB avail=%.1f GiB budget=%.1f GiB rss=%.0f MiB peak=%.0f MiB\n",
                info.total_ram / 1024.0 / 1024.0 / 1024.0,
                info.avail_ram / 1024.0 / 1024.0 / 1024.0,
                info.budget_bytes / 1024.0 / 1024.0 / 1024.0,
                info.rss_bytes / 1024.0 / 1024.0,
                info.peak_rss_bytes / 1024.0 / 1024.0);

    edge_ai_chat_message messages[2];
    messages[0] = {"system", "You are a concise assistant."};
    messages[1] = {"user", "Say hello in one short sentence."};

    edge_ai_chat_plan plan;
    plan.struct_size = sizeof(plan);
    std::vector<char> prompt(1024 * 1024);
    status = edge_ai_prepare_chat(handle, messages, 2, 64, 0, prompt.data(),
                                  static_cast<int32_t>(prompt.size()), &plan);
    std::printf("prepare=%d (%s) tokens=%d max_out=%d dropped=%d total=%d fits=%d bytes=%d\n",
                status, edge_ai_status_string(status), plan.prompt_tokens, plan.max_output_tokens,
                plan.dropped_messages, plan.total_messages, plan.fits, plan.prompt_bytes);

    edge_ai_gen_params params;
    std::memset(&params, 0, sizeof(params));
    params.struct_size = sizeof(params);
    params.max_tokens = 32;
    params.temperature = 0.2f;
    params.top_p = 0.9f;
    params.top_k = 20;
    params.repeat_penalty = 1.05f;
    params.repeat_last_n = 32;

    status = edge_ai_start_ex(handle, prompt.data(), &params, err, sizeof(err));
    std::printf("start=%d (%s) %s\n", status, edge_ai_status_string(status), err);
    if (status != EDGE_AI_OK) {
        edge_ai_destroy(handle);
        return 1;
    }

    std::string output;
    char buffer[4096];
    int32_t reason = EDGE_AI_STOP_NONE;
    for (;;) {
        int32_t len = 0;
        status = edge_ai_next_ex(handle, buffer, sizeof(buffer), &len, &reason, err, sizeof(err));
        if (status != EDGE_AI_OK) {
            std::printf("next=%d (%s) %s\n", status, edge_ai_status_string(status), err);
            break;
        }
        output.append(buffer, static_cast<size_t>(len));
        if (len == 0) break;
    }
    std::printf("output:\n%s\n", output.c_str());

    edge_ai_generation_stats stats;
    stats.struct_size = sizeof(stats);
    edge_ai_get_stats(handle, &stats);
    std::printf("stats: prompt=%d generated=%d prefill=%.1fms decode=%.1fms tok/s=%.2f reason=%s\n",
                stats.prompt_tokens, stats.generated_tokens, stats.prefill_ms, stats.decode_ms,
                stats.tokens_per_second, edge_ai_stop_reason_string(stats.stop_reason));

    edge_ai_destroy(handle);
    return 0;
}
