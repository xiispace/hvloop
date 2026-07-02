cmake_minimum_required(VERSION 3.25)
project(${SKBUILD_PROJECT_NAME} LANGUAGES C)

# Find Python and Cython-cmake
find_package(Python COMPONENTS Interpreter Development.Module REQUIRED)

# When invoked directly (not through scikit-build-core), the cython-cmake CMake
# helpers (UseCython / FindCython) are not on the module path. Locate them via
# the configured Python interpreter so the documented standalone
# `cmake -S . -B build ...` workflow works out of the box.
if(NOT cython-cmake_FOUND)
    execute_process(
        COMMAND "${Python_EXECUTABLE}" -c
            "import cython_cmake, os; print(os.path.join(os.path.dirname(cython_cmake.__file__), 'cmake'))"
        OUTPUT_VARIABLE _cython_cmake_dir
        OUTPUT_STRIP_TRAILING_WHITESPACE
        RESULT_VARIABLE _cython_cmake_rc
    )
    if(_cython_cmake_rc EQUAL 0 AND EXISTS "${_cython_cmake_dir}")
        list(PREPEND CMAKE_MODULE_PATH "${_cython_cmake_dir}")
    endif()
endif()

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
# Windows: the wepoll reactor backend is what makes add_reader/add_writer
# (and thus sock_*) work on Windows. libhv defaults it to ON; FORCE it so a
# cache/default drift can never silently disable it (tech design section 11).
if(WIN32)
    set(WITH_WEPOLL ON CACHE BOOL "compile event/wepoll -> use iocp" FORCE)
endif()

# Add libhv subdirectory. EXCLUDE_FROM_ALL keeps libhv's own install() rules
# (headers under include/hv, libhv.a, cmake config) OUT of the wheel; the
# hv_static target is still built as a link dependency of _core.
add_subdirectory(vendor/libhv EXCLUDE_FROM_ALL)

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
