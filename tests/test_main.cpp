#include <cstdio>

#include "check.hpp"

int main() {
    runSpeciesTests();
    runPlantTests();
    runBayTests();
    runColonyTests();
    std::printf("\n%d checks, %d failures\n", farmtest::checks, farmtest::failures);
    return farmtest::failures == 0 ? 0 : 1;
}
