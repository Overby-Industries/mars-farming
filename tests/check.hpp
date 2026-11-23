#pragma once

// A tiny test harness: CHECK for a condition, CHECK_NEAR for a number against a tolerance
// that is written down before the run. Failures print where and what, and the process
// exit code is the number of failures (capped), so ctest sees them.

#include <cmath>
#include <cstdio>

namespace farmtest {

inline int checks = 0;
inline int failures = 0;

inline void fail(const char* what, const char* file, int line) {
    ++failures;
    std::printf("FAIL %s:%d  %s\n", file, line, what);
}

}  // namespace farmtest

#define CHECK(cond)                                                       \
    do {                                                                  \
        ++farmtest::checks;                                               \
        if (!(cond)) farmtest::fail(#cond, __FILE__, __LINE__);           \
    } while (0)

#define CHECK_NEAR(actual, expected, tol)                                                                    \
    do {                                                                                                     \
        ++farmtest::checks;                                                                                  \
        const double a_ = static_cast<double>(actual);                                                       \
        const double e_ = static_cast<double>(expected);                                                     \
        const double t_ = static_cast<double>(tol);                                                          \
        if (!(std::fabs(a_ - e_) <= t_)) {                                                                   \
            ++farmtest::failures;                                                                            \
            std::printf("FAIL %s:%d  %s = %.9g, expected %.9g +- %.3g\n", __FILE__, __LINE__, #actual, a_, e_, t_); \
        }                                                                                                    \
    } while (0)

void runSpeciesTests();
void runPlantTests();
void runBayTests();
void runColonyTests();
