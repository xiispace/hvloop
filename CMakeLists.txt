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

# Transpile loop.pyx to C
# Note: handle.pyx, transport.pyx, server.pyx are included in loop.pyx via cimport
cython_transpile(
    src/hvloop/loop.pyx
    LANGUAGE C
    OUTPUT_VARIABLE loop_c_source
)

# Create Python extension module
# WITH_SOABI adds the ABI tag (e.g., loop.cpython-311-darwin.so)
python_add_library(loop MODULE "${loop_c_source}" WITH_SOABI)

# Link with libhv static library
target_link_libraries(loop PRIVATE hv_static)

# Configure include directories
target_include_directories(loop PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/src/hvloop          # For .pxd files
    ${CMAKE_CURRENT_SOURCE_DIR}/vendor/libhv/include # For libhv headers
    ${CMAKE_CURRENT_BINARY_DIR}/vendor/libhv/include # For generated hconfig.h
)

# Add compile definitions for static linking
target_compile_definitions(loop PRIVATE HV_STATICLIB)

# ============================================================================
# Installation
# ============================================================================
# Install Python extension modules
# scikit-build-core automatically handles the correct installation paths
install(
    TARGETS loop
    COMPONENT python_modules
    LIBRARY DESTINATION hvloop
    RUNTIME DESTINATION hvloop
)