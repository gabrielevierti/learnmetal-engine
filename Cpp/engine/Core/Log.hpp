// Log.hpp
// printf-style logging with a level in front. Messages go to stderr, so they do not
// mix with anything a tool prints on stdout.
#pragma once

#include <cstdarg>
#include <cstdio>

namespace lm {

inline void logMessage(const char* level, const char* format, va_list arguments) {
    std::fprintf(stderr, "[%s] ", level);
    std::vfprintf(stderr, format, arguments);
    std::fputc('\n', stderr);
}

#if defined(__GNUC__)
#define LM_PRINTF_LIKE __attribute__((format(printf, 1, 2)))
#else
#define LM_PRINTF_LIKE
#endif

LM_PRINTF_LIKE inline void logInfo(const char* format, ...) {
    va_list arguments;
    va_start(arguments, format);
    logMessage("info", format, arguments);
    va_end(arguments);
}

LM_PRINTF_LIKE inline void logWarning(const char* format, ...) {
    va_list arguments;
    va_start(arguments, format);
    logMessage("warning", format, arguments);
    va_end(arguments);
}

LM_PRINTF_LIKE inline void logError(const char* format, ...) {
    va_list arguments;
    va_start(arguments, format);
    logMessage("error", format, arguments);
    va_end(arguments);
}

}  // namespace lm
