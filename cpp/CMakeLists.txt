cmake_minimum_required(VERSION 3.16)
project(onload_guard LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
  set(CMAKE_BUILD_TYPE RelWithDebInfo CACHE STRING "Build type" FORCE)
endif()

add_library(onload_guard STATIC src/onload_guard.cpp)
add_library(onload_guard::onload_guard ALIAS onload_guard)

target_include_directories(onload_guard
  PUBLIC
    $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>
    $<INSTALL_INTERFACE:include>
)

target_compile_options(onload_guard PRIVATE -Wall -Wextra -Wpedantic)

option(ONLOAD_GUARD_BUILD_TESTS "Build onload_guard unit tests" ON)
option(ONLOAD_GUARD_BUILD_EXAMPLES "Build onload_guard example launcher" ON)

if(ONLOAD_GUARD_BUILD_TESTS)
  enable_testing()
  add_subdirectory(tests)
endif()

if(ONLOAD_GUARD_BUILD_EXAMPLES)
  add_subdirectory(examples)
endif()

install(TARGETS onload_guard EXPORT onload_guard-targets)
install(DIRECTORY include/ DESTINATION include)
install(EXPORT onload_guard-targets
  FILE onload_guard-targets.cmake
  NAMESPACE onload_guard::
  DESTINATION lib/cmake/onload_guard
)
