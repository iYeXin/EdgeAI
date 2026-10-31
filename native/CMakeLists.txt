cmake_minimum_required(VERSION 3.19)
project(edge_ai_native C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

set(BUILD_SHARED_LIBS OFF CACHE BOOL "" FORCE)
set(GGML_VULKAN ON CACHE BOOL "" FORCE)
set(GGML_CPU ON CACHE BOOL "" FORCE)
set(GGML_OPENMP OFF CACHE BOOL "" FORCE)
set(GGML_NATIVE OFF CACHE BOOL "" FORCE)
set(GGML_BACKEND_DL OFF CACHE BOOL "" FORCE)

set(LLAMA_BUILD_COMMON ON CACHE BOOL "" FORCE)
set(LLAMA_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_TOOLS OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_TESTS OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_SERVER OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_APP OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_MTMD ON CACHE BOOL "" FORCE)
set(LLAMA_CURL OFF CACHE BOOL "" FORCE)

add_subdirectory(${CMAKE_CURRENT_SOURCE_DIR}/../third_party/llama.cpp ${CMAKE_BINARY_DIR}/llama.cpp)

add_library(edge_ai SHARED src/edge_ai.cpp)
target_include_directories(edge_ai PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/include
    ${CMAKE_CURRENT_SOURCE_DIR}/../third_party/llama.cpp/common
    ${CMAKE_CURRENT_SOURCE_DIR}/../third_party/llama.cpp/tools/mtmd)
target_link_libraries(edge_ai PRIVATE llama llama-common mtmd log)
target_link_options(edge_ai PRIVATE
    "-Wl,-z,max-page-size=16384"
    "-Wl,--version-script=${CMAKE_CURRENT_SOURCE_DIR}/edge_ai.map")
set_target_properties(edge_ai PROPERTIES
    LIBRARY_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/out)

add_executable(edge_ai_smoke test/smoke.cpp)
target_include_directories(edge_ai_smoke PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/include)
target_link_libraries(edge_ai_smoke PRIVATE edge_ai)
set_target_properties(edge_ai_smoke PROPERTIES
    RUNTIME_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/out)

add_executable(edge_ai_vision_smoke test/vision_smoke.cpp)
target_include_directories(edge_ai_vision_smoke PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/include)
target_link_libraries(edge_ai_vision_smoke PRIVATE edge_ai)
set_target_properties(edge_ai_vision_smoke PROPERTIES
    RUNTIME_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/out)

add_executable(edge_ai_vision_state_smoke test/vision_state_smoke.cpp)
target_include_directories(edge_ai_vision_state_smoke PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/include)
target_link_libraries(edge_ai_vision_state_smoke PRIVATE edge_ai)
set_target_properties(edge_ai_vision_state_smoke PROPERTIES
    RUNTIME_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/out)
