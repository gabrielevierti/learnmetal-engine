// Test.hpp
// A unit-test framework in forty lines: TEST(name) { ... } registers a test,
// CHECK and CHECK_NEAR record failures, and main() in Main.cpp runs everything.
#pragma once

#include <cmath>
#include <cstdio>
#include <functional>
#include <vector>

namespace lmtest {

struct Case {
    const char* name;
    std::function<void()> body;
};

inline std::vector<Case>& cases() {
    static std::vector<Case> all;
    return all;
}

inline int& failures() {
    static int count = 0;
    return count;
}

struct Register {
    Register(const char* name, std::function<void()> body) { cases().push_back({name, std::move(body)}); }
};

}  // namespace lmtest

#define TEST(name)                                                        \
    static void test_##name();                                            \
    static lmtest::Register register_##name(#name, test_##name);          \
    static void test_##name()

#define CHECK(condition)                                                  \
    do {                                                                  \
        if (!(condition)) {                                               \
            std::printf("    FAILED %s:%d: %s\n", __FILE__, __LINE__, #condition); \
            lmtest::failures()++;                                         \
        }                                                                 \
    } while (0)

#define CHECK_NEAR(actual, expected, tolerance)                           \
    do {                                                                  \
        double lmA = double(actual), lmE = double(expected);              \
        if (!(std::abs(lmA - lmE) <= double(tolerance))) {                \
            std::printf("    FAILED %s:%d: %s is %g, expected %g\n", __FILE__, __LINE__, #actual, lmA, lmE); \
            lmtest::failures()++;                                         \
        }                                                                 \
    } while (0)
