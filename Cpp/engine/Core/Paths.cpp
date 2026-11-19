#include "Core/Paths.hpp"

#include <cstdlib>
#include <filesystem>

#ifndef LM_SOURCE_ROOT
#define LM_SOURCE_ROOT "."
#endif

namespace lm {

namespace fs = std::filesystem;

std::string findRootDirectory(const std::string& executablePath) {
    if (const char* fromEnvironment = std::getenv("LM_ROOT")) {
        return fromEnvironment;
    }
    if (!executablePath.empty()) {
        std::error_code code;
        fs::path beside = fs::absolute(fs::path(executablePath), code).parent_path();
        if (!code && fs::exists(beside / "Shaders")) return beside.string();
    }
    return LM_SOURCE_ROOT;
}

}  // namespace lm
