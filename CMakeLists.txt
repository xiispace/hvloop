cmake_minimum_required(VERSION 3.25)
project(${SKBUILD_PROJECT_NAME} LANGUAGES C)

# Find Python and Cython-cmake
find_package(Python COMPONENTS Interpreter Development.Module REQUIRED)

# ============================================================================
# libhv Configuration
# ============================================================================
# Configure libhv build options (must be set before add_subdirectory)
set(BUILD_SHARED OFF CACHE BOOL "build shared library" FORCE)
set(BUILD_STATIC ON CACHE BOOL "build static library" FORCE)
set(BUILD_EXAMPLES OFF CACHE BOOL "build examples" FORCE)
set(BUILD_UNITTEST OFF CACHE BOOL "build unittest" FORCE)

# libhv feature flags - only enable what we need
set(WITH_EVPP OFF CACHE BOOL "compile evpp" FORCE)
set(WITH_HTTP OFF CACHE BOOL "compile http" FORCE)
set(WITH_HTTP_SERVER OFF CACHE BOOL "compile http/server" FORCE)
set(WITH_HTTP_CLIENT OFF CACHE BOOL "compile http/client" FORCE)
set(WITH_OPENSSL OFF CACHE BOOL "with openssl library" FORCE)
set(WITH_MQTT OFF CACHE BOOL "compile mqtt" FORCE)
set(WITH_PROTOCOL OFF CACHE BOOL "compile protocol" FORCE)

# Add libhv subdirectory
add_subdirectory(vendor/libhv)

# ============================================================================
# Build Cython Module
# ============================================================================
include(UseCython)

# Transpile the thin Cython/libhv binding to C.
cython_transpile(src/hvloop/_core.pyx LANGUAGE C OUTPUT_VARIABLE core_c_source)

# WITH_SOABI adds ABI tag (e.g., module.cpython-311-darwin.so).
python_add_library(_core MODULE "${core_c_source}" WITH_SOABI)

target_link_libraries(_core PRIVATE hv_static)

target_include_directories(_core PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/src/hvloop
    ${CMAKE_CURRENT_SOURCE_DIR}/vendor/libhv/include
    ${CMAKE_CURRENT_SOURCE_DIR}/vendor/libhv/include/hv
    ${CMAKE_CURRENT_SOURCE_DIR}/vendor/libhv/base
    ${CMAKE_CURRENT_SOURCE_DIR}/vendor/libhv/event
    ${CMAKE_CURRENT_BINARY_DIR}/vendor/libhv/include
    ${CMAKE_CURRENT_BINARY_DIR}/vendor/libhv/include/hv
)

target_compile_definitions(_core PRIVATE HV_STATICLIB)

# ============================================================================
# Installation
# ============================================================================
# Install Python extension modules
# scikit-build-core automatically handles the correct installation paths
install(
    TARGETS _core
    COMPONENT python_modules
    LIBRARY DESTINATION hvloop
    RUNTIME DESTINATION hvloop
)
