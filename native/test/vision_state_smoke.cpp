#include "edge_ai.h"

#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

static std::string generate(edge_ai_handle * h, const char * image,
                            const std::string & system, const std::string & user,
                            const std::string & assistant, bool has_assistant,
                            int max_tokens, edge_ai_generation_stats * stats) {
    edge_ai_chat_message_v4 messages[4];
    std::vector<const char *> paths;
    paths.push_back(image);
    messages[0] = {"system", system.c_str(), nullptr, 0, 0};
    messages[1] = {"user", user.c_str(), paths.data(), 1, 0};
    int n = 2;
    if (has_assistant) {
        messages[n++] = {"assistant", assistant.c_str(), nullptr, 0, 0};
        messages[n++] = {"user", "Again", nullptr, 0, 0};
    }
    edge_ai_gen_params params;
    std::memset(&params, 0, sizeof(params));
    params.struct_size = sizeof(params);
    params.max_tokens = max_tokens;
    params.temperature = 0.2f;
    params.top_p = 0.9f;
    params.top_k = 20;
    char err[1024] = {0};
    auto status = edge_ai_start_chat_v4(h, messages, n, &params, err, sizeof(err));
    std::printf("start=%d %s\n", status, err);
    if (status != EDGE_AI_OK) return {};
    std::string out;
    char buf[4096];
    int32_t reason = 0;
    for (;;) {
        int32_t len = 0;
        status = edge_ai_next_ex(h, buf, sizeof(buf), &len, &reason, err, sizeof(err));
        if (status != EDGE_AI_OK || len == 0) break;
        out.append(buf, static_cast<size_t>(len));
    }
    if (stats) {
        stats->struct_size = sizeof(*stats);
        edge_ai_get_stats(h, stats);
    }
    std::printf("output: %s\n", out.c_str());
    return out;
}

int main(int argc, char ** argv) {
    if (argc < 4) {
        std::fprintf(stderr, "usage: %s model mmproj image state.bin\n", argv[0]);
        return 2;
    }
    const std::string system = "You are a concise assistant.";
    const std::string user = "Describe this image in one short sentence.";
    edge_ai_config config;
    edge_ai_config_defaults(&config);
    config.model_path = argv[1];
    config.backend = EDGE_AI_BACKEND_CPU;
    config.n_ctx = 2048;
    config.min_ctx = 512;
    config.max_ctx = 2048;
    config.n_threads = 4;
    config.memory_reserve_bytes = 1ull * 1024 * 1024 * 1024;
    char err[1024] = {0};
    edge_ai_handle * h = nullptr;
    auto status = edge_ai_create_ex(&config, &h, err, sizeof(err));
    std::printf("create=%d %s\n", status, err);
    if (status != EDGE_AI_OK) return 1;
    status = edge_ai_load_mmproj(h, argv[2], err, sizeof(err));
    std::printf("mmproj=%d %s\n", status, err);
    if (status != EDGE_AI_OK) return 1;

    edge_ai_generation_stats stats{};
    const std::string first = generate(h, argv[3], system, user, "", false, 8, &stats);
    std::printf("first prefill=%.1f gen=%d\n", stats.prefill_ms, stats.generated_tokens);
    status = edge_ai_state_save(h, argv[4], err, sizeof(err));
    std::printf("state save=%d %s\n", status, err);
    edge_ai_destroy(h);

    h = nullptr;
    status = edge_ai_create_ex(&config, &h, err, sizeof(err));
    if (status != EDGE_AI_OK) return 1;
    status = edge_ai_load_mmproj(h, argv[2], err, sizeof(err));
    if (status != EDGE_AI_OK) return 1;
    status = edge_ai_state_load(h, argv[4], err, sizeof(err));
    std::printf("state load=%d %s\n", status, err);
    edge_ai_generation_stats second{};
    generate(h, argv[3], system, user, first, true, 8, &second);
    std::printf("second prefill=%.1f gen=%d\n", second.prefill_ms, second.generated_tokens);
    edge_ai_destroy(h);
    return 0;
}
