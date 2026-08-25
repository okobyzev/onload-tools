include(FetchContent)

set(gtest_force_shared_crt ON CACHE BOOL "" FORCE)

FetchContent_Declare(
  googletest
  GIT_REPOSITORY https://github.com/google/googletest.git
  GIT_TAG        v1.15.2
)
FetchContent_MakeAvailable(googletest)

add_executable(onload_guard_tests test_onload_guard.cpp)
target_link_libraries(onload_guard_tests PRIVATE onload_guard::onload_guard GTest::gtest_main)
target_compile_options(onload_guard_tests PRIVATE -Wall -Wextra)

include(GoogleTest)
gtest_discover_tests(onload_guard_tests)
